import CryptoKit
import Foundation
import OrchClient
import OrchCustody
import OrchProtocol

/// A device's two public keys. `OrchCustody.DevicePublicKeys` has no public initializer (reported for slice 0/M3); this is the fakes' own.
public struct DemoKeys: Sendable, Equatable {
    public let sig: SigningPublicKey
    public let kx: AgreementPublicKey
    public init(sig: SigningPublicKey, kx: AgreementPublicKey) { self.sig = sig; self.kx = kx }
    public init(_ k: DevicePublicKeys) { sig = k.sig; kx = k.kx }
    public var deviceID: ID16 { Identifiers.deviceID(sig) }
}

/// FakePrimary (host-api section 5): the synthetic Demo `PK`, `PVK` and primary-device keys, all generated fresh when the actor is
/// built and never persisted or derived from a vector scalar. It can be built only with a `DemoCapability`. It enforces protocol
/// section 8.4 with `PrimaryLedger`: it opens a host request only after the checks (in order), draws its nonce after the keys
/// reached it, signs a challenge with `PK`, and certifies exactly the keys of that challenge, once, only after an explicit second
/// approval that names the compared code. A joining phone is certified through this flow and nothing else; `certify` below is the
/// owner's enrolment of devices outside it (the Demo Mac's own key, test seeding of members).
public actor FakePrimary {
    private let pk = SoftwareSigner()
    private let pvk: SymmetricKey
    private let sig = SoftwareSigner()
    private let kx = SoftwareKeyAgreer()
    nonisolated var pkSigner: SoftwareSigner { pk }
    var pvkKey: SymmetricKey { pvk }
    var kxAgreer: SoftwareKeyAgreer { kx }
    let wall: any WallClock
    let entropy: any Entropy
    var ledger = PrimaryLedger()
    package func ledgerSnapshot() -> PrimaryLedger { ledger }
    var prompts: [ID16: PrimaryPrompt] = [:]
    var refusals: [ID16: Refusal] = [:]
    var relaySession: (session: RelaySession, expiresMs: Int64)?
    nonisolated var deviceSigner: SoftwareSigner { sig }
    /// The label the host shows next to "Open orch on ...".
    public nonisolated let label = "Demo Mac"
    let capability: DemoCapability
    public nonisolated let publicKey: SigningPublicKey
    public nonisolated let personID: ID16
    public nonisolated let deviceID: ID16
    public nonisolated let deviceKeys: DemoKeys

    public init(capability: DemoCapability, wall: any WallClock, entropy: any Entropy) {
        self.wall = wall; self.capability = capability; self.entropy = entropy
        pvk = SymmetricKey(data: entropy.bytes(32))
        publicKey = pk.publicKey
        personID = Identifiers.personID(pk.publicKey)
        deviceID = Identifiers.deviceID(sig.publicKey)
        deviceKeys = DemoKeys(sig: sig.publicKey, kx: kx.publicKey)
        DemoAuthorities.shared.register(personID)
    }

    /// A PK-signed certificate for exactly these keys, without the section 8.4 flow: the owner enrolling a device in person (the Demo
    /// Mac's own key, members seeded by tests). A phone that joins through pairing never gets its certificate here.
    public func certify(_ keys: DemoKeys, label: String, scopesMax: [String] = ["look", "decide", "operate", "type"],
                        lifetimeMs: Int64? = nil) throws -> JSONValue {
        try capability.generation.check()
        return try signDeviceCert(keys, label: label, scopesMax: scopesMax, lifetimeMs: lifetimeMs)
    }

    func signDeviceCert(_ keys: DemoKeys, label: String, scopesMax: [String], lifetimeMs: Int64?) throws -> JSONValue {
        guard Scopes.isValid(scopesMax), !scopesMax[0].utf8.starts(with: "drop:".utf8) else { throw Refusal.scopeExceeded }
        let device = Identifiers.deviceID(keys.sig)
        let now = wall.nowMs
        let sealed = try SealedLabel.seal(label: label, pvk: pvk, person: personID, device: device)
        let cert = try SignedObject.sign([
            "v": 2, "suite": 2, "kind": "device_cert", "device_id": .string(device.hex), "person_id": .string(personID.hex),
            "dk_sig_pub": .string(B64U.encode(keys.sig.x963)), "dk_kx_pub": .string(B64U.encode(keys.kx.x963)),
            "label_sealed": .string(B64U.encode(sealed)), "created_ms": .int(now),
            "expires_ms": lifetimeMs.map { .int(now + $0) } ?? .null, "scopes_max": .array(scopesMax.map { .string($0) })],
                                         kind: .deviceCert, signer: pk)
        return cert.json
    }

    public func certifyOwnDevice(label: String = "Demo Mac") throws -> JSONValue { try certify(deviceKeys, label: label) }

    func delegation(workspace: ID16, wsk: SigningPublicKey, clientHosted: Bool) throws -> SignedObject {
        try capability.generation.check()
        return try WorkspaceDelegation.sign(workspace: workspace, wsk: wsk, clientHosted: clientHosted, issuedMs: wall.nowMs, owner: pk)
    }

    /// A PK-signed revocation (section 6.2) of a device of this person.
    public func revoke(device: ID16, reason: String = "lost") throws -> JSONValue {
        try capability.generation.check()
        return try SignedObject.sign(["v": 2, "suite": 2, "kind": "revocation", "person_id": .string(personID.hex), "device_id": .string(device.hex),
                               "revoked_ms": .int(wall.nowMs), "reason": .string(reason)], kind: .revocation, signer: pk).json
    }

    func sign(login challenge: Data, origin: String) throws -> Data {
        try capability.generation.check()
        return try RelayAuth.sign(sig, origin: origin, challenge: challenge, kind: .device, id: deviceID)
    }
}

/// FakeHost shell: `WSK`, `WXK`, the epoch keys and `CK` of one Demo workspace, enough to publish a card, grants and a
/// member list through the relay's own checks. The section 8.6 pipeline arrives in slice 2a.
public actor FakeHost {
    public nonisolated let workspace: ID16
    public nonisolated let wskPublic: SigningPublicKey
    nonisolated let wsk = SoftwareSigner()
    let wxk = SoftwareKeyAgreer()
    let primary: FakePrimary
    let capability: DemoCapability
    let wall: any WallClock
    let entropy: any Entropy
    let origin: String
    private let clientHosted: Bool
    private let name: String
    private let hostedBy: String?
    var wks: [UInt32: SymmetricKey] = [:]
    var cks: [UInt32: SymmetricKey] = [:]
    var cardSeq: UInt32 = 0
    var cardDelegation: SignedObject?
    var listSeq: Int64 = 0
    public internal(set) var epoch: UInt32 = 0
    var core: HostBridgeCore
    var handler: HostHandler?
    let demoDropFixtures: Bool
    var dropSeedTask: Task<Void, Error>?
    var dropSeedComplete = false
    var dropSeedBodies: [Data]?
    var dropSeedUploaded = 0
    var viewState: HostViewState?
    var lastArrival: UInt64 = 0
    /// The last request position this host completed (its acknowledged cursor, P3-D10).
    var completedArrival: UInt64 = 0
    /// Adversarial tests: sign responses with another key (a member device, not the host).
    package var responseSigner: SoftwareSigner?
    var roster: [ID16: (keys: DemoKeys, scopes: [String])] = [:]
    /// Set by `pump`: the relay and host session a revocation-driven rotation publishes to.
    var bridgeRelay: (relay: FakeRelay, session: RelaySession)?
    /// A rotation in progress. Requests wait for it, so nothing new is sealed under an epoch being retired.
    var rotation: Task<Void, Error>?
    /// Retained across publication failures, including public rotations with an explicitly changed roster.
    var pendingRotations: [(remaining: [(DemoKeys, [String])], relay: FakeRelay, session: RelaySession)] = []
    var lastRotationRoster: [(DemoKeys, [String])]?
    var rotationRemoved: Set<ID16> = []
    var rotationSessions: [ObjectIdentifier: RelaySession] = [:]
    var rotationFailures = 0
    /// The membership publication persisted before it is sent (P3-D7): resent byte for byte until committed or definitely refused.
    var pendingPublication: PendingPublication?
    /// Grants and card-key wraps exactly as sealed and sent: a later publication carries the same bytes, never a reseal.
    var sealedGrants: [MemberList.Directory.GrantKey: JSONValue] = [:]
    var sealedWraps: [ID16: [UInt32: String]] = [:]
    /// The holder generation this host writes under (P3-D10).
    var holderGen: UInt64?
    /// One membership publication at a time (joins and rotations share the pending slot and `list_seq`).
    var publicationLocked = false
    /// The epoch of a relay list this host did not publish (section 19.7): the next publication goes above it.
    var relayEpochFloor: UInt32 = 0
    /// Q10 liveness: refusals in a row that burned an epoch, and the alarm that stops publishing (`MembershipPublicationAlarm`).
    var consecutiveBurns = 0
    public internal(set) var publicationAlarm: MembershipPublicationAlarm?
    var publicationWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set BEFORE any rotation suspends (or a revocation removes a member), cleared only after grants, list and epoch install. While set,
    /// no data is sealed; the next pump retries the publication.
    var rotationRequired = false
    /// Tests: runs inside a rotation's publication, after the body is built and persisted, before it is first sent.
    package var publishHook: (@Sendable () async throws -> Void)?
    /// Streams (by request id) that are accepted but not finished: request epoch and next chunk index.
    var streamOpen: [ID16: (device: ID16, epoch: UInt32, next: UInt64)] = [:]
    /// Streams a rotation already ended; their handlers' late answers are discarded.
    var streamEnded: Set<ID16> = []
    /// Host chunks the relay refused and this host tolerated (rid, code): tests assert where they happen.
    package var relayRefusedChunks: [(rid: ID16, code: RelayRefusal.Code)] = []
    /// Chunks the host must post that no request is waiting on (rotation ending open streams).
    var outbox: [(rid: ID16, chunk: Data)] = []

    // Pairing (section 8.3). The scenario knobs below are the fakes' own behaviours; the human decisions are explicit calls.
    var relaySession: (session: RelaySession, expiresMs: Int64)?
    var lastPairArrival: UInt64 = 0
    var lastPairingError: String?
    /// The host is the owner's primary device (it certifies locally after its own approval). Refused for a client-hosted workspace.
    public internal(set) var hostIsPrimary = false
    /// Adversarial: the cert request names the host's own keys instead of the phone's (R1).
    public internal(set) var r1Attack = false
    /// Adversarial: `pending` echoes a foreign key.
    public internal(set) var echoWrongKey: EchoedKey?
    public enum EchoedKey: Sendable { case signing, exchange }
    public nonisolated let isClientHosted: Bool
    /// Adversarial knobs for T0 (package scope: unreachable from the app): what a hostile or buggy host would do at the end of a join.
    package struct Hostile: Sendable {
        /// The card-key wrap is sealed to the device with this key instead of the card's `CK`.
        package var wrapKey: SymmetricKey?
        /// The member list names the device with these scopes instead of the approved ones.
        package var listScopes: [String]?
        /// The approved answer claims this epoch.
        package var approvedEpoch: UInt32?
        /// The member list leaves the device out.
        package var omitFromList = false
        package init() {}
    }
    package var hostile = Hostile()
    /// Tests: runs at the named points of the host's approval (an `await` there lets a test act concurrently, e.g. reject).
    package var approvalHook: (@Sendable (String) async -> Void)?
    package func setApprovalHook(_ h: (@Sendable (String) async -> Void)?) { approvalHook = h }
    /// Scenario knob: a join's member list is published only once the wall clock reaches this time (at the next pump). Everything else
    /// of the join (certificate, grant, card-key wrap) is already out, so the phone sits in `joining` until exactly this boundary.
    package var listHoldUntilMs: Int64?
    package func holdMemberList(until ms: Int64?) { listHoldUntilMs = ms }
    var heldList: (adding: (DemoKeys, [String])?, wraps: [DemoKeys])?
    package func setHostile(_ f: (inout Hostile) -> Void) { f(&hostile) }

    public init(capability: DemoCapability, context: RealmContext, primary: FakePrimary, name: String = "Laptop", clientHosted: Bool = false,
                hostedBy: String? = nil, workspace: ID16? = nil, demoDropFixtures: Bool = false, wall: any WallClock, entropy: any Entropy) throws {
        guard context.realm == .demo, context.generation === capability.generation else { throw RealmViolation.wrongStore }
        self.workspace = workspace ?? entropy.id16()
        self.capability = capability
        self.demoDropFixtures = demoDropFixtures
        self.primary = primary; self.wall = wall; self.entropy = entropy; self.origin = context.origin
        self.name = name; self.clientHosted = clientHosted; self.hostedBy = hostedBy; isClientHosted = clientHosted
        wskPublic = wsk.publicKey
        core = HostBridgeCore(workspace: self.workspace, epoch: 0)
        core.wskPub = wsk.publicKey; core.ownerPK = primary.publicKey
    }

    func wk(_ e: UInt32) -> SymmetricKey {
        if let k = wks[e] { return k }
        let k = SymmetricKey(data: entropy.bytes(32)); wks[e] = k; return k
    }

    /// Epoch 1, card_seq 1, with a fresh CK.
    public func card() async throws -> JSONValue { try await card(relayURL: nil) }

    /// `relayURL` overrides the card's `relay_url` (adversarial tests only: a relay publishes just its own origin).
    package func card(relayURL: String?) async throws -> JSONValue {
        try capability.generation.check()
        cardSeq = max(cardSeq, 1)
        let ck = cks[cardSeq] ?? SymmetricKey(data: entropy.bytes(32)); cks[cardSeq] = ck
        let part = CardSealedPart(name: name, description: "Demo workspace", capabilities: ["tickets", "questions", "drop"], hostedBy: hostedBy)
        let sealed = try Card.sealPart(part, ck: ck, workspace: workspace, cardSeq: cardSeq)
        // PK signs the delegation once; every later card carries it byte for byte (`delegation_changed` otherwise).
        let delegation: SignedObject
        if let d = cardDelegation { delegation = d } else {
            delegation = try await primary.delegation(workspace: workspace, wsk: wsk.publicKey, clientHosted: clientHosted)
            cardDelegation = delegation
        }
        return try Card.make(delegation: delegation,
                             workspace: workspace, wxk: wxk.publicKey, wxkVersion: 1, owner: primary.personID, relayURL: relayURL ?? origin,
                             cardSeq: cardSeq, issuedMs: wall.nowMs, sealed: sealed, ck: ck, wsk: wsk)
    }

    /// `WK_e` sealed to a device and signed by `WSK` (section 7.3).
    public func grant(for keys: DemoKeys, epoch e: UInt32) throws -> JSONValue {
        try capability.generation.check()
        return try WKGrant.make(wsk: wsk, workspace: workspace, device: Identifiers.deviceID(keys.sig), deviceKey: keys.kx, epoch: e, wk: wk(e)).json
    }

    /// `CK` of a card sequence sealed to a device (purpose `card`, section 5.3).
    public func cardKeyWrap(for keys: DemoKeys, cardSeq seq: UInt32 = 1) throws -> Data {
        try capability.generation.check()
        guard let real = cks[seq] else { throw Refusal.malformed }
        let ck = hostile.wrapKey ?? real
        return try CardKeyWrap.seal(ck: ck, to: keys.kx, deviceID: Identifiers.deviceID(keys.sig), workspace: workspace, cardSeq: seq)
    }

    /// A WSK-signed member list (section 7.2, P3-D6). Every member names its person: the owner's unless `personOf` says otherwise;
    /// `persons` lists the other persons the list authorizes (sorted, unique). `wk_commit` commits this host's `WK_e` (Q10; created
    /// here if the epoch has none yet); `wkCommit` overrides it (adversarial tests only).
    public func memberList(_ members: [(device: ID16, scopes: [String])], epoch e: UInt32, listSeq seq: Int64, persons: [ID16] = [],
                           personOf: [ID16: ID16] = [:]) throws -> JSONValue {
        try memberList(members, epoch: e, listSeq: seq, persons: persons, personOf: personOf, wkCommit: nil)
    }

    package func memberList(_ members: [(device: ID16, scopes: [String])], epoch e: UInt32, listSeq seq: Int64, persons: [ID16] = [],
                            personOf: [ID16: ID16] = [:], wkCommit: Data?) throws -> JSONValue {
        try capability.generation.check()
        let sorted = members.sorted { $0.device.hex < $1.device.hex }
        let entries: [JSONValue] = sorted.map {
            .object(["device_id": .string($0.device.hex), "person_id": .string((personOf[$0.device] ?? primary.personID).hex),
                     "scopes": .array($0.scopes.map { .string($0) })])
        }
        return try SignedObject.sign([
            "v": 2, "suite": 2, "kind": "member_list", "workspace_id": .string(workspace.hex), "epoch": .int(Int64(e)), "list_seq": .int(seq),
            "issued_ms": .int(wall.nowMs), "persons": .array(Set(persons).map(\.hex).sorted().map { .string($0) }), "members": .array(entries),
            "wk_commit": .string(B64U.encode(wkCommit ?? WKCommit.compute(workspace: workspace, epoch: e, wk: wk(e))))],
                                     kind: .memberList, signer: wsk).json
    }

    /// Workspace session with the relay (section 12.2, signed with `WSK`). The login is bound to the transport's own context:
    /// it must be this Demo lifetime's context at this host's origin, or nothing is sent (a forwarding wrapper that reports another
    /// context cannot make `WSK` sign a foreign origin; `RelayClient` signs `transport.context.origin`).
    public func openSession(transport: any RelayTransport) async throws -> RelaySession {
        try capability.generation.check()
        let c = transport.context
        guard c.realm == .demo, c.origin == origin, c.generation === capability.generation else { throw RealmViolation.wrongTransport }
        let opened = try await RelayClient(transport: transport).openSession(kind: .workspace, id: workspace, signer: wsk)
        relaySession = (opened.session, opened.expiresMs)
        return opened.session
    }

    /// The host's workspace session, renewed when it is about to end (a 10-minute pairing outlives nothing, but 15-minute sessions do).
    func currentSession(transport: any RelayTransport) async throws -> RelaySession {
        if let s = relaySession, wall.nowMs < s.expiresMs - 30_000 { return s.session }
        return try await openSession(transport: transport)
    }

    /// Publishes the directory entries and the card, then the first list with every `WK_1` grant and CK wrap in one atomic
    /// membership publication (P3-D7). Returns the workspace session.
    @discardableResult
    public func publishInitial(relay: FakeRelay, transport: any RelayTransport, devices: [(keys: DemoKeys, cert: JSONValue, scopes: [String])]) async throws -> RelaySession {
        await relay.registerOwner(primary.publicKey)
        for d in devices { try await relay.publishCertificate(d.cert) }
        try await relay.publishCard(try await card())
        let session = try await openSession(transport: transport)
        let roster = devices.map { ($0.keys, $0.scopes) }
        try await publishMembership(roster: roster, epoch: 1, wraps: devices.map(\.keys), relay: relay, session: session)
        return session
    }
}
