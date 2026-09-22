import Foundation

enum CalendarAuthorizationState: Equatable {
    case notDetermined
    case requesting
    case fullAccess
    case denied
    case restricted

    var canReadEvents: Bool {
        self == .fullAccess
    }
}

struct CalendarSource: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let colorHex: String
    var isEnabled: Bool
    let isWritable: Bool

    init(
        id: String,
        title: String,
        colorHex: String,
        isEnabled: Bool,
        isWritable: Bool = false
    ) {
        self.id = id
        self.title = title
        self.colorHex = colorHex
        self.isEnabled = isEnabled
        self.isWritable = isWritable
    }
}

struct ScheduleEvent: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let location: String?
    let notes: String?
    let url: URL?
    let calendarID: String
    let calendarTitle: String
    let colorHex: String

    var duration: TimeInterval {
        max(0, endDate.timeIntervalSince(startDate))
    }
}

enum CalendarDisplayMode: String, CaseIterable, Identifiable {
    case week
    case month

    var id: Self { self }
}

struct CalendarPeriodSchedule: Equatable {
    let startDate: Date
    let endDate: Date
    let events: [ScheduleEvent]
}

struct CalendarViewportState: Equatable {
    let displayMode: CalendarDisplayMode
    let focusedDate: Date
    let periodSchedule: CalendarPeriodSchedule
    let weekLayout: WeekLayout
    let monthLayout: MonthLayout
    let navigationDirection: CalendarNavigationDirection
    let renderRevision: UInt64

    init(
        displayMode: CalendarDisplayMode,
        focusedDate: Date,
        periodSchedule: CalendarPeriodSchedule,
        weekLayout: WeekLayout,
        monthLayout: MonthLayout,
        navigationDirection: CalendarNavigationDirection,
        renderRevision: UInt64 = 0
    ) {
        self.displayMode = displayMode
        self.focusedDate = focusedDate
        self.periodSchedule = periodSchedule
        self.weekLayout = weekLayout
        self.monthLayout = monthLayout
        self.navigationDirection = navigationDirection
        self.renderRevision = renderRevision
    }

    static func == (lhs: CalendarViewportState, rhs: CalendarViewportState) -> Bool {
        lhs.displayMode == rhs.displayMode
            && lhs.focusedDate == rhs.focusedDate
            && lhs.periodSchedule == rhs.periodSchedule
            && lhs.weekLayout == rhs.weekLayout
            && lhs.monthLayout == rhs.monthLayout
            && lhs.navigationDirection == rhs.navigationDirection
    }

    func withRenderRevision(_ revision: UInt64) -> CalendarViewportState {
        CalendarViewportState(
            displayMode: displayMode,
            focusedDate: focusedDate,
            periodSchedule: periodSchedule,
            weekLayout: weekLayout,
            monthLayout: monthLayout,
            navigationDirection: navigationDirection,
            renderRevision: revision
        )
    }

    func withNavigationDirection(
        _ direction: CalendarNavigationDirection
    ) -> CalendarViewportState {
        CalendarViewportState(
            displayMode: displayMode,
            focusedDate: focusedDate,
            periodSchedule: periodSchedule,
            weekLayout: weekLayout,
            monthLayout: monthLayout,
            navigationDirection: direction,
            renderRevision: renderRevision
        )
    }
}

struct TimedEventLayout: Identifiable, Equatable {
    let id: String
    let event: ScheduleEvent
    let dayIndex: Int
    let startMinute: Int
    let endMinute: Int
    let lane: Int
    let laneCount: Int
}

struct DayLayout: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let allDayEvents: [ScheduleEvent]
    let timedEvents: [TimedEventLayout]
}

struct WeekLayout: Equatable {
    let weekStart: Date
    let weekEnd: Date
    let visibleStartMinute: Int
    let visibleEndMinute: Int
    let days: [DayLayout]
    let maximumAllDayEventCount: Int

    static func empty(startingAt date: Date, calendar: Calendar = .autoupdatingCurrent) -> WeekLayout {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        let days = (0..<7).compactMap { offset -> DayLayout? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return DayLayout(date: day, allDayEvents: [], timedEvents: [])
        }
        return WeekLayout(
            weekStart: start,
            weekEnd: end,
            visibleStartMinute: 8 * 60,
            visibleEndMinute: 20 * 60,
            days: days,
            maximumAllDayEventCount: 0
        )
    }
}

struct MonthEventSpan: Identifiable, Equatable {
    let id: String
    let event: ScheduleEvent
    let startDayIndex: Int
    let endDayIndex: Int
    let lane: Int

    var daySpan: Int {
        max(1, endDayIndex - startDayIndex + 1)
    }
}

struct MonthDayLayout: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let isInDisplayedMonth: Bool
    let allDayEvents: [ScheduleEvent]
    let timedEvents: [ScheduleEvent]
}

struct MonthWeekLayout: Identifiable, Equatable {
    var id: Date { weekStart }
    let weekStart: Date
    let days: [MonthDayLayout]
    let spanningEvents: [MonthEventSpan]
    let spanningLaneCount: Int
    let maximumTimedEventCount: Int
}

struct MonthLayout: Equatable {
    let monthStart: Date
    let monthEnd: Date
    let gridStart: Date
    let gridEnd: Date
    let weeks: [MonthWeekLayout]

    static func empty(
        containing date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> MonthLayout {
        MonthLayoutEngine(calendar: calendar).makeLayout(events: [], containing: date)
    }
}
