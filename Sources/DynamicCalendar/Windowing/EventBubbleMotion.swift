import AppKit
import SwiftUI

/// One reversible playhead overlaps growth, neck separation, travel and content recovery.
/// The form keeps its final layout; only its composited layer follows the surface.
struct EventBubblePose {
  var body: CGRect
  var radius: CGFloat
  var neckWidth: CGFloat
  var showsDonor: Bool
  var contentOpacity: Double
  var surfaceOpacity: Double
  var contentScale: CGFloat = 1
  var contentBlur: CGFloat = 0
  var donor: CGRect = .zero
  var proximity: CGFloat = 26
  var editorRimInset: CGFloat = 0
  var growth: Double = 0
  var toolbar: EventToolbarPose?
}

/// Toolbar geometry is derived from the complete scene channels.
/// Coordinates remain relative to the original three-command capsule.
struct EventToolbarPose {
  var cancel: CGRect
  var save: CGRect
  var remainder: CGRect
  var mother: CGRect
  var layoutOffset: CGFloat
  var rotation: Double
  var blue: Double
  var checkOpacity: Double
  var softness: Double
  var proximity: CGFloat

  var bounded: Self {
    var result = self
    func rect(_ r: CGRect) -> CGRect {
      let w = max(0.01, r.width), h = max(0.01, r.height)
      return CGRect(x: r.origin.x + (r.width - w) / 2, y: r.origin.y + (r.height - h) / 2, width: w, height: h)
    }
    result.cancel = rect(cancel); result.save = rect(save); result.remainder = rect(remainder); result.mother = rect(mother)
    result.blue = min(1, max(0, blue)); result.checkOpacity = min(1, max(0, checkOpacity))
    result.softness = min(1, max(0, softness)); result.proximity = max(0, proximity)
    return result
  }

  var clipPath: CGPath {
    let row = cancel.union(save).union(remainder)
    return CGPath(roundedRect: row, cornerWidth: row.height / 2,
                  cornerHeight: row.height / 2, transform: nil)
  }

  func trailingCenter(_ x: CGFloat, source: CGRect) -> CGPoint {
    let sx = mother.width / source.width
    // Remainder's right edge is the same shared transform at opening and the
    // receiver's center during closing. Both converge to the exact idle anchors.
    return CGPoint(x: remainder.maxX - (source.maxX - x) * sx, y: remainder.midY)
  }

  static func pressed(source: CGRect, amount: CGFloat) -> Self {
    var pose = EventToolbarMotion.pose(fraction: 0, closing: false, source: source)
    let sx = 1 + 0.035 * amount, sy = 1 + 0.045 * amount
    func transform(_ r: CGRect) -> CGRect {
      CGRect(x: source.midX + (r.minX - source.midX) * sx,
             y: source.midY + (r.minY - source.midY) * sy,
             width: r.width * sx, height: r.height * sy)
    }
    pose.mother = transform(pose.mother)
    pose.remainder = transform(pose.remainder)
    pose.cancel = transform(pose.cancel)
    pose.save = transform(pose.save)
    return pose
  }

  /// Component-wise arithmetic also carries presentation velocity on reversal.
  static func combine(_ a: Self, _ b: Self, _ f: (Double, Double) -> Double) -> Self {
    func rect(_ x: CGRect, _ y: CGRect) -> CGRect {
      CGRect(x: f(x.origin.x, y.origin.x), y: f(x.origin.y, y.origin.y),
             width: f(x.width, y.width), height: f(x.height, y.height))
    }
    return Self(cancel: rect(a.cancel, b.cancel), save: rect(a.save, b.save),
      remainder: rect(a.remainder, b.remainder), mother: rect(a.mother, b.mother),
      layoutOffset: f(a.layoutOffset, b.layoutOffset), rotation: f(a.rotation, b.rotation),
      blue: f(a.blue, b.blue), checkOpacity: f(a.checkOpacity, b.checkOpacity),
      softness: f(a.softness, b.softness), proximity: f(a.proximity, b.proximity))
  }
}

/// A single set of scene channels describes every connected and detached part.
/// Growth does not restart an easing function at the moment the neck separates.
struct EventFissionChannels {
  var spread: Double
  var width: Double
  var height: Double
  var growth: Double
  var travel: Double
  var content: Double = 0
  var rotation: Double = 0
  // Recoil is measured in layout points, independent of the short separation gap.
  // The three offsets form one right-to-left return wave: save, cancel, mode picker.
  var buttonOverrun: Double = 0
  var saveOverrun: Double = 0
  var modeOverrun: Double = 0
  var editorOverrun: Double = 0
  var receiverOffset: Double = 0

  static func combine(_ a: Self, _ b: Self, _ f: (Double, Double) -> Double) -> Self {
    Self(spread: f(a.spread, b.spread), width: f(a.width, b.width),
      height: f(a.height, b.height), growth: f(a.growth, b.growth), travel: f(a.travel, b.travel),
      content: f(a.content, b.content), rotation: f(a.rotation, b.rotation),
      buttonOverrun: f(a.buttonOverrun, b.buttonOverrun),
      saveOverrun: f(a.saveOverrun, b.saveOverrun),
      modeOverrun: f(a.modeOverrun, b.modeOverrun),
      editorOverrun: f(a.editorOverrun, b.editorOverrun),
      receiverOffset: f(a.receiverOffset, b.receiverOffset))
  }
  static let closed = Self(spread: 0, width: 1, height: 1, growth: 0, travel: 0)
  static let open = Self(spread: 1, width: 1, height: 1, growth: 1, travel: 1, content: 1, rotation: 1)
  static let zero = Self(spread: 0, width: 0, height: 0, growth: 0, travel: 0)
  var bounded: Self {
    Self(spread: min(1.08, max(0, spread)), width: min(1.4, max(0.85, width)),
      height: min(1.4, max(0.85, height)), growth: min(1, max(0, growth)),
      travel: min(1.08, max(0, travel)), content: min(1, max(0, content)),
      rotation: min(1.04, max(0, rotation)),
      buttonOverrun: min(8, max(-3, buttonOverrun)),
      saveOverrun: min(8, max(-3, saveOverrun)),
      modeOverrun: min(8, max(-3, modeOverrun)),
      editorOverrun: min(20, max(-8, editorOverrun)),
      receiverOffset: min(3, max(-6, receiverOffset)))
  }
}

enum EventFissionMotion {
  static let fusionDistance: CGFloat = 6
  /// Times are seconds, independent for each action. All tracks are sampled
  /// from the same display-link time; no delayed callbacks or extra animators.
  private struct Track {
    let keys: [(time: Double, value: Double)]
    let slopes: [Double]
    let softLanding: Bool

    init(_ keys: [(Double, Double)], softLanding: Bool = false) {
      self.keys = keys
      self.softLanding = softLanding
      var slopes = Array(repeating: 0.0, count: keys.count)
      for i in 1..<(keys.count - 1) {
        let a = (keys[i].1 - keys[i - 1].1) / (keys[i].0 - keys[i - 1].0)
        let b = (keys[i + 1].1 - keys[i].1) / (keys[i + 1].0 - keys[i].0)
        // Same-sign harmonic tangents preserve a monotonic segment without
        // introducing a stop at every independently authored speed change.
        slopes[i] = a * b > 0 ? 2 * a * b / (a + b) : 0
      }
      self.slopes = slopes
    }

    func value(at time: Double) -> Double {
      guard time > keys[0].time else { return keys[0].value }
      guard let j = keys.firstIndex(where: { $0.time > time }) else { return keys.last!.value }
      let i = j - 1, h = keys[j].time - keys[i].time
      let u = (time - keys[i].time) / h, u2 = u * u, u3 = u2 * u
      if softLanding && j == keys.count - 1 {
        // Turn once at the peak, then spend most of the return slowing down.
        // The tail reaches the endpoint with zero speed and acceleration.
        let rest = 1 - u
        return keys[j].value + (keys[i].value - keys[j].value) * rest * rest * rest * (1 + 3 * u)
      }
      return (2*u3 - 3*u2 + 1) * keys[i].value + (-2*u3 + 3*u2) * keys[j].value
        + (u3 - 2*u2 + u) * h * slopes[i] + (u3 - u2) * h * slopes[j]
    }
  }

  private struct Sequence {
    let duration: Double
    let load: Track
    let spread: Track
    let growth: Track
    let travel: Track
    let content: Track
    let rotation: Track
    let buttonOverrun: Track
    let saveOverrun: Track
    let modeOverrun: Track
    let editorOverrun: Track
    let receiverOffset: Track

    func sample(at time: Double) -> EventFissionChannels {
      let pressure = load.value(at: time)
      return EventFissionChannels(spread: spread.value(at: time),
        width: 1 + 0.16 * pressure, height: 1 + 0.22 * pressure,
        growth: growth.value(at: time), travel: travel.value(at: time),
        content: content.value(at: time), rotation: rotation.value(at: time),
        buttonOverrun: buttonOverrun.value(at: time),
        saveOverrun: saveOverrun.value(at: time),
        modeOverrun: modeOverrun.value(at: time),
        editorOverrun: editorOverrun.value(at: time),
        receiverOffset: receiverOffset.value(at: time))
    }
  }

  // A short load precedes a fast release. At full body size, actual point
  // offsets carry the leaves/window beyond their destinations, then reverse.
  private static let opening = Sequence(
    duration: 0.58,
    load: Track([(0, 0), (0.06, 0.45), (0.12, 1), (0.20, 0.60),
                 (0.26, 0.15), (0.30, 0)]),
    spread: Track([(0, 0), (0.04, 0.02), (0.12, 0.22), (0.22, 0.85), (0.30, 1)]),
    growth: Track([(0, 0), (0.035, 0), (0.10, 0.08), (0.14, 0.24),
                   (0.24, 0.86), (0.32, 1)]),
    travel: Track([(0, 0), (0.08, 0), (0.14, 0.16), (0.23, 0.80), (0.30, 1)]),
    content: Track([(0, 0), (0.07, 0), (0.14, 0.30), (0.23, 0.90), (0.28, 1)]),
    rotation: Track([(0, 0), (0.06, 0.02), (0.14, 0.24), (0.28, 0.97),
                     (0.35, 1.015), (0.50, 1)]),
    buttonOverrun: Track([(0, 0), (0.20, 0), (0.26, 2.5), (0.35, 5),
                          (0.42, 5.0 / 3), (0.50, 0)]),
    saveOverrun: Track([(0, 0), (0.20, 0), (0.26, 2.5), (0.31, 5),
                        (0.38, 5.0 / 3), (0.46, 0), (0.54, 0)]),
    modeOverrun: Track([(0, 0), (0.20, 0), (0.30, 2.5), (0.39, 5),
                        (0.46, 5.0 / 3), (0.54, 0)]),
    editorOverrun: Track([(0, 0), (0.20, 0), (0.26, 6), (0.35, 12),
                          (0.58, 0)], softLanding: true),
    receiverOffset: Track([(0, 0), (0.54, 0)])
  )

  // One absorption pulse carries the closing recoil. Centers do not inherit
  // that pulse or a second vertical spring, so stronger shape stays coherent.
  private static let closing = Sequence(
    duration: 0.38,
    load: Track([(0, 0), (0.10, 0), (0.18, 0.55), (0.23, 1),
                 (0.31, 0.40), (0.38, 0)]),
    spread: Track([(0, 1), (0.05, 0.985), (0.12, 0.78), (0.20, 0.15), (0.25, 0)]),
    growth: Track([(0, 1), (0.04, 0.98), (0.12, 0.70), (0.20, 0.12), (0.25, 0)]),
    travel: Track([(0, 1), (0.04, 0.97), (0.12, 0.50), (0.20, 0)]),
    content: Track([(0, 1), (0.05, 0.98), (0.14, 0.65), (0.22, 0)]),
    rotation: Track([(0, 1), (0.05, 0.98), (0.14, 0.55), (0.25, 0)]),
    buttonOverrun: Track([(0, 0), (0.38, 0)]),
    saveOverrun: Track([(0, 0), (0.38, 0)]),
    modeOverrun: Track([(0, 0), (0.38, 0)]),
    editorOverrun: Track([(0, 0), (0.38, 0)]),
    receiverOffset: Track([(0, 0), (0.38, 0)])
  )

  static var openingDuration: Double { opening.duration }
  static var closingDuration: Double { closing.duration }

  static func channels(at fraction: Double, closing isClosing: Bool) -> EventFissionChannels {
    let sequence = isClosing ? closing : opening
    return sequence.sample(at: min(1, max(0, fraction)) * sequence.duration)
  }

  static func toolbar(_ channels: EventFissionChannels, source: CGRect) -> EventToolbarPose {
    let c = channels.bounded
    let spread = c.spread, cut = 29 * min(1, spread)
    let mother = CGRect(x: source.midX - source.width * c.width / 2,
      y: source.midY - source.height * c.height / 2 + c.receiverOffset,
      width: source.width * c.width, height: source.height * c.height)
    let receiver = CGRect(x: mother.minX + cut * c.width, y: mother.minY,
      width: mother.width - cut * c.width, height: mother.height)
    let attached = 1 - EventBubbleMotion.smooth((spread - 0.55) / 0.45)
    func leaf(x: Double, size: Double, scalesPosition: Bool = true) -> CGRect {
      // Both leaves release the same pressure without sequential axis pulses.
      let sx = 1 + (c.width - 1) * attached
      let w = max(0.01, size * sx)
      let h = w
      let positionScale = scalesPosition ? sx : 1
      return CGRect(x: source.midX + (source.minX + x - source.midX) * positionScale - w / 2,
        y: source.midY - h / 2 + c.receiverOffset, width: w, height: h)
    }
    let cancel = leaf(x: 17 - 52 * spread, size: 32, scalesPosition: false)
      .offsetBy(dx: -c.buttonOverrun, dy: 0)
    // Save emerges inside the capsule. Loading shapes it without moving its
    // center: capsule recovery would otherwise reverse its short travel twice
    // before the intended overrun and single return.
    let save = leaf(x: 17 - 12 * spread, size: 32 * EventBubbleMotion.smooth(spread / 0.20),
      scalesPosition: false)
      .offsetBy(dx: -c.saveOverrun, dy: 0)
    // Pigment follows physical isolation, not a separate timer. Connected
    // surfaces remain optically compatible; the final leaf is still blue.
    let saveGap = min(save.minX - cancel.maxX, receiver.minX - save.maxX)
    let blue = EventBubbleMotion.smooth((saveGap - fusionDistance) / (8 - fusionDistance))
    return EventToolbarPose(cancel: cancel, save: save, remainder: receiver, mother: mother,
      layoutOffset: 51 * spread + c.modeOverrun, rotation: .pi / 4 * c.rotation, blue: blue,
      checkOpacity: EventBubbleMotion.smooth((spread - 0.15) / 0.60),
      softness: 0, proximity: fusionDistance)
  }

  static func pose(_ channels: EventFissionChannels, source: CGRect, destination: CGRect) -> EventBubblePose {
    let c = channels.bounded
    let toolbar = toolbar(c, source: source)
    let donor = toolbar.remainder
    // Height leads width near the source. The silhouette grows from a rounded
    // seed into an oval before resolving into the resting editor rectangle.
    // Reversing growth follows the same contour family without a second lobe.
    let lateralGrowth = pow(EventBubbleMotion.smooth(c.growth), 1.35)
    let width = source.width * 0.70 + (destination.width - source.width * 0.70) * lateralGrowth
    let height = max(0.01, destination.height * c.growth)
    let centerX = source.midX + (destination.midX - source.midX) * lateralGrowth
    // Ease out the embedded depth before reaching 12 pt. A hard min switched
    // the emerging edge's velocity instantly when the body reached that height.
    let embeddedHeight = min(24, height)
    let inset = embeddedHeight * (1 - embeddedHeight / 48)
    let y = donor.maxY - inset + (destination.minY - source.maxY + inset) * c.travel + c.editorOverrun
    let body = CGRect(x: centerX - width / 2, y: y, width: width, height: height)
    let roundRadius = min(width, height) / 2
    let restingRadius = min(22, roundRadius)
    let contourRecovery = EventBubbleMotion.smooth((c.growth - 0.30) / 0.65)
    let radius = roundRadius + (restingRadius - roundRadius) * contourRecovery
    // Blur belongs to visible deformation, not elapsed time. Stable content
    // stays sharp, including either endpoint and Reduced Motion.
    // Keep strong blur while the content is actually visible, then resolve
    // with the same rotation/recovery channel before the final settle.
    let blur = 10 * EventBubbleMotion.smooth(c.content / 0.20)
      * (1 - EventBubbleMotion.smooth((c.rotation - 0.50) / 0.50))
    return EventBubblePose(body: body, radius: radius, neckWidth: 0, showsDonor: true,
      contentOpacity: c.content, surfaceOpacity: c.growth > 0 ? 1 : 0,
      // A single continuous content scale avoids the velocity kink when the
      // limiting axis switches during the narrow-to-wide contour transition.
      contentScale: 0.35 + 0.65 * EventBubbleMotion.smooth(c.growth),
      contentBlur: blur,
      donor: donor, proximity: fusionDistance, editorRimInset: 0, growth: c.growth, toolbar: toolbar)
  }
}

/// Full-scene Hermite continuation preserves shared geometry and velocity when
/// reversing. There is no separate toolbar continuation racing editor progress.
struct EventFissionTransition {
  let closing: Bool
  let duration: Double
  let initial: EventFissionChannels
  let initialVelocity: EventFissionChannels
  var correctionDuration: Double?
  var isRetargeting = false
  func channels(at fraction: Double) -> EventFissionChannels {
    let u = min(1, max(0, fraction))
    if isRetargeting { return continuation(at: u * duration) }
    let base = EventFissionMotion.channels(at: u, closing: closing)
    let start = EventFissionMotion.channels(at: 0, closing: closing)
    let delta = EventFissionChannels.combine(initial, start, -)
    let correction = correctionDuration ?? duration
    let v = min(1, u * duration / correction), rest = 1 - v
    let position = EventFissionChannels.combine(base, delta) { $0 + $1 * (1 + 2*v) * rest * rest }
    return .combine(position, initialVelocity) { $0 + $1 * correction * v * rest * rest }
  }
  /// Interrupted motion approaches the new endpoint from the rendered state,
  /// rather than subtracting two complete recipes and clipping their difference.
  private func continuation(at time: Double) -> EventFissionChannels {
    let start = initial.bounded, end = closing ? EventFissionChannels.closed : .open
    func value(_ a: Double, _ v: Double, _ b: Double, _ range: ClosedRange<Double>) -> Double {
      if time >= duration { return b }
      let velocity = (a <= range.lowerBound && v < 0) || (a >= range.upperBound && v > 0) ? 0 : v
      func settle(from: Double, velocity: Double, time: Double, duration: Double) -> Double {
        guard duration > 0, time < duration else { return b }
        let u = max(0, time / duration), rest = 1 - u
        return from * (1 + 2*u) * rest * rest + b * u*u*(3 - 2*u)
          + velocity * duration * u * rest * rest
      }
      let distance = b - a
      if velocity * distance < 0 || (distance == 0 && velocity != 0) {
        // Keep momentum for one bounded braking arc, then reverse exactly once.
        let room = velocity > 0 ? range.upperBound - a : a - range.lowerBound
        let braking = min(duration * 0.2, 1.8 * room / abs(velocity))
        if braking > 0 {
          let stopped = a + velocity * braking / 2
          if time < braking { return a + velocity * (time - time*time / (2*braking)) }
          return settle(from: stopped, velocity: 0, time: time - braking, duration: duration - braking)
        }
      }
      // A cubic whose first control point lies between its endpoints cannot
      // overshoot. A fast incoming channel can settle before the scene clock.
      let travelDuration = velocity * distance > 0 ? min(duration, 3 * abs(distance / velocity)) : duration
      return settle(from: a, velocity: velocity, time: time, duration: travelDuration)
    }
    return EventFissionChannels(
      spread: value(start.spread, initialVelocity.spread, end.spread, 0...1.08),
      width: value(start.width, initialVelocity.width, end.width, 0.85...1.4),
      height: value(start.height, initialVelocity.height, end.height, 0.85...1.4),
      growth: value(start.growth, initialVelocity.growth, end.growth, 0...1),
      travel: value(start.travel, initialVelocity.travel, end.travel, 0...1.08),
      content: value(start.content, initialVelocity.content, end.content, 0...1),
      rotation: value(start.rotation, initialVelocity.rotation, end.rotation, 0...1.04),
      buttonOverrun: value(start.buttonOverrun, initialVelocity.buttonOverrun, end.buttonOverrun, -3...8),
      saveOverrun: value(start.saveOverrun, initialVelocity.saveOverrun, end.saveOverrun, -3...8),
      modeOverrun: value(start.modeOverrun, initialVelocity.modeOverrun, end.modeOverrun, -3...8),
      editorOverrun: value(start.editorOverrun, initialVelocity.editorOverrun, end.editorOverrun, -8...20),
      receiverOffset: value(start.receiverOffset, initialVelocity.receiverOffset, end.receiverOffset, -6...3))
  }

  func velocity(at fraction: Double) -> EventFissionChannels {
    if fraction >= 1 { return .zero }
    let a = max(0, fraction - 0.0001), b = min(1, fraction + 0.0001)
    return .combine(channels(at: b).bounded, channels(at: a).bounded) { ($0 - $1) / ((b - a) * duration) }
  }
}

// Geometry helpers and endpoint adapters are also used by the older-OS renderer.
enum EventToolbarMotion {
  static func pose(fraction: Double, closing: Bool, source: CGRect) -> EventToolbarPose {
    EventFissionMotion.toolbar(EventFissionMotion.channels(at: fraction, closing: closing), source: source)
  }
}

enum EventBubbleMotion {
  static let separation = 0.48
  static let pressedScale = CGSize(width: 1.045, height: 1.045)
  static func duration(closing: Bool, reduceMotion: Bool) -> Double {
    reduceMotion ? 0.1 : (closing ? EventFissionMotion.closingDuration : EventFissionMotion.openingDuration)
  }
  static func smooth(_ value: Double) -> Double {
    let t = min(1, max(0, value))
    return t * t * t * (t * (t * 6 - 15) + 10)
  }
  static func bodyPath(_ pose: EventBubblePose, inset: CGFloat = 0) -> CGPath {
    CGPath(roundedRect: pose.body.insetBy(dx: inset, dy: inset),
      cornerWidth: max(0, pose.radius - inset), cornerHeight: max(0, pose.radius - inset), transform: nil)
  }
  static func matchesSource(_ lhs: CGRect, _ rhs: CGRect, backingScale: CGFloat) -> Bool {
    let tolerance = 1 / max(1, backingScale)
    return abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance
      && abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
  }
  static func contentFrame(pose: EventBubblePose, destination: CGRect) -> CGRect {
    let size = CGSize(width: destination.width * pose.contentScale, height: destination.height * pose.contentScale)
    return CGRect(x: pose.body.maxX - size.width, y: pose.body.midY - size.height / 2, width: size.width, height: size.height)
  }
  static func contentMask(pose: EventBubblePose, destination: CGRect) -> CGPath {
    let frame = contentFrame(pose: pose, destination: destination)
    let scale = max(0.001, pose.contentScale)
    let body = CGRect(x: (pose.body.minX - frame.minX) / scale, y: (pose.body.minY - frame.minY) / scale,
      width: pose.body.width / scale, height: pose.body.height / scale)
    return CGPath(roundedRect: body, cornerWidth: pose.radius / scale, cornerHeight: pose.radius / scale, transform: nil)
  }
  static func path(pose: EventBubblePose, source: CGRect) -> CGPath {
    let body = bodyPath(pose)
    guard pose.showsDonor else { return body }
    return body.union(pose.toolbar?.clipPath ?? CGPath(roundedRect: pose.donor,
      cornerWidth: pose.donor.height / 2, cornerHeight: pose.donor.height / 2, transform: nil))
  }
}

/// Presentation time must not skip the visible loading/absorption stages after
/// a late compositor callback. Keep one clock for every deformation channel.
struct EventFissionPresentationClock {
  private var previous: Double?
  private(set) var elapsed = 0.0

  mutating func advance(to timestamp: Double) -> Double {
    if let previous {
      elapsed += min(1.0 / 30, max(0, timestamp - previous))
    }
    previous = max(previous ?? timestamp, timestamp)
    return elapsed
  }
}
