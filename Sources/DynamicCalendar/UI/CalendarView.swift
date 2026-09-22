import AppKit
import QuartzCore
import SwiftUI

struct CalendarView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @EnvironmentObject private var motion: PanelMotionModel
  @ObservedObject var model: AppModel
  let surfaceNamespace: Namespace.ID
  let onCollapse: () -> Void
  let onTogglePin: () -> Void

  @StateObject private var modeSelectionAnimator = CalendarModeSelectionAnimator()

  var body: some View {
    CalendarInteractionHost(model: model, interaction: model.interaction,
      modeSelectionAnimator: modeSelectionAnimator, surfaceNamespace: surfaceNamespace,
      onCollapse: onCollapse, onTogglePin: onTogglePin,
      toolbarScale: toolbarScale, toolbarOffset: toolbarOffset,
      toolbarAnimation: toolbarAnimation, gridScale: gridScale,
      gridOffset: gridOffset, gridAnimation: gridAnimation)
      .onAppear {
        model.interaction.reduceMotion = reduceMotion
        model.interaction.onModeChange = { [weak interaction = model.interaction,
                                            weak animator = modeSelectionAnimator] source, target in
          if interaction?.reduceMotion == true { animator?.complete(mode: target) }
          else { animator?.play(from: source, to: target) }
        }
      }
      .onChange(of: reduceMotion) { _, value in model.interaction.reduceMotion = value }
      .onDisappear {
        model.interaction.onModeChange = nil
        model.interaction.reset()
      }
  }

  private var isContentVisible: Bool {
    motion.phase.keepsExpandedContentAlive
  }

  private var toolbarScale: CGFloat {
    reduceMotion || isContentVisible ? 1 : 0.985
  }

  private var gridScale: CGFloat {
    reduceMotion || isContentVisible ? 1 : 0.975
  }

  private var toolbarOffset: CGSize {
    reduceMotion || isContentVisible ? .zero : CGSize(width: 9, height: -7)
  }

  private var gridOffset: CGSize {
    reduceMotion || isContentVisible ? .zero : CGSize(width: 16, height: -11)
  }

  private var toolbarAnimation: Animation {
    if reduceMotion { return .easeOut(duration: 0.1) }
    switch motion.phase {
    case .expanding:
      return PanelMotionTiming.toolbarRevealAnimation
    case .collapsing:
      return PanelMotionTiming.contentCollapseAnimation
    default:
      return PanelMotionTiming.contentCollapseAnimation
    }
  }

  private var gridAnimation: Animation {
    if reduceMotion { return .easeOut(duration: 0.1) }
    switch motion.phase {
    case .expanding:
      return PanelMotionTiming.gridRevealAnimation
    case .collapsing:
      return PanelMotionTiming.contentCollapseAnimation
    default:
      return PanelMotionTiming.contentCollapseAnimation
    }
  }
}
