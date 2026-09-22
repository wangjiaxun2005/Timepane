import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class PanelCoordinator: NSObject, NSWindowDelegate {
    private struct ScreenGeometry {
        let id: UInt32
        let screen: NSScreen
        let frame: NSRect
        let hotZoneFrame: NSRect
    }

    private enum MouseSemanticRegion: Equatable {
        case hiddenOutside(UInt32?)
        case hiddenHotCorner(UInt32)
        case visibleInside
        case visibleOutside
    }

    private let model: AppModel
    private let motion = PanelMotionModel()
    private let haptics: PanelHapticGate
    private let morphLayers: PanelMorphLayerCoordinator

    private let panelSize = NSSize(width: 760, height: 620)
    private let compactSize = NSSize(width: 56, height: 32)
    private let hotCornerSize: CGFloat = 12
    private let hotCornerOverscan: CGFloat = 8
    private let hotCornerCaptureSize: CGFloat = 8
    private let panelEntryGracePeriod: TimeInterval = 0.8
    private let panelExitDelay: TimeInterval = 0.1
    private let mouseEvaluationInterval: TimeInterval = 1.0 / 60.0
    private let shadowRefreshInterval: TimeInterval = 1.0 / 60.0

    private lazy var eventWindow = EventCreationWindowCoordinator(model: model)
    private var panelWindow: FloatingPanel?
    private var hotCornerCapturePanels: [UInt32: HotCornerCapturePanel] = [:]
    private var currentScreen: NSScreen?
    private var restingPanelFrame: NSRect?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var localCalendarSwipeMonitor: Any?
    private var globalOutsideClickMonitor: Any?
    private var localOutsideClickMonitor: Any?
    private var calendarSwipeTracker = CalendarSwipeTracker()
    private var mouseEvaluationWorkItem: DispatchWorkItem?
    private var latestMouseLocation = NSPoint.zero
    private var lastMouseEvaluationUptime: TimeInterval = 0
    private var screenObserver: NSObjectProtocol?
    private var revealActivity: NSObjectProtocol?
    private var hideWorkItem: DispatchWorkItem?
    private var transitionWorkItems: [DispatchWorkItem] = []
    private var autoDismissOnMouseExit = false
    private var panelPresentedAtUptime: TimeInterval?
    private var screenGeometries: [ScreenGeometry] = []
    private var screenGeometryByID: [UInt32: ScreenGeometry] = [:]
    private var lastMouseSemanticRegion: MouseSemanticRegion?
    private var panelTraceToken: CalendarAnimationTraceToken?
    private var shadowRefreshSource: DispatchSourceTimer?
    #if DEBUG
    private var motionPreviewMonitor: Any?
    private var motionPreviewTime: TimeInterval = 0.21
    private var motionPreviewIsClosing = false
    private var motionPreviewClosingDiagnostics = ""
    #endif

    init(
        model: AppModel,
        hapticProvider: PanelHapticProviding = SystemPanelHapticProvider()
    ) {
        self.model = model
        haptics = PanelHapticGate(provider: hapticProvider)
        morphLayers = PanelMorphLayerCoordinator(compactSize: CGSize(width: 56, height: 32), motion: motion)
        super.init()
        refreshScreenGeometries()
    }

    deinit {
        shadowRefreshSource?.cancel()
        mouseEvaluationWorkItem?.cancel()
        if let revealActivity {
            ProcessInfo.processInfo.endActivity(revealActivity)
        }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let localCalendarSwipeMonitor { NSEvent.removeMonitor(localCalendarSwipeMonitor) }
        if let globalOutsideClickMonitor { NSEvent.removeMonitor(globalOutsideClickMonitor) }
        if let localOutsideClickMonitor { NSEvent.removeMonitor(localOutsideClickMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        #if DEBUG
        if let motionPreviewMonitor { NSEvent.removeMonitor(motionPreviewMonitor) }
        #endif
    }

    func start() {
        globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    _ = self?.handleMouseDown(event, at: NSEvent.mouseLocation, window: nil)
                }
            }
        localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    self?.handleMouseDown(event, at: NSEvent.mouseLocation, window: event.window) ?? false
                }
                return consumed ? nil : event
            }
        model.onEventCreationRequested = { [weak self] in
            guard let self, let panel = self.panelWindow else { return }
            self.cancelPendingHide()
            self.eventWindow.attach(to: panel)
            self.bringPanelForward(panel, makeKey: true)
        }
        refreshScreenGeometries()
        rebuildHotCornerCapturePanels()
        let mouseEvents: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged
        ]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.queueMouseEvaluation(at: NSEvent.mouseLocation)
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            MainActor.assumeIsolated {
                self?.queueMouseEvaluation(at: NSEvent.mouseLocation)
            }
            return event
        }
        localCalendarSwipeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .swipe]
        ) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                self?.handleCalendarSwipe(event) ?? false
            }
            return handled ? nil : event
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repositionForScreenChanges()
            }
        }
    }

    @discardableResult
    private func handleMouseDown(_ event: NSEvent, at point: CGPoint, window: NSWindow?) -> Bool {
        if event.type == .leftMouseDown,
           panelWindow?.isVisible != true,
           let capturePanel = window as? HotCornerCapturePanel,
           let geometry = screenGeometryByID[capturePanel.displayID] {
            preparePanelReveal(on: geometry.screen)
            showPanel(on: geometry.screen, autoDismissOnMouseExit: true)
            return true
        }
        handleOutsideClick(at: point, window: window)
        return false
    }

    private func handleOutsideClick(at point: CGPoint, window: NSWindow?) {
        guard model.eventCreation.isActive, !model.eventCreation.isSuspended,
              !model.isPinned, let panel = panelWindow, panel.isVisible,
              !motion.phase.isDismissing, NSApp.modalWindow == nil else { return }
        // Native date/calendar menus and sheets are separate app-owned windows.
        if let window, window !== panel, !eventWindow.ownsWindow(window) { return }
        let calendarBody = panel.frame.insetBy(dx: PanelSurfacePose.canvasInset,
                                              dy: PanelSurfacePose.canvasInset)
        guard !calendarBody.contains(point), !eventWindow.containsEditorPoint(point) else { return }
        hidePanel()
    }

    func screenUnderMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return screenGeometry(containing: point)?.screen ?? NSScreen.main
    }

    #if DEBUG
    /// Reuses the production surface/content samplers to inspect real native
    /// glass at a fixed time. It does not replace the normal playback path.
    func enableMotionPreview() {
        model.isPinned = true
        showMotionPreview()
        motionPreviewMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.panelWindow else { return false }
                switch event.keyCode {
                case 123: self.motionPreviewTime = max(0, self.motionPreviewTime - 1.0 / 60)
                case 124:
                    self.motionPreviewTime = min(self.motionPreviewIsClosing ? PanelCollapseTrajectory.duration
                        : PanelExpansionTrajectory.duration, self.motionPreviewTime + 1.0 / 60)
                case 49:
                    self.panelWindow?.title = "Timepane · Live motion"
                    self.panelWindow?.orderOut(nil)
                    self.showPanel(on: self.currentScreen)
                    return true
                default:
                    let key = event.charactersIgnoringModifiers ?? ""
                    if key == "c" || key == "o" {
                        self.motionPreviewIsClosing = key == "c"
                        self.motionPreviewTime = key == "c" ? 0.095 : 0.21
                        self.showMotionPreview()
                        return true
                    }
                    if key == "x" || key == "r" || key == "d" {
                        self.hidePanel(clearPin: true)
                        self.model.isPinned = true
                        if key != "x" {
                            self.scheduleTransition(after: key == "r" ? 0.096 : 0.208,
                                                    generation: self.motion.generation) { [weak self] in
                                guard let self else { return }
                                self.model.isPinned = true
                                self.showPanel(on: self.currentScreen)
                            }
                        }
                        return true
                    }
                    let checkpoints: [String: TimeInterval] = self.motionPreviewIsClosing
                        ? ["1": 0.028, "2": 0.060, "3": 0.096, "4": 0.136,
                           "5": 0.16, "6": 0.192, "7": 0.216, "8": PanelCollapseTrajectory.duration]
                        : ["1": 0.045, "2": 0.13, "3": 0.21, "4": 0.29,
                           "5": 0.37, "6": 0.46, "7": 0.55, "8": 0.64]
                    guard let time = checkpoints[key] else { return false }
                    self.motionPreviewTime = time
                }
                self.showMotionPreview()
                return true
            }
            return handled ? nil : event
        }
    }

    private func showMotionPreview() {
        guard let screen = currentScreen ?? screenUnderMouse() else { return }
        currentScreen = screen
        cancelTransitionWorkItems()
        cancelPendingHide()
        let panel = panelWindow ?? makePanelWindow()
        panelWindow = panel
        let frame = panelFrame(on: screen)
        restingPanelFrame = frame
        panel.setFrame(frame, display: false)
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            _ = motion.beginTransition(to: motionPreviewIsClosing ? .collapsing : .expanding)
            motion.setExpansionTime(motionPreviewIsClosing ? PanelExpansionTrajectory.duration : motionPreviewTime)
            motion.setCollapseTime(motionPreviewIsClosing ? motionPreviewTime : 0)
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        if motionPreviewIsClosing { morphLayers.previewCollapse(at: motionPreviewTime) }
        else { morphLayers.previewExpansion(at: motionPreviewTime) }
        panel.invalidateShadow()
        panel.title = "Timepane · \(motionPreviewIsClosing ? "Close" : "Open") \(Int((motionPreviewTime * 1000).rounded())) ms"
        bringPanelForward(panel, makeKey: true)
    }
    #endif

    private func handleCalendarSwipe(_ event: NSEvent) -> Bool {
        guard panelWindow?.isVisible == true,
              !model.eventCreation.isActive,
              event.window === panelWindow,
              model.route == .calendar,
              motion.phase == .expanded else {
            calendarSwipeTracker.reset()
            return false
        }

        let weekOffset: Int?
        if event.type == .swipe {
            weekOffset = calendarSwipeTracker.consumeDiscreteSwipe(
                horizontal: event.deltaX,
                timestamp: event.timestamp
            )
        } else {
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            // Scroll-wheel deltas describe content scrolling, opposite to the
            // physical finger direction used by discrete swipe events.
            let horizontal = CalendarSwipeTracker.fingerDelta(
                fromScrollingDelta: event.scrollingDeltaX
            ) * scale
            let vertical = event.scrollingDeltaY * scale
            let isHorizontalGesture = CalendarSwipeTracker.isHorizontalGesture(
                horizontal: horizontal,
                vertical: vertical
            )
            weekOffset = calendarSwipeTracker.consumeScroll(
                horizontal: horizontal,
                vertical: vertical,
                timestamp: event.timestamp,
                began: event.phase.contains(.began),
                hasPhase: !event.phase.isEmpty,
                isMomentum: !event.momentumPhase.isEmpty
            )
            if let weekOffset {
                model.interaction.submit(.movePeriod(weekOffset))
            }
            // Keep recognized horizontal streams out of SwiftUI. This avoids
            // redispatching every momentum event through the full calendar tree.
            return isHorizontalGesture
        }

        guard let weekOffset else { return false }
        model.interaction.submit(.movePeriod(weekOffset))
        return true
    }

    func showPanel(on screen: NSScreen?, autoDismissOnMouseExit: Bool = false) {
        guard let screen = screen ?? screenUnderMouse() ?? NSScreen.main else { return }

        if panelWindow?.isVisible == true {
            self.autoDismissOnMouseExit = autoDismissOnMouseExit || self.autoDismissOnMouseExit
            if motion.phase.isDismissing {
                reverseDismissal(on: screen)
            }
            return
        }

        currentScreen = screen
        lastMouseSemanticRegion = nil
        endRevealActivity()
        setHotCornerCapturePanelsActive(false)
        cancelPendingHide()
        cancelTransitionWorkItems()
        self.autoDismissOnMouseExit = autoDismissOnMouseExit
        panelPresentedAtUptime = CACurrentMediaTime()

        let panel = panelWindow ?? makePanelWindow()
        panelWindow = panel
        let finalFrame = panelFrame(on: screen)
        restingPanelFrame = finalFrame
        panel.ignoresMouseEvents = true

        haptics.performIfAllowed()

        if reducedMotion {
            let generation = motion.beginTransition(to: .expanded)
            beginPanelTrace(.panelExpansion, generation: generation)
            panel.setFrame(finalFrame, display: false)
            panel.contentView?.layoutSubtreeIfNeeded()
            eventWindow.prepareIdleToolbarForParentReveal()
            if model.eventCreation.isSuspended {
                eventWindow.prepareForParentExpansion()
            }
            bringPanelForward(panel, makeKey: true)
            finishShowing(panel, generation: generation)
            return
        }

        let generation = motion.beginTransition(to: .compact)
        motion.setExpansionTime(0)
        motion.setCollapseTime(0)
        beginPanelTrace(.panelExpansion, generation: generation)
        // Lay out once at the resting size. The entry frame only changes the
        // screen origin; it does not require another whole-calendar layout.
        panel.setFrame(finalFrame, display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        eventWindow.prepareIdleToolbarForParentReveal()
        if model.eventCreation.isSuspended {
            // Embed the retained editor into calendar content before its first
            // animated frame so both share the same blur and clipping.
            eventWindow.prepareForParentExpansion()
        }
        let entryFrame = PanelMotionGeometry.offscreenFrame(
            from: finalFrame,
            screenFrame: screen.frame,
            compactSize: compactSize,
            margin: 8 + PanelSurfacePose.canvasInset
        )
        panel.setFrame(entryFrame, display: false)
        panel.alphaValue = 1
        morphLayers.prepareCompact(on: panel)
        bringPanelForward(panel, makeKey: true)
        morphLayers.beginExpansion(on: panel, targetFrame: finalFrame) { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.finishShowing(panel, generation: generation)
        }
        // Content reaches imperceptibly non-identity values at 320 ms, so its
        // SwiftUI clock can stop without tearing down the compositing layer.
        // The native shell continues independently through its 640 ms settling
        // tail; finishShowing commits the exact content endpoint afterward.
        withAnimation(.linear(duration: PanelExpansionTrajectory.contentRevealEnd)) {
            motion.setExpansionTime(PanelExpansionTrajectory.contentRevealEnd)
        }
        startShadowRefresh(
            for: panel,
            duration: PanelMotionTiming.expansionCompletionDelay,
            generation: generation
        )

        scheduleTransition(
            after: PanelMotionTiming.expansionWidthDelay,
            generation: generation
        ) { [weak self] in
            guard let self else { return }
            // Geometry is driven by PanelMorphLayerCoordinator. Phase-scoped
            // content animations remain explicit at their views.
            _ = self.motion.transition(to: .expanding, generation: generation)
        }

    }

    private func makePanelWindow() -> FloatingPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: panelSize)
                .insetBy(dx: -PanelSurfacePose.canvasInset, dy: -PanelSurfacePose.canvasInset),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = model.isPinned ? .statusBar : .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.cancelEditor = { [weak model] in
            guard let creation = model?.eventCreation, creation.isActive else { return false }
            creation.requestCancel()
            return true
        }

        let rootView = PanelMotionHost(
            model: model,
            motion: motion,
            onCollapse: { [weak self] in self?.hidePanel(clearPin: true) },
            onTogglePin: { [weak self] in self?.togglePin() },
            onQuit: { NSApp.terminate(nil) }
        )
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        // The morph mask belongs to an AppKit canvas whose bounds are stable,
        // independent of SwiftUI's expanding blur/render bounds.
        let containerController = NSViewController()
        let canvas = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.clear.cgColor
        containerController.view = canvas
        containerController.addChild(hostingController)
        hostingController.view.frame = canvas.bounds
        hostingController.view.autoresizingMask = [.width, .height]
        let backgroundController = NSHostingController(rootView: PanelGlassBackground(motion: motion))
        containerController.addChild(backgroundController)
        backgroundController.view.frame = canvas.bounds
        backgroundController.view.autoresizingMask = [.width, .height]
        canvas.addSubview(backgroundController.view)
        // A native foreground container keeps closing transforms out of SwiftUI's
        // animation clock and leaves the live glass outside the content transform.
        let foreground = NSView(frame: canvas.bounds)
        foreground.wantsLayer = true
        foreground.autoresizingMask = [.width, .height]
        foreground.addSubview(hostingController.view)
        canvas.addSubview(foreground)
        panel.contentViewController = containerController
        morphLayers.install(on: panel, contentView: canvas, foregroundView: foreground)
        eventWindow.attach(to: panel)
        return panel
    }

    private func togglePin() {
        model.isPinned.toggle()
        guard let panel = panelWindow else { return }
        panel.level = model.isPinned ? .statusBar : .floating
        panel.orderFrontRegardless()
        if model.isPinned {
            cancelPendingHide()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
        }
    }

    private func hidePanel(clearPin: Bool = false) {
        guard let panel = panelWindow, panel.isVisible else { return }
        guard !model.isPinned || clearPin else { return }
        if model.eventCreation.isActive, !model.eventCreation.isSuspended,
           !eventWindow.suspendWithParent() { cancelPendingHide(); return }
        cancelPendingHide()
        cancelTransitionWorkItems()
        if clearPin { autoDismissOnMouseExit = false }
        panelPresentedAtUptime = nil
        if clearPin { model.isPinned = false }

        panel.ignoresMouseEvents = true
        haptics.performIfAllowed()

        if reducedMotion {
            let generation = motion.beginTransition(to: .departing)
            beginPanelTrace(.panelCollapse, generation: generation)
            finishHiding(panel, generation: generation)
            return
        }

        let generation = motion.beginTransition(to: .collapsing)
        beginPanelTrace(.panelCollapse, generation: generation)
        // Content stays mounted at its existing size. Native layer transforms
        // drive collapse; forcing SwiftUI layout here delays the first frame.
        let destination = (panel.screen ?? currentScreen).flatMap { screen in
            restingPanelFrame.map { frame in
                PanelCollapseTrajectory.offscreenFrame(from: frame, screenFrame: screen.frame,
                    compactSize: compactSize)
            }
        }
        morphLayers.beginCollapse(on: panel, targetFrame: destination, onDeparture: { [weak self] in
            guard let self else { return }
            _ = self.motion.transition(to: .departing, generation: generation)
        }, completion: { [weak self, weak panel] in
            guard let self, let panel, generation == self.motion.generation else { return }
            self.finishHiding(panel, generation: generation)
        })
        startShadowRefresh(
            for: panel,
            duration: PanelMotionTiming.departureVisibleCompletion,
            generation: generation
        )

    }

    private func reverseDismissal(on screen: NSScreen?) {
        guard let panel = panelWindow,
              panel.isVisible,
              motion.phase.isDismissing else { return }

        cancelPendingHide()
        cancelTransitionWorkItems()
        if let screen { currentScreen = screen }
        let finalFrame = restingPanelFrame
            ?? currentScreen.map(panelFrame(on:))
            ?? panel.frame
        restingPanelFrame = finalFrame
        autoDismissOnMouseExit = true
        panelPresentedAtUptime = CACurrentMediaTime()
        panel.ignoresMouseEvents = true
        haptics.performIfAllowed()

        if reducedMotion {
            let generation = motion.beginTransition(to: .expanded)
            beginPanelTrace(.panelExpansion, generation: generation)
            panel.setFrame(finalFrame, display: true)
            finishShowing(panel, generation: generation)
            return
        }

        let generation = motion.beginTransition(to: .expanding)
        beginPanelTrace(.panelExpansion, generation: generation)
        morphLayers.beginExpansion(on: panel, targetFrame: finalFrame, reversing: true) { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.finishShowing(panel, generation: generation)
        }
        startShadowRefresh(
            for: panel,
            duration: PanelMotionTiming.expansionCompletionDelay,
            generation: generation
        )
    }

    private func bringPanelForward(_ panel: NSPanel, makeKey: Bool) {
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        if makeKey { panel.makeKey() }
    }

    private func finishShowing(_ panel: NSPanel, generation: Int) {
        guard generation == motion.generation else { return }
        stopShadowRefresh()
        _ = motion.transition(to: .expanded, generation: generation)
        motion.setExpansionTime(PanelExpansionTrajectory.duration)
        motion.setCollapseTime(0)
        if let restingPanelFrame {
            panel.setFrame(restingPanelFrame, display: true)
        }
        panel.alphaValue = 1
        morphLayers.finishExpanded(on: panel)
        panel.ignoresMouseEvents = false
        if model.eventCreation.isSuspended {
            eventWindow.resumeWithParent()
        } else {
            panel.makeKey()
        }
        #if DEBUG
        if motionPreviewMonitor != nil {
            panel.title = "Timepane · Open \(morphLayers.playbackDiagnostics) · Last close \(motionPreviewClosingDiagnostics)"
        }
        #endif
        finishPanelTrace(generation: generation)
    }

    private func finishHiding(_ panel: NSPanel, generation: Int) {
        guard generation == motion.generation else { return }
        #if DEBUG
        if motionPreviewMonitor != nil {
            motionPreviewClosingDiagnostics = morphLayers.playbackDiagnostics
        }
        #endif
        stopShadowRefresh()
        morphLayers.finishHidden(on: panel)
        panel.orderOut(nil)
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        autoDismissOnMouseExit = false
        lastMouseSemanticRegion = nil
        _ = motion.transition(to: .hidden, generation: generation)
        motion.setExpansionTime(0)
        motion.setCollapseTime(0)
        if !model.eventCreation.isSuspended { resetPanelContentAfterHiding() }
        setHotCornerCapturePanelsActive(true)
        finishPanelTrace(generation: generation)
    }

    private func beginPanelTrace(
        _ kind: CalendarAnimationTraceKind,
        generation: Int
    ) {
        CalendarAnimationTrace.end(panelTraceToken, outcome: "superseded")
        panelTraceToken = CalendarAnimationTrace.begin(kind, generation: generation)
    }

    private func finishPanelTrace(generation: Int) {
        guard panelTraceToken?.generation == generation else { return }
        CalendarAnimationTrace.end(panelTraceToken)
        panelTraceToken = nil
    }

    private func scheduleTransition(
        after delay: TimeInterval,
        generation: Int,
        action: @escaping @MainActor () -> Void
    ) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, generation == self.motion.generation else { return }
            action()
        }
        transitionWorkItems.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startShadowRefresh(
        for panel: NSPanel,
        duration: TimeInterval,
        generation: Int
    ) {
        stopShadowRefresh()
        panel.hasShadow = true
        panel.invalidateShadow()

        let startTime = CACurrentMediaTime()
        let isExpansion = abs(duration - PanelMotionTiming.expansionCompletionDelay) < 0.000_001
        // By 270 ms the opening surface is already close enough to its final size
        // that further soft-shadow rasterization is visually redundant. Stop it
        // before the late growth frames; finishExpanded installs the exact final
        // shadow after all movement. Mask, glass and content remain display-linked.
        let refreshDuration = isExpansion ? min(duration, 0.27) : duration
        let deadline = startTime + refreshDuration
        let refreshInterval = isExpansion ? 1.0 / 30.0 : shadowRefreshInterval
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(
            deadline: .now() + refreshInterval,
            repeating: refreshInterval,
            leeway: .milliseconds(2)
        )
        source.setEventHandler { [weak self, weak panel] in
            MainActor.assumeIsolated {
                guard let self,
                      let panel,
                      generation == self.motion.generation,
                      CACurrentMediaTime() < deadline else {
                    self?.stopShadowRefresh()
                    return
                }
                panel.invalidateShadow()
            }
        }
        shadowRefreshSource = source
        source.resume()
    }

    private func stopShadowRefresh() {
        shadowRefreshSource?.cancel()
        shadowRefreshSource = nil
    }

    private func cancelTransitionWorkItems() {
        stopShadowRefresh()
        transitionWorkItems.forEach { $0.cancel() }
        transitionWorkItems.removeAll()
    }

    private func resetPanelContentAfterHiding() {
        model.interaction.reset()
        model.selectedEvent = nil
        if model.route != .welcome {
            model.route = .calendar
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let panel = panelWindow,
              let window = notification.object as? NSWindow,
              window === panel,
              !model.isPinned,
              !model.eventCreation.isActive,
              model.authorization != .requesting,
              motion.phase == .expanded else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard self?.model.isPinned == false else { return }
            self?.hidePanel()
        }
    }

    private func evaluateMouse(at point: NSPoint) {
        if panelWindow?.isVisible == true {
            endRevealActivity()
            evaluatePanelDismissal(at: point)
            return
        }
        guard let geometry = screenGeometry(containing: point) else {
            let region = MouseSemanticRegion.hiddenOutside(nil)
            guard region != lastMouseSemanticRegion else { return }
            lastMouseSemanticRegion = region
            cancelPanelRevealPreparation()
            return
        }

        if geometry.hotZoneFrame.contains(point) {
            let region = MouseSemanticRegion.hiddenHotCorner(geometry.id)
            guard region != lastMouseSemanticRegion else { return }
            lastMouseSemanticRegion = region
            preparePanelReveal(on: geometry.screen)
        } else {
            let region = MouseSemanticRegion.hiddenOutside(geometry.id)
            guard region != lastMouseSemanticRegion else { return }
            lastMouseSemanticRegion = region
            cancelPanelRevealPreparation()
        }
    }

    private func queueMouseEvaluation(at point: NSPoint) {
        latestMouseLocation = point
        guard mouseEvaluationWorkItem == nil else { return }

        let now = CACurrentMediaTime()
        let delay = max(0, mouseEvaluationInterval - (now - lastMouseEvaluationUptime))
        guard delay > 0 else {
            lastMouseEvaluationUptime = now
            evaluateMouse(at: point)
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.mouseEvaluationWorkItem = nil
            self.lastMouseEvaluationUptime = CACurrentMediaTime()
            self.evaluateMouse(at: self.latestMouseLocation)
        }
        mouseEvaluationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func preparePanelReveal(on screen: NSScreen) {
        beginRevealActivity()

        currentScreen = screen
        let panel = panelWindow ?? makePanelWindow()
        panelWindow = panel
        let finalFrame = panelFrame(on: screen)
        restingPanelFrame = finalFrame
        panel.setFrame(finalFrame, display: false)
        panel.ignoresMouseEvents = true

        if motion.phase == .hidden {
            _ = motion.beginTransition(to: .compact)
            motion.setExpansionTime(0)
            motion.setCollapseTime(0)
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        eventWindow.prepareIdleToolbarForParentReveal()
        morphLayers.prepareCompact(on: panel)
        panel.contentView?.displayIfNeeded()
    }

    private func evaluatePanelDismissal(at point: NSPoint) {
        if model.eventCreation.isActive {
            cancelPendingHide()
            lastMouseSemanticRegion = nil
            return
        }
        guard PanelDismissalPolicy.permitsAutoDismiss(
                isEnabled: autoDismissOnMouseExit,
                isPinned: model.isPinned
              ),
              let panel = panelWindow else {
            cancelPendingHide()
            return
        }

        let hoverInset = PanelSurfacePose.canvasInset - 8
        let hoverFrame = (restingPanelFrame ?? panel.frame).insetBy(dx: hoverInset, dy: hoverInset)
        let screen = currentScreen ?? panel.screen
        let isInHotCorner = screen.map { hotZoneFrame(on: $0).contains(point) } ?? false
        let isInside = hoverFrame.contains(point) || isInHotCorner

        if panelPresentedAtUptime.map({ CACurrentMediaTime() - $0 < panelEntryGracePeriod }) != true {
            let region: MouseSemanticRegion = isInside ? .visibleInside : .visibleOutside
            if region == lastMouseSemanticRegion {
                return
            }
            lastMouseSemanticRegion = region
        }

        if motion.phase.isDismissing {
            if isInside { reverseDismissal(on: screen) }
            return
        }

        guard motion.phase == .expanded else {
            cancelPendingHide()
            return
        }

        if let panelPresentedAtUptime,
           CACurrentMediaTime() - panelPresentedAtUptime < panelEntryGracePeriod {
            cancelPendingHide()
            return
        }

        if isInside {
            cancelPendingHide()
        } else {
            schedulePanelHide()
        }
    }

    private func schedulePanelHide() {
        guard hideWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.hideWorkItem = nil
            guard self?.model.isPinned == false else { return }
            self?.hidePanel()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + panelExitDelay, execute: work)
    }

    private func repositionForScreenChanges() {
        refreshScreenGeometries()
        rebuildHotCornerCapturePanels()
        lastMouseSemanticRegion = nil
        let validScreen = currentScreen.flatMap { current in
            screenID(for: current).flatMap { screenGeometryByID[$0]?.screen }
        } ?? screenUnderMouse() ?? NSScreen.main
        guard let validScreen else { return }
        currentScreen = validScreen

        let newFrame = panelFrame(on: validScreen)
        restingPanelFrame = newFrame
        if let panel = panelWindow, panel.isVisible, !motion.phase.isDismissing {
            panel.setFrame(newFrame, display: true, animate: false)
            morphLayers.updateStableGeometry(on: panel)
        }
    }

    private func panelFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let width = max(320, min(panelSize.width, visible.width - 24))
        let height = max(420, min(panelSize.height, visible.height - 24))
        return NSRect(
            x: visible.maxX - width - 12,
            y: visible.maxY - height,
            width: width,
            height: height
        )
        .insetBy(dx: -PanelSurfacePose.canvasInset, dy: -PanelSurfacePose.canvasInset)
    }

    private func hotZoneFrame(on screen: NSScreen) -> NSRect {
        if let id = screenID(for: screen),
           let cached = screenGeometryByID[id] {
            return cached.hotZoneFrame
        }
        return NSRect(
            x: screen.frame.maxX - hotCornerSize,
            y: screen.frame.maxY - hotCornerSize,
            width: hotCornerSize + hotCornerOverscan,
            height: hotCornerSize + hotCornerOverscan
        )
    }

    private func refreshScreenGeometries() {
        let geometries = NSScreen.screens.compactMap { screen -> ScreenGeometry? in
            guard let id = screenID(for: screen) else { return nil }
            let frame = screen.frame
            return ScreenGeometry(
                id: id,
                screen: screen,
                frame: frame,
                hotZoneFrame: NSRect(
                    x: frame.maxX - hotCornerSize,
                    y: frame.maxY - hotCornerSize,
                    width: hotCornerSize + hotCornerOverscan,
                    height: hotCornerSize + hotCornerOverscan
                )
            )
        }
        screenGeometries = geometries
        screenGeometryByID = Dictionary(uniqueKeysWithValues: geometries.map { ($0.id, $0) })
    }

    private func rebuildHotCornerCapturePanels() {
        let validIDs = Set(screenGeometries.map(\.id))
        let staleIDs = hotCornerCapturePanels.keys.filter { !validIDs.contains($0) }
        for id in staleIDs {
            hotCornerCapturePanels.removeValue(forKey: id)?.close()
        }

        for geometry in screenGeometries {
            let capturePanel: HotCornerCapturePanel
            if let existing = hotCornerCapturePanels[geometry.id] {
                capturePanel = existing
            } else {
                capturePanel = HotCornerCapturePanel(displayID: geometry.id) { [weak self] displayID in
                    guard let self,
                          self.panelWindow?.isVisible != true,
                          let geometry = self.screenGeometryByID[displayID] else { return }
                    self.preparePanelReveal(on: geometry.screen)
                    self.showPanel(on: geometry.screen, autoDismissOnMouseExit: true)
                }
                hotCornerCapturePanels[geometry.id] = capturePanel
            }
            capturePanel.setFrame(
                NSRect(
                    x: geometry.frame.maxX - hotCornerCaptureSize,
                    y: geometry.frame.maxY - hotCornerCaptureSize,
                    width: hotCornerCaptureSize,
                    height: hotCornerCaptureSize
                ),
                display: false
            )
        }
        setHotCornerCapturePanelsActive(panelWindow?.isVisible != true)
    }

    private func setHotCornerCapturePanelsActive(_ active: Bool) {
        for capturePanel in hotCornerCapturePanels.values {
            if active {
                capturePanel.orderFrontRegardless()
            } else {
                capturePanel.orderOut(nil)
            }
        }
    }

    private func screenGeometry(containing point: NSPoint) -> ScreenGeometry? {
        screenGeometries.first(where: { NSMouseInRect(point, $0.frame, false) })
    }

    private func screenID(for screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func cancelPanelRevealPreparation() {
        endRevealActivity()
        guard panelWindow?.isVisible != true, motion.phase == .compact else { return }
        _ = motion.beginTransition(to: .hidden)
        motion.setExpansionTime(0)
        motion.setCollapseTime(0)
    }

    private func beginRevealActivity() {
        guard revealActivity == nil else { return }
        revealActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Prepare the calendar while the pointer is in the reveal corner"
        )
    }

    private func endRevealActivity() {
        guard let revealActivity else { return }
        ProcessInfo.processInfo.endActivity(revealActivity)
        self.revealActivity = nil
    }

    private func cancelPendingHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    private var reducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

final class FloatingPanel: NSPanel {
    var cancelEditor: (() -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        if cancelEditor?() != true { super.cancelOperation(sender) }
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // The coordinator positions the visible surface below the menu bar.
        // Its transparent animation inset must be allowed above that boundary;
        // constraining the entire native window would push the surface down.
        frameRect
    }
}

final class HotCornerCapturePanel: NSPanel {
    let displayID: UInt32

    init(displayID: UInt32, onClick: @escaping @MainActor (UInt32) -> Void) {
        self.displayID = displayID
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        isMovable = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        level = .statusBar
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        contentView = HotCornerCaptureView { onClick(displayID) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class HotCornerCaptureView: NSView {
    private let onClick: @MainActor () -> Void

    init(onClick: @escaping @MainActor () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }
}
