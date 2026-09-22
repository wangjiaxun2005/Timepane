import AppKit
import QuartzCore
import SwiftUI

struct CalendarModePicker: View, Equatable {
  let displayMode: CalendarDisplayMode
  let animator: CalendarModeSelectionAnimator
  let onSelect: (CalendarDisplayMode) -> Void
  var committedMode: CalendarDisplayMode? = nil

  static func == (lhs: CalendarModePicker, rhs: CalendarModePicker) -> Bool {
    lhs.displayMode == rhs.displayMode
      && lhs.committedMode == rhs.committedMode
      && lhs.animator === rhs.animator
  }

  var body: some View {
    ZStack {
      CalendarModeSelectionLayerView(
        displayMode: committedMode ?? displayMode,
        animator: animator
      )
      .allowsHitTesting(false)

      HStack(spacing: 0) {
        modeButton(.week, title: "周", isSelected: displayMode == .week)
        modeButton(.month, title: "月", isSelected: displayMode == .month)
      }
    }
    .frame(width: CalendarModePickerMetrics.width, height: CalendarModePickerMetrics.height)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("视图")
  }

  private func modeButton(
    _ mode: CalendarDisplayMode,
    title: String,
    isSelected: Bool
  ) -> some View {
    Button {
      onSelect(mode)
    } label: {
      Color.clear
        .contentShape(Rectangle())
        .accessibilityLabel(title)
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

enum CalendarModePickerMetrics {
  static let width: CGFloat = 76
  static let height: CGFloat = 26
  static let segmentWidth = width / 2
  static let lensWidth = segmentWidth - 2
  static let lensHeight = height - 2
}

struct CalendarModePickerLabels: View {
  let foreground: Color

  var body: some View {
    HStack(spacing: 0) {
      Text("周")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Text("月")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .font(.system(size: 12, weight: .semibold))
    .foregroundStyle(foreground)
    .frame(width: CalendarModePickerMetrics.width, height: CalendarModePickerMetrics.height)
    .allowsHitTesting(false)
  }
}

struct CalendarModeSelectionLayerView: NSViewRepresentable {
  @Environment(\.colorScheme) private var colorScheme
  let displayMode: CalendarDisplayMode
  let animator: CalendarModeSelectionAnimator

  func makeNSView(context: Context) -> CalendarModeSelectionNSView {
    let view = CalendarModeSelectionNSView()
    NativeGlassAppearance.apply(colorScheme, to: view)
    animator.attach(view, committedMode: displayMode)
    return view
  }

  func updateNSView(_ nsView: CalendarModeSelectionNSView, context: Context) {
    NativeGlassAppearance.apply(colorScheme, to: nsView)
    animator.attach(nsView, committedMode: displayMode)
  }

  static func dismantleNSView(
    _ nsView: CalendarModeSelectionNSView,
    coordinator: Void
  ) {
    nsView.stopAnimation()
  }
}

final class CalendarModeSelectionAnimator: ObservableObject {
  private weak var view: CalendarModeSelectionNSView?
  private var committedMode: CalendarDisplayMode = .week
  private var intendedMode: CalendarDisplayMode?
  private(set) var generation = 0

  func attach(
    _ view: CalendarModeSelectionNSView,
    committedMode: CalendarDisplayMode
  ) {
    let isNewView = self.view !== view
    self.view = view
    self.committedMode = committedMode

    if let intendedMode {
      if intendedMode == committedMode {
        self.intendedMode = nil
        view.settle(at: committedMode)
      } else if isNewView {
        view.play(from: committedMode, to: intendedMode)
      }
    } else {
      view.settle(at: committedMode)
    }
  }

  func play(from sourceMode: CalendarDisplayMode, to targetMode: CalendarDisplayMode) {
    guard sourceMode != targetMode else { return }
    generation &+= 1
    committedMode = sourceMode
    intendedMode = targetMode
    view?.play(from: sourceMode, to: targetMode)
  }

  func isCurrent(
    generation: Int,
    targetMode: CalendarDisplayMode
  ) -> Bool {
    generation == self.generation && intendedMode == targetMode
  }

  func complete(mode: CalendarDisplayMode) {
    committedMode = mode
    intendedMode = nil
    view?.settle(at: mode)
  }
}

final class CalendarModeSelectionNSView: NSView {
  private let lensLayer = CALayer()
  private let selectionMaskLayer = CALayer()
  private let unselectedMaskLayer = CAShapeLayer()
  private let baseLabels = CALayer()
  private let selectedLabels = CALayer()
  private var activeFrames: [SelectionFrame] = []
  private var activeBeginTime: CFTimeInterval = 0
  private var visualMode: CalendarDisplayMode = .week
  private lazy var weekToMonthKeyframes = makeSelectionKeyframes(direction: .weekToMonth)
  private lazy var monthToWeekKeyframes = makeSelectionKeyframes(direction: .monthToWeek)

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureLayers()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureLayers()
  }

  override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    let labelFrame = CGRect(
      origin: .zero,
      size: CGSize(
        width: CalendarModePickerMetrics.width,
        height: CalendarModePickerMetrics.height
      )
    )
    baseLabels.frame = labelFrame
    selectedLabels.frame = labelFrame
    unselectedMaskLayer.frame = labelFrame
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateLensAppearance()
    if window != nil { updateLabelImages() }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { updateLabelImages() }
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    if window != nil { updateLabelImages() }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  func play(from sourceMode: CalendarDisplayMode, to targetMode: CalendarDisplayMode) {
    guard sourceMode != targetMode else {
      settle(at: targetMode)
      return
    }

    let beginTime = CACurrentMediaTime()
    let presentation = lensLayer.presentation()
    let interrupted = !(lensLayer.animationKeys()?.isEmpty ?? true)
    let current = presentation.map {
      SelectionFrame(bounds: $0.bounds, position: $0.position, cornerRadius: $0.cornerRadius)
    }
    let previousFrames = activeFrames
    let previousStart = activeBeginTime
    visualMode = targetMode
    let direction: CalendarZoomDirection = targetMode == .month ? .weekToMonth : .monthToWeek
    var keyframes = selectionKeyframes(direction: direction)
    guard let finalFrame = keyframes.frames.last else { return }
    if interrupted, let current, !previousFrames.isEmpty {
      keyframes = continuationFrames(from: current, to: finalFrame, previous: previousFrames,
        previousStart: previousStart, now: beginTime)
    }
    activeFrames = keyframes.frames
    activeBeginTime = beginTime
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    lensLayer.removeAllAnimations()
    selectionMaskLayer.removeAllAnimations()
    unselectedMaskLayer.removeAllAnimations()
    // Commit the final model values and install both animations atomically.
    // A separate model-value transaction can expose the destination for one
    // frame before the reverse month-to-week animation is attached.
    apply(finalFrame)
    addGeometryAnimations(
      to: lensLayer,
      keyframes: keyframes,
      beginTime: beginTime,
      prefix: "selector.lens"
    )
    addGeometryAnimations(
      to: selectionMaskLayer,
      keyframes: keyframes,
      beginTime: beginTime,
      prefix: "selector.mask"
    )
    addKeyframeAnimation(to: unselectedMaskLayer, keyPath: "path",
      values: keyframes.unselectedMaskValues, keyTimes: keyframes.keyTimes,
      beginTime: beginTime, key: "selector.unselectedMask")
    CATransaction.commit()
    // Submit the selector now; calendar scene preparation can occupy the main thread.
    CATransaction.flush()
  }

  func settle(at mode: CalendarDisplayMode) {
    guard lensLayer.animationKeys()?.isEmpty ?? true,
          selectionMaskLayer.animationKeys()?.isEmpty ?? true else { return }
    visualMode = mode
    let travel: CGFloat = mode == .week ? 0 : 1
    let frame = selectionFrame(
      sample: .settled(at: travel),
      motionDirection: mode == .week ? -1 : 1
    )
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    apply(frame)
    CATransaction.commit()
  }

  func stopAnimation() {
    lensLayer.removeAllAnimations()
    selectionMaskLayer.removeAllAnimations()
    unselectedMaskLayer.removeAllAnimations()
  }

  private func configureLayers() {
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    layer?.masksToBounds = false

    updateLensAppearance()
    selectionMaskLayer.backgroundColor = NSColor.black.cgColor
    unselectedMaskLayer.fillColor = NSColor.black.cgColor
    unselectedMaskLayer.fillRule = .evenOdd
    baseLabels.mask = unselectedMaskLayer

    layer?.addSublayer(lensLayer)
    baseLabels.zPosition = 1
    selectedLabels.zPosition = 2
    layer?.addSublayer(baseLabels)
    layer?.addSublayer(selectedLabels)
    selectedLabels.mask = selectionMaskLayer
    settle(at: .week)
  }

  private func updateLensAppearance() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      lensLayer.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.06)
        : NSColor.controlAccentColor.withAlphaComponent(0.12)).cgColor
    }
  }

  private func updateLabelImages() {
    // Keep both labels in transparent, unmanaged layers. A nested hosting view
    // must not cover the unselected label or replace the selection mask.
    let scheme: ColorScheme = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    let scale = window?.backingScaleFactor ?? 2
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // Complementary masks give every glyph edge one color, rather than painting
    // transparent blue antialiasing over a second gray/white copy of the text.
    for (target, foreground) in [(baseLabels, Color.primary.opacity(0.78)), (selectedLabels, Color.accentColor)] {
      let renderer = ImageRenderer(content: CalendarModePickerLabels(foreground: foreground)
        .environment(\.colorScheme, scheme))
      renderer.scale = scale
      target.contentsScale = scale
      target.contents = renderer.cgImage
    }
    CATransaction.commit()
  }

  private struct SelectionFrame {
    let bounds: CGRect
    let position: CGPoint
    let cornerRadius: CGFloat
  }

  private struct SelectionKeyframes {
    let frames: [SelectionFrame]
    let keyTimes: [NSNumber]
    let boundsValues: [Any]
    let positionValues: [Any]
    let cornerRadiusValues: [Any]
    let unselectedMaskValues: [Any]

    init(frames: [SelectionFrame]) {
      self.frames = frames
      keyTimes = frames.indices.map {
        NSNumber(value: Double($0) / Double(max(1, frames.count - 1)))
      }
      boundsValues = frames.map { NSValue(rect: $0.bounds) }
      positionValues = frames.map { NSValue(point: $0.position) }
      cornerRadiusValues = frames.map { NSNumber(value: Double($0.cornerRadius)) }
      unselectedMaskValues = frames.map { CalendarModeSelectionNSView.unselectedMask(for: $0) }
    }
  }

  private func selectionKeyframes(
    direction: CalendarZoomDirection
  ) -> SelectionKeyframes {
    switch direction {
    case .weekToMonth:
      weekToMonthKeyframes
    case .monthToWeek:
      monthToWeekKeyframes
    }
  }

  private func makeSelectionKeyframes(
    direction: CalendarZoomDirection
  ) -> SelectionKeyframes {
    let sampleCount = 61
    let frames = (0..<sampleCount).map { index in
      let playbackProgress = CGFloat(index) / CGFloat(sampleCount - 1)
      let forward = CalendarZoomMotionSpec.selectorPlaybackSample(playbackProgress)
      let sample: CalendarModeSelectionSample
      let motionDirection: CGFloat
      switch direction {
      case .weekToMonth:
        sample = forward
        motionDirection = 1
      case .monthToWeek:
        sample = CalendarModeSelectionSample(
          travel: 1 - forward.travel,
          widthScale: forward.widthScale,
          heightScale: forward.heightScale,
          directionalOffset: forward.directionalOffset
        )
        motionDirection = -1
      }
      return selectionFrame(sample: sample, motionDirection: motionDirection)
    }
    return SelectionKeyframes(frames: frames)
  }

  private func continuationFrames(from source: SelectionFrame, to target: SelectionFrame,
                                  previous: [SelectionFrame], previousStart: TimeInterval,
                                  now: TimeInterval) -> SelectionKeyframes {
    let duration = CalendarZoomMotionSpec.selectorCompletionTime
    let epsilon = 0.0001
    func previousValue(_ key: (SelectionFrame) -> CGFloat, at time: TimeInterval) -> CGFloat {
      let index = min(CGFloat(previous.count - 1), max(0,
        CGFloat((time - previousStart) / duration) * CGFloat(previous.count - 1)))
      let lower = Int(index)
      let upper = min(previous.count - 1, lower + 1)
      return key(previous[lower]) + (key(previous[upper]) - key(previous[lower])) * (index - CGFloat(lower))
    }
    func track(_ key: (SelectionFrame) -> CGFloat) -> CalendarMotionTrack {
      let velocity = (previousValue(key, at: now + epsilon) - previousValue(key, at: now - epsilon))
        / CGFloat(2 * epsilon)
      return CalendarMotionTrack(startTime: now, duration: duration, source: key(source),
        target: key(target), initialVelocity: velocity, curve: .spring(bounce: 0.40))
    }
    let x = track { $0.position.x }
    let y = track { $0.position.y }
    let width = track { $0.bounds.width }
    let height = track { $0.bounds.height }
    let radius = track { $0.cornerRadius }
    return SelectionKeyframes(frames: (0...60).map { index in
      let time = now + Double(index) / 60 * duration
      return SelectionFrame(bounds: CGRect(x: 0, y: 0,
        width: width.value(at: time), height: height.value(at: time)),
        position: CGPoint(x: x.value(at: time), y: y.value(at: time)),
        cornerRadius: radius.value(at: time))
    })
  }

  private func selectionFrame(
    sample: CalendarModeSelectionSample,
    motionDirection: CGFloat
  ) -> SelectionFrame {
    let clamped = min(1.06, max(-0.06, sample.travel))
    let offset =
      CalendarModePickerMetrics.segmentWidth * (clamped - 0.5)
        + CalendarModePickerMetrics.lensWidth * sample.directionalOffset * motionDirection
    let size = CGSize(
      width: CalendarModePickerMetrics.lensWidth * sample.widthScale,
      height: CalendarModePickerMetrics.lensHeight * sample.heightScale
    )
    return SelectionFrame(
      bounds: CGRect(origin: .zero, size: size),
      position: CGPoint(
        x: CalendarModePickerMetrics.width / 2 + offset,
        y: CalendarModePickerMetrics.height / 2 - 0.5
      ),
      cornerRadius: size.height / 2
    )
  }

  private static func unselectedMask(for frame: SelectionFrame) -> CGPath {
    let path = CGMutablePath()
    path.addRect(CGRect(x: 0, y: 0, width: CalendarModePickerMetrics.width,
                       height: CalendarModePickerMetrics.height))
    let lens = CGRect(x: frame.position.x - frame.bounds.width / 2,
                      y: frame.position.y - frame.bounds.height / 2,
                      width: frame.bounds.width, height: frame.bounds.height)
    path.addRoundedRect(in: lens, cornerWidth: frame.cornerRadius, cornerHeight: frame.cornerRadius)
    return path
  }

  private func apply(_ frame: SelectionFrame) {
    unselectedMaskLayer.path = Self.unselectedMask(for: frame)
    for layer in [lensLayer, selectionMaskLayer] {
      layer.bounds = frame.bounds
      layer.position = frame.position
      layer.cornerRadius = frame.cornerRadius
    }
  }

  private func addGeometryAnimations(
    to layer: CALayer,
    keyframes: SelectionKeyframes,
    beginTime: CFTimeInterval,
    prefix: String
  ) {
    addKeyframeAnimation(
      to: layer,
      keyPath: "bounds",
      values: keyframes.boundsValues,
      keyTimes: keyframes.keyTimes,
      beginTime: beginTime,
      key: "\(prefix).bounds"
    )
    addKeyframeAnimation(
      to: layer,
      keyPath: "position",
      values: keyframes.positionValues,
      keyTimes: keyframes.keyTimes,
      beginTime: beginTime,
      key: "\(prefix).position"
    )
    addKeyframeAnimation(
      to: layer,
      keyPath: "cornerRadius",
      values: keyframes.cornerRadiusValues,
      keyTimes: keyframes.keyTimes,
      beginTime: beginTime,
      key: "\(prefix).corner"
    )
  }

  private func addKeyframeAnimation(
    to layer: CALayer,
    keyPath: String,
    values: [Any],
    keyTimes: [NSNumber],
    beginTime: CFTimeInterval,
    key: String
  ) {
    let animation = CAKeyframeAnimation(keyPath: keyPath)
    animation.values = values
    animation.keyTimes = keyTimes
    animation.calculationMode = .linear
    animation.beginTime = beginTime
    animation.duration = CalendarZoomMotionSpec.selectorCompletionTime
    animation.fillMode = .both
    animation.isRemovedOnCompletion = true
    layer.add(animation, forKey: key)
  }
}
