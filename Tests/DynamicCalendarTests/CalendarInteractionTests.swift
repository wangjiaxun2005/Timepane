import AppKit
import Combine
import SwiftUI
import XCTest
@testable import DynamicCalendar

final class CalendarMotionTrackTests: XCTestCase {
  func testPinchTriggersOnlyOnceUntilFingersLift() {
    var gesture = CalendarZoomGestureSession()
    XCTAssertEqual(gesture.consume(magnification: 0.99), .prepare)
    XCTAssertEqual(gesture.consume(magnification: 0.98), .none)
    XCTAssertEqual(gesture.consume(magnification: 0.96), .trigger)
    XCTAssertEqual(gesture.consume(magnification: 0.7), .none)
    XCTAssertTrue(gesture.isActive)
    gesture.end()
    XCTAssertFalse(gesture.isActive)
    XCTAssertEqual(gesture.consume(magnification: 0.7), .trigger)
  }

  func testEveryTrackRetargetsWithContinuousPositionAndVelocity() {
    for curve in [CalendarMotionTrack.Curve.linear, .page, .pageEvents, .zoomTitle] {
      let duration = curve == .zoomTitle ? 0.24 : 0.5
      let original = CalendarMotionTrack(startTime: 10, duration: duration,
        source: 0, target: 1, initialVelocity: 0, curve: curve)
      for fraction in [0.0, 0.06, 0.3, 0.65, 0.94, 1.0] {
        let time = 10 + fraction * duration
        let previous = original.sample(at: time)
        let reverse = original.retarget(to: 0, at: time, duration: 0.3)
        XCTAssertEqual(reverse.sample(at: time).value, previous.value, accuracy: 0.000001)
        XCTAssertEqual(reverse.sample(at: time).velocity, previous.velocity, accuracy: 0.000001)
        XCTAssertEqual(reverse.value(at: time + 0.3), 0, accuracy: 0.000001)
        XCTAssertEqual(reverse.sample(at: time + 0.3).velocity, 0, accuracy: 0.000001)
      }
    }
  }

  func testRepeatedRetargetsRemainFiniteAndEndAtLatestTarget() {
    var trajectory = CalendarMotionTrack(startTime: 0, duration: 0.5,
      source: 0, target: 1, initialVelocity: 0, curve: .linear)
    for index in 1...100 {
      let now = Double(index) * 0.017
      let before = trajectory.sample(at: now)
      trajectory = trajectory.retarget(to: index.isMultiple(of: 2) ? 1 : 0,
        at: now, duration: 0.3)
      XCTAssertEqual(trajectory.sample(at: now), before)
      XCTAssertTrue(trajectory.value(at: now + 0.01).isFinite)
    }
    XCTAssertEqual(trajectory.value(at: 3), 1)
    XCTAssertEqual(trajectory.sample(at: 3).velocity, 0)
  }

  func testUninterruptedZoomUsesOriginalClockAndCurves() {
    let track = CalendarMotionTrack(startTime: 0, duration: CalendarAnimationClock.zoomDuration,
      source: 0, target: 1, initialVelocity: 0, curve: .linear)
    for index in 0...100 {
      let progress = CGFloat(index) / 100
      XCTAssertEqual(track.value(at: Double(progress) * 0.5), progress, accuracy: 0.000001)
      XCTAssertEqual(CalendarZoomMotionSpec.eventProgress(track.value(at: Double(progress) * 0.5)),
                     CalendarZoomMotionSpec.eventProgress(progress), accuracy: 0.000001)
    }
  }

  func testInterruptedPageKeepsTheOriginalSpringResponseAndRebound() {
    let initial = CalendarMotionTrack(startTime: 0, duration: 0.48,
      source: 0, target: 1, initialVelocity: 0, curve: .page)
    let now = 0.12
    let sample = initial.sample(at: now)
    let reverse = initial.retarget(to: 0, at: now, duration: 0.48)
    let spring = Spring(duration: 0.48, bounce: 0.22)
    for elapsed in [0.01, 0.06, 0.12, 0.24, 0.36] {
      XCTAssertEqual(reverse.value(at: now + elapsed), sample.value
        + spring.value(target: -sample.value, initialVelocity: sample.velocity, time: elapsed),
        accuracy: 0.000001)
    }
    XCTAssertLessThan(reverse.value(at: now + 0.36), 0, "Retargeting must retain the restrained rebound")
  }

  func testPageAndEventTracksSettleWithoutAnEndpointJump() {
    for curve in [CalendarMotionTrack.Curve.page, .pageEvents] {
      let track = CalendarMotionTrack(startTime: 0, duration: 0.48,
        source: 0, target: 1, initialVelocity: 0, curve: curve)
      XCTAssertEqual(track.value(at: 0.48 - 0.000001), 1, accuracy: 0.000001)
      XCTAssertEqual(track.sample(at: 0.48 - 0.000001).velocity, 0, accuracy: 0.001)
      let original = Spring(duration: 0.48, bounce: 0.22)
      let raw = original.value(target: 1, initialVelocity: 0.35, time: 0.36)
      XCTAssertEqual(track.value(at: 0.36),
        curve == .pageEvents ? CalendarPeriodMotionCurve.eventTravel(raw) : raw, accuracy: 0.000001)
    }
  }
}

@MainActor
final class CalendarInteractionTests: XCTestCase {
  private var model: AppModel!
  private var interaction: CalendarInteractionCoordinator!
  private var time: TimeInterval = 100
  private var defaults: UserDefaults!
  private var suite: String!

  override func setUp() async throws {
    suite = "Timepane.InteractionTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.firstWeekday = 1
    let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 12))!
    let onboarding = OnboardingStore(defaults: defaults)
    onboarding.markComplete()
    model = AppModel(provider: InteractionTestProvider(),
      selectionStore: CalendarSelectionStore(defaults: defaults),
      onboardingStore: onboarding, calendar: calendar, now: date, nowProvider: { date })
    time = 100
    interaction = CalendarInteractionCoordinator(model: model, clock: { [unowned self] in self.time })
  }

  override func tearDown() async throws {
    interaction.reset()
    interaction = nil
    model = nil
    defaults.removePersistentDomain(forName: suite)
  }

  func testRepeatingTheCurrentModeTargetDoesNotRestartMotion() async throws {
    interaction.submit(.displayMode(.month))
    try await resolvePreparation()
    try installGeometry()
    time += 0.1
    let generation = interaction.generation
    let track = interaction.layers[0].zoomProgress
    interaction.submit(.displayMode(.month))
    XCTAssertEqual(interaction.generation, generation)
    XCTAssertEqual(interaction.layers[0].zoomProgress, track)
  }

  func testSelectorStartsBeforeCalendarPreparationAndSurvivesViewUpdate() async throws {
    let animator = CalendarModeSelectionAnimator()
    let selector = CalendarModeSelectionNSView(frame: CGRect(x: 0, y: 0, width: 76, height: 26))
    let window = NSWindow(contentRect: selector.frame, styleMask: .borderless,
      backing: .buffered, defer: false)
    window.contentView = selector
    selector.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    animator.attach(selector, committedMode: .week)
    let preparation = expectation(description: "calendar preparation after selector commit")
    let observation = interaction.$isActive.filter { $0 }.first().sink { _ in preparation.fulfill() }
    defer { observation.cancel() }
    var receivedFeedback = false
    interaction.onModeChange = { [unowned self] source, target in
      XCTAssertFalse(self.interaction.isActive)
      XCTAssertTrue(self.interaction.layers.isEmpty)
      animator.play(from: source, to: target)
      receivedFeedback = true
    }
    interaction.submit(.displayMode(.month))
    XCTAssertTrue(receivedFeedback)
    XCTAssertEqual(interaction.intendedMode, .month)
    XCTAssertFalse(interaction.isActive, "Scene construction must yield to selector feedback")
    animator.attach(selector, committedMode: .week)
    let lens = try XCTUnwrap(selector.layer?.sublayers?.first {
      $0.animation(forKey: "selector.lens.position") != nil
    })
    let animation = try XCTUnwrap(lens.animation(forKey: "selector.lens.position"))
    XCTAssertEqual(animation.duration, CalendarZoomMotionSpec.selectorCompletionTime, accuracy: 0.0001)
    await fulfillment(of: [preparation], timeout: 2)
    try await resolvePreparation()
    XCTAssertTrue(interaction.isActive)
  }

  func testReversingBeforeScenePreparationCancelsThePendingModeChange() async throws {
    var feedback: [CalendarDisplayMode] = []
    interaction.onModeChange = { _, target in feedback.append(target) }
    interaction.submit(.displayMode(.month))
    interaction.submit(.displayMode(.week))
    XCTAssertEqual(feedback, [.month, .week])
    try await Task.sleep(for: .milliseconds(10))
    try await resolvePreparation()
    XCTAssertEqual(interaction.intendedMode, .week)
    XCTAssertTrue(interaction.layers.allSatisfy { $0.zoom == nil })
  }

  func testEarlyZoomReversalKeepsFullPlaybackDuration() async throws {
    interaction.submit(.displayMode(.month))
    try await resolvePreparation()
    try installGeometry()
    time += 0.05
    interaction.submit(.displayMode(.week))
    XCTAssertEqual(interaction.layers[0].zoomProgress.duration, CalendarAnimationClock.zoomDuration)
    time += 0.13
    XCTAssertFalse(interaction.finishMotion(generation: interaction.generation))
    try commitLatest()
  }

  func testSlowBridgePreparationDoesNotConsumeZoomPlaybackTime() async throws {
    interaction.submit(.displayMode(.month))
    try await resolvePreparation()
    let layer = try XCTUnwrap(interaction.layers.first)
    let generation = interaction.generation
    interaction.installGeometry(layerID: layer.id, generation: generation,
      frames: geometryFrames(for: try XCTUnwrap(layer.zoom)))
    time += 0.4
    XCTAssertTrue(interaction.layers[0].needsPresentation)
    XCTAssertEqual(interaction.layers[0].zoomProgress.value(at: time), 0)
    XCTAssertFalse(interaction.finishMotion(generation: generation))
    interaction.beginZoomAfterPresentation(layerID: layer.id, generation: generation - 1)
    XCTAssertTrue(interaction.layers[0].needsPresentation)
    interaction.beginZoomAfterPresentation(layerID: layer.id, generation: generation)
    XCTAssertEqual(interaction.layers[0].zoomProgress.value(at: time), 0)
    time += 0.25
    XCTAssertEqual(interaction.layers[0].zoomProgress.value(at: time), 0.5, accuracy: 0.000001)
    try commitLatest()
  }

  func testThreeRapidPageRequestsAccumulateFromIntendedDate() async throws {
    let start = model.currentFocusedDate
    interaction.submit(.movePeriod(1))
    interaction.submit(.movePeriod(1))
    interaction.submit(.movePeriod(1))
    try await resolvePreparation()
    XCTAssertEqual(interaction.target?.date, model.calendar.date(byAdding: .day, value: 21, to: start))
    XCTAssertEqual(model.currentFocusedDate, start)
    try commitLatest()
    XCTAssertEqual(model.currentFocusedDate, model.calendar.date(byAdding: .day, value: 21, to: start))
  }

  func testReversingDuringFirstFramePreparationInvalidatesItsCallback() async throws {
    interaction.submit(.displayMode(.month))
    try await resolvePreparation()
    let layer = try XCTUnwrap(interaction.layers.first)
    let generation = interaction.generation
    interaction.installGeometry(layerID: layer.id, generation: generation,
      frames: geometryFrames(for: try XCTUnwrap(layer.zoom)))
    interaction.submit(.displayMode(.week))
    interaction.beginZoomAfterPresentation(layerID: layer.id, generation: generation)
    XCTAssertNil(interaction.layers[0].zoom)
    XCTAssertFalse(interaction.layers[0].needsPresentation)
    try commitLatest()
    XCTAssertEqual(model.displayMode, .week)
  }

  func testReversePageKeepsBothChromeAndEventVelocities() async throws {
    interaction.submit(.movePeriod(1))
    try await resolvePreparation()
    time += 0.12
    let oldLayers = interaction.layers
    let generation = interaction.generation
    interaction.submit(.movePeriod(-1))
    for layer in oldLayers {
      let current = try XCTUnwrap(interaction.layers.first(where: { $0.id == layer.id }))
      XCTAssertEqual(current.chromeX.sample(at: time), layer.chromeX.sample(at: time))
      XCTAssertEqual(current.eventsX.sample(at: time), layer.eventsX.sample(at: time))
    }
    XCTAssertFalse(interaction.finishMotion(generation: generation))
    try commitLatest()
    XCTAssertEqual(model.calendar.component(.day, from: model.currentFocusedDate), 13)
  }

  func testReversedPageFirstRenderUsesThePresentedClock() async throws {
    let samples = PlaybackProbeSamples()
    let host = NSHostingView(rootView: CalendarPlaybackClock(interaction: interaction) {
      PlaybackProbe(interaction: self.interaction, samples: samples)
    })
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    interaction.submit(.movePeriod(1))
    try await resolvePreparation()
    let original = try XCTUnwrap(interaction.layers.first?.chromeX)
    for _ in 0..<100 {
      host.layoutSubtreeIfNeeded()
      if samples.values.contains(where: { $0.time >= original.endTime }) { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(samples.values.contains { $0.time >= original.endTime })
    let presentedTime = original.startTime + 0.12
    interaction.recordPresentationTime(presentedTime)
    interaction.submit(.movePeriod(-1))
    let reversed = try XCTUnwrap(interaction.layers.first?.chromeX)
    for _ in 0..<100 {
      host.layoutSubtreeIfNeeded()
      if samples.values.contains(where: { $0.track == reversed }) { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let first = try XCTUnwrap(samples.values.first { $0.track == reversed })
    XCTAssertEqual(first.time, presentedTime, accuracy: 0.000001,
      "The replacement recipe must never render with the previous animation's destination clock")
    XCTAssertEqual(first.track.value(at: first.time), original.value(at: presentedTime), accuracy: 0.000001)
    withExtendedLifetime(window) {}
  }

  func testReplacedPlaybackCannotOverwriteTheReversedPageClock() async throws {
    interaction.submit(.movePeriod(1))
    try await resolvePreparation()
    let oldRevision = interaction.playbackRevision
    let presentedTime = time + 0.12
    interaction.recordPlaybackPresentation(presentedTime, revision: oldRevision)
    interaction.submit(.movePeriod(-1))
    XCTAssertNotEqual(interaction.playbackRevision, oldRevision)
    XCTAssertEqual(Double(interaction.playbackTime), presentedTime)
    interaction.recordPlaybackPresentation(time + 0.48, revision: oldRevision)
    interaction.advancePlayback(to: time + 0.48, revision: oldRevision)
    XCTAssertEqual(interaction.currentTime, presentedTime)
    XCTAssertEqual(Double(interaction.playbackTime), presentedTime)
  }

  func testRetargetSamplesPresentedPositionWhenRenderingLagsBehindWallTime() async throws {
    interaction.submit(.movePeriod(1))
    try await resolvePreparation()
    let oldLayers = interaction.layers
    let visibleTime = time + 0.1
    interaction.recordPresentationTime(visibleTime)
    time += 0.4
    interaction.submit(.movePeriod(-1))
    for old in oldLayers {
      let current = try XCTUnwrap(interaction.layers.first(where: { $0.id == old.id }))
      XCTAssertEqual(current.chromeX.startTime, visibleTime)
      XCTAssertEqual(current.chromeX.sample(at: visibleTime), old.chromeX.sample(at: visibleTime))
      XCTAssertEqual(current.eventsX.sample(at: visibleTime), old.eventsX.sample(at: visibleTime))
    }
    interaction.recordPresentationTime(time + 1)
    try commitLatest()
  }

  func testWallClockDeadlineCannotCutOffUnfinishedPresentation() async throws {
    interaction.submit(.displayMode(.month))
    try await resolvePreparation()
    try installGeometry()
    let start = time
    interaction.recordPresentationTime(start + 0.1)
    time += 0.8
    XCTAssertFalse(interaction.finishMotion(generation: interaction.generation))
    interaction.recordPresentationTime(start + 0.5)
    try commitLatest()
  }

  func testZoomReversesTheLiveSceneWithoutRebuildingItsEndpoints() async throws {
    interaction.submit(.displayMode(.month))
    try await resolvePreparation()
    try installGeometry()
    time += 0.18
    let old = try XCTUnwrap(interaction.layers.first)
    let sample = old.zoomProgress.sample(at: time)
    interaction.submit(.displayMode(.week))
    let reversed = try XCTUnwrap(interaction.layers.first)
    XCTAssertEqual(old.id, reversed.id)
    XCTAssertEqual(old.zoom, reversed.zoom)
    XCTAssertEqual(reversed.zoomProgress.sample(at: time), sample)
    XCTAssertEqual(reversed.zoomProgress.target, 0)
    try commitLatest()
    XCTAssertEqual(model.displayMode, .week)
  }

  func testPreparationKeepsSourceAndRejectsIncompleteOrStaleGeometry() async throws {
    interaction.submit(.displayMode(.month))
    try await resolvePreparation()
    let layer = try XCTUnwrap(interaction.layers.first)
    XCTAssertTrue(layer.needsGeometry)
    XCTAssertFalse(interaction.finishMotion(generation: interaction.generation))
    interaction.installGeometry(layerID: layer.id, generation: interaction.generation, frames: [:])
    XCTAssertTrue(interaction.layers[0].needsGeometry)
    interaction.installGeometry(layerID: layer.id, generation: interaction.generation - 1,
                                frames: geometryFrames(for: try XCTUnwrap(layer.zoom)))
    XCTAssertTrue(interaction.layers[0].needsGeometry)
    try installGeometry()
    XCTAssertFalse(interaction.layers[0].needsGeometry)
    XCTAssertEqual(interaction.layers[0].zoomProgress.value(at: time), 0)
  }

  func testPageThenModeSwitchPreservesTheMovingPagePosition() async throws {
    interaction.submit(.movePeriod(1))
    try await resolvePreparation()
    time += 0.13
    let incoming = try XCTUnwrap(interaction.layers.last)
    interaction.submit(.displayMode(.month))
    try await resolvePreparation()
    let morph = try XCTUnwrap(interaction.layers.first(where: { $0.id == incoming.id }))
    XCTAssertNotNil(morph.zoom)
    XCTAssertEqual(morph.chromeX.sample(at: time), incoming.chromeX.sample(at: time))
    XCTAssertEqual(morph.eventsX.sample(at: time), incoming.eventsX.sample(at: time))
    try installGeometry()
    try commitLatest()
    XCTAssertEqual(model.displayMode, .month)
  }

  func testZoomThenPageDoesNotResetTheOutgoingMorph() async throws {
    interaction.submit(.displayMode(.month))
    try await resolvePreparation()
    try installGeometry()
    time += 0.13
    let outgoing = try XCTUnwrap(interaction.layers.first)
    interaction.submit(.movePeriod(1))
    try await resolvePreparation()
    let continuing = try XCTUnwrap(interaction.layers.first(where: { $0.id == outgoing.id }))
    XCTAssertEqual(continuing.zoomProgress, outgoing.zoomProgress)
    XCTAssertEqual(continuing.chromeX.value(at: time), outgoing.chromeX.value(at: time))
    try commitLatest()
    XCTAssertEqual(model.displayMode, .month)
    XCTAssertEqual(model.calendar.component(.month, from: model.currentFocusedDate), 10)
  }

  func testTodayOverridesPendingNavigationAndLatePreparation() async throws {
    interaction.submit(.movePeriod(3))
    interaction.submit(.today)
    try commitLatest()
    for _ in 0..<10 { await Task.yield() }
    interaction.preparedViewportChanged()
    XCTAssertEqual(model.calendar.component(.day, from: model.currentFocusedDate), 13)
    XCTAssertFalse(interaction.isActive)
  }

  func testSelectionMadeDuringMotionSurvivesTheCommit() async throws {
    interaction.submit(.movePeriod(1))
    try await resolvePreparation()
    let event = ScheduleEvent(id: "selected", title: "Selected event", startDate: model.currentFocusedDate,
      endDate: model.currentFocusedDate.addingTimeInterval(3600), isAllDay: false,
      location: nil, notes: nil, url: nil, calendarID: "test", calendarTitle: "Test", colorHex: "#123456")
    interaction.selectEvent(event)
    try commitLatest()
    XCTAssertEqual(model.selectedEvent, event)
    interaction.submit(.movePeriod(1))
    XCTAssertNil(model.selectedEvent)
  }

  func testResetInvalidatesHandoffAndPendingPreparation() async throws {
    interaction.submit(.movePeriod(1))
    let oldGeneration = interaction.generation
    interaction.reset()
    for _ in 0..<10 { await Task.yield() }
    interaction.preparedViewportChanged()
    XCTAssertFalse(interaction.finishMotion(generation: oldGeneration))
    XCTAssertFalse(interaction.isActive)
    XCTAssertTrue(interaction.layers.isEmpty)
    XCTAssertNil(interaction.target)
  }

  func testReducedMotionCommitsLatestTargetWithoutAnimationLayers() async throws {
    interaction.reduceMotion = true
    interaction.submit(.movePeriod(2))
    try await resolvePreparation()
    XCTAssertFalse(interaction.isActive)
    XCTAssertTrue(interaction.layers.isEmpty)
    XCTAssertEqual(model.calendar.component(.day, from: model.currentFocusedDate), 27)
  }

  func testRepeatedPagesReleaseOldLayersAndTitles() async throws {
    for _ in 0..<20 {
      interaction.submit(.movePeriod(1))
      try await resolvePreparation()
      time += 0.1
    }
    XCTAssertLessThan(interaction.layers.count, 10)
    XCTAssertLessThan(interaction.titles.count, 10)
    try commitLatest()
    XCTAssertTrue(interaction.layers.isEmpty)
    XCTAssertTrue(interaction.titles.isEmpty)
  }

  func testPagePlaybackWaitsForLayoutWithoutChangingItsRecipes() async throws {
    interaction.submit(.movePeriod(1))
    try await resolvePreparation(presentPage: false)
    let viewport = try XCTUnwrap(interaction.preparingPage)
    let start = interaction.playbackTime
    let revision = interaction.playbackRevision
    let tracks = interaction.playbackTracks
    interaction.advancePlayback(to: Double(start) + 1, revision: revision)
    XCTAssertEqual(interaction.playbackTime, start)
    XCTAssertFalse(interaction.finishMotion(generation: interaction.generation))
    interaction.beginPageAfterPresentation(token: CalendarViewportRenderToken(viewport: viewport,
      generation: interaction.generation - 1, canvasSize: CGSize(width: 760, height: 564)))
    XCTAssertNotNil(interaction.preparingPage)
    interaction.beginPageAfterPresentation(token: CalendarViewportRenderToken(viewport: viewport,
      generation: interaction.generation, canvasSize: CGSize(width: 760, height: 564)))
    XCTAssertNil(interaction.preparingPage)
    XCTAssertNotEqual(interaction.playbackRevision, revision)
    XCTAssertEqual(interaction.playbackTime, start)
    XCTAssertEqual(interaction.playbackTracks, tracks)
  }

  private func resolvePreparation(presentPage: Bool = true) async throws {
    for _ in 0..<200 {
      interaction.preparedViewportChanged()
      if let target = interaction.target,
         interaction.layers.contains(where: { target.matches($0.destination, calendar: model.calendar) })
          || !interaction.isActive {
        if presentPage, let viewport = interaction.preparingPage {
          interaction.beginPageAfterPresentation(token: CalendarViewportRenderToken(viewport: viewport,
            generation: interaction.generation, canvasSize: CGSize(width: 760, height: 564)))
        }
        return
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Target did not prepare")
  }

  private func installGeometry() throws {
    for layer in interaction.layers where layer.needsGeometry {
      interaction.installGeometry(layerID: layer.id, generation: interaction.generation,
        frames: geometryFrames(for: try XCTUnwrap(layer.zoom)))
      interaction.beginZoomAfterPresentation(layerID: layer.id, generation: interaction.generation)
    }
  }

  private func geometryFrames(for scene: CalendarZoomScene) -> [CalendarZoomGeometryKey: CGRect] {
    var frames: [CalendarZoomGeometryKey: CGRect] = [:]
    for endpoint in [CalendarZoomEndpoint.source, .target] {
      frames[CalendarZoomGeometryKey(endpoint: endpoint, element: .canvas)] = CGRect(x: 0, y: 0, width: 760, height: 564)
      for track in scene.dateTracks {
        frames[CalendarZoomGeometryKey(endpoint: endpoint, element: .date(track.date))] =
          CGRect(x: CGFloat(48 + track.dayIndex * 100), y: endpoint == .source ? 20 : 180, width: 24, height: 24)
      }
    }
    return frames
  }

  private func commitLatest() throws {
    time += 1
    XCTAssertTrue(interaction.finishMotion(generation: interaction.generation))
    let viewport = try XCTUnwrap(interaction.handoffViewport)
    interaction.completeHandoff(token: CalendarViewportRenderToken(viewport: viewport,
      generation: interaction.generation, canvasSize: CGSize(width: 760, height: 564)))
    XCTAssertFalse(interaction.isActive)
  }
}

@MainActor
private final class PlaybackProbeSamples {
  var values: [(track: CalendarMotionTrack, time: TimeInterval)] = []
}

@MainActor
private struct PlaybackProbe: View {
  @Environment(\.calendarPlaybackTime) private var time
  @ObservedObject var interaction: CalendarInteractionCoordinator
  let samples: PlaybackProbeSamples

  var body: some View {
    if let track = interaction.layers.first?.chromeX {
      let _ = samples.values.append((track, Double(time)))
    }
    Color.clear.frame(width: 100, height: 100)
  }
}

@MainActor
private final class InteractionTestProvider: CalendarProviding {
  var onCalendarStoreChanged: (() -> Void)?
  func authorizationStatus() -> CalendarAuthorizationState { .fullAccess }
  func requestFullAccess() async -> CalendarAuthorizationState { .fullAccess }
  func availableCalendars() async -> [CalendarSource] { [] }
  func events(in interval: DateInterval, calendarIDs: Set<String>) async -> [ScheduleEvent] { [] }
}
