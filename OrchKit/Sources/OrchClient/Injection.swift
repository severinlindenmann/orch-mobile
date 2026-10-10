import Foundation
import OrchProtocol

// Injected time, entropy and faults (host-api section 5, decision A5). Nothing in the client stack reads the system
// clock or the system RNG directly; actors take these.

/// Wall-clock milliseconds, for the protocol's section 15 rules. Scheduling uses `any Clock<Duration>` via `sleep(for:)`.
public protocol WallClock: Sendable {
    var nowMs: Int64 { get }
}

public struct SystemWallClock: WallClock {
    public init() {}
    public var nowMs: Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }
}

/// Where random bytes for ids, challenges and tokens come from. Production uses `SystemEntropy`; a deterministic source
/// exists only in test targets. Key generation uses CryptoKit directly and is never replaced.
public protocol Entropy: Sendable {
    func bytes(_ count: Int) -> Data
}

public extension Entropy {
    func id16() -> ID16 { ID16(bytes: bytes(16))! }
}

public struct SystemEntropy: Entropy {
    public init() {}
    public func bytes(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
    }
}

/// Named boundaries at which a fake may fail (host-api section 5).
public enum FaultBoundary: Hashable, Sendable {
    case beforeQueue
    case afterCommitBeforeResponse
    case beforeGrantPublication
    /// Chunks leaving a poll: reorder, duplicate, drop or corrupt them.
    case pollDelivery
}

public enum FaultAction: Equatable, Sendable {
    case none
    /// Wait on the injected clock before continuing.
    case delay(Duration)
    /// The request or reply is lost: the client sees a disconnect.
    case drop
    /// The operation happens twice (or a chunk appears twice).
    case duplicate
    case disconnect
    case reorder
    /// Flip one ciphertext byte. Verifiers must still reject it.
    case corrupt
}

public protocol FaultPolicy: Sendable {
    func action(at boundary: FaultBoundary, route: String) -> FaultAction
}

public struct NoFaults: FaultPolicy {
    public init() {}
    public func action(at boundary: FaultBoundary, route: String) -> FaultAction { .none }
}

/// A script of faults, each consumed once, in order per boundary. For tests and curated Demo scenarios.
public final class ScriptedFaults: FaultPolicy, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [(boundary: FaultBoundary, routePrefix: String?, action: FaultAction)] = []
    public init() {}

    @discardableResult
    public func enqueue(_ action: FaultAction, at boundary: FaultBoundary, routePrefix: String? = nil, times: Int = 1) -> Self {
        lock.lock(); defer { lock.unlock() }
        for _ in 0..<max(times, 0) { script.append((boundary, routePrefix, action)) }
        return self
    }

    public var remaining: Int { lock.lock(); defer { lock.unlock() }; return script.count }

    public func action(at boundary: FaultBoundary, route: String) -> FaultAction {
        lock.lock(); defer { lock.unlock() }
        guard let i = script.firstIndex(where: { $0.boundary == boundary && ($0.routePrefix.map(route.hasPrefix) ?? true) }) else {
            return .none
        }
        return script.remove(at: i).action
    }
}

/// A deterministic clock for scheduling and wall time (in-house, decision A14). `advance(by:)` moves both and wakes
/// sleepers whose deadline has passed. It never sleeps for real.
public final class TestClock: Clock, WallClock, @unchecked Sendable {
    public typealias Duration = Swift.Duration

    public struct Instant: InstantProtocol, Sendable {
        public var offset: Swift.Duration
        public init(offset: Swift.Duration = .zero) { self.offset = offset }
        public func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        public func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        public static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private struct Waiter { let deadline: Instant; let continuation: CheckedContinuation<Void, Error> }
    private let lock = NSLock()
    private var current = Instant()
    private var waiters: [UInt64: Waiter] = [:]
    private var nextID: UInt64 = 0
    private let startWallMs: Int64

    public init(wallStartMs: Int64 = 1_790_000_000_000) { startWallMs = wallStartMs }

    public var now: Instant { lock.lock(); defer { lock.unlock() }; return current }
    public var minimumResolution: Swift.Duration { .zero }

    public var nowMs: Int64 {
        let c = now.offset.components
        return startWallMs + c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000
    }

    /// Sleep ids are allocated before the continuation exists, so a cancellation can arrive first. One state machine under
    /// one lock keeps every interleaving: `cancelled` remembers a cancel that beat the registration.
    private var cancelled: Set<UInt64> = []

    package func beginSleep() -> UInt64 { lock.withLock { let id = nextID; nextID += 1; return id } }

    /// Resumes the continuation exactly once: cancelled (even before it was registered), already due, or parked.
    private func register(_ id: UInt64, _ deadline: Instant, _ c: CheckedContinuation<Void, Error>) {
        enum Outcome { case cancelled, due, parked }
        let outcome: Outcome = lock.withLock {
            if cancelled.remove(id) != nil { return .cancelled }
            if deadline <= current { return .due }
            waiters[id] = Waiter(deadline: deadline, continuation: c)
            return .parked
        }
        switch outcome {
        case .cancelled: c.resume(throwing: CancellationError())
        case .due: c.resume()
        case .parked: break
        }
    }

    package func cancelSleep(_ id: UInt64) {
        let w: Waiter? = lock.withLock {
            if let w = waiters.removeValue(forKey: id) { return w }
            cancelled.insert(id)            // not parked yet: the registration will see this
            return nil
        }
        w?.continuation.resume(throwing: CancellationError())
    }

    package func awaitSleep(_ id: UInt64, until deadline: Instant) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in register(id, deadline, c) }
    }

    public func sleep(until deadline: Instant, tolerance: Swift.Duration? = nil) async throws {
        let id = beginSleep()
        defer { _ = lock.withLock { cancelled.remove(id) } }       // a cancel that lost the race to completion leaves nothing behind
        try await withTaskCancellationHandler {
            try await awaitSleep(id, until: deadline)
        } onCancel: { cancelSleep(id) }
    }

    /// Moves time forward and wakes every sleeper whose deadline is now reached, earliest first.
    public func advance(by d: Swift.Duration) {
        let due: [(key: UInt64, value: Waiter)] = lock.withLock {
            current = current.advanced(by: d)
            let due = waiters.filter { $0.value.deadline <= current }.sorted { $0.value.deadline < $1.value.deadline }
            for (id, _) in due { waiters[id] = nil }
            return due
        }
        for (_, w) in due { w.continuation.resume() }
    }

    public func advance(milliseconds ms: Int64) { advance(by: .milliseconds(ms)) }

    /// Number of tasks currently asleep on this clock (for tests that wait until a sleeper is registered).
    public var sleeperCount: Int { lock.lock(); defer { lock.unlock() }; return waiters.count }
}
