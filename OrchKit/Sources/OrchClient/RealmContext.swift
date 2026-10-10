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

/// One Demo lifetime. Everything built from a `DemoCapability` (context, transport, relay, authority actors, the device's
/// signing handles) checks it and throws `RealmViolation.staleGeneration` once it has been invalidated by a reset.
public final class DemoGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    package init() {}
    public var isCurrent: Bool { lock.withLock { valid } }
    /// Takes the gate, so it waits for every `perform` in flight: when it returns, no lookup that passed the check is still running.
    package func invalidate() { lock.withLock { valid = false } }
    package func check() throws { if !isCurrent { throw RealmViolation.staleGeneration } }
    /// Runs `body` with the generation held current: check and body are one step with respect to `invalidate`, so a reset
    /// cannot complete between them (custody access that creates keys must never outlive the reset that deleted them).
    package func perform<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard valid else { throw RealmViolation.staleGeneration }
        return try body()
    }
}

/// The person ids of every Demo authority created in this process. A live context refuses a certificate or card owned by
/// one of them even if some other check was skipped (defence in depth for "certificate reuse denied").
package final class DemoAuthorities: @unchecked Sendable {
    package static let shared = DemoAuthorities()
    private let lock = NSLock()
    private var people: Set<ID16> = []
    package func register(_ person: ID16) { lock.lock(); people.insert(person); lock.unlock() }
    package func contains(_ person: ID16) -> Bool { lock.lock(); defer { lock.unlock() }; return people.contains(person) }
}

/// A realm plus the one relay origin it may talk to. Wraps the OrchCustody `Realm`; there is no parallel Demo abstraction.
/// A Demo context can be built only from a `DemoCapability`.
public struct RealmContext: Sendable {
    public let realm: Realm
    public let origin: String
    /// The owner key a live realm has pinned (nil before the first pairing).
    public let pinnedOwner: SigningPublicKey?
    /// Demo only: the lifetime this context belongs to (nil for a live context).
    package let generation: DemoGeneration?

    private init(realm: Realm, origin: String, pinnedOwner: SigningPublicKey?, generation: DemoGeneration? = nil) {
        self.realm = realm; self.origin = origin; self.pinnedOwner = pinnedOwner; self.generation = generation
    }

    /// A live context for one reviewed relay origin. The Demo origin and any `.invalid` host are refused.
    public static func live(origin: String, pinnedOwner: SigningPublicKey? = nil) throws -> RealmContext {
        guard RelayURL.isValid(origin) else { throw RealmViolation.invalidOrigin }
        guard !Self.isDemoLooking(origin) else { throw RealmViolation.crossRealmOrigin }
        return RealmContext(realm: .live, origin: origin, pinnedOwner: pinnedOwner)
    }

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
        // Check and custody access are one step against `DemoGeneration.invalidate` (see `perform`).
        let identity = try generation.map { try $0.perform(lookup) } ?? lookup()
        // Every Demo identity is leased to the context's generation: its handles stop signing when the Demo is reset.
        guard let g = generation else { return identity }
        return DeviceIdentity(sig: LeasedSigner(inner: identity.sig, generation: g), kx: LeasedKeyAgreer(inner: identity.kx, generation: g), realm: identity.realm)
    }

    /// An identity of the other realm never signs, logs in or is bound in this one.
    public func admit(identity: DeviceIdentity) throws {
        guard identity.realm == realm else { throw RealmViolation.wrongStore }
    }
}
