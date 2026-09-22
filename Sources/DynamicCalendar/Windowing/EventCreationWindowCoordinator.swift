import AppKit
import QuartzCore
import SwiftUI

/// The live editor stays in the parent's content hierarchy, including while typing.
/// Its standalone fission uses one display-link clock and a fixed-size form.
@MainActor
final class EventCreationWindowCoordinator {
  @MainActor private final class DisplayLinkTarget: NSObject {
    weak var owner: EventCreationWindowCoordinator?
    @objc func update(_ link: CADisplayLink) { owner?.advance(link) }
  }
  private let model: AppModel
  private weak var parent: NSPanel?
  private var preparedFrame: CGRect?
  private var canvas: EventEditorCanvas?
  private var form: NSView?
  private let formBlur = EventFormBlurState()
  private let surfaceMask = CAShapeLayer()
  private let formMask = CAShapeLayer()
  private let editorShadow = CALayer()
  private let editorShadowMask = CAShapeLayer()
  private let editorInput = CAShapeLayer()
  private var editorOutline: EventEditorOutline?
  private var nativeGlass: NSView?
  private var glyphHost: EventToolbarGlyphs?
  private var toolbarCancel: EventToolbarCancelTarget?
  private var toolbarSave: EventToolbarCancelTarget?
  private var toolbarPin: EventToolbarCancelTarget?
  private var toolbarSettings: EventToolbarCancelTarget?
  private var transition: EventFissionTransition?
  private var motionFraction = 0.0
  private var channels = EventFissionChannels.closed
  private var sceneRefreshPending = false
  private var toolbarPose: EventToolbarPose?
  private var surfaceCanvas: EventEditorCanvas?
  private var preparedSource: CGRect?
  private var source = CGRect.zero
  private var destination = CGRect.zero
  private let target = DisplayLinkTarget()
  private var link: CADisplayLink?
  private var started = 0.0
  private var presentationClock = EventFissionPresentationClock()
  private var awaitingFirstTick = false
  private var preparationObservers: [NSObjectProtocol] = []
  private var duration = 0.0
  private var closing = false
  private var progress = 0.0
  private var completion: (() -> Void)?
  private var endpointSubmitted = false
  private var isEmbeddedInParent = false
  private var embeddedParentFrame: CGRect?
  private var embeddedVisibleFrame: CGRect?
  private var embeddedBackingScale: CGFloat?
  #if DEBUG
  private var previousTick = 0.0
  private var maximumGap = 0.0
  private var frameCount = 0
  private var gapAtProgress = 0.0
  private var traceFrames: [[String: Any]] = []
  private var lastTracePose: [String: Any] = [:]
  private var preparationMilliseconds = 0.0
  private var preparationStages: [String: Double] = [:]
  private var focusObservers: [NSObjectProtocol] = []
  private var clickMonitor: Any?
  #endif

  init(model: AppModel) {
    self.model = model
    target.owner = self
    model.eventCreation.motionDriver = { [weak self] closing, completion in
      self?.play(closing: closing, completion: completion)
    }
    model.eventCreation.presentationLayoutDriver = { [weak self] in self?.scheduleSceneRefresh() }
    model.eventCreation.sourceState.toolbarPressDriver = { [weak self] amount in
      guard let self, !self.model.eventCreation.isMounted else { return }
      self.presentIdle(press: amount)
    }
    #if DEBUG
    if CommandLine.arguments.contains("--qa-event-trace") { installFocusTrace() }
    #endif
  }
  deinit {
    link?.invalidate()
    for observer in preparationObservers { NotificationCenter.default.removeObserver(observer) }
    #if DEBUG
    for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
    if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    #endif
  }

  #if DEBUG
  private func installFocusTrace() {
    focusObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
      NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
      NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification].map { name in
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        MainActor.assumeIsolated {
          self?.traceFocus(name.rawValue, eventWindow: note.object as? NSWindow)
        }
      }
    }
    clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self, self.model.eventCreation.isActive else { return }
        let root = event.window?.contentView
        let point = root?.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        let hit = root?.hitTest(point).map { String(describing: type(of: $0)) } ?? "none"
        self.traceFocus("mouse-\(event.type.rawValue)", eventWindow: event.window, hit: hit)
        DispatchQueue.main.async { [weak self, weak window = event.window] in
          self?.traceFocus("after-mouse-\(event.type.rawValue)", eventWindow: window, hit: hit)
        }
      }
      return event
    }
  }

  private func traceFocus(_ kind: String, eventWindow: NSWindow?, hit: String = "") {
    guard model.eventCreation.isActive else { return }
    let row: [String: Any] = ["kind": kind, "hostTime": CACurrentMediaTime(),
      "eventWindow": eventWindow?.windowNumber ?? -1, "hitView": hit,
      "parentWindow": parent?.windowNumber ?? -1, "editorWindow": canvas?.window?.windowNumber ?? -1,
      "keyWindow": NSApp.keyWindow?.windowNumber ?? -1, "mainWindow": NSApp.mainWindow?.windowNumber ?? -1,
      "editorKey": canvas?.window?.isKeyWindow ?? false, "appActive": NSApp.isActive,
      "firstResponder": canvas?.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"]
    if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
      FileHandle.standardError.write(data + Data([10]))
    }
  }
  #endif

  func attach(to parent: NSPanel) {
    guard self.parent !== parent else { return }
    self.parent = parent
    for observer in preparationObservers { NotificationCenter.default.removeObserver(observer) }
    preparationObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didExposeNotification,
                            NSWindow.didUpdateNotification].map { name in
      NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.schedulePreparation() }
      }
    }
    schedulePreparation()
  }

  /// Temporary parent dismissal never runs the draft's cancel/save lifecycle.
  @discardableResult
  func suspendWithParent() -> Bool {
    guard model.eventCreation.suspendPresentation() else { return false }
    link?.invalidate()
    link = nil
    if canvas != nil, model.eventCreation.phase != .preparing {
      let finish = completion
      completion = nil
      finish?()
      // No window transfer or field-editor teardown on the dismissal path.
    }
    return true
  }

  func prepareForParentExpansion() {
    guard model.eventCreation.isSuspended, model.eventCreation.draft != nil else { return }
    if isEmbeddedInParent, let parent, let canvas,
       canvas.superview === model.eventCreation.parentPresentationView,
       canvas.window === parent,
       embeddedParentFrame == parent.frame,
       embeddedVisibleFrame == parent.screen?.visibleFrame,
       embeddedBackingScale == parent.backingScaleFactor {
      // The retained canvas is already in the correct resting coordinates.
      // Do not move every control through two window lifecycles before reveal.
      // Finish any standalone opening interrupted by the parent's dismissal.
      apply(progress: 1)
      return
    }
    guard preparePanel() else { return }
    apply(progress: 1)
  }

  /// Keep the native idle toolbar ready while its parent window is ordered out.
  /// SwiftUI intentionally hides these glyphs on macOS 26, so waiting for a
  /// later window-expose notification would leave them absent during reveal.
  func prepareIdleToolbarForParentReveal() {
    guard !model.eventCreation.isActive,
          preparePanel(allowPlaceholder: true) else { return }
    presentIdle(press: model.eventCreation.sourceState.toolbarPressAmount)
  }

  /// Mount at preparation time and retain the same window for the editor's whole
  /// lifetime. Parent motion never transfers controls between NSWindows.
  private func embedInParent() {
    guard let parent, let preparedFrame, let canvas,
          let host = model.eventCreation.parentPresentationView,
          host.window === parent else { return }
    // Use resting content coordinates. Converting through the SwiftUI host
    // during opening would bake its current scale/offset into the final frame.
    let inset = PanelSurfacePose.canvasInset
    let frame = CGRect(x: preparedFrame.minX - parent.frame.minX - inset,
                       y: parent.frame.maxY - inset - preparedFrame.maxY,
                       width: preparedFrame.width, height: preparedFrame.height)
    embeddedParentFrame = parent.frame
    embeddedVisibleFrame = parent.screen?.visibleFrame
    embeddedBackingScale = parent.backingScaleFactor
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    canvas.autoresizingMask = []
    canvas.frame = frame
    if canvas.superview !== host { host.addSubview(canvas) }
    isEmbeddedInParent = true
    CATransaction.commit()
  }

  func resumeWithParent() {
    guard model.eventCreation.isSuspended, model.eventCreation.draft != nil else { return }
    // Reduced Motion may arrive without the normal reveal preparation.
    if canvas?.window !== parent { guard preparePanel() else { return } }
    apply(progress: 1)
    canvas?.isHidden = false
    model.eventCreation.resumePresentation()
    parent?.makeKey()
  }

  func containsEditorPoint(_ screenPoint: CGPoint) -> Bool {
    guard let canvas, let window = canvas.window, window.isVisible,
          !canvas.isHidden, !model.eventCreation.isSuspended else { return false }
    let point = canvas.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
    return canvas.hitRegion?.contains(point) == true
  }

  func ownsWindow(_ window: NSWindow?) -> Bool { window != nil && window === canvas?.window }

  private func schedulePreparation() {
    guard canvas == nil else { return }
    scheduleSceneRefresh()
  }

  /// Coalesce layout notifications; never publish SwiftUI state from layout.
  /// The same scene renders the idle toolbar and the complete moving editor.
  private func scheduleSceneRefresh() {
    guard !sceneRefreshPending else { return }
    sceneRefreshPending = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.sceneRefreshPending = false
      if self.model.eventCreation.isActive {
        if self.model.eventCreation.phase == .visible {
          self.apply(channels: self.channels, coverSource: false)
        }
        return
      }
      guard let parent = self.parent,
            self.model.eventCreation.sourceView?.window === parent,
            self.model.eventCreation.parentPresentationView?.window === parent else {
        self.canvas?.isHidden = true
        return
      }
      // An ordered-out parent can still retain a deliberately prepared native
      // idle scene. Its visibility changes only when structural anchors detach.
      guard parent.isVisible else { return }
      if self.preparePanel(allowPlaceholder: true) {
        self.presentIdle(press: self.model.eventCreation.sourceState.toolbarPressAmount)
      }
    }
  }

  private func presentIdle(press: CGFloat = 0) {
    guard canvas != nil, !model.eventCreation.isMounted else { return }
    channels = .closed
    channels.width += 0.035 * press
    channels.height += 0.045 * press
    apply(channels: channels, coverSource: false)
    canvas?.isHidden = nativeGlass == nil
  }

  private func preparePanel(allowPlaceholder: Bool = false) -> Bool {
    guard let parent, let anchor = model.eventCreation.sourceView,
          anchor.window === parent,
          let host = model.eventCreation.parentPresentationView, host.window === parent,
          allowPlaceholder || model.eventCreation.draft != nil else { return false }
    let current = model.eventCreation.draft ?? EventDraft(
      focusedDate: model.currentFocusedDate, now: Date(), calendar: .current, calendarID: "")
    guard anchor.bounds.width > 0, anchor.bounds.height > 0,
          model.eventCreation.parentPresentationView?.window === parent else { return false }
    let screenSource = Self.restingSourceFrame(anchor: anchor, host: host, parentFrame: parent.frame)
    let visible = parent.screen?.visibleFrame ?? parent.frame
    let size = CGSize(width: min(420, visible.width - 48), height: min(520, visible.height - 100))
    var end = CGRect(x: screenSource.maxX - size.width,
                     y: screenSource.minY - 18 - size.height, width: size.width, height: size.height)
    end.origin.x = min(max(visible.minX + 24, end.minX), visible.maxX - size.width - 24)
    end.origin.y = max(visible.minY + 24, end.minY)
    let union = screenSource.union(end)
    let frame = union.insetBy(dx: -24, dy: -24)
    func local(_ rect: CGRect) -> CGRect {
      CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
    source = local(screenSource)
    destination = local(end)
    #if DEBUG
    preparationStages["hadPanel"] = canvas == nil ? 0 : 1
    preparationStages["matchingFrame"] = preparedFrame == frame ? 1 : 0
    preparationStages["matchingSource"] = preparedSource == source ? 1 : 0
    if let cached = preparedSource {
      preparationStages["sourceDeltaX"] = source.minX - cached.minX
      preparationStages["sourceDeltaY"] = source.minY - cached.minY
      preparationStages["sourceDeltaWidth"] = source.width - cached.width
      preparationStages["sourceDeltaHeight"] = source.height - cached.height
    }
    #endif
    if canvas?.bounds.size == frame.size,
       form?.bounds.size == destination.size, let cached = preparedSource,
       EventBubbleMotion.matchesSource(source, cached, backingScale: parent.backingScaleFactor) {
      // Screen position does not invalidate fixed-size controls. Local geometry
      // still gates reuse, including screen-edge clamping.
      preparedFrame = frame
      if form?.frame != destination { form?.frame = destination }
      embedInParent()
      return true
    }
    if model.eventCreation.isActive { parent.makeFirstResponder(nil) }
    canvas?.removeFromSuperview()
    isEmbeddedInParent = false
    let canvas = EventEditorCanvas(frame: CGRect(origin: .zero, size: frame.size))
    canvas.wantsLayer = true
    canvas.layer?.backgroundColor = NSColor.clear.cgColor
    editorShadow.removeFromSuperlayer()
    editorShadow.frame = canvas.bounds
    editorShadow.shadowColor = NSColor.black.cgColor
    editorShadow.shadowRadius = 12
    editorShadow.shadowOffset = CGSize(width: 0, height: 4)
    editorShadow.shadowOpacity = 0
    editorShadowMask.fillRule = .evenOdd
    editorShadowMask.fillColor = NSColor.black.cgColor
    editorShadowMask.frame = canvas.bounds
    editorShadow.mask = editorShadowMask
    canvas.layer?.addSublayer(editorShadow)
    // Native backdrop glass is not sufficient for WindowServer's input region.
    // Paint a minimal nonzero backing alpha inside the body so empty areas do
    // not send clicks through to the calendar underneath.
    editorInput.removeFromSuperlayer()
    editorInput.frame = canvas.bounds
    editorInput.fillColor = NSColor.black.withAlphaComponent(0.01).cgColor
    editorInput.contentsScale = parent.backingScaleFactor
    canvas.layer?.addSublayer(editorInput)
    let surfaceCanvas = EventEditorCanvas(frame: canvas.bounds)
    surfaceCanvas.wantsLayer = true
    surfaceMask.fillColor = NSColor.black.cgColor
    surfaceMask.contentsScale = parent.backingScaleFactor
    canvas.addSubview(surfaceCanvas)
    if #available(macOS 26.0, *) {
      let glass = EventNativeGlassSurface(frame: surfaceCanvas.bounds)
      surfaceCanvas.addSubview(glass)
      nativeGlass = glass
    } else {
      nativeGlass = nil
      surfaceCanvas.layer?.mask = surfaceMask
      let material = NSVisualEffectView()
      material.material = .popover
      material.blendingMode = .behindWindow
      material.state = .active
      material.frame = surfaceCanvas.bounds.insetBy(dx: -12, dy: -12)
      surfaceCanvas.addSubview(material)
    }
    if nativeGlass == nil {
      let outline = EventEditorOutline(frame: surfaceCanvas.bounds)
      surfaceCanvas.addSubview(outline)
      editorOutline = outline
    } else { editorOutline = nil }
    let glyphs = EventToolbarGlyphs(frame: surfaceCanvas.bounds)
    surfaceCanvas.addSubview(glyphs)
    glyphHost = glyphs
    let creation = model.eventCreation
    let card = EventCreationCard(creation: creation,
      draft: Binding(get: { creation.draft ?? current }, set: {
        if creation.draft != nil { creation.draft = $0 }
      }),
      openPrivacySettings: { [weak model] in model?.openCalendarPrivacySettings() })
      .environment(\.locale, Locale(identifier: "zh-Hans"))
      .frame(width: size.width, height: size.height)
      .modifier(EventFormBlur(state: formBlur))
    let form = NSHostingView(rootView: card)
    form.sizingOptions = []
    form.frame = destination
    form.alphaValue = 0
    form.isHidden = true
    form.wantsLayer = true
    surfaceCanvas.addSubview(form)
    formMask.fillColor = NSColor.black.cgColor
    formMask.contentsScale = parent.backingScaleFactor
    form.layer?.mask = formMask
    let cancelTarget = EventToolbarCancelTarget(frame: .zero)
    cancelTarget.onCancel = { [weak model] in
      guard let model else { return }
      if !model.eventCreation.isActive || model.eventCreation.isClosing { model.beginEventCreation() }
      else { model.eventCreation.requestCancel() }
    }
    cancelTarget.isHidden = true
    canvas.addSubview(cancelTarget)
    toolbarCancel = cancelTarget
    cancelTarget.onPress = { [weak model] pressed in
      guard let model, !model.eventCreation.isMounted else { return }
      model.eventCreation.sourceState.isPressed = pressed
    }
    if nativeGlass != nil {
      let save = EventToolbarCancelTarget(frame: .zero)
      save.setAccessibilityIdentifier("event.save")
      save.setAccessibilityLabel("添加事件")
      save.keyEquivalent = "\r"
      save.keyEquivalentModifierMask = [.command]
      save.onCancel = { [weak model] in
        guard let model else { return }
        Task { await model.eventCreation.save() }
      }
      let pin = EventToolbarCancelTarget(frame: .zero)
      pin.setAccessibilityIdentifier("event.pin")
      pin.onCancel = { [weak model] in model?.eventCreation.toolbarPinAction?() }
      let settings = EventToolbarCancelTarget(frame: .zero)
      settings.setAccessibilityIdentifier("event.settings")
      settings.setAccessibilityLabel("设置")
      settings.onCancel = { [weak model] in
        guard let model, !model.eventCreation.isActive else { return }
        model.interaction.reset()
        model.selectedEvent = nil
        model.route = .settings
      }
      for control in [save, pin, settings] { canvas.addSubview(control) }
      toolbarSave = save
      toolbarPin = pin
      toolbarSettings = settings
    }
    canvas.isHidden = true
    preparedFrame = frame
    self.canvas = canvas
    preparedSource = source
    self.surfaceCanvas = surfaceCanvas
    self.form = form
    embedInParent()
    canvas.layoutSubtreeIfNeeded()
    return true
  }

  /// Anchor and scene share the parent's animated content transform. Remove
  /// that common transform before embedding the scene, otherwise expansion's
  /// scale/vertical offset is baked into the source and then applied again.
  static func restingSourceFrame(anchor: NSView, host: NSView, parentFrame: CGRect) -> CGRect {
    let local = anchor.convert(anchor.bounds, to: host)
    let inset = PanelSurfacePose.canvasInset
    return CGRect(x: parentFrame.minX + inset + local.minX,
                  y: parentFrame.maxY - inset - local.maxY,
                  width: local.width, height: local.height)
  }

  private func play(closing: Bool, completion: @escaping () -> Void) {
    #if DEBUG
    let requestedAt = CACurrentMediaTime()
    var stageAt = requestedAt
    preparationStages = [:]
    func recordStage(_ name: String) {
      let now = CACurrentMediaTime()
      preparationStages[name] = (now - stageAt) * 1000
      stageAt = now
    }
    #endif
    // The submitted endpoint still belongs to the current playback until its
    // completion tick; reopening in that interval must not reset to closed.
    let wasAnimating = link != nil
    let previousVelocity = wasAnimating ? transition?.velocity(at: motionFraction) : nil
    link?.invalidate()
    self.completion = completion
    self.closing = closing
    if !closing && !wasAnimating {
      guard preparePanel() else { completion(); return }
      progress = 0
    }
    guard let canvas else { completion(); return }
    if model.eventCreation.isSuspended {
      // A draft prepared during group motion joins the same retained content.
      apply(progress: 1)
      canvas.isHidden = false
      self.completion = nil
      completion()
      return
    }
    #if DEBUG
    recordStage("preparePanelMS")
    #endif
    duration = EventBubbleMotion.duration(closing: closing, reduceMotion: model.eventCreation.reduceMotion)
    if wasAnimating { duration *= max(0.55, closing ? min(1, channels.growth) : 1 - min(1, channels.growth)) }
    var initial = channels
    var initialVelocity = previousVelocity ?? .zero
    if !closing && !wasAnimating {
      let state = model.eventCreation.sourceState
      initial = .closed
      initial.width += 0.035 * state.toolbarPressAmount
      initial.height += 0.045 * state.toolbarPressAmount
      initialVelocity.width = 0.035 * state.toolbarPressVelocity
      initialVelocity.height = 0.045 * state.toolbarPressVelocity
    }
    transition = EventFissionTransition(closing: closing, duration: duration,
      initial: initial, initialVelocity: initialVelocity,
      correctionDuration: !wasAnimating ? 0.16 : nil, isRetargeting: wasAnimating)
    motionFraction = 0
    endpointSubmitted = false
    // The layer shadow follows the same pose as the glass. A WindowServer shadow
    // toggled at rest produces a separate, visibly late perimeter transition.
    // The permanent scene already owns glass and glyphs. This transaction only
    // switches logical input ownership and submits the first complete pose.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    canvas.isHidden = false
    apply(channels: initial, coverSource: !model.eventCreation.reduceMotion)
    CATransaction.commit()
    model.eventCreation.sourceState.isLaunching = false
    model.eventCreation.sourceState.isPressed = false
    #if DEBUG
    recordStage("initialPoseMS")
    #endif
    // Native controls use the parent's field editor throughout their lifetime.
    if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
    parent?.makeMain()
    parent?.makeKey()
    #if DEBUG
    recordStage("exposeMS")
    #endif
    // Submit the initial geometry without synchronously drawing the entire
    // hosted form twice. AppKit coalesces its layout/display before presentation.
    #if DEBUG
    recordStage("displayMS")
    #endif
    started = CACurrentMediaTime()
    presentationClock = EventFissionPresentationClock()
    awaitingFirstTick = true
    #if DEBUG
    previousTick = started
    maximumGap = 0
    frameCount = 0
    gapAtProgress = 0
    preparationMilliseconds = (started - requestedAt) * 1000
    traceFrames.removeAll(keepingCapacity: true)
    #endif
    let displayLink = canvas.displayLink(target: target, selector: #selector(DisplayLinkTarget.update(_:)))
    displayLink.add(to: .main, forMode: .common)
    link = displayLink
  }

  private func advance(_ link: CADisplayLink) {
    if awaitingFirstTick {
      // First exposure can be delayed by the compositor. Never consume the
      // opening's swelling/fission time before the first display-link callback.
      started = link.targetTimestamp
      awaitingFirstTick = false
      #if DEBUG
      previousTick = CACurrentMediaTime()
      #endif
    }
    if endpointSubmitted {
      self.link?.invalidate()
      self.link = nil
      let finish = completion
      completion = nil
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      // The hidden SwiftUI press modifier may still hold its last launch sample.
      // Clear it before idle layout can replay that pressure after the close.
      if closing { model.eventCreation.sourceState.recordToolbarPress(amount: 0) }
      // Commit the lifecycle before deriving endpoint input availability.
      finish?()
      // The exact scene endpoint was submitted on the preceding display tick.
      // Restore logical controls without replacing the native presentation.
      apply(channels: closing ? .closed : .open, coverSource: false)
      if closing {
        parent?.makeFirstResponder(nil)
        canvas?.isHidden = nativeGlass == nil
        let sourceState = model.eventCreation.sourceState
        sourceState.handoffScale = 1
        sourceState.isLaunching = false
        sourceState.isCovered = false
        model.eventCreation.sourceVisibilityDriver?(false)
        sourceState.isPressed = false
        parent?.makeKey()
      }
      CATransaction.commit()
      #if DEBUG
      let endpoint: [String: Any] = [
        "kind": "endpoint", "direction": closing ? "close" : "open", "hostTime": CACurrentMediaTime(),
        "sourceCovered": model.eventCreation.sourceState.isCovered,
        "parentKey": parent?.isKeyWindow ?? false, "parentMain": parent?.isMainWindow ?? false,
        "editorKey": canvas?.window?.isKeyWindow ?? false, "editorVisible": (canvas?.window?.isVisible == true && canvas?.isHidden == false),
        "appActive": NSApp.isActive
      ]
      if CommandLine.arguments.contains("--qa-event-trace"),
         let data = try? JSONSerialization.data(withJSONObject: [
           "direction": closing ? "close" : "open",
           "pid": ProcessInfo.processInfo.processIdentifier,
           "endpoint": endpoint,
           "appearance": NSApp.effectiveAppearance.name.rawValue,
           "reduceMotion": model.eventCreation.reduceMotion,
           "fixture": CommandLine.arguments.contains("--demo") ? "demo" : "personal",
           "calendarDate": ISO8601DateFormatter().string(from: model.currentFocusedDate),
           "arguments": CommandLine.arguments,
           "preparationMS": preparationMilliseconds,
           "preparationStages": preparationStages,
           "maximumGapMS": maximumGap * 1000,
           "frames": traceFrames
         ], options: [.sortedKeys]) {
        // Emit once after playback; file I/O never competes with animation frames.
        FileHandle.standardError.write(data + Data([10]))
      }
      #endif
      return
    }
    #if DEBUG
    let now = CACurrentMediaTime()
    if now - previousTick > maximumGap {
      maximumGap = now - previousTick
      gapAtProgress = progress
    }
    previousTick = now
    frameCount += 1
    #endif
    let elapsed = presentationClock.advance(to: CACurrentMediaTime())
    let t = min(1, elapsed / duration)
    motionFraction = t
    if model.eventCreation.reduceMotion {
      var pose = EventFissionMotion.pose(.open, source: source, destination: destination)
      let opacity = closing ? 1 - t : t
      pose.surfaceOpacity = opacity
      pose.contentOpacity = opacity
      pose.toolbar = EventFissionMotion.toolbar(closing ? .closed : .open, source: source)
      channels = closing ? .closed : .open
      apply(pose: pose, coverSource: false)
    } else {
      apply(channels: transition?.channels(at: t) ?? (closing ? .closed : .open), coverSource: true)
    }
    #if DEBUG
    if CommandLine.arguments.contains("--qa-event-trace") {
      var row = lastTracePose
      row["timeMS"] = elapsed * 1000
      row["applyMS"] = (CACurrentMediaTime() - now) * 1000
      row["targetIntervalMS"] = (link.targetTimestamp - link.timestamp) * 1000
      traceFrames.append(row)
    }
    #endif
    endpointSubmitted = t >= 1
  }

  private func apply(progress: Double) {
    apply(channels: progress >= 1 ? .open : .closed, coverSource: false)
  }

  private func apply(channels: EventFissionChannels, coverSource: Bool) {
    self.channels = channels.bounded
    apply(pose: EventFissionMotion.pose(self.channels, source: source, destination: destination),
          coverSource: coverSource)
  }

  private func apply(pose input: EventBubblePose, coverSource: Bool) {
    var pose = input
    progress = pose.growth
    let toolbarPose = pose.toolbar!.bounded
    self.toolbarPose = toolbarPose
    // Native glass and glyphs persist at both endpoints. Only logical input
    // hands over to the SwiftUI controls after the last display tick.
    pose.showsDonor = nativeGlass != nil || coverSource
    pose.toolbar = toolbarPose
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let shadowProgress = min(1, max(0, (progress - EventBubbleMotion.separation) / (1 - EventBubbleMotion.separation)))
    let shadowFade = shadowProgress * shadowProgress * (3 - 2 * shadowProgress)
    let bodyPath = EventBubbleMotion.bodyPath(pose)
    let creation = model.eventCreation
    let nativeInput = nativeGlass != nil
    let idle = !creation.isActive
    let canCancel = (nativeInput || coverSource)
      && (idle || closing || toolbarPose.rotation > 0.12)
      && !creation.isSaving && !creation.isRequestingAccess
    toolbarCancel?.frame = toolbarPose.cancel
    toolbarCancel?.setAccessibilityLabel(idle || closing ? "添加事件" : "取消添加")
    toolbarCancel?.setAccessibilityIdentifier(idle ? "event.create" : "event.cancel")
    toolbarCancel?.isHidden = !(nativeInput || canCancel)
    toolbarCancel?.isEnabled = canCancel
    var inputPath = pose.surfaceOpacity > 0 ? bodyPath : CGMutablePath()
    if nativeInput {
      toolbarSave?.frame = toolbarPose.save
      toolbarSave?.isHidden = toolbarPose.checkOpacity <= 0.01
      toolbarSave?.isEnabled = creation.canSave && creation.phase == .visible && !creation.isRequestingAccess
      func controlFrame(_ x: CGFloat) -> CGRect {
        let center = toolbarPose.trailingCenter(x, source: source)
        return CGRect(x: center.x - 14, y: center.y - 13, width: 28, height: 26)
      }
      toolbarPin?.frame = controlFrame(source.maxX - 46)
      toolbarPin?.setAccessibilityLabel(model.isPinned ? "取消置顶" : "置顶")
      toolbarPin?.isEnabled = idle || creation.phase == .visible
      toolbarSettings?.frame = controlFrame(source.maxX - 17)
      toolbarSettings?.isEnabled = idle
      for control in [toolbarCancel, toolbarSave, toolbarPin, toolbarSettings].compactMap({ $0 }) where !control.isHidden {
        inputPath = inputPath.union(CGPath(roundedRect: control.frame, cornerWidth: control.frame.height / 2,
          cornerHeight: control.frame.height / 2, transform: nil))
      }
    } else if canCancel {
      inputPath = inputPath.union(CGPath(ellipseIn: toolbarPose.cancel, transform: nil))
    }
    canvas?.hitRegion = inputPath
    model.eventCreation.presentToolbarLayout(toolbarPose.layoutOffset)
    if nativeGlass == nil {
      editorShadow.shadowPath = bodyPath
      editorInput.path = bodyPath
      editorInput.opacity = Float(pose.surfaceOpacity)
      editorOutline?.apply(pose, backingScale: canvas?.window?.backingScaleFactor ?? 2)
      // A translucent panel must not sample its own shadow as a second dark pane.
      let outside = CGMutablePath()
      outside.addRect(editorShadow.bounds)
      outside.addPath(bodyPath.union(toolbarPose.clipPath))
      editorShadowMask.path = outside
      editorShadow.shadowOpacity = Float(0.18 * (model.eventCreation.reduceMotion ? 1 : shadowFade) * Double(pose.surfaceOpacity))
      #if DEBUG
      if CommandLine.arguments.contains("--qa-event-no-shadow") { editorShadow.shadowOpacity = 0 }
      #endif
    } else { editorShadow.shadowOpacity = 0 }
    // Visibility and geometry share one AppKit transaction; no delayed SwiftUI
    // visibility update can leave a second glyph copy during source handoff.
    glyphHost?.isHidden = nativeGlass == nil && !coverSource
    if let toolbar = pose.toolbar {
      glyphHost?.apply(toolbar, source: source, isPinned: model.isPinned, canSave: model.eventCreation.canSave)
    }
    surfaceCanvas?.alphaValue = 1
    editorInput.path = bodyPath
    editorInput.opacity = Float(pose.surfaceOpacity)
    form?.alphaValue = pose.contentOpacity
    // The retained scene also exists at idle; exclude its dormant form from
    // accessibility and keyboard navigation until the content becomes visible.
    form?.isHidden = pose.contentOpacity <= 0
    if #available(macOS 26.0, *), let glass = nativeGlass as? EventNativeGlassSurface {
      glass.apply(pose, source: source)
    }
    if nativeGlass == nil, let host = surfaceCanvas?.layer {
      surfaceMask.frame = host.bounds
      // The mask uses the flipped canvas coordinates, matching its NSView children.
      let path = EventBubbleMotion.path(pose: pose, source: source)
      surfaceMask.path = pose.showsDonor ? path.union(pose.toolbar!.clipPath) : path
    }
    if let layer = form?.layer {
      // SwiftUI owns this hosting layer; render blur inside its view graph
      // rather than attaching filters that hosting updates may replace.
      formBlur.update(pose.contentBlur)
      let contentFrame = EventBubbleMotion.contentFrame(pose: pose, destination: destination)
      layer.anchorPoint = .zero
      layer.position = contentFrame.origin
      layer.setAffineTransform(CGAffineTransform(scaleX: pose.contentScale, y: pose.contentScale))
      formMask.frame = CGRect(origin: .zero, size: destination.size)
      formMask.path = EventBubbleMotion.contentMask(pose: pose, destination: destination)
    }
    model.eventCreation.sourceVisibilityDriver?(coverSource)
    if model.eventCreation.sourceState.isCovered != coverSource {
      model.eventCreation.sourceState.isCovered = coverSource
    }
    // Never publish an unchanged SwiftUI state on every animation frame. The
    // detached source is already at rest; restore ownership only after motion.
    if !coverSource, model.eventCreation.isMounted, model.eventCreation.sourceState.isLaunching {
      model.eventCreation.sourceState.isLaunching = false
    }
    CATransaction.commit()
    #if DEBUG
    if CommandLine.arguments.contains("--qa-event-trace") {
    lastTracePose = [
      "kind": "pose", "hostTime": CACurrentMediaTime(), "progress": progress,
      "direction": closing ? "close" : "open", "body": [pose.body.minX, pose.body.minY, pose.body.width, pose.body.height],
      "donor": [pose.donor.minX, pose.donor.minY, pose.donor.width, pose.donor.height], "rimInset": pose.editorRimInset,
      "sourceCovered": pose.showsDonor, "shadowOpacity": editorShadow.shadowOpacity,
      "parentKey": parent?.isKeyWindow ?? false, "parentMain": parent?.isMainWindow ?? false,
      "editorKey": canvas?.window?.isKeyWindow ?? false, "appActive": NSApp.isActive,
      "editorWindowShadow": false
    ]
    }
    #endif
  }


}

final class EventEditorPanel: NSPanel {
  var cancel: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func cancelOperation(_ sender: Any?) { cancel?() }

  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    // preparePanel already constrains the visible form to the screen. Preserve
    // its transparent top inset so the native donor stays on the real toolbar
    // capsule when the parent is flush with the menu bar.
    frameRect
  }
}

private final class EventEditorCanvas: NSView {
  var hitRegion: CGPath?
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? {
    if let hitRegion, !hitRegion.contains(convert(point, from: superview)) { return nil }
    return super.hitTest(point)
  }
}

/// A logical control stays independent of the moving glass and glyph proxies.
private final class EventToolbarCancelTarget: NSButton {
  var onCancel: (() -> Void)?
  var onPress: ((Bool) -> Void)?
  override func mouseDown(with event: NSEvent) {
    guard isEnabled else { return }
    onPress?(true)
    defer { onPress?(false) }
    super.mouseDown(with: event)
  }
  override init(frame: NSRect) {
    super.init(frame: frame)
    title = ""
    isBordered = false
    isTransparent = true
    target = self
    action = #selector(cancelEditing)
    setAccessibilityLabel("取消添加")
    setAccessibilityIdentifier("event.cancel.motion")
  }
  required init?(coder: NSCoder) { nil }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  @objc private func cancelEditing() { onCancel?() }
}

/// Unmanaged sublayers own glyph geometry. AppKit must not reconcile animated
/// centers with the origins of NSHostingView backing layers during handoff.
private final class EventToolbarGlyphs: NSView {
  private let plus = CALayer()
  private let check = CALayer()
  private let neutralCheck = CALayer()
  private let pin = CALayer()
  private let settings = CALayer()
  private var pinned = false
  override var isFlipped: Bool { true }
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    for glyph in [plus, check, neutralCheck, pin, settings] {
      glyph.bounds = CGRect(x: 0, y: 0, width: 28, height: 26)
      glyph.anchorPoint = CGPoint(x: 0.5, y: 0.5)
      layer?.addSublayer(glyph)
    }
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { updateImages() } }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance(); if window != nil { updateImages() }
  }
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties(); if window != nil { updateImages() }
  }
  private func updateImages() {
    let scheme: ColorScheme = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    let scale = window?.backingScaleFactor ?? 2
    let images: [(CALayer, EventToolbarGlyph)] = [
      (plus, EventToolbarGlyph(symbol: "plus")),
      (check, EventToolbarGlyph(symbol: "checkmark", primary: true)),
      (neutralCheck, EventToolbarGlyph(symbol: "checkmark")),
      (pin, EventToolbarGlyph(symbol: pinned ? "pin.fill" : "pin", active: pinned)),
      (settings, EventToolbarGlyph(symbol: "gearshape"))
    ]
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (glyph, content) in images {
      let renderer = ImageRenderer(content: content.environment(\.colorScheme, scheme))
      renderer.scale = scale
      glyph.contentsScale = scale
      effectiveAppearance.performAsCurrentDrawingAppearance {
        glyph.contents = renderer.cgImage
      }
    }
    CATransaction.commit()
  }
  func apply(_ pose: EventToolbarPose, source: CGRect, isPinned: Bool, canSave: Bool) {
    if pinned != isPinned { pinned = isPinned; updateImages() }
    let cancelScale = min(1.12, min(pose.cancel.width, pose.cancel.height) / 32)
    let checkScale = min(pose.save.width, pose.save.height) / 32
    plus.position = CGPoint(x: pose.cancel.midX, y: pose.cancel.midY)
    plus.setAffineTransform(CGAffineTransform(rotationAngle: pose.rotation).scaledBy(x: cancelScale, y: cancelScale))
    for glyph in [check, neutralCheck] {
      glyph.position = CGPoint(x: pose.save.midX, y: pose.save.midY)
      glyph.setAffineTransform(CGAffineTransform(scaleX: checkScale, y: checkScale))
    }
    let opacity = pose.checkOpacity * (canSave ? 1 : 0.45)
    check.opacity = Float(opacity * pose.blue)
    neutralCheck.opacity = Float(opacity * (1 - pose.blue))
    pin.position = pose.trailingCenter(source.maxX - 46, source: source)
    settings.position = pose.trailingCenter(source.maxX - 17, source: source)
    let scale = min(1.08, min(pose.mother.width / source.width, pose.mother.height / source.height))
    for glyph in [pin, settings] { glyph.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale)) }
  }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct EventToolbarGlyph: View {
  let symbol: String
  var primary = false
  var active = false
  var body: some View {
    Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
      .foregroundStyle(primary ? Color.white : (active ? Color.accentColor : Color.primary.opacity(0.78)))
      .frame(width: 28, height: 26)
      .background(Capsule().fill(Color.primary.opacity(active ? 0.065 : 0)))
      .allowsHitTesting(false).accessibilityHidden(true)
  }
}

/// A permanent native scene surface. Actual glass bounds define fusion; no
/// overscan, second material, per-frame output mask or hand-drawn optical neck.
@available(macOS 26.0, *)
final class EventNativeGlassSurface: NSView {
  private let container = NSGlassEffectContainerView()
  private let content = EventEditorCanvas()
  private let donor = ToolbarGlassEffectView(frame: .zero)
  private let cancel = ToolbarGlassEffectView(frame: .zero)
  private let save = ToolbarGlassEffectView(frame: .zero)
  private let editor = ToolbarGlassEffectView(frame: .zero)
  override var isFlipped: Bool { true }
  override init(frame: NSRect) {
    super.init(frame: frame)
    clipsToBounds = false
    container.frame = bounds
    container.autoresizingMask = [.width, .height]
    container.clipsToBounds = false
    container.spacing = EventFissionMotion.fusionDistance
    content.frame = bounds
    content.autoresizingMask = [.width, .height]
    content.clipsToBounds = false
    container.contentView = content
    // One optical family and coordinate system, with the editor behind leaves.
    for glass in [editor, donor, cancel, save] { content.addSubview(glass) }
    addSubview(container)
  }
  required init?(coder: NSCoder) { nil }
  func apply(_ pose: EventBubblePose, source: CGRect) {
    guard let toolbar = pose.toolbar else { return }
    donor.frame = toolbar.remainder
    donor.cornerRadius = donor.frame.height / 2
    cancel.frame = toolbar.cancel
    cancel.cornerRadius = min(toolbar.cancel.width, toolbar.cancel.height) / 2
    save.frame = toolbar.save
    save.cornerRadius = min(toolbar.save.width, toolbar.save.height) / 2
    // Tiny leaves stay inside their receiver; the native compositor owns their
    // emergence instead of boolean visibility switches on a partial overlap.
    save.accentAmount = toolbar.blue
    editor.frame = pose.body
    editor.cornerRadius = pose.radius
    editor.isHidden = pose.body.height < 0.5 || pose.surfaceOpacity == 0
    editor.alphaValue = pose.surfaceOpacity
  }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A single thin contour outside native glass composition, inside the body edge.
final class EventEditorOutline: NSView {
  private let stroke = CAShapeLayer()
  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    stroke.fillColor = nil
    layer?.addSublayer(stroke)
    updateColor()
  }
  required init?(coder: NSCoder) { nil }

  func apply(_ pose: EventBubblePose, backingScale: CGFloat) {
    let width = 1 / max(1, backingScale)
    stroke.frame = bounds
    stroke.contentsScale = backingScale
    stroke.lineWidth = width
    stroke.path = EventBubbleMotion.bodyPath(pose, inset: width / 2)
    // Introduce the independent outline gradually as the editor leaves its
    // seed, rather than turning it on in the separation frame.
    stroke.opacity = Float(EventBubbleMotion.smooth((pose.contentScale - 0.06) / 0.20))
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColor()
  }
  private func updateColor() {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    stroke.strokeColor = (dark ? NSColor.white.withAlphaComponent(0.22)
      : NSColor.black.withAlphaComponent(0.16)).cgColor
    CATransaction.commit()
  }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class EventFormBlurState: ObservableObject {
  @Published private(set) var radius: CGFloat = 0

  func update(_ value: CGFloat) {
    guard value != radius else { return }
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) { radius = value }
  }
}

private struct EventFormBlur: ViewModifier {
  @ObservedObject var state: EventFormBlurState
  func body(content: Content) -> some View {
    content.blur(radius: state.radius)
  }
}
