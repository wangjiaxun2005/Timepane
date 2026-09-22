import Combine
import Foundation

enum CalendarNavigationDirection: Equatable {
  case stationary
  case backward
  case forward

  init(from currentStart: Date, to targetStart: Date) {
    if targetStart < currentStart {
      self = .backward
    } else if targetStart > currentStart {
      self = .forward
    } else {
      self = .stationary
    }
  }
}

struct CalendarPeriodNavigationRequest: Identifiable, Equatable {
  let id: Int
  let mode: CalendarDisplayMode
  let targetDate: Date
  let interval: DateInterval
  let direction: CalendarNavigationDirection

  func matches(_ viewport: CalendarViewportState) -> Bool {
    viewport.displayMode == mode
      && viewport.focusedDate == targetDate
      && viewport.periodSchedule.startDate == interval.start
      && viewport.periodSchedule.endDate == interval.end
  }
}

enum CalendarPeriodMotionCurve {
  static func eventTravel(_ progress: CGFloat) -> CGFloat {
    if progress < 0 { return -tailTravel(-progress, targetSlope: 0.72) }
    if progress > 1 { return 1 + tailTravel(progress - 1, targetSlope: 1.18) }
    let eased = progress * progress * (3 - 2 * progress)
    return progress + (eased - progress) * 0.42
  }

  private static func tailTravel(_ distance: CGFloat, targetSlope: CGFloat) -> CGFloat {
    // The interior curve arrives with slope 0.58. Integrate a smooth change
    // of slope so crossing the endpoint cannot abruptly double event speed.
    let width: CGFloat = 0.02
    let u = min(1, distance / width)
    let integratedBlend = width * (u * u * u - 0.5 * u * u * u * u)
      + max(0, distance - width)
    return 0.58 * distance + (targetSlope - 0.58) * integratedBlend
  }
}

struct CalendarSwipeTracker {
  private let activationThreshold: CGFloat
  private let gestureResetInterval: TimeInterval
  private let discreteCooldown: TimeInterval

  private var accumulatedHorizontalDelta: CGFloat = 0
  private var didTriggerCurrentGesture = false
  private var lastScrollTimestamp: TimeInterval?
  private var lastDiscreteTimestamp: TimeInterval?

  init(
    activationThreshold: CGFloat = 52,
    gestureResetInterval: TimeInterval = 0.22,
    discreteCooldown: TimeInterval = 0.35
  ) {
    self.activationThreshold = activationThreshold
    self.gestureResetInterval = gestureResetInterval
    self.discreteCooldown = discreteCooldown
  }

  static func isHorizontalGesture(horizontal: CGFloat, vertical: CGFloat) -> Bool {
    abs(horizontal) > abs(vertical) * 1.15 && abs(horizontal) >= 0.5
  }

  static func fingerDelta(fromScrollingDelta delta: CGFloat) -> CGFloat {
    -delta
  }

  mutating func consumeScroll(
    horizontal: CGFloat,
    vertical: CGFloat,
    timestamp: TimeInterval,
    began: Bool,
    hasPhase: Bool = false,
    isMomentum: Bool = false
  ) -> Int? {
    // Momentum belongs to the preceding gesture and must never turn a page.
    if isMomentum {
      lastScrollTimestamp = timestamp
      return nil
    }
    // Native phased gestures end only when a new gesture begins, not when
    // event delivery pauses. Timeout grouping is for phase-less mouse wheels.
    if began || (!hasPhase && shouldResetScroll(at: timestamp)) {
      resetScrollGesture()
    }
    lastScrollTimestamp = timestamp

    guard !didTriggerCurrentGesture,
          Self.isHorizontalGesture(horizontal: horizontal, vertical: vertical) else {
      return nil
    }

    accumulatedHorizontalDelta += horizontal
    guard abs(accumulatedHorizontalDelta) >= activationThreshold else { return nil }

    didTriggerCurrentGesture = true
    return accumulatedHorizontalDelta > 0 ? 1 : -1
  }

  mutating func consumeDiscreteSwipe(
    horizontal: CGFloat,
    timestamp: TimeInterval
  ) -> Int? {
    guard horizontal != 0 else { return nil }
    if didTriggerCurrentGesture, let lastScrollTimestamp,
       timestamp - lastScrollTimestamp < discreteCooldown {
      return nil
    }
    if let lastDiscreteTimestamp,
       timestamp - lastDiscreteTimestamp < discreteCooldown {
      return nil
    }
    lastDiscreteTimestamp = timestamp
    return horizontal > 0 ? 1 : -1
  }

  mutating func reset() {
    resetScrollGesture()
    lastScrollTimestamp = nil
    lastDiscreteTimestamp = nil
  }

  private func shouldResetScroll(at timestamp: TimeInterval) -> Bool {
    guard let lastScrollTimestamp else { return true }
    return timestamp - lastScrollTimestamp > gestureResetInterval
  }

  private mutating func resetScrollGesture() {
    accumulatedHorizontalDelta = 0
    didTriggerCurrentGesture = false
  }
}
