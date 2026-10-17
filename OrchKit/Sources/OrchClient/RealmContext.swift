import Foundation
import OrchCustody
import OrchProtocol

/// Why a realm boundary refused something. Always raised before any request is made.
public enum RealmViolation: Error, Equatable, Sendable {
    /// Not a section 7.1 origin.
    case invalidOrigin
    /// An origin other than the one this realm may reach (Demo: anything but `relay.demo.invalid`).
    case externalOrigin
    /// The other realm's relay origin (a Demo link in a live context, or the reverse).
    case crossRealmOrigin
    /// A link, index entry or other record tagged with the other realm.
    case crossRealmRecord
    /// A certificate whose owner belongs to the other realm.
    case crossRealmCertificate
    /// A Demo context paired with something other than the in-process relay.
    case wrongTransport
    /// A store, custody realm or device identity of a realm other than the one this context belongs to.
    case wrongStore
    /// The Demo environment this handle belonged to was reset: every retained handle (signing, transport, authority) is dead.
    case staleGeneration
}

/// The Demo realm's fixed relay identity. It never resolves (`.invalid`) and is reachable only in-process.
public enum DemoRelay {
    public static let host = "relay.demo.invalid"
    public static let origin = "https://relay.demo.invalid"
}

/// Proof that a Demo setup path ran (challenge C1). It has no public initializer: only realm bootstrap inside this
/// package mints one, and FakePrimary/FakeHost cannot be built without it. Callers cannot supply a live store, custody
/// realm or external transport to manufacture one.
public struct DemoCapability: Sendable {
    public let id: ID16
    /// The lifetime this capability (and everything built from it) belongs to. `DemoSetup.reset` invalidates it.
    public let generation: DemoGeneration
    package init(id: ID16, generation: DemoGeneration = DemoGeneration()) { self.id = id; self.generation = generation }
}

/// One realm lifetime (Demo or Live). Everything built from a `RealmContext` (transport, relay, authority actors, the device's signing
/// handles, the workspace store and the vault writes of sessions and pairings) checks it and throws `RealmViolation.staleGeneration`
/// once it has been invalidated by a reset or a "Leave".
///
/// The gate is a lock held only across SYNCHRONOUS check-and-act bodies (`perform`): `invalidate` takes the same lock, so when it
/// returns no body that passed the check is still running and none starts later. The lock is recursive, so a transaction that signs
/// (the signer re-checks) stays one critical section. It is never held across an await.
public final class RealmGeneration: WriteFence, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    /// `valid` has its own tiny lock, never held across a body: `check`/`isCurrent` read it without waiting for a body in flight, and
    /// `invalidate` clears it BEFORE taking the gate, so it waits only for the one body that already passed its check.
    private let flagLock = NSLock()
    private var valid = true
    private var participants: [ObjectIdentifier: WeakParticipant] = [:]
    private struct WeakParticipant { weak var value: (any RealmParticipant)? }
    package init() {}
    public var isCurrent: Bool { flagLock.withLock { valid } }
    /// Clears the flag, then takes the gate, so when it returns no body that passed the check is still running. Calling it from inside
    /// a `perform` body on the same thread (the lock is recursive) does not deadlock; the rest of that body then fails its nested checks.
    package func invalidate() {
        flagLock.withLock { valid = false }
        lock.lock(); lock.unlock()
    }
    package func check() throws { if !isCurrent { throw RealmViolation.staleGeneration } }
    /// Runs `body` with the generation held current: check and body are one step with respect to `invalidate`, so a reset
    /// cannot complete between them (custody access that creates keys must never outlive the reset that deleted them). `body` must not suspend.
    /// The check is repeated under the gate (an invalidation that cleared the flag meanwhile wins).
    package func perform<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard isCurrent else { throw RealmViolation.staleGeneration }
        return try body()
    }
    public func performFenced<T>(_ body: () throws -> T) throws -> T { try perform(body) }

    /// Registers a session or pairing coordinator of this realm (weakly) so `shutdownParticipants` can end and await it. Returns false,
    /// registering nothing, once the realm is invalid: the caller must then start no work.
    @discardableResult
    package func register(_ p: any RealmParticipant) -> Bool {
        lock.withLock {
            guard isCurrent else { return false }
            participants = participants.filter { $0.value.value != nil }
            participants[ObjectIdentifier(p)] = WeakParticipant(value: p)
            return true
        }
    }

    package var participantCount: Int { lock.withLock { participants.values.filter { $0.value != nil }.count } }

    /// Cancels every registered participant and waits for them, but never longer than `timeout`. Each participant's shutdown runs in its
    /// own unstructured task, all concurrently; the caller resumes exactly once, on "all finished" or on the deadline, and never waits
    /// for a participant that ignores cancellation (it is abandoned: the realm is already invalidated, so it can no longer act).
    /// Call after `invalidate`.
    package func shutdownParticipants(timeout: Duration = .seconds(5)) async {
        let live = lock.withLock { participants.values.compactMap(\.value) }
        guard !live.isEmpty else { return }
        let once = OnceResume()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            once.install(c)
            let remaining = Countdown(live.count)
            for p in live {
                Task { await p.realmShutdown(); if remaining.decrement() { once.fire() } }
            }
            let timer = Task { try? await Task.sleep(for: timeout); once.fire() }
            once.onFire { timer.cancel() }
        }
    }
}

/// Resumes its continuation exactly once, whoever fires first.
private final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Never>?
    private var fired = false
    private var cleanup: (@Sendable () -> Void)?
    func install(_ c: CheckedContinuation<Void, Never>) { lock.withLock { cont = c } }
    func onFire(_ f: @escaping @Sendable () -> Void) {
        let run = lock.withLock { () -> Bool in if fired { return true }; cleanup = f; return false }
        if run { f() }
    }
    func fire() {
        let (c, f) = lock.withLock { () -> (CheckedContinuation<Void, Never>?, (@Sendable () -> Void)?) in
            guard !fired else { return (nil, nil) }
            fired = true; defer { cont = nil; cleanup = nil }
            return (cont, cleanup)
        }
        f?(); c?.resume()
    }
}

private final class Countdown: @unchecked Sendable {
    private let lock = NSLock(); private var n: Int
    init(_ n: Int) { self.n = n }
    /// True when this call took the count to zero.
    func decrement() -> Bool { lock.withLock { n -= 1; return n == 0 } }
}

/// Something that works inside a realm (a `WorkspaceSession`, a `PairingCoordinator`) and can be cancelled and awaited at shutdown.
public protocol RealmParticipant: AnyObject, Sendable {
    /// Stops all in-flight work and returns when it has ended. Idempotent.
    func realmShutdown() async
}

public typealias DemoGeneration = RealmGeneration

/// The person ids of every Demo authority created in this process. A live context refuses a certificate or card owned by
/// one of them even if some other check was skipped (defence in depth for "certificate reuse denied").
package final class DemoAuthorities: @unchecked Sendable {
    package static let shared = DemoAuthorities()
    private let lock = NSLock()
    private var people: Set<ID16> = []
    package func register(_ person: ID16) { lock.lock(); people.insert(person); lock.unlock() }
    package func contains(_ person: ID16) -> Bool { lock.lock(); defer { lock.unlock() }; return people.contains(person) }
    #if DEBUG
    /// TEST-ONLY: lets a test host stand in for a real (Live) authority, e.g. the dev-sandbox lane tests, whose Live-realm phone talks to a
    /// FakeHost. Not compiled into Release.
    package func unregisterForTesting(_ person: ID16) { lock.lock(); people.remove(person); lock.unlock() }
    #endif
}

/// A realm plus the one relay origin it may talk to. Wraps the OrchCustody `Realm`; there is no parallel Demo abstraction.
/// A Demo context can be built only from a `DemoCapability`.
public struct RealmContext: Sendable {
    public let realm: Realm
    public let origin: String
    /// The owner key a live realm has pinned (nil before the first pairing).
    public let pinnedOwner: SigningPublicKey?
    /// The lifetime this context belongs to: every context, Demo or Live, has exactly one.
    package let generation: RealmGeneration

    private init(realm: Realm, origin: String, pinnedOwner: SigningPublicKey?, generation: RealmGeneration = RealmGeneration()) {
        self.realm = realm; self.origin = origin; self.pinnedOwner = pinnedOwner; self.generation = generation
    }

    /// A live context for one reviewed relay origin. Production origins are `https` only: the section 7.1 loopback `http`
    /// spellings are valid for the protocol (`RelayURL`) but are refused here, so a shipped build can never talk plaintext.
    /// The Demo origin and any `.invalid` host are refused.
    public static func live(origin: String, pinnedOwner: SigningPublicKey? = nil) throws -> RealmContext {
        guard origin.hasPrefix("https://"), RelayURL.isValid(origin) else { throw RealmViolation.invalidOrigin }
        guard !Self.isDemoLooking(origin) else { throw RealmViolation.crossRealmOrigin }
        return RealmContext(realm: .live, origin: origin, pinnedOwner: pinnedOwner, generation: RealmGeneration())
    }

    #if DEBUG
    /// TEST-ONLY admission of a loopback relay (`http://127.0.0.1:<port>` or `http://[::1]:<port>`) for integration tests
    /// against a locally started orch-relay.
    ///
    /// Why this cannot reach a Release app build: (1) the whole declaration sits inside `#if DEBUG`, so it does not exist in
    /// a Release compile of OrchClient; (2) it is `package` access, so even in a Debug build only code in the OrchKit
    /// package (its test targets) can call it, never the App target, which sees `public` API only; (3) `live(origin:)`,
    /// the only public route to a live context, requires `https://`. The port is required (a port-less `http://127.0.0.1`
    /// is refused) and `localhost` is excluded because it can resolve to a non-loopback address.
    package static func liveLoopbackForTesting(origin: String, pinnedOwner: SigningPublicKey? = nil) throws -> RealmContext {
        guard Self.isLoopbackHTTP(origin) else { throw RealmViolation.invalidOrigin }
        return RealmContext(realm: .live, origin: origin, pinnedOwner: pinnedOwner)
    }

    /// `http://127.0.0.1:<port>` or `http://[::1]:<port>`, valid under `RelayURL`, with an explicit port.
    package static func isLoopbackHTTP(_ origin: String) -> Bool {
        guard RelayURL.isValid(origin) else { return false }
        for prefix in ["http://127.0.0.1:", "http://[::1]:"] where origin.hasPrefix(prefix) { return true }
        return false
    }
    #endif

    /// Ends this context's lifetime, synchronously: every signature, send, store write and vault write that has not passed its check
    /// refuses from now on, and none that passed is still running when this returns. Call it before the first await of a teardown.
    public func invalidate() { generation.invalidate() }
    public var isCurrent: Bool { generation.isCurrent }
    /// The realm's gate as a `WriteFence`, for the few writes that happen outside OrchClient (they run inside `performFenced`).
    public var writeFence: any WriteFence { generation }
    /// Whether both contexts are the same lifetime (a transport built for another context would not stop when this one is invalidated).
    public func sharesLifetime(with other: RealmContext) -> Bool { generation === other.generation }
    /// Cancels and awaits every session and pairing coordinator built on this context (bounded). Call after `invalidate`.
    public func shutdownParticipants(timeout: Duration = .seconds(5)) async { await generation.shutdownParticipants(timeout: timeout) }

    public static func demo(_ capability: DemoCapability) -> RealmContext {
        RealmContext(realm: .demo, origin: DemoRelay.origin, pinnedOwner: nil, generation: capability.generation)
    }

    static func isDemoLooking(_ origin: String) -> Bool {
        let host = origin.split(separator: "/", omittingEmptySubsequences: true).dropFirst().first.map(String.init) ?? ""
        let h = host.split(separator: ":").first.map(String.init) ?? host
        return h == DemoRelay.host || h.hasSuffix(".invalid")
    }

    /// The check every pairing link, card and request origin passes before anything is sent.
    public func admit(origin candidate: String) throws {
        guard RelayURL.isValid(candidate) else { throw RealmViolation.invalidOrigin }
        if candidate == origin { return }
        switch realm {
        case .live: throw Self.isDemoLooking(candidate) ? RealmViolation.crossRealmOrigin : RealmViolation.externalOrigin
        case .demo: throw RealmViolation.externalOrigin
        }
    }

    /// A record tagged with a realm (a link, a stored index entry) must belong to this one.
    public func admit(realm other: Realm) throws {
        guard other == realm else { throw RealmViolation.crossRealmRecord }
    }

    /// Verifies a device certificate for this realm. A live realm never takes one owned by a Demo authority; the Demo
    /// realm takes only Demo authorities. Then the ordinary section 6.1 verification.
    public func admitCertificate(_ cert: JSONValue, ownerKey: SigningPublicKey, nowMs: Int64) throws -> DeviceCertificate {
        let owner = Identifiers.personID(ownerKey)
        switch realm {
        case .live:
            if DemoAuthorities.shared.contains(owner) { throw RealmViolation.crossRealmCertificate }
            if let pinned = pinnedOwner, pinned != ownerKey { throw Refusal.otherPerson }
        case .demo:
            if !DemoAuthorities.shared.contains(owner) { throw RealmViolation.crossRealmCertificate }
        }
        return try DeviceCertificate.verify(cert, personKey: ownerKey, nowMs: nowMs)
    }

    /// This realm's device keys: created on first use under realm-tagged secret ids, never shared with the other realm.
    /// The identity must carry this context's realm tag, which only an in-package custody sets: a wrapper custody that
    /// answers a Demo request with live keys (or the reverse) is refused with `RealmViolation.wrongStore`.
    public func deviceIdentity(custody: any DeviceKeyCustody, createIfMissing: Bool) throws -> DeviceIdentity {
        // A stale Demo context must not touch custody at all (it would recreate keys a reset just deleted).
        let lookup = {
            let identity: DeviceIdentity
            do { identity = try custody.load(realm: realm) }
            catch CustodyError.missing where createIfMissing { identity = try custody.create(realm: realm) }
            try admit(identity: identity)
            return identity
        }
        // Check and custody access are one step against `RealmGeneration.invalidate` (see `perform`).
        let identity = try generation.perform(lookup)
        // Every identity is leased to the context's generation: its handles stop signing when the realm is invalidated.
        return leased(identity)
    }

    /// The identity with its signer and key agreer leased to this context's generation. Leasing an already leased handle wraps it again
    /// (harmless: both leases check the same generation); it is not a no-op.
    public func leased(_ identity: DeviceIdentity) -> DeviceIdentity {
        DeviceIdentity(sig: LeasedSigner(inner: identity.sig, generation: generation), kx: LeasedKeyAgreer(inner: identity.kx, generation: generation), realm: identity.realm, custody: identity.custody)
    }

    /// An identity of the other realm never signs, logs in or is bound in this one.
    public func admit(identity: DeviceIdentity) throws {
        guard identity.realm == realm else { throw RealmViolation.wrongStore }
    }
}
