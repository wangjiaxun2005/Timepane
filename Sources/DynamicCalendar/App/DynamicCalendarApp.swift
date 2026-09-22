import AppKit
import SwiftUI

@main
struct DynamicCalendarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var panelCoordinator: PanelCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let model: AppModel
#if DEBUG
        let isDemo = CommandLine.arguments.contains("--demo")
            || ProcessInfo.processInfo.environment["DYNAMIC_CALENDAR_DEMO"] == "1"
        if isDemo {
            let defaults = UserDefaults(suiteName: "com.wangjiaxun.DynamicCalendar.demo") ?? .standard
            let onboardingStore = OnboardingStore(defaults: defaults)
            onboardingStore.markComplete()
            model = AppModel(
                provider: DemoCalendarProvider(),
                selectionStore: CalendarSelectionStore(defaults: defaults),
                onboardingStore: onboardingStore
            )
        } else {
            model = AppModel(provider: EventKitCalendarProvider())
        }
        if ProcessInfo.processInfo.environment["DYNAMIC_CALENDAR_QA_PIN"] == "1"
            || CommandLine.arguments.contains("--qa-pin") {
            model.isPinned = true
        }
        if ProcessInfo.processInfo.environment["DYNAMIC_CALENDAR_QA_MODE"] == "month"
            || CommandLine.arguments.contains("--qa-month") {
            model.setDisplayMode(.month)
        }
#else
        model = AppModel(provider: EventKitCalendarProvider())
#endif
        let coordinator = PanelCoordinator(model: model)
        self.model = model
        self.panelCoordinator = coordinator

        model.start()
        coordinator.start()
        #if DEBUG
        if CommandLine.arguments.contains("--qa-panel-motion") {
            coordinator.enableMotionPreview()
            return
        }
        #endif
        coordinator.showPanel(on: coordinator.screenUnderMouse() ?? NSScreen.main)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard let coordinator = panelCoordinator else { return false }
        coordinator.showPanel(on: coordinator.screenUnderMouse() ?? NSScreen.main)
        return true
    }
}
