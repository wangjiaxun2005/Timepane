import AppKit
import SwiftUI
import XCTest
@testable import DynamicCalendar

final class CalendarZoomTransitionTests: XCTestCase {
  private let tracker = CalendarZoomGestureTracker()

  func testWeekPinchProducesDiscretePreparationAndTriggerActions() {
    XCTAssertEqual(action(magnification: 0.991, mode: .week), .none)
    XCTAssertEqual(action(magnification: 0.99, mode: .week), .prepare)
    XCTAssertEqual(action(magnification: 0.961, mode: .week, hasPrepared: true), .none)
    XCTAssertEqual(action(magnification: 0.96, mode: .week, hasPrepared: true), .trigger)
  }

  func testLightPinchDoesNotTriggerFromSmallJitterOrRepeatedSamples() {
    XCTAssertEqual(action(magnification: 0.996, mode: .week), .none)
    XCTAssertEqual(action(magnification: 0.97, mode: .week, hasPrepared: true), .none)
    XCTAssertEqual(action(magnification: 0.96, mode: .week, hasTriggered: true), .none)
  }

  func testMonthPinchNeverProducesAnAction() {
    XCTAssertEqual(action(magnification: 1.039, mode: .month), .none)
    XCTAssertEqual(action(magnification: 1.04, mode: .month), .none)
    XCTAssertEqual(action(magnification: 1.07, mode: .month, hasPrepared: true), .none)
    XCTAssertEqual(action(magnification: 1.08, mode: .month, hasPrepared: true), .none)
    XCTAssertEqual(action(magnification: 1.4, mode: .month), .none)
    XCTAssertEqual(action(magnification: 0.6, mode: .month), .none)
  }

  func testOppositeGestureDirectionDoesNotProduceAnAction() {
    XCTAssertEqual(action(magnification: 1.2, mode: .week), .none)
    XCTAssertEqual(action(magnification: 0.8, mode: .month), .none)
  }

  func testMeasuredGeometryIsNormalizedToItsCanvas() {
    let date = makeDate()
    let snapshot = CalendarZoomGeometrySnapshot(
      canvas: CGRect(x: 12, y: 20, width: 712, height: 560),
      frames: [
        .date(date): CGRect(x: 112, y: 70, width: 24, height: 24)
      ]
    )

    XCTAssertEqual(
      snapshot.frame(for: .date(date)),
      CGRect(x: 100, y: 50, width: 24, height: 24)
    )
  }

  func testCanvasSizedEventGeometryIsRejectedBeforeMorphing() {
    let appearance = CalendarZoomEventAppearance.monthTimed(
      rowIndex: 0,
      dayIndex: 0,
      itemIndex: 0,
      spanningLaneCount: 0,
      maximumTimedCount: 1
    )
    let snapshot = CalendarZoomGeometrySnapshot(
      canvas: CGRect(x: 0, y: 0, width: 700, height: 500),
      frames: [
        .event("event", appearance): CGRect(x: 0, y: 0, width: 700, height: 500)
      ]
    )

    XCTAssertNil(snapshot.frame(for: .event("event", appearance)))
  }

  func testEndpointTransferHasExactExclusiveFramesAtBothEnds() {
    XCTAssertEqual(CalendarZoomEndpointTransfer.sourceBandProgress(0), 0, accuracy: 0.001)
    XCTAssertEqual(CalendarZoomEndpointTransfer.targetBandProgress(0), 0, accuracy: 0.001)
    XCTAssertEqual(CalendarZoomEndpointTransfer.sourceBandProgress(1), 1, accuracy: 0.001)
    XCTAssertEqual(CalendarZoomEndpointTransfer.targetBandProgress(1), 1, accuracy: 0.001)
  }

  func testEndpointTransferCompletesEachSixPercentHandoff() {
    let handoff = CalendarZoomEndpointTransfer.handoffFraction
    XCTAssertEqual(
      CalendarZoomEndpointTransfer.sourceBandProgress(handoff),
      1,
      accuracy: 0.001
    )
    XCTAssertEqual(
      CalendarZoomEndpointTransfer.targetBandProgress(1 - handoff),
      0,
      accuracy: 0.001
    )
  }

  func testRenderTokenRejectsAStaleGenerationOrGeometrySnapshot() {
    let calendar = makeCalendar()
    let date = makeDate()
    let viewport = makeViewport(mode: .month, date: date, calendar: calendar)
    let geometry = CalendarZoomGeometrySnapshot(
      canvas: CGRect(x: 0, y: 0, width: 712, height: 560),
      frames: [.date(date): CGRect(x: 12, y: 18, width: 21, height: 21)]
    )
    let expected = CalendarViewportRenderToken(
      viewport: viewport,
      generation: 7,
      canvasSize: CGSize(width: 712, height: 560),
      geometrySummary: geometry
    )

    XCTAssertNotEqual(
      expected,
      CalendarViewportRenderToken(
        viewport: viewport,
        generation: 6,
        canvasSize: CGSize(width: 712, height: 560),
        geometrySummary: geometry
      )
    )
    XCTAssertNotEqual(
      expected,
      CalendarViewportRenderToken(
        viewport: viewport,
        generation: 7,
        canvasSize: CGSize(width: 712, height: 560),
        geometrySummary: nil
      )
    )
  }

  @MainActor
  func testPagingEventLayerMatchesSteadyWeekGeometryAtHandoff() async throws {
    let calendar = makeCalendar()
    let date = makeDate()
    let events = [false, true].map { allDay in
      ScheduleEvent(id: allDay ? "all-day" : "timed", title: "Event",
        startDate: date.addingTimeInterval(9 * 3600),
        endDate: date.addingTimeInterval(10 * 3600), isAllDay: allDay,
        location: nil, notes: nil, url: nil, calendarID: "calendar",
        calendarTitle: "Calendar", colorHex: "#0A84FF")
    }
    let viewport = makeViewport(mode: .week, date: date, calendar: calendar, events: events)
    let captured = LockedGeometryCapture()
    let ready = expectation(description: "steady and paging event frames")
    let root = ZStack {
      CalendarViewportContent(viewport: viewport, calendar: calendar,
        onSelectEvent: { _ in }, onDismissDetail: {}, onSelectDay: { _ in }, zoomEndpoint: .source)
      CalendarViewportContent(viewport: viewport, calendar: calendar,
        onSelectEvent: { _ in }, onDismissDetail: {}, onSelectDay: { _ in },
        eventsOnly: true, zoomEndpoint: .target)
    }
    .frame(width: 760, height: 564)
    .coordinateSpace(name: CalendarZoomCoordinateSpace.name)
    .onPreferenceChange(CalendarZoomGeometryPreferenceKey.self) { frames in
      guard captured.frames.isEmpty else { return }
      let sourceEvents = frames.keys.filter { key in
        if case .event = key.element { return key.endpoint == .source }
        return false
      }
      guard sourceEvents.count >= 2,
            sourceEvents.allSatisfy({ frames[CalendarZoomGeometryKey(endpoint: .target, element: $0.element)] != nil })
      else { return }
      captured.frames = frames
      ready.fulfill()
    }
    let host = NSHostingView(rootView: root)
    host.frame = CGRect(x: 0, y: 0, width: 760, height: 564)
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    await fulfillment(of: [ready], timeout: 2)
    for (key, frame) in captured.frames where key.endpoint == .source {
      guard case .event = key.element else { continue }
      let paging = try XCTUnwrap(captured.frames[CalendarZoomGeometryKey(endpoint: .target, element: key.element)])
      XCTAssertEqual(frame.minX, paging.minX, accuracy: 0.001)
      XCTAssertEqual(frame.minY, paging.minY, accuracy: 0.001)
      XCTAssertEqual(frame.width, paging.width, accuracy: 0.001)
      XCTAssertEqual(frame.height, paging.height, accuracy: 0.001)
    }
  }

  @MainActor
  func testPositionedEventGeometryRecordsCardBoundsInsteadOfTheWholeCanvas() async {
    let element = CalendarZoomElementID.appearance(
      .monthOverflow(rowIndex: 0, dayIndex: 0, slot: 0)
    )
    let key = CalendarZoomGeometryKey(endpoint: .source, element: element)
    let captured = LockedGeometryCapture()
    let expectation = expectation(description: "geometry preference")
    let root = ZStack(alignment: .topLeading) {
      Color.clear
      RoundedRectangle(cornerRadius: 4)
        .frame(width: 84, height: 36)
        .calendarZoomGeometry(element, endpoint: .source)
        .position(x: 160, y: 100)
    }
    .frame(width: 700, height: 500)
    .coordinateSpace(name: CalendarZoomCoordinateSpace.name)
    .onPreferenceChange(CalendarZoomGeometryPreferenceKey.self) { frames in
      guard let frame = frames[key] else { return }
      captured.frame = frame
      expectation.fulfill()
    }
    let host = NSHostingView(rootView: root)
    host.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()

    await fulfillment(of: [expectation], timeout: 1)
    XCTAssertEqual(captured.frame?.width ?? 0, 84, accuracy: 0.5)
    XCTAssertEqual(captured.frame?.height ?? 0, 36, accuracy: 0.5)
  }

  func testSceneUsesFocusedMonthRowAndDirectionalPeripheralTracks() {
    let calendar = makeCalendar()
    let date = makeDate()
    let scene = CalendarZoomScene.make(
      source: makeViewport(mode: .week, date: date, calendar: calendar),
      targetMode: .month,
      focusedDate: date,
      calendar: calendar
    )

    XCTAssertEqual(scene.monthRowCount, 5)
    XCTAssertEqual(scene.focusRowIndex, 0)
    XCTAssertEqual(scene.rowTracks.count, 4)
    XCTAssertTrue(scene.rowTracks.allSatisfy { $0.exitEdge == .bottom })
    XCTAssertNil(scene.rowTrack(at: scene.focusRowIndex))
    XCTAssertEqual(scene.rowTrack(at: 1)?.rowIndex, 1)
  }

  func testInstallingGeometryResolvesEventEndpointsBeforeAnimation() throws {
    let calendar = makeCalendar()
    let date = makeDate()
    let event = ScheduleEvent(
      id: "event",
      title: "Event",
      startDate: date,
      endDate: date.addingTimeInterval(3_600),
      isAllDay: false,
      location: nil,
      notes: nil,
      url: nil,
      calendarID: "calendar",
      calendarTitle: "Calendar",
      colorHex: "#0A84FF"
    )
    let scene = CalendarZoomScene.make(
      source: makeViewport(mode: .week, date: date, calendar: calendar, events: [event]),
      target: makeViewport(mode: .month, date: date, calendar: calendar, events: [event]),
      focusedDate: date,
      calendar: calendar
    )
    let track = try XCTUnwrap(scene.eventTracks.first)
    let canvas = CGRect(x: 0, y: 0, width: 712, height: 560)
    let sourceRect = CGRect(x: 80, y: 90, width: 72, height: 54)
    let targetRect = CGRect(x: 210, y: 150, width: 86, height: 15)
    let installed = scene.installing(
      sourceGeometry: CalendarZoomGeometrySnapshot(
        canvas: canvas,
        frames: [.event(track.id, track.source): sourceRect]
      ),
      targetGeometry: CalendarZoomGeometrySnapshot(
        canvas: canvas,
        frames: [.event(track.id, track.target): targetRect]
      )
    )

    XCTAssertEqual(installed.resolvedEventTracks.first?.sourceRect, sourceRect)
    XCTAssertEqual(installed.resolvedEventTracks.first?.targetRect, targetRect)
  }

  func testPeripheralRowsExitThroughTheirNearestVerticalEdge() {
    let geometry = CalendarZoomGeometry(
      size: CGSize(width: 712, height: 560),
      focusRowIndex: 2,
      monthRowCount: 5
    )
    let top = CalendarZoomRowTrack(rowIndex: 1, distance: 1, exitEdge: .top)
    let bottom = CalendarZoomRowTrack(rowIndex: 3, distance: 1, exitEdge: .bottom)

    XCTAssertLessThan(
      top.verticalOffset(geometry: geometry, transitionProgress: 1, direction: .monthToWeek),
      0
    )
    XCTAssertGreaterThan(
      bottom.verticalOffset(geometry: geometry, transitionProgress: 1, direction: .monthToWeek),
      0
    )
    XCTAssertEqual(
      top.verticalOffset(geometry: geometry, transitionProgress: 1, direction: .weekToMonth),
      0,
      accuracy: 0.001
    )
    XCTAssertEqual(
      bottom.verticalOffset(geometry: geometry, transitionProgress: 1, direction: .weekToMonth),
      0,
      accuracy: 0.001
    )
  }

  func testSceneFreezesExactPreparedTargetViewport() {
    let calendar = makeCalendar()
    let date = makeDate()
    let source = makeViewport(mode: .week, date: date, calendar: calendar)
    let target = makeViewport(mode: .month, date: date, calendar: calendar)
    let scene = CalendarZoomScene.make(
      source: source,
      target: target,
      focusedDate: date,
      calendar: calendar
    )

    XCTAssertEqual(scene.source, source)
    XCTAssertEqual(scene.target, target)
  }

  func testZoomWaitsForPreparedMonthAndIncludesPeripheralWeekEvents() {
    let calendar = makeCalendar()
    let date = makeDate()
    let source = makeViewport(mode: .week, date: date, calendar: calendar)
    let provisional = CalendarZoomScene.make(
      source: source,
      targetMode: .month,
      focusedDate: date,
      calendar: calendar
    )

    XCTAssertNil(CalendarZoomPreparedTargetResolver.resolve(
      scene: provisional,
      preparedViewport: nil,
      calendar: calendar
    ))

    let peripheralDate = calendar.date(byAdding: .day, value: 14, to: date)!
    let peripheralEvent = ScheduleEvent(
      id: "peripheral-event",
      title: "另一周的日程",
      startDate: peripheralDate,
      endDate: calendar.date(byAdding: .hour, value: 1, to: peripheralDate)!,
      isAllDay: false,
      location: nil,
      notes: nil,
      url: nil,
      calendarID: "calendar",
      calendarTitle: "日历",
      colorHex: "#0A84FF"
    )
    let prepared = makeViewport(
      mode: .month,
      date: date,
      calendar: calendar,
      events: [peripheralEvent]
    )
    let resolved = CalendarZoomPreparedTargetResolver.resolve(
      scene: provisional,
      preparedViewport: prepared,
      calendar: calendar
    )

    XCTAssertEqual(resolved?.target, prepared)
    XCTAssertTrue(resolved?.target.monthLayout.weeks.enumerated().contains { index, week in
      index != resolved?.focusRowIndex
        && week.days.contains { day in day.timedEvents.contains { $0.id == peripheralEvent.id } }
    } == true)
  }

  func testMonthViewportAlreadyCoversItsFocusedWeek() {
    let calendar = makeCalendar()
    let date = makeDate()
    let scene = CalendarZoomScene.make(
      source: makeViewport(mode: .month, date: date, calendar: calendar),
      targetMode: .week,
      focusedDate: date,
      calendar: calendar
    )

    XCTAssertTrue(CalendarZoomPreparedTargetResolver.sourceCoversTarget(scene))
  }

  func testWeekViewportDoesNotClaimToCoverItsMonth() {
    let calendar = makeCalendar()
    let date = makeDate()
    let scene = CalendarZoomScene.make(
      source: makeViewport(mode: .week, date: date, calendar: calendar),
      targetMode: .month,
      focusedDate: date,
      calendar: calendar
    )

    XCTAssertFalse(CalendarZoomPreparedTargetResolver.sourceCoversTarget(scene))
  }

  func testGeometryKeepsEventEndpointsInsideCalendarCanvas() {
    let geometry = CalendarZoomGeometry(
      size: CGSize(width: 712, height: 560),
      focusRowIndex: 2,
      monthRowCount: 5
    )
    let dot = geometry.rect(
      for: .monthDot(
        rowIndex: 2,
        dayIndex: 3,
        itemIndex: 0,
        visibleCount: 1,
        hasOverflow: false
      )
    )
    XCTAssertGreaterThanOrEqual(dot.minX, 0)
    XCTAssertLessThanOrEqual(dot.maxX, 712)
    XCTAssertGreaterThanOrEqual(dot.minY, 0)
    XCTAssertLessThanOrEqual(dot.maxY, 560)
  }

  func testRowsRetainDistanceStaggerAndElasticTail() {
    let nearby = CalendarZoomMotionSpec.rowProgress(0.35, distance: 1)
    let distant = CalendarZoomMotionSpec.rowProgress(0.35, distance: 3)

    XCTAssertGreaterThan(nearby, distant)
    XCTAssertGreaterThan(CalendarZoomMotionSpec.rowProgress(0.80, distance: 3), 1)
    XCTAssertEqual(
      CalendarZoomMotionSpec.rowProgress(
        1 - CalendarZoomEndpointTransfer.handoffFraction,
        distance: 3
      ),
      1,
      accuracy: 0.001
    )
  }

  func testFocusMotionUsesAnticipationAccelerationAndExactEndpoints() {
    XCTAssertEqual(CalendarZoomMotionSpec.focusProgress(0), 0, accuracy: 0.001)
    XCTAssertLessThan(CalendarZoomMotionSpec.focusProgress(0.02), 0.01)
    XCTAssertGreaterThan(CalendarZoomMotionSpec.focusProgress(0.50), 0.95)
    XCTAssertGreaterThan(CalendarZoomMotionSpec.focusProgress(0.68), 1)
    XCTAssertEqual(
      CalendarZoomMotionSpec.focusProgress(1 - CalendarZoomEndpointTransfer.handoffFraction),
      1,
      accuracy: 0.001
    )
    XCTAssertEqual(CalendarZoomMotionSpec.focusProgress(1.04), 1, accuracy: 0.001)
  }

  func testEventCardsUseStableCascadeAndElasticTail() {
    let leading = CalendarZoomMotionSpec.eventProgress(0.35, order: 0, count: 8)
    let trailing = CalendarZoomMotionSpec.eventProgress(0.35, order: 7, count: 8)

    XCTAssertGreaterThan(leading, trailing)
    XCTAssertGreaterThan(leading - trailing, 0.20)
    XCTAssertEqual(
      CalendarZoomMotionSpec.eventProgress(
        1 - CalendarZoomEndpointTransfer.handoffFraction,
        order: 7,
        count: 8
      ),
      1,
      accuracy: 0.001
    )
    XCTAssertGreaterThan(CalendarZoomMotionSpec.eventProgress(0.76, order: 7, count: 8), 1)
    XCTAssertEqual(
      CalendarZoomMotionSpec.eventProgress(1.04, order: 7, count: 8),
      1,
      accuracy: 0.001
    )
  }

  func testEventTypographyUsesOneBoundedMidTransitionWipe() {
    XCTAssertEqual(CalendarZoomMotionSpec.eventTextTransferProgress(0), 0, accuracy: 0.001)
    XCTAssertEqual(CalendarZoomMotionSpec.eventTextTransferProgress(0.28), 0, accuracy: 0.001)
    XCTAssertEqual(CalendarZoomMotionSpec.eventTextTransferProgress(0.50), 0.5, accuracy: 0.001)
    XCTAssertEqual(CalendarZoomMotionSpec.eventTextTransferProgress(0.72), 1, accuracy: 0.001)
    XCTAssertEqual(CalendarZoomMotionSpec.eventTextTransferProgress(1.08), 1, accuracy: 0.001)
  }

  func testHeaderDatesCascadeOutwardFromFocusedDate() {
    let focused = CalendarZoomMotionSpec.headerProgress(0.24, distanceFromFocus: 0)
    let outer = CalendarZoomMotionSpec.headerProgress(0.24, distanceFromFocus: 5)

    XCTAssertGreaterThan(focused, outer)
    XCTAssertEqual(CalendarZoomMotionSpec.headerProgress(0, distanceFromFocus: 5), 0)
    XCTAssertEqual(
      CalendarZoomMotionSpec.headerProgress(
        1 - CalendarZoomEndpointTransfer.handoffFraction,
        distanceFromFocus: 5
      ),
      1,
      accuracy: 0.001
    )
  }

  func testTimeLabelsUseDistanceStaggerAndNonlinearVisibility() {
    let nearby = CalendarZoomMotionSpec.timeLabelProgress(0.22, normalizedDistance: 0)
    let distant = CalendarZoomMotionSpec.timeLabelProgress(0.22, normalizedDistance: 1)

    XCTAssertGreaterThan(nearby, distant)
    XCTAssertEqual(CalendarZoomMotionSpec.timeLabelOpacity(monthness: 0), 1, accuracy: 0.001)
    XCTAssertGreaterThan(CalendarZoomMotionSpec.timeLabelOpacity(monthness: 0.35), 0.5)
    XCTAssertEqual(CalendarZoomMotionSpec.timeLabelOpacity(monthness: 0.88), 0, accuracy: 0.001)
  }

  func testToolbarMotionsFinishWellBeforeTheCalendarHandoff() {
    XCTAssertEqual(CalendarZoomMotionSpec.selectorProgress(0), 0, accuracy: 0.001)
    XCTAssertEqual(CalendarZoomMotionSpec.titleProgress(0), 0, accuracy: 0.001)
    XCTAssertNotEqual(CalendarZoomMotionSpec.selectorProgress(0.24), 0.24, accuracy: 0.001)
    XCTAssertNotEqual(CalendarZoomMotionSpec.titleProgress(0.20), 0.20, accuracy: 0.001)
    XCTAssertEqual(
      CalendarZoomMotionSpec.selectorProgress(0.58),
      1,
      accuracy: 0.001
    )
    XCTAssertEqual(
      CalendarZoomMotionSpec.titleProgress(0.50),
      1,
      accuracy: 0.001
    )
    XCTAssertLessThan(
      CalendarZoomMotionSpec.selectorCompletionTime,
      CalendarZoomMotionSpec.transitionDuration * 0.60
    )
    XCTAssertLessThan(
      CalendarZoomMotionSpec.titleCompletionTime,
      CalendarZoomMotionSpec.selectorCompletionTime
    )
  }

  func testModeSelectorPlaybackUsesItsOwnClockWithoutChangingTheExistingCurve() {
    XCTAssertEqual(
      CalendarZoomMotionSpec.selectorPlaybackClockEnd,
      CGFloat(
        CalendarZoomMotionSpec.selectorCompletionTime
          / CalendarZoomMotionSpec.transitionDuration
      ),
      accuracy: 0.001
    )

    for playbackProgress in [CGFloat(0), 0.2, 0.5, 0.8, 1] {
      let actual = CalendarZoomMotionSpec.selectorPlaybackSample(playbackProgress)
      let expected = CalendarZoomMotionSpec.selectorSample(
        playbackProgress * CalendarZoomMotionSpec.selectorPlaybackClockEnd
      )
      XCTAssertEqual(actual.travel, expected.travel, accuracy: 0.001)
      XCTAssertEqual(actual.widthScale, expected.widthScale, accuracy: 0.001)
      XCTAssertEqual(actual.heightScale, expected.heightScale, accuracy: 0.001)
      XCTAssertEqual(
        actual.directionalOffset,
        expected.directionalOffset,
        accuracy: 0.001
      )
    }

    let halfway = CalendarZoomMotionSpec.selectorPlaybackSample(0.5)
    XCTAssertGreaterThan(halfway.travel, 0)
    XCTAssertEqual(CalendarZoomMotionSpec.selectorSample(0).travel, 0, accuracy: 0.001)
    XCTAssertEqual(
      CalendarZoomMotionSpec.selectorPlaybackSample(1),
      .settled(at: 1)
    )
  }

  func testModeSelectorUsesElasticSolidThumbDeformation() {
    let launch = CalendarZoomMotionSpec.selectorSample(0)
    let takeoff = CalendarZoomMotionSpec.selectorSample(0.065)
    let lift = CalendarZoomMotionSpec.selectorSample(0.13)
    let middle = CalendarZoomMotionSpec.selectorSample(0.26)
    let landing = CalendarZoomMotionSpec.selectorSample(0.41)
    let rebound = CalendarZoomMotionSpec.selectorSample(0.50)
    let arrival = CalendarZoomMotionSpec.selectorSample(0.58)

    XCTAssertEqual(launch.travel, 0, accuracy: 0.001)
    XCTAssertGreaterThan(takeoff.widthScale, takeoff.heightScale)
    XCTAssertGreaterThan(takeoff.directionalOffset, 0.035)
    XCTAssertGreaterThan(lift.widthScale, 1.10)
    XCTAssertGreaterThan(lift.heightScale, 1.15)
    XCTAssertGreaterThan(middle.travel, 0)
    XCTAssertGreaterThan(middle.travel, 1)
    XCTAssertGreaterThan(middle.widthScale, 1.25)
    XCTAssertGreaterThan(middle.widthScale, middle.heightScale)
    XCTAssertGreaterThan(landing.heightScale, 1.12)
    XCTAssertGreaterThan(landing.heightScale, landing.widthScale)
    XCTAssertGreaterThan(rebound.widthScale, 1.03)
    XCTAssertLessThan(rebound.heightScale, 0.99)
    XCTAssertEqual(arrival.travel, 1, accuracy: 0.001)
    XCTAssertEqual(arrival.widthScale, 1, accuracy: 0.001)
    XCTAssertEqual(arrival.heightScale, 1, accuracy: 0.001)
    XCTAssertEqual(arrival.directionalOffset, 0, accuracy: 0.001)
  }

  private func action(
    magnification: CGFloat,
    mode: CalendarDisplayMode,
    hasPrepared: Bool = false,
    hasTriggered: Bool = false
  ) -> CalendarZoomGestureAction {
    tracker.action(
      magnification: magnification,
      mode: mode,
      hasPrepared: hasPrepared,
      hasTriggered: hasTriggered
    )
  }

  private func makeCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.firstWeekday = 2
    return calendar
  }

  private func makeDate() -> Date {
    makeCalendar().date(
      from: DateComponents(year: 2026, month: 9, day: 3, hour: 12)
    )!
  }

  private func makeViewport(
    mode: CalendarDisplayMode,
    date: Date,
    calendar: Calendar,
    events: [ScheduleEvent] = []
  ) -> CalendarViewportState {
    let week = WeekLayoutEngine(calendar: calendar).makeLayout(events: events, weekStart: date)
    let month = MonthLayoutEngine(calendar: calendar).makeLayout(events: events, containing: date)
    let interval = mode == .week
      ? DateInterval(start: week.weekStart, end: week.weekEnd)
      : DateInterval(start: month.gridStart, end: month.gridEnd)
    return CalendarViewportState(
      displayMode: mode,
      focusedDate: date,
      periodSchedule: CalendarPeriodSchedule(
        startDate: interval.start,
        endDate: interval.end,
        events: events.filter { $0.startDate < interval.end && $0.endDate > interval.start }
      ),
      weekLayout: week,
      monthLayout: month,
      navigationDirection: .stationary
    )
  }
}

@MainActor
private final class LockedGeometryCapture {
  var frame: CGRect?
  var frames: [CalendarZoomGeometryKey: CGRect] = [:]
}
