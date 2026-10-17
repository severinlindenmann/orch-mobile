import Foundation
import OrchCustody
import OrchProtocol

/// Proof that this process may sign Demo person events with a software key under `passphrase` custody (orch-52 Q2). It is minted only by
/// `DemoSetup`, next to the in-process relay transport, and is bound to that transport's realm lifetime: `PersonEventPolicy.derive`
/// accepts it only for a context of the same generation. A Live context, a software identity or another environment's grant never
/// qualifies. Application enforcement, not cryptographic attestation (the host still accepts `passphrase`).
///
/// It is bound to ONE transport instance as well (Opus MUST 2): the in-process sender it was minted next to (`sender`, the identity of the
/// FakeRelay object, kept alive by `anchor` so the identity cannot be reused). A session built over any other transport, even one of the
/// same generation, gets no policy and refuses construction.
public final class ProcessLocalWriteGrant: Sendable {
    package let generation: RealmGeneration
    package let sender: ObjectIdentifier
    let anchor: any AnyObject & Sendable
    package init(generation: RealmGeneration, sender: any AnyObject & Sendable) {
        self.generation = generation; self.sender = ObjectIdentifier(sender); self.anchor = sender
    }

    /// The grant belongs to this context's lifetime and to exactly this transport's in-process sender.
    package func admits(context: RealmContext, transport: any RelayTransport) -> Bool {
        generation === context.generation && transport.context.generation === context.generation && transport.processLocalSender == sender
    }
}

/// What this session may sign as, and over which relay. No public or package initializer: the only constructor is `derive`, which reads
/// the custody tag of the identity (set by an in-package custody) and the realm of the context, never a caller's claim.
///
/// - Live: a `secure-enclave-unlocked` event, from a Live identity held in the Secure Enclave, under a Live context.
/// - Demo: a `passphrase` event, from a Demo identity under a Demo context, with a `ProcessLocalWriteGrant` of that context's lifetime.
/// - Otherwise nil: Simulator and macOS Live (software custody), a software identity under a Live context, a mismatched realm or a foreign grant.
package struct PersonEventPolicy: Sendable, Equatable {
    /// Which signing lane a policy belongs to. `devSandbox` exists only in a Debug Simulator build (`DevSandboxLane.swift`).
    package enum Lane: Sendable, Equatable {
        case live, demo
        #if DEBUG && targetEnvironment(simulator)
        case devSandbox
        #endif
    }
    package let auth: F1Auth
    package let lane: Lane
    package let realm: Realm
    package let generation: RealmGeneration

    private init(auth: F1Auth, lane: Lane, realm: Realm, generation: RealmGeneration) {
        self.auth = auth; self.lane = lane; self.realm = realm; self.generation = generation
    }

    package static func derive(identity: DeviceIdentity, context: RealmContext, grant: ProcessLocalWriteGrant?,
                               transport: any RelayTransport) -> PersonEventPolicy? {
        guard identity.realm == context.realm else { return nil }
        switch context.realm {
        case .live:
            guard identity.custody == .secureEnclave else { return nil }
            return PersonEventPolicy(auth: .secureEnclaveUnlocked, lane: .live, realm: .live, generation: context.generation)
        case .demo:
            guard let grant, grant.admits(context: context, transport: transport) else { return nil }
            return PersonEventPolicy(auth: .passphrase, lane: .demo, realm: .demo, generation: context.generation)
        }
    }

    /// The actor a signed event names for this device.
    package func actor(person: ID16, device: ID16) throws -> PhoneActor { try PhoneActor(person: person, device: device, auth: auth) }

    /// The permit a write carries to the transport (`bridgePost`). The write gate of the session is the only caller.
    /// On the dev-sandbox lane the permit names the one workspace it was minted for; the network transport checks it against the route.
    package func permit(workspace: ID16) -> WritePermit {
        #if DEBUG && targetEnvironment(simulator)
        if lane == .devSandbox { return WritePermit(auth: auth, realm: realm, generation: generation, devSandboxWorkspace: workspace) }
        #endif
        return WritePermit(auth: auth, realm: realm, generation: generation)
    }

    package static func == (a: PersonEventPolicy, b: PersonEventPolicy) -> Bool {
        a.auth == b.auth && a.lane == b.lane && a.realm == b.realm && a.generation === b.generation
    }
}

#if DEBUG && targetEnvironment(simulator)
extension PersonEventPolicy {
    /// `derive` plus the lane branch: a Live context + a software identity + the enabler + a reader capability of level 1 (+ the variant's
    /// origin) gives `convenience` on the `.devSandbox` lane. A Secure Enclave identity is `derive`'s, always first; Demo is unchanged.
    package static func derive(identity: DeviceIdentity, context: RealmContext, grant: ProcessLocalWriteGrant?, transport: any RelayTransport,
                               enabler: DevSandboxLaneEnabler?, reader: ReaderRuntime) -> PersonEventPolicy? {
        if let base = derive(identity: identity, context: context, grant: grant, transport: transport) { return base }
        guard enabler != nil, context.realm == .live, identity.realm == .live, identity.custody == .software,
              reader.capability != nil, reader.level >= 1,
              DevSandboxLane.admitsOrigin(context.origin), transport.context.origin == context.origin else { return nil }
        return PersonEventPolicy(auth: .convenience, lane: .devSandbox, realm: .live, generation: context.generation)
    }
}
#endif

/// Carried by a person-event write to `RelayTransport.bridgePost`: the credential the event was signed under, the realm and the realm
/// lifetime. The transport checks all three against itself before sealing a request. Only `PersonEventPolicy.permit()` mints one.
public struct WritePermit: Sendable {
    public let auth: F1Auth
    public let realm: Realm
    package let generation: RealmGeneration
    /// Opus MUST 3: only `PersonEventPolicy.permit()` (this file) mints a permit.
    #if DEBUG && targetEnvironment(simulator)
    fileprivate init(auth: F1Auth, realm: Realm, generation: RealmGeneration) {
        self.auth = auth; self.realm = realm; self.generation = generation; devSandboxWorkspace = nil
    }
    /// The dev-sandbox lane's workspace (`.devSandbox(workspace:)`): nil for every other permit.
    package let devSandboxWorkspace: ID16?
    fileprivate init(auth: F1Auth, realm: Realm, generation: RealmGeneration, devSandboxWorkspace: ID16?) {
        self.auth = auth; self.realm = realm; self.generation = generation; self.devSandboxWorkspace = devSandboxWorkspace
    }
    package static func forTesting(auth: F1Auth, realm: Realm, generation: RealmGeneration, devSandboxWorkspace: ID16?) -> WritePermit {
        WritePermit(auth: auth, realm: realm, generation: generation, devSandboxWorkspace: devSandboxWorkspace)
    }
    #else
    fileprivate init(auth: F1Auth, realm: Realm, generation: RealmGeneration) { self.auth = auth; self.realm = realm; self.generation = generation }
    #endif

    #if DEBUG
    /// Tests only: a permit with chosen fields, to drive a transport's refusals directly.
    package static func forTesting(auth: F1Auth, realm: Realm, generation: RealmGeneration) -> WritePermit {
        WritePermit(auth: auth, realm: realm, generation: generation)
    }
    #endif
}
