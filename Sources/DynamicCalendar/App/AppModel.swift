import AppKit
import Combine
import Foundation

enum PanelRoute: Equatable {
  case welcome
  case calendar
  case settings
}

private struct PreparedPeriodTarget {
  let mode: CalendarDisplayMode
  let focusedDate: Date
  let interval: DateInterval

  func matches(
    mode: CalendarDisplayMode,
    focusedDate: Date,
    interval: DateInterval
  ) -> Bool {
    self.mode == mode && self.focusedDate == focusedDate && self.interval == interval
  }
}

private struct PreparedPeriod {
  let target: PreparedPeriodTarget
  let events: [ScheduleEvent]

  func matches(
    mode: CalendarDisplayMode,
    focusedDate: Date,
    interval: DateInterval
  ) -> Bool {
    target.matches(mode: mode, focusedDate: focusedDate, interval: interval)
  }
}

struct EventReloadKey: Equatable {
  let interval: DateInterval
  let mode: CalendarDisplayMode
  let focusedDate: Date
  let calendarIDs: Set<String>
}

struct CalendarReloadCoordinator {
  enum EventDecision: Equatable {
    case coalesced
    case start
  }

  private(set) var activeEventKey: EventReloadKey?
  private(set) var isCalendarStoreReloadInFlight = false
  private var hasPendingCalendarStoreReload = false

  mutating func requestCalendarStoreReload() -> Bool {
    guard !isCalendarStoreReloadInFlight, activeEventKey == nil else {
      hasPendingCalendarStoreReload = true
      return false
    }
    isCalendarStoreReloadInFlight = true
    return true
  }

  mutating func beginEventReload(for key: EventReloadKey) -> EventDecision {
    guard activeEventKey != key else { return .coalesced }
    if isCalendarStoreReloadInFlight {
      hasPendingCalendarStoreReload = true
      isCalendarStoreReloadInFlight = false
    }
    activeEventKey = key
    return .start
  }

  mutating func finishEventReload(for key: EventReloadKey) -> Bool {
    guard activeEventKey == key else { return false }
    activeEventKey = nil
    return consumePendingCalendarStoreReload()
  }

  mutating func finishCalendarStoreReload() -> Bool {
    guard isCalendarStoreReloadInFlight else { return false }
    isCalendarStoreReloadInFlight = false
    return consumePendingCalendarStoreReload()
  }

  mutating func cancelActiveReload() {
    activeEventKey = nil
    isCalendarStoreReloadInFlight = false
  }

  private mutating func consumePendingCalendarStoreReload() -> Bool {
    guard hasPendingCalendarStoreReload else { return false }
    hasPendingCalendarStoreReload = false
    return true
  }
}

@MainActor
final class AppModel: ObservableObject {
  static let periodicRefreshInterval: TimeInterval = 60
  static let periodicRefreshLeeway: TimeInterval = 2

  @Published private(set) var authorization: CalendarAuthorizationState
  @Published private(set) var calendars: [CalendarSource] = []
  @Published private(set) var viewport: CalendarViewportState
  @Published private(set) var preparedViewport: CalendarViewportState?
  @Published private(set) var periodNavigationRequest: CalendarPeriodNavigationRequest?
  @Published var route: PanelRoute
  @Published var selectedEvent: ScheduleEvent?
  @Published var isPinned = false
  var onEventCreationRequested: (() -> Void)?

  let calendar: Calendar

  private let provider: CalendarProviding
  private let selectionStore: CalendarSelectionStore
  private let onboardingStore: OnboardingStore
  private let weekLayoutEngine: WeekLayoutEngine
  private let monthLayoutEngine: MonthLayoutEngine
  private let layoutWorker: CalendarLayoutWorking
  private let refreshScheduler: PeriodicRefreshScheduling
  lazy var interaction = CalendarInteractionCoordinator(model: self)
  lazy var eventCreation = EventCreationModel(provider: provider, onSaved: { [weak self] _ in
    self?.scheduleCalendarStoreReload()
  }, onAccessChanged: { [weak self] in
    self?.scheduleCalendarStoreReload()
  })
  private var isInteractiveNavigationActive = false
  var navigationToday: Date { nowProvider() }

  private let nowProvider: () -> Date
  private var filterPreferences: CalendarFilterPreferences?
  private var reloadTask: Task<Void, Never>?
  private var reloadGeneration = 0
  private var reloadCoordinator = CalendarReloadCoordinator()
  private var preparationTask: Task<Void, Never>?
  private var preparationGeneration = 0
  private var periodNavigationGeneration = 0
  private var preparationTarget: PreparedPeriodTarget?
  private var preparedPeriod: PreparedPeriod?
  private var focusedDate: Date
  private var requestedInterval: DateInterval
  private var requestedNavigationDirection: CalendarNavigationDirection = .stationary
  private var isZoomHandoffActive = false
  private var deferredZoomViewport: CalendarViewportState?
  private var renderRevisionCounter: UInt64 = 1
  private var lastSuccessfulEventReloadAt: Date?
  private var wakeObserver: NSObjectProtocol?
  private var hasStarted = false

  init(
    provider: CalendarProviding,
    selectionStore: CalendarSelectionStore = CalendarSelectionStore(),
    onboardingStore: OnboardingStore = OnboardingStore(),
    calendar: Calendar = .autoupdatingCurrent,
    now: Date = Date(),
    refreshScheduler: PeriodicRefreshScheduling = DispatchSourcePeriodicRefreshScheduler(),
    layoutWorker: CalendarLayoutWorking? = nil,
    nowProvider: @escaping () -> Date = Date.init
  ) {
    self.provider = provider
    self.selectionStore = selectionStore
    self.onboardingStore = onboardingStore
    self.calendar = calendar
    let weekLayoutEngine = WeekLayoutEngine(calendar: calendar)
    let monthLayoutEngine = MonthLayoutEngine(calendar: calendar)
    self.weekLayoutEngine = weekLayoutEngine
    self.monthLayoutEngine = monthLayoutEngine
    self.layoutWorker = layoutWorker ?? CalendarLayoutWorker(calendar: calendar)
    self.refreshScheduler = refreshScheduler
    self.nowProvider = nowProvider
    self.authorization = provider.authorizationStatus()

    let initialLayout = weekLayoutEngine.makeLayout(
      events: [],
      weekStart: now
    )
    let initialMonthLayout = monthLayoutEngine.makeLayout(events: [], containing: now)
    let initialSchedule = CalendarPeriodSchedule(
      startDate: initialLayout.weekStart,
      endDate: initialLayout.weekEnd,
      events: []
    )
    self.viewport = CalendarViewportState(
      displayMode: .week,
      focusedDate: now,
      periodSchedule: initialSchedule,
      weekLayout: initialLayout,
      monthLayout: initialMonthLayout,
      navigationDirection: .stationary,
      renderRevision: 1
    )
    self.preparedViewport = nil
    self.periodNavigationRequest = nil
    self.focusedDate = now
    self.requestedInterval = DateInterval(
      start: initialLayout.weekStart,
      end: initialLayout.weekEnd
    )
    self.route = onboardingStore.shouldPresentWelcome ? .welcome : .calendar
  }

  deinit {
    reloadTask?.cancel()
    preparationTask?.cancel()
    refreshScheduler.cancel()
    if let wakeObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
    }
  }

  var enabledCalendarIDs: Set<String> {
    Set(calendars.filter(\.isEnabled).map(\.id))
  }

  var periodSchedule: CalendarPeriodSchedule { viewport.periodSchedule }
  var weekLayout: WeekLayout { viewport.weekLayout }
  var monthLayout: MonthLayout { viewport.monthLayout }
  var displayMode: CalendarDisplayMode { viewport.displayMode }
  var navigationDirection: CalendarNavigationDirection { viewport.navigationDirection }

  var currentFocusedDate: Date {
    focusedDate
  }

  func start() {
    guard !hasStarted else { return }
    hasStarted = true
    provider.onCalendarStoreChanged = { [weak self] in
      self?.scheduleCalendarStoreReload()
    }
    refreshScheduler.start(
      interval: Self.periodicRefreshInterval,
      leeway: Self.periodicRefreshLeeway
    ) { [weak self] in
      self?.schedulePeriodicEventRefresh()
    }
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.refreshEventsAfterWakeIfNeeded()
      }
    }
    scheduleCalendarStoreReload()
  }

  func beginEventCreation() {
    guard route == .calendar, eventCreation.reserve() else { return }
    onEventCreationRequested?()
    Task { @MainActor [weak self] in
      guard let self else { return }
      if self.interaction.isActive {
        for await active in self.interaction.$isActive.values {
          if !active { break }
        }
      }
      if self.selectedEvent != nil {
        self.selectedEvent = nil
        try? await Task.sleep(for: .seconds(self.eventCreation.reduceMotion ? 0.1 : 0.3))
      }
      await self.eventCreation.prepare(focusedDate: self.currentFocusedDate, now: self.navigationToday,
                                       calendar: self.calendar, sources: self.calendars)
    }
  }

  func requestCalendarAccess() async {
    guard authorization != .requesting, !authorization.canReadEvents else { return }
    authorization = .requesting
    authorization = await provider.requestFullAccess()
    onboardingStore.markComplete()
    route = authorization.canReadEvents ? .calendar : .welcome
    scheduleCalendarStoreReload()
  }

  func finishWelcomeWithoutRequesting() {
    onboardingStore.markComplete()
    route = .calendar
  }

  func movePeriod(by value: Int) {
    let component: Calendar.Component = displayMode == .week ? .weekOfYear : .month
    guard
      let date = calendar.date(
        byAdding: component,
        value: value,
        to: focusedDate
      )
    else {
      return
    }
    setPeriod(containing: date)
  }

  func requestPeriodMove(by value: Int) {
    guard value != 0, periodNavigationRequest == nil else { return }
    let component: Calendar.Component = displayMode == .week ? .weekOfYear : .month
    guard let targetDate = calendar.date(
      byAdding: component,
      value: value,
      to: focusedDate
    ) else { return }
    requestPeriodNavigation(to: targetDate)
  }

  private func requestPeriodNavigation(to targetDate: Date) {
    guard periodNavigationRequest == nil else { return }
    let interval = periodInterval(containing: targetDate, mode: displayMode)
    guard interval != requestedInterval else { return }

    periodNavigationGeneration &+= 1
    let request = CalendarPeriodNavigationRequest(
      id: periodNavigationGeneration,
      mode: displayMode,
      targetDate: targetDate,
      interval: interval,
      direction: CalendarNavigationDirection(
        from: requestedInterval.start,
        to: interval.start
      )
    )
    selectedEvent = nil
    periodNavigationRequest = request
    prepareDisplayMode(displayMode, focusedDate: targetDate)
  }

  func commitPeriodNavigation(generation: Int) {
    guard let request = periodNavigationRequest,
          request.id == generation else { return }
    periodNavigationRequest = nil
    setPeriod(containing: request.targetDate)
  }

  func cancelPeriodNavigation(generation: Int) {
    guard periodNavigationRequest?.id == generation else { return }
    periodNavigationRequest = nil
    invalidatePreparedPeriod()
  }

  func goToToday() {
    requestPeriodNavigation(to: nowProvider())
  }

  func setDisplayMode(_ mode: CalendarDisplayMode) {
    guard displayMode != mode else { return }
    switchDisplayMode(to: mode, focusedDate: focusedDate)
  }

  func showWeek(containing date: Date) {
    switchDisplayMode(to: .week, focusedDate: date)
  }

  func beginInteractiveNavigation() {
    isInteractiveNavigationActive = true
  }

  func discardPreparedNavigation() {
    invalidatePreparedPeriod()
  }

  func commitInteractiveViewport(_ target: CalendarViewportState) {
    let selection = selectedEvent
    isInteractiveNavigationActive = false
    commitZoomViewport(target)
    completeZoomHandoff()
    selectedEvent = selection
  }

  func cancelInteractiveNavigation() {
    guard isInteractiveNavigationActive else { return }
    isInteractiveNavigationActive = false
    invalidatePreparedPeriod()
    if let deferred = deferredZoomViewport,
       deferred.displayMode == displayMode,
       deferred.periodSchedule.startDate == viewport.periodSchedule.startDate {
      deferredZoomViewport = nil
      applyResolvedViewport(deferred)
    } else {
      deferredZoomViewport = nil
    }
  }

  func commitZoomViewport(_ target: CalendarViewportState) {
    let interval = DateInterval(
      start: target.periodSchedule.startDate,
      end: target.periodSchedule.endDate
    )
    reloadGeneration &+= 1
    reloadTask?.cancel()
    reloadTask = nil
    reloadCoordinator.cancelActiveReload()
    requestedNavigationDirection = .stationary
    periodNavigationRequest = nil
    selectedEvent = nil
    focusedDate = target.focusedDate
    requestedInterval = interval
    isZoomHandoffActive = true
    deferredZoomViewport = nil
    if viewport != target {
      viewport = target
    }
  }

  func completeZoomHandoff() {
    guard isZoomHandoffActive else { return }
    isZoomHandoffActive = false

    let mode = displayMode
    let targetDate = focusedDate
    let interval = requestedInterval
    let matchingPrepared = preparedPeriod?.matches(
      mode: mode,
      focusedDate: targetDate,
      interval: interval
    ) == true

    if let deferredZoomViewport {
      self.deferredZoomViewport = nil
      if viewport != deferredZoomViewport {
        viewport = deferredZoomViewport
      }
      if matchingPrepared {
        clearPreparedPeriodState()
      }
      return
    }

    if let preparedPeriod, matchingPrepared {
      let events = preparedPeriod.events
      clearPreparedPeriodState()
      applyPeriod(
        events: events,
        interval: interval,
        mode: mode,
        focusedDate: targetDate
      )
      return
    }

    if preparationTarget?.matches(
      mode: mode,
      focusedDate: targetDate,
      interval: interval
    ) == true {
      return
    }

    guard authorization.canReadEvents, !enabledCalendarIDs.isEmpty else { return }
    scheduleEventReload(interval: interval, mode: mode, focusedDate: targetDate)
  }

  func prepareDisplayMode(_ mode: CalendarDisplayMode, focusedDate date: Date? = nil) {
    let targetDate = date ?? focusedDate
    let interval = periodInterval(containing: targetDate, mode: mode)
    guard mode != displayMode || interval != requestedInterval else { return }

    if preparedPeriod?.matches(mode: mode, focusedDate: targetDate, interval: interval) == true
      || preparationTarget?.matches(mode: mode, focusedDate: targetDate, interval: interval) == true
    {
      return
    }

    preparationGeneration &+= 1
    let generation = preparationGeneration
    preparationTask?.cancel()
    preparedPeriod = nil
    preparedViewport = nil
    let target = PreparedPeriodTarget(mode: mode, focusedDate: targetDate, interval: interval)
    preparationTarget = target

    guard authorization.canReadEvents else {
      preparedPeriod = PreparedPeriod(target: target, events: [])
      preparedViewport = makeViewport(
        events: [],
        interval: interval,
        mode: mode,
        focusedDate: targetDate,
        navigationDirection: .stationary
      )
      preparationTarget = nil
      return
    }

    let calendarIDs = enabledCalendarIDs
    preparationTask = Task { [weak self] in
      guard let self else { return }
      let events = calendarIDs.isEmpty
        ? []
        : await provider.events(in: interval, calendarIDs: calendarIDs)
      guard !Task.isCancelled, generation == preparationGeneration else { return }
      let unstampedViewport = await layoutWorker.makeViewport(
        events: events,
        interval: interval,
        mode: mode,
        focusedDate: targetDate,
        navigationDirection: .stationary,
        currentWeekLayout: weekLayout,
        currentMonthLayout: monthLayout
      )
      guard !Task.isCancelled, generation == preparationGeneration else { return }
      let preparedViewport = stampViewport(unstampedViewport)
      preparedPeriod = PreparedPeriod(target: target, events: events)
      self.preparedViewport = preparedViewport
      preparationTarget = nil

      if displayMode == mode, requestedInterval == interval {
        applyResolvedViewport(preparedViewport)
      }
    }
  }

  func setCalendarEnabled(_ id: String, isEnabled: Bool) {
    guard let index = calendars.firstIndex(where: { $0.id == id }) else { return }
    calendars[index].isEnabled = isEnabled

    let knownIDs = Set(calendars.map(\.id))
    let preferences = CalendarFilterPreferences(
      selectedCalendarIDs: enabledCalendarIDs,
      knownCalendarIDs: knownIDs
    )
    filterPreferences = preferences
    selectionStore.save(preferences)
    invalidatePreparedPeriod()
    reloadEvents()
  }

  func openCalendarPrivacySettings() {
    let candidates = [
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars",
      "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars",
    ]
    for candidate in candidates {
      if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
        return
      }
    }
  }

  private func setPeriod(
    containing date: Date,
    preserveStationaryDirection: Bool = false
  ) {
    let interval = periodInterval(containing: date, mode: displayMode)
    let preparedEvents = preparedPeriod.flatMap { prepared -> [ScheduleEvent]? in
      prepared.matches(mode: displayMode, focusedDate: date, interval: interval)
        ? prepared.events
        : nil
    }
    let exactPreparedViewport = preparedViewport.flatMap { prepared -> CalendarViewportState? in
      prepared.displayMode == displayMode
        && prepared.focusedDate == date
        && prepared.periodSchedule.startDate == interval.start
        && prepared.periodSchedule.endDate == interval.end
        ? prepared
        : nil
    }
    requestedNavigationDirection = preserveStationaryDirection
      ? .stationary
      : CalendarNavigationDirection(from: requestedInterval.start, to: interval.start)
    if interval != requestedInterval {
      selectedEvent = nil
    }
    focusedDate = date
    requestedInterval = interval
    periodNavigationRequest = nil
    if preparedEvents != nil {
      preparationGeneration &+= 1
      preparationTask?.cancel()
      preparationTask = nil
      preparationTarget = nil
      preparedPeriod = nil
      preparedViewport = nil
    } else {
      invalidatePreparedPeriod()
    }
    if let exactPreparedViewport {
      applyResolvedViewport(
        exactPreparedViewport.withNavigationDirection(requestedNavigationDirection)
      )
    } else {
      applyPeriod(
        events: preparedEvents ?? periodSchedule.events.filter {
            $0.startDate < interval.end && $0.endDate > interval.start
          },
        interval: interval,
        mode: displayMode,
        focusedDate: date
      )
    }
    if preparedEvents == nil {
      scheduleEventReload(interval: interval, mode: displayMode, focusedDate: date)
    }
  }

  private func switchDisplayMode(
    to mode: CalendarDisplayMode,
    focusedDate targetDate: Date
  ) {
    let interval = periodInterval(containing: targetDate, mode: mode)
    reloadGeneration &+= 1
    reloadTask?.cancel()
    reloadCoordinator.cancelActiveReload()
    requestedNavigationDirection = .stationary
    periodNavigationRequest = nil
    selectedEvent = nil
    focusedDate = targetDate
    requestedInterval = interval

    if let preparedPeriod,
       preparedPeriod.target.matches(mode: mode, focusedDate: targetDate, interval: interval) {
      let exactPreparedViewport = preparedViewport.flatMap { prepared -> CalendarViewportState? in
        prepared.displayMode == mode
          && prepared.focusedDate == targetDate
          && prepared.periodSchedule.startDate == interval.start
          && prepared.periodSchedule.endDate == interval.end
          ? prepared
          : nil
      }
      clearPreparedPeriodState()
      if let exactPreparedViewport {
        applyResolvedViewport(exactPreparedViewport.withNavigationDirection(.stationary))
      } else {
        applyPeriod(
          events: preparedPeriod.events,
          interval: interval,
          mode: mode,
          focusedDate: targetDate
        )
      }
      return
    }

    let visibleEvents = periodSchedule.events.filter {
      $0.startDate < interval.end && $0.endDate > interval.start
    }
    applyPeriod(
      events: visibleEvents,
      interval: interval,
      mode: mode,
      focusedDate: targetDate
    )

    if preparationTarget?.matches(mode: mode, focusedDate: targetDate, interval: interval) != true {
      scheduleEventReload(interval: interval, mode: mode, focusedDate: targetDate)
    }
  }

  private func invalidatePreparedPeriod() {
    preparationGeneration &+= 1
    preparationTask?.cancel()
    preparationTask = nil
    preparationTarget = nil
    preparedPeriod = nil
    preparedViewport = nil
  }

  private func clearPreparedPeriodState() {
    preparationGeneration &+= 1
    preparationTask?.cancel()
    preparationTask = nil
    preparationTarget = nil
    preparedPeriod = nil
    preparedViewport = nil
  }

  private func periodInterval(
    containing date: Date,
    mode: CalendarDisplayMode
  ) -> DateInterval {
    switch mode {
    case .week:
      let start = weekLayoutEngine.weekStart(containing: date)
      let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
      return DateInterval(start: start, end: end)
    case .month:
      return monthLayoutEngine.visibleInterval(containing: date)
    }
  }

  private func scheduleCalendarStoreReload() {
    invalidatePreparedPeriod()
    guard reloadCoordinator.requestCalendarStoreReload() else { return }
    startReload { [weak self] generation in
      guard let self else { return }
      await self.performCalendarStoreReload(generation: generation)
      self.finishCalendarStoreReload(generation: generation)
    }
  }

  private func performCalendarStoreReload(generation: Int) async {
    let updatedAuthorization = provider.authorizationStatus()
    if authorization != updatedAuthorization {
      authorization = updatedAuthorization
    }
    guard updatedAuthorization.canReadEvents else {
      applyCalendars([])
      applyPeriod(
        events: [],
        interval: requestedInterval,
        mode: displayMode,
        focusedDate: focusedDate
      )
      return
    }

    let sources = await provider.availableCalendars()
    guard isCurrentReload(generation) else { return }
    let currentIDs = Set(sources.map(\.id))
    let storedPreferences = filterPreferences ?? selectionStore.load()
    var preferences = storedPreferences

    if preferences == nil {
      preferences = CalendarFilterPreferences(
        selectedCalendarIDs: currentIDs,
        knownCalendarIDs: currentIDs
      )
    } else if var stored = preferences {
      let newCalendarIDs = currentIDs.subtracting(stored.knownCalendarIDs)
      stored.selectedCalendarIDs = stored.selectedCalendarIDs
        .intersection(currentIDs)
        .union(newCalendarIDs)
      stored.knownCalendarIDs = currentIDs
      preferences = stored
    }

    let resolved =
      preferences
      ?? CalendarFilterPreferences(
        selectedCalendarIDs: currentIDs,
        knownCalendarIDs: currentIDs
      )
    if filterPreferences != resolved {
      filterPreferences = resolved
    }
    if storedPreferences != resolved {
      selectionStore.save(resolved)
    }
    let updatedCalendars = sources.map { source in
      var updated = source
      updated.isEnabled = resolved.selectedCalendarIDs.contains(source.id)
      return updated
    }
    applyCalendars(updatedCalendars)

    await performEventReload(
      interval: requestedInterval,
      mode: displayMode,
      focusedDate: focusedDate,
      generation: generation
    )
  }

  private func reloadEvents() {
    scheduleEventReload(
      interval: requestedInterval,
      mode: displayMode,
      focusedDate: focusedDate
    )
  }

  private func schedulePeriodicEventRefresh() {
    guard authorization.canReadEvents, !enabledCalendarIDs.isEmpty else { return }
    scheduleEventReload(
      interval: requestedInterval,
      mode: displayMode,
      focusedDate: focusedDate
    )
  }

  func refreshEventsAfterWakeIfNeeded(at date: Date? = nil) {
    let now = date ?? nowProvider()
    guard lastSuccessfulEventReloadAt.map({ now.timeIntervalSince($0) >= Self.periodicRefreshInterval })
      ?? true
    else {
      return
    }
    schedulePeriodicEventRefresh()
  }

  private func scheduleEventReload(
    interval: DateInterval,
    mode: CalendarDisplayMode,
    focusedDate: Date
  ) {
    let calendarIDs = enabledCalendarIDs
    let key = EventReloadKey(
      interval: interval,
      mode: mode,
      focusedDate: focusedDate,
      calendarIDs: calendarIDs
    )
    guard reloadCoordinator.beginEventReload(for: key) == .start else { return }
    startReload { [weak self] generation in
      guard let self else { return }
      await self.performEventReload(
        interval: interval,
        mode: mode,
        focusedDate: focusedDate,
        calendarIDs: calendarIDs,
        generation: generation
      )
      self.finishEventReload(key: key, generation: generation)
    }
  }

  private func performEventReload(
    interval: DateInterval,
    mode: CalendarDisplayMode,
    focusedDate: Date,
    calendarIDs requestedCalendarIDs: Set<String>? = nil,
    generation: Int
  ) async {
    guard authorization.canReadEvents else { return }
    let calendarIDs = requestedCalendarIDs ?? enabledCalendarIDs
    let events = calendarIDs.isEmpty
      ? []
      : await provider.events(in: interval, calendarIDs: calendarIDs)
    guard isCurrentReload(generation) else { return }
    let refreshedAt = nowProvider()
    lastSuccessfulEventReloadAt = refreshedAt
    if periodInputsMatchCurrentViewport(
      events: events,
      interval: interval,
      mode: mode,
      focusedDate: focusedDate
    ) {
      return
    }

    let unstampedViewport = await layoutWorker.makeViewport(
      events: events,
      interval: interval,
      mode: mode,
      focusedDate: focusedDate,
      navigationDirection: requestedNavigationDirection,
      currentWeekLayout: weekLayout,
      currentMonthLayout: monthLayout
    )
    guard isCurrentReload(generation) else { return }
    applyResolvedViewport(stampViewport(unstampedViewport))
  }

  private func finishEventReload(key: EventReloadKey, generation: Int) {
    guard generation == reloadGeneration else { return }
    let shouldReloadStore = reloadCoordinator.finishEventReload(for: key)
    reloadTask = nil
    if shouldReloadStore { scheduleCalendarStoreReload() }
  }

  private func finishCalendarStoreReload(generation: Int) {
    guard generation == reloadGeneration else { return }
    let shouldReloadStore = reloadCoordinator.finishCalendarStoreReload()
    reloadTask = nil
    if shouldReloadStore { scheduleCalendarStoreReload() }
  }

  private func startReload(
    operation: @escaping @MainActor (Int) async -> Void
  ) {
    reloadGeneration &+= 1
    let generation = reloadGeneration
    reloadTask?.cancel()
    reloadTask = Task {
      await operation(generation)
    }
  }

  private func isCurrentReload(_ generation: Int) -> Bool {
    !Task.isCancelled && generation == reloadGeneration
  }

  private func applyCalendars(_ updatedCalendars: [CalendarSource]) {
    if calendars != updatedCalendars {
      calendars = updatedCalendars
      eventCreation.synchronizeCalendars(updatedCalendars)
    }
  }

  private func applyPeriod(
    events: [ScheduleEvent],
    interval: DateInterval,
    mode: CalendarDisplayMode,
    focusedDate: Date
  ) {
    let updatedViewport: CalendarViewportState
    if periodInputsMatchCurrentViewport(
      events: events,
      interval: interval,
      mode: mode,
      focusedDate: focusedDate
    ) {
      guard viewport.navigationDirection != requestedNavigationDirection else { return }
      updatedViewport = CalendarViewportState(
        displayMode: viewport.displayMode,
        focusedDate: viewport.focusedDate,
        periodSchedule: viewport.periodSchedule,
        weekLayout: viewport.weekLayout,
        monthLayout: viewport.monthLayout,
        navigationDirection: requestedNavigationDirection,
        renderRevision: viewport.renderRevision
      )
    } else {
      updatedViewport = makeViewport(
        events: events,
        interval: interval,
        mode: mode,
        focusedDate: focusedDate,
        navigationDirection: requestedNavigationDirection
      )
    }
    applyResolvedViewport(updatedViewport)
  }

  private func applyResolvedViewport(_ updatedViewport: CalendarViewportState) {
    if isZoomHandoffActive || isInteractiveNavigationActive {
      deferredZoomViewport = updatedViewport
      return
    }
    if viewport != updatedViewport { viewport = updatedViewport }

    let schedule = updatedViewport.periodSchedule
    if let selectedEvent {
      let refreshedSelection = schedule.events.first(where: { $0.id == selectedEvent.id })
      if self.selectedEvent != refreshedSelection {
        self.selectedEvent = refreshedSelection
      }
    }
  }

  private func periodInputsMatchCurrentViewport(
    events: [ScheduleEvent],
    interval: DateInterval,
    mode: CalendarDisplayMode,
    focusedDate: Date
  ) -> Bool {
    viewport.displayMode == mode
      && viewport.focusedDate == focusedDate
      && viewport.periodSchedule.startDate == interval.start
      && viewport.periodSchedule.endDate == interval.end
      && viewport.periodSchedule.events == events
  }

  private func makeViewport(
    events: [ScheduleEvent],
    interval: DateInterval,
    mode: CalendarDisplayMode,
    focusedDate: Date,
    navigationDirection: CalendarNavigationDirection
  ) -> CalendarViewportState {
    let schedule = CalendarPeriodSchedule(
      startDate: interval.start,
      endDate: interval.end,
      events: events
    )
    var updatedWeekLayout = weekLayout
    var updatedMonthLayout = monthLayout
    switch mode {
    case .week:
      let layout = weekLayoutEngine.makeLayout(events: events, weekStart: interval.start)
      updatedWeekLayout = layout
    case .month:
      let layout = monthLayoutEngine.makeLayout(events: events, containing: focusedDate)
      updatedMonthLayout = layout
    }

    return CalendarViewportState(
      displayMode: mode,
      focusedDate: focusedDate,
      periodSchedule: schedule,
      weekLayout: updatedWeekLayout,
      monthLayout: updatedMonthLayout,
      navigationDirection: navigationDirection,
      renderRevision: nextRenderRevision()
    )
  }

  private func stampViewport(_ viewport: CalendarViewportState) -> CalendarViewportState {
    viewport.withRenderRevision(nextRenderRevision())
  }

  private func nextRenderRevision() -> UInt64 {
    renderRevisionCounter &+= 1
    if renderRevisionCounter == 0 {
      renderRevisionCounter = 1
    }
    return renderRevisionCounter
  }
}
