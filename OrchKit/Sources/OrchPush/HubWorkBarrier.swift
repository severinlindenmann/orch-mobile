import Foundation

// THE WIPE BARRIER (design B6, L2-B6d-1). One rule for every component that touches hub-scoped state:
//
//   Take a `HubWorkToken` BEFORE a unit of work starts (`HubWipe.workToken()`). Every WRITE of hub-scoped state (a `hub.*` vault item, the cache,
//   `state/hub/`) goes through `token.perform { ... }` (the custody write methods and `HubPushIntake.accept` require the token as a parameter, so
//   the compiler enforces it). `perform` runs the write under the barrier's lock and refuses it once a wipe has begun. After any `await`, check
//   `token.isValid` before going on. Never test "is a wipe pending?" yourself.
//
// Why this closes the race class: `HubWipe.begin` closes the barrier under the SAME lock. A write therefore either finished before the wipe began
// (and the wipe, which deletes only after it began, removes it) or is refused. No component needs its own "was I wiped meanwhile" check, and a
// component that forgets one cannot write. A token taken while a wipe is pending, or before one began, is never valid again; the barrier opens for
// NEW tokens only when the wipe has finished.
//
// Reads and deletes are not writes and do not need a token. `HubWorkToken.unguarded` exists for tests and for the notification extension, which has
// no session and cannot open anything once the wipe deleted the push material; a guard test (HubWorkBarrierGuardTests) fails on any other use.

public final class HubWorkBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch = 0
    private var closed = false

    public init(closed: Bool = false) { self.closed = closed }

    /// A wipe begins: every token taken so far is dead, and none is handed out until `open`.
    public func close() { lock.withLock { epoch += 1; closed = true } }

    /// The wipe finished. Tokens taken from now on are valid; older ones stay dead.
    public func open() { lock.withLock { closed = false } }

    public var isClosed: Bool { lock.withLock { closed } }

    public func token() -> HubWorkToken { lock.withLock { HubWorkToken(barrier: self, epoch: closed ? -1 : epoch) } }

    func valid(_ epoch: Int) -> Bool { lock.withLock { !closed && epoch == self.epoch } }

    func perform<T>(_ epoch: Int, _ body: () throws -> T) throws -> T {
        try lock.withLock {
            guard !closed, epoch == self.epoch else { throw HubWorkError.wipeInProgress }
            return try body()
        }
    }
}

public enum HubWorkError: Error, Equatable, Sendable {
    /// A hub wipe began (or is pending) since this unit of work started: nothing may be written.
    case wipeInProgress
}

public struct HubWorkToken: Sendable {
    let barrier: HubWorkBarrier?
    let epoch: Int

    /// No barrier: tests, and the notification extension (see the note at the top of this file).
    public static let unguarded = HubWorkToken(barrier: nil, epoch: 0)

    /// True while no wipe has begun since the token was taken. Check after every `await`.
    public var isValid: Bool { barrier?.valid(epoch) ?? true }

    /// Runs a synchronous write under the barrier's lock, or throws `HubWorkError.wipeInProgress`. The body must not await or take the barrier again.
    public func perform<T>(_ body: () throws -> T) throws -> T {
        guard let barrier else { return try body() }
        return try barrier.perform(epoch, body)
    }

    public func check() throws { if !isValid { throw HubWorkError.wipeInProgress } }
}
