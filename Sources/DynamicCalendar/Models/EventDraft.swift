import Foundation

enum EventCreationError: LocalizedError, Equatable {
  case accessDenied
  case calendarUnavailable
  case invalid(String)

  var errorDescription: String? {
    switch self {
    case .accessDenied: return "需要日历访问权限才能添加事件。"
    case .calendarUnavailable: return "所选日历已不可写，请选择其他日历。"
    case .invalid(let message): return message
    }
  }
}

enum EventRepeatFrequency: String, CaseIterable, Identifiable {
  case none, daily, weekly, monthly, yearly
  var id: Self { self }
  var title: String {
    switch self {
    case .none: return "不重复"
    case .daily: return "天"
    case .weekly: return "周"
    case .monthly: return "月"
    case .yearly: return "年"
    }
  }
}

enum EventRepeatEnd: String, CaseIterable, Identifiable {
  case never, date, count
  var id: Self { self }
  var title: String {
    switch self {
    case .never: return "永不"
    case .date: return "于日期"
    case .count: return "重复次数"
    }
  }
}

struct EventRepeatRule: Equatable {
  var frequency: EventRepeatFrequency = .none
  var interval = 1
  var weekdays: Set<Int> = []
  var end: EventRepeatEnd = .never
  var endDate: Date
  var count = 10
}

enum EventAlertChoice: String, CaseIterable, Identifiable {
  case none, atStart, fiveMinutes, tenMinutes, fifteenMinutes, thirtyMinutes
  case oneHour, twoHours, oneDay, twoDays, oneWeek, custom
  case sameDayMorning, previousMorning, twoDaysMorning
  var id: Self { self }
  var title: String {
    switch self {
    case .none: return "无"
    case .atStart: return "事件开始时"
    case .fiveMinutes: return "提前 5 分钟"
    case .tenMinutes: return "提前 10 分钟"
    case .fifteenMinutes: return "提前 15 分钟"
    case .thirtyMinutes: return "提前 30 分钟"
    case .oneHour: return "提前 1 小时"
    case .twoHours: return "提前 2 小时"
    case .oneDay: return "提前 1 天"
    case .twoDays: return "提前 2 天"
    case .oneWeek: return "提前 1 周"
    case .custom: return "自定义…"
    case .sameDayMorning: return "当天 09:00"
    case .previousMorning: return "前一天 09:00"
    case .twoDaysMorning: return "前两天 09:00"
    }
  }
  static func choices(allDay: Bool) -> [Self] {
    allDay ? [.none, .sameDayMorning, .previousMorning, .twoDaysMorning, .custom]
      : [.none, .atStart, .fiveMinutes, .tenMinutes, .fifteenMinutes, .thirtyMinutes,
         .oneHour, .twoHours, .oneDay, .twoDays, .oneWeek, .custom]
  }
}

struct EventDraft: Equatable {
  var title = ""
  var location = ""
  var notes = ""
  var urlText = ""
  var calendarID: String
  var start: Date
  var end: Date
  var isAllDay = false
  var timeZone: TimeZone
  var recurrence: EventRepeatRule
  var alert: EventAlertChoice = .none
  var customAlertAmount = 15
  var customAlertUnit = 60
  private var timedStart: Date?
  private var timedEnd: Date?

  init(focusedDate: Date, now: Date, calendar: Calendar, calendarID: String) {
    self.calendarID = calendarID
    timeZone = calendar.timeZone
    if calendar.isDate(focusedDate, inSameDayAs: now) {
      let minute = calendar.component(.minute, from: now)
      let floor = calendar.dateInterval(of: .minute, for: now)?.start ?? now
      start = calendar.date(byAdding: .minute, value: 30 - minute % 30, to: floor) ?? now
    } else {
      start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: focusedDate) ?? focusedDate
    }
    end = calendar.date(byAdding: .hour, value: 1, to: start) ?? start.addingTimeInterval(3600)
    recurrence = EventRepeatRule(
      weekdays: [calendar.component(.weekday, from: start)],
      endDate: calendar.date(byAdding: .month, value: 1, to: start) ?? end
    )
  }

  var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
  }

  mutating func moveStart(to date: Date, preservingRepeatWeekdays: Bool = false) {
    if isAllDay {
      let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
      start = calendar.startOfDay(for: date)
      end = calendar.date(byAdding: .day, value: max(0, days), to: start) ?? start
    } else {
      let duration = end.timeIntervalSince(start)
      start = date
      end = date.addingTimeInterval(max(60, duration))
    }
    if !preservingRepeatWeekdays { recurrence.weekdays = [calendar.component(.weekday, from: start)] }
  }

  mutating func setAllDay(_ value: Bool) {
    guard isAllDay != value else { return }
    if value {
      timedStart = start
      timedEnd = end
      start = calendar.startOfDay(for: start)
      end = calendar.startOfDay(for: end.addingTimeInterval(-1))
      end = max(start, end)
    } else {
      let startTime = calendar.dateComponents([.hour, .minute], from: timedStart ?? start)
      let endTime = calendar.dateComponents([.hour, .minute], from: timedEnd ?? end)
      start = calendar.date(bySettingHour: startTime.hour ?? 9, minute: startTime.minute ?? 0,
                            second: 0, of: start) ?? start
      end = calendar.date(bySettingHour: endTime.hour ?? 10, minute: endTime.minute ?? 0,
                          second: 0, of: end) ?? end
      if endTime.hour == 0 && endTime.minute == 0 {
        end = calendar.date(byAdding: .day, value: 1, to: end) ?? end
      }
      if end <= start { end = start.addingTimeInterval(3600) }
    }
    isAllDay = value
    if !EventAlertChoice.choices(allDay: value).contains(alert) { alert = .none }
  }

  var savedStart: Date { isAllDay ? calendar.startOfDay(for: start) : start }
  var savedEnd: Date {
    isAllDay ? (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end) : end
  }

  var alarmOffset: TimeInterval? {
    switch alert {
    case .none: return nil
    case .atStart: return 0
    case .fiveMinutes: return -300
    case .tenMinutes: return -600
    case .fifteenMinutes: return -900
    case .thirtyMinutes: return -1800
    case .oneHour: return -3600
    case .twoHours: return -7200
    case .oneDay: return -86400
    case .twoDays: return -172800
    case .oneWeek: return -604800
    case .custom: return -Double(customAlertAmount) * Double(customAlertUnit)
    case .sameDayMorning, .previousMorning, .twoDaysMorning:
      let days = alert == .sameDayMorning ? 0 : (alert == .previousMorning ? -1 : -2)
      let day = calendar.date(byAdding: .day, value: days, to: savedStart) ?? savedStart
      let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
      return morning.timeIntervalSince(savedStart)
    }
  }

  func validate() throws {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw EventCreationError.invalid("请填写事件标题。")
    }
    guard savedEnd > savedStart else { throw EventCreationError.invalid("结束时间必须晚于开始时间。") }
    guard !calendarID.isEmpty else { throw EventCreationError.calendarUnavailable }
    let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !url.isEmpty {
      guard let parsed = URLComponents(string: url),
            ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
            parsed.host?.isEmpty == false else {
        throw EventCreationError.invalid("请输入包含 http:// 或 https:// 的有效网址。")
      }
    }
    if recurrence.frequency != .none {
      guard (1...999).contains(recurrence.interval) else {
        throw EventCreationError.invalid("重复间隔须为 1–999。")
      }
      if recurrence.frequency == .weekly && recurrence.weekdays.isEmpty {
        throw EventCreationError.invalid("请选择至少一个重复的星期。")
      }
      if recurrence.end == .date && calendar.startOfDay(for: recurrence.endDate) < calendar.startOfDay(for: start) {
        throw EventCreationError.invalid("重复结束日期不能早于事件开始日期。")
      }
      if recurrence.end == .count && !(1...9999).contains(recurrence.count) {
        throw EventCreationError.invalid("重复次数须为 1–9999。")
      }
    }
    if alert == .custom && (!(1...9999).contains(customAlertAmount) || ![60, 3600, 86400].contains(customAlertUnit)) {
      throw EventCreationError.invalid("请输入 1–9999 的提醒提前量。")
    }
  }
}
