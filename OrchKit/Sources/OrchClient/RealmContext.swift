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
    /// A store or custody realm other than the one this context belongs to.
    case wrongStore
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
    package init(id: ID16) { self.id = id }
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

    private init(realm: Realm, origin: String, pinnedOwner: SigningPublicKey?) {
        self.realm = realm; self.origin = origin; self.pinnedOwner = pinnedOwner
    }

    /// A live context for one reviewed relay origin. The Demo origin and any `.invalid` host are refused.
    public static func live(origin: String, pinnedOwner: SigningPublicKey? = nil) throws -> RealmContext {
        guard RelayURL.isValid(origin) else { throw RealmViolation.invalidOrigin }
        guard !Self.isDemoLooking(origin) else { throw RealmViolation.crossRealmOrigin }
        return RealmContext(realm: .live, origin: origin, pinnedOwner: pinnedOwner)
    }

    public static func demo(_ capability: DemoCapability) -> RealmContext {
        RealmContext(realm: .demo, origin: DemoRelay.origin, pinnedOwner: nil)
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
    public func deviceIdentity(custody: any DeviceKeyCustody, createIfMissing: Bool) throws -> DeviceIdentity {
        do { return try custody.load(realm: realm) }
        catch CustodyError.missing where createIfMissing { return try custody.create(realm: realm) }
    }
}
