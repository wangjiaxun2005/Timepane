import Foundation
import OSLog

enum CalendarAnimationClock {
  static let zoomDuration: TimeInterval = 0.50
  static let periodDuration: TimeInterval = 0.48
  static let detailSwitchDuration: TimeInterval = 0.34
}

enum CalendarAnimationTraceKind: String {
  case calendarZoom
  case periodNavigation
  case panelExpansion
  case panelCollapse
}

struct CalendarAnimationTraceToken {
  let kind: CalendarAnimationTraceKind
  let generation: Int
  fileprivate let signpostID: OSSignpostID
  fileprivate let intervalState: OSSignpostIntervalState
}

enum CalendarAnimationTrace {
  private static let signposter = OSSignposter(
    subsystem: "com.wangjiaxun.DynamicCalendar",
    category: "Animation"
  )

  static func begin(
    _ kind: CalendarAnimationTraceKind,
    generation: Int
  ) -> CalendarAnimationTraceToken {
    let signpostID = signposter.makeSignpostID()
    let state = signposter.beginInterval(
      "CalendarAnimation",
      id: signpostID,
      "kind=\(kind.rawValue, privacy: .public) generation=\(generation)"
    )
    return CalendarAnimationTraceToken(
      kind: kind,
      generation: generation,
      signpostID: signpostID,
      intervalState: state
    )
  }

  static func phase(_ name: StaticString, token: CalendarAnimationTraceToken?) {
    guard let token else { return }
    signposter.emitEvent(
      name,
      id: token.signpostID,
      "kind=\(token.kind.rawValue, privacy: .public) generation=\(token.generation)"
    )
  }

  static func end(
    _ token: CalendarAnimationTraceToken?,
    outcome: String = "completed"
  ) {
    guard let token else { return }
    signposter.endInterval(
      "CalendarAnimation",
      token.intervalState,
      "kind=\(token.kind.rawValue, privacy: .public) generation=\(token.generation) outcome=\(outcome, privacy: .public)"
    )
  }
}
