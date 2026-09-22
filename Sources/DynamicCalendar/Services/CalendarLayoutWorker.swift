import Foundation

protocol CalendarLayoutWorking: AnyObject {
  func makeViewport(
    events: [ScheduleEvent],
    interval: DateInterval,
    mode: CalendarDisplayMode,
    focusedDate: Date,
    navigationDirection: CalendarNavigationDirection,
    currentWeekLayout: WeekLayout,
    currentMonthLayout: MonthLayout
  ) async -> CalendarViewportState
}

final class CalendarLayoutWorker: CalendarLayoutWorking, @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "com.wangjiaxun.DynamicCalendar.layout",
    qos: .userInitiated
  )
  private let calendar: Calendar

  init(calendar: Calendar) {
    self.calendar = calendar
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
    await withCheckedContinuation { continuation in
      queue.async { [calendar] in
        let schedule = CalendarPeriodSchedule(
          startDate: interval.start,
          endDate: interval.end,
          events: events
        )
        var weekLayout = currentWeekLayout
        var monthLayout = currentMonthLayout
        switch mode {
        case .week:
          weekLayout = WeekLayoutEngine(calendar: calendar).makeLayout(
            events: events,
            weekStart: interval.start
          )
        case .month:
          monthLayout = MonthLayoutEngine(calendar: calendar).makeLayout(
            events: events,
            containing: focusedDate
          )
        }
        continuation.resume(
          returning: CalendarViewportState(
            displayMode: mode,
            focusedDate: focusedDate,
            periodSchedule: schedule,
            weekLayout: weekLayout,
            monthLayout: monthLayout,
            navigationDirection: navigationDirection
          )
        )
      }
    }
  }
}
