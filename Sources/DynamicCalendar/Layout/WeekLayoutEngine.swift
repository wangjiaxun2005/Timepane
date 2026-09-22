import Foundation

struct WeekLayoutEngine {
  private let calendar: Calendar

  init(calendar: Calendar = .autoupdatingCurrent) {
    self.calendar = calendar
  }

  func weekStart(containing date: Date) -> Date {
    calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
  }

  func makeLayout(
    events: [ScheduleEvent],
    weekStart: Date
  ) -> WeekLayout {
    let normalizedStart = self.weekStart(containing: weekStart)
    let weekEnd = calendar.date(byAdding: .day, value: 7, to: normalizedStart) ?? normalizedStart
    let weekInterval = DateInterval(start: normalizedStart, end: weekEnd)
    let relevantEvents = events.filter {
      $0.endDate > weekInterval.start && $0.startDate < weekInterval.end
    }

    let dayBoundaries = (0...7).compactMap {
      calendar.date(byAdding: .day, value: $0, to: normalizedStart)
    }
    guard dayBoundaries.count == 8 else {
      return WeekLayout.empty(startingAt: normalizedStart, calendar: calendar)
    }

    var allDayBuckets = Array(repeating: [ScheduleEvent](), count: 7)
    var timedBuckets = Array(repeating: [TimedSeed](), count: 7)
    for event in relevantEvents {
      let eventStartDay = calendar.startOfDay(for: event.startDate)
      let inclusiveEnd = max(
        event.endDate,
        event.startDate.addingTimeInterval(0.001)
      ).addingTimeInterval(-0.001)
      let eventEndDay = calendar.startOfDay(for: inclusiveEnd)
      let rawStartIndex = calendar.dateComponents(
        [.day],
        from: normalizedStart,
        to: eventStartDay
      ).day ?? 0
      let rawEndIndex = calendar.dateComponents(
        [.day],
        from: normalizedStart,
        to: eventEndDay
      ).day ?? rawStartIndex
      let firstDayIndex = max(0, rawStartIndex)
      let lastDayIndex = min(6, rawEndIndex)
      guard firstDayIndex <= lastDayIndex else { continue }

      for dayIndex in firstDayIndex...lastDayIndex {
        let dayStart = dayBoundaries[dayIndex]
        let dayEnd = dayBoundaries[dayIndex + 1]
        guard event.endDate > dayStart && event.startDate < dayEnd else { continue }

        if event.isAllDay {
          allDayBuckets[dayIndex].append(event)
          continue
        }

        let segmentStart = max(event.startDate, dayStart)
        let segmentEnd = min(max(event.endDate, event.startDate.addingTimeInterval(60)), dayEnd)
        let startMinute = minuteOffset(from: dayStart, to: segmentStart)
        let endMinute = max(startMinute + 1, minuteOffset(from: dayStart, to: segmentEnd))
        timedBuckets[dayIndex].append(
          TimedSeed(
            id: "\(event.id)-day\(dayIndex)",
            event: event,
            dayIndex: dayIndex,
            startMinute: max(0, min(1440, startMinute)),
            endMinute: max(0, min(1440, endMinute))
          )
        )
      }
    }

    var days: [DayLayout] = []
    days.reserveCapacity(7)
    var earliestTimedMinute: Int?
    var latestTimedMinute: Int?
    for dayIndex in 0..<7 {
      let dayStart = dayBoundaries[dayIndex]
      var allDayEvents = allDayBuckets[dayIndex]
      allDayEvents.sort { lhs, rhs in
        if lhs.startDate == rhs.startDate { return lhs.title < rhs.title }
        return lhs.startDate < rhs.startDate
      }

      let timedEvents = assignLanes(to: timedBuckets[dayIndex])
      for item in timedEvents {
        earliestTimedMinute = min(earliestTimedMinute ?? item.startMinute, item.startMinute)
        latestTimedMinute = max(latestTimedMinute ?? item.endMinute, item.endMinute)
      }

      days.append(
        DayLayout(
          date: dayStart,
          allDayEvents: allDayEvents,
          timedEvents: timedEvents
        )
      )
    }

    let visibleStart = earliestTimedMinute.map {
      max(0, min(8 * 60, roundedHour($0 - 30, direction: .down)))
    } ?? 8 * 60
    let visibleEnd = latestTimedMinute.map {
      min(24 * 60, max(20 * 60, roundedHour($0 + 30, direction: .up)))
    } ?? 20 * 60

    return WeekLayout(
      weekStart: normalizedStart,
      weekEnd: weekEnd,
      visibleStartMinute: visibleStart,
      visibleEndMinute: max(visibleStart + 60, visibleEnd),
      days: days,
      maximumAllDayEventCount: days.reduce(0) { maximum, day in
        max(maximum, day.allDayEvents.count)
      }
    )
  }

  private func minuteOffset(from start: Date, to end: Date) -> Int {
    calendar.dateComponents([.minute], from: start, to: end).minute ?? 0
  }

  private enum RoundDirection {
    case up
    case down
  }

  private func roundedHour(_ minute: Int, direction: RoundDirection) -> Int {
    switch direction {
    case .down:
      return Int(floor(Double(minute) / 60.0)) * 60
    case .up:
      return Int(ceil(Double(minute) / 60.0)) * 60
    }
  }

  private func assignLanes(to seeds: [TimedSeed]) -> [TimedEventLayout] {
    let sorted = seeds.sorted {
      if $0.startMinute == $1.startMinute { return $0.endMinute > $1.endMinute }
      return $0.startMinute < $1.startMinute
    }

    var result: [TimedEventLayout] = []
    result.reserveCapacity(sorted.count)
    var cluster: [TimedSeed] = []
    var clusterEnd = -1

    func appendCluster(_ cluster: [TimedSeed], to output: inout [TimedEventLayout]) {
      guard !cluster.isEmpty else { return }
      var laneEnds: [Int] = []
      var assignments: [(TimedSeed, Int)] = []
      laneEnds.reserveCapacity(cluster.count)
      assignments.reserveCapacity(cluster.count)

      for seed in cluster {
        let availableLane = laneEnds.firstIndex(where: { $0 <= seed.startMinute })
        let lane = availableLane ?? laneEnds.count
        if let availableLane {
          laneEnds[availableLane] = seed.endMinute
        } else {
          laneEnds.append(seed.endMinute)
        }
        assignments.append((seed, lane))
      }

      let laneCount = max(1, laneEnds.count)
      for (seed, lane) in assignments {
        output.append(
          TimedEventLayout(
            id: seed.id,
            event: seed.event,
            dayIndex: seed.dayIndex,
            startMinute: seed.startMinute,
            endMinute: seed.endMinute,
            lane: lane,
            laneCount: laneCount
          ))
      }
    }

    for seed in sorted {
      if !cluster.isEmpty, seed.startMinute >= clusterEnd {
        appendCluster(cluster, to: &result)
        cluster.removeAll(keepingCapacity: true)
        clusterEnd = -1
      }
      cluster.append(seed)
      clusterEnd = max(clusterEnd, seed.endMinute)
    }
    appendCluster(cluster, to: &result)

    return result
  }
}

private struct TimedSeed {
  let id: String
  let event: ScheduleEvent
  let dayIndex: Int
  let startMinute: Int
  let endMinute: Int
}
