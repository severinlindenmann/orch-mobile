import Foundation
import OrchCustody
import OrchPush

// The wipe of the phone's hub pairing (design B6). One resumable operation for three triggers: Leave, a revoke the hub itself confirmed, and
// Reset this iPhone. The intent is written to a journal BEFORE anything is deleted, every phase is idempotent, and the phase is persisted
// after it ran, so a kill at any point is finished at the next launch (`resume`). Nothing of the hub survives a finished wipe, and it never
// touches a direct-mode pairing (it only names `hub.*` items, P3).

/// What a wipe removes: one hub (Leave, a confirmed revoke) or every hub item there is (Reset this iPhone).
public enum HubWipeScope: Sendable, Equatable, Codable {
    case hub(String)
    case everything

    var hubID: String? { if case .hub(let h) = self { h } else { nil } }
}

/// The durable wipe intent: what is being wiped, and how far it got.
public struct HubWipeIntent: Sendable, Equatable, Codable {
    public var scope: HubWipeScope
    public var phase: Int
    public init(scope: HubWipeScope, phase: Int) { self.scope = scope; self.phase = phase }
}

/// Where the intent lives. It must survive a kill (production: `UserDefaults`); it holds no secret (a hub id and a phase number).
public protocol HubWipeJournal: Sendable {
    func read() -> HubWipeIntent?
    func write(_ intent: HubWipeIntent) throws
    func clear()
}

public final class InMemoryHubWipeJournal: HubWipeJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var intent: HubWipeIntent?
    public init() {}
    public func read() -> HubWipeIntent? { lock.withLock { intent } }
    public func write(_ i: HubWipeIntent) throws { lock.withLock { intent = i } }
    public func clear() { lock.withLock { intent = nil } }
}

public struct DefaultsHubWipeJournal: HubWipeJournal, @unchecked Sendable {
    let defaults: UserDefaults
    let key: String
    public init(defaults: UserDefaults = .standard, key: String = "orch.hub.wipeIntent") { self.defaults = defaults; self.key = key }
    public func read() -> HubWipeIntent? { defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(HubWipeIntent.self, from: $0) } }
    public func write(_ i: HubWipeIntent) throws {
        defaults.set(try JSONEncoder().encode(i), forKey: key)
        guard defaults.data(forKey: key) != nil else { throw CocoaError(.fileWriteUnknown) }
    }
    public func clear() { defaults.removeObject(forKey: key) }
}

/// Extra local data of the hub that other tasks keep outside the vault (the replay rows and delivered notifications of B4, the Face ID
/// baseline of B3). Each one is idempotent and runs in the "local data" phase; a throw leaves the wipe resumable.
public typealias HubWipeStep = @Sendable (HubWipeScope) async throws -> Void

public final class HubWipe: Sendable {
    /// Phases, in order. Persisted after each one ran.
    enum Phase { static let begun = 0, quiesced = 1, secrets = 2, localData = 3, record = 4 }

    private let custody: HubKeyCustody
    private let cache: any HubCacheStore
    private let journal: any HubWipeJournal
    private let quiesce: @Sendable (HubWipeScope) async -> Void
    private let hooks = Hooks()
    /// The one wipe barrier (see `HubWorkBarrier`): closed when a wipe begins, open again when it has finished.
    public let barrier: HubWorkBarrier
    private let steps: [HubWipeStep]
    private let running = Running()

    private final class Hooks: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [@Sendable (HubWipeScope) async -> Void] = []
        func add(_ f: @escaping @Sendable (HubWipeScope) async -> Void) { lock.withLock { list.append(f) } }
        var all: [@Sendable (HubWipeScope) async -> Void] { lock.withLock { list } }
    }

    /// Registers something that must stop before a wipe deletes anything: the hub home's refreshes, B3's sign session, B4's push driver.
    /// Best effort, must not throw. Registered by the owner of the thing at its creation.
    public func onQuiesce(_ f: @escaping @Sendable (HubWipeScope) async -> Void) { hooks.add(f) }

    private actor Running {
        var task: Task<Void, Error>?
        func join(_ make: @Sendable () -> Task<Void, Error>) async throws {
            if let t = task { return try await t.value }
            let t = make(); task = t
            defer { task = nil }
            try await t.value
        }
    }

    /// `quiesce` stops hub views and in-flight signs before anything is deleted (best effort; it must not throw); `steps` clear local data
    /// outside the vault and the cache.
    public init(custody: HubKeyCustody, cache: any HubCacheStore, journal: any HubWipeJournal = InMemoryHubWipeJournal(),
                quiesce: @escaping @Sendable (HubWipeScope) async -> Void = { _ in }, steps: [HubWipeStep] = []) {
        self.custody = custody; self.cache = cache; self.journal = journal; self.quiesce = quiesce; self.steps = steps
        barrier = HubWorkBarrier(closed: journal.read() != nil)      // a wipe a killed run left blocks all hub work until it has finished
    }

    /// A new unit of hub work: take it BEFORE the work starts (see `HubWorkBarrier`).
    public func workToken() -> HubWorkToken { barrier.token() }

    /// A wipe was started and has not finished: nothing of this hub may be used or paired over until `resume` finishes it.
    public var pending: Bool { journal.read() != nil }
    public var intent: HubWipeIntent? { journal.read() }

    /// Writes the intent (synchronously, durable before any await). A wipe already pending is kept; `.everything` widens a pending hub wipe.
    /// Throws when the intent cannot be made durable: nothing is deleted then.
    public func begin(_ scope: HubWipeScope) throws {
        // The barrier closes and the intent is journaled under ONE lock (`HubWorkBarrier.beginWipe`): from here no hub write can succeed, whatever
        // happens to the journal write, and a finishing wipe cannot reopen the barrier over this intent.
        try barrier.beginWipe {
            let current = journal.read()
            switch (current?.scope, scope) {
            case (nil, _): try journal.write(HubWipeIntent(scope: scope, phase: Phase.begun))
            case (.hub?, .everything): try journal.write(HubWipeIntent(scope: .everything, phase: Phase.begun))
            default: break
            }
        }
    }

    /// Begins and runs one wipe to its end.
    public func wipe(_ scope: HubWipeScope) async throws {
        try begin(scope)
        try await run()
    }

    /// Finishes a wipe an earlier run left (launch). Nothing pending: nothing happens.
    public func resume() async throws { if pending { try await run() } }

    /// Runs the pending wipe from its persisted phase. One run at a time: a second caller joins the first.
    ///
    /// Repeats while a wipe is pending: a wipe that began after the running one's last journal read joins that task, which then ends without
    /// having run it (L2-B6d3-1); the loop runs it before this call returns.
    public func run() async throws {
        repeat { try await running.join { Task { try await self.runPhases() } } } while pending
    }

    private func runPhases() async throws {
        while let i = journal.read() {
            switch i.phase {
            case Phase.begun:
                await quiesce(i.scope)
                for f in hooks.all { await f(i.scope) }
                try advance(i, to: Phase.quiesced)
            case Phase.quiesced:
                // the keys, the session token and the push key; the record stays, so a half-done wipe still names the hub
                try custody.deleteSecrets(hubID: i.scope.hubID)
                try advance(i, to: Phase.secrets)
            case Phase.secrets:
                switch i.scope {
                case .hub(let h): cache.remove(hubID: h)
                case .everything: cache.removeAll()
                }
                for step in steps { try await step(i.scope) }
                try advance(i, to: Phase.localData)
            case Phase.localData:
                try custody.deleteRecords(hubID: i.scope.hubID)
                try advance(i, to: Phase.record)
            default:
                // finished: clear the journal and open the barrier only if the journal still holds exactly this intent (else a newer wipe
                // began meanwhile: it stays pending, the barrier stays closed, and the loop runs it)
                barrier.finishWipe {
                    guard journal.read() == i else { return false }
                    journal.clear()
                    return true
                }
            }
        }
    }

    private func advance(_ i: HubWipeIntent, to phase: Int) throws {
        // A widened intent (a hub wipe became Reset while this ran) starts over from its first phase: it is re-read, never overwritten.
        // (under the barrier lock: a begin cannot land between the read and the write)
        try barrier.serialized {
            guard let now = journal.read(), now.scope == i.scope else { return }
            try journal.write(HubWipeIntent(scope: now.scope, phase: max(now.phase, phase)))
        }
    }
}
