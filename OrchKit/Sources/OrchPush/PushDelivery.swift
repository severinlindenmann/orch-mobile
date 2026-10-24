import Foundation

/// The extension's delivery state machine, minus UserNotifications, so its interleavings are testable.
///
/// - Processing runs OFF the callback thread.
/// - The completion is claimed exactly once: by the processed result, or by the time limit with generic text and no I/O. Whichever claims first
///   wins; the other finds nothing to do, so the deadline can always deliver generic text and a late presentation is rejected.
public final class PushDelivery: @unchecked Sendable {
    private let handler: PushHandler
    private let queue: DispatchQueue
    private let gate = CompletionGate<PushPresentation> { _ in .generic }

    public init(handler: PushHandler, queue: DispatchQueue = DispatchQueue(label: "orch.push.nse", qos: .userInitiated)) {
        self.handler = handler; self.queue = queue
    }

    /// `complete` is called exactly once with what to show.
    public func start(o: String?, complete: @escaping (PushPresentation) -> Void) {
        gate.install(complete)
        queue.async { [self] in
            let r = handler.handle(o: o)
            gate.complete(with: r.presentation)
        }
    }

    /// Time limit: claim the completion with generic text at once (no locks, no I/O), then record the marker
    /// best-effort, only if the time limit won.
    public func expire() {
        if gate.complete(with: .generic) { handler.recordExpired() }
    }
}
