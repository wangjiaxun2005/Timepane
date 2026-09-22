import XCTest
@testable import DynamicCalendar

final class MonthLayoutEngineTests: XCTestCase {
  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(secondsFromGMT: 0)!
    value.firstWeekday = 2
    return value
  }

  func testMonthGridUsesFourFiveAndSixWeeks() {
    let engine = MonthLayoutEngine(calendar: calendar)

    XCTAssertEqual(engine.makeLayout(events: [], containing: date(2021, 2, 10)).weeks.count, 4)
    XCTAssertEqual(engine.makeLayout(events: [], containing: date(2026, 9, 10)).weeks.count, 5)
    XCTAssertEqual(engine.makeLayout(events: [], containing: date(2026, 8, 10)).weeks.count, 6)
  }

  func testGridIncludesAdjacentMonthDates() {
    let layout = MonthLayoutEngine(calendar: calendar).makeLayout(
      events: [],
      containing: date(2026, 9, 10)
    )

    XCTAssertEqual(layout.gridStart, date(2026, 8, 31))
    XCTAssertEqual(layout.gridEnd, date(2026, 10, 5))
    XCTAssertFalse(layout.weeks[0].days[0].isInDisplayedMonth)
    XCTAssertTrue(layout.weeks[0].days[1].isInDisplayedMonth)
    XCTAssertFalse(layout.weeks.last?.days.last?.isInDisplayedMonth ?? true)
  }

  func testTimedEventIsPlacedOnItsStartDateInStableOrder() {
    let late = event(
      id: "late",
      start: date(2026, 9, 2, 14),
      end: date(2026, 9, 2, 15)
    )
    let early = event(
      id: "early",
      start: date(2026, 9, 2, 9),
      end: date(2026, 9, 2, 10)
    )
    let layout = MonthLayoutEngine(calendar: calendar).makeLayout(
      events: [late, early],
      containing: date(2026, 9, 10)
    )

    let day = layout.weeks.flatMap(\.days).first { $0.date == date(2026, 9, 2) }
    XCTAssertEqual(day?.timedEvents.map(\.id), ["early", "late"])
  }

  func testCrossWeekEventCreatesContinuousSegments() {
    let event = event(
      id: "trip",
      start: date(2026, 9, 4, 9),
      end: date(2026, 9, 9, 18)
    )
    let layout = MonthLayoutEngine(calendar: calendar).makeLayout(
      events: [event],
      containing: date(2026, 9, 10)
    )
    let spans = layout.weeks.flatMap(\.spanningEvents)

    XCTAssertEqual(spans.count, 2)
    XCTAssertEqual(spans[0].startDayIndex, 4)
    XCTAssertEqual(spans[0].endDayIndex, 6)
    XCTAssertEqual(spans[1].startDayIndex, 0)
    XCTAssertEqual(spans[1].endDayIndex, 2)
    XCTAssertTrue(spans.allSatisfy { $0.event.id == "trip" })
  }

  func testOverlappingSpansUseDifferentLanes() {
    let first = event(
      id: "first",
      start: date(2026, 9, 1, 9),
      end: date(2026, 9, 4, 10)
    )
    let second = event(
      id: "second",
      start: date(2026, 9, 2, 9),
      end: date(2026, 9, 5, 10)
    )
    let layout = MonthLayoutEngine(calendar: calendar).makeLayout(
      events: [second, first],
      containing: date(2026, 9, 10)
    )
    let spans = layout.weeks[0].spanningEvents

    XCTAssertEqual(Set(spans.map(\.lane)), Set([0, 1]))
  }

  func testAllDayEventUsesDailyMarkersInsteadOfSpanningLane() {
    let holiday = event(
      id: "holiday",
      start: date(2026, 9, 2),
      end: date(2026, 9, 5),
      isAllDay: true
    )
    let layout = MonthLayoutEngine(calendar: calendar).makeLayout(
      events: [holiday],
      containing: date(2026, 9, 10)
    )
    let days = layout.weeks.flatMap(\.days)

    XCTAssertTrue(layout.weeks.flatMap(\.spanningEvents).isEmpty)
    XCTAssertEqual(days.first { $0.date == date(2026, 9, 1) }?.allDayEvents, [])
    XCTAssertEqual(days.first { $0.date == date(2026, 9, 2) }?.allDayEvents.map(\.id), ["holiday"])
    XCTAssertEqual(days.first { $0.date == date(2026, 9, 3) }?.allDayEvents.map(\.id), ["holiday"])
    XCTAssertEqual(days.first { $0.date == date(2026, 9, 4) }?.allDayEvents.map(\.id), ["holiday"])
    XCTAssertEqual(days.first { $0.date == date(2026, 9, 5) }?.allDayEvents, [])
  }

  func testAllDayMarkersAreSortedStably() {
    let later = event(
      id: "later",
      start: date(2026, 9, 2),
      end: date(2026, 9, 3),
      isAllDay: true
    )
    let earlierID = event(
      id: "earlier",
      start: date(2026, 9, 2),
      end: date(2026, 9, 3),
      isAllDay: true
    )
    let layout = MonthLayoutEngine(calendar: calendar).makeLayout(
      events: [later, earlierID],
      containing: date(2026, 9, 10)
    )

    XCTAssertEqual(
      layout.weeks.flatMap(\.days).first { $0.date == date(2026, 9, 2) }?.allDayEvents.map(\.id),
      ["earlier", "later"]
    )
  }

  func testTimedEventEndingAtMidnightStaysOnOneDay() {
    let event = event(
      id: "late",
      start: date(2026, 9, 2, 23),
      end: date(2026, 9, 3)
    )
    let layout = MonthLayoutEngine(calendar: calendar).makeLayout(
      events: [event],
      containing: date(2026, 9, 10)
    )

    XCTAssertTrue(layout.weeks.flatMap(\.spanningEvents).isEmpty)
    XCTAssertEqual(
      layout.weeks.flatMap(\.days).first { $0.date == date(2026, 9, 2) }?.timedEvents.map(\.id),
      ["late"]
    )
  }

  private func date(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int = 0
  ) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
  }

  private func event(
    id: String,
    start: Date,
    end: Date,
    isAllDay: Bool = false
  ) -> ScheduleEvent {
    ScheduleEvent(
      id: id,
      title: id,
      startDate: start,
      endDate: end,
      isAllDay: isAllDay,
      location: nil,
      notes: nil,
      url: nil,
      calendarID: "work",
      calendarTitle: "工作",
      colorHex: "#3366FF"
    )
  }
}
