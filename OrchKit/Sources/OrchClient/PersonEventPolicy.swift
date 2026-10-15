import Foundation
import OrchCustody
import OrchProtocol

/// Proof that this process may sign Demo person events with a software key under `passphrase` custody (orch-52 Q2). It is minted only by
/// `DemoSetup`, next to the in-process relay transport, and is bound to that transport's realm lifetime: `PersonEventPolicy.derive`
/// accepts it only for a context of the same generation. A Live context, a software identity or another environment's grant never
/// qualifies. Application enforcement, not cryptographic attestation (the host still accepts `passphrase`).
public final class ProcessLocalWriteGrant: Sendable {
    package let generation: RealmGeneration
    package init(generation: RealmGeneration) { self.generation = generation }
}

/// What this session may sign as, and over which relay. No public or package initializer: the only constructor is `derive`, which reads
/// the custody tag of the identity (set by an in-package custody) and the realm of the context, never a caller's claim.
///
/// - Live: a `secure-enclave-unlocked` event, from a Live identity held in the Secure Enclave, under a Live context.
/// - Demo: a `passphrase` event, from a Demo identity under a Demo context, with a `ProcessLocalWriteGrant` of that context's lifetime.
/// - Otherwise nil: Simulator and macOS Live (software custody), a software identity under a Live context, a mismatched realm or a foreign grant.
package struct PersonEventPolicy: Sendable, Equatable {
    package let auth: F1Auth
    package let realm: Realm
    package let generation: RealmGeneration

    private init(auth: F1Auth, realm: Realm, generation: RealmGeneration) { self.auth = auth; self.realm = realm; self.generation = generation }

    package static func derive(identity: DeviceIdentity, context: RealmContext, grant: ProcessLocalWriteGrant?) -> PersonEventPolicy? {
        guard identity.realm == context.realm else { return nil }
        switch context.realm {
        case .live:
            guard identity.custody == .secureEnclave else { return nil }
            return PersonEventPolicy(auth: .secureEnclaveUnlocked, realm: .live, generation: context.generation)
        case .demo:
            guard let grant, grant.generation === context.generation else { return nil }
            return PersonEventPolicy(auth: .passphrase, realm: .demo, generation: context.generation)
        }
    }

    /// The actor a signed event names for this device.
    package func actor(person: ID16, device: ID16) throws -> PhoneActor { try PhoneActor(person: person, device: device, auth: auth) }

    /// The permit a write carries to the transport (`bridgePost`). The write gate of the session is the only caller.
    package func permit() -> WritePermit { WritePermit(auth: auth, realm: realm, generation: generation) }

    package static func == (a: PersonEventPolicy, b: PersonEventPolicy) -> Bool { a.auth == b.auth && a.realm == b.realm && a.generation === b.generation }
}

/// Carried by a person-event write to `RelayTransport.bridgePost`: the credential the event was signed under, the realm and the realm
/// lifetime. The transport checks all three against itself before sealing a request. Only `PersonEventPolicy.permit()` mints one.
public struct WritePermit: Sendable {
    public let auth: F1Auth
    public let realm: Realm
    package let generation: RealmGeneration
    package init(auth: F1Auth, realm: Realm, generation: RealmGeneration) { self.auth = auth; self.realm = realm; self.generation = generation }
}
