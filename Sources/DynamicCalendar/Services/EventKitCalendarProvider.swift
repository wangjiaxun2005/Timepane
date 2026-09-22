import AppKit
@preconcurrency import EventKit
import Foundation

@MainActor
final class EventKitCalendarProvider: CalendarProviding {
  var onCalendarStoreChanged: (() -> Void)?

  private let eventStore: EKEventStore
  private let queryQueue = DispatchQueue(
    label: "com.wangjiaxun.DynamicCalendar.event-query",
    qos: .userInitiated
  )
  private var changeObserver: NSObjectProtocol?
  private var changeWorkItem: DispatchWorkItem?

  init(eventStore: EKEventStore = EKEventStore()) {
    self.eventStore = eventStore
    changeObserver = NotificationCenter.default.addObserver(
      forName: .EKEventStoreChanged,
      object: eventStore,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.scheduleStoreChangedCallback()
      }
    }
  }

  deinit {
    changeWorkItem?.cancel()
    if let changeObserver {
      NotificationCenter.default.removeObserver(changeObserver)
    }
  }

  func authorizationStatus() -> CalendarAuthorizationState {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .notDetermined:
      return .notDetermined
    case .restricted:
      return .restricted
    case .denied, .writeOnly:
      return .denied
    case .authorized, .fullAccess:
      return .fullAccess
    @unknown default:
      return .denied
    }
  }

  func requestFullAccess() async -> CalendarAuthorizationState {
    do {
      _ = try await eventStore.requestFullAccessToEvents()
      return authorizationStatus()
    } catch {
      return authorizationStatus()
    }
  }

  func availableCalendars() async -> [CalendarSource] {
    guard authorizationStatus().canReadEvents else { return [] }

    let queryStore = EventStoreQueryHandle(eventStore)
    let cancellation = QueryCancellationToken()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        queryQueue.async {
          guard !cancellation.isCancelled else {
            continuation.resume(returning: [])
            return
          }
          let sources = autoreleasepool {
            queryStore.value.calendars(for: .event)
              .map { calendar in
                CalendarSource(
                  id: calendar.calendarIdentifier,
                  title: calendar.title,
                  colorHex: Self.hexColor(from: calendar.cgColor),
                  isEnabled: true,
                  isWritable: calendar.allowsContentModifications
                )
              }
              .sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
              }
          }
          continuation.resume(returning: sources)
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  func events(in interval: DateInterval, calendarIDs: Set<String>) async -> [ScheduleEvent] {
    guard authorizationStatus().canReadEvents, !calendarIDs.isEmpty else { return [] }

    let queryStore = EventStoreQueryHandle(eventStore)
    let cancellation = QueryCancellationToken()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        queryQueue.async {
          guard !cancellation.isCancelled else {
            continuation.resume(returning: [])
            return
          }
          let events = autoreleasepool {
            let calendars = queryStore.value.calendars(for: .event).filter {
              calendarIDs.contains($0.calendarIdentifier)
            }
            guard !calendars.isEmpty else { return [ScheduleEvent]() }

            let metadataByID = Dictionary(
              uniqueKeysWithValues: calendars.map { calendar in
                (
                  calendar.calendarIdentifier,
                  CalendarMetadata(
                    title: calendar.title,
                    colorHex: Self.hexColor(from: calendar.cgColor)
                  )
                )
              }
            )
            let predicate = queryStore.value.predicateForEvents(
              withStart: interval.start,
              end: interval.end,
              calendars: calendars
            )

            return queryStore.value.events(matching: predicate)
              .filter { $0.status != .canceled }
              .map { event in
                Self.makeScheduleEvent(
                  from: event,
                  metadata: metadataByID[event.calendar.calendarIdentifier]
                )
              }
              .sorted {
                if $0.startDate == $1.startDate { return $0.endDate < $1.endDate }
                return $0.startDate < $1.startDate
              }
          }
          continuation.resume(returning: events)
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  func defaultCalendarForNewEvents() async -> String? {
    guard authorizationStatus().canReadEvents else { return nil }
    let store = EventStoreQueryHandle(eventStore)
    return await withCheckedContinuation { continuation in
      queryQueue.async {
        let calendar = store.value.defaultCalendarForNewEvents
        continuation.resume(returning: calendar?.allowsContentModifications == true
          ? calendar?.calendarIdentifier : nil)
      }
    }
  }

  func createEvent(_ draft: EventDraft) async throws -> ScheduleEvent {
    try draft.validate()
    guard authorizationStatus().canReadEvents else { throw EventCreationError.accessDenied }
    let store = EventStoreQueryHandle(eventStore)
    return try await withCheckedThrowingContinuation { continuation in
      queryQueue.async {
        do {
          guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw EventCreationError.accessDenied
          }
          guard let calendar = store.value.calendar(withIdentifier: draft.calendarID),
                calendar.allowsContentModifications else { throw EventCreationError.calendarUnavailable }
          let event = EKEvent(eventStore: store.value)
          event.calendar = calendar
          EventKitDraftMapper.apply(draft, to: event)
          try store.value.save(event, span: .thisEvent, commit: true)
          continuation.resume(returning: Self.makeScheduleEvent(from: event, metadata: nil))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func scheduleStoreChangedCallback() {
    changeWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        self?.changeWorkItem = nil
        self?.onCalendarStoreChanged?()
      }
    }
    changeWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
  }

  nonisolated private static func makeScheduleEvent(
    from event: EKEvent,
    metadata: CalendarMetadata?
  ) -> ScheduleEvent {
    let eventID = event.eventIdentifier ?? event.calendarItemIdentifier
    let occurrenceID = "\(eventID)-\(Int(event.startDate.timeIntervalSince1970))"
    return ScheduleEvent(
      id: occurrenceID,
      title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "未命名日程",
      startDate: event.startDate,
      endDate: max(event.endDate, event.startDate),
      isAllDay: event.isAllDay,
      location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      notes: event.notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      url: event.url,
      calendarID: event.calendar.calendarIdentifier,
      calendarTitle: metadata?.title ?? event.calendar.title,
      colorHex: metadata?.colorHex ?? hexColor(from: event.calendar.cgColor)
    )
  }

  nonisolated private static func hexColor(from cgColor: CGColor) -> String {
    guard let color = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else {
      return "#5B8DEF"
    }

    return String(
      format: "#%02X%02X%02X",
      Int((color.redComponent * 255).rounded()),
      Int((color.greenComponent * 255).rounded()),
      Int((color.blueComponent * 255).rounded())
    )
  }
}

private struct CalendarMetadata {
  let title: String
  let colorHex: String
}

private struct EventStoreQueryHandle: @unchecked Sendable {
  let value: EKEventStore

  init(_ value: EKEventStore) {
    self.value = value
  }
}

private final class QueryCancellationToken: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}

extension String {
  fileprivate var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
