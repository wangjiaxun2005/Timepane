import SwiftUI

/// An immutable, sampleable trajectory. Retargeting never reads a model value
/// that SwiftUI has already advanced to the destination.
struct CalendarMotionSample: Equatable {
  let value: CGFloat
  let velocity: CGFloat
}

struct CalendarMotionTrack: Equatable {
  enum Curve: Equatable {
    case linear
    case page
    case pageEvents
    case zoomTitle
    case continuation
    case spring(bounce: Double)
  }

  let startTime: TimeInterval
  let duration: TimeInterval
  let source: CGFloat
  let target: CGFloat
  let initialVelocity: CGFloat
  let curve: Curve

  static func constant(_ value: CGFloat) -> Self {
    Self(startTime: 0, duration: 0, source: value, target: value,
         initialVelocity: 0, curve: .linear)
  }

  var endTime: TimeInterval { startTime + duration }

  func value(at time: TimeInterval) -> CGFloat {
    guard duration > 0 else { return target }
    let elapsed = time - startTime
    guard elapsed > 0 else { return source }
    guard elapsed < duration else { return target }
    let u = CGFloat(elapsed / duration)
    if case .spring(let bounce) = curve {
      return springSample(elapsed: elapsed, bounce: bounce, includingVelocity: false).value
    }
    if curve == .continuation {
      // Hermite continuation preserves both position and velocity at the
      // interruption and settles with zero velocity at the new destination.
      let h00 = 2 * u * u * u - 3 * u * u + 1
      let h10 = u * u * u - 2 * u * u + u
      let h01 = -2 * u * u * u + 3 * u * u
      return h00 * source + h10 * CGFloat(duration) * initialVelocity + h01 * target
    }
    let progress: CGFloat
    switch curve {
    case .linear, .continuation, .spring:
      progress = u
    case .page, .pageEvents:
      let spring = Spring(duration: CalendarAnimationClock.periodDuration, bounce: 0.22)
      let raw = CGFloat(spring.value(target: 1, initialVelocity: 0.35, time: elapsed))
      let travel = curve == .pageEvents ? CalendarPeriodMotionCurve.eventTravel(raw) : raw
      // The native spring still overshoots at the nominal duration. Close only
      // its final tail so handing off to the steady page cannot snap by pixels.
      let tail = min(1, max(0, (u - 0.86) / 0.14))
      let blend = tail * tail * (3 - 2 * tail)
      progress = travel + (1 - travel) * blend
    case .zoomTitle:
      progress = CalendarZoomMotionSpec.titleProgress(CGFloat(elapsed / CalendarAnimationClock.zoomDuration))
    }
    return source + (target - source) * progress
  }

  func sample(at time: TimeInterval) -> CalendarMotionSample {
    guard duration > 0, time < endTime else {
      return CalendarMotionSample(value: target, velocity: 0)
    }
    if case .spring(let bounce) = curve {
      return springSample(elapsed: max(0, time - startTime), bounce: bounce)
    }
    if curve == .continuation {
      let u = CGFloat(min(1, max(0, (time - startTime) / duration)))
      let velocity = ((6 * u * u - 6 * u) * source
        + (3 * u * u - 4 * u + 1) * CGFloat(duration) * initialVelocity
        + (-6 * u * u + 6 * u) * target) / CGFloat(duration)
      return CalendarMotionSample(value: value(at: time), velocity: velocity)
    }
    // Sampling a pure curve is independent of refresh rate and does not retain
    // a frame history. The one-sided derivative also handles frame zero.
    let epsilon = 0.00001
    let a = max(startTime, time - epsilon)
    let b = min(endTime, time + epsilon)
    return CalendarMotionSample(value: value(at: time),
      velocity: b > a ? (value(at: b) - value(at: a)) / CGFloat(b - a) : 0)
  }

  func retarget(to destination: CGFloat, at time: TimeInterval, duration: TimeInterval,
                curve: Curve = .spring(bounce: 0.22)) -> Self {
    let current = sample(at: time)
    return Self(startTime: time, duration: duration, source: current.value,
      target: destination, initialVelocity: current.velocity, curve: curve)
  }

  private func springSample(elapsed: TimeInterval, bounce: Double,
                            includingVelocity: Bool = true) -> CalendarMotionSample {
    guard elapsed > 0 else { return CalendarMotionSample(value: source, velocity: initialVelocity) }
    let spring = Spring(duration: duration, bounce: bounce)
    let value = source + spring.value(target: target - source,
      initialVelocity: initialVelocity, time: elapsed)
    // Preserve the spring's acceleration and rebound. Only close the residual
    // in the final tail, matching the original zoom tracks' endpoint treatment.
    let tailDuration = duration * 0.14
    let tail = CGFloat(max(0, min(1, (elapsed - duration * 0.86) / tailDuration)))
    let blend = tail * tail * (3 - 2 * tail)
    // Rendering reads only position. Keep the exact value formula, and compute
    // the derivative only for callers sampling velocity to interrupt/retarget.
    guard includingVelocity else {
      return CalendarMotionSample(value: value + (target - value) * blend, velocity: 0)
    }
    let velocity = spring.velocity(target: target - source,
      initialVelocity: initialVelocity, time: elapsed)
    let blendVelocity = 6 * tail * (1 - tail) / CGFloat(tailDuration)
    return CalendarMotionSample(value: value + (target - value) * blend,
      velocity: velocity * (1 - blend) + (target - value) * blendVelocity)
  }
}

struct CalendarNavigationTarget: Equatable {
  var mode: CalendarDisplayMode
  var date: Date

  func matches(_ viewport: CalendarViewportState, calendar: Calendar) -> Bool {
    guard mode == viewport.displayMode else { return false }
    let component: Calendar.Component = mode == .week ? .weekOfYear : .month
    return calendar.dateInterval(of: component, for: date)
      == calendar.dateInterval(of: component, for: viewport.focusedDate)
  }

  func moving(by offset: Int, calendar: Calendar) -> Self {
    let component: Calendar.Component = mode == .week ? .weekOfYear : .month
    return Self(mode: mode, date: calendar.date(byAdding: component, value: offset, to: date) ?? date)
  }
}

enum CalendarInteractionIntent {
  case movePeriod(Int)
  case today
  case displayMode(CalendarDisplayMode)
  case week(Date)
}

/// Live rendering recipes, not bitmap snapshots or nested transition trees.
/// Departing layers finish their existing exit rather than being restarted by
/// every subsequent click, bounding their lifetime during sustained input.
struct CalendarMotionLayer: Identifiable {
  let id: Int
  var viewport: CalendarViewportState
  var zoom: CalendarZoomScene?
  var zoomProgress = CalendarMotionTrack.constant(0)
  var chromeX = CalendarMotionTrack.constant(0)
  var eventsX = CalendarMotionTrack.constant(0)
  var needsGeometry = false
  var needsPresentation = false

  var destination: CalendarViewportState {
    guard let zoom else { return viewport }
    if needsGeometry || needsPresentation { return zoom.target }
    return zoomProgress.target == 0 ? zoom.source : zoom.target
  }

  var endTime: TimeInterval {
    max(zoomProgress.endTime, chromeX.endTime, eventsX.endTime)
  }

  func isVisible(at time: TimeInterval) -> Bool {
    abs(chromeX.value(at: time)) < 1.001 || abs(eventsX.value(at: time)) < 1.001
  }
}

struct CalendarTitleLayer: Identifiable {
  let id: Int
  let text: String
  var x = CalendarMotionTrack.constant(0)
  var y = CalendarMotionTrack.constant(0)
}
