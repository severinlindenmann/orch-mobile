import Foundation

/// The extension's delivery state machine, minus UserNotifications, so its interleavings are testable.
///
/// - Processing runs OFF the callback thread.
/// - The completion handler is claimed only at the moment content is delivered, never before blocking work: the
///   normal path calls it from INSIDE `PushHandler.handoff` (holding the removal and replay locks, bounded waits), and the
///   time limit claims it with no lock and no I/O. Whichever claims first wins; the other finds nothing to do, so the
///   deadline can always deliver generic text and a late presentation is rejected.
public final class PushDelivery: @unchecked Sendable {
    private let handler: PushHandler
    private let queue: DispatchQueue
    private let handoffTimeout: TimeInterval
    /// "Remove the delivered notification with this entity key, then call the continuation." Asynchronous in the extension.
    private let removeDelivered: @Sendable (_ key: String, _ done: @escaping @Sendable () -> Void) -> Void
    private let lock = NSLock()
    private var expiredWon = false
    private let gate = CompletionGate<PushPresentation> { _ in .generic }

    public init(handler: PushHandler, queue: DispatchQueue = DispatchQueue(label: "orch.push.nse", qos: .userInitiated), handoffTimeout: TimeInterval = 3,
                removeDelivered: @escaping @Sendable (String, @escaping @Sendable () -> Void) -> Void) {
        self.handler = handler; self.queue = queue; self.handoffTimeout = handoffTimeout; self.removeDelivered = removeDelivered
    }

    /// `complete` is called exactly once with what to show.
    public func start(o: String?, complete: @escaping (PushPresentation) -> Void) {
        gate.install(complete)
        queue.async { [self] in
            let r = handler.handle(o: o)
            if let key = r.presentation.removesDelivered { removeDelivered(key) { [self] in hand(r) } } else { hand(r) }
        }
    }

    private func hand(_ r: PushHandler.Result) {
        handler.handoff(r, timeout: handoffTimeout) { [gate] in gate.complete(with: $0) }
    }

    /// Time limit: claim the completion with generic text at once (no locks, no I/O), then record the marker
    /// best-effort, only if the time limit won.
    public func expire() {
        if gate.complete(with: .generic) { handler.recordExpired() }
    }
}
