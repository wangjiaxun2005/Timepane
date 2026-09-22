import SwiftUI

enum EventDetailPresentationPhase: Equatable {
  case hidden
  case presenting
  case visible
  case switching
  case dismissing
}

enum EventDetailSwitchDirection: Equatable {
  case earlier
  case later

  var insertionEdge: Edge {
    self == .later ? .trailing : .leading
  }

  var removalEdge: Edge {
    self == .later ? .leading : .trailing
  }
}

enum EventDetailOrdering {
  static func direction(
    from current: ScheduleEvent,
    to destination: ScheduleEvent
  ) -> EventDetailSwitchDirection {
    if destination.startDate != current.startDate {
      return destination.startDate < current.startDate ? .earlier : .later
    }
    if destination.endDate != current.endDate {
      return destination.endDate < current.endDate ? .earlier : .later
    }
    return destination.id.localizedStandardCompare(current.id) == .orderedAscending
      ? .earlier
      : .later
  }
}

@MainActor
final class EventDetailPresentationModel: ObservableObject {
  @Published private(set) var phase: EventDetailPresentationPhase = .hidden
  @Published private(set) var event: ScheduleEvent?
  @Published private(set) var switchDirection: EventDetailSwitchDirection = .later
  @Published private(set) var isSurfacePresented = false
  @Published private(set) var drawerImpact: CGFloat = 0
  @Published private(set) var generation = 0
  private(set) var displayContent: EventDetailDisplayContent?

  private var completionWorkItem: DispatchWorkItem?
  private var impactBuildWorkItem: DispatchWorkItem?
  private var impactRecoveryWorkItem: DispatchWorkItem?

  deinit {
    completionWorkItem?.cancel()
    impactBuildWorkItem?.cancel()
    impactRecoveryWorkItem?.cancel()
  }

  func updateSelection(_ selection: ScheduleEvent?, reduceMotion: Bool) {
    guard let selection else {
      dismiss(reduceMotion: reduceMotion)
      return
    }

    guard let current = event, isSurfacePresented else {
      present(selection, reduceMotion: reduceMotion)
      return
    }

    guard current.id != selection.id else {
      var transaction = Transaction(animation: nil)
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        displayContent = EventDetailDisplayContent(event: selection)
        event = selection
      }
      return
    }

    completionWorkItem?.cancel()
    cancelImpactSequence()
    withAnimation(EventDetailMotionTiming.impactRecoveryAnimation) {
      drawerImpact = 0
    }
    switchDirection = EventDetailOrdering.direction(from: current, to: selection)
    let generation = beginTransition(to: .switching)
    withAnimation(EventDetailMotionTiming.switchAnimation(reduceMotion: reduceMotion)) {
      displayContent = EventDetailDisplayContent(event: selection)
      event = selection
    }
    scheduleCompletion(
      after: reduceMotion ? 0.1 : EventDetailMotionTiming.switchDuration,
      generation: generation
    )
  }

  @discardableResult
  func completeTransition(generation: Int) -> Bool {
    guard generation == self.generation else { return false }
    switch phase {
    case .presenting, .switching:
      phase = .visible
    case .dismissing:
      event = nil
      displayContent = nil
      phase = .hidden
    case .hidden, .visible:
      break
    }
    completionWorkItem = nil
    return true
  }

  func reset() {
    completionWorkItem?.cancel()
    completionWorkItem = nil
    cancelImpactSequence()
    generation &+= 1
    phase = .hidden
    event = nil
    displayContent = nil
    isSurfacePresented = false
    drawerImpact = 0
  }

  private func present(_ selection: ScheduleEvent, reduceMotion: Bool) {
    completionWorkItem?.cancel()
    cancelImpactSequence()
    let generation = beginTransition(to: .presenting)
    displayContent = EventDetailDisplayContent(event: selection)
    event = selection
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      drawerImpact = 0
    }
    withAnimation(EventDetailMotionTiming.presentationAnimation(reduceMotion: reduceMotion)) {
      isSurfacePresented = true
    }
    if !reduceMotion {
      scheduleImpactSequence(generation: generation)
    }
    scheduleCompletion(
      after: reduceMotion ? 0.1 : EventDetailMotionTiming.presentationDuration,
      generation: generation
    )
  }

  private func dismiss(reduceMotion: Bool) {
    guard event != nil, isSurfacePresented else { return }
    completionWorkItem?.cancel()
    cancelImpactSequence()
    let generation = beginTransition(to: .dismissing)
    withAnimation(EventDetailMotionTiming.dismissalAnimation(reduceMotion: reduceMotion)) {
      drawerImpact = 0
      isSurfacePresented = false
    }
    scheduleCompletion(
      after: reduceMotion ? 0.1 : EventDetailMotionTiming.dismissalDuration,
      generation: generation
    )
  }

  private func beginTransition(to phase: EventDetailPresentationPhase) -> Int {
    generation &+= 1
    self.phase = phase
    return generation
  }

  private func scheduleCompletion(after delay: TimeInterval, generation: Int) {
    let workItem = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        _ = self?.completeTransition(generation: generation)
      }
    }
    completionWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  private func scheduleImpactSequence(generation: Int) {
    let buildWorkItem = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self, generation == self.generation, self.isSurfacePresented else { return }
        withAnimation(EventDetailMotionTiming.impactBuildAnimation) {
          self.drawerImpact = 1
        }
      }
    }
    impactBuildWorkItem = buildWorkItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + EventDetailMotionTiming.impactLeadIn,
      execute: buildWorkItem
    )

    let recoveryWorkItem = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self, generation == self.generation, self.isSurfacePresented else { return }
        withAnimation(EventDetailMotionTiming.impactRecoveryAnimation) {
          self.drawerImpact = 0
        }
      }
    }
    impactRecoveryWorkItem = recoveryWorkItem
    DispatchQueue.main.asyncAfter(
      deadline: .now()
        + EventDetailMotionTiming.impactLeadIn
        + EventDetailMotionTiming.impactBuildDuration,
      execute: recoveryWorkItem
    )
  }

  private func cancelImpactSequence() {
    impactBuildWorkItem?.cancel()
    impactRecoveryWorkItem?.cancel()
    impactBuildWorkItem = nil
    impactRecoveryWorkItem = nil
  }
}
