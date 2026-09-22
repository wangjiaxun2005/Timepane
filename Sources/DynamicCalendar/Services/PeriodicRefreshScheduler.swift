import Foundation

protocol PeriodicRefreshScheduling: AnyObject {
  func start(
    interval: TimeInterval,
    leeway: TimeInterval,
    action: @escaping @MainActor () -> Void
  )
  func cancel()
}

final class DispatchSourcePeriodicRefreshScheduler: PeriodicRefreshScheduling {
  private var source: DispatchSourceTimer?

  deinit {
    source?.cancel()
  }

  func start(
    interval: TimeInterval,
    leeway: TimeInterval,
    action: @escaping @MainActor () -> Void
  ) {
    cancel()

    let source = DispatchSource.makeTimerSource(queue: .main)
    source.schedule(
      deadline: .now() + interval,
      repeating: interval,
      leeway: .milliseconds(max(0, Int((leeway * 1_000).rounded())))
    )
    source.setEventHandler {
      MainActor.assumeIsolated {
        action()
      }
    }
    self.source = source
    source.resume()
  }

  func cancel() {
    source?.cancel()
    source = nil
  }
}
