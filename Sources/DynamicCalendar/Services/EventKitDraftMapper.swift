import EventKit
import Foundation

enum EventKitDraftMapper {
  static func apply(_ draft: EventDraft, to event: EKEvent) {
    event.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    event.startDate = draft.savedStart
    event.endDate = draft.savedEnd
    event.isAllDay = draft.isAllDay
    event.timeZone = draft.isAllDay ? nil : draft.timeZone
    event.location = nonempty(draft.location)
    event.notes = nonempty(draft.notes)
    event.url = nonempty(draft.urlText).flatMap(URL.init(string:))
    event.alarms = draft.alarmOffset.map { [EKAlarm(relativeOffset: $0)] }
    event.recurrenceRules = recurrence(draft).map { [$0] }
  }

  static func recurrence(_ draft: EventDraft) -> EKRecurrenceRule? {
    let rule = draft.recurrence
    let frequency: EKRecurrenceFrequency
    switch rule.frequency {
    case .none: return nil
    case .daily: frequency = .daily
    case .weekly: frequency = .weekly
    case .monthly: frequency = .monthly
    case .yearly: frequency = .yearly
    }
    let end: EKRecurrenceEnd?
    switch rule.end {
    case .never: end = nil
    case .count: end = EKRecurrenceEnd(occurrenceCount: rule.count)
    case .date:
      let nextDay = draft.calendar.date(byAdding: .day, value: 1,
        to: draft.calendar.startOfDay(for: rule.endDate)) ?? rule.endDate
      end = EKRecurrenceEnd(end: nextDay.addingTimeInterval(-1))
    }
    let days: [EKRecurrenceDayOfWeek]? = frequency == .weekly ? rule.weekdays.sorted().compactMap {
      EKWeekday(rawValue: $0).map { EKRecurrenceDayOfWeek($0) }
    } : nil
    return EKRecurrenceRule(recurrenceWith: frequency, interval: rule.interval,
      daysOfTheWeek: days, daysOfTheMonth: nil, monthsOfTheYear: nil,
      weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: end)
  }

  private static func nonempty(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
