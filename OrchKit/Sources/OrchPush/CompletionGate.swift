import Foundation

/// Both extension lifecycle callbacks (didReceive and time-will-expire) consume
/// the same lock-protected completion, so the delivery handler runs exactly once.
/// The handler is invoked outside the lock to permit reentrancy.
public final class CompletionGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let makeValue: @Sendable () -> Value
    private var pending: ((Value) -> Void)?
    private var expired = false

    /// - Parameter makeValue: builds the value delivered to the handler, at delivery time.
    public init(makeValue: @escaping @Sendable () -> Value) {
        self.makeValue = makeValue
    }

    public func install(_ handler: @escaping (Value) -> Void) {
        lock.lock()
        pending = handler
        let shouldFinish = expired
        lock.unlock()
        if shouldFinish { finish() }
    }

    public func finish(expiring: Bool = false) {
        lock.lock()
        if expiring { expired = true }
        let handler = pending
        pending = nil
        lock.unlock()
        handler?(makeValue())
    }
}
