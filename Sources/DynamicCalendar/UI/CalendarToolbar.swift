import AppKit
import SwiftUI

struct CalendarToolbar: View {
  @EnvironmentObject private var motion: PanelMotionModel
  @ObservedObject var model: AppModel
  @ObservedObject var creation: EventCreationModel
  let modeSelectionAnimator: CalendarModeSelectionAnimator
  @ObservedObject var interaction: CalendarInteractionCoordinator
  let surfaceNamespace: Namespace.ID
  let onCollapse: () -> Void
  let onTogglePin: () -> Void
  let onMovePeriod: (Int) -> Void
  let onSelectDisplayMode: (CalendarDisplayMode) -> Void

  var body: some View {
    // Editor commands stay live in the toolbar throughout the split.
    Group {
      HStack(spacing: 10) {
        AdaptiveGlassControlGroup(clearGlass: true) {
          HStack(spacing: 1) {
            Button {
              onMovePeriod(-1)
            } label: {
              Image(systemName: "chevron.left")
                .frame(width: 16, height: 16)
            }
            .buttonStyle(SharedGlassToolbarButtonStyle())
            .help(interaction.intendedMode == .week ? "上一周" : "上个月")

            Button {
              interaction.submit(.today)
            } label: {
              Text("今天")
            }
            .buttonStyle(SharedGlassToolbarButtonStyle(minimumWidth: 40))

            Button {
              onMovePeriod(1)
            } label: {
              Image(systemName: "chevron.right")
                .frame(width: 16, height: 16)
            }
            .buttonStyle(SharedGlassToolbarButtonStyle())
            .help(interaction.intendedMode == .week ? "下一周" : "下个月")
          }
        }

        .allowsHitTesting(!creation.isActive)

        Group {
          if interaction.isActive {
            CalendarInteractionTitle(interaction: interaction)
          } else {
            Text(periodTitle)
              .font(.system(size: 15, weight: .semibold))
              .lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .frame(width: 168, height: 24, alignment: .leading)
        .clipped()
        .padding(.leading, 6)

        Spacer()

        EventToolbarModeSlot(creation: creation) {
          AdaptiveGlassControlGroup(clearGlass: true) {
          CalendarModePicker(
            displayMode: interaction.intendedMode,
            animator: modeSelectionAnimator,
            onSelect: onSelectDisplayMode,
            committedMode: model.displayMode
          )
          .equatable()
        }

        .allowsHitTesting(!creation.isActive)

        }

        EventCreationToolbarActions(creation: creation, isPinned: model.isPinned,
          onAdd: model.beginEventCreation, onTogglePin: onTogglePin,
          onSettings: {
            interaction.reset()
            model.selectedEvent = nil
            model.route = .settings
          })

      }
      .padding(.horizontal, 14)
      .frame(height: 56)
    }
  }

  private var periodTitle: String {
    switch model.displayMode {
    case .week:
      let end =
        model.calendar.date(byAdding: .day, value: -1, to: model.periodSchedule.endDate)
        ?? model.periodSchedule.endDate
      return
        "\(DateFormatting.shortDay.string(from: model.periodSchedule.startDate)) – \(DateFormatting.shortDay.string(from: end))"
    case .month:
      return DateFormatting.monthAndYear.string(from: model.monthLayout.monthStart)
    }
  }

}

/// Logical toolbar controls share the permanent parent scene for glass.
/// Their fixed layout anchors and accessibility actions survive fission.
private struct EventCreationToolbarActions: View {
  @ObservedObject var creation: EventCreationModel
  let isPinned: Bool
  let onAdd: () -> Void
  let onTogglePin: () -> Void
  let onSettings: () -> Void
  @State private var isSplit = false

  var body: some View {
    EventCreationSourceContent(creation: creation,
      root: controls.frame(width: 143, height: 32, alignment: .trailing),
      hitWidth: isSplit ? 143 : 92)
      .allowsHitTesting(!usesNativeScene)
      .accessibilityHidden(usesNativeScene)
      .frame(width: 143, height: 32)
      .frame(width: 92, height: 32, alignment: .trailing)
      .background(alignment: .trailing) {
        EventCreationSourceAnchor(creation: creation, displayedScale: 1)
          .frame(width: 92, height: 32).allowsHitTesting(false)
      }
      .onAppear { isSplit = creation.isMounted && !creation.isClosing }
      .onReceive(creation.sourceState.$isCovered) { covered in
        // Change endpoint controls only after native geometry owns the surface.
        if covered { isSplit = creation.isMounted && !creation.isClosing }
      }
      .onChange(of: creation.phase) { _, phase in
        if creation.sourceState.isCovered || creation.reduceMotion || phase == .hidden || phase == .visible {
          isSplit = creation.isMounted && !creation.isClosing
        }
      }
  }

  private var usesNativeScene: Bool {
    if #available(macOS 26.0, *) { return true }
    return false
  }

  @ViewBuilder private var controls: some View {
    if isSplit {
      HStack(spacing: 8) {
        cancelButton
          .frame(width: 32, height: 32)
        saveButton
          .frame(width: 32, height: 32)
        trailingButtons.padding(3)
      }
      .background(EventToolbarEndpointGlass(isSplit: true))
    } else {
      EventToolbarPressGroup(state: creation.sourceState, reduceMotion: creation.reduceMotion) {
          HStack(spacing: 1) {
            Button(action: onAdd) { Image(systemName: "plus").frame(width: 16, height: 16).modifier(EventSceneGlyph()) }
              .buttonStyle(EventCreationAddButtonStyle(sourceState: creation.sourceState))
              .help("添加事件")
              .accessibilityLabel("添加事件")
              .accessibilityIdentifier("event.create")
            trailingButtons
          }
          .padding(3)
          .background(EventToolbarEndpointGlass(isSplit: false))
      }
    }
  }

  private var cancelButton: some View {
    Button { creation.requestCancel() } label: {
      Image(systemName: "plus").rotationEffect(.degrees(45))
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.primary.opacity(0.78))
        .frame(width: 32, height: 32).contentShape(Circle())
        .modifier(EventSceneGlyph())
    }
    .buttonStyle(.plain)
    .allowsHitTesting(!creation.isSaving && !creation.isRequestingAccess && !creation.isClosing)
    .help("取消添加").accessibilityLabel("取消添加").accessibilityIdentifier("event.cancel")
  }

  private var saveButton: some View {
    Button { Task { await creation.save() } } label: {
      Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white.opacity(creation.canSave ? 1 : 0.45))
        .frame(width: 32, height: 32).contentShape(Circle())
        .modifier(EventSceneGlyph())
    }
    .buttonStyle(.plain)
    .disabled(!creation.canSave || creation.phase != .visible || creation.isRequestingAccess)
    .modifier(EventSaveShortcut())
    .help(creation.isSaving ? "正在添加事件" : "添加事件")
    .accessibilityLabel("添加事件").accessibilityIdentifier("event.save")
  }

  private var trailingButtons: some View {
    HStack(spacing: 1) {
      Button(action: onTogglePin) {
        Image(systemName: isPinned ? "pin.fill" : "pin").frame(width: 16, height: 16).modifier(EventSceneGlyph())
      }
      .buttonStyle(SharedGlassToolbarButtonStyle(isActive: isPinned))
      .help(isPinned ? "取消置顶" : "保持置顶")
      .accessibilityLabel(isPinned ? "取消置顶" : "置顶")
      Button(action: onSettings) { Image(systemName: "gearshape").frame(width: 16, height: 16).modifier(EventSceneGlyph()) }
        .buttonStyle(SharedGlassToolbarButtonStyle())
        .help("设置").accessibilityLabel("设置").allowsHitTesting(!creation.isActive).accessibilityHidden(creation.isActive)
    }
  }
}

/// The button remains a real accessible control. Only its image is supplied by
/// the native scene so glass can never cover or replace the endpoint glyph.
private struct EventSceneGlyph: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) { content.opacity(0) }
    else { content }
  }
}

private struct EventSaveShortcut: ViewModifier {
  @ViewBuilder func body(content: Content) -> some View {
    if #available(macOS 26.0, *) { content }
    else { content.keyboardShortcut(.return, modifiers: .command) }
  }
}

/// Use the animation's actual compositor at rest, not individual glass views
/// whose material changes when they enter a native fusion container.
private struct EventToolbarEndpointGlass: View {
  let isSplit: Bool
  var body: some View {
    if #available(macOS 26.0, *) {
      // The parent scene owns native glass at rest and throughout motion.
      Color.clear
    } else {
      HStack(spacing: 8) {
        if isSplit {
          Circle().fill(Color.primary.opacity(0.08)).frame(width: 32)
          Circle().fill(Color.accentColor).frame(width: 32)
        }
        Capsule().fill(Color.black.opacity(0.10))
          .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
      }
    }
  }
}

/// Reserve the expanded footprint once; only the small hosting view moves.
/// The selector remains inside this slot in both states, including hit testing.
private struct EventToolbarModeSlot<Content: View>: NSViewRepresentable {
  let creation: EventCreationModel
  @ViewBuilder let content: () -> Content
  func makeNSView(context: Context) -> EventToolbarModeContainer<Content> {
    let view = EventToolbarModeContainer(root: content())
    creation.toolbarLayoutDriver = { [weak view] offset in view?.present(offset) }
    view.present(creation.toolbarLayoutOffset)
    return view
  }
  func updateNSView(_ view: EventToolbarModeContainer<Content>, context: Context) {
    view.host.rootView = content()
    view.present(creation.toolbarLayoutOffset)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: EventToolbarModeContainer<Content>, context: Context) -> CGSize? {
    // This selector has a fixed 76 × 26 content size and 3-point glass padding.
    // Do not feed a constrained hosting frame back into the next layout proposal.
    CGSize(width: CalendarModePickerMetrics.width + 6 + 55,
           height: CalendarModePickerMetrics.height + 6)
  }
}

private final class EventToolbarModeContainer<Content: View>: NSView {
  let host: NSHostingView<Content>
  private var offset: CGFloat = 0
  init(root: Content) {
    host = NSHostingView(rootView: root)
    host.sizingOptions = []
    super.init(frame: .zero)
    addSubview(host)
  }
  required init?(coder: NSCoder) { nil }
  override func layout() { super.layout(); present(offset) }
  func present(_ offset: CGFloat) {
    self.offset = offset
    let size = CGSize(width: max(0, bounds.width - 55), height: bounds.height)
    let frame = CGRect(x: 55 - offset, y: 0, width: size.width, height: size.height)
    if host.frame != frame { host.frame = frame }
  }
  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard host.frame.contains(local) else { return nil }
    return host.hitTest(local)
  }
}
