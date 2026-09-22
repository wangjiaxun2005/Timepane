import Foundation

struct CalendarFilterPreferences: Codable, Equatable {
    var selectedCalendarIDs: Set<String>
    var knownCalendarIDs: Set<String>
}

final class CalendarSelectionStore {
    private let defaults: UserDefaults
    private let key = "calendarFilterPreferences.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> CalendarFilterPreferences? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CalendarFilterPreferences.self, from: data)
    }

    func save(_ preferences: CalendarFilterPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}

final class OnboardingStore {
    private let defaults: UserDefaults
    private let key = "didCompleteWelcome.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var shouldPresentWelcome: Bool {
        !defaults.bool(forKey: key)
    }

    func markComplete() {
        defaults.set(true, forKey: key)
    }
}

