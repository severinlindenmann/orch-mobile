import Foundation

/// The extension's delivery state machine, minus UserNotifications, so its interleavings are testable:
/// processing runs OFF the callback thread; completion is consumed exactly once by whichever of (processing done,
/// time limit) gets there first; the expiry path completes at once with generic text and does no blocking I/O; the
/// normal path re-checks removal and supersession (`PushHandler.finalize`) immediately before the handler is called.
public final class PushDelivery: @unchecked Sendable {
    private let handler: PushHandler
    private let queue: DispatchQueue
    /// "Remove the delivered notification with this entity key, then call the continuation." Asynchronous in the extension.
    private let removeDelivered: @Sendable (_ key: String, _ done: @escaping @Sendable () -> Void) -> Void
    private let lock = NSLock()
    private var result: PushHandler.Result?
    private var consumed = false
    private var expiredWon = false
    private lazy var gate = CompletionGate<PushPresentation> { [weak self] expiring in
        guard let self else { return .generic }
        self.lock.lock(); self.consumed = true; if expiring { self.expiredWon = true }; let r = self.result; self.lock.unlock()
        if expiring { return .generic }          // no I/O on the deadline path
        guard let r else { return .generic }
        return self.handler.finalize(r)           // lock check right before the content handler is called
    }

    public init(handler: PushHandler, queue: DispatchQueue = DispatchQueue(label: "orch.push.nse", qos: .userInitiated),
                removeDelivered: @escaping @Sendable (String, @escaping @Sendable () -> Void) -> Void) {
        self.handler = handler; self.queue = queue; self.removeDelivered = removeDelivered
    }

    /// `complete` is called exactly once with what to show.
    public func start(o: String?, complete: @escaping (PushPresentation) -> Void) {
        gate.install(complete)
        queue.async { [self] in
            let r = handler.handle(o: o)
            lock.lock()
            let accepted = !consumed          // a presentation that arrives after completion is rejected
            if accepted { result = r }
            lock.unlock()
            guard accepted else { return }
            if let key = r.presentation.removesDelivered { removeDelivered(key) { [gate] in gate.finish() } } else { gate.finish() }
        }
    }

    /// Time limit: complete immediately with generic text, then record the marker best-effort (never waits).
    public func expire() {
        gate.finish(expiring: true)
        lock.lock(); let won = expiredWon; lock.unlock()
        if won { handler.recordExpired() }   // only when the time limit, not a normal completion, consumed the completion
    }
}
