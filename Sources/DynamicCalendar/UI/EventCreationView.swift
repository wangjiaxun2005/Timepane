import SwiftUI

/// Only calendar content is covered while editing; toolbar draft actions remain live.
struct EventCreationCalendarInputGate: ViewModifier {
  @ObservedObject var creation: EventCreationModel
  func body(content: Content) -> some View {
    content
      .allowsHitTesting(!creation.isActive)
      .accessibilityHidden(creation.isActive)
      .overlay {
        if creation.isActive { Color.clear.contentShape(Rectangle()).onTapGesture {} }
      }
  }
}

struct EventCreationHost<Content: View>: View {
  @ObservedObject var creation: EventCreationModel
  let openPrivacySettings: () -> Void
  let content: Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(creation: EventCreationModel, openPrivacySettings: @escaping () -> Void,
       @ViewBuilder content: () -> Content) {
    self.creation = creation
    self.openPrivacySettings = openPrivacySettings
    self.content = content()
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      content
      if let notice = creation.savedNotice, !creation.isActive {
        Text(notice)
          .font(.system(size: 12, weight: .medium))
          .padding(.horizontal, 14).padding(.vertical, 10)
          .panelSurface(cornerRadius: 14)
          .padding(.top, 64).padding(.trailing, 14)
          .transition(.opacity)
          .allowsHitTesting(false)
      }

    }
    .onAppear { creation.reduceMotion = reduceMotion }
    .onChange(of: reduceMotion) { _, value in creation.reduceMotion = value }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await creation.refreshAccess() }
    }
  }
}


struct EventCreationCard: View {
  @ObservedObject var creation: EventCreationModel
  @Binding var draft: EventDraft
  let openPrivacySettings: () -> Void
  @FocusState private var titleFocused: Bool
  @State private var repeatPreset = "none"

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 15) {
          TextField("事件标题", text: $draft.title)
            .font(.system(size: 18, weight: .medium))
            .textFieldStyle(.plain)
            .focused($titleFocused)
            .accessibilityIdentifier("event.title")
          TextField("添加地点", text: $draft.location)
            .textFieldStyle(.plain)
            .accessibilityIdentifier("event.location")
          Divider()
          if !creation.authorization.canReadEvents {
            accessMessage
          } else if creation.calendars.isEmpty {
            Text("没有可写入的日历。请先在苹果日历中添加可写日历。")
              .font(.system(size: 12)).foregroundStyle(.secondary)
          }
          row("日历") {
            Picker("日历", selection: $draft.calendarID) {
              if !creation.calendars.contains(where: { $0.id == draft.calendarID }) {
                Text("请选择日历").tag(draft.calendarID)
              }
              ForEach(creation.calendars) { source in
                Text(source.title + (source.isEnabled ? "" : "（未显示）")).tag(source.id)
              }
            }.labelsHidden().accessibilityIdentifier("event.calendar")
          }
          row("全天") {
            Toggle("全天", isOn: Binding(get: { draft.isAllDay }, set: { draft.setAllDay($0) }))
              .labelsHidden().toggleStyle(.switch).controlSize(.small)
              .accessibilityIdentifier("event.allDay")
          }
          row("开始") {
            DatePicker("开始", selection: Binding(get: { draft.start }, set: {
              draft.moveStart(to: $0, preservingRepeatWeekdays: repeatPreset == "custom")
            }),
              displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
              .labelsHidden().accessibilityIdentifier("event.start")
          }
          row("结束") {
            DatePicker("结束", selection: $draft.end,
              displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
              .labelsHidden().accessibilityIdentifier("event.end")
          }
          if !draft.isAllDay {
            Text(draft.timeZone.localizedName(for: .generic, locale: Locale(identifier: "zh-Hans")) ?? draft.timeZone.identifier)
              .font(.system(size: 11)).foregroundStyle(.tertiary)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
          Divider()
          repeatFields
          alertFields
          Divider()
          TextField("添加网址（https://…）", text: $draft.urlText)
            .textFieldStyle(.plain).accessibilityIdentifier("event.url")
          TextField("添加备注", text: $draft.notes, axis: .vertical)
            .lineLimit(3...5).textFieldStyle(.plain)
            .accessibilityIdentifier("event.notes")
        }
        .font(.system(size: 13))
        .padding(18)
        .disabled(creation.isSaving)
      }
      if let error = creation.errorMessage {
        Divider()
        Text(error).font(.system(size: 12)).foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 18).padding(.vertical, 12)
          .accessibilityIdentifier("event.error")
      }
    }
    .allowsHitTesting(creation.phase == .visible)
    .environment(\.timeZone, draft.timeZone)
    .onAppear { titleFocused = creation.phase == .visible }
    .onChange(of: creation.draftID) { _, _ in repeatPreset = "none" }
    .onChange(of: creation.phase) { _, phase in titleFocused = phase == .visible }
    .onExitCommand(perform: creation.requestCancel)
    .alert("放弃这个事件？", isPresented: $creation.confirmsDiscard) {
      Button("继续编辑", role: .cancel) {}
      Button("放弃更改", role: .destructive, action: creation.dismiss)
    } message: { Text("尚未添加的内容将被丢弃。") }
  }

  private var accessMessage: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("需要日历访问权限才能添加事件。")
        .font(.system(size: 12)).foregroundStyle(.secondary)
      if creation.authorization == .notDetermined {
        AdaptiveGlassButton(action: { Task { await creation.requestAccess() } }) {
          Text(creation.isRequestingAccess ? "正在等待授权…" : "允许日历访问")
        }.disabled(creation.isRequestingAccess)
      } else {
        AdaptiveGlassButton(action: openPrivacySettings) { Text("打开系统设置") }
      }
    }
  }

  private var repeatFields: some View {
    VStack(spacing: 12) {
      row("重复") {
        Picker("重复", selection: $repeatPreset) {
          Text("不重复").tag("none")
          Text("每天").tag("daily")
          Text("每周").tag("weekly")
          Text("每两周").tag("biweekly")
          Text("每月").tag("monthly")
          Text("每年").tag("yearly")
          Text("自定义…").tag("custom")
        }.labelsHidden().accessibilityIdentifier("event.repeat")
          .onChange(of: repeatPreset) { _, value in
            if value == "custom" {
              if draft.recurrence.frequency == .none { draft.recurrence.frequency = .weekly }
            } else {
              draft.recurrence.frequency = value == "biweekly" ? .weekly : EventRepeatFrequency(rawValue: value) ?? .none
              draft.recurrence.interval = value == "biweekly" ? 2 : 1
              draft.recurrence.weekdays = [draft.calendar.component(.weekday, from: draft.start)]
            }
          }
      }
      if repeatPreset == "custom" {
        row("每隔") {
          HStack {
            EventIntegerField("间隔", value: $draft.recurrence.interval)
              .textFieldStyle(.roundedBorder).frame(width: 54)
              .accessibilityIdentifier("event.repeatInterval")
            Picker("单位", selection: $draft.recurrence.frequency) {
              ForEach(EventRepeatFrequency.allCases.filter { $0 != .none }) { frequency in
                Text(frequency.title).tag(frequency)
              }
            }.labelsHidden().frame(width: 80)
          }
        }
        if draft.recurrence.frequency == .weekly {
          row("重复日") {
            HStack(spacing: 3) {
              ForEach(1...7, id: \.self) { day in
                Button {
                  if draft.recurrence.weekdays.contains(day) { draft.recurrence.weekdays.remove(day) }
                  else { draft.recurrence.weekdays.insert(day) }
                } label: { Text(["日", "一", "二", "三", "四", "五", "六"][day - 1]) }
                  .buttonStyle(SharedGlassToolbarButtonStyle(isSelected: draft.recurrence.weekdays.contains(day)))
                  .accessibilityLabel("星期" + ["日", "一", "二", "三", "四", "五", "六"][day - 1])
                  .accessibilityAddTraits(draft.recurrence.weekdays.contains(day) ? .isSelected : [])
              }
            }
          }
        }
      }
      if draft.recurrence.frequency != .none {
        row("结束重复") {
          Picker("结束重复", selection: $draft.recurrence.end) {
            ForEach(EventRepeatEnd.allCases) { end in Text(end.title).tag(end) }
          }.labelsHidden().accessibilityIdentifier("event.repeatEnd")
        }
        if draft.recurrence.end == .date {
          row("结束日期") {
            DatePicker("结束日期", selection: $draft.recurrence.endDate, displayedComponents: [.date]).labelsHidden()
          }
        } else if draft.recurrence.end == .count {
          row("次数") {
            EventIntegerField("次数", value: $draft.recurrence.count)
              .textFieldStyle(.roundedBorder).frame(width: 70)
          }
        }
      }
    }
  }

  private var alertFields: some View {
    VStack(spacing: 12) {
      row("提醒") {
        Picker("提醒", selection: $draft.alert) {
          ForEach(EventAlertChoice.choices(allDay: draft.isAllDay)) { choice in Text(choice.title).tag(choice) }
        }.labelsHidden().accessibilityIdentifier("event.alert")
      }
      if draft.alert == .custom {
        row("提前") {
          HStack {
            EventIntegerField("提前量", value: $draft.customAlertAmount)
              .textFieldStyle(.roundedBorder).frame(width: 65)
            Picker("单位", selection: $draft.customAlertUnit) {
              Text("分钟").tag(60)
              Text("小时").tag(3600)
              Text("天").tag(86400)
            }.labelsHidden().frame(width: 80)
          }
        }
      }
    }
  }

  private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Text(title).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
      Spacer(minLength: 0)
      control().controlSize(.small)
    }
    .frame(minHeight: 24)
  }
}

/// Tracks the real capsule in screen coordinates; no toolbar geometry is duplicated.
struct EventCreationSourceGroup<Content: View>: View {
  let creation: EventCreationModel
  @ObservedObject private var sourceState: EventCreationSourceState
  let content: () -> Content
  init(creation: EventCreationModel, @ViewBuilder content: @escaping () -> Content) {
    self.creation = creation
    self.sourceState = creation.sourceState
    self.content = content
  }
  var body: some View {
    let pressActive = !sourceState.isCovered && (sourceState.isPressed || sourceState.isLaunching)
    EventCreationSourceContent(creation: creation, root: content())
      .modifier(EventCreationPressPresentation(creation: creation,
        scale: pressActive
          ? EventBubbleMotion.pressedScale.width : sourceState.handoffScale))
      .brightness(pressActive ? 0.045 : 0)
      .animation(.easeOut(duration: 0.10), value: pressActive)
      .transaction { transaction in
        if sourceState.isCovered { transaction.disablesAnimations = true; transaction.animation = nil }
      }
  }
}

/// Keep real toolbar controls and their layout stable while the parent scene
/// supplies their visual presentation. Coverage changes only input ownership.
struct EventCreationSourceContent<Root: View>: NSViewRepresentable {
  let creation: EventCreationModel
  let root: Root
  var hitWidth: CGFloat? = nil
  func makeNSView(context: Context) -> EventCreationSourceContainer<Root> {
    let view = EventCreationSourceContainer(root: root)
    view.hitWidth = hitWidth
    creation.sourceVisibilityDriver = { [weak view] covered in view?.setCovered(covered) }
    return view
  }
  func updateNSView(_ view: EventCreationSourceContainer<Root>, context: Context) {
    view.host.rootView = root
    view.hitWidth = hitWidth
    view.setCovered(creation.sourceState.isCovered)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: EventCreationSourceContainer<Root>, context: Context) -> CGSize? {
    nsView.host.fittingSize
  }
}

final class EventCreationSourceContainer<Root: View>: NSView {
  var hitWidth: CGFloat?
  let host: NSHostingView<Root>
  init(root: Root) {
    host = NSHostingView(rootView: root)
    super.init(frame: .zero)
    host.autoresizingMask = [.width, .height]
    clipsToBounds = false
    host.clipsToBounds = false
    addSubview(host)
  }
  required init?(coder: NSCoder) { nil }
  override func layout() {
    super.layout()
    if host.superview != nil { host.frame = bounds }
  }
  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    let width = min(bounds.width, hitWidth ?? bounds.width)
    let visibleControls = CGRect(x: bounds.maxX - width, y: bounds.minY,
                                 width: width, height: bounds.height)
    // The unused left side reserves fission space, but must never intercept
    // the Week/Month selector underneath that transparent footprint.
    guard !isHidden, !host.isHidden, visibleControls.contains(local) else { return nil }
    return host.hitTest(local)
  }

  func setCovered(_ covered: Bool) {
    guard host.isHidden != covered else { return }
    if !covered { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
    host.isHidden = covered
  }
}

private struct EventCreationPressPresentation: AnimatableModifier {
  let creation: EventCreationModel
  var scale: CGFloat
  var animatableData: CGFloat {
    get { scale }
    set { scale = newValue }
  }
  func body(content: Content) -> some View {
    content.scaleEffect(scale)
      .background(EventCreationSourceAnchor(creation: creation, displayedScale: scale))
  }
}

struct EventCreationSourceAnchor: NSViewRepresentable {
  let creation: EventCreationModel
  let displayedScale: CGFloat
  func makeNSView(context: Context) -> NSView {
    let view = EventCreationAnchorView()
    view.creation = creation
    creation.sourceView = view
    return view
  }
  func updateNSView(_ nsView: NSView, context: Context) {
    creation.sourceState.recordPresentation(scale: displayedScale)
    creation.presentationLayoutDriver?()
  }
}


private final class EventCreationAnchorView: NSView {
  weak var creation: EventCreationModel?
  override func layout() { super.layout(); creation?.presentationLayoutDriver?() }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); creation?.presentationLayoutDriver?() }
}

/// Keep the draft in sync while editing, including empty or malformed values.
/// A formatted numeric TextField can otherwise leave the previous value in the
/// model until focus changes, allowing Save to race its formatter's commit.
private struct EventIntegerField: View {
  let title: String
  @Binding var value: Int
  @State private var text: String
  init(_ title: String, value: Binding<Int>) {
    self.title = title
    self._value = value
    self._text = State(initialValue: String(value.wrappedValue))
  }
  var body: some View {
    TextField(title, text: Binding(get: { text }, set: {
      text = $0
      value = Int($0.trimmingCharacters(in: .whitespaces)) ?? 0
    }))
    .onChange(of: value) { _, newValue in
      if (Int(text.trimmingCharacters(in: .whitespaces)) ?? 0) != newValue {
        text = String(newValue)
      }
    }
  }
}

/// Shares the actual Button press state with its glass capsule and presentation handoff.
struct EventCreationAddButtonStyle: ButtonStyle {
  let sourceState: EventCreationSourceState
  func makeBody(configuration: Configuration) -> some View {
    EventCreationPressLabel(label: configuration.label, pressed: configuration.isPressed,
                            sourceState: sourceState)
  }
}

private struct EventCreationPressLabel<Label: View>: View {
  let label: Label
  let pressed: Bool
  @ObservedObject var sourceState: EventCreationSourceState
  var body: some View {
    let responding = pressed || sourceState.isLaunching
    label.font(.system(size: 12, weight: .semibold))
      .foregroundStyle(Color.primary.opacity(0.78))
      .frame(width: 28, height: 26)
      .background(Capsule().fill(Color.primary.opacity(responding ? 0.10 : 0)))
      .contentShape(Capsule())
      .animation(.easeOut(duration: 0.09), value: responding)
      .onChange(of: pressed) { _, value in sourceState.isPressed = value }
  }
}

/// The glass and all three symbols share one press transform. The outer layout
/// and source anchor stay fixed, and the compositor samples this actual pose.
struct EventToolbarPressGroup<Content: View>: View {
  @ObservedObject var state: EventCreationSourceState
  let reduceMotion: Bool
  @ViewBuilder let content: () -> Content
  var body: some View {
    let active = state.isPressed || state.isLaunching
    content()
      .modifier(EventToolbarPressTransform(amount: active && !reduceMotion ? 1 : 0, state: state))
      .animation(.easeOut(duration: active ? 0.07 : 0.12), value: active)
      .transaction {
        if state.isCovered { $0.disablesAnimations = true; $0.animation = nil }
      }
  }
}

private struct EventToolbarPressTransform: AnimatableModifier {
  var amount: CGFloat
  let state: EventCreationSourceState
  var animatableData: CGFloat {
    get { amount }
    set { amount = newValue }
  }
  func body(content: Content) -> some View {
    if !state.isCovered { state.recordToolbarPress(amount: amount) }
    return content.scaleEffect(x: 1 + 0.035 * amount, y: 1 + 0.045 * amount)
  }
}
