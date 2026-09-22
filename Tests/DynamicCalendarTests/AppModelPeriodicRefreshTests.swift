import Combine
import XCTest
@testable import DynamicCalendar

@MainActor
final class AppModelPeriodicRefreshTests: XCTestCase {
  func testSchedulerUsesMinuteIntervalAndIdenticalReloadDoesNotPublishPeriod() async {
    let scheduler = ManualRefreshScheduler()
    let provider = RecordingCalendarProvider()
    let layoutWorker = RecordingLayoutWorker(calendar: testCalendar())
    let now = makeDate()
    provider.eventsResult = [makeEvent(id: "event", title: "日程", date: now)]
    let model = makeModel(
      provider: provider,
      scheduler: scheduler,
      now: now,
      layoutWorker: layoutWorker
    )

    model.start()
    await waitUntil {
      provider.eventRequestCount == 1
        && layoutWorker.callCount == 1
        && model.periodSchedule.events.count == 1
    }
    XCTAssertEqual(scheduler.interval, 60)
    XCTAssertEqual(scheduler.leeway, 2)

    var publicationCount = 0
    let cancellable = model.$viewport.dropFirst().sink { _ in
      publicationCount += 1
    }
    scheduler.fire()
    await waitUntil { provider.eventRequestCount == 2 }
    await Task.yield()

    XCTAssertEqual(publicationCount, 0)
    XCTAssertEqual(layoutWorker.callCount, 1)
    withExtendedLifetime(cancellable) {}
  }

  func testIdenticalPeriodicRequestsShareOneInFlightQuery() async {
    let scheduler = ManualRefreshScheduler()
    let provider = RecordingCalendarProvider()
    let now = makeDate()
    provider.eventsResult = [makeEvent(id: "event", title: "日程", date: now)]
    let model = makeModel(provider: provider, scheduler: scheduler, now: now)

    model.start()
    await waitUntil { model.periodSchedule.events.count == 1 }

    provider.holdNextEventRequest = true
    scheduler.fire()
    await waitUntil { provider.hasHeldEventRequest }
    scheduler.fire()
    scheduler.fire()
    await Task.yield()

    XCTAssertEqual(provider.eventRequestCount, 2)
    provider.resolveHeldEvents(provider.eventsResult)
    await Task.yield()
  }

  func testCalendarChangesDuringQueryCoalesceIntoOneFollowUpReload() async {
    let scheduler = ManualRefreshScheduler()
    let provider = RecordingCalendarProvider()
    let now = makeDate()
    provider.eventsResult = [makeEvent(id: "event", title: "日程", date: now)]
    let model = makeModel(provider: provider, scheduler: scheduler, now: now)

    model.start()
    await waitUntil { model.periodSchedule.events.count == 1 }

    provider.holdNextEventRequest = true
    scheduler.fire()
    await waitUntil { provider.hasHeldEventRequest }
    provider.notifyCalendarStoreChanged()
    provider.notifyCalendarStoreChanged()
    await Task.yield()
    XCTAssertEqual(provider.eventRequestCount, 2)

    provider.resolveHeldEvents(provider.eventsResult)
    await waitUntil { provider.eventRequestCount == 3 }
    XCTAssertEqual(provider.eventRequestCount, 3)
  }

  func testPeriodicRefreshSkipsWithoutAuthorization() async {
    let scheduler = ManualRefreshScheduler()
    let provider = RecordingCalendarProvider()
    provider.authorization = .denied
    let model = makeModel(provider: provider, scheduler: scheduler, now: makeDate())

    model.start()
    await Task.yield()
    scheduler.fire()
    await Task.yield()

    XCTAssertEqual(provider.eventRequestCount, 0)
  }

  func testWakeRefreshesOnlyWhenLastSuccessIsAtLeastOneMinuteOld() async {
    let scheduler = ManualRefreshScheduler()
    let provider = RecordingCalendarProvider()
    var now = makeDate()
    provider.eventsResult = [makeEvent(id: "event", title: "日程", date: now)]
    let model = makeModel(
      provider: provider,
      scheduler: scheduler,
      now: now,
      nowProvider: { now }
    )

    model.start()
    await waitUntil { provider.eventRequestCount == 1 }

    now = now.addingTimeInterval(59)
    model.refreshEventsAfterWakeIfNeeded(at: now)
    await Task.yield()
    XCTAssertEqual(provider.eventRequestCount, 1)

    now = now.addingTimeInterval(1)
    model.refreshEventsAfterWakeIfNeeded(at: now)
    await waitUntil { provider.eventRequestCount == 2 }
  }

  func testRefreshReconcilesOrDismissesSelectedOccurrence() async {
    let scheduler = ManualRefreshScheduler()
    let provider = RecordingCalendarProvider()
    let now = makeDate()
    let original = makeEvent(id: "selected", title: "旧标题", date: now)
    provider.eventsResult = [original]
    let model = makeModel(provider: provider, scheduler: scheduler, now: now)

    model.start()
    await waitUntil { model.periodSchedule.events.count == 1 }
    model.selectedEvent = original

    provider.eventsResult = [makeEvent(id: "selected", title: "新标题", date: now)]
    scheduler.fire()
    await waitUntil { provider.eventRequestCount == 2 && model.selectedEvent?.title == "新标题" }

    provider.eventsResult = []
    scheduler.fire()
    await waitUntil { provider.eventRequestCount == 3 && model.selectedEvent == nil }
  }

  func testExistingFullAccessDoesNotRequestAgain() async {
    let scheduler = ManualRefreshScheduler()
    let provider = RecordingCalendarProvider()
    let model = makeModel(provider: provider, scheduler: scheduler, now: makeDate())

    await model.requestCalendarAccess()

    XCTAssertEqual(provider.accessRequestCount, 0)
  }

  func testStartsInWeekModeAndQueriesSevenDayInterval() async {
    let scheduler = ManualRefreshScheduler()
    let provider = RecordingCalendarProvider()
    let model = makeModel(provider: provider, scheduler: scheduler, now: makeDate())

    model.start()
    await waitUntil { provider.eventRequestCount == 1 }

    XCTAssertEqual(model.displayMode, .week)
    XCTAssertEqual(provider.eventIntervals.last.map(dayCount), 7)
  }

  func testMonthModeQueriesCompleteSixWeekGridAndMovesForwardOneMonth() async {
    let scheduler = ManualRefreshScheduler()
    let provider = RecordingCalendarProvider()
    let model = makeModel(provider: provider, scheduler: scheduler, now: makeDate())

    model.start()
    await waitUntil { provider.eventRequestCount == 1 }

    model.setDisplayMode(.month)
    await waitUntil { provider.eventRequestCount == 2 }

    XCTAssertEqual(model.displayMode, .month)
    XCTAssertEqual(provider.eventIntervals.last.map(dayCount), 42)
    XCTAssertEqual(model.monthLayout.monthStart, date(2026, 8, 1))

    model.movePeriod(by: 1)
    await waitUntil { provider.eventRequestCount == 3 }

    XCTAssertEqual(model.navigationDirection, .forward)
    XCTAssertEqual(model.monthLayout.monthStart, date(2026, 9, 1))
    XCTAssertEqual(provider.eventIntervals.last.map(dayCount), 35)
  }

  func testSelectingMonthDateEntersContainingWeek() async {
    let scheduler = ManualRefreshScheduler()
    let provider = RecordingCalendarProvider()
    let model = makeModel(provider: provider, scheduler: scheduler, now: makeDate())

    model.start()
    await waitUntil { provider.eventRequestCount == 1 }
    model.setDisplayMode(.month)
    await waitUntil { provider.eventRequestCount == 2 }

    model.showWeek(containing: date(2026, 9, 17))
    await waitUntil { provider.eventRequestCount == 3 }

    XCTAssertEqual(model.displayMode, .week)
    XCTAssertEqual(model.navigationDirection, .stationary)
    XCTAssertEqual(model.periodSchedule.startDate, date(2026, 9, 14))
    XCTAssertEqual(provider.eventIntervals.last.map(dayCount), 7)
  }

  func testModeSwitchPublishesOneAtomicViewportBeforePreparedEventsArrive() async {
    let scheduler = ManualRefreshScheduler()
    let provider = RecordingCalendarProvider()
    let model = makeModel(provider: provider, scheduler: scheduler, now: makeDate())
    var published: [CalendarViewportState] = []
    let cancellable = model.$viewport.dropFirst().sink { published.append($0) }

    model.setDisplayMode(.month)

    XCTAssertEqual(published.count, 1)
    XCTAssertEqual(published.first?.displayMode, .month)
    XCTAssertEqual(published.first?.periodSchedule.startDate, published.first?.monthLayout.gridStart)
    withExtendedLifetime(cancellable) {}
  }

  func testPreparedViewportDoesNotPublishActiveViewportUntilCommit() async {
    let scheduler = ManualRefreshScheduler()
    let provider = RecordingCalendarProvider()
    let model = makeModel(provider: provider, scheduler: scheduler, now: makeDate())
    var published: [CalendarViewportState] = []
    let cancellable = model.$viewport.dropFirst().sink { published.append($0) }

    model.prepareDisplayMode(.month)
    await waitUntil { model.preparedViewport != nil }

    XCTAssertTrue(published.isEmpty)
    XCTAssertEqual(model.displayMode, .week)
    XCTAssertEqual(model.preparedViewport?.displayMode, .month)

    model.setDisplayMode(.month)
    XCTAssertEqual(published.count, 1)
    XCTAssertEqual(published.first?.displayMode, .month)
    withExtendedLifetime(cancellable) {}
  }

  func testPeriodNavigationFreezesViewportUntilPreparedCommit() async {
    let scheduler = ManualRefreshScheduler()
    let provider = RecordingCalendarProvider()
    let model = makeModel(provider: provider, scheduler: scheduler, now: makeDate())
    let originalStart = model.periodSchedule.startDate
    var published: [CalendarViewportState] = []
    let cancellable = model.$viewport.dropFirst().sink { published.append($0) }

    model.requestPeriodMove(by: 1)
    guard let request = model.periodNavigationRequest else {
      return XCTFail("Expected a period navigation request")
    }
    await waitUntil { model.preparedViewport != nil }

    XCTAssertTrue(published.isEmpty)
    XCTAssertEqual(model.periodSchedule.startDate, originalStart)
    XCTAssertTrue(request.matches(model.preparedViewport!))

    model.commitPeriodNavigation(generation: request.id)
    XCTAssertEqual(published.count, 1)
    XCTAssertEqual(model.navigationDirection, .forward)
    XCTAssertEqual(model.periodSchedule.startDate, request.interval.start)
    XCTAssertNil(model.periodNavigationRequest)
    withExtendedLifetime(cancellable) {}
  }

  func testGoToTodayUsesPeriodNavigationAndChronologicalDirection() async {
    let scheduler = ManualRefreshScheduler()
    let provider = RecordingCalendarProvider()
    let viewedDate = date(2026, 9, 21)
    let today = date(2026, 9, 7)
    let model = makeModel(
      provider: provider,
      scheduler: scheduler,
      now: viewedDate,
      nowProvider: { today }
    )
    let originalStart = model.periodSchedule.startDate

    model.goToToday()
    guard let request = model.periodNavigationRequest else {
      return XCTFail("Expected today to create a period navigation request")
    }

    XCTAssertEqual(request.direction, .backward)
    XCTAssertEqual(model.periodSchedule.startDate, originalStart)
    await waitUntil { model.preparedViewport != nil }
    XCTAssertTrue(request.matches(model.preparedViewport!))

    model.commitPeriodNavigation(generation: request.id)
    XCTAssertEqual(model.navigationDirection, .backward)
    XCTAssertEqual(model.periodSchedule.startDate, request.interval.start)
  }

  func testGoToTodayDoesNothingInsideCurrentPeriod() {
    let scheduler = ManualRefreshScheduler()
    let provider = RecordingCalendarProvider()
    let viewedDate = date(2026, 9, 7)
    let today = date(2026, 9, 9)
    let model = makeModel(
      provider: provider,
      scheduler: scheduler,
      now: viewedDate,
      nowProvider: { today }
    )

    model.goToToday()

    XCTAssertNil(model.periodNavigationRequest)
  }

  func testZoomHandoffCommitsAnAlreadyPreparedViewportOnlyOnce() async {
    let scheduler = ManualRefreshScheduler()
    let provider = RecordingCalendarProvider()
    let now = makeDate()
    provider.eventsResult = [makeEvent(id: "prepared", title: "已预取", date: now)]
    let model = makeModel(provider: provider, scheduler: scheduler, now: now)
    model.start()
    await waitUntil { provider.eventRequestCount == 1 }

    model.prepareDisplayMode(.month)
    await waitUntil { model.preparedViewport != nil }
    guard let target = model.preparedViewport else {
      return XCTFail("Expected a prepared month viewport")
    }
    var published: [CalendarViewportState] = []
    let cancellable = model.$viewport.dropFirst().sink { published.append($0) }

    model.commitZoomViewport(target)
    model.completeZoomHandoff()

    XCTAssertEqual(published.count, 1)
    XCTAssertEqual(model.viewport, target)
    XCTAssertNil(model.preparedViewport)
    withExtendedLifetime(cancellable) {}
  }

  func testLatePreparedEventsStayDeferredUntilZoomHandoffCompletes() async {
    let scheduler = ManualRefreshScheduler()
    let provider = RecordingCalendarProvider()
    let now = makeDate()
    let model = makeModel(provider: provider, scheduler: scheduler, now: now)
    model.start()
    await waitUntil { provider.eventRequestCount == 1 }

    provider.holdNextEventRequest = true
    model.prepareDisplayMode(.month)
    await waitUntil { provider.hasHeldEventRequest }

    let frozenTarget = CalendarZoomScene.make(
      source: model.viewport,
      targetMode: .month,
      focusedDate: model.currentFocusedDate,
      calendar: model.calendar
    ).target
    var published: [CalendarViewportState] = []
    let cancellable = model.$viewport.dropFirst().sink { published.append($0) }

    model.commitZoomViewport(frozenTarget)
    provider.resolveHeldEvents([
      makeEvent(id: "late", title: "迟到数据", date: now)
    ])
    await waitUntil { model.preparedViewport?.periodSchedule.events.count == 1 }

    XCTAssertEqual(published.count, 1)
    XCTAssertTrue(model.viewport.periodSchedule.events.isEmpty)

    model.completeZoomHandoff()

    XCTAssertEqual(published.count, 2)
    XCTAssertEqual(model.viewport.periodSchedule.events.map(\.id), ["late"])
    withExtendedLifetime(cancellable) {}
  }

  private func makeModel(
    provider: RecordingCalendarProvider,
    scheduler: ManualRefreshScheduler,
    now: Date,
    layoutWorker: CalendarLayoutWorking? = nil,
    nowProvider: @escaping () -> Date = Date.init
  ) -> AppModel {
    let defaults = UserDefaults(suiteName: "AppModelPeriodicRefreshTests.\(UUID().uuidString)")!
    let onboarding = OnboardingStore(defaults: defaults)
    onboarding.markComplete()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.firstWeekday = 2
    return AppModel(
      provider: provider,
      selectionStore: CalendarSelectionStore(defaults: defaults),
      onboardingStore: onboarding,
      calendar: calendar,
      now: now,
      refreshScheduler: scheduler,
      layoutWorker: layoutWorker,
      nowProvider: nowProvider
    )
  }

  private func testCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.firstWeekday = 2
    return calendar
  }

  private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool,
    attempts: Int = 400
  ) async {
    for _ in 0..<attempts {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out waiting for asynchronous refresh")
  }

  private func makeDate() -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 12))!
  }

  private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
  }

  private func dayCount(_ interval: DateInterval) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.dateComponents([.day], from: interval.start, to: interval.end).day ?? 0
  }

  private func makeEvent(id: String, title: String, date: Date) -> ScheduleEvent {
    ScheduleEvent(
      id: id,
      title: title,
      startDate: date.addingTimeInterval(60 * 60),
      endDate: date.addingTimeInterval(2 * 60 * 60),
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

private final class ManualRefreshScheduler: PeriodicRefreshScheduling {
  private(set) var interval: TimeInterval?
  private(set) var leeway: TimeInterval?
  private var action: (@MainActor () -> Void)?

  func start(
    interval: TimeInterval,
    leeway: TimeInterval,
    action: @escaping @MainActor () -> Void
  ) {
    self.interval = interval
    self.leeway = leeway
    self.action = action
  }

  func cancel() {
    action = nil
  }

  @MainActor
  func fire() {
    action?()
  }
}

@MainActor
private final class RecordingCalendarProvider: CalendarProviding {
  var onCalendarStoreChanged: (() -> Void)?
  var authorization: CalendarAuthorizationState = .fullAccess
  var eventsResult: [ScheduleEvent] = []
  private(set) var accessRequestCount = 0
  private(set) var eventRequestCount = 0
  private(set) var eventIntervals: [DateInterval] = []
  var holdNextEventRequest = false
  private var heldEventContinuation: CheckedContinuation<[ScheduleEvent], Never>?

  var hasHeldEventRequest: Bool {
    heldEventContinuation != nil
  }

  func authorizationStatus() -> CalendarAuthorizationState {
    authorization
  }

  func requestFullAccess() async -> CalendarAuthorizationState {
    accessRequestCount += 1
    return authorization
  }

  func availableCalendars() async -> [CalendarSource] {
    [CalendarSource(id: "work", title: "工作", colorHex: "#3366FF", isEnabled: true)]
  }

  func events(in interval: DateInterval, calendarIDs: Set<String>) async -> [ScheduleEvent] {
    eventRequestCount += 1
    eventIntervals.append(interval)
    if holdNextEventRequest {
      holdNextEventRequest = false
      return await withCheckedContinuation { continuation in
        heldEventContinuation = continuation
      }
    }
    return eventsResult
  }

  func resolveHeldEvents(_ events: [ScheduleEvent]) {
    let continuation = heldEventContinuation
    heldEventContinuation = nil
    continuation?.resume(returning: events)
  }

  func notifyCalendarStoreChanged() {
    onCalendarStoreChanged?()
  }
}

private final class RecordingLayoutWorker: CalendarLayoutWorking {
  private let lock = NSLock()
  private let worker: CalendarLayoutWorker
  private var _callCount = 0

  init(calendar: Calendar) {
    worker = CalendarLayoutWorker(calendar: calendar)
  }

  var callCount: Int {
    lock.withLock { _callCount }
  }

  func makeViewport(
    events: [ScheduleEvent],
    interval: DateInterval,
    mode: CalendarDisplayMode,
    focusedDate: Date,
    navigationDirection: CalendarNavigationDirection,
    currentWeekLayout: WeekLayout,
    currentMonthLayout: MonthLayout
  ) async -> CalendarViewportState {
    lock.withLock { _callCount += 1 }
    return await worker.makeViewport(
      events: events,
      interval: interval,
      mode: mode,
      focusedDate: focusedDate,
      navigationDirection: navigationDirection,
      currentWeekLayout: currentWeekLayout,
      currentMonthLayout: currentMonthLayout
    )
  }
}
