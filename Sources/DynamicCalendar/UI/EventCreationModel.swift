import SwiftUI

enum EventCreationPhase: Equatable { case hidden, preparing, presenting, visible, dismissing }

@MainActor
final class EventCreationSourceState: ObservableObject {
  @Published var isCovered = false
  @Published var isPressed = false
  @Published var isLaunching = false
  @Published var handoffScale: CGFloat = 1
  private(set) var displayedScale: CGFloat = 1
  private(set) var displayedVelocity: CGFloat = 0
  private var sampledAt = 0.0
  private(set) var toolbarPressAmount: CGFloat = 0
  private(set) var toolbarPressVelocity: CGFloat = 0
  private var pressSampledAt = 0.0
  var toolbarPressDriver: ((CGFloat) -> Void)?
  func recordToolbarPress(amount: CGFloat) {
    let now = ProcessInfo.processInfo.systemUptime
    let dt = now - pressSampledAt
    toolbarPressVelocity = dt > 0.001 && dt < 0.1 ? (amount - toolbarPressAmount) / dt : 0
    toolbarPressAmount = amount
    pressSampledAt = now
    toolbarPressDriver?(amount)
  }

  func recordPresentation(scale: CGFloat) {
    let now = ProcessInfo.processInfo.systemUptime
    let elapsed = now - sampledAt
    if scale != displayedScale {
      displayedVelocity = elapsed > 0.001 && elapsed < 0.1 ? (scale - displayedScale) / elapsed : 0
      displayedScale = scale
      sampledAt = now
    } else if elapsed > 0.05 {
      displayedVelocity = 0
    }
  }

  var currentVelocity: CGFloat {
    ProcessInfo.processInfo.systemUptime - sampledAt < 0.05 ? displayedVelocity : 0
  }
}

@MainActor
final class EventCreationModel: ObservableObject {
  @Published private(set) var draftID = UUID()
  @Published var draft: EventDraft? {
    didSet {
      if draft?.calendarID != oldValue?.calendarID { calendarSelectionRevision &+= 1 }
    }
  }
  @Published private(set) var phase: EventCreationPhase = .hidden
  @Published private(set) var isSuspended = false
  @Published private(set) var calendars: [CalendarSource] = []
  @Published private(set) var authorization: CalendarAuthorizationState = .notDetermined
  @Published private(set) var isSaving = false
  @Published private(set) var isRequestingAccess = false
  @Published private(set) var isLoadingCalendars = false
  @Published var errorMessage: String?
  @Published var confirmsDiscard = false
  @Published private(set) var savedNotice: String?
  var motionDriver: ((Bool, @escaping () -> Void) -> Void)?
  weak var sourceView: NSView?
  var presentationLayoutDriver: (() -> Void)?
  var toolbarPinAction: (() -> Void)?
  weak var parentPresentationView: NSView?
  var sourceVisibilityDriver: ((Bool) -> Void)?
  // Native presentation values do not invalidate the calendar's SwiftUI tree.
  var toolbarLayoutDriver: ((CGFloat) -> Void)?
  private(set) var toolbarLayoutOffset: CGFloat = 0
  func presentToolbarLayout(_ offset: CGFloat) {
    toolbarLayoutOffset = offset
    toolbarLayoutDriver?(offset)
  }
  let sourceState = EventCreationSourceState()
  var reduceMotion = false
  var isActive: Bool { phase != .hidden }
  var isMounted: Bool { phase != .hidden && phase != .preparing }
  var isClosing: Bool { phase == .dismissing }
  var hasChanges: Bool { draft != initialDraft }
  var canSave: Bool {
    authorization.canReadEvents && calendars.contains(where: { $0.id == draft?.calendarID && $0.isWritable })
      && !isSaving && !isLoadingCalendars
  }

  @discardableResult
  func suspendPresentation() -> Bool {
    guard isActive, !isClosing, !isSaving, !isRequestingAccess, !confirmsDiscard else { return false }
    isSuspended = true
    return true
  }

  func resumePresentation() { isSuspended = false }
  private let provider: CalendarProviding
  private let onSaved: (ScheduleEvent) -> Void
  private let onAccessChanged: () -> Void
  private var initialDraft: EventDraft?
  private var transitionTask: Task<Void, Never>?
  private var calendarLoadTask: Task<Void, Never>?
  private var noticeTask: Task<Void, Never>?
  private var enabledIDs: Set<String> = []
  private var generation = 0
  private var calendarSelectionRevision = 0
  private var defaultCalendarID: String?

  init(provider: CalendarProviding, onSaved: @escaping (ScheduleEvent) -> Void,
       onAccessChanged: @escaping () -> Void = {}) {
    self.provider = provider
    self.onSaved = onSaved
    self.onAccessChanged = onAccessChanged
  }

  @discardableResult
  func reserve() -> Bool {
    if isClosing, draft != nil {
      animate(closing: false)
      return false
    }
    guard !isActive else { return false }
    isSuspended = false
    sourceState.isLaunching = true
    phase = .preparing
    savedNotice = nil
    return true
  }

  func prepare(focusedDate: Date, now: Date, calendar: Calendar, sources: [CalendarSource]) async {
    guard phase == .preparing else { return }
    enabledIDs = Set(sources.filter(\.isEnabled).map(\.id))
    authorization = provider.authorizationStatus()
    // Present from the calendar list already loaded by the main view. EventKit's
    // serial query queue must not gate the first frame of button feedback.
    calendars = sources.filter(\.isWritable)
    let selected = calendars.first(where: { $0.id == defaultCalendarID })
      ?? calendars.first(where: \.isEnabled) ?? calendars.first
    draftID = UUID()
    draft = EventDraft(focusedDate: focusedDate, now: now, calendar: calendar,
                       calendarID: selected?.id ?? "")
    initialDraft = draft
    errorMessage = nil
    isLoadingCalendars = true
    let preparedID = draftID
    let selectionRevision = calendarSelectionRevision
    animate(closing: false)
    calendarLoadTask?.cancel()
    calendarLoadTask = Task { [weak self] in
      await self?.resolveCalendars(for: preparedID, selectionRevision: selectionRevision)
    }
  }

  private func resolveCalendars(for preparedID: UUID, selectionRevision: Int) async {
    let refreshed = await provider.availableCalendars()
    guard !Task.isCancelled, draftID == preparedID, draft != nil else { return }
    let defaultID = await provider.defaultCalendarForNewEvents()
    // Publish metadata after motion, without relaying out the form mid-flight.
    // A cancelled/replaced draft must not receive a previous request's result.
    if phase != .visible {
      for await phase in $phase.values {
        if phase == .visible || phase == .hidden || draftID != preparedID { break }
      }
    }
    guard !Task.isCancelled, draftID == preparedID, draft != nil, phase == .visible else { return }
    defaultCalendarID = defaultID
    calendars = refreshed.filter(\.isWritable).map {
      var source = $0
      source.isEnabled = enabledIDs.contains(source.id)
      return source
    }
    if calendarSelectionRevision == selectionRevision {
      let resolved = calendars.first(where: { $0.id == defaultID })
        ?? calendars.first(where: \.isEnabled) ?? calendars.first
      draft?.calendarID = resolved?.id ?? ""
      initialDraft?.calendarID = draft?.calendarID ?? ""
    }
    isLoadingCalendars = false
  }

  func requestAccess() async {
    guard !isRequestingAccess else { return }
    calendarLoadTask?.cancel()
    isLoadingCalendars = false
    isRequestingAccess = true
    authorization = await provider.requestFullAccess()
    onAccessChanged()
    await reloadCalendars()
    let defaultID = await provider.defaultCalendarForNewEvents()
    if draft?.calendarID.isEmpty == true {
      draft?.calendarID = calendars.first(where: { $0.id == defaultID })?.id ?? calendars.first?.id ?? ""
      initialDraft?.calendarID = draft?.calendarID ?? ""
    }
    isRequestingAccess = false
  }

  func refreshAccess() async {
    guard isActive, !isSaving, !isRequestingAccess, !isLoadingCalendars else { return }
    authorization = provider.authorizationStatus()
    await reloadCalendars()
    if draft?.calendarID.isEmpty == true {
      let defaultID = await provider.defaultCalendarForNewEvents()
      draft?.calendarID = calendars.first(where: { $0.id == defaultID })?.id ?? calendars.first?.id ?? ""
      initialDraft?.calendarID = draft?.calendarID ?? ""
    }
  }

  func synchronizeCalendars(_ sources: [CalendarSource]) {
    guard isActive else { return }
    enabledIDs = Set(sources.filter(\.isEnabled).map(\.id))
    calendars = sources.filter(\.isWritable)
  }

  func requestCancel() {
    guard !isSaving, !isRequestingAccess, !isClosing else { return }
    if hasChanges { confirmsDiscard = true } else { dismiss() }
  }

  func dismiss() {
    guard !isSaving, !isRequestingAccess else { return }
    confirmsDiscard = false
    animate(closing: true)
  }

  func save() async {
    guard !isSaving, !isLoadingCalendars, phase == .visible || phase == .presenting, let draft else { return }
    do { try draft.validate() } catch { errorMessage = error.localizedDescription; return }
    isSaving = true
    errorMessage = nil
    do {
      let event = try await provider.createEvent(draft)
      onSaved(event)
      let hidden = calendars.first(where: { $0.id == event.calendarID })?.isEnabled == false
      savedNotice = hidden ? "已添加至“\(event.calendarTitle)”（此日历当前未显示）" : "事件已添加"
      isSaving = false
      dismiss()
      noticeTask?.cancel()
      noticeTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(4))
        guard !Task.isCancelled else { return }
        self?.savedNotice = nil
      }
    } catch {
      isSaving = false
      errorMessage = error.localizedDescription
      authorization = provider.authorizationStatus()
      await reloadCalendars()
    }
  }

  private func reloadCalendars() async {
    calendars = await provider.availableCalendars().filter(\.isWritable).map {
      var source = $0
      source.isEnabled = enabledIDs.contains(source.id)
      return source
    }
  }

  private func animate(closing: Bool) {
    transitionTask?.cancel()
    generation += 1
    let current = generation
    let duration = EventBubbleMotion.duration(closing: closing, reduceMotion: reduceMotion)
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      phase = closing ? .dismissing : .presenting
    }
    let finish: () -> Void = { [weak self] in
        guard let self, current == self.generation else { return }
        if closing {
          self.isSuspended = false
          self.phase = .hidden
          self.calendarLoadTask?.cancel()
          self.isLoadingCalendars = false
          self.sourceState.isLaunching = false
          self.sourceState.isPressed = false
          self.draft = nil
          self.initialDraft = nil
        } else { self.phase = .visible }
    }
    if let driver = motionDriver {
      // The native coordinator owns its retained canvas and mounts the initial
      // pose synchronously; no SwiftUI mount/yield is needed before starting.
      driver(closing, finish)
    } else {
      transitionTask = Task {
        try? await Task.sleep(for: .seconds(duration))
        guard !Task.isCancelled else { return }
        finish()
      }
    }
  }

}
