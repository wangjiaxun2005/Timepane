import QuartzCore
import SwiftUI

struct CalendarInteractionHost: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @EnvironmentObject private var motion: PanelMotionModel
  @ObservedObject var model: AppModel
  @ObservedObject var interaction: CalendarInteractionCoordinator
  let modeSelectionAnimator: CalendarModeSelectionAnimator
  let surfaceNamespace: Namespace.ID
  let onCollapse: () -> Void
  let onTogglePin: () -> Void
  let toolbarScale: CGFloat
  let toolbarOffset: CGSize
  let toolbarAnimation: Animation
  let gridScale: CGFloat
  let gridOffset: CGSize
  let gridAnimation: Animation
  @State private var pinch = CalendarZoomGestureSession()
  @GestureState private var isMagnifying = false

  var body: some View {
    CalendarPlaybackClock(interaction: interaction) {
      calendarContent
    }
  }

  private var calendarContent: some View {
    VStack(spacing: 0) {
      CalendarToolbar(model: model, creation: model.eventCreation, modeSelectionAnimator: modeSelectionAnimator,
        interaction: interaction, surfaceNamespace: surfaceNamespace,
        onCollapse: onCollapse, onTogglePin: onTogglePin,
        onMovePeriod: { interaction.submit(.movePeriod($0)) },
        onSelectDisplayMode: { interaction.submit(.displayMode($0)) })
        .scaleEffect(toolbarScale, anchor: .topTrailing)
        .offset(toolbarOffset)
        .animation(toolbarAnimation, value: motion.phase)
      Divider().opacity(0.6)
        .animation(toolbarAnimation, value: motion.phase)
      Group {
        if interaction.isActive {
          CalendarInteractionStage(model: model, interaction: interaction)
        } else {
          CalendarViewportPage(viewport: model.viewport, authorization: model.authorization,
            hasEnabledCalendars: !model.enabledCalendarIDs.isEmpty, calendar: model.calendar,
            zoomEndpoint: nil, onSelectEvent: interaction.selectEvent,
            onDismissDetail: interaction.dismissDetail,
            onSelectDay: { interaction.submit(.week($0)) },
            onOpenSettings: { model.route = .settings },
            onRequestCalendarAccess: { Task { await model.requestCalendarAccess() } },
            onOpenPrivacySettings: model.openCalendarPrivacySettings)
            .equatable()
        }
      }
      .clipped()
      .modifier(EventCreationCalendarInputGate(creation: model.eventCreation))
      .simultaneousGesture(DragGesture(minimumDistance: 36).onEnded { value in
        guard !model.eventCreation.isActive else { return }
        let actual = value.translation
        let predicted = value.predictedEndTranslation
        let horizontal = abs(predicted.width) > abs(actual.width) ? predicted.width : actual.width
        let vertical = abs(predicted.height) > abs(actual.height) ? predicted.height : actual.height
        if abs(horizontal) >= 64, abs(horizontal) > abs(vertical) * 1.2 {
          interaction.submit(.movePeriod(horizontal < 0 ? 1 : -1))
        }
      })
      .highPriorityGesture(calendarZoomGesture,
        including: pinch.isActive || interaction.intendedMode == .week ? .all : .subviews)
      .scaleEffect(gridScale, anchor: .topTrailing)
      .offset(gridOffset)
      .animation(gridAnimation, value: motion.phase)
    }
    .onChange(of: model.preparedViewport) { _, _ in interaction.preparedViewportChanged() }
    .onChange(of: isMagnifying) { _, active in
      // GestureState also resets when recognition is cancelled, unlike onEnded.
      if !active { pinch.end() }
    }
    .task(id: model.viewport.renderRevision) {
      await Task.yield()
      guard !Task.isCancelled, !interaction.isActive, model.displayMode == .week,
            model.authorization.canReadEvents, !model.enabledCalendarIDs.isEmpty else { return }
      model.prepareDisplayMode(.month)
    }
  }

  private var calendarZoomGesture: some Gesture {
    MagnifyGesture(minimumScaleDelta: CalendarZoomMotionSpec.recognitionDelta)
      .updating($isMagnifying) { _, active, _ in active = true }
      .onChanged { value in
        handleZoomMagnification(value.magnification)
      }
      .onEnded { value in
        // A short pinch may cross the threshold in its final delivered sample.
        handleZoomMagnification(value.magnification)
        pinch.end()
      }
  }

  private func handleZoomMagnification(_ magnification: CGFloat) {
    guard motion.phase == .expanded, !model.eventCreation.isActive,
          pinch.isActive || interaction.intendedMode == .week,
          model.authorization.canReadEvents, !model.enabledCalendarIDs.isEmpty else { return }
    let action = pinch.consume(magnification: magnification)
    if action == .prepare {
      model.prepareDisplayMode(.month, focusedDate: interaction.target?.date)
    } else if action == .trigger {
      interaction.submit(.displayMode(.month))
    }
  }

}

/// Only input changes rebuild the scene. SwiftUI interpolates the clock inside
/// the existing Animatable leaves, keeping static endpoint text and layout out
/// of the per-frame path.
struct CalendarPlaybackClock<Content: View>: View {
  @ObservedObject var interaction: CalendarInteractionCoordinator
  @ViewBuilder let content: () -> Content

  var body: some View {
    content()
      .environment(\.calendarPlaybackTime, interaction.playbackTime)
      .background {
        CalendarPresentationObserver(time: interaction.playbackTime,
          revision: interaction.playbackRevision, interaction: interaction)
          .allowsHitTesting(false)
      }
      .task(id: interaction.playbackRevision) {
        guard interaction.isActive, interaction.preparingPage == nil else { return }
        let generation = interaction.generation
        let revision = interaction.playbackRevision
        let start = Double(interaction.playbackTime)
        let end = max(start, interaction.playbackTracks.map(\.endTime).max() ?? start)
        await Task.yield()
        guard !Task.isCancelled, generation == interaction.generation,
              revision == interaction.playbackRevision else { return }
        guard end > start else {
          _ = interaction.finishMotion(generation: generation)
          return
        }
        withAnimation(.linear(duration: end - start), completionCriteria: .removed) {
          interaction.advancePlayback(to: end, revision: revision)
        } completion: {
          guard generation == interaction.generation,
                revision == interaction.playbackRevision else { return }
          interaction.recordPlaybackPresentation(end, revision: revision)
          _ = interaction.finishMotion(generation: generation)
        }
      }
  }
}

private struct CalendarPresentationObserver: View, Animatable {
  var time: CGFloat
  let revision: Int
  let interaction: CalendarInteractionCoordinator
  var animatableData: CGFloat {
    get { time }
    set {
      time = newValue
      // Record interpolated presentation samples, not body evaluations of the
      // model destination. Replaced animations cannot overwrite the new clock.
      interaction.recordPlaybackPresentation(Double(newValue), revision: revision)
    }
  }
  var body: some View {
    Color.clear.frame(width: 1, height: 1)
  }
}

private struct CalendarPlaybackTimeKey: EnvironmentKey {
  static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
  var calendarPlaybackTime: CGFloat {
    get { self[CalendarPlaybackTimeKey.self] }
    set { self[CalendarPlaybackTimeKey.self] = newValue }
  }
}

struct CalendarInteractionStage: View {
  @Environment(\.calendarPlaybackTime) private var time
  let model: AppModel
  @ObservedObject var interaction: CalendarInteractionCoordinator

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        ForEach(interaction.layers) { layer in
          Group {
            if layer.zoom == nil {
              page(layer, eventsOnly: false)
                .modifier(CalendarTrackOffset(time: time, x: layer.chromeX,
                  scaleX: geometry.size.width))
            }
          }
        }
        ForEach(interaction.layers) { layer in
          Group {
            if layer.zoom == nil {
              page(layer, eventsOnly: true)
                .modifier(CalendarTrackOffset(time: time, x: layer.eventsX,
                  scaleX: geometry.size.width))
            } else {
              zoom(layer, time: time, size: geometry.size)
            }
          }
        }
        if let viewport = interaction.handoffViewport {
          CalendarRenderCommitProbe(token: CalendarViewportRenderToken(viewport: viewport,
            generation: interaction.generation, canvasSize: geometry.size),
            onCommitted: interaction.completeHandoff)
            .frame(width: 1, height: 1).allowsHitTesting(false)
        }
        if let viewport = interaction.preparingPage {
          CalendarRenderCommitProbe(token: CalendarViewportRenderToken(viewport: viewport,
            generation: interaction.generation, canvasSize: geometry.size),
            onCommitted: interaction.beginPageAfterPresentation)
            .frame(width: 1, height: 1).allowsHitTesting(false)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      .clipped()
    }
  }

  private func page(_ layer: CalendarMotionLayer, eventsOnly: Bool) -> some View {
    CalendarViewportContent(viewport: layer.viewport, calendar: model.calendar,
      onSelectEvent: interaction.selectEvent, onDismissDetail: interaction.dismissDetail,
      onSelectDay: { interaction.submit(.week($0)) },
      hidesAllEvents: !eventsOnly, eventsOnly: eventsOnly)
      .equatable()
  }

  private func zoom(_ layer: CalendarMotionLayer, time: CGFloat, size: CGSize) -> some View {
    let generation = interaction.generation
    return CalendarZoomEndpointHost(viewport: layer.viewport, scene: layer.zoom,
      phase: layer.needsGeometry ? .preparing : .animating,
      progress: layer.needsGeometry ? 0 : time,
      clock: layer.needsGeometry ? nil : layer.zoomProgress,
      generation: generation, authorization: model.authorization,
      hasEnabledCalendars: !model.enabledCalendarIDs.isEmpty, calendar: model.calendar,
      onSelectEvent: interaction.selectEvent, onDismissDetail: interaction.dismissDetail,
      onSelectDay: { interaction.submit(.week($0)) },
      onOpenSettings: { interaction.reset(); model.route = .settings },
      onRequestCalendarAccess: { Task { await model.requestCalendarAccess() } },
      onOpenPrivacySettings: model.openCalendarPrivacySettings,
      onRenderCommitted: { _ in })
      .environment(\.calendarEventOffset, layer.chromeX == layer.eventsX
        ? CalendarEventMotion()
        : CalendarEventMotion(time: time, chrome: layer.chromeX, events: layer.eventsX, width: size.width))
      .coordinateSpace(name: CalendarZoomCoordinateSpace.name)
      .onPreferenceChange(CalendarZoomGeometryPreferenceKey.self) { frames in
        interaction.installGeometry(layerID: layer.id, generation: generation, frames: frames)
      }
      .overlay(alignment: .topLeading) {
        if layer.needsPresentation, let scene = layer.zoom {
          CalendarRenderCommitProbe(token: CalendarViewportRenderToken(viewport: scene.target,
            generation: generation, canvasSize: size)) { token in
              interaction.beginZoomAfterPresentation(layerID: layer.id, generation: token.generation)
            }
            .frame(width: 1, height: 1).allowsHitTesting(false)
        }
      }
      .modifier(CalendarTrackOffset(time: time, x: layer.chromeX, scaleX: size.width))
  }
}

private struct CalendarTrackOffset: AnimatableModifier {
  var time: CGFloat
  let x: CalendarMotionTrack
  var y: CalendarMotionTrack = .constant(0)
  var scaleX: CGFloat = 1

  var animatableData: CGFloat {
    get { time }
    set { time = newValue }
  }

  func body(content: Content) -> some View {
    content.offset(x: x.value(at: Double(time)) * scaleX, y: y.value(at: Double(time)))
  }
}

struct CalendarInteractionTitle: View {
  @Environment(\.calendarPlaybackTime) private var time
  @ObservedObject var interaction: CalendarInteractionCoordinator
  var body: some View {
    Group {
      ZStack(alignment: .leading) {
        ForEach(interaction.titles) { title in
          Text(title.text)
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .modifier(CalendarTrackOffset(time: time, x: title.x, y: title.y))
        }
      }
      .clipped()
    }
  }
}

struct CalendarEventMotion: Equatable {
  var time: CGFloat = 0
  var chrome = CalendarMotionTrack.constant(0)
  var events = CalendarMotionTrack.constant(0)
  var width: CGFloat = 0
}

struct CalendarEventOffsetModifier: AnimatableModifier {
  var motion: CalendarEventMotion
  var animatableData: CGFloat {
    get { motion.time }
    set { motion.time = newValue }
  }
  func body(content: Content) -> some View {
    content.offset(x: (motion.events.value(at: Double(motion.time))
      - motion.chrome.value(at: Double(motion.time))) * motion.width)
  }
}

private struct CalendarEventOffsetKey: EnvironmentKey {
  static let defaultValue = CalendarEventMotion()
}

extension EnvironmentValues {
  var calendarEventOffset: CalendarEventMotion {
    get { self[CalendarEventOffsetKey.self] }
    set { self[CalendarEventOffsetKey.self] = newValue }
  }
}
