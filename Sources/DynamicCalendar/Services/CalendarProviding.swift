import Foundation

@MainActor
protocol CalendarProviding: AnyObject {
    var onCalendarStoreChanged: (() -> Void)? { get set }

    func authorizationStatus() -> CalendarAuthorizationState
    func requestFullAccess() async -> CalendarAuthorizationState
    func availableCalendars() async -> [CalendarSource]
    func events(in interval: DateInterval, calendarIDs: Set<String>) async -> [ScheduleEvent]
    func defaultCalendarForNewEvents() async -> String?
    func createEvent(_ draft: EventDraft) async throws -> ScheduleEvent
}

extension CalendarProviding {
    func defaultCalendarForNewEvents() async -> String? { nil }
    func createEvent(_ draft: EventDraft) async throws -> ScheduleEvent {
        throw EventCreationError.calendarUnavailable
    }
}
