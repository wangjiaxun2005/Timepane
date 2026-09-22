import SwiftUI

struct CalendarModeSelectionSample: Equatable {
  let travel: CGFloat
  let widthScale: CGFloat
  let heightScale: CGFloat
  /// A fraction of the unscaled thumb width, positive toward the destination.
  let directionalOffset: CGFloat

  static func settled(at travel: CGFloat) -> Self {
    Self(
      travel: travel,
      widthScale: 1,
      heightScale: 1,
      directionalOffset: 0
    )
  }
}

enum CalendarZoomMotionSpec {
  static let recognitionDelta: CGFloat = 0.005
  static let preparationDelta: CGFloat = 0.01
  static let commitDelta: CGFloat = 0.04
  static let transitionDuration = CalendarAnimationClock.zoomDuration
  static let selectorCompletionTime: TimeInterval = 0.28
  static let titleCompletionTime: TimeInterval = 0.24
  static let selectorPlaybackClockEnd = CGFloat(selectorCompletionTime / transitionDuration)

  private static let contentTimeScale = transitionDuration / 0.58
  private static let focusSpring = Spring(duration: 0.46 * contentTimeScale, bounce: 0.20)
  private static let eventSpring = Spring(duration: 0.40 * contentTimeScale, bounce: 0.17)
  private static let headerSpring = Spring(duration: 0.42 * contentTimeScale, bounce: 0.12)
  private static let timeLabelSpring = Spring(duration: 0.38 * contentTimeScale, bounce: 0.08)
  private static let rowSpring = Spring(duration: 0.42 * contentTimeScale, bounce: 0.14)
  private static let selectorSpring = Spring(duration: 0.26, bounce: 0.40)
  private static let titleSpring = Spring(duration: 0.22, bounce: 0.18)

  static var transitionAnimation: Animation {
    // This is deliberately only a clock. Each visual track samples its own
    // spring from elapsed time, so delays remain real milliseconds instead of
    // being compressed by an already-eased master progress.
    .linear(duration: transitionDuration)
  }

  static func eventProgress(_ progress: CGFloat) -> CGFloat {
    eventProgress(progress, order: 0, count: 1)
  }

  static func focusProgress(_ progress: CGFloat) -> CGFloat {
    springProgress(
      progress,
      delay: 0.010 * contentTimeScale,
      spring: focusSpring
    )
  }

  static func eventProgress(
    _ progress: CGFloat,
    order: Int,
    count: Int
  ) -> CGFloat {
    let wave = count <= 1
      ? 0
      : min(1, CGFloat(max(0, order)) / CGFloat(min(7, max(1, count - 1))))
    return springProgress(
      progress,
      delay: (0.030 + TimeInterval(wave) * 0.060) * contentTimeScale,
      spring: eventSpring
    )
  }

  static func headerProgress(_ progress: CGFloat, distanceFromFocus: Int) -> CGFloat {
    springProgress(
      progress,
      delay: (
        0.035 + min(0.050, TimeInterval(max(0, distanceFromFocus)) * 0.010)
      ) * contentTimeScale,
      spring: headerSpring
    )
  }

  static func timeLabelProgress(
    _ progress: CGFloat,
    normalizedDistance: CGFloat
  ) -> CGFloat {
    springProgress(
      progress,
      delay: (
        0.030 + TimeInterval(min(1, max(0, normalizedDistance))) * 0.050
      ) * contentTimeScale,
      spring: timeLabelSpring
    )
  }

  static func timeLabelOpacity(monthness: CGFloat) -> Double {
    let fade = smoothStep((monthness - 0.10) / 0.78)
    return Double(1 - fade)
  }

  static func rowProgress(_ progress: CGFloat, distance: Int) -> CGFloat {
    springProgress(
      progress,
      delay: (
        0.030 + min(0.054, TimeInterval(max(0, distance)) * 0.018)
      ) * contentTimeScale,
      spring: rowSpring
    )
  }

  static func selectorProgress(_ progress: CGFloat) -> CGFloat {
    selectorSample(progress).travel
  }

  static func selectorPlaybackSample(_ playbackProgress: CGFloat) -> CalendarModeSelectionSample {
    selectorSample(
      min(1, max(0, playbackProgress)) * selectorPlaybackClockEnd
    )
  }

  static func selectorSample(_ progress: CGFloat) -> CalendarModeSelectionSample {
    let bounded = min(1, max(0, progress))
    let elapsed = TimeInterval(bounded) * transitionDuration
    guard elapsed > 0 else { return .settled(at: 0) }
    guard elapsed < selectorCompletionTime else { return .settled(at: 1) }

    let phase = CGFloat(elapsed / selectorCompletionTime)
    let travel = shortSpringProgress(
      progress,
      spring: selectorSpring,
      completionTime: selectorCompletionTime
    )

    // Use broad, overlapping envelopes instead of sampling instantaneous spring
    // velocity. The latter concentrated almost all deformation into a few frames
    // and made the selector feel abrupt even though its positional spring bounced.
    let bloom = smoothPulse(phase, start: 0, peak: 0.34, end: 0.72)
    let launchStretch = smoothPulse(phase, start: 0, peak: 0.12, end: 0.32)
    let directionalStretch = smoothPulse(phase, start: 0.10, peak: 0.46, end: 0.78)
    let arrivalSquash = smoothPulse(phase, start: 0.54, peak: 0.74, end: 0.93)
    let shapeRebound = smoothPulse(phase, start: 0.78, peak: 0.88, end: 1)

    // The solid thumb visibly blooms, stretches in the direction of travel,
    // compresses on contact, then returns through one restrained shape rebound.
    let widthScale =
      1 + 0.14 * bloom + 0.09 * launchStretch + 0.25 * directionalStretch
        - 0.10 * arrivalSquash + 0.055 * shapeRebound
    let heightScale =
      1 + 0.28 * bloom - 0.035 * launchStretch - 0.08 * directionalStretch
        + 0.18 * arrivalSquash - 0.045 * shapeRebound

    return CalendarModeSelectionSample(
      travel: travel,
      widthScale: widthScale,
      heightScale: heightScale,
      directionalOffset: 0.045 * launchStretch
    )
  }

  static func titleProgress(_ progress: CGFloat) -> CGFloat {
    shortSpringProgress(
      progress,
      spring: titleSpring,
      completionTime: titleCompletionTime
    )
  }

  static func eventTextTransferProgress(_ progress: CGFloat) -> CGFloat {
    smoothStep((min(1, max(0, progress)) - 0.28) / 0.44)
  }

  private static func springProgress(
    _ progress: CGFloat,
    delay: TimeInterval,
    spring: Spring,
    settleStart: CGFloat = 0.86
  ) -> CGFloat {
    let bounded = min(1, max(0, progress))
    let animationEnd = 1 - CalendarZoomEndpointTransfer.handoffFraction
    if bounded >= animationEnd { return 1 }

    let elapsed = TimeInterval(bounded) * transitionDuration - delay
    guard elapsed > 0 else { return 0 }

    let sampled: Double = spring.value(
      target: 1,
      initialVelocity: 0,
      time: elapsed
    )
    let settlement = smoothStep(
      (bounded - settleStart) / max(0.001, animationEnd - settleStart)
    )
    return CGFloat(sampled) + (1 - CGFloat(sampled)) * settlement
  }

  private static func shortSpringProgress(
    _ progress: CGFloat,
    spring: Spring,
    completionTime: TimeInterval
  ) -> CGFloat {
    let bounded = min(1, max(0, progress))
    let elapsed = TimeInterval(bounded) * transitionDuration
    guard elapsed > 0 else { return 0 }
    guard elapsed < completionTime else { return 1 }

    let sampled: Double = spring.value(
      target: 1,
      initialVelocity: 0,
      time: elapsed
    )
    let settleStart = completionTime * 0.72
    let settlement = smoothStep(
      CGFloat((elapsed - settleStart) / max(0.001, completionTime - settleStart))
    )
    return CGFloat(sampled) + (1 - CGFloat(sampled)) * settlement
  }

  static func smoothStep(_ value: CGFloat) -> CGFloat {
    let value = min(1, max(0, value))
    return value * value * (3 - 2 * value)
  }

  private static func smoothPulse(
    _ value: CGFloat,
    start: CGFloat,
    peak: CGFloat,
    end: CGFloat
  ) -> CGFloat {
    guard value > start, value < end else { return 0 }
    if value <= peak {
      return smoothStep((value - start) / max(0.001, peak - start))
    }
    return 1 - smoothStep((value - peak) / max(0.001, end - peak))
  }
}

enum CalendarZoomEndpointTransfer {
  static let handoffFraction: CGFloat = 0.06

  static func sourceBandProgress(_ progress: CGFloat) -> CGFloat {
    CalendarZoomMotionSpec.smoothStep(clamp(progress) / handoffFraction)
  }

  static func targetBandProgress(_ progress: CGFloat) -> CGFloat {
    CalendarZoomMotionSpec.smoothStep(
      (clamp(progress) - (1 - handoffFraction)) / handoffFraction
    )
  }

  private static func clamp(_ value: CGFloat) -> CGFloat {
    min(1, max(0, value))
  }
}
