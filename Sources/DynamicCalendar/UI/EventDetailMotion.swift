import SwiftUI

enum EventDetailMotionTiming {
  static let restingCornerRadius: CGFloat = 18
  static let presentationTravelDuration: TimeInterval = 0.31
  // Keep one installation frame so the inserted drawer exists before its
  // independent impact animation begins, then build deformation for the
  // entire upward travel and peak exactly as the drawer reaches its endpoint.
  static let impactLeadIn: TimeInterval = 0.008
  static let impactBuildDuration = presentationTravelDuration - impactLeadIn
  static let impactRecoveryDuration: TimeInterval = 0.30
  static let presentationDuration = impactLeadIn + impactBuildDuration + impactRecoveryDuration
  static let dismissalDuration: TimeInterval = 0.3
  static let switchDuration = CalendarAnimationClock.detailSwitchDuration

  static func presentationAnimation(reduceMotion: Bool) -> Animation {
    if reduceMotion { return .easeOut(duration: 0.1) }
    return .timingCurve(
      0.17,
      0.82,
      0.22,
      1,
      duration: presentationTravelDuration
    )
  }

  static var impactBuildAnimation: Animation {
    .timingCurve(0.18, 0.12, 0.34, 1, duration: impactBuildDuration)
  }

  static var impactRecoveryAnimation: Animation {
    .interpolatingSpring(
      duration: impactRecoveryDuration,
      bounce: 0.31,
      initialVelocity: 0.64
    )
  }

  static func dismissalAnimation(reduceMotion: Bool) -> Animation {
    if reduceMotion { return .easeOut(duration: 0.1) }
    return .timingCurve(0.4, 0, 0.2, 1, duration: dismissalDuration)
  }

  static func backgroundAnimation(reduceMotion: Bool) -> Animation {
    reduceMotion ? .easeOut(duration: 0.1) : .easeInOut(duration: 0.24)
  }

  static func switchAnimation(reduceMotion: Bool) -> Animation {
    if reduceMotion { return .easeOut(duration: 0.1) }
    return .interpolatingSpring(
      duration: switchDuration,
      bounce: 0.26,
      initialVelocity: 0.28
    )
  }

  static func drawerTransition(reduceMotion: Bool) -> AnyTransition {
    if reduceMotion { return .opacity }
    return .asymmetric(
      insertion: .move(edge: .bottom),
      removal: .move(edge: .bottom)
        .combined(
          with: .modifier(
            active: EventDetailDrawerMotionModifier(
              progress: 0,
              initialXScale: 0.991,
              initialYScale: 1.0125,
              initialCornerRadius: 19,
              restingOffset: 3
            ),
            identity: EventDetailDrawerMotionModifier(progress: 1)
          )
        )
      )
  }

  static func cardSwitchTransition(
    direction: EventDetailSwitchDirection,
    reduceMotion: Bool
  ) -> AnyTransition {
    guard !reduceMotion else { return .identity }
    return .asymmetric(
      insertion: .move(edge: direction.insertionEdge)
        .combined(
          with: .modifier(
            active: EventDetailHorizontalStretchModifier(progress: 0),
            identity: EventDetailHorizontalStretchModifier(progress: 1)
          )
        ),
      removal: .move(edge: direction.removalEdge)
        .combined(
          with: .modifier(
            active: EventDetailHorizontalStretchModifier(progress: 0),
            identity: EventDetailHorizontalStretchModifier(progress: 1)
          )
        )
    )
  }
}

struct EventDetailImpactGeometry: Equatable {
  let xScale: CGFloat
  let yScale: CGFloat
  let cornerRadius: CGFloat

  static func resolve(impulse: CGFloat) -> Self {
    let impulse = min(max(impulse, -0.24), 1.06)
    // Keep the original elastic timing with half the visible strain.
    let stretch = max(impulse, 0)
    let rebound = max(-impulse, 0)
    return Self(
      xScale: 1 - 0.02 * stretch + 0.005 * rebound,
      yScale: 1 + 0.04 * stretch - 0.01 * rebound,
      cornerRadius: EventDetailMotionTiming.restingCornerRadius
        + 2.5 * stretch
        - 0.75 * rebound
    )
  }
}

struct EventDetailImpactMotionModifier: AnimatableModifier {
  var impulse: CGFloat

  var animatableData: CGFloat {
    get { impulse }
    set { impulse = newValue }
  }

  func body(content: Content) -> some View {
    let geometry = EventDetailImpactGeometry.resolve(impulse: impulse)
    content
      .environment(\.eventDetailCornerRadius, geometry.cornerRadius)
      .scaleEffect(
        x: geometry.xScale,
        y: geometry.yScale,
        anchor: .bottom
      )
  }
}

private struct EventDetailDrawerMotionModifier: AnimatableModifier {
  var progress: CGFloat
  var initialXScale: CGFloat = 1
  var initialYScale: CGFloat = 1
  var initialCornerRadius = EventDetailMotionTiming.restingCornerRadius
  var restingOffset: CGFloat = 0

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func body(content: Content) -> some View {
    // Preserve a small spring overshoot instead of clamping at the resting frame.
    let progress = min(max(progress, 0), 1.14)
    let cornerRadius = initialCornerRadius
      + (EventDetailMotionTiming.restingCornerRadius - initialCornerRadius) * progress
    content
      .environment(\.eventDetailCornerRadius, cornerRadius)
      .scaleEffect(
        x: initialXScale + (1 - initialXScale) * progress,
        y: initialYScale + (1 - initialYScale) * progress,
        anchor: .bottom
      )
      .offset(y: restingOffset * (1 - progress))
  }
}

private struct EventDetailHorizontalStretchModifier: AnimatableModifier {
  var progress: CGFloat

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func body(content: Content) -> some View {
    let unitProgress = min(max(progress, 0), 1)
    let pulse = CGFloat(sin(Double.pi * Double(unitProgress)))
    content
      .environment(
        \.eventDetailCornerRadius,
        EventDetailMotionTiming.restingCornerRadius + 2.5 * pulse
      )
      .scaleEffect(
        x: 1 + 0.04 * pulse,
        y: 1 - 0.02 * pulse,
        anchor: .center
      )
  }
}

private struct EventDetailCornerRadiusKey: EnvironmentKey {
  static let defaultValue = EventDetailMotionTiming.restingCornerRadius
}

extension EnvironmentValues {
  var eventDetailCornerRadius: CGFloat {
    get { self[EventDetailCornerRadiusKey.self] }
    set { self[EventDetailCornerRadiusKey.self] = newValue }
  }
}
