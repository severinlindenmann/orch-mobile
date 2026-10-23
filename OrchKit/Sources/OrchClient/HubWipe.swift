import Foundation
import OrchCustody

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
    private let steps: [HubWipeStep]
    private let running = Running()

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
    }

    /// A wipe was started and has not finished: nothing of this hub may be used or paired over until `resume` finishes it.
    public var pending: Bool { journal.read() != nil }
    public var intent: HubWipeIntent? { journal.read() }

    /// Writes the intent (synchronously, durable before any await). A wipe already pending is kept; `.everything` widens a pending hub wipe.
    /// Throws when the intent cannot be made durable: nothing is deleted then.
    public func begin(_ scope: HubWipeScope) throws {
        let current = journal.read()
        switch (current?.scope, scope) {
        case (nil, _): try journal.write(HubWipeIntent(scope: scope, phase: Phase.begun))
        case (.hub?, .everything): try journal.write(HubWipeIntent(scope: .everything, phase: Phase.begun))
        default: break
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
    public func run() async throws {
        try await running.join { Task { try await self.runPhases() } }
    }

    private func runPhases() async throws {
        while let i = journal.read() {
            switch i.phase {
            case Phase.begun:
                await quiesce(i.scope)
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
                journal.clear()
            }
        }
    }

    private func advance(_ i: HubWipeIntent, to phase: Int) throws {
        // A widened intent (a hub wipe became Reset while this ran) starts over from its first phase: it is re-read, never overwritten.
        guard let now = journal.read(), now.scope == i.scope else { return }
        try journal.write(HubWipeIntent(scope: now.scope, phase: max(now.phase, phase)))
    }
}
