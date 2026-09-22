import AppKit
import QuartzCore
import SwiftUI

struct CalendarViewportRenderToken: Equatable {
  let generation: Int
  let canvasSize: CGSize
  let displayMode: CalendarDisplayMode
  let focusedDate: Date
  let periodStart: Date
  let periodEnd: Date
  let visibleStartMinute: Int
  let visibleEndMinute: Int
  let maximumAllDayEventCount: Int
  let monthGridStart: Date
  let monthGridEnd: Date
  let monthRowCount: Int
  let eventIDs: [String]
  let layoutSignature: CalendarViewportLayoutSignature
  let geometrySummary: CalendarZoomGeometrySnapshot?

  init(
    viewport: CalendarViewportState,
    generation: Int,
    canvasSize: CGSize,
    geometrySummary: CalendarZoomGeometrySnapshot? = nil
  ) {
    self.generation = generation
    self.canvasSize = canvasSize
    displayMode = viewport.displayMode
    focusedDate = viewport.focusedDate
    periodStart = viewport.periodSchedule.startDate
    periodEnd = viewport.periodSchedule.endDate
    visibleStartMinute = viewport.weekLayout.visibleStartMinute
    visibleEndMinute = viewport.weekLayout.visibleEndMinute
    maximumAllDayEventCount = viewport.weekLayout.maximumAllDayEventCount
    monthGridStart = viewport.monthLayout.gridStart
    monthGridEnd = viewport.monthLayout.gridEnd
    monthRowCount = viewport.monthLayout.weeks.count
    eventIDs = viewport.periodSchedule.events.map(\.id).sorted()
    layoutSignature = CalendarViewportLayoutSignature(viewport: viewport)
    self.geometrySummary = geometrySummary
  }
}

struct CalendarViewportLayoutSignature: Equatable {
  let focusedDate: Date
  let periodSchedule: CalendarPeriodSchedule
  let weekLayout: WeekLayout
  let monthLayout: MonthLayout

  init(viewport: CalendarViewportState) {
    focusedDate = viewport.focusedDate
    periodSchedule = viewport.periodSchedule
    weekLayout = viewport.weekLayout
    monthLayout = viewport.monthLayout
  }
}

enum CalendarZoomCoordinateSpace {
  static let name = "calendar.zoom.canvas"
}

struct CalendarZoomGeometryPreferenceKey: PreferenceKey {
  static var defaultValue: [CalendarZoomGeometryKey: CGRect] = [:]

  static func reduce(
    value: inout [CalendarZoomGeometryKey: CGRect],
    nextValue: () -> [CalendarZoomGeometryKey: CGRect]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

extension View {
  @ViewBuilder
  func calendarZoomGeometry(
    _ element: CalendarZoomElementID,
    endpoint: CalendarZoomEndpoint?
  ) -> some View {
    if let endpoint {
      background {
        GeometryReader { proxy in
          Color.clear.preference(
            key: CalendarZoomGeometryPreferenceKey.self,
            value: [
              CalendarZoomGeometryKey(endpoint: endpoint, element: element):
                proxy.frame(in: .named(CalendarZoomCoordinateSpace.name))
            ]
          )
        }
      }
    } else {
      self
    }
  }
}

struct CalendarZoomEndpointMask: Shape {
  enum Role {
    case source
    case bridge
    case target
  }

  var progress: CGFloat
  var clock: CalendarMotionTrack? = nil
  let role: Role
  let direction: CalendarZoomDirection
  let weekCenterY: CGFloat
  let monthCenterY: CGFloat

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func path(in rect: CGRect) -> Path {
    let boundedProgress = min(1, max(0, clock?.value(at: Double(progress)) ?? progress))
    let bandProgress: CGFloat
    let drawsInsideBand: Bool
    switch role {
    case .source:
      bandProgress = CalendarZoomEndpointTransfer.sourceBandProgress(boundedProgress)
      drawsInsideBand = false
    case .bridge:
      if boundedProgress < CalendarZoomEndpointTransfer.handoffFraction {
        bandProgress = CalendarZoomEndpointTransfer.sourceBandProgress(boundedProgress)
        drawsInsideBand = true
      } else if boundedProgress > 1 - CalendarZoomEndpointTransfer.handoffFraction {
        bandProgress = CalendarZoomEndpointTransfer.targetBandProgress(boundedProgress)
        drawsInsideBand = false
      } else {
        return Path(rect)
      }
    case .target:
      bandProgress = CalendarZoomEndpointTransfer.targetBandProgress(boundedProgress)
      drawsInsideBand = true
    }

    let monthness = direction == .weekToMonth ? boundedProgress : 1 - boundedProgress
    let centerY = weekCenterY + (monthCenterY - weekCenterY) * monthness
    let center = min(rect.maxY, max(rect.minY, centerY))
    let reach = max(center - rect.minY, rect.maxY - center)
    let halfHeight = reach * bandProgress
    let band = CGRect(
      x: rect.minX,
      y: center - halfHeight,
      width: rect.width,
      height: halfHeight * 2
    ).intersection(rect)

    if drawsInsideBand {
      guard bandProgress > 0 else { return Path() }
      return Path(band)
    }

    guard bandProgress < 1 else { return Path() }
    var path = Path()
    if band.minY > rect.minY {
      path.addRect(CGRect(
        x: rect.minX,
        y: rect.minY,
        width: rect.width,
        height: band.minY - rect.minY
      ))
    }
    if band.maxY < rect.maxY {
      path.addRect(CGRect(
        x: rect.minX,
        y: band.maxY,
        width: rect.width,
        height: rect.maxY - band.maxY
      ))
    }
    return path
  }
}

extension CGRect {
  var center: CGPoint { CGPoint(x: midX, y: midY) }
}

struct CalendarViewportPage: View, Equatable {
  let viewport: CalendarViewportState
  let authorization: CalendarAuthorizationState
  let hasEnabledCalendars: Bool
  let calendar: Calendar
  let zoomEndpoint: CalendarZoomEndpoint?
  let onSelectEvent: (ScheduleEvent) -> Void
  let onDismissDetail: () -> Void
  let onSelectDay: (Date) -> Void
  let onOpenSettings: () -> Void
  let onRequestCalendarAccess: () -> Void
  let onOpenPrivacySettings: () -> Void

  static func == (lhs: CalendarViewportPage, rhs: CalendarViewportPage) -> Bool {
    let viewportMatches = lhs.viewport.renderRevision != 0 || rhs.viewport.renderRevision != 0
      ? lhs.viewport.renderRevision == rhs.viewport.renderRevision
      : lhs.viewport == rhs.viewport
    return viewportMatches
      && lhs.authorization == rhs.authorization
      && lhs.hasEnabledCalendars == rhs.hasEnabledCalendars
      && lhs.calendar == rhs.calendar
      && lhs.zoomEndpoint == rhs.zoomEndpoint
  }

  var body: some View {
    ZStack {
      CalendarViewportContent(
        viewport: viewport,
        calendar: calendar,
        onSelectEvent: onSelectEvent,
        onDismissDetail: onDismissDetail,
        onSelectDay: onSelectDay,
        zoomEndpoint: zoomEndpoint
      )

      if !authorization.canReadEvents {
        PermissionOverlay(
          authorization: authorization,
          onRequestAccess: onRequestCalendarAccess,
          onOpenSettings: onOpenPrivacySettings
        )
      } else if !hasEnabledCalendars {
        EmptyOverlay(
          icon: "calendar.badge.minus",
          title: "没有启用的日历",
          detail: "在设置中勾选至少一个日历。",
          action: onOpenSettings
        )
      } else if viewport.displayMode == .month,
                viewport.periodSchedule.events.isEmpty {
        EmptyOverlay(
          icon: "calendar",
          title: "本月暂无日程",
          detail: "这个月很清爽。你可以切换到前后月查看安排。",
          action: nil
        )
      }
    }
  }
}

struct CalendarZoomEndpointHost: View {
  let viewport: CalendarViewportState
  let scene: CalendarZoomScene?
  let phase: CalendarZoomPhase
  var progress: CGFloat
  var clock: CalendarMotionTrack? = nil
  let generation: Int
  let authorization: CalendarAuthorizationState
  let hasEnabledCalendars: Bool
  let calendar: Calendar
  let onSelectEvent: (ScheduleEvent) -> Void
  let onDismissDetail: () -> Void
  let onSelectDay: (Date) -> Void
  let onOpenSettings: () -> Void
  let onRequestCalendarAccess: () -> Void
  let onOpenPrivacySettings: () -> Void
  let onRenderCommitted: (CalendarViewportRenderToken) -> Void

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .topLeading) {
        if let scene, phase == .animating || phase == .handoff {
          CalendarZoomStage(
            scene: scene,
            calendar: calendar,
            progress: progress, clock: clock,
            onSelectEvent: onSelectEvent,
            onSelectDay: onSelectDay
          )
          .modifier(CalendarZoomHitTesting(progress: progress, clock: clock, role: .bridge))
          .mask {
            endpointMask(role: .bridge, scene: scene, size: proxy.size)
          }
        }

        // Keep live callbacks inside the Equatable page. Replacing them with
        // no-ops during a transition lets SwiftUI reuse those stale closures
        // after handoff because closures are intentionally absent from `==`.
        CalendarViewportPage(
          viewport: viewport,
          authorization: authorization,
          hasEnabledCalendars: hasEnabledCalendars,
          calendar: calendar,
          zoomEndpoint: phase == .preparing ? .source : nil,
          onSelectEvent: onSelectEvent,
          onDismissDetail: onDismissDetail,
          onSelectDay: onSelectDay,
          onOpenSettings: onOpenSettings,
          onRequestCalendarAccess: onRequestCalendarAccess,
          onOpenPrivacySettings: onOpenPrivacySettings
        )
        .equatable()
        // Once magnification wins recognition, prevent a child event Button
        // from completing its pending click in the same input sequence.
        .modifier(CalendarZoomHitTesting(progress: progress, clock: clock, role: .source))
        .mask {
          if let scene {
            endpointMask(role: .source, scene: scene, size: proxy.size)
          } else {
            Rectangle()
          }
        }

        if let scene {
          CalendarViewportPage(
            viewport: scene.target,
            authorization: authorization,
            hasEnabledCalendars: hasEnabledCalendars,
            calendar: calendar,
            zoomEndpoint: phase == .preparing ? .target : nil,
            onSelectEvent: onSelectEvent,
            onDismissDetail: onDismissDetail,
            onSelectDay: onSelectDay,
            onOpenSettings: onOpenSettings,
            onRequestCalendarAccess: onRequestCalendarAccess,
            onOpenPrivacySettings: onOpenPrivacySettings
          )
          .equatable()
          .allowsHitTesting(phase != .preparing)
          .modifier(CalendarZoomHitTesting(progress: progress, clock: clock, role: .target))
          .modifier(CalendarZoomTargetEndpointModifier(
            isPreparing: phase == .preparing,
            progress: progress, clock: clock,
            direction: scene.direction,
            weekCenterY: proxy.size.height / 2,
            monthCenterY: monthCenterY(scene: scene, size: proxy.size)
          ))
        }

        if phase == .handoff, let scene {
          CalendarRenderCommitProbe(
            token: CalendarViewportRenderToken(
              viewport: scene.target,
              generation: generation,
              canvasSize: proxy.size,
              geometrySummary: scene.targetGeometry
            ),
            onCommitted: onRenderCommitted
          )
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
  }

  private func monthCenterY(scene: CalendarZoomScene, size: CGSize) -> CGFloat {
    let geometry = CalendarZoomGeometry(
      size: size,
      focusRowIndex: scene.focusRowIndex,
      monthRowCount: scene.monthRowCount
    )
    return geometry.focusRowMidY
  }

  private func endpointMask(
    role: CalendarZoomEndpointMask.Role,
    scene: CalendarZoomScene,
    size: CGSize
  ) -> CalendarZoomEndpointMask {
    CalendarZoomEndpointMask(
      progress: progress, clock: clock,
      role: role,
      direction: scene.direction,
      weekCenterY: size.height / 2,
      monthCenterY: monthCenterY(scene: scene, size: size)
    )
  }
}

private struct CalendarZoomHitTesting: AnimatableModifier {
  var progress: CGFloat
  let clock: CalendarMotionTrack?
  let role: CalendarZoomEndpointMask.Role
  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }
  func body(content: Content) -> some View {
    let value = clock?.value(at: Double(progress)) ?? progress
    let enabled: Bool
    switch role {
    case .source: enabled = value <= CalendarZoomEndpointTransfer.handoffFraction
    case .bridge: enabled = value > 0 && value < 1
    case .target: enabled = value >= 1 - CalendarZoomEndpointTransfer.handoffFraction
    }
    return content.allowsHitTesting(enabled)
  }
}

struct CalendarZoomTargetEndpointModifier: ViewModifier {
  let isPreparing: Bool
  let progress: CGFloat
  var clock: CalendarMotionTrack? = nil
  let direction: CalendarZoomDirection
  let weekCenterY: CGFloat
  let monthCenterY: CGFloat

  func body(content: Content) -> some View {
    if isPreparing {
      content.hidden()
    } else {
      content.mask {
        CalendarZoomEndpointMask(
          progress: progress, clock: clock,
          role: .target,
          direction: direction,
          weekCenterY: weekCenterY,
          monthCenterY: monthCenterY
        )
      }
    }
  }
}

struct CalendarRenderCommitProbe: NSViewRepresentable {
  let token: CalendarViewportRenderToken
  let onCommitted: (CalendarViewportRenderToken) -> Void

  func makeNSView(context: Context) -> ProbeView {
    let view = ProbeView()
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.clear.cgColor
    return view
  }

  func updateNSView(_ nsView: ProbeView, context: Context) {
    nsView.arm(token: token, onCommitted: onCommitted)
  }

  final class ProbeView: NSView {
    private var token: CalendarViewportRenderToken?
    private var reportedToken: CalendarViewportRenderToken?
    private var onCommitted: ((CalendarViewportRenderToken) -> Void)?

    override var wantsUpdateLayer: Bool { true }

    func arm(
      token: CalendarViewportRenderToken,
      onCommitted: @escaping (CalendarViewportRenderToken) -> Void
    ) {
      self.token = token
      self.onCommitted = onCommitted
      if reportedToken != token {
        needsDisplay = true
        layer?.setNeedsDisplay()
      }
    }

    override func updateLayer() {
      super.updateLayer()
      guard let token, reportedToken != token else { return }
      reportedToken = token
      let callback = onCommitted
      DispatchQueue.main.async {
        callback?(token)
      }
    }
  }
}

struct CalendarViewportContent: View, Equatable {
  let viewport: CalendarViewportState
  let calendar: Calendar
  let onSelectEvent: (ScheduleEvent) -> Void
  let onDismissDetail: () -> Void
  let onSelectDay: (Date) -> Void
  var hidesFocusDates = false
  var focusRowIndex: Int?
  var hiddenEventRowIndex: Int?
  var hidesAllEvents = false
  var eventsOnly = false
  var monthRowMotion: MonthCalendarRowMotion? = nil
  var zoomEndpoint: CalendarZoomEndpoint? = nil

  static func == (lhs: Self, rhs: Self) -> Bool {
    let sameViewport = lhs.viewport.renderRevision != 0 || rhs.viewport.renderRevision != 0
      ? lhs.viewport.renderRevision == rhs.viewport.renderRevision : lhs.viewport == rhs.viewport
    return sameViewport && lhs.calendar == rhs.calendar
      && lhs.hidesFocusDates == rhs.hidesFocusDates && lhs.focusRowIndex == rhs.focusRowIndex
      && lhs.hiddenEventRowIndex == rhs.hiddenEventRowIndex && lhs.hidesAllEvents == rhs.hidesAllEvents
      && lhs.eventsOnly == rhs.eventsOnly && lhs.monthRowMotion == rhs.monthRowMotion
      && lhs.zoomEndpoint == rhs.zoomEndpoint
  }

  var body: some View {
    content
      .calendarZoomGeometry(.canvas, endpoint: zoomEndpoint)
  }

  @ViewBuilder
  private var content: some View {
    switch viewport.displayMode {
      case .week:
        WeekGridView(
          layout: viewport.weekLayout,
          calendar: calendar,
          onSelectEvent: onSelectEvent,
          onDismissDetail: onDismissDetail,
          renderRevision: viewport.renderRevision,
          hidesHeaderDates: hidesFocusDates,
          hidesEvents: hidesAllEvents,
          eventsOnly: eventsOnly,
          zoomEndpoint: zoomEndpoint
        )
        .equatable()
      case .month:
        MonthCalendarGrid(
          layout: viewport.monthLayout,
          calendar: calendar,
          onSelectEvent: onSelectEvent,
          onSelectDay: onSelectDay,
          renderRevision: viewport.renderRevision,
          hiddenDateRowIndex: hidesFocusDates ? focusRowIndex : nil,
          hiddenEventRowIndex: hiddenEventRowIndex,
          hidesAllEvents: hidesAllEvents,
          eventsOnly: eventsOnly,
          rowMotion: monthRowMotion,
          zoomEndpoint: zoomEndpoint
        )
        .equatable()
    }
  }
}

struct PermissionOverlay: View {
  let authorization: CalendarAuthorizationState
  let onRequestAccess: () -> Void
  let onOpenSettings: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "calendar.badge.exclamationmark")
        .font(.system(size: 30, weight: .medium))
        .foregroundStyle(.secondary)
      Text(authorization == .notDetermined ? "允许访问系统日历" : "无法访问系统日历")
        .font(.system(size: 15, weight: .semibold))
      Text("日历权限仅用于读取和展示日历，不会修改任何事项。")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)

      if authorization == .notDetermined {
        AdaptiveGlassButton(isProminent: true, action: onRequestAccess) { Text("允许访问") }
      } else if authorization == .requesting {
        ProgressView().controlSize(.small)
      } else {
        AdaptiveGlassButton(action: onOpenSettings) { Text("打开系统设置") }
      }
    }
    .padding(28)
    .panelSurface(cornerRadius: 16)
  }
}

struct EmptyOverlay: View {
  let icon: String
  let title: String
  let detail: String
  let action: (() -> Void)?

  init(icon: String, title: String, detail: String, action: (() -> Void)?) {
    self.icon = icon
    self.title = title
    self.detail = detail
    self.action = action
  }

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 27))
        .foregroundStyle(.tertiary)
      Text(title)
        .font(.system(size: 14, weight: .semibold))
      Text(detail)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      if let action {
        AdaptiveGlassButton(action: action) { Text("打开设置") }
          .controlSize(.small)
      }
    }
    .padding(22)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
  }
}
