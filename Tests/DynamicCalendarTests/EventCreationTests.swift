import AppKit
import EventKit
import XCTest
@testable import DynamicCalendar

final class EventDraftTests: XCTestCase {
  func testBlurOverlapsReadableContentInsteadOfOnlyHiddenEmergence() {
    let source = CGRect(x: 352, y: 24, width: 92, height: 32)
    let destination = CGRect(x: 24, y: 74, width: 420, height: 520)
    for closing in [false, true] {
      let frames = (0...1000).map {
        EventFissionMotion.pose(EventFissionMotion.channels(at: Double($0) / 1000,
          closing: closing), source: source, destination: destination)
      }
      let visibleBlur = frames.filter { $0.contentOpacity > 0.5 && $0.contentBlur > 4 }
      XCTAssertGreaterThan(visibleBlur.count, 100)
      XCTAssertEqual(frames.first!.contentBlur, 0)
      XCTAssertEqual(frames.last!.contentBlur, 0)
    }
  }

  func testDelayedPresentationDoesNotSkipLoadingStage() {
    var clock = EventFissionPresentationClock()
    XCTAssertEqual(clock.advance(to: 10), 0)
    let delayed = clock.advance(to: 10.226)
    XCTAssertEqual(delayed, 1.0 / 30, accuracy: 0.000001)
    let shape = EventFissionMotion.channels(at: delayed / EventFissionMotion.openingDuration, closing: false)
    XCTAssertLessThan(shape.growth, 0.08)
    XCTAssertGreaterThan(shape.width, 1)
    XCTAssertEqual(clock.advance(to: 10.20), delayed)
    for frame in 1...31 { _ = clock.advance(to: 10.226 + Double(frame) / 60) }
    XCTAssertGreaterThan(clock.elapsed, EventFissionMotion.openingDuration)
  }

  func testReferenceContourRoundsBeforeResolvingAndHasSharpEndpoints() {
    let source = CGRect(x: 352, y: 24, width: 92, height: 32)
    let destination = CGRect(x: 24, y: 74, width: 420, height: 520)
    func pose(_ growth: Double) -> EventBubblePose {
      var channels = EventFissionChannels.open
      channels.growth = growth
      channels.content = growth
      channels.rotation = growth
      return EventFissionMotion.pose(channels, source: source, destination: destination)
    }
    let seed = pose(0.24)
    XCTAssertEqual(seed.radius, min(seed.body.width, seed.body.height) / 2, accuracy: 0.000001)
    XCTAssertLessThan(seed.body.width, source.width * 0.7 + (destination.width - source.width * 0.7) * 0.24)
    XCTAssertGreaterThan(seed.contentBlur, 0)
    XCTAssertEqual(pose(0).contentBlur, 0)
    XCTAssertEqual(pose(1).contentBlur, 0, accuracy: 0.000001)
    XCTAssertEqual(pose(1).body, destination)
    XCTAssertEqual(pose(1).radius, 22)
    var previousWidth: CGFloat = 0
    for step in 0...1000 {
      let sample = pose(Double(step) / 1000)
      XCTAssertGreaterThanOrEqual(sample.body.width, previousWidth)
      XCTAssertLessThanOrEqual(sample.radius, min(sample.body.width, sample.body.height) / 2 + 0.000001)
      XCTAssertLessThanOrEqual(sample.contentBlur, 10)
      previousWidth = sample.body.width
    }
  }

  func testClosingHasOneVisibleInflationPulseWithStableButtonCenters() {
    let source = CGRect(x: 352, y: 24, width: 92, height: 32)
    var widths: [CGFloat] = []
    for step in 0...1000 {
      let channels = EventFissionMotion.channels(at: Double(step) / 1000, closing: true)
      let pose = EventFissionMotion.toolbar(channels, source: source)
      widths.append(pose.mother.width)
      XCTAssertEqual(channels.receiverOffset, 0)
      XCTAssertEqual(pose.mother.midX, source.midX, accuracy: 0.000001)
      XCTAssertEqual(pose.mother.midY, source.midY, accuracy: 0.000001)
      XCTAssertEqual(pose.cancel.midY, source.midY)
      XCTAssertEqual(pose.save.midY, source.midY)
    }
    XCTAssertGreaterThan(widths.max()!, source.width * 1.15)
    let directions = zip(widths, widths.dropFirst()).compactMap { a, b -> Int? in
      abs(b - a) < 0.000001 ? nil : (b > a ? 1 : -1)
    }
    XCTAssertEqual(zip(directions, directions.dropFirst()).filter { $0 != $1 }.count, 1)
    XCTAssertEqual(widths.last!, source.width)
  }

  @MainActor
  func testToolbarAnchorExcludesSharedParentExpansionTransform() {
    final class FlippedView: NSView { override var isFlipped: Bool { true } }
    let root = FlippedView(frame: CGRect(x: 0, y: 0, width: 808, height: 668))
    let shared = FlippedView(frame: CGRect(x: 24, y: 24, width: 760, height: 620))
    let calendar = FlippedView(frame: CGRect(x: 0, y: 0, width: 760, height: 620))
    let host = FlippedView(frame: calendar.frame)
    let anchor = FlippedView(frame: CGRect(x: 654, y: 12, width: 92, height: 32))
    root.addSubview(shared)
    shared.addSubview(calendar)
    shared.addSubview(host)
    calendar.addSubview(anchor)
    let parentFrame = CGRect(x: 1000, y: 300, width: 808, height: 668)
    let expected = CGRect(x: 1678, y: 900, width: 92, height: 32)
    for time in [0.0, 0.14, 0.21, 0.29, 0.38, 0.64] {
      let sample = PanelExpansionTrajectory.content(at: time)
      shared.frame = CGRect(x: 24 + 760 * (1 - sample.scale), y: 24 + sample.offset,
                            width: 760 * sample.scale, height: 620 * sample.scale)
      shared.bounds = CGRect(x: 0, y: 0, width: 760, height: 620)
      let actual = EventCreationWindowCoordinator.restingSourceFrame(
        anchor: anchor, host: host, parentFrame: parentFrame)
      XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.000001)
      XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.000001)
      XCTAssertEqual(actual.width, expected.width, accuracy: 0.000001)
      XCTAssertEqual(actual.height, expected.height, accuracy: 0.000001)
      let shifted = EventCreationWindowCoordinator.restingSourceFrame(
        anchor: anchor, host: host, parentFrame: parentFrame.offsetBy(dx: 13, dy: 27))
      XCTAssertEqual(shifted.minX - actual.minX, 13, accuracy: 0.000001)
      XCTAssertEqual(shifted.minY - actual.minY, 27, accuracy: 0.000001)
    }
  }

  func testInterruptedFissionRemainsInPresentationBoundsThroughRepeatedReversals() {
    func values(_ c: EventFissionChannels) -> [Double] {
      [c.spread, c.width, c.height, c.growth, c.travel, c.content, c.rotation,
       c.buttonOverrun, c.saveOverrun, c.modeOverrun, c.editorOverrun, c.receiverOffset]
    }
    let opening = EventFissionTransition(closing: false, duration: EventFissionMotion.openingDuration,
      initial: .closed, initialVelocity: .zero)
    for interruption in [0.15, 0.30, 0.55, 0.80, 1.0] {
      var previous = opening
      var fraction = interruption
      for reversal in 0..<4 {
        let start = previous.channels(at: fraction).bounded
        let velocity = previous.velocity(at: fraction)
        let closing = reversal.isMultiple(of: 2)
        let duration = closing ? 0.20 : 0.28
        let next = EventFissionTransition(closing: closing, duration: duration,
          initial: start, initialVelocity: velocity, isRetargeting: true)
        for (actual, expected) in zip(values(next.channels(at: 0)), values(start)) {
          XCTAssertEqual(actual, expected, accuracy: 0.000001)
        }
        for step in 0...1000 {
          let actual = next.channels(at: Double(step) / 1000)
          for (raw, bounded) in zip(values(actual), values(actual.bounded)) {
            XCTAssertTrue(raw.isFinite)
            XCTAssertEqual(raw, bounded, accuracy: 0.000001, "A reversal must not rely on hard clipping")
          }
        }
        for (actual, expected) in zip(values(next.channels(at: 1)), values(closing ? .closed : .open)) {
          XCTAssertEqual(actual, expected, accuracy: 0.000001)
        }
        XCTAssertTrue(values(next.velocity(at: 1)).allSatisfy { $0 == 0 })
        previous = next
        fraction = 0.43
      }
    }
  }

  func testFissionReversalPreservesIncomingVelocityBeforeItsSingleTurn() {
    let opening = EventFissionTransition(closing: false, duration: EventFissionMotion.openingDuration,
      initial: .closed, initialVelocity: .zero)
    let fraction = 0.30
    let start = opening.channels(at: fraction)
    let velocity = opening.velocity(at: fraction)
    let closing = EventFissionTransition(closing: true, duration: 0.20,
      initial: start, initialVelocity: velocity, isRetargeting: true)
    let dt = 0.000001
    let first = closing.channels(at: dt / 0.20)
    XCTAssertEqual((first.growth - start.growth) / dt, velocity.growth, accuracy: 0.001)
    XCTAssertEqual((first.spread - start.spread) / dt, velocity.spread, accuracy: 0.001)
    let samples = (0...1000).map { closing.channels(at: Double($0) / 1000).growth }
    let directions = zip(samples, samples.dropFirst()).compactMap { a, b -> Int? in
      abs(b - a) < 0.0000001 ? nil : (b > a ? 1 : -1)
    }
    XCTAssertEqual(zip(directions, directions.dropFirst()).filter { $0 != $1 }.count, 1)
    XCTAssertEqual(directions.first, 1)
    XCTAssertEqual(directions.last, -1)
  }

  func testEditorEmergenceHasNoHardDepthVelocitySwitch() {
    let source = CGRect(x: 352, y: 24, width: 92, height: 32)
    let destination = CGRect(x: 24, y: 74, width: 420, height: 520)
    func top(_ height: Double) -> Double {
      var channels = EventFissionChannels.closed
      channels.growth = height / destination.height
      return EventFissionMotion.pose(channels, source: source, destination: destination).body.minY
    }
    let delta = 0.00001
    for height in [12.0, 24.0] {
      let before = (top(height) - top(height - delta)) / delta
      let after = (top(height + delta) - top(height)) / delta
      XCTAssertEqual(before, after, accuracy: 0.00001)
    }
  }

  func testFissionReleaseHasOneSharedShapePulseAndReturn() {
    let source = CGRect(x: 352, y: 24, width: 92, height: 32)
    let destination = CGRect(x: 24, y: 74, width: 420, height: 520)
    let frames = (0...1000).map { step -> EventBubblePose in
      let channels = EventFissionMotion.channels(at: Double(step) / 1000, closing: false)
      return EventFissionMotion.pose(channels, source: source, destination: destination)
    }
    let cancelPeak = frames.indices.max { frames[$0].toolbar!.cancel.width < frames[$1].toolbar!.cancel.width }!
    let savePeak = frames.indices.max { frames[$0].toolbar!.save.width < frames[$1].toolbar!.save.width }!
    XCTAssertLessThanOrEqual(abs(cancelPeak - savePeak), 2, "Both leaves must release the same shape pulse")
    for pose in frames {
      for leaf in [pose.toolbar!.cancel, pose.toolbar!.save] {
        XCTAssertEqual(leaf.width, leaf.height, accuracy: 0.000001,
          "Do not introduce a second directional pulse by stretching each axis independently")
      }
      XCTAssertLessThanOrEqual(pose.body.height, destination.height + 0.000001)
    }
    for (a, b) in zip(frames, frames.dropFirst()) {
      XCTAssertGreaterThanOrEqual(b.body.height + 0.000001, a.body.height)
    }
    let buttonPeak = frames.indices.min { frames[$0].toolbar!.cancel.midX < frames[$1].toolbar!.cancel.midX }!
    let editorPeak = frames.indices.max { frames[$0].body.minY < frames[$1].body.minY }!
    XCTAssertLessThanOrEqual(abs(buttonPeak - editorPeak), 2)
    let settled = frames.indices.dropFirst(buttonPeak).first {
      abs(frames[$0].toolbar!.cancel.midX - frames.last!.toolbar!.cancel.midX) < 0.0001
    }!
    let returnDuration = Double(settled - buttonPeak) / 1000 * EventFissionMotion.openingDuration
    XCTAssertLessThanOrEqual(returnDuration, 0.16)
    XCTAssertEqual(frames.last!.body, destination)
  }

  func testFissionClosingDoesNotLeaveALongEmptyAbsorptionTail() {
    let samples = (0...1000).map { EventFissionMotion.channels(at: Double($0) / 1000, closing: true) }
    let empty = samples.firstIndex { $0.content <= 0.000001 }!
    let absorbed = samples.firstIndex { $0.growth <= 0.000001 && $0.spread <= 0.000001 }!
    let duration = EventFissionMotion.closingDuration
    XCTAssertLessThanOrEqual(Double(absorbed - empty) / 1000 * duration, 0.04)
    XCTAssertLessThanOrEqual(Double(1000 - absorbed) / 1000 * duration, 0.14)
    for (a, b) in zip(samples, samples.dropFirst()) {
      XCTAssertLessThanOrEqual(b.growth, a.growth + 0.000001)
      XCTAssertLessThanOrEqual(b.spread, a.spread + 0.000001)
    }
    XCTAssertEqual(samples.last!.receiverOffset, 0)
    XCTAssertEqual(samples.last!.width, 1)
    XCTAssertEqual(samples.last!.height, 1)
  }

  func testToolbarLeavesAndModePickerHaveOneStaggeredOpeningRecoil() {
    let source = CGRect(x: 352, y: 24, width: 92, height: 32)
    for closing in [false, true] {
      let poses = (0...1200).map {
        EventToolbarMotion.pose(fraction: Double($0) / 1200, closing: closing, source: source)
      }
      let cancelCenters = poses.map { $0.cancel.midX }
      let saveCenters = poses.map { $0.save.midX }
      for centers in [cancelCenters, saveCenters] {
        let directions = zip(centers, centers.dropFirst()).compactMap { a, b -> Int? in
          guard abs(b - a) > 0.000001 else { return nil }
          return b > a ? 1 : -1
        }
        let turns = zip(directions, directions.dropFirst()).filter { $0 != $1 }.count
        XCTAssertEqual(directions.first, closing ? 1 : -1)
        XCTAssertEqual(directions.last, 1)
        XCTAssertEqual(turns, closing ? 0 : 1,
          "Each leaf should separate, overrun once, and return without intermediate wobble")
        if !closing {
          XCTAssertEqual(centers.min()!, centers.last! - 5, accuracy: 0.001)
        }
      }
      if !closing {
        let savePeak = saveCenters.indices.min { saveCenters[$0] < saveCenters[$1] }!
        let cancelPeak = cancelCenters.indices.min { cancelCenters[$0] < cancelCenters[$1] }!
        let modeOffsets = poses.map(\.layoutOffset)
        let modePeak = modeOffsets.indices.max { modeOffsets[$0] < modeOffsets[$1] }!
        XCTAssertLessThan(savePeak, cancelPeak,
          "The right leaf should begin its return before the left leaf")
        XCTAssertLessThan(cancelPeak, modePeak,
          "The mode picker should finish the same right-to-left return wave")
        let saveToCancel = Double(cancelPeak - savePeak) / 1200 * EventFissionMotion.openingDuration
        let cancelToMode = Double(modePeak - cancelPeak) / 1200 * EventFissionMotion.openingDuration
        XCTAssertEqual(saveToCancel, 0.040, accuracy: 0.001)
        XCTAssertEqual(cancelToMode, 0.040, accuracy: 0.001)
        XCTAssertEqual(modeOffsets.max()!, modeOffsets.last! + 5, accuracy: 0.001)
        let modeDirections = zip(modeOffsets, modeOffsets.dropFirst()).compactMap { a, b -> Int? in
          guard abs(b - a) > 0.000001 else { return nil }
          return b > a ? 1 : -1
        }
        XCTAssertEqual(zip(modeDirections, modeDirections.dropFirst()).filter { $0 != $1 }.count, 1,
          "The mode picker should overrun and return exactly once")
      }
      let endpoint = poses.last!
      XCTAssertEqual(endpoint.cancel.midX, source.minX + (closing ? 17 : -35), accuracy: 0.001)
      XCTAssertEqual(endpoint.save.midX, source.minX + (closing ? 17 : 5), accuracy: 0.001)
      XCTAssertEqual(endpoint.layoutOffset, closing ? 0 : 51, accuracy: 0.001)
    }
  }

  @MainActor
  func testSourceReuseToleratesSubpixelLayoutNoiseButNotRelocation() {
    let source = CGRect(x: 352, y: 24, width: 92, height: 32)
    XCTAssertTrue(EventBubbleMotion.matchesSource(source, source.offsetBy(dx: 0.000001, dy: 0), backingScale: 2))
    XCTAssertTrue(EventBubbleMotion.matchesSource(source, source.insetBy(dx: -0.25, dy: 0), backingScale: 2))
    XCTAssertFalse(EventBubbleMotion.matchesSource(source, source.offsetBy(dx: 1, dy: 0), backingScale: 2))
    XCTAssertFalse(EventBubbleMotion.matchesSource(source, source.insetBy(dx: 1, dy: 0), backingScale: 2))
  }

  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return value
  }
  private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
  private func draft(_ start: String = "2026-09-14T16:00:00Z") -> EventDraft {
    var result = EventDraft(focusedDate: date(start), now: date("2026-09-12T16:00:00Z"),
                            calendar: calendar, calendarID: "work")
    result.title = "Meeting"
    return result
  }

  func testTodayRoundsUpToNextHalfHourAndOtherDatesUseNine() {
    let now = date("2026-09-14T17:12:43Z")
    let current = EventDraft(focusedDate: now, now: now, calendar: calendar, calendarID: "work")
    XCTAssertEqual(current.start, date("2026-09-14T17:30:00Z"))
    XCTAssertEqual(current.end, date("2026-09-14T18:30:00Z"))
    XCTAssertEqual(draft().start, date("2026-09-14T16:00:00Z"))
    let midnight = date("2026-09-15T06:55:00Z")
    let nextDay = EventDraft(focusedDate: midnight, now: midnight, calendar: calendar, calendarID: "work")
    XCTAssertEqual(nextDay.start, date("2026-09-15T07:00:00Z"))
  }

  func testMovingStartPreservesDurationAcrossDayBoundary() {
    var value = draft()
    value.end = value.start.addingTimeInterval(7200)
    value.moveStart(to: date("2026-09-15T06:30:00Z"))
    XCTAssertEqual(value.end, date("2026-09-15T08:30:00Z"))
  }

  func testWeeklyPresetFollowsChangedStartButCustomWeekdaysStaySelected() {
    var value = draft()
    value.recurrence.frequency = .weekly
    value.moveStart(to: date("2026-09-15T16:00:00Z"))
    XCTAssertEqual(value.recurrence.weekdays, [3])
    value.recurrence.weekdays = [2, 4, 6]
    value.moveStart(to: date("2026-09-16T16:00:00Z"), preservingRepeatWeekdays: true)
    XCTAssertEqual(value.recurrence.weekdays, [2, 4, 6])
  }

  func testAllDayUsesExclusiveEndAndRestoresTimes() {
    var value = draft()
    let originalStart = value.start
    let originalEnd = value.end
    value.setAllDay(true)
    XCTAssertEqual(value.savedStart, date("2026-09-14T07:00:00Z"))
    XCTAssertEqual(value.savedEnd, date("2026-09-15T07:00:00Z"))
    value.setAllDay(false)
    XCTAssertEqual(value.start, originalStart)
    XCTAssertEqual(value.end, originalEnd)
  }

  func testAllDayCrossesSpringAndFallDSTByCalendarDays() {
    for (start, expectedHours) in [("2026-03-08T16:00:00Z", 23.0), ("2026-11-01T17:00:00Z", 25.0)] {
      var value = draft(start)
      value.setAllDay(true)
      XCTAssertEqual(value.savedEnd.timeIntervalSince(value.savedStart) / 3600, expectedHours)
      value.end = value.calendar.date(byAdding: .day, value: 2, to: value.start)!
      XCTAssertEqual(value.calendar.dateComponents([.day], from: value.savedStart, to: value.savedEnd).day, 3)
    }
  }

  func testAllDayMidnightEndRoundTrip() {
    var value = draft()
    value.end = date("2026-09-15T07:00:00Z")
    let originalEnd = value.end
    value.setAllDay(true)
    XCTAssertEqual(value.end, value.start)
    value.setAllDay(false)
    XCTAssertEqual(value.end, originalEnd)
  }

  func testValidationRejectsInvalidFieldsAndAcceptsValidURL() throws {
    var value = draft()
    try value.validate()
    value.title = " \n "
    XCTAssertThrowsError(try value.validate())
    value.title = "Meeting"
    value.end = value.start
    XCTAssertThrowsError(try value.validate())
    value.end = value.start.addingTimeInterval(3600)
    value.urlText = "not a url"
    XCTAssertThrowsError(try value.validate())
    value.urlText = "https://example.com/meeting"
    try value.validate()
    value.calendarID = ""
    XCTAssertThrowsError(try value.validate())
  }

  func testCustomRepeatValidationAndInclusiveEndDate() throws {
    var value = draft()
    value.recurrence.frequency = .weekly
    value.recurrence.weekdays = []
    XCTAssertThrowsError(try value.validate())
    value.recurrence.weekdays = [2, 4, 6]
    value.recurrence.interval = 0
    XCTAssertThrowsError(try value.validate())
    value.recurrence.interval = 2
    value.recurrence.end = .count
    value.recurrence.count = 0
    XCTAssertThrowsError(try value.validate())
    value.recurrence.count = 12
    try value.validate()
    let counted = try XCTUnwrap(EventKitDraftMapper.recurrence(value))
    XCTAssertEqual(counted.frequency, .weekly)
    XCTAssertEqual(counted.interval, 2)
    XCTAssertEqual(counted.daysOfTheWeek?.map { $0.dayOfTheWeek.rawValue }, [2, 4, 6])
    XCTAssertEqual(counted.recurrenceEnd?.occurrenceCount, 12)
    value.recurrence.end = .date
    value.recurrence.endDate = value.start.addingTimeInterval(-86400)
    XCTAssertThrowsError(try value.validate())
    value.recurrence.endDate = value.start
    try value.validate()
    XCTAssertEqual(EventKitDraftMapper.recurrence(value)?.recurrenceEnd?.endDate,
                   date("2026-09-15T06:59:59Z"))
  }

  func testRepeatFrequenciesUseNativeRuleAndNeverEnd() throws {
    var value = draft()
    XCTAssertNil(EventKitDraftMapper.recurrence(value))
    for (frequency, expected) in [(EventRepeatFrequency.daily, EKRecurrenceFrequency.daily),
      (.weekly, .weekly), (.monthly, .monthly), (.yearly, .yearly)] {
      value.recurrence.frequency = frequency
      let rule = try XCTUnwrap(EventKitDraftMapper.recurrence(value))
      XCTAssertEqual(rule.frequency, expected)
      XCTAssertNil(rule.recurrenceEnd)
    }
  }

  func testReminderMappingsAndAllDayMorningAcrossDST() throws {
    var value = draft("2026-03-08T16:00:00Z")
    XCTAssertNil(value.alarmOffset)
    for (choice, seconds) in [(EventAlertChoice.atStart, 0.0), (.fiveMinutes, -300), (.tenMinutes, -600),
      (.fifteenMinutes, -900), (.thirtyMinutes, -1800), (.oneHour, -3600), (.twoHours, -7200),
      (.oneDay, -86400), (.twoDays, -172800), (.oneWeek, -604800)] {
      value.alert = choice
      XCTAssertEqual(value.alarmOffset, seconds)
    }
    value.setAllDay(true)
    value.alert = .sameDayMorning
    XCTAssertEqual(value.savedStart.addingTimeInterval(value.alarmOffset!), date("2026-03-08T16:00:00Z"))
    value.alert = .previousMorning
    XCTAssertEqual(value.savedStart.addingTimeInterval(value.alarmOffset!), date("2026-03-07T17:00:00Z"))
    value.alert = .custom
    value.customAlertUnit = 3600
    value.customAlertAmount = 3
    XCTAssertEqual(value.alarmOffset, -10800)
    value.customAlertAmount = 0
    XCTAssertThrowsError(try value.validate())
  }

  func testEventKitMapperIncludesAllUserFieldsWithoutSaving() {
    var value = draft()
    value.title = "  Planning  "
    value.location = " Room A "
    value.notes = "Agenda\nDecisions"
    value.urlText = "https://example.com"
    value.alert = .fifteenMinutes
    value.recurrence.frequency = .monthly
    let event = EKEvent(eventStore: EKEventStore())
    EventKitDraftMapper.apply(value, to: event)
    XCTAssertEqual(event.title, "Planning")
    XCTAssertEqual(event.location, "Room A")
    XCTAssertEqual(event.notes, value.notes)
    XCTAssertEqual(event.url, URL(string: value.urlText))
    XCTAssertEqual(event.startDate, value.start)
    XCTAssertEqual(event.endDate, value.end)
    XCTAssertEqual(event.timeZone, value.timeZone)
    XCTAssertEqual(event.alarms?.first?.relativeOffset, -900)
    XCTAssertEqual(event.recurrenceRules?.first?.frequency, .monthly)
  }

}

@MainActor
final class EventCreationModelTests: XCTestCase {
  func testSuspensionRestoresTheSameDirtyDraftWithoutSavingOrCancelling() async {
    let provider = CreationTestProvider()
    let model = await open(provider)
    try? await Task.sleep(for: .milliseconds(150))
    model.draft?.title = "Retained draft"
    model.draft?.notes = "Still editing"
    let draft = model.draft
    let id = model.draftID
    for _ in 0..<3 {
      XCTAssertTrue(model.suspendPresentation())
      XCTAssertTrue(model.isActive)
      XCTAssertFalse(model.reserve())
      XCTAssertFalse(model.confirmsDiscard)
      model.resumePresentation()
      XCTAssertEqual(model.draft, draft)
      XCTAssertEqual(model.draftID, id)
      XCTAssertEqual(model.phase, .visible)
    }
    XCTAssertEqual(provider.saveCount, 0)
    model.requestCancel()
    XCTAssertTrue(model.confirmsDiscard, "Suspension must preserve the original dirty baseline")
    XCTAssertFalse(model.suspendPresentation(), "Do not hide an unanswered discard confirmation")
    model.dismiss()
    try? await Task.sleep(for: .milliseconds(150))
    XCTAssertNil(model.draft)
    XCTAssertFalse(model.isSuspended)
  }

  private func open(_ provider: CreationTestProvider, onSave: @escaping (ScheduleEvent) -> Void = { _ in }) async -> EventCreationModel {
    let model = EventCreationModel(provider: provider, onSaved: onSave)
    model.reduceMotion = true
    XCTAssertTrue(model.reserve())
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    await model.prepare(focusedDate: date, now: date, calendar: Calendar(identifier: .gregorian), sources: provider.sources)
    for _ in 0..<200 {
      if model.phase == .visible && !model.isLoadingCalendars { break }
      try? await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(model.phase, .visible)
    XCTAssertFalse(model.isLoadingCalendars)
    return model
  }

  func testDefaultCalendarAndFallbackPreferVisibleWritableSources() async {
    let provider = CreationTestProvider()
    provider.defaultID = "hidden"
    let preferred = await open(provider)
    XCTAssertEqual(preferred.draft?.calendarID, "hidden")
    XCTAssertFalse(preferred.calendars.contains { !$0.isWritable })
    provider.defaultID = "readonly"
    let fallback = await open(provider)
    XCTAssertEqual(fallback.draft?.calendarID, "work")
  }

  func testCancelProtectsDirtyDraftAndSecondOpenCannotReplaceIt() async {
    let model = await open(CreationTestProvider())
    model.draft?.title = "Unsaved"
    model.requestCancel()
    XCTAssertTrue(model.confirmsDiscard)
    XCTAssertTrue(model.isActive)
    XCTAssertFalse(model.reserve())
    XCTAssertEqual(model.draft?.title, "Unsaved")
    model.dismiss()
    try? await Task.sleep(for: .milliseconds(150))
    XCTAssertFalse(model.isActive)
    XCTAssertNil(model.draft)
  }

  func testSaveCoalescesDoubleClickAndRefreshesOnce() async {
    let provider = CreationTestProvider()
    provider.holdSave = true
    var saveCount = 0
    let model = await open(provider) { _ in saveCount += 1 }
    model.draft?.title = "Created"
    let first = Task { await model.save() }
    for _ in 0..<100 where provider.heldSave == nil { await Task.yield() }
    XCTAssertTrue(model.isSaving)
    await model.save()
    model.requestCancel()
    XCTAssertFalse(model.confirmsDiscard)
    XCTAssertEqual(provider.saveCount, 1)
    provider.heldSave?.resume()
    await first.value
    XCTAssertEqual(saveCount, 1)
    XCTAssertEqual(model.savedNotice, "事件已添加")
    try? await Task.sleep(for: .milliseconds(150))
    XCTAssertNil(model.draft)
  }

  func testSaveFailureRetainsDraftAndAllowsRetry() async {
    let provider = CreationTestProvider()
    let model = await open(provider)
    model.draft?.title = "Keep this"
    provider.saveError = .calendarUnavailable
    await model.save()
    XCTAssertEqual(model.draft?.title, "Keep this")
    XCTAssertNotNil(model.errorMessage)
    XCTAssertFalse(model.isSaving)
    provider.saveError = nil
    await model.save()
    XCTAssertEqual(provider.saveCount, 2)
    XCTAssertNil(model.errorMessage)
  }

  func testHiddenCalendarNoticeDoesNotChangeFilters() async {
    let provider = CreationTestProvider()
    provider.defaultID = "hidden"
    let model = await open(provider)
    model.draft?.title = "Hidden"
    await model.save()
    XCTAssertTrue(model.savedNotice?.contains("当前未显示") == true)
    XCTAssertFalse(provider.sources.first { $0.id == "hidden" }!.isEnabled)
  }

  func testPermissionRevocationAndRecoveryKeepDraft() async {
    let provider = CreationTestProvider()
    let model = await open(provider)
    model.draft?.title = "Keep"
    provider.authorization = .denied
    await model.save()
    XCTAssertFalse(model.canSave)
    XCTAssertEqual(model.draft?.title, "Keep")
    provider.authorization = .fullAccess
    await model.refreshAccess()
    XCTAssertTrue(model.canSave)
    XCTAssertEqual(model.draft?.title, "Keep")
  }

  func testNoWritableCalendarAndEmptyTitleCannotSave() async {
    let provider = CreationTestProvider()
    provider.sources = []
    let model = await open(provider)
    XCTAssertFalse(model.canSave)
    await model.save()
    XCTAssertEqual(provider.saveCount, 0)
    XCTAssertNotNil(model.errorMessage)
  }

  func testAppModelCreationRefreshesExistingViewportWithoutChangingMode() async {
    let provider = CreationTestProvider()
    let name = "Timepane.EventCreationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let onboarding = OnboardingStore(defaults: defaults)
    onboarding.markComplete()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let app = AppModel(provider: provider, selectionStore: CalendarSelectionStore(defaults: defaults),
      onboardingStore: onboarding, now: now, nowProvider: { now })
    app.start()
    for _ in 0..<100 where app.calendars.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
    let originalMode = app.displayMode
    let originalFocus = app.currentFocusedDate
    app.beginEventCreation()
    for _ in 0..<200 {
      if app.eventCreation.phase == .visible && !app.eventCreation.isLoadingCalendars { break }
      try? await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(app.eventCreation.phase, .visible)
    XCTAssertFalse(app.eventCreation.isLoadingCalendars)
    app.eventCreation.draft?.title = "Created in viewport"
    await app.eventCreation.save()
    for _ in 0..<100 where app.periodSchedule.events.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(app.periodSchedule.events.first?.title, "Created in viewport")
    XCTAssertEqual(app.displayMode, originalMode)
    XCTAssertEqual(app.currentFocusedDate, originalFocus)
  }

  func testClosingRetainsButtonAppearanceButRejectsAnotherSave() async {
    let provider = CreationTestProvider()
    let model = await open(provider)
    model.draft?.title = "Closing"
    model.dismiss()
    XCTAssertTrue(model.canSave)
    await model.save()
    XCTAssertEqual(provider.saveCount, 0)
  }
}

@MainActor
private final class CreationTestProvider: CalendarProviding {
  var onCalendarStoreChanged: (() -> Void)?
  var sources = [
    CalendarSource(id: "work", title: "Work", colorHex: "#007AFF", isEnabled: true, isWritable: true),
    CalendarSource(id: "hidden", title: "Hidden", colorHex: "#00FF00", isEnabled: false, isWritable: true),
    CalendarSource(id: "readonly", title: "Read only", colorHex: "#FF0000", isEnabled: true)
  ]
  var authorization = CalendarAuthorizationState.fullAccess
  var defaultID: String? = "work"
  var saveError: EventCreationError?
  var saveCount = 0
  var holdSave = false
  var heldSave: CheckedContinuation<Void, Never>?
  var storedEvents: [ScheduleEvent] = []
  func authorizationStatus() -> CalendarAuthorizationState { authorization }
  func requestFullAccess() async -> CalendarAuthorizationState { authorization }
  func availableCalendars() async -> [CalendarSource] { authorization.canReadEvents ? sources : [] }
  func events(in interval: DateInterval, calendarIDs: Set<String>) async -> [ScheduleEvent] {
    storedEvents.filter { calendarIDs.contains($0.calendarID) && $0.startDate < interval.end && $0.endDate > interval.start }
  }
  func defaultCalendarForNewEvents() async -> String? { defaultID }
  func createEvent(_ draft: EventDraft) async throws -> ScheduleEvent {
    saveCount += 1
    guard authorization.canReadEvents else { throw EventCreationError.accessDenied }
    if let saveError { throw saveError }
    if holdSave { await withCheckedContinuation { heldSave = $0 } }
    let event = ScheduleEvent(id: "created", title: draft.title, startDate: draft.savedStart,
      endDate: draft.savedEnd, isAllDay: draft.isAllDay, location: draft.location,
      notes: draft.notes, url: nil, calendarID: draft.calendarID,
      calendarTitle: sources.first { $0.id == draft.calendarID }!.title, colorHex: "#007AFF")
    storedEvents.append(event)
    onCalendarStoreChanged?()
    return event
  }
}
