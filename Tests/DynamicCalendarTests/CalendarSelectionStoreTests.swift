import XCTest
@testable import DynamicCalendar

final class CalendarSelectionStoreTests: XCTestCase {
    func testPreferencesRoundTrip() throws {
        let suite = "CalendarSelectionStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CalendarSelectionStore(defaults: defaults)
        let preferences = CalendarFilterPreferences(
            selectedCalendarIDs: ["work", "personal"],
            knownCalendarIDs: ["work", "personal", "holidays"]
        )

        store.save(preferences)

        XCTAssertEqual(store.load(), preferences)
    }

    func testWelcomeIsShownOnlyUntilCompletion() throws {
        let suite = "OnboardingStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OnboardingStore(defaults: defaults)

        XCTAssertTrue(store.shouldPresentWelcome)
        store.markComplete()
        XCTAssertFalse(store.shouldPresentWelcome)
    }
}

