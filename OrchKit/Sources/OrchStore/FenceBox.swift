import Foundation
import OrchProtocol

/// A store's realm fence, behind a lock that every write reads at the moment it runs, so binding a fence is never raced by an open
/// or a write in flight (the database reads the box, it does not copy the fence). Bound at most once to one fence.
public final class FenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fence: (any WriteFence)?
    public init(_ fence: (any WriteFence)? = nil) { self.fence = fence }
    public var current: (any WriteFence)? { lock.withLock { fence } }
    /// Binds `f`; binding the same fence again is a no-op, a different one is refused.
    public func bind(_ f: any WriteFence) throws {
        try lock.withLock {
            if let fence, fence !== f { throw StoreError.fenceMismatch }
            fence = f
        }
    }
    /// Runs the synchronous `body` inside the bound fence (check and body one step against invalidation), or plainly when unbound.
    public func perform<T>(_ body: () throws -> T) throws -> T {
        guard let f = current else { return try body() }
        return try f.performFenced(body)
    }
}
