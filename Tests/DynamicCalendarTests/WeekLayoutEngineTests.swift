import XCTest

@testable import DynamicCalendar

final class WeekLayoutEngineTests: XCTestCase {
  private var calendar: Calendar!
  private var engine: WeekLayoutEngine!

  override func setUp() {
    super.setUp()
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_GB")
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    self.calendar = calendar
    self.engine = WeekLayoutEngine(calendar: calendar)
  }

  func testOverlappingEventsReceiveDistinctLanes() {
    let monday = date(2026, 8, 31)
    let events = [
      event("A", start: date(2026, 8, 31, 9, 0), end: date(2026, 8, 31, 10, 0)),
      event("B", start: date(2026, 8, 31, 9, 15), end: date(2026, 8, 31, 10, 15)),
      event("C", start: date(2026, 8, 31, 9, 30), end: date(2026, 8, 31, 9, 45)),
    ]

    let layout = engine.makeLayout(events: events, weekStart: monday)
    let items = layout.days[0].timedEvents

    XCTAssertEqual(Set(items.map(\.lane)), Set([0, 1, 2]))
    XCTAssertEqual(Set(items.map(\.laneCount)), Set([3]))
  }

  func testAdjacentEventsDoNotShareAnOverlapCluster() {
    let monday = date(2026, 8, 31)
    let events = [
      event("A", start: date(2026, 8, 31, 9, 0), end: date(2026, 8, 31, 10, 0)),
      event("B", start: date(2026, 8, 31, 10, 0), end: date(2026, 8, 31, 11, 0)),
    ]

    let layout = engine.makeLayout(events: events, weekStart: monday)

    XCTAssertEqual(layout.days[0].timedEvents.map(\.laneCount), [1, 1])
  }

  func testCrossMidnightEventIsSplitAcrossBothDays() throws {
    let monday = date(2026, 8, 31)
    let overnight = event(
      "Overnight",
      start: date(2026, 8, 31, 23, 0),
      end: date(2026, 9, 1, 1, 0)
    )

    let layout = engine.makeLayout(events: [overnight], weekStart: monday)
    let mondaySegment = try XCTUnwrap(layout.days[0].timedEvents.first)
    let tuesdaySegment = try XCTUnwrap(layout.days[1].timedEvents.first)

    XCTAssertEqual(mondaySegment.startMinute, 23 * 60)
    XCTAssertEqual(mondaySegment.endMinute, 24 * 60)
    XCTAssertEqual(tuesdaySegment.startMinute, 0)
    XCTAssertEqual(tuesdaySegment.endMinute, 60)
    XCTAssertEqual(layout.visibleStartMinute, 0)
    XCTAssertEqual(layout.visibleEndMinute, 24 * 60)
  }

  func testMultiDayAllDayEventAppearsOnEveryIntersectingDay() {
    let monday = date(2026, 8, 31)
    let event = ScheduleEvent(
      id: "all-day",
      title: "发布周",
      startDate: monday,
      endDate: date(2026, 9, 2),
      isAllDay: true,
      location: nil,
      notes: nil,
      url: nil,
      calendarID: "work",
      calendarTitle: "工作",
      colorHex: "#3366FF"
    )

    let layout = engine.makeLayout(events: [event], weekStart: monday)

    XCTAssertEqual(layout.days[0].allDayEvents.map(\.id), ["all-day"])
    XCTAssertEqual(layout.days[1].allDayEvents.map(\.id), ["all-day"])
    XCTAssertTrue(layout.days[2].allDayEvents.isEmpty)
  }

  func testTimeRangeExpandsToContainEarlyAndLateEvents() {
    let monday = date(2026, 8, 31)
    let events = [
      event("Early", start: date(2026, 8, 31, 5, 20), end: date(2026, 8, 31, 6, 0)),
      event("Late", start: date(2026, 9, 1, 22, 30), end: date(2026, 9, 1, 23, 15)),
    ]

    let layout = engine.makeLayout(events: events, weekStart: monday)

    XCTAssertEqual(layout.visibleStartMinute, 4 * 60)
    XCTAssertEqual(layout.visibleEndMinute, 24 * 60)
  }

  func testCurrentTimeIndicatorUsesOnlyMatchingDayAndVisibleMinute() throws {
    let layout = engine.makeLayout(events: [], weekStart: date(2026, 8, 31))
    let placement = try XCTUnwrap(
      CurrentTimeIndicatorGeometry.placement(
        at: date(2026, 9, 2, 10, 30),
        layout: layout,
        calendar: calendar
      )
    )

    XCTAssertEqual(placement.dayIndex, 2)
    XCTAssertEqual(placement.verticalFraction, 2.5 / 12, accuracy: 0.0001)
  }

  func testCurrentTimeIndicatorDropsTimesOutsideVisibleRange() {
    let layout = engine.makeLayout(events: [], weekStart: date(2026, 8, 31))

    XCTAssertNil(
      CurrentTimeIndicatorGeometry.placement(
        at: date(2026, 9, 2, 7, 59),
        layout: layout,
        calendar: calendar
      )
    )
    XCTAssertNil(
      CurrentTimeIndicatorGeometry.placement(
        at: date(2026, 9, 2, 20, 0),
        layout: layout,
        calendar: calendar
      )
    )
  }

  func testCurrentTimeIndicatorDropsDatesOutsideDisplayedWeek() {
    let layout = engine.makeLayout(events: [], weekStart: date(2026, 8, 31))

    XCTAssertNil(
      CurrentTimeIndicatorGeometry.placement(
        at: date(2026, 9, 7, 10, 0),
        layout: layout,
        calendar: calendar
      )
    )
  }

  private func event(_ id: String, start: Date, end: Date) -> ScheduleEvent {
    ScheduleEvent(
      id: id,
      title: id,
      startDate: start,
      endDate: end,
      isAllDay: false,
      location: "会议室",
      notes: nil,
      url: nil,
      calendarID: "work",
      calendarTitle: "工作",
      colorHex: "#3366FF"
    )
  }

  private func date(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int = 0,
    _ minute: Int = 0
  ) -> Date {
    calendar.date(
      from: DateComponents(
        timeZone: calendar.timeZone,
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute
      ))!
  }
}

@MainActor
final class AppModelReloadTests: XCTestCase {
  func testStaleEventQueryCannotReplaceLatestWeek() async {
    let provider = SuspendedCalendarProvider()
    let defaultsName = "AppModelReloadTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: defaultsName)!
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let onboardingStore = OnboardingStore(defaults: defaults)
    onboardingStore.markComplete()

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.firstWeekday = 2
    let initialDate = calendar.date(
      from: DateComponents(year: 2026, month: 8, day: 31, hour: 12)
    )!
    let model = AppModel(
      provider: provider,
      selectionStore: CalendarSelectionStore(defaults: defaults),
      onboardingStore: onboardingStore,
      calendar: calendar,
      now: initialDate
    )

    model.start()
    await waitUntil { provider.requests.count == 1 }
    model.movePeriod(by: 1)
    await waitUntil { provider.requests.count == 2 }

    let latestRequest = provider.requests[1]
    latestRequest.continuation.resume(returning: [
      makeEvent(id: "latest", date: latestRequest.interval.start)
    ])
    await waitUntil { model.periodSchedule.events.first?.id == "latest" }

    let staleRequest = provider.requests[0]
    staleRequest.continuation.resume(returning: [
      makeEvent(id: "stale", date: staleRequest.interval.start)
    ])
    await Task.yield()

    XCTAssertEqual(model.periodSchedule.startDate, latestRequest.interval.start)
    XCTAssertEqual(model.periodSchedule.events.map(\.id), ["latest"])
  }

  private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool,
    attempts: Int = 100
  ) async {
    for _ in 0..<attempts {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("Timed out waiting for asynchronous reload")
  }

  private func makeEvent(id: String, date: Date) -> ScheduleEvent {
    ScheduleEvent(
      id: id,
      title: id,
      startDate: date.addingTimeInterval(9 * 60 * 60),
      endDate: date.addingTimeInterval(10 * 60 * 60),
      isAllDay: false,
      location: nil,
      notes: nil,
      url: nil,
      calendarID: "work",
      calendarTitle: "工作",
      colorHex: "#3366FF"
    )
  }
}

@MainActor
private final class SuspendedCalendarProvider: CalendarProviding {
  struct Request {
    let interval: DateInterval
    let continuation: CheckedContinuation<[ScheduleEvent], Never>
  }

  var onCalendarStoreChanged: (() -> Void)?
  private(set) var requests: [Request] = []

  func authorizationStatus() -> CalendarAuthorizationState { .fullAccess }
  func requestFullAccess() async -> CalendarAuthorizationState { .fullAccess }
  func availableCalendars() async -> [CalendarSource] {
    [CalendarSource(id: "work", title: "工作", colorHex: "#3366FF", isEnabled: true)]
  }

  func events(
    in interval: DateInterval,
    calendarIDs: Set<String>
  ) async -> [ScheduleEvent] {
    await withCheckedContinuation { continuation in
      requests.append(Request(interval: interval, continuation: continuation))
    }
  }
}
