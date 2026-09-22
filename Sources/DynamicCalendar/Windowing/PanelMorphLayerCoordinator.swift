import AppKit
import QuartzCore
import OSLog

@MainActor
final class PanelMorphLayerCoordinator {
    private enum WindowTravel {
        case timed(from: CGPoint, to: CGPoint, delay: TimeInterval, duration: TimeInterval, curve: PanelMotionCurve)
        case continuation(x: CalendarMotionTrack, y: CalendarMotionTrack)

        // Playback needs position only; velocity is sampled at interruption.
        func origin(at time: TimeInterval) -> CGPoint {
            switch self {
            case let .timed(source, target, delay, duration, curve):
                let progress = curve.progress(at: (time - delay) / duration)
                return CGPoint(x: source.x + (target.x - source.x) * progress,
                               y: source.y + (target.y - source.y) * progress)
            case let .continuation(x, y):
                return CGPoint(x: x.value(at: time), y: y.value(at: time))
            }
        }

        func sample(at time: TimeInterval) -> (origin: CGPoint, velocity: CGPoint) {
            switch self {
            case let .timed(source, target, delay, duration, curve):
                let elapsed = time - delay
                let progress = curve.progress(at: elapsed / duration)
                let a = max(0, elapsed - 0.0001)
                let b = min(duration, elapsed + 0.0001)
                let speed = elapsed >= 0 && elapsed < duration && b > a
                    ? (curve.progress(at: b / duration) - curve.progress(at: a / duration)) / CGFloat(b - a) : 0
                let dx = target.x - source.x, dy = target.y - source.y
                return (CGPoint(x: source.x + dx * progress, y: source.y + dy * progress),
                        CGPoint(x: dx * speed, y: dy * speed))
            case let .continuation(x, y):
                let sx = x.sample(at: time), sy = y.sample(at: time)
                return (CGPoint(x: sx.value, y: sy.value), CGPoint(x: sx.velocity, y: sy.velocity))
            }
        }

        static func retarget(from source: CGPoint, velocity: CGPoint, to target: CGPoint,
                             duration: TimeInterval) -> Self {
            .continuation(
                x: CalendarMotionTrack(startTime: 0, duration: duration, source: source.x, target: target.x,
                                       initialVelocity: velocity.x, curve: .spring(bounce: 0)),
                y: CalendarMotionTrack(startTime: 0, duration: duration, source: source.y, target: target.y,
                                       initialVelocity: velocity.y, curve: .spring(bounce: 0)))
        }
    }

    private struct Playback {
        var startTime: TimeInterval
        let duration: TimeInterval
        let referenceSize: CGSize?
        var isCollapsing: Bool
        let compactSize: CGSize
        let tracks: [CalendarMotionTrack]
        var windowTravel: WindowTravel?
        var opacity = CalendarMotionTrack.constant(1)
        var foregroundTracks: [CalendarMotionTrack]?

        // Scale, opacity, and translation are sampled with the shell, but retain
        // their own timing. Normal opening keeps its existing SwiftUI recipe.
        func foreground(at time: TimeInterval, size: CGSize,
                        surface: PanelSurfacePose? = nil) -> [CGFloat] {
            if let foregroundTracks { return foregroundTracks.map { $0.value(at: time) } }
            guard isCollapsing else { return [1, 1, 0, 0] }
            let content = PanelCollapseTrajectory.content(at: time, size: size)
            let surface = surface ?? pose(at: time)
            return [content.scale, content.opacity, surface.frame.maxX - size.width, surface.frame.minY]
        }

        func foregroundVelocity(at time: TimeInterval, size: CGSize) -> [CGFloat] {
            if let foregroundTracks { return foregroundTracks.map { $0.sample(at: time).velocity } }
            let a = max(0, time - 0.0001), b = min(duration, time + 0.0001)
            guard b > a, time < duration else { return [0, 0, 0, 0] }
            return zip(foreground(at: b, size: size), foreground(at: a, size: size))
                .map { ($0 - $1) / CGFloat(b - a) }
        }

        func pose(at elapsed: TimeInterval) -> PanelSurfacePose {
            if let referenceSize {
                if isCollapsing {
                    return PanelCollapseTrajectory.pose(at: elapsed, size: referenceSize, compactSize: compactSize)
                }
                return PanelExpansionTrajectory.pose(at: elapsed, size: referenceSize, compactSize: compactSize)
            }
            return PanelSurfacePose(components: tracks.map { $0.value(at: elapsed) })
        }

        func velocity(at elapsed: TimeInterval) -> [CGFloat] {
            if referenceSize == nil { return tracks.map { $0.sample(at: elapsed).velocity } }
            let a = max(0, elapsed - 0.0001)
            let b = min(duration, elapsed + 0.0001)
            guard b > a, elapsed < duration else { return Array(repeating: 0, count: 6) }
            return zip(pose(at: b).components, pose(at: a).components).map { ($0 - $1) / CGFloat(b - a) }
        }
    }

    @MainActor
    private final class DisplayLinkTarget: NSObject {
        weak var owner: PanelMorphLayerCoordinator?
        @objc func update(_ link: CADisplayLink) { owner?.advance(link) }
    }

    private let compactSize: CGSize
    private let motion: PanelMotionModel
    private let maskLayer = CALayer()
    private let capsuleMask = CALayer()
    private let tailMask = CAShapeLayer()
    private let displayLinkTarget = DisplayLinkTarget()
    private weak var contentView: NSView?
    private weak var foregroundView: NSView?
    private var currentForeground: [CGFloat] = [1, 1, 0, 0]
    private weak var panel: NSPanel?
    private var displayLink: CADisplayLink?
    private var playback: Playback?
    private var appliedTime: TimeInterval = 0
    private var endpointSubmitted = false
    private var awaitingCollapseTick = false
    private var completion: (() -> Void)?
    private var departure: (() -> Void)?
    // All mask updates are explicit display-link samples. Keep their pose and
    // velocity together, including the lobe that cannot be read from bounds.
    private var currentPose = PanelSurfacePose.expanded(size: .zero)
    #if DEBUG
    private let performanceLog = Logger(subsystem: "com.wangjiaxun.DynamicCalendar", category: "PanelPlayback")
    private var callbackCount = 0
    private var firstCallbackDelay: TimeInterval = 0
    private var maximumCallbackGap: TimeInterval = 0
    private var maximumCallbackGapElapsed: TimeInterval = 0
    private var previousCallbackTime: TimeInterval?

    var playbackDiagnostics: String {
        "\(callbackCount) frames · first \(Int((firstCallbackDelay * 1000).rounded())) ms · max gap \(Int((maximumCallbackGap * 1000).rounded())) ms @ \(Int((maximumCallbackGapElapsed * 1000).rounded())) ms"
    }
    #endif

    init(compactSize: CGSize, motion: PanelMotionModel) {
        self.compactSize = compactSize
        self.motion = motion
        maskLayer.backgroundColor = NSColor.black.cgColor
        maskLayer.cornerCurve = .continuous
        capsuleMask.backgroundColor = NSColor.black.cgColor
        capsuleMask.cornerCurve = .continuous
        tailMask.fillColor = NSColor.black.cgColor
        maskLayer.addSublayer(capsuleMask)
        maskLayer.addSublayer(tailMask)
        displayLinkTarget.owner = self
    }

    deinit { displayLink?.invalidate() }

    func install(on panel: NSPanel, contentView: NSView, foregroundView: NSView? = nil) {
        self.contentView = contentView
        self.foregroundView = foregroundView
        self.panel = panel
        maskLayer.contentsScale = panel.backingScaleFactor
        capsuleMask.contentsScale = panel.backingScaleFactor
        tailMask.contentsScale = panel.backingScaleFactor
        contentView.wantsLayer = true
        contentView.layoutSubtreeIfNeeded()
        contentView.layer?.mask = maskLayer
        applyForeground([1, 1, 0, 0])
        apply(.expanded(size: surfaceSize))
    }

    func prepareCompact(on panel: NSPanel) {
        stopPlayback()
        panel.alphaValue = 1
        applyForeground([1, 1, 0, 0])
        apply(.compact(size: surfaceSize, compactSize: compactSize))
        panel.hasShadow = true
        panel.invalidateShadow()
    }

    func beginExpansion(on panel: NSPanel, targetFrame: CGRect? = nil, reversing: Bool = false, completion: @escaping () -> Void) {
        let source = currentPose
        let velocity = currentVelocity
        let foreground = currentForeground
        let foregroundVelocity = playback?.foregroundVelocity(at: appliedTime, size: surfaceSize) ?? [0, 0, 0, 0]
        let opacity = playback?.opacity.sample(at: appliedTime)
            ?? CalendarMotionSample(value: panel.alphaValue, velocity: 0)
        let window = playback?.windowTravel?.sample(at: appliedTime) ?? (origin: panel.frame.origin, velocity: CGPoint.zero)
        stopPlayback()
        panel.hasShadow = true
        self.completion = completion
        if reversing {
            playback = continuation(from: source, velocity: velocity,
                                    to: .expanded(size: surfaceSize), duration: 0.50, bounce: 0.12)
        } else {
            playback = Playback(startTime: CACurrentMediaTime(), duration: PanelExpansionTrajectory.duration,
                                referenceSize: surfaceSize, isCollapsing: false, compactSize: compactSize, tracks: [])
        }
        if let targetFrame {
            playback?.windowTravel = reversing
                ? .retarget(from: window.origin, velocity: window.velocity, to: targetFrame.origin,
                            duration: PanelMotionTiming.entryTravelDuration)
                : .timed(from: window.origin, to: targetFrame.origin, delay: 0,
                         duration: PanelMotionTiming.entryTravelDuration, curve: PanelMotionTiming.entryCurve)
        }
        if reversing {
            playback?.foregroundTracks = foregroundContinuation(from: foreground, velocity: foregroundVelocity,
                                                                 to: [1, 1, 0, 0])
            playback?.opacity = CalendarMotionTrack(startTime: 0, duration: 0.10,
                source: opacity.value, target: 1, initialVelocity: opacity.velocity, curve: .spring(bounce: 0))
        }
        startPlayback()
    }

    func beginCollapse(on panel: NSPanel, targetFrame: CGRect? = nil, onDeparture: @escaping () -> Void = {},
                       completion: @escaping () -> Void = {}) {
        let source = currentPose
        let velocity = currentVelocity
        let foreground = currentForeground
        let foregroundVelocity = playback?.foregroundVelocity(at: appliedTime, size: surfaceSize) ?? [0, 0, 0, 0]
        let opacity = playback?.opacity.sample(at: appliedTime)
            ?? CalendarMotionSample(value: panel.alphaValue, velocity: 0)
        let window = playback?.windowTravel?.sample(at: appliedTime) ?? (origin: panel.frame.origin, velocity: CGPoint.zero)
        stopPlayback()
        panel.hasShadow = true
        self.completion = completion
        departure = onDeparture
        if source == .expanded(size: surfaceSize), velocity.allSatisfy({ abs($0) < 0.001 }) {
            playback = Playback(startTime: CACurrentMediaTime(), duration: PanelCollapseTrajectory.duration,
                                referenceSize: surfaceSize, isCollapsing: true, compactSize: compactSize, tracks: [])
        } else {
            // An interrupted opening already has a moving, smaller surface.
            // Retarget it instead of jumping back to the full-size reference.
            playback = continuation(from: source, velocity: velocity,
                                    to: .collapsed(size: surfaceSize, compactSize: compactSize),
                                    duration: PanelCollapseTrajectory.duration, bounce: 0)
        }
        if let targetFrame {
            if abs(window.velocity.x) < 0.001 && abs(window.velocity.y) < 0.001 {
                playback?.windowTravel = .timed(from: window.origin, to: targetFrame.origin,
                    delay: PanelCollapseTrajectory.departureStart, duration: PanelMotionTiming.departureDuration,
                    curve: PanelMotionTiming.departureCurve)
            } else {
                playback?.windowTravel = .retarget(from: window.origin, velocity: window.velocity,
                    to: targetFrame.origin, duration: PanelCollapseTrajectory.duration)
            }
        }
        playback?.isCollapsing = true
        if foreground != [1, 1, 0, 0] {
            playback?.foregroundTracks = foregroundContinuation(from: foreground, velocity: foregroundVelocity,
                to: [PanelCollapseTrajectory.content(at: PanelCollapseTrajectory.duration).scale, 0, 0, 0],
                duration: PanelCollapseTrajectory.duration)
        }
        // Fade the shrinking shell and its shadow out on the same native clock.
        // Interrupted fades continue immediately from their sampled opacity.
        let fadeStart = opacity.value == 1 && abs(opacity.velocity) < 0.001
            ? PanelCollapseTrajectory.surfaceFadeStart : 0
        playback?.opacity = CalendarMotionTrack(startTime: fadeStart,
            duration: PanelCollapseTrajectory.surfaceFadeEnd - PanelCollapseTrajectory.surfaceFadeStart,
            source: opacity.value, target: PanelCollapseTrajectory.finalSurfaceOpacity,
            initialVelocity: opacity.velocity, curve: .continuation)
        startPlayback()
    }

    func finishExpanded(on panel: NSPanel) {
        stopPlayback()
        panel.alphaValue = 1
        applyForeground([1, 1, 0, 0])
        apply(.expanded(size: surfaceSize))
        panel.hasShadow = true
        panel.invalidateShadow()
    }

    func finishHidden(on panel: NSPanel) {
        stopPlayback()
        panel.hasShadow = false
        apply(.collapsed(size: surfaceSize, compactSize: compactSize))
    }

    func updateStableGeometry(on panel: NSPanel) {
        stopPlayback()
        applyForeground([1, 1, 0, 0])
        apply(.expanded(size: surfaceSize))
        panel.invalidateShadow()
    }

    func tearDown() {
        stopPlayback()
        contentView?.layer?.mask = nil
        applyForeground([1, 1, 0, 0])
    }

    #if DEBUG
    func previewExpansion(at time: TimeInterval) {
        stopPlayback()
        applyForeground([1, 1, 0, 0])
        apply(PanelExpansionTrajectory.pose(at: time, size: surfaceSize, compactSize: compactSize))
    }

    func previewCollapse(at time: TimeInterval) {
        stopPlayback()
        let pose = PanelCollapseTrajectory.pose(at: time, size: surfaceSize, compactSize: compactSize)
        let content = PanelCollapseTrajectory.content(at: time, size: surfaceSize)
        applyForeground([content.scale, content.opacity, pose.frame.maxX - surfaceSize.width, pose.frame.minY])
        apply(pose)
    }

    var sampledVelocity: [CGFloat] { currentVelocity }
    var sampledForeground: [CGFloat] { currentForeground }
    var sampledForegroundVelocity: [CGFloat] {
        playback?.foregroundVelocity(at: appliedTime, size: surfaceSize) ?? [0, 0, 0, 0]
    }
    var sampledWindowMotion: (origin: CGPoint, velocity: CGPoint)? {
        playback?.windowTravel?.sample(at: appliedTime)
    }

    /// Advance the actual playback sampler without a wall-clock wait in tests.
    func previewPlayback(at time: TimeInterval) {
        guard let playback else { return }
        applyPlayback(at: time, playback: playback)
    }
    #endif

    private var surfaceSize: CGSize {
        let bounds = contentView?.bounds ?? .zero
        let inset = PanelSurfacePose.canvasInset
        return CGSize(width: max(1, bounds.width - 2 * inset), height: max(1, bounds.height - 2 * inset))
    }

    private var currentVelocity: [CGFloat] {
        playback?.velocity(at: appliedTime) ?? Array(repeating: 0, count: 6)
    }

    private func continuation(from source: PanelSurfacePose, velocity: [CGFloat], to target: PanelSurfacePose,
                              duration: TimeInterval, bounce: Double) -> Playback {
        let tracks = zip(source.components, target.components).enumerated().map { index, pair in
            CalendarMotionTrack(startTime: 0, duration: duration, source: pair.0, target: pair.1,
                                initialVelocity: velocity[index], curve: .spring(bounce: bounce))
        }
        return Playback(startTime: CACurrentMediaTime(), duration: duration, referenceSize: nil,
                        isCollapsing: false, compactSize: compactSize, tracks: tracks)
    }

    private func startPlayback() {
        guard let contentView, let playback else { return }
        appliedTime = 0
        endpointSubmitted = false
        awaitingCollapseTick = playback.isCollapsing
        #if DEBUG
        callbackCount = 0
        firstCallbackDelay = 0
        maximumCallbackGap = 0
        maximumCallbackGapElapsed = 0
        previousCallbackTime = nil
        #endif
        applyPlayback(at: 0, playback: playback)
        let link = contentView.displayLink(target: displayLinkTarget, selector: #selector(DisplayLinkTarget.update(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func advance(_ link: CADisplayLink) {
        guard var playback else { return }
        #if DEBUG
        let callbackTime = CACurrentMediaTime()
        callbackCount += 1
        if let previousCallbackTime {
            let gap = callbackTime - previousCallbackTime
            if gap > maximumCallbackGap {
                maximumCallbackGap = gap
                maximumCallbackGapElapsed = callbackTime - playback.startTime
            }
        } else {
            firstCallbackDelay = callbackTime - playback.startTime
        }
        previousCallbackTime = callbackTime
        #endif
        if awaitingCollapseTick {
            // App deactivation may finish field-editor/layout work after the
            // outside click returns. Do not consume the close before its first
            // display tick. Subsequent samples retain the original 320 ms clock.
            playback.startTime = link.targetTimestamp
            self.playback = playback
            awaitingCollapseTick = false
        }
        if endpointSubmitted {
            // The exact endpoint was committed on the preceding display tick.
            #if DEBUG
            performanceLog.notice("collapse=\(playback.isCollapsing) callbacks=\(self.callbackCount) firstMS=\(self.firstCallbackDelay * 1000) maxGapMS=\(self.maximumCallbackGap * 1000)")
            #endif
            let completion = self.completion
            stopPlayback()
            completion?()
            return
        }
        applyPlayback(at: link.targetTimestamp - playback.startTime, playback: playback)
        endpointSubmitted = appliedTime >= playback.duration
    }

    private func applyPlayback(at time: TimeInterval, playback: Playback) {
        appliedTime = min(playback.duration, max(0, time))
        // Window origin and surface geometry are sampled at exactly the same time,
        // even when a callback skips over the departure milestone.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let panel {
            if let origin = playback.windowTravel?.origin(at: appliedTime),
               panel.frame.origin != origin {
                panel.setFrameOrigin(origin)
            }
            let opacity = min(1, max(0, playback.opacity.value(at: appliedTime)))
            if panel.alphaValue != opacity { panel.alphaValue = opacity }
        }
        let pose = playback.pose(at: appliedTime)
        apply(pose)
        applyForeground(playback.foreground(at: appliedTime, size: surfaceSize, surface: pose))
        CATransaction.commit()
        if appliedTime >= PanelCollapseTrajectory.departureStart, let departure {
            self.departure = nil
            // This callback only updates semantic state; it starts no animation.
            departure()
        }
    }

    private func apply(_ pose: PanelSurfacePose) {
        guard let host = contentView?.layer else { return }
        currentPose = pose
        let inset = PanelSurfacePose.canvasInset
        let hasTail = pose.tailHeight > 0
        let flipped = host.isGeometryFlipped
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.anchorPoint = CGPoint(x: 1, y: host.isGeometryFlipped ? 0 : 1)
        maskLayer.position = CGPoint(x: inset + pose.frame.maxX,
                                     y: host.isGeometryFlipped ? inset + pose.frame.minY
                                        : host.bounds.height - inset - pose.frame.minY)
        maskLayer.bounds = CGRect(origin: .zero, size: pose.visibleFrame.size)
        let radius = max(0, min(pose.cornerRadius, min(pose.frame.width, pose.frame.height) / 2))
        // Keep the approved opening's native continuous corners unchanged.
        // Only the return lobe needs the two-piece mask.
        maskLayer.backgroundColor = hasTail ? NSColor.clear.cgColor : NSColor.black.cgColor
        maskLayer.cornerRadius = hasTail ? 0 : radius
        capsuleMask.isHidden = !hasTail
        tailMask.isHidden = !hasTail
        if hasTail {
            capsuleMask.frame = CGRect(x: 0, y: flipped ? 0 : pose.tailHeight,
                                       width: pose.frame.width, height: pose.frame.height)
            capsuleMask.cornerRadius = radius
            tailMask.frame = maskLayer.bounds
            var transform = flipped ? CGAffineTransform.identity
                : CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: pose.visibleFrame.height)
            tailMask.path = pose.tailPath.copy(using: &transform)
        }
        if displayLink == nil {
            maskLayer.removeAllAnimations()
            maskLayer.transform = CATransform3DIdentity
        }
        motion.surfaceRenderer?.applySurface(pose)
        CATransaction.commit()
    }

    private func foregroundContinuation(from source: [CGFloat], velocity: [CGFloat], to target: [CGFloat],
                                        duration: TimeInterval = 0.24)
        -> [CalendarMotionTrack] {
        zip(source, target).enumerated().map { index, pair in
            CalendarMotionTrack(startTime: 0, duration: duration,
                source: pair.0, target: pair.1, initialVelocity: velocity[index], curve: .continuation)
        }
    }

    private func applyForeground(_ values: [CGFloat]) {
        currentForeground = values
        guard let layer = foregroundView?.layer else { return }
        let scale = values[0]
        let inset = PanelSurfacePose.canvasInset
        let anchorX = inset + surfaceSize.width
        let anchorY = layer.isGeometryFlipped ? inset : layer.bounds.height - inset
        let dy = layer.isGeometryFlipped ? values[3] : -values[3]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let transform = CATransform3DMakeAffineTransform(CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale,
            tx: anchorX * (1 - scale) + values[2], ty: anchorY * (1 - scale) + dy))
        // Normal opening leaves this native transform at identity while SwiftUI
        // owns the content reveal. Do not dirty it on every display callback.
        if !CATransform3DEqualToTransform(layer.sublayerTransform, transform) {
            layer.sublayerTransform = transform
        }
        let opacity = Float(min(1, max(0, values[1])))
        if layer.opacity != opacity { layer.opacity = opacity }
        CATransaction.commit()
    }

    private func stopPlayback() {
        displayLink?.invalidate()
        displayLink = nil
        playback = nil
        completion = nil
        departure = nil
        endpointSubmitted = false
        awaitingCollapseTick = false
    }
}
