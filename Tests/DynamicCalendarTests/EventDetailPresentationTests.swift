import XCTest
@testable import DynamicCalendar

@MainActor
final class EventDetailPresentationTests: XCTestCase {
  func testDescriptionLinkifierMakesWebURLsClickable() {
    let url = URL(string: "https://example.com/meeting?id=42")!
    let attributed = EventDescriptionLinkifier.attributedString(
      for: "课程资料：\(url.absoluteString)"
    )

    XCTAssertEqual(attributed.runs.compactMap { $0.link }, [url])
  }

  func testDescriptionLinkifierLeavesPlainTextUnlinked() {
    let attributed = EventDescriptionLinkifier.attributedString(for: "课程资料稍后发布")

    XCTAssertTrue(attributed.runs.compactMap { $0.link }.isEmpty)
  }

  func testReopeningDuringDismissalRejectsOldHideCompletion() {
    let model = EventDetailPresentationModel()
    let first = event(id: "first", start: 100, end: 150)
    let second = event(id: "second", start: 200, end: 250)
    model.updateSelection(first, reduceMotion: false)
    _ = model.completeTransition(generation: model.generation)
    model.updateSelection(nil, reduceMotion: false)
    let dismissal = model.generation

    model.updateSelection(second, reduceMotion: false)
    XCTAssertTrue(model.isSurfacePresented)
    XCTAssertEqual(model.event, second)
    XCTAssertFalse(model.completeTransition(generation: dismissal))
    XCTAssertEqual(model.event, second)
    XCTAssertTrue(model.completeTransition(generation: model.generation))
    XCTAssertEqual(model.phase, .visible)
  }

  func testOrderingUsesStartEndAndStableID() {
    let current = event(id: "b", start: 100, end: 200)

    XCTAssertEqual(
      EventDetailOrdering.direction(from: current, to: event(id: "c", start: 101, end: 150)),
      .later
    )
    XCTAssertEqual(
      EventDetailOrdering.direction(from: current, to: event(id: "a", start: 99, end: 250)),
      .earlier
    )
    XCTAssertEqual(
      EventDetailOrdering.direction(from: current, to: event(id: "c", start: 100, end: 201)),
      .later
    )
    XCTAssertEqual(
      EventDetailOrdering.direction(from: current, to: event(id: "a", start: 100, end: 200)),
      .earlier
    )
    XCTAssertEqual(EventDetailSwitchDirection.later.insertionEdge, .trailing)
    XCTAssertEqual(EventDetailSwitchDirection.later.removalEdge, .leading)
    XCTAssertEqual(EventDetailSwitchDirection.earlier.insertionEdge, .leading)
    XCTAssertEqual(EventDetailSwitchDirection.earlier.removalEdge, .trailing)
  }

  func testSwitchKeepsSurfacePresentedAndUsesChronologicalDirection() {
    let model = EventDetailPresentationModel()
    let early = event(id: "early", start: 100, end: 150)
    let late = event(id: "late", start: 200, end: 250)

    model.updateSelection(early, reduceMotion: true)
    XCTAssertTrue(model.isSurfacePresented)
    XCTAssertEqual(model.phase, .presenting)
    XCTAssertEqual(model.event, early)
    let presentationGeneration = model.generation
    XCTAssertTrue(model.completeTransition(generation: presentationGeneration))

    model.updateSelection(late, reduceMotion: true)
    XCTAssertTrue(model.isSurfacePresented)
    XCTAssertEqual(model.phase, .switching)
    XCTAssertEqual(model.switchDirection, .later)
    XCTAssertEqual(model.event, late)
    let laterGeneration = model.generation

    model.updateSelection(early, reduceMotion: true)
    XCTAssertEqual(model.switchDirection, .earlier)
    XCTAssertEqual(model.event, early)
    XCTAssertFalse(model.completeTransition(generation: laterGeneration))
    XCTAssertTrue(model.completeTransition(generation: model.generation))
    XCTAssertEqual(model.phase, .visible)
  }

  func testSameOccurrenceRefreshesContentWithoutStartingTransition() {
    let model = EventDetailPresentationModel()
    let original = event(id: "same", title: "旧标题", start: 100, end: 150)
    let refreshed = event(id: "same", title: "新标题", start: 100, end: 150)

    model.updateSelection(original, reduceMotion: true)
    _ = model.completeTransition(generation: model.generation)
    let generation = model.generation

    model.updateSelection(refreshed, reduceMotion: true)

    XCTAssertEqual(model.event, refreshed)
    XCTAssertEqual(model.phase, .visible)
    XCTAssertEqual(model.generation, generation)
  }

  func testDismissRetainsEventUntilDownwardExitCompletes() {
    let model = EventDetailPresentationModel()
    let selected = event(id: "selected", start: 100, end: 150)

    model.updateSelection(selected, reduceMotion: true)
    _ = model.completeTransition(generation: model.generation)
    model.updateSelection(nil, reduceMotion: true)

    XCTAssertFalse(model.isSurfacePresented)
    XCTAssertEqual(model.phase, .dismissing)
    XCTAssertEqual(model.event, selected)
    XCTAssertTrue(model.completeTransition(generation: model.generation))
    XCTAssertEqual(model.phase, .hidden)
    XCTAssertNil(model.event)
  }

  private func event(
    id: String,
    title: String? = nil,
    start: TimeInterval,
    end: TimeInterval
  ) -> ScheduleEvent {
    ScheduleEvent(
      id: id,
      title: title ?? id,
      startDate: Date(timeIntervalSinceReferenceDate: start),
      endDate: Date(timeIntervalSinceReferenceDate: end),
      isAllDay: false,
      location: nil,
      notes: nil,
      url: nil,
      calendarID: "work",
      calendarTitle: "工作",
      colorHex: "#3366FF"
    )
  }
}
