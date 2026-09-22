import Foundation

struct MonthLayoutEngine {
  private let calendar: Calendar

  init(calendar: Calendar = .autoupdatingCurrent) {
    self.calendar = calendar
  }

  func visibleInterval(containing date: Date) -> DateInterval {
    let month = calendar.dateInterval(of: .month, for: date)
      ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86_400)
    let monthStart = calendar.startOfDay(for: month.start)
    let monthEnd = calendar.startOfDay(for: month.end)
    let gridStart = weekStart(containing: monthStart)
    let lastMonthDay = calendar.date(byAdding: .day, value: -1, to: monthEnd) ?? monthStart
    let finalWeekStart = weekStart(containing: lastMonthDay)
    let gridEnd = calendar.date(byAdding: .day, value: 7, to: finalWeekStart) ?? monthEnd
    return DateInterval(start: gridStart, end: gridEnd)
  }

  func makeLayout(events: [ScheduleEvent], containing date: Date) -> MonthLayout {
    let month = calendar.dateInterval(of: .month, for: date)
      ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86_400)
    let monthStart = calendar.startOfDay(for: month.start)
    let monthEnd = calendar.startOfDay(for: month.end)
    let gridInterval = visibleInterval(containing: date)
    let relevantEvents = events.filter {
      $0.endDate > gridInterval.start && $0.startDate < gridInterval.end
    }
    let dayCount = max(
      0,
      calendar.dateComponents([.day], from: gridInterval.start, to: gridInterval.end).day ?? 0
    )
    let weekCount = max(1, dayCount / 7)

    let dayBoundaries = (0...dayCount).compactMap {
      calendar.date(byAdding: .day, value: $0, to: gridInterval.start)
    }
    guard dayBoundaries.count == dayCount + 1 else {
      return MonthLayout(
        monthStart: monthStart,
        monthEnd: monthEnd,
        gridStart: gridInterval.start,
        gridEnd: gridInterval.end,
        weeks: []
      )
    }

    var allDayBuckets = Array(repeating: [ScheduleEvent](), count: dayCount)
    var timedBuckets = Array(repeating: [ScheduleEvent](), count: dayCount)
    var spanningSeedsByWeek = Array(repeating: [MonthSpanSeed](), count: weekCount)

    for event in relevantEvents {
      let eventStartDay = calendar.startOfDay(for: event.startDate)
      let eventEndDay = self.eventEndDay(for: event)

      if event.isAllDay {
        let rawStartIndex = calendar.dateComponents(
          [.day],
          from: gridInterval.start,
          to: eventStartDay
        ).day ?? 0
        let rawEndIndex = calendar.dateComponents(
          [.day],
          from: gridInterval.start,
          to: eventEndDay
        ).day ?? rawStartIndex
        let firstDayIndex = max(0, rawStartIndex)
        let lastDayIndex = min(dayCount - 1, rawEndIndex)
        if firstDayIndex <= lastDayIndex {
          for dayIndex in firstDayIndex...lastDayIndex {
            let dayStart = dayBoundaries[dayIndex]
            let dayEnd = dayBoundaries[dayIndex + 1]
            if event.endDate > dayStart && event.startDate < dayEnd {
              allDayBuckets[dayIndex].append(event)
            }
          }
        }
        continue
      }

      if eventEndDay == eventStartDay {
        let dayIndex = calendar.dateComponents(
          [.day],
          from: gridInterval.start,
          to: eventStartDay
        ).day ?? -1
        if (0..<dayCount).contains(dayIndex) {
          let dayStart = dayBoundaries[dayIndex]
          let dayEnd = dayBoundaries[dayIndex + 1]
          if event.startDate >= dayStart && event.startDate < dayEnd {
            timedBuckets[dayIndex].append(event)
          }
        }
        continue
      }

      let rawFirstWeek = calendar.dateComponents(
        [.day],
        from: gridInterval.start,
        to: eventStartDay
      ).day.map { $0 / 7 } ?? 0
      let rawLastWeek = calendar.dateComponents(
        [.day],
        from: gridInterval.start,
        to: eventEndDay
      ).day.map { $0 / 7 } ?? rawFirstWeek
      let firstWeekIndex = max(0, rawFirstWeek)
      let lastWeekIndex = min(weekCount - 1, rawLastWeek)
      guard firstWeekIndex <= lastWeekIndex else { continue }

      for weekIndex in firstWeekIndex...lastWeekIndex {
        let weekStart = dayBoundaries[weekIndex * 7]
        let weekEnd = dayBoundaries[min(dayCount, weekIndex * 7 + 7)]
        guard event.endDate > weekStart && event.startDate < weekEnd else { continue }

        let clippedStart = max(eventStartDay, weekStart)
        let clippedEnd = min(
          eventEndDay,
          calendar.date(byAdding: .day, value: -1, to: weekEnd) ?? eventEndDay
        )
        let startIndex = calendar.dateComponents(
          [.day],
          from: weekStart,
          to: clippedStart
        ).day ?? 0
        let endIndex = calendar.dateComponents(
          [.day],
          from: weekStart,
          to: clippedEnd
        ).day ?? 0
        guard startIndex <= endIndex, endIndex >= 0, startIndex < 7 else { continue }

        spanningSeedsByWeek[weekIndex].append(
          MonthSpanSeed(
            id: "\(event.id)-week\(weekIndex)-\(startIndex)",
            event: event,
            startDayIndex: max(0, startIndex),
            endDayIndex: min(6, endIndex)
          )
        )
      }
    }

    var weeks: [MonthWeekLayout] = []
    weeks.reserveCapacity(weekCount)
    for weekIndex in 0..<weekCount {
      let weekStart = dayBoundaries[weekIndex * 7]

      var days: [MonthDayLayout] = []
      days.reserveCapacity(7)
      for dayIndex in 0..<7 {
        let absoluteDayIndex = weekIndex * 7 + dayIndex
        guard absoluteDayIndex < dayCount else { continue }
        let dayStart = dayBoundaries[absoluteDayIndex]
        let timedEvents = timedBuckets[absoluteDayIndex].sorted(by: eventSort)
        let allDayEvents = allDayBuckets[absoluteDayIndex].sorted(by: eventSort)

        days.append(
          MonthDayLayout(
            date: dayStart,
            isInDisplayedMonth: dayStart >= monthStart && dayStart < monthEnd,
            allDayEvents: allDayEvents,
            timedEvents: timedEvents
          )
        )
      }

      let spanningLayout = assignLanes(to: spanningSeedsByWeek[weekIndex])
      weeks.append(
        MonthWeekLayout(
          weekStart: weekStart,
          days: days,
          spanningEvents: spanningLayout.events,
          spanningLaneCount: spanningLayout.laneCount,
          maximumTimedEventCount: days.map(\.timedEvents.count).max() ?? 0
        )
      )
    }

    return MonthLayout(
      monthStart: monthStart,
      monthEnd: monthEnd,
      gridStart: gridInterval.start,
      gridEnd: gridInterval.end,
      weeks: weeks
    )
  }

  private func weekStart(containing date: Date) -> Date {
    calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
  }

  private func eventEndDay(for event: ScheduleEvent) -> Date {
    let minimumEnd = max(event.endDate, event.startDate.addingTimeInterval(1))
    let inclusiveEnd = minimumEnd.addingTimeInterval(-0.001)
    return calendar.startOfDay(for: inclusiveEnd)
  }

  private func eventSort(_ lhs: ScheduleEvent, _ rhs: ScheduleEvent) -> Bool {
    if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
    if lhs.endDate != rhs.endDate { return lhs.endDate < rhs.endDate }
    return lhs.id < rhs.id
  }

  private func assignLanes(
    to seeds: [MonthSpanSeed]
  ) -> (events: [MonthEventSpan], laneCount: Int) {
    let sorted = seeds.sorted {
      if $0.startDayIndex != $1.startDayIndex { return $0.startDayIndex < $1.startDayIndex }
      if $0.endDayIndex != $1.endDayIndex { return $0.endDayIndex > $1.endDayIndex }
      if $0.event.startDate != $1.event.startDate { return $0.event.startDate < $1.event.startDate }
      return $0.event.id < $1.event.id
    }
    var laneEnds: [Int] = []
    var result: [MonthEventSpan] = []
    result.reserveCapacity(sorted.count)

    for seed in sorted {
      let reusableLane = laneEnds.firstIndex(where: { $0 < seed.startDayIndex })
      let lane = reusableLane ?? laneEnds.count
      if let reusableLane {
        laneEnds[reusableLane] = seed.endDayIndex
      } else {
        laneEnds.append(seed.endDayIndex)
      }
      result.append(
        MonthEventSpan(
          id: seed.id,
          event: seed.event,
          startDayIndex: seed.startDayIndex,
          endDayIndex: seed.endDayIndex,
          lane: lane
        )
      )
    }
    return (result, laneEnds.count)
  }
}

private struct MonthSpanSeed {
  let id: String
  let event: ScheduleEvent
  let startDayIndex: Int
  let endDayIndex: Int
}
