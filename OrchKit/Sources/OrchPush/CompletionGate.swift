import Foundation

/// Both extension lifecycle callbacks (didReceive and time-will-expire) consume
/// the same lock-protected completion, so the delivery handler runs exactly once.
/// The handler is invoked outside the lock to permit reentrancy.
///
/// Whoever takes the handler decides the terminal value: `makeValue(expiring)` is evaluated by that one caller, and
/// `expiring` is true when the time limit (not normal completion) consumed the completion, including when it fired
/// before the handler was installed. A later caller finds nothing to consume.
public final class CompletionGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let makeValue: @Sendable (_ expiring: Bool) -> Value
    private var pending: ((Value) -> Void)?
    private var expired = false

    /// - Parameter makeValue: builds the value delivered to the handler, at delivery time; `expiring` says the time limit won.
    public init(makeValue: @escaping @Sendable (_ expiring: Bool) -> Value) {
        self.makeValue = makeValue
    }

    public convenience init(makeValue: @escaping @Sendable () -> Value) {
        self.init(makeValue: { _ in makeValue() })
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
        let ex = expired
        pending = nil
        lock.unlock()
        handler?(makeValue(ex))
    }

    /// Claims the completion and delivers `value` (computed by the caller, possibly while it holds other locks). Returns
    /// false, delivering nothing, if the completion was already consumed or no handler is installed yet. Claiming is one
    /// short critical section, so it can never wait on I/O: the deadline path (`complete(with: generic)`) always works.
    @discardableResult
    public func complete(with value: Value) -> Bool {
        lock.lock()
        let handler = pending
        pending = nil
        lock.unlock()
        guard let handler else { return false }
        handler(value)
        return true
    }
}
