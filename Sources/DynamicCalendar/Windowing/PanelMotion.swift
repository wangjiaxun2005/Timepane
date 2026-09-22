import AppKit
import SwiftUI

enum PanelMotionPhase: Equatable {
    case hidden
    case compact
    case expanding
    case expanded
    case collapsing
    case departing

    var showsExpandedSurface: Bool {
        self == .expanding || self == .expanded
    }

    var showsCompactSurface: Bool {
        self == .compact
    }

    var keepsExpandedContentAlive: Bool {
        self != .hidden
    }

    var isDismissing: Bool {
        self == .collapsing || self == .departing
    }
}

struct PanelMotionCurve: Equatable {
    let controlPoint1X: Float
    let controlPoint1Y: Float
    let controlPoint2X: Float
    let controlPoint2Y: Float

    func progress(at time: TimeInterval) -> CGFloat {
        guard time > 0 else { return 0 }
        guard time < 1 else { return 1 }
        var lower = 0.0, upper = 1.0
        for _ in 0..<24 {
            let t = (lower + upper) / 2, u = 1 - t
            let x = 3*u*u*t*Double(controlPoint1X) + 3*u*t*t*Double(controlPoint2X) + t*t*t
            if x < time { lower = t } else { upper = t }
        }
        let t = (lower + upper) / 2, u = 1 - t
        return CGFloat(3*u*u*t*Double(controlPoint1Y) + 3*u*t*t*Double(controlPoint2Y) + t*t*t)
    }
}

enum PanelMotionTiming {
    static let expansionCompletionDelay: TimeInterval = 0.64
    static let entryTravelDuration: TimeInterval = 0.19
    static let expansionWidthDelay: TimeInterval = 0.045

    static let toolbarRevealTime: TimeInterval = 0.08
    static let gridRevealTime: TimeInterval = 0.12
    static let genericContentRevealDuration: TimeInterval = 0.20
    static let toolbarRevealDuration: TimeInterval = 0.19
    static let gridRevealDuration: TimeInterval = 0.20
    static let contentCollapseDuration: TimeInterval = 0.20

    static let departureDelay = PanelCollapseTrajectory.departureStart
    static let departureDuration = PanelCollapseTrajectory.duration - departureDelay
    static let departureVisibleCompletion = departureDelay + departureDuration

    static let entryCurve = PanelMotionCurve(
        controlPoint1X: 0.16,
        controlPoint1Y: 0.84,
        controlPoint2X: 0.24,
        controlPoint2Y: 1
    )
    static let collapseCurve = PanelMotionCurve(
        controlPoint1X: 0.36,
        controlPoint1Y: 0,
        controlPoint2X: 0.22,
        controlPoint2Y: 1
    )
    // Accelerate through the screen edge without a slow compact-surface tail.
    static let departureCurve = PanelMotionCurve(
        controlPoint1X: 0.30,
        controlPoint1Y: 0,
        controlPoint2X: 0.70,
        controlPoint2Y: 0.65
    )

    // The native shell owns the visible rebound. Keep the large SwiftUI content
    // transforms inside the early reveal window so they do not repaint the
    // calendar during the shell's final settling segment.
    static let genericContentRevealAnimation = Animation.timingCurve(
        0.18, 0, 0.20, 1,
        duration: genericContentRevealDuration
    )
    .delay(toolbarRevealTime - expansionWidthDelay)
    static let toolbarRevealAnimation = Animation.timingCurve(
        0.18, 0, 0.20, 1,
        duration: toolbarRevealDuration
    )
    .delay(toolbarRevealTime - expansionWidthDelay)
    static let gridRevealAnimation = Animation.timingCurve(
        0.18, 0, 0.20, 1,
        duration: gridRevealDuration
    )
    .delay(gridRevealTime - expansionWidthDelay)
    static let contentCollapseAnimation = Animation.timingCurve(
        Double(collapseCurve.controlPoint1X),
        Double(collapseCurve.controlPoint1Y),
        Double(collapseCurve.controlPoint2X),
        Double(collapseCurve.controlPoint2Y),
        duration: contentCollapseDuration
    )
}

@MainActor
final class PanelMotionModel: ObservableObject {
    @Published private(set) var phase: PanelMotionPhase = .hidden
    @Published private(set) var generation = 0
    @Published private(set) var expansionTime: TimeInterval = 0
    @Published private(set) var collapseTime: TimeInterval = 0
    weak var surfaceRenderer: (any PanelSurfaceRendering)?

    func setExpansionTime(_ time: TimeInterval) {
        expansionTime = time
    }

    func setCollapseTime(_ time: TimeInterval) {
        collapseTime = time
    }

    @discardableResult
    func beginTransition(to phase: PanelMotionPhase) -> Int {
        generation &+= 1
        self.phase = phase
        return generation
    }

    @discardableResult
    func transition(to phase: PanelMotionPhase, generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        self.phase = phase
        return true
    }

    func invalidateTransitions() {
        generation &+= 1
    }
}

@MainActor
protocol PanelSurfaceRendering: AnyObject {
    func applySurface(_ pose: PanelSurfacePose)
}

/// A surface lives inside a larger transparent window so its small overshoot
/// can be rendered without changing the calendar's layout or clipping an edge.
struct PanelSurfacePose: Equatable {
    var frame: CGRect
    var cornerRadius: CGFloat
    var tailHeight: CGFloat

    static let canvasInset: CGFloat = 24

    static func expanded(size: CGSize) -> Self {
        Self(frame: CGRect(origin: .zero, size: size), cornerRadius: 22)
    }

    static func compact(size: CGSize, compactSize: CGSize) -> Self {
        Self(frame: CGRect(x: size.width - compactSize.width, y: 0,
                           width: compactSize.width, height: compactSize.height),
             cornerRadius: compactSize.height / 2)
    }

    static func collapsed(size: CGSize, compactSize: CGSize) -> Self {
        let diameter = min(compactSize.width, compactSize.height)
        return .compact(size: size, compactSize: CGSize(width: diameter, height: diameter))
    }

    var components: [CGFloat] {
        [frame.origin.x, frame.origin.y, frame.width, frame.height, cornerRadius, tailHeight]
    }

    var visibleFrame: CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height + tailHeight)
    }

    /// A small, smooth lobe overlaps the capsule's lower edge. Coordinates are
    /// local and top-down; the native mask converts them to its layer space.
    var tailPath: CGPath {
        let path = CGMutablePath()
        let left = frame.width * 0.22
        let right = frame.width * 0.78
        let center = frame.width / 2
        let span = max(0, right - left)
        let shoulder = frame.height - min(8, cornerRadius * 0.25)
        let bottom = frame.height + tailHeight
        path.move(to: CGPoint(x: left, y: shoulder))
        path.addCurve(to: CGPoint(x: center, y: bottom),
                      control1: CGPoint(x: left + span * 0.18, y: shoulder),
                      control2: CGPoint(x: center - span * 0.22, y: bottom))
        path.addCurve(to: CGPoint(x: right, y: shoulder),
                      control1: CGPoint(x: center + span * 0.22, y: bottom),
                      control2: CGPoint(x: right - span * 0.18, y: shoulder))
        path.closeSubpath()
        return path
    }

    init(frame: CGRect, cornerRadius: CGFloat, tailHeight: CGFloat = 0) {
        self.frame = frame
        self.cornerRadius = cornerRadius
        self.tailHeight = max(0, tailHeight)
    }

    init(components: [CGFloat]) {
        frame = CGRect(x: components[0], y: components[1],
                       width: components[2], height: components[3])
        cornerRadius = components[4]
        tailHeight = max(0, components[5])
    }
}

/// The reference's normal opening: compact surface, rounded expansion,
/// readable content before the end, a restrained overshoot, and a quiet tail.
/// Coordinates are normalized to the destination, not to a fixed phone size.
enum PanelExpansionTrajectory {
    static let duration: TimeInterval = 0.64
    // Direct (non-settling) shell growth reaches the destination here.
    static let growthDuration: TimeInterval = 0.38
    static let contentRevealStart: TimeInterval = 0.14
    static let contentRevealEnd: TimeInterval = 0.32
    static let blurRevealEnd: TimeInterval = 0.29
    // Keep the blur filter alive at an optically clear radius while the shell
    // settles. Dropping the radius to exactly zero mid-flight tears down the
    // full-calendar compositing layer and can miss a display callback.
    static let settledBlurFloor: CGFloat = 0.01
    static let settledOpacityCeiling: CGFloat = 0.9999
    static let settledScaleFloor: CGFloat = 1.0001
    static let settledOffsetFloor: CGFloat = 0.01

    private static let times: [TimeInterval] = [0, 0.045, 0.13, 0.21, 0.29, 0.37, 0.46, 0.55, 0.64]

    static func pose(at time: TimeInterval, size: CGSize, compactSize: CGSize,
                     includesSettling: Bool = true) -> PanelSurfacePose {
        if time <= 0 { return .compact(size: size, compactSize: compactSize) }
        if time >= (includesSettling ? duration : growthDuration) { return .expanded(size: size) }
        func interpolate(_ values: [CGFloat], at time: TimeInterval) -> CGFloat {
            if includesSettling {
                return PanelMotionSpline.interpolate(values, at: time, times: times)
            }
            // Reuse the opening's growth knots. Replace only its overshoot and
            // relaxation with a direct arrival at the expanded endpoint.
            let endpoint = values[values.count - 1]
            var growth = Array(values.prefix(5))
            growth[4] = min(max(growth[4], min(growth[3], endpoint)), max(growth[3], endpoint))
            growth.append(endpoint)
            return PanelMotionSpline.interpolate(growth, at: time,
                                                 times: Array(times.prefix(5)) + [growthDuration])
        }
        let width = interpolate(
            [compactSize.width, 52, size.width * 0.26, size.width * 0.60,
             size.width * 0.95, size.width * 1.027, size.width * 1.012,
             size.width * 1.002, size.width], at: time)
        let height = interpolate(
            [compactSize.height, 46, size.height * 0.29, size.height * 0.74,
             size.height * 1.006, size.height * 1.006, size.height * 1.002,
             size.height, size.height], at: time)
        let right = size.width + interpolate(
            [0, -2, -size.width * 0.06, -size.width * 0.02,
             size.width * 0.012, size.width * 0.013, size.width * 0.004,
             0, 0], at: time)
        let top = interpolate(
            [0, 8, size.height * 0.05, size.height * 0.055,
             size.height * 0.02, -size.height * 0.005, -1,
             0, 0], at: time)
        let radius = interpolate(
            [compactSize.height / 2, 23, min(size.width * 0.26, size.height * 0.29) / 2,
             min(size.width * 0.60, size.height * 0.74) * 0.475,
             min(size.width * 0.95, size.height * 1.006) * 0.21,
             47, 25, 22, 22], at: time)
        return PanelSurfacePose(
            frame: CGRect(x: right - width, y: top, width: width, height: height),
            cornerRadius: min(radius, min(width, height) / 2))
    }

    static func content(at time: TimeInterval) -> (opacity: CGFloat, blur: CGFloat, scale: CGFloat, offset: CGFloat) {
        let u = CGFloat(min(1, max(0, (time - contentRevealStart) / (contentRevealEnd - contentRevealStart))))
        let progress = u * u * (3 - 2 * u)
        // Finish the visible full-calendar blur before the shell reaches its
        // near-full-size correction. Opacity, scale and offset finish at 320 ms.
        // The imperceptible floor keeps the same filter installed
        // until all shell motion has finished, avoiding a mid-flight teardown.
        let blurU = CGFloat(min(1, max(0, (time - contentRevealStart) / (blurRevealEnd - contentRevealStart))))
        let blurProgress = blurU * blurU * (3 - 2 * blurU)
        if time >= duration { return (1, 0, 1, 0) }
        let blur = settledBlurFloor + (12 - settledBlurFloor) * (1 - blurProgress)
        // Identity scale/offset and fully opaque content also let SwiftUI remove
        // intermediate compositing state. Hold imperceptibly off those identities
        // until the shell's exact endpoint, so 320 ms is an ordinary frame.
        return (
            min(progress, settledOpacityCeiling),
            blur,
            max(1 + 0.065 * (1 - progress), settledScaleFloor),
            max(14 * (1 - progress), settledOffsetFloor)
        )
    }

}

/// Both axes contract together, with a small normalized height lead. Travel
/// starts before contraction slows, blending rounding and exit into one motion.
enum PanelCollapseTrajectory {
    static let duration: TimeInterval = 0.32
    static let departureStart = duration / 3
    static let circularizationTime = duration * 0.72
    static let surfaceFadeStart = duration * 0.48
    static let surfaceFadeEnd = duration * 0.90
    static let contentFadeStart = duration / 12
    static let contentFadeEnd = duration / 2
    static let finalSurfaceOpacity: CGFloat = 0
    private static let contractionCurve = PanelMotionCurve(
        controlPoint1X: 0.42, controlPoint1Y: 0,
        controlPoint2X: 0.72, controlPoint2Y: 1
    )

    static func pose(at time: TimeInterval, size: CGSize, compactSize: CGSize) -> PanelSurfacePose {
        if time <= 0 { return .expanded(size: size) }
        if time >= duration { return .collapsed(size: size, compactSize: compactSize) }
        let normalizedTime = CGFloat(time / duration)
        let progress = contractionCurve.progress(at: time / duration)
        // Keep the large rectangle moving long enough to read as one continuous
        // contraction. The previous extra quadratic boost moved the speed peak
        // too early and left a slow circular tail.
        let heightProgress = progress + 0.10 * progress * (1 - progress)
        let diameter = min(compactSize.width, compactSize.height)
        let baseHeight = size.height + (diameter - size.height) * heightProgress
        let baseWidth = size.width + (diameter - size.width) * progress
        // Author aspect convergence on the shared clock instead of feeding it
        // the already-eased size progress. This delays circularization and gives
        // the visible circle a short, decisive contraction before fading.
        let circleTime = min(1, max(0, (normalizedTime - 0.26) / 0.46))
        let circleBlend = circleTime * circleTime * (3 - 2 * circleTime)
        let width: CGFloat
        let height: CGFloat
        if baseWidth >= baseHeight {
            width = baseWidth + (baseHeight - baseWidth) * circleBlend
            height = baseHeight
        } else {
            width = baseWidth
            height = baseHeight + (baseWidth - baseHeight) * circleBlend
        }
        let rounding = min(1, max(0, (normalizedTime - 0.18) / 0.54))
        let initialRoundness = min(1, 44 / min(size.width, size.height))
        let roundness = initialRoundness + (1 - initialRoundness) * rounding * rounding * (3 - 2 * rounding)
        let radius = min(width, height) / 2 * roundness
        // Bow inward and down like the opening's rounded growth. Drive only
        // position from the same contraction progress as size and rounding.
        // The window departure clock is unchanged. The arc has zero endpoint slope
        // and spans the contraction broadly to avoid a second speed surge.
        let arc = 16 * progress * progress * (1 - progress) * (1 - progress)
        return PanelSurfacePose(
            frame: CGRect(x: size.width - width - size.width * 0.06 * arc,
                          y: size.height * 0.055 * arc, width: width, height: height),
            cornerRadius: min(radius, min(width, height) / 2))
    }

    static func content(at time: TimeInterval, size: CGSize = CGSize(width: 760, height: 620))
        -> (opacity: CGFloat, blur: CGFloat, scale: CGFloat, offset: CGFloat) {
        let u = CGFloat(min(1, max(0, (time - contentFadeStart) / (contentFadeEnd - contentFadeStart))))
        let fade = u * u * (3 - 2 * u)
        // Lose detail before the shell gets small, without reducing the calendar
        // to a readable thumbnail. The native outer mask owns the shrinking edge.
        return (1 - fade, 0, 1 - 0.045 * fade, 0)
    }

    static func offscreenFrame(from restingFrame: CGRect, screenFrame: CGRect, compactSize: CGSize) -> CGRect {
        // Return to the opening's entry origin. Computing clearance from an
        // intermediate circle adds an outward shove that cancels the inward arc.
        PanelMotionGeometry.offscreenFrame(from: restingFrame, screenFrame: screenFrame,
            compactSize: compactSize, margin: 8 + PanelSurfacePose.canvasInset)
    }
}

private enum PanelMotionSpline {
    static func interpolate(_ values: [CGFloat], at time: TimeInterval, times: [TimeInterval]) -> CGFloat {
        let i = min(times.count - 2, max(0, times.lastIndex(where: { $0 <= time }) ?? 0))
        let h = CGFloat(times[i + 1] - times[i])
        let u = CGFloat((time - times[i]) / Double(h))
        func slope(_ index: Int) -> CGFloat {
            guard index > 0, index < values.count - 1 else { return 0 }
            let h0 = CGFloat(times[index] - times[index - 1])
            let h1 = CGFloat(times[index + 1] - times[index])
            let d0 = (values[index] - values[index - 1]) / h0
            let d1 = (values[index + 1] - values[index]) / h1
            guard d0 * d1 > 0 else { return 0 }
            let w0 = 2 * h1 + h0
            let w1 = h1 + 2 * h0
            return (w0 + w1) / (w0 / d0 + w1 / d1)
        }
        return (2 * u * u * u - 3 * u * u + 1) * values[i]
            + (u * u * u - 2 * u * u + u) * h * slope(i)
            + (-2 * u * u * u + 3 * u * u) * values[i + 1]
            + (u * u * u - u * u) * h * slope(i + 1)
    }
}

protocol PanelHapticProviding {
    func performTransitionFeedback()
}

struct SystemPanelHapticProvider: PanelHapticProviding {
    func performTransitionFeedback() {
        NSHapticFeedbackManager.defaultPerformer.perform(
            .generic,
            performanceTime: .drawCompleted
        )
    }
}

final class PanelHapticGate {
    private let provider: PanelHapticProviding
    private let cooldown: TimeInterval
    private var lastFeedbackTime: TimeInterval?

    init(
        provider: PanelHapticProviding = SystemPanelHapticProvider(),
        cooldown: TimeInterval = 0.25
    ) {
        self.provider = provider
        self.cooldown = cooldown
    }

    @discardableResult
    func performIfAllowed(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if let lastFeedbackTime, now - lastFeedbackTime < cooldown {
            return false
        }
        lastFeedbackTime = now
        provider.performTransitionFeedback()
        return true
    }
}

enum PanelMotionGeometry {
    static func offscreenFrame(
        from restingFrame: NSRect,
        screenFrame: NSRect,
        compactSize: NSSize,
        margin: CGFloat = 8
    ) -> NSRect {
        let deltaX = screenFrame.maxX - restingFrame.maxX + compactSize.width + margin
        let deltaY = screenFrame.maxY - restingFrame.maxY + compactSize.height + margin
        return restingFrame.offsetBy(dx: deltaX, dy: deltaY)
    }
}

enum PanelDismissalPolicy {
    static func permitsAutoDismiss(isEnabled: Bool, isPinned: Bool) -> Bool {
        isEnabled && !isPinned
    }
}
