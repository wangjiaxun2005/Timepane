import SwiftUI

struct PanelRootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: AppModel
    @ObservedObject var motion: PanelMotionModel
    let surfaceNamespace: Namespace.ID
    let onCollapse: () -> Void
    let onTogglePin: () -> Void
    let onQuit: () -> Void

    @StateObject private var detailPresentation = EventDetailPresentationModel()

    var body: some View {
        EventCreationHost(creation: model.eventCreation, openPrivacySettings: model.openCalendarPrivacySettings) {
            panelContent
        }
        .environment(\.locale, Locale(identifier: "zh-Hans"))
    }

    private var panelContent: some View {
        ZStack {
            if model.route == .welcome {
                WelcomeView(model: model, onCollapse: onCollapse)
            } else {
                // Keep the calendar and its prepared state alive behind settings.
                // Only presentation transforms change during this short route transition.
                calendarContent
                    .opacity(model.route == .calendar ? 1 : 0)
                    .offset(x: reduceMotion || model.route == .calendar ? 0 : -18)
                    .allowsHitTesting(model.route == .calendar)
                    .accessibilityHidden(model.route != .calendar)

                if model.route == .settings {
                    SettingsView(model: model, onQuit: onQuit)
                        .transition(reduceMotion ? .opacity : .offset(x: 24).combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.1 : 0.18), value: model.route)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .environmentObject(motion)
        .offset(genericContentOffset)
        .animation(genericContentAnimation, value: motion.phase)
        .onAppear {
            detailPresentation.updateSelection(model.selectedEvent, reduceMotion: reduceMotion)
        }
        .onChange(of: model.selectedEvent) { _, selection in
            detailPresentation.updateSelection(selection, reduceMotion: reduceMotion)
        }
        .onChange(of: model.route) { _, route in
            if route != .calendar {
                detailPresentation.updateSelection(nil, reduceMotion: reduceMotion)
            }
        }
    }

    private var calendarContent: some View {
        ZStack(alignment: .bottom) {
            CalendarView(
                model: model,
                surfaceNamespace: surfaceNamespace,
                onCollapse: onCollapse,
                onTogglePin: onTogglePin
            )
            .scaleEffect(detailBackgroundScale, anchor: .top)
            .offset(y: detailBackgroundOffset)
            .animation(
                EventDetailMotionTiming.backgroundAnimation(reduceMotion: reduceMotion),
                value: detailPresentation.isSurfacePresented
            )

            if detailPresentation.isSurfacePresented {
                Color.black.opacity(0.075)
                    .allowsHitTesting(false)
                    .transition(.opacity)

                EventDetailDrawer(
                    presentation: detailPresentation
                )
                .transition(
                    EventDetailMotionTiming.drawerTransition(reduceMotion: reduceMotion)
                )
            }
        }
    }

    private var detailBackgroundScale: CGFloat {
        reduceMotion || !detailPresentation.isSurfacePresented ? 1 : 0.994
    }

    private var detailBackgroundOffset: CGFloat {
        reduceMotion || !detailPresentation.isSurfacePresented ? 0 : -3
    }

    private var genericContentOffset: CGSize {
        guard !reduceMotion else { return .zero }
        return motion.phase.keepsExpandedContentAlive
            ? .zero
            : CGSize(width: 10, height: -8)
    }

    private var genericContentAnimation: Animation {
        if reduceMotion { return .easeOut(duration: 0.1) }
        switch motion.phase {
        case .expanding:
            return PanelMotionTiming.genericContentRevealAnimation
        case .collapsing:
            return PanelMotionTiming.contentCollapseAnimation
        default:
            return PanelMotionTiming.contentCollapseAnimation
        }
    }

}
