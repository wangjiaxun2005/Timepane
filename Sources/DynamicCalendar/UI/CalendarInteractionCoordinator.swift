import Combine
import QuartzCore
import SwiftUI

@MainActor
final class CalendarInteractionCoordinator: ObservableObject {
  @Published private(set) var layers: [CalendarMotionLayer] = []
  @Published private(set) var titles: [CalendarTitleLayer] = []
  @Published private(set) var target: CalendarNavigationTarget?
  @Published private(set) var isActive = false
  @Published private(set) var handoffViewport: CalendarViewportState?
  @Published private(set) var preparingPage: CalendarViewportState?
  @Published private(set) var playbackTime: CGFloat = 0
  private(set) var playbackRevision = 0
  private(set) var generation = 0
  private weak var model: AppModel?
  private let clock: () -> TimeInterval
  private var presentationTime: TimeInterval?

  var currentTime: TimeInterval { presentationTime ?? clock() }

  func recordPresentationTime(_ time: TimeInterval) { presentationTime = time }

  func recordPlaybackPresentation(_ time: TimeInterval, revision: Int) {
    guard revision == playbackRevision else { return }
    recordPresentationTime(time)
  }

  func advancePlayback(to time: TimeInterval, revision: Int) {
    guard revision == playbackRevision, preparingPage == nil else { return }
    playbackTime = CGFloat(time)
  }

  private func rebasePlayback(at time: TimeInterval) {
    playbackRevision &+= 1
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    // Publish the clock with the replacement recipes, before SwiftUI renders
    // them. Resetting it later in a view task exposes the old destination time.
    withTransaction(transaction) { playbackTime = CGFloat(time) }
  }

  var playbackTracks: [CalendarMotionTrack] {
    layers.flatMap { [$0.zoomProgress, $0.chromeX, $0.eventsX] }
      + titles.flatMap { [$0.x, $0.y] }
  }
  private var nextLayerID = 0
  private var primaryID: Int?
  private var awaitingData = false
  private var trace: CalendarAnimationTraceToken?
  var reduceMotion = false
  var onModeChange: ((CalendarDisplayMode, CalendarDisplayMode) -> Void)?

  init(model: AppModel, clock: @escaping () -> TimeInterval = CACurrentMediaTime) {
    self.model = model
    self.clock = clock
  }

  var intendedMode: CalendarDisplayMode { target?.mode ?? model?.displayMode ?? .week }

  func submit(_ intent: CalendarInteractionIntent) {
    guard let model, model.route == .calendar else { return }
    var goal = target ?? CalendarNavigationTarget(mode: model.displayMode, date: model.currentFocusedDate)
    switch intent {
    case .movePeriod(let offset): goal = goal.moving(by: offset, calendar: model.calendar)
    case .today: goal.date = model.navigationToday
    case .displayMode(let mode): goal.mode = mode
    case .week(let date): goal = CalendarNavigationTarget(mode: .week, date: date)
    }
    guard goal != target else { return }
    if !isActive, goal.mode == intendedMode, goal.matches(model.viewport, calendar: model.calendar) {
      target = goal
      return
    }

    let sourceMode = intendedMode
    let defersPreparation = sourceMode != goal.mode && onModeChange != nil && !reduceMotion
    if sourceMode != goal.mode { onModeChange?(sourceMode, goal.mode) }
    generation &+= 1
    handoffViewport = nil
    preparingPage = nil
    CalendarAnimationTrace.end(trace, outcome: "retargeted")
    trace = CalendarAnimationTrace.begin(goal.mode == intendedMode ? .periodNavigation : .calendarZoom,
                                        generation: generation)
    target = goal
    if defersPreparation {
      let requestGeneration = generation
      Task { @MainActor in
        // Let the selector commit before constructing the calendar scene.
        await Task.yield()
        guard requestGeneration == self.generation else { return }
        self.prepareNavigation(to: goal)
      }
    } else {
      prepareNavigation(to: goal)
    }
  }

  private func prepareNavigation(to goal: CalendarNavigationTarget) {
    guard let model else { return }
    let now = currentTime
    model.selectedEvent = nil
    model.beginInteractiveNavigation()
    if layers.isEmpty {
      let layer = CalendarMotionLayer(id: allocateID(), viewport: model.viewport)
      layers = [layer]
      primaryID = layer.id
      titles = [CalendarTitleLayer(id: allocateID(), text: title(for: model.viewport))]
    }
    isActive = true
    awaitingData = false
    // Offscreen, settled exits must not accumulate during repeated input.
    layers.removeAll { $0.id != primaryID && $0.endTime <= now
      && (abs($0.chromeX.target) >= 1 || abs($0.eventsX.target) >= 1) }

    if let cached = cachedViewport(for: goal) {
      model.discardPreparedNavigation()
      transition(to: cached, at: now)
    } else if goal.mode == .week,
              let month = layers.first(where: {
                $0.destination.displayMode == .month
                  && $0.destination.periodSchedule.startDate <= goal.date
                  && $0.destination.periodSchedule.endDate > goal.date
              })?.destination {
      let scene = CalendarZoomScene.make(source: month, targetMode: .week,
        focusedDate: goal.date, calendar: model.calendar)
      model.discardPreparedNavigation()
      transition(to: scene.target, at: now)
    } else {
      awaitingData = true
      model.prepareDisplayMode(goal.mode, focusedDate: goal.date)
      preparedViewportChanged()
    }
  }

  func preparedViewportChanged() {
    guard awaitingData, let model, let target, let prepared = model.preparedViewport,
          target.matches(prepared, calendar: model.calendar),
          target.date == prepared.focusedDate else { return }
    awaitingData = false
    transition(to: prepared, at: currentTime)
  }

  func selectEvent(_ event: ScheduleEvent) {
    model?.selectedEvent = event
  }
  func dismissDetail() { model?.selectedEvent = nil }

  func reset() {
    playbackRevision &+= 1
    presentationTime = nil
    generation &+= 1
    layers = []
    titles = []
    primaryID = nil
    target = nil
    awaitingData = false
    handoffViewport = nil
    preparingPage = nil
    isActive = false
    CalendarAnimationTrace.end(trace, outcome: "cancelled")
    trace = nil
    model?.cancelInteractiveNavigation()
  }

  func installGeometry(layerID: Int, generation: Int,
                       frames: [CalendarZoomGeometryKey: CGRect]) {
    guard generation == self.generation,
          let index = layers.firstIndex(where: { $0.id == layerID }),
          layers[index].needsGeometry, let scene = layers[index].zoom else { return }
    let dates = scene.dateTracks.map(\.date)
    guard let source = CalendarZoomGeometrySnapshot.make(endpoint: .source, frames: frames, requiredDates: dates),
          let targetGeometry = CalendarZoomGeometrySnapshot.make(endpoint: .target, frames: frames, requiredDates: dates)
    else { return }
    layers[index].zoom = scene.installing(sourceGeometry: source, targetGeometry: targetGeometry)
    layers[index].needsGeometry = false
    layers[index].needsPresentation = true
    layers[index].zoomProgress = .constant(0)
  }

  func beginZoomAfterPresentation(layerID: Int, generation: Int) {
    guard generation == self.generation,
          let index = layers.firstIndex(where: { $0.id == layerID }),
          layers[index].needsPresentation, let scene = layers[index].zoom else { return }
    // Construct and render the bridge at its source before starting the clock.
    // Endpoint layout and view creation must not consume visible playback time.
    let now = currentTime
    rebasePlayback(at: now)
    layers[index].needsPresentation = false
    layers[index].zoomProgress = CalendarMotionTrack(startTime: now,
      duration: CalendarAnimationClock.zoomDuration, source: 0, target: 1,
      initialVelocity: 0, curve: .linear)
    if layerID == primaryID {
      retargetTitles(to: scene.target, from: scene.source, zoom: true, at: now)
    }
  }

  func beginPageAfterPresentation(token: CalendarViewportRenderToken) {
    guard let viewport = preparingPage, token.generation == generation,
          token.canvasSize.width > 0, token.canvasSize.height > 0,
          token == CalendarViewportRenderToken(viewport: viewport, generation: generation,
                                               canvasSize: token.canvasSize) else { return }
    preparingPage = nil
    // The recipes stay at their original starting sample while AppKit lays out
    // both pages. Restart the task only after that commit, retaining every
    // track's original curve, duration and stagger on this logical clock.
    rebasePlayback(at: Double(playbackTime))
    CalendarAnimationTrace.phase("Animating", token: trace)
  }

  func completeHandoff(token: CalendarViewportRenderToken) {
    guard let model, let viewport = handoffViewport,
          token.generation == generation,
          token == CalendarViewportRenderToken(viewport: viewport, generation: generation,
                                               canvasSize: token.canvasSize),
          token.canvasSize.width > 0, token.canvasSize.height > 0 else { return }
    // Commit only after the live destination has rendered; the preceding stage
    // stays visible throughout this handshake.
    model.commitInteractiveViewport(viewport)
    layers = []
    titles = []
    primaryID = nil
    handoffViewport = nil
    isActive = false
    CalendarAnimationTrace.end(trace)
    trace = nil
  }

  private func cachedViewport(for goal: CalendarNavigationTarget) -> CalendarViewportState? {
    guard let model else { return nil }
    for layer in layers.reversed() {
      if let scene = layer.zoom {
        if goal.matches(scene.source, calendar: model.calendar) { return scene.source }
        if goal.matches(scene.target, calendar: model.calendar) { return scene.target }
      }
      if goal.matches(layer.viewport, calendar: model.calendar) { return layer.viewport }
    }
    if goal.matches(model.viewport, calendar: model.calendar) { return model.viewport }
    if let prepared = model.preparedViewport,
       goal.matches(prepared, calendar: model.calendar) { return prepared }
    return nil
  }

  private func transition(to viewport: CalendarViewportState, at now: TimeInterval) {
    guard let model, let goal = target else { return }
    rebasePlayback(at: now)
    if reduceMotion {
      model.commitInteractiveViewport(viewport)
      layers = []
      titles = []
      isActive = false
      CalendarAnimationTrace.end(trace)
      trace = nil
      return
    }
    let previous = layers.first(where: { $0.id == primaryID })?.destination ?? model.viewport
    var destinationIndex = layers.firstIndex { layer in
      if let scene = layer.zoom {
        return goal.matches(scene.source, calendar: model.calendar)
          || goal.matches(scene.target, calendar: model.calendar)
      }
      return goal.matches(layer.viewport, calendar: model.calendar)
    }
    var startsZoom = false
    if let index = destinationIndex, let scene = layers[index].zoom {
      let end: CGFloat = goal.matches(scene.source, calendar: model.calendar) ? 0 : 1
      if layers[index].needsGeometry || layers[index].needsPresentation {
        if end == 0 {
          layers[index].viewport = scene.source
          layers[index].zoom = nil
          layers[index].needsGeometry = false
          layers[index].needsPresentation = false
        }
      } else if layers[index].zoomProgress.target != end {
        layers[index].zoomProgress = layers[index].zoomProgress.retarget(to: end, at: now,
          duration: CalendarAnimationClock.zoomDuration, curve: .continuation)
      }
    } else if destinationIndex == nil,
              let index = layers.firstIndex(where: { $0.id == primaryID }),
              layers[index].zoom == nil,
              layers[index].viewport.displayMode != viewport.displayMode {
      let source = layers[index].viewport
      layers[index].zoom = CalendarZoomScene.make(source: source, target: viewport,
        focusedDate: goal.date, calendar: model.calendar)
      layers[index].zoomProgress = .constant(1)
      layers[index].needsGeometry = true
      destinationIndex = index
      startsZoom = true
    }

    let navigationDirection: CGFloat = viewport.focusedDate < previous.focusedDate ? 1 : -1
    if destinationIndex == nil {
      var incoming = CalendarMotionLayer(id: allocateID(), viewport: viewport)
      incoming.chromeX = .constant(-navigationDirection)
      incoming.eventsX = .constant(-navigationDirection)
      layers.append(incoming)
      destinationIndex = layers.count - 1
    }
    guard let destinationIndex else { return }
    let destinationID = layers[destinationIndex].id
    let isInitialPage = layers.count == 2 && primaryID != destinationID
      && layers.allSatisfy { $0.zoom == nil && $0.chromeX.duration == 0 }
    if isInitialPage { preparingPage = viewport }
    for index in layers.indices {
      let isDestination = layers[index].id == destinationID
      let end: CGFloat
      if isDestination {
        end = 0
      } else {
        let date = layers[index].destination.focusedDate
        end = date == viewport.focusedDate ? navigationDirection : (date < viewport.focusedDate ? -1 : 1)
      }
      // An exit already headed in the right direction retains its original
      // deadline. New commands cannot keep invisible old pages alive forever.
      if !isDestination, layers[index].chromeX.target == end,
         layers[index].chromeX.duration > 0 { continue }
      if isInitialPage {
        layers[index].chromeX = CalendarMotionTrack(startTime: now,
          duration: CalendarAnimationClock.periodDuration,
          source: layers[index].chromeX.value(at: now), target: end, initialVelocity: 0, curve: .page)
        layers[index].eventsX = CalendarMotionTrack(startTime: now,
          duration: CalendarAnimationClock.periodDuration,
          source: layers[index].eventsX.value(at: now), target: end, initialVelocity: 0, curve: .pageEvents)
      } else if layers[index].chromeX.target != end || layers[index].chromeX.value(at: now) != end {
        layers[index].chromeX = layers[index].chromeX.retarget(to: end, at: now,
          duration: CalendarAnimationClock.periodDuration)
        layers[index].eventsX = layers[index].eventsX.retarget(to: end, at: now,
          duration: CalendarAnimationClock.periodDuration)
      }
    }
    primaryID = destinationID
    if !startsZoom {
      retargetTitles(to: viewport, from: previous,
                     zoom: previous.displayMode != viewport.displayMode, at: now)
    }
    CalendarAnimationTrace.phase(isInitialPage ? "PreparingPage" : "Animating", token: trace)
  }

  private func retargetTitles(to viewport: CalendarViewportState, from previous: CalendarViewportState,
                              zoom: Bool, at now: TimeInterval) {
    let text = title(for: viewport)
    let destinationID: Int
    if let existing = titles.first(where: { $0.text == text }) {
      destinationID = existing.id
    } else {
      destinationID = allocateID()
      var incoming = CalendarTitleLayer(id: destinationID, text: text)
      if zoom { incoming.y = .constant(viewport.displayMode == .month ? 28 : -28) }
      else { incoming.x = .constant(viewport.focusedDate < previous.focusedDate ? -168 : 168) }
      titles.append(incoming)
    }
    titles.removeAll { $0.id != destinationID &&
      (abs($0.x.value(at: now)) >= 168 || abs($0.y.value(at: now)) >= 28) }
    let fresh = titles.count == 2 && titles.allSatisfy { $0.x.duration == 0 && $0.y.duration == 0 }
    for index in titles.indices {
      let selected = titles[index].id == destinationID
      let endX: CGFloat = selected || zoom ? 0 : (viewport.focusedDate < previous.focusedDate ? 168 : -168)
      let endY: CGFloat = selected || !zoom ? 0 : (viewport.displayMode == .month ? -28 : 28)
      let duration = zoom ? CalendarZoomMotionSpec.titleCompletionTime : CalendarAnimationClock.periodDuration
      if fresh {
        titles[index].x = CalendarMotionTrack(startTime: now, duration: duration,
          source: titles[index].x.value(at: now), target: endX, initialVelocity: 0,
          curve: zoom ? .zoomTitle : .page)
        titles[index].y = CalendarMotionTrack(startTime: now, duration: duration,
          source: titles[index].y.value(at: now), target: endY, initialVelocity: 0,
          curve: zoom ? .zoomTitle : .page)
      } else {
        let curve = CalendarMotionTrack.Curve.spring(bounce: zoom ? 0.18 : 0.22)
        titles[index].x = titles[index].x.retarget(to: endX, at: now, duration: duration, curve: curve)
        titles[index].y = titles[index].y.retarget(to: endY, at: now, duration: duration, curve: curve)
      }
    }
    titles.removeAll { $0.id != destinationID && $0.x.endTime < now && $0.y.endTime < now }
  }

  @discardableResult
  func finishMotion(generation: Int) -> Bool {
    guard generation == self.generation, !awaitingData, preparingPage == nil,
          !layers.contains(where: { $0.needsGeometry || $0.needsPresentation }),
          layers.allSatisfy({ $0.endTime <= currentTime }),
          titles.allSatisfy({ max($0.x.endTime, $0.y.endTime) <= currentTime }),
          let primary = layers.first(where: { $0.id == primaryID }) else { return false }
    handoffViewport = primary.destination
    CalendarAnimationTrace.phase("Handoff", token: trace)
    return true
  }

  private func title(for viewport: CalendarViewportState) -> String {
    guard let model else { return "" }
    if viewport.displayMode == .month {
      return DateFormatting.monthAndYear.string(from: viewport.monthLayout.monthStart)
    }
    let end = model.calendar.date(byAdding: .day, value: -1, to: viewport.periodSchedule.endDate)
      ?? viewport.periodSchedule.endDate
    return "\(DateFormatting.shortDay.string(from: viewport.periodSchedule.startDate)) – \(DateFormatting.shortDay.string(from: end))"
  }

  private func allocateID() -> Int {
    nextLayerID &+= 1
    return nextLayerID
  }
}
