import XCTest

@testable import DynamicCalendar

final class WeekNavigationTests: XCTestCase {
  func testDirectionFollowsTargetWeekStart() {
    let current = Date(timeIntervalSinceReferenceDate: 10_000)

    XCTAssertEqual(
      CalendarNavigationDirection(from: current, to: current.addingTimeInterval(7 * 86_400)),
      .forward
    )
    XCTAssertEqual(
      CalendarNavigationDirection(from: current, to: current.addingTimeInterval(-7 * 86_400)),
      .backward
    )
    XCTAssertEqual(CalendarNavigationDirection(from: current, to: current), .stationary)
  }

  func testScrollSwipeAccumulatesOncePerGesture() {
    var tracker = CalendarSwipeTracker(activationThreshold: 50)

    XCTAssertNil(
      tracker.consumeScroll(horizontal: 24, vertical: 2, timestamp: 1, began: true)
    )
    XCTAssertEqual(
      tracker.consumeScroll(horizontal: 28, vertical: 1, timestamp: 1.02, began: false),
      1
    )
    XCTAssertNil(
      tracker.consumeScroll(horizontal: 80, vertical: 0, timestamp: 1.04, began: false)
    )
  }

  func testPhasedSwipeDoesNotRetriggerAfterDeliveryPause() {
    var tracker = CalendarSwipeTracker()
    XCTAssertEqual(tracker.consumeScroll(horizontal: 60, vertical: 0,
      timestamp: 1, began: true, hasPhase: true), 1)
    for timestamp in [1.3, 1.7, 2.1] {
      XCTAssertNil(tracker.consumeScroll(horizontal: 100, vertical: 0,
        timestamp: timestamp, began: false, hasPhase: true))
    }
    XCTAssertEqual(tracker.consumeScroll(horizontal: -60, vertical: 0,
      timestamp: 2.12, began: true, hasPhase: true), -1)
  }

  func testMomentumCannotNavigateEvenAfterResetOrLongGap() {
    var tracker = CalendarSwipeTracker()
    XCTAssertEqual(tracker.consumeScroll(horizontal: 60, vertical: 0,
      timestamp: 1, began: true, hasPhase: true), 1)
    for timestamp in [1.4, 1.8, 2.2] {
      XCTAssertNil(tracker.consumeScroll(horizontal: 100, vertical: 0,
        timestamp: timestamp, began: false, isMomentum: true))
    }
    XCTAssertNil(tracker.consumeDiscreteSwipe(horizontal: 1, timestamp: 2.21))
    tracker.reset()
    XCTAssertNil(tracker.consumeScroll(horizontal: 100, vertical: 0,
      timestamp: 3, began: false, isMomentum: true))
  }

  func testPhaseLessWheelStartsAnotherGestureAfterIdle() {
    var tracker = CalendarSwipeTracker()
    XCTAssertEqual(tracker.consumeScroll(horizontal: 60, vertical: 0,
      timestamp: 1, began: false), 1)
    XCTAssertNil(tracker.consumeScroll(horizontal: 60, vertical: 0,
      timestamp: 1.05, began: false))
    XCTAssertEqual(tracker.consumeScroll(horizontal: 60, vertical: 0,
      timestamp: 1.5, began: false), 1)
  }

  func testNewGestureCanMoveBackwardAndVerticalScrollIsIgnored() {
    var tracker = CalendarSwipeTracker(activationThreshold: 40)

    XCTAssertNil(
      tracker.consumeScroll(horizontal: 12, vertical: 40, timestamp: 1, began: true)
    )
    XCTAssertEqual(
      tracker.consumeScroll(horizontal: -45, vertical: 2, timestamp: 2, began: true),
      -1
    )
  }

  func testHorizontalGestureClassificationRejectsVerticalMomentum() {
    XCTAssertTrue(CalendarSwipeTracker.isHorizontalGesture(horizontal: 8, vertical: 2))
    XCTAssertFalse(CalendarSwipeTracker.isHorizontalGesture(horizontal: 2, vertical: 8))
    XCTAssertFalse(CalendarSwipeTracker.isHorizontalGesture(horizontal: 0.2, vertical: 0))
  }

  func testScrollWheelDeltaIsConvertedToFingerDirection() {
    XCTAssertEqual(CalendarSwipeTracker.fingerDelta(fromScrollingDelta: 12), -12)
    XCTAssertEqual(CalendarSwipeTracker.fingerDelta(fromScrollingDelta: -12), 12)
  }

  func testDiscreteSwipeHasCooldown() {
    var tracker = CalendarSwipeTracker(discreteCooldown: 0.35)

    XCTAssertEqual(tracker.consumeDiscreteSwipe(horizontal: 1, timestamp: 1), 1)
    XCTAssertNil(tracker.consumeDiscreteSwipe(horizontal: 1, timestamp: 1.1))
    XCTAssertEqual(tracker.consumeDiscreteSwipe(horizontal: -1, timestamp: 1.4), -1)
  }

  func testEventTravelHasStrongerMidCurveAndElasticTail() {
    XCTAssertLessThan(CalendarPeriodMotionCurve.eventTravel(0.2), 0.2)
    XCTAssertGreaterThan(CalendarPeriodMotionCurve.eventTravel(0.8), 0.8)
    XCTAssertEqual(CalendarPeriodMotionCurve.eventTravel(0), 0, accuracy: 0.001)
    XCTAssertEqual(CalendarPeriodMotionCurve.eventTravel(1), 1, accuracy: 0.001)
    XCTAssertGreaterThan(CalendarPeriodMotionCurve.eventTravel(1.04), 1.04)
  }

  func testEventTravelVelocityIsContinuousAcrossElasticBoundaries() {
    let epsilon: CGFloat = 0.000001
    for boundary: CGFloat in [-0.02, 0, 1, 1.02] {
      let position = CalendarPeriodMotionCurve.eventTravel(boundary)
      let incoming = (position - CalendarPeriodMotionCurve.eventTravel(boundary - epsilon)) / epsilon
      let outgoing = (CalendarPeriodMotionCurve.eventTravel(boundary + epsilon) - position) / epsilon
      XCTAssertEqual(incoming, outgoing, accuracy: 0.0001, "Boundary \(boundary)")
      XCTAssertGreaterThan(incoming, 0)
    }
  }
}
