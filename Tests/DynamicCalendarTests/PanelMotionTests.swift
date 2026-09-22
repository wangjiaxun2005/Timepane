import AppKit
import XCTest
@testable import DynamicCalendar

@MainActor
final class PanelMotionTests: XCTestCase {
    func testVisiblePanelCanStayFlushWithMenuBarAfterOrderingAndRepositioning() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let inset = PanelSurfacePose.canvasInset
        let visibleSurface = CGRect(x: screen.visibleFrame.maxX - 332,
                                    y: screen.visibleFrame.maxY - 420, width: 320, height: 420)
        let frame = visibleSurface.insetBy(dx: -inset, dy: -inset)
        let panel = FloatingPanel(contentRect: frame, styleMask: [.borderless, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        defer { panel.close() }
        panel.orderFront(nil)
        panel.setFrame(frame, display: true)
        XCTAssertEqual(panel.frame.maxY - inset, screen.visibleFrame.maxY, accuracy: 0.001)
        XCTAssertEqual(panel.frame.size, frame.size)
    }

    func testCollapseContractsBothAxesWithHeightLeadingAndNoOvershoot() {
        for size in [CGSize(width: 760, height: 620), CGSize(width: 320, height: 420)] {
            let compact = CGSize(width: 56, height: 32)
            let canvas = CGRect(origin: .zero, size: size).insetBy(dx: -24, dy: -24)
            XCTAssertEqual(PanelCollapseTrajectory.pose(at: 0, size: size, compactSize: compact),
                           .expanded(size: size))
            XCTAssertEqual(PanelCollapseTrajectory.pose(at: PanelCollapseTrajectory.duration, size: size, compactSize: compact),
                           .collapsed(size: size, compactSize: compact))
            for tick in 0...Int(PanelCollapseTrajectory.duration * 1000) {
                let pose = PanelCollapseTrajectory.pose(at: Double(tick) / 1000, size: size, compactSize: compact)
                XCTAssertTrue(canvas.contains(pose.visibleFrame), "Clipped at \(tick) ms: \(pose.visibleFrame)")
                XCTAssertGreaterThan(pose.frame.width, 0)
                XCTAssertGreaterThan(pose.frame.height, 0)
                XCTAssertLessThanOrEqual(pose.cornerRadius, min(pose.frame.width, pose.frame.height) / 2)
                XCTAssertGreaterThanOrEqual(pose.tailHeight, 0)
            }
            var previous = PanelCollapseTrajectory.pose(at: 0, size: size, compactSize: compact)
            for tick in 1...Int(PanelCollapseTrajectory.duration * 1000) {
                let pose = PanelCollapseTrajectory.pose(at: Double(tick) / 1000, size: size, compactSize: compact)
                XCTAssertLessThan(pose.frame.width, previous.frame.width)
                XCTAssertLessThan(pose.frame.height, previous.frame.height)
                let widthProgress = (size.width - pose.frame.width) / (size.width - compact.height)
                let heightProgress = (size.height - pose.frame.height) / (size.height - compact.height)
                if Double(tick) / 1000 <= 0.045 {
                    XCTAssertGreaterThanOrEqual(heightProgress + 0.000001, widthProgress)
                    XCTAssertLessThanOrEqual(heightProgress - widthProgress, 0.041)
                }
                if Double(tick) / 1000 >= PanelCollapseTrajectory.circularizationTime {
                    XCTAssertEqual(pose.frame.width, pose.frame.height, accuracy: 0.000001)
                    XCTAssertEqual(pose.cornerRadius, pose.frame.height / 2, accuracy: 0.000001)
                }
                XCTAssertLessThanOrEqual(pose.frame.maxX, size.width)
                XCTAssertGreaterThanOrEqual(pose.frame.maxX, size.width * 0.94)
                XCTAssertGreaterThanOrEqual(pose.frame.minY, 0)
                XCTAssertLessThanOrEqual(pose.frame.minY, size.height * 0.055)
                XCTAssertEqual(pose.tailHeight, 0)
                previous = pose
            }
            // Circularization now precedes the fade endpoint so the final round
            // surface has a short, visible and decisive contraction.
            let circle = PanelCollapseTrajectory.pose(at: PanelCollapseTrajectory.circularizationTime,
                size: size, compactSize: compact)
            XCTAssertEqual(circle.frame.width, circle.frame.height, accuracy: 0.000001)
            XCTAssertEqual(circle.cornerRadius, circle.frame.height / 2, accuracy: 0.000001)
            let fadingCircle = PanelCollapseTrajectory.pose(at: PanelCollapseTrajectory.surfaceFadeEnd,
                size: size, compactSize: compact)
            XCTAssertLessThan(fadingCircle.frame.width, circle.frame.width)
            XCTAssertEqual(fadingCircle.frame.width, fadingCircle.frame.height, accuracy: 0.000001)
            let nearEnd = PanelCollapseTrajectory.pose(at: PanelCollapseTrajectory.duration - 0.00001, size: size, compactSize: compact)
            let beforeNearEnd = PanelCollapseTrajectory.pose(at: PanelCollapseTrajectory.duration - 0.00002, size: size, compactSize: compact)
            let end = PanelCollapseTrajectory.pose(at: PanelCollapseTrajectory.duration, size: size, compactSize: compact)
            for index in end.components.indices {
                // Second-order difference distinguishes endpoint velocity from
                // the entry trajectory's appreciable endpoint acceleration.
                let velocity = (3 * end.components[index] - 4 * nearEnd.components[index]
                                + beforeNearEnd.components[index]) / 0.00002
                XCTAssertEqual(velocity, 0, accuracy: 0.05)
            }
        }
        XCTAssertEqual(PanelCollapseTrajectory.content(at: 0).opacity, 1)
        var opacity: CGFloat = 1
        for tick in 0...Int(PanelCollapseTrajectory.duration * 1000) {
            let closing = PanelCollapseTrajectory.content(at: Double(tick) / 1000)
            XCTAssertLessThanOrEqual(closing.opacity, opacity)
            XCTAssertGreaterThanOrEqual(closing.opacity, 0)
            XCTAssertGreaterThanOrEqual(closing.blur, 0)
            opacity = closing.opacity
        }
        XCTAssertEqual(PanelCollapseTrajectory.content(at: PanelCollapseTrajectory.duration * 0.75).opacity, 0)
        XCTAssertTrue(PanelMotionPhase.departing.keepsExpandedContentAlive)
    }

    func testCollapseDefersCircularizationAndKeepsTheRoundRetreatBrisk() {
        let size = CGSize(width: 760, height: 620)
        let compact = CGSize(width: 56, height: 32)
        let midpoint = PanelCollapseTrajectory.pose(at: PanelCollapseTrajectory.duration / 2,
                                                    size: size, compactSize: compact)
        XCTAssertGreaterThan(midpoint.frame.width / midpoint.frame.height, 1.10)

        let circleTime = PanelCollapseTrajectory.circularizationTime
        let circle = PanelCollapseTrajectory.pose(at: circleTime, size: size, compactSize: compact)
        let fade = PanelCollapseTrajectory.pose(at: PanelCollapseTrajectory.surfaceFadeEnd,
                                                size: size, compactSize: compact)
        let earlyDistance = hypot(size.width - circle.frame.width, size.height - circle.frame.height)
        let lateDistance = hypot(circle.frame.width - fade.frame.width,
                                 circle.frame.height - fade.frame.height)
        let earlySpeed = earlyDistance / circleTime
        let lateSpeed = lateDistance / (PanelCollapseTrajectory.surfaceFadeEnd - circleTime)
        XCTAssertGreaterThan(lateSpeed, earlySpeed * 0.70)

        var previous = PanelCollapseTrajectory.pose(at: 0, size: size, compactSize: compact)
        var peakSpeed: CGFloat = 0
        var peakTime: TimeInterval = 0
        for tick in 1...Int(PanelCollapseTrajectory.duration * 1000) {
            let time = Double(tick) / 1000
            let pose = PanelCollapseTrajectory.pose(at: time, size: size, compactSize: compact)
            let speed = hypot(pose.frame.width - previous.frame.width,
                              pose.frame.height - previous.frame.height) * 1000
            if speed > peakSpeed {
                peakSpeed = speed
                peakTime = time
            }
            previous = pose
        }
        XCTAssertGreaterThanOrEqual(peakTime, PanelCollapseTrajectory.duration * 0.45)
        XCTAssertLessThanOrEqual(peakTime, PanelCollapseTrajectory.duration * 0.65)
    }

    func testClosingContentRetreatsModestlyAndLosesDetailBeforeTheShellBecomesSmall() {
        for size in [CGSize(width: 760, height: 620), CGSize(width: 320, height: 420)] {
            var previousScale: CGFloat = 1
            for tick in 0...Int(PanelCollapseTrajectory.duration * 1000) {
                let time = Double(tick) / 1000
                let content = PanelCollapseTrajectory.content(at: time, size: size)
                XCTAssertLessThanOrEqual(content.scale, previousScale)
                XCTAssertGreaterThanOrEqual(content.scale, 0.955)
                XCTAssertLessThanOrEqual(content.scale, 1)
                XCTAssertEqual(content.blur, 0)
                XCTAssertEqual(content.offset, 0)
                previousScale = content.scale
            }
        }
        XCTAssertGreaterThan(PanelCollapseTrajectory.content(at: 0.10).opacity, 0)
        XCTAssertEqual(PanelCollapseTrajectory.content(at: PanelCollapseTrajectory.contentFadeEnd).opacity, 0, accuracy: 0.000001)
        XCTAssertGreaterThan(PanelCollapseTrajectory.content(at: 0.05).scale, 0.95)
    }

    func testClosingSurfaceFadeOverlapsContentAndReopensWithoutAnOpacityJump() {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 808, height: 668),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let canvas = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
        canvas.wantsLayer = true
        panel.contentView = canvas
        let model = PanelMotionModel()
        let coordinator = PanelMorphLayerCoordinator(compactSize: CGSize(width: 56, height: 32), motion: model)
        coordinator.install(on: panel, contentView: canvas)
        coordinator.finishExpanded(on: panel)
        coordinator.beginCollapse(on: panel)
        coordinator.previewPlayback(at: PanelCollapseTrajectory.surfaceFadeStart)
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertGreaterThan(PanelCollapseTrajectory.content(at: PanelCollapseTrajectory.surfaceFadeStart).opacity, 0)
        coordinator.previewPlayback(at: (PanelCollapseTrajectory.surfaceFadeStart + PanelCollapseTrajectory.surfaceFadeEnd) / 2)
        XCTAssertEqual(panel.alphaValue, 0.5, accuracy: 0.000001)
        let fadingOpacity = panel.alphaValue
        coordinator.beginExpansion(on: panel, reversing: true, completion: {})
        XCTAssertEqual(panel.alphaValue, fadingOpacity, accuracy: 0.000001)
        coordinator.previewPlayback(at: 0.10)
        XCTAssertEqual(panel.alphaValue, 1)
        coordinator.finishExpanded(on: panel)
        coordinator.beginCollapse(on: panel)
        coordinator.previewPlayback(at: PanelCollapseTrajectory.surfaceFadeEnd)
        XCTAssertEqual(panel.alphaValue, 0, accuracy: 0.000001)
        coordinator.previewPlayback(at: PanelCollapseTrajectory.duration)
        XCTAssertEqual(panel.alphaValue, 0, accuracy: 0.000001)
        coordinator.beginExpansion(on: panel, reversing: true, completion: {})
        XCTAssertEqual(panel.alphaValue, 0)
        coordinator.previewPlayback(at: 0.10)
        XCTAssertEqual(panel.alphaValue, 1)
        coordinator.prepareCompact(on: panel)
        XCTAssertEqual(panel.alphaValue, 1)
        coordinator.tearDown()
    }

    func testNativeForegroundSharesSkippedShellSamplesAndPreservesReversal() {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 808, height: 668),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let canvas = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
        let foreground = NSView(frame: canvas.bounds)
        canvas.wantsLayer = true
        foreground.wantsLayer = true
        canvas.addSubview(foreground)
        panel.contentView = canvas
        let model = PanelMotionModel()
        let coordinator = PanelMorphLayerCoordinator(compactSize: CGSize(width: 56, height: 32), motion: model)
        coordinator.install(on: panel, contentView: canvas, foregroundView: foreground)
        for time in [0.081, 0.105, 0.17] {
            coordinator.finishExpanded(on: panel)
            coordinator.beginCollapse(on: panel)
            coordinator.previewPlayback(at: time)
            let content = PanelCollapseTrajectory.content(at: time)
            let pose = PanelCollapseTrajectory.pose(at: time, size: CGSize(width: 760, height: 620),
                                                    compactSize: CGSize(width: 56, height: 32))
            let layer = foreground.layer!
            XCTAssertEqual(layer.sublayerTransform.m11, content.scale, accuracy: 0.000001)
            XCTAssertEqual(CGFloat(layer.opacity), content.opacity, accuracy: 0.000001)
            XCTAssertEqual(layer.sublayerTransform.m41,
                           784 * (1 - content.scale) + pose.frame.maxX - 760, accuracy: 0.000001)
            let sample = coordinator.sampledForeground
            let velocity = coordinator.sampledForegroundVelocity
            coordinator.beginExpansion(on: panel, reversing: true, completion: {})
            for index in sample.indices {
                XCTAssertEqual(coordinator.sampledForeground[index], sample[index], accuracy: 0.000001)
                XCTAssertEqual(coordinator.sampledForegroundVelocity[index], velocity[index], accuracy: 0.000001)
            }
            coordinator.previewPlayback(at: 0.06)
            let reopening = coordinator.sampledForeground
            coordinator.beginCollapse(on: panel)
            for index in reopening.indices {
                XCTAssertEqual(coordinator.sampledForeground[index], reopening[index], accuracy: 0.000001)
            }
            coordinator.previewPlayback(at: PanelCollapseTrajectory.duration)
            XCTAssertEqual(layer.opacity, 0)
            coordinator.beginExpansion(on: panel, reversing: true, completion: {})
            coordinator.previewPlayback(at: PanelCollapseTrajectory.duration)
            XCTAssertEqual(layer.opacity, 1)
            XCTAssertTrue(CATransform3DIsIdentity(layer.sublayerTransform))
        }
        coordinator.tearDown()
    }

    func testCollapseReversalPreservesSurfaceAndVelocity() {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 808, height: 668),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let canvas = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
        canvas.wantsLayer = true
        panel.contentView = canvas
        let model = PanelMotionModel()
        let recorder = PanelSurfaceRecorder()
        model.surfaceRenderer = recorder
        let coordinator = PanelMorphLayerCoordinator(compactSize: CGSize(width: 56, height: 32), motion: model)
        coordinator.install(on: panel, contentView: canvas)
        for time in [0.028, 0.08, 0.096, 0.16, 0.192, 0.216, PanelCollapseTrajectory.duration] {
            coordinator.finishExpanded(on: panel)
            coordinator.beginCollapse(on: panel)
            coordinator.previewPlayback(at: time)
            let source = recorder.pose!
            let velocity = coordinator.sampledVelocity
            XCTAssertEqual(canvas.layer!.mask!.bounds.size, source.visibleFrame.size)
            coordinator.beginExpansion(on: panel, reversing: true, completion: {})
            XCTAssertEqual(recorder.pose, source)
            for (before, after) in zip(velocity, coordinator.sampledVelocity) {
                XCTAssertEqual(before, after, accuracy: 0.000001)
            }
            coordinator.previewPlayback(at: 0.5)
            XCTAssertEqual(recorder.pose, .expanded(size: CGSize(width: 760, height: 620)))
        }
        coordinator.tearDown()
    }

    func testDepartureOverlapsCollapseAndIsCancelledByReversal() {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 808, height: 668),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let canvas = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
        canvas.wantsLayer = true
        panel.contentView = canvas
        let model = PanelMotionModel()
        let recorder = PanelSurfaceRecorder()
        model.surfaceRenderer = recorder
        let coordinator = PanelMorphLayerCoordinator(compactSize: CGSize(width: 56, height: 32), motion: model)
        coordinator.install(on: panel, contentView: canvas)
        coordinator.finishExpanded(on: panel)
        var departures = 0
        coordinator.beginCollapse(on: panel, onDeparture: { departures += 1 })
        coordinator.previewPlayback(at: PanelCollapseTrajectory.departureStart - 0.001)
        XCTAssertEqual(departures, 0)
        coordinator.previewPlayback(at: PanelCollapseTrajectory.departureStart)
        XCTAssertEqual(departures, 1)
        XCTAssertGreaterThan(recorder.pose!.frame.height, 32 * 2)
        coordinator.previewPlayback(at: PanelCollapseTrajectory.duration)
        XCTAssertEqual(departures, 1)

        coordinator.finishExpanded(on: panel)
        coordinator.beginCollapse(on: panel, onDeparture: { departures += 1 })
        coordinator.previewPlayback(at: PanelCollapseTrajectory.departureStart - 0.01)
        coordinator.beginExpansion(on: panel, reversing: true, completion: {})
        coordinator.previewPlayback(at: 0.34)
        XCTAssertEqual(departures, 1, "Reversal must cancel the outgoing travel milestone")
        coordinator.tearDown()
    }

    func testWindowAndSurfaceStaySynchronizedAcrossSkippedDepartureCallbacks() {
        let resting = CGRect(x: 300, y: 150, width: 808, height: 668)
        let destination = resting.offsetBy(dx: 76, dy: 76)
        let panel = NSPanel(contentRect: resting, styleMask: [.borderless], backing: .buffered, defer: false)
        let canvas = NSView(frame: CGRect(origin: .zero, size: resting.size))
        canvas.wantsLayer = true
        panel.contentView = canvas
        let model = PanelMotionModel()
        let recorder = PanelSurfaceRecorder()
        model.surfaceRenderer = recorder
        let coordinator = PanelMorphLayerCoordinator(compactSize: CGSize(width: 56, height: 32), motion: model)
        coordinator.install(on: panel, contentView: canvas)
        for firstCallback in [0.081, 0.12, 0.18] {
            panel.setFrame(resting, display: false)
            coordinator.finishExpanded(on: panel)
            var milestones = 0
            coordinator.beginCollapse(on: panel, targetFrame: destination, onDeparture: { milestones += 1 })
            for time in [firstCallback, 0.20, PanelCollapseTrajectory.duration] {
                coordinator.previewPlayback(at: time)
                let progress = PanelMotionTiming.departureCurve.progress(at:
                    (time - PanelCollapseTrajectory.departureStart) / PanelMotionTiming.departureDuration)
                let expected = CGPoint(x: resting.minX + 76 * progress, y: resting.minY + 76 * progress)
                XCTAssertEqual(coordinator.sampledWindowMotion!.origin.x, expected.x, accuracy: 0.000001)
                XCTAssertEqual(coordinator.sampledWindowMotion!.origin.y, expected.y, accuracy: 0.000001)
                XCTAssertEqual(panel.frame.minX, expected.x, accuracy: 1)
                XCTAssertEqual(panel.frame.minY, expected.y, accuracy: 1)
                XCTAssertEqual(recorder.pose, PanelCollapseTrajectory.pose(at: time,
                    size: CGSize(width: 760, height: 620), compactSize: CGSize(width: 56, height: 32)))
            }
            XCTAssertEqual(milestones, 1)
        }
        coordinator.tearDown()
    }

    func testWindowReversalPreservesOriginAndVelocityInBothDirections() {
        let resting = CGRect(x: 300, y: 150, width: 808, height: 668)
        let destination = resting.offsetBy(dx: 76, dy: 76)
        let panel = NSPanel(contentRect: resting, styleMask: [.borderless], backing: .buffered, defer: false)
        let canvas = NSView(frame: CGRect(origin: .zero, size: resting.size))
        canvas.wantsLayer = true
        panel.contentView = canvas
        let model = PanelMotionModel()
        let coordinator = PanelMorphLayerCoordinator(compactSize: CGSize(width: 56, height: 32), motion: model)
        coordinator.install(on: panel, contentView: canvas)
        for time in [0.06, 0.12, 0.20, 0.23] {
            panel.setFrame(resting, display: false)
            coordinator.finishExpanded(on: panel)
            coordinator.beginCollapse(on: panel, targetFrame: destination)
            coordinator.previewPlayback(at: time)
            let outgoing = coordinator.sampledWindowMotion!
            coordinator.beginExpansion(on: panel, targetFrame: resting, reversing: true, completion: {})
            XCTAssertEqual(coordinator.sampledWindowMotion!.origin, outgoing.origin)
            XCTAssertEqual(coordinator.sampledWindowMotion!.velocity, outgoing.velocity)
            coordinator.previewPlayback(at: 0.07)
            let returning = coordinator.sampledWindowMotion!
            coordinator.beginCollapse(on: panel, targetFrame: destination)
            XCTAssertEqual(coordinator.sampledWindowMotion!.origin, returning.origin)
            XCTAssertEqual(coordinator.sampledWindowMotion!.velocity, returning.velocity)
            coordinator.previewPlayback(at: PanelCollapseTrajectory.duration)
            XCTAssertEqual(coordinator.sampledWindowMotion!.origin, destination.origin)
        }
        coordinator.tearDown()
    }

    func testSurfaceRendererAndStableCanvasMaskUseTheSameGeometryDuringReversal() {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 808, height: 668),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let canvas = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
        canvas.wantsLayer = true
        panel.contentView = canvas
        let model = PanelMotionModel()
        let recorder = PanelSurfaceRecorder()
        model.surfaceRenderer = recorder
        let coordinator = PanelMorphLayerCoordinator(compactSize: CGSize(width: 56, height: 32), motion: model)
        coordinator.install(on: panel, contentView: canvas)
        coordinator.previewExpansion(at: 0.29)
        let pose = recorder.pose!
        let mask = canvas.layer!.mask!
        XCTAssertEqual(mask.position.x, pose.frame.maxX + 24, accuracy: 0.001)
        XCTAssertEqual(mask.position.y, canvas.bounds.height - pose.frame.minY - 24, accuracy: 0.001)
        XCTAssertEqual(mask.bounds.size, pose.frame.size)
        coordinator.beginCollapse(on: panel)
        for (actual, expected) in zip(recorder.pose!.components, pose.components) {
            XCTAssertEqual(actual, expected, accuracy: 0.000001)
        }
        coordinator.beginExpansion(on: panel, reversing: true, completion: {})
        for (actual, expected) in zip(recorder.pose!.components, pose.components) {
            XCTAssertEqual(actual, expected, accuracy: 0.000001)
        }
        XCTAssertTrue(CATransform3DIsIdentity(mask.transform))
        coordinator.tearDown()
    }

    func testReferenceExpansionKeepsExactEndpointsAndDoesNotClipItsOvershoot() {
        for size in [CGSize(width: 760, height: 620), CGSize(width: 320, height: 420)] {
            let compact = CGSize(width: 56, height: 32)
            let canvas = CGRect(origin: .zero, size: size)
                .insetBy(dx: -PanelSurfacePose.canvasInset, dy: -PanelSurfacePose.canvasInset)
            XCTAssertEqual(PanelExpansionTrajectory.pose(at: 0, size: size, compactSize: compact),
                           .compact(size: size, compactSize: compact))
            XCTAssertEqual(PanelExpansionTrajectory.pose(at: 0.64, size: size, compactSize: compact),
                           .expanded(size: size))
            var maximumWidth: CGFloat = 0
            for tick in 0...640 {
                let pose = PanelExpansionTrajectory.pose(at: Double(tick) / 1000, size: size, compactSize: compact)
                XCTAssertTrue(canvas.contains(pose.frame), "Surface clipped at \(tick) ms: \(pose.frame)")
                XCTAssertGreaterThan(pose.frame.width, 0)
                XCTAssertGreaterThan(pose.frame.height, 0)
                XCTAssertGreaterThan(pose.cornerRadius, 0)
                XCTAssertLessThanOrEqual(pose.cornerRadius, min(pose.frame.width, pose.frame.height) / 2)
                maximumWidth = max(maximumWidth, pose.frame.width)
            }
            XCTAssertEqual(maximumWidth / size.width, 1.027, accuracy: 0.001)
        }
    }

    func testReferenceExpansionPassesThroughRoundedMovingSurfaceAndSettlesGently() {
        let size = CGSize(width: 760, height: 620)
        let compact = CGSize(width: 56, height: 32)
        let bubble = PanelExpansionTrajectory.pose(at: 0.13, size: size, compactSize: compact)
        XCTAssertLessThan(bubble.frame.maxX, size.width)
        XCTAssertGreaterThan(bubble.frame.minY, 0)
        XCTAssertEqual(bubble.cornerRadius, min(bubble.frame.width, bubble.frame.height) / 2, accuracy: 0.001)
        let before = PanelExpansionTrajectory.pose(at: 0.63999, size: size, compactSize: compact)
        let end = PanelExpansionTrajectory.pose(at: 0.64, size: size, compactSize: compact)
        for (a, b) in zip(before.components, end.components) {
            XCTAssertEqual(a, b, accuracy: 0.0001)
            XCTAssertEqual((b - a) / 0.00001, 0, accuracy: 0.05)
        }
    }

    func testReferenceContentBecomesReadableBeforeTheSurfaceFinishesSettling() {
        let early = PanelExpansionTrajectory.content(at: 0.13)
        let entering = PanelExpansionTrajectory.content(at: 0.25)
        let readable = PanelExpansionTrajectory.content(at: 0.39)
        XCTAssertEqual(early.opacity, 0)
        XCTAssertGreaterThan(entering.opacity, 0)
        XCTAssertLessThan(entering.opacity, 1)
        XCTAssertGreaterThan(entering.blur, 0)
        XCTAssertEqual(
            PanelExpansionTrajectory.content(at: PanelExpansionTrajectory.blurRevealEnd).blur,
            PanelExpansionTrajectory.settledBlurFloor,
            accuracy: 0.000001
        )
        XCTAssertEqual(PanelExpansionTrajectory.content(at: PanelExpansionTrajectory.duration).blur, 0)
        XCTAssertLessThan(PanelExpansionTrajectory.blurRevealEnd, PanelExpansionTrajectory.contentRevealEnd)
        XCTAssertLessThan(PanelExpansionTrajectory.contentRevealEnd, PanelExpansionTrajectory.growthDuration)
        XCTAssertEqual(readable.opacity, PanelExpansionTrajectory.settledOpacityCeiling)
        XCTAssertEqual(readable.blur, PanelExpansionTrajectory.settledBlurFloor)
        XCTAssertEqual(readable.scale, PanelExpansionTrajectory.settledScaleFloor)
        XCTAssertEqual(readable.offset, PanelExpansionTrajectory.settledOffsetFloor)
        let endpoint = PanelExpansionTrajectory.content(at: PanelExpansionTrajectory.duration)
        XCTAssertEqual(endpoint.opacity, 1)
        XCTAssertEqual(endpoint.blur, 0)
        XCTAssertEqual(endpoint.scale, 1)
        XCTAssertEqual(endpoint.offset, 0)
        XCTAssertLessThan(0.39, PanelExpansionTrajectory.duration)
    }

    func testPhaseControlsSurfaceAndContentLayers() {
        XCTAssertTrue(PanelMotionPhase.compact.showsCompactSurface)
        XCTAssertTrue(PanelMotionPhase.compact.keepsExpandedContentAlive)
        XCTAssertTrue(PanelMotionPhase.expanding.showsExpandedSurface)
        XCTAssertTrue(PanelMotionPhase.expanded.showsExpandedSurface)
        XCTAssertFalse(PanelMotionPhase.collapsing.showsCompactSurface)
        XCTAssertTrue(PanelMotionPhase.collapsing.isDismissing)
        XCTAssertFalse(PanelMotionPhase.departing.showsCompactSurface)
        XCTAssertFalse(PanelMotionPhase.hidden.keepsExpandedContentAlive)
    }

    func testStaleGenerationCannotCompleteCancelledTransition() {
        let model = PanelMotionModel()
        let collapseGeneration = model.beginTransition(to: .collapsing)
        let reverseGeneration = model.beginTransition(to: .expanding)

        XCTAssertFalse(model.transition(to: .hidden, generation: collapseGeneration))
        XCTAssertTrue(model.transition(to: .expanded, generation: reverseGeneration))
        XCTAssertEqual(model.phase, .expanded)
    }

    func testPinnedPanelCannotAutoDismiss() {
        XCTAssertFalse(
            PanelDismissalPolicy.permitsAutoDismiss(isEnabled: true, isPinned: true)
        )
        XCTAssertTrue(
            PanelDismissalPolicy.permitsAutoDismiss(isEnabled: true, isPinned: false)
        )
        XCTAssertFalse(
            PanelDismissalPolicy.permitsAutoDismiss(isEnabled: false, isPinned: false)
        )
    }

    func testHapticGateSuppressesFeedbackInsideCooldown() {
        let provider = HapticSpy()
        let gate = PanelHapticGate(provider: provider, cooldown: 0.25)

        XCTAssertTrue(gate.performIfAllowed(now: 10))
        XCTAssertFalse(gate.performIfAllowed(now: 10.249))
        XCTAssertTrue(gate.performIfAllowed(now: 10.25))
        XCTAssertEqual(provider.callCount, 2)
    }

    func testClosingReturnsToOpeningOriginWithoutASecondSpeedSurge() {
        for size in [CGSize(width: 760, height: 620), CGSize(width: 320, height: 420)] {
            for origin in [CGPoint.zero, CGPoint(x: -1440, y: 900)] {
                let screen = CGRect(origin: origin, size: CGSize(width: 1440, height: 900))
                let resting = CGRect(x: screen.maxX - size.width - 12,
                                     y: screen.maxY - 36 - size.height,
                                     width: size.width, height: size.height).insetBy(dx: -24, dy: -24)
                let compact = CGSize(width: 56, height: 32)
                let entry = PanelCollapseTrajectory.offscreenFrame(from: resting, screenFrame: screen,
                                                                   compactSize: compact)
                XCTAssertEqual(entry, PanelMotionGeometry.offscreenFrame(from: resting, screenFrame: screen,
                    compactSize: compact, margin: 8 + PanelSurfacePose.canvasInset))
                func screenContour(_ pose: PanelSurfacePose, displacement: CGFloat) -> CGRect {
                    CGRect(x: resting.minX + (entry.minX - resting.minX) * displacement + 24 + pose.frame.minX,
                           y: resting.maxY + (entry.maxY - resting.maxY) * displacement - 24 - pose.frame.maxY,
                           width: pose.frame.width, height: pose.frame.height)
                }
                var previous = screenContour(.expanded(size: size), displacement: 0)
                var previousSpeed: CGFloat = 0
                var passedSpeedPeak = false
                for tick in 0...Int(PanelCollapseTrajectory.duration * 1000) {
                    let time = Double(tick) / 1000
                    let leaving = PanelMotionTiming.departureCurve.progress(at:
                        (time - PanelCollapseTrajectory.departureStart) / PanelMotionTiming.departureDuration)
                    let closing = PanelCollapseTrajectory.pose(at: time, size: size, compactSize: compact)
                    let contour = screenContour(closing, displacement: leaving)
                    XCTAssertGreaterThanOrEqual(contour.minX + 0.000001, previous.minX)
                    XCTAssertGreaterThanOrEqual(contour.minY + 0.000001, previous.minY)
                    let speed = hypot(contour.midX - previous.midX, contour.midY - previous.midY) * 1000
                    if speed < previousSpeed - 1 { passedSpeedPeak = true }
                    if passedSpeedPeak {
                        XCTAssertLessThanOrEqual(speed, previousSpeed + 1,
                                                 "A second speed surge at \(tick) ms splits rounding from exit")
                    }
                    previousSpeed = speed
                    previous = contour
                }
                XCTAssertTrue(passedSpeedPeak)
                let endpoint = PanelCollapseTrajectory.pose(at: PanelCollapseTrajectory.duration,
                                                           size: size, compactSize: compact)
                XCTAssertFalse(screen.intersects(screenContour(endpoint, displacement: 1)))
                let circleTime = PanelCollapseTrajectory.circularizationTime
                let circlePose = PanelCollapseTrajectory.pose(at: circleTime, size: size, compactSize: compact)
                let circleProgress = PanelMotionTiming.departureCurve.progress(at:
                    (circleTime - PanelCollapseTrajectory.departureStart) / PanelMotionTiming.departureDuration)
                XCTAssertTrue(screen.intersects(screenContour(circlePose, displacement: circleProgress)))
                let exitTime = PanelCollapseTrajectory.surfaceFadeEnd
                let exitPose = PanelCollapseTrajectory.pose(at: exitTime, size: size, compactSize: compact)
                XCTAssertEqual(exitPose.frame.width, exitPose.frame.height, accuracy: 0.000001)
            }
        }
    }

    func testDepartureAcceleratesBeforeRoundingFinishesOnTheSameDeadline() {
        XCTAssertEqual(PanelCollapseTrajectory.duration, 0.32)
        XCTAssertEqual(PanelCollapseTrajectory.surfaceFadeEnd, 0.288, accuracy: 0.000001)
        XCTAssertGreaterThan(PanelCollapseTrajectory.surfaceFadeEnd, PanelCollapseTrajectory.circularizationTime)
        let size = CGSize(width: 760, height: 620)
        let startingPose = PanelCollapseTrajectory.pose(at: PanelCollapseTrajectory.departureStart,
                                                       size: size, compactSize: CGSize(width: 56, height: 32))
        XCTAssertLessThan(startingPose.cornerRadius, min(startingPose.frame.width, startingPose.frame.height) / 2)
        XCTAssertEqual(PanelMotionTiming.departureDuration + PanelCollapseTrajectory.departureStart,
                       PanelCollapseTrajectory.duration, accuracy: 0.000001)
        let curve = PanelMotionTiming.departureCurve
        let firstQuarter = curve.progress(at: 0.25)
        let secondQuarter = curve.progress(at: 0.50) - curve.progress(at: 0.25)
        let thirdQuarter = curve.progress(at: 0.75) - curve.progress(at: 0.50)
        let finalQuarter = 1 - curve.progress(at: 0.75)
        XCTAssertGreaterThan(secondQuarter, firstQuarter)
        XCTAssertGreaterThan(thirdQuarter, secondQuarter)
        XCTAssertGreaterThan(finalQuarter, thirdQuarter)
    }

    func testDeparturePlacesEntireCompactSurfaceBeyondUpperRightCorner() {
        let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let resting = NSRect(x: 668, y: 268, width: 760, height: 620)
        let compact = NSSize(width: 56, height: 32)

        let departure = PanelMotionGeometry.offscreenFrame(
            from: resting,
            screenFrame: screen,
            compactSize: compact
        )
        let compactSurface = NSRect(
            x: departure.maxX - compact.width,
            y: departure.maxY - compact.height,
            width: compact.width,
            height: compact.height
        )

        XCTAssertGreaterThan(compactSurface.minX, screen.maxX)
        XCTAssertGreaterThan(compactSurface.minY, screen.maxY)
    }

    func testTimingKeepsOpeningOrderAndSharedClosingDeadline() {
        XCTAssertLessThan(
            PanelMotionTiming.expansionWidthDelay,
            PanelMotionTiming.toolbarRevealTime
        )
        XCTAssertLessThan(
            PanelMotionTiming.toolbarRevealTime,
            PanelMotionTiming.gridRevealTime
        )
        XCTAssertLessThanOrEqual(
            PanelMotionTiming.gridRevealTime + PanelMotionTiming.gridRevealDuration,
            PanelExpansionTrajectory.contentRevealEnd
        )
        XCTAssertEqual(
            PanelMotionTiming.departureDelay + PanelMotionTiming.departureDuration,
            PanelMotionTiming.departureVisibleCompletion,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PanelMotionTiming.departureVisibleCompletion,
            PanelCollapseTrajectory.duration,
            accuracy: 0.000_001
        )
    }

    func testSharedAnimationClockPreservesExistingDurations() {
        XCTAssertEqual(CalendarAnimationClock.zoomDuration, 0.50, accuracy: 0.000_001)
        XCTAssertEqual(CalendarAnimationClock.periodDuration, 0.48, accuracy: 0.000_001)
        XCTAssertEqual(CalendarAnimationClock.detailSwitchDuration, 0.34, accuracy: 0.000_001)
    }
}

private final class HapticSpy: PanelHapticProviding {
    private(set) var callCount = 0

    func performTransitionFeedback() {
        callCount += 1
    }
}

@MainActor
private final class PanelSurfaceRecorder: PanelSurfaceRendering {
    var pose: PanelSurfacePose?
    func applySurface(_ pose: PanelSurfacePose) { self.pose = pose }
}
