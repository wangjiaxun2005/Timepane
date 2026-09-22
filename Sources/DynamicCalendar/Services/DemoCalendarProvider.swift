#if DEBUG
import Foundation

@MainActor
final class DemoCalendarProvider: CalendarProviding {
    var onCalendarStoreChanged: (() -> Void)?

    private let calendar: Calendar
    private var createdEvents: [ScheduleEvent] = []
    private let sources: [CalendarSource] = [
        CalendarSource(id: "work", title: "工作", colorHex: "#5B8DEF", isEnabled: true, isWritable: true),
        CalendarSource(id: "focus", title: "专注", colorHex: "#8B5CF6", isEnabled: true, isWritable: true),
        CalendarSource(id: "personal", title: "个人", colorHex: "#34A853", isEnabled: true, isWritable: true)
    ]

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    func authorizationStatus() -> CalendarAuthorizationState { .fullAccess }

    func requestFullAccess() async -> CalendarAuthorizationState { .fullAccess }

    func availableCalendars() async -> [CalendarSource] { sources }

    func events(in interval: DateInterval, calendarIDs: Set<String>) async -> [ScheduleEvent] {
        (sampleEvents + createdEvents).filter {
            calendarIDs.contains($0.calendarID)
                && $0.endDate > interval.start
                && $0.startDate < interval.end
        }
    }

    func defaultCalendarForNewEvents() async -> String? { "work" }

    func createEvent(_ draft: EventDraft) async throws -> ScheduleEvent {
        try draft.validate()
        guard let source = sources.first(where: { $0.id == draft.calendarID && $0.isWritable }) else {
            throw EventCreationError.calendarUnavailable
        }
        let event = ScheduleEvent(id: UUID().uuidString, title: draft.title,
            startDate: draft.savedStart, endDate: draft.savedEnd, isAllDay: draft.isAllDay,
            location: draft.location, notes: draft.notes, url: URL(string: draft.urlText),
            calendarID: source.id, calendarTitle: source.title, colorHex: source.colorHex)
        createdEvents.append(event)
        onCalendarStoreChanged?()
        return event
    }

    private var sampleEvents: [ScheduleEvent] {
        return [
            makeEvent("launch", "产品发布周", day: 0, hour: 0, minute: 0, duration: 48 * 60, allDay: true, calendarID: "work"),
            makeEvent("planning", "本周计划", day: 0, hour: 9, minute: 0, duration: 50, location: "线上", calendarID: "work"),
            makeEvent("research", "用户研究回顾", day: 0, hour: 11, minute: 0, duration: 75, location: "会议室 A", calendarID: "work"),
            makeEvent("standup", "团队晨会", day: 1, hour: 9, minute: 30, duration: 30, location: "Zoom", calendarID: "work"),
            makeEvent("review", "交互设计评审", day: 1, hour: 10, minute: 0, duration: 90, location: "会议室 3A", calendarID: "work", notes: "确认周视图的信息密度、事件详情抽屉以及多屏触发行为。"),
            makeEvent("partner", "合作方同步", day: 1, hour: 10, minute: 30, duration: 45, location: "Google Meet", calendarID: "work", url: URL(string: "https://meet.google.com")),
            makeEvent("focus", "专注：周历视觉打磨", day: 1, hour: 14, minute: 0, duration: 150, location: "免打扰", calendarID: "focus"),
            makeEvent("retro", "项目复盘", day: 2, hour: 11, minute: 0, duration: 60, location: "白板区", calendarID: "work"),
            makeEvent("dentist", "牙医预约", day: 2, hour: 16, minute: 30, duration: 45, location: "中环诊所", calendarID: "personal"),
            makeEvent("deep-work", "深度工作", day: 3, hour: 8, minute: 30, duration: 180, calendarID: "focus"),
            makeEvent("demo", "版本演示", day: 3, hour: 15, minute: 0, duration: 60, location: "线上", calendarID: "work"),
            makeEvent("weekly", "周总结", day: 4, hour: 17, minute: 0, duration: 45, calendarID: "work"),
            makeEvent("run", "跑步", day: 5, hour: 8, minute: 0, duration: 60, location: "海滨长廊", calendarID: "personal")
        ]
    }

    private func makeEvent(
        _ id: String,
        _ title: String,
        day: Int,
        hour: Int,
        minute: Int,
        duration: Int,
        allDay: Bool = false,
        location: String? = nil,
        calendarID: String,
        notes: String? = nil,
        url: URL? = nil
    ) -> ScheduleEvent {
        let now = Date()
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        let dayDate = calendar.date(byAdding: .day, value: day, to: weekStart) ?? weekStart
        let start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: dayDate) ?? dayDate
        let end = calendar.date(byAdding: .minute, value: duration, to: start) ?? start
        let source = sources.first(where: { $0.id == calendarID }) ?? sources[0]
        return ScheduleEvent(
            id: id,
            title: title,
            startDate: start,
            endDate: end,
            isAllDay: allDay,
            location: location,
            notes: notes,
            url: url,
            calendarID: source.id,
            calendarTitle: source.title,
            colorHex: source.colorHex
        )
    }
}
#endif
