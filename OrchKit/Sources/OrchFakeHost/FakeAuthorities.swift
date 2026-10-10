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

/// FakePrimary shell (host-api section 5): the synthetic Demo `PK`, `PVK` and primary-device keys, all generated fresh when
/// the actor is built and never persisted or derived from a vector scalar. It can be built only with a `DemoCapability`.
/// Slice 1 needs no more than certifying keys, delegating a workspace and revoking; the section 8.4 request queue, challenge
/// and code confirmation arrive with pairing (slice 2b) and replace `certify`.
public actor FakePrimary {
    private let pk = SoftwareSigner()
    private let pvk: SymmetricKey
    private let sig = SoftwareSigner()
    private let kx = SoftwareKeyAgreer()
    let wall: any WallClock
    let capability: DemoCapability
    public nonisolated let publicKey: SigningPublicKey
    public nonisolated let personID: ID16
    public nonisolated let deviceID: ID16
    public nonisolated let deviceKeys: DemoKeys

    public init(capability: DemoCapability, wall: any WallClock, entropy: any Entropy) {
        self.wall = wall; self.capability = capability
        pvk = SymmetricKey(data: entropy.bytes(32))
        publicKey = pk.publicKey
        personID = Identifiers.personID(pk.publicKey)
        deviceID = Identifiers.deviceID(sig.publicKey)
        deviceKeys = DemoKeys(sig: sig.publicKey, kx: kx.publicKey)
        DemoAuthorities.shared.register(personID)
    }

    /// A PK-signed certificate for exactly these keys (shell for the section 8.4 flow).
    public func certify(_ keys: DemoKeys, label: String, scopesMax: [String] = ["look", "decide", "operate", "type"],
                        lifetimeMs: Int64? = nil) throws -> JSONValue {
        try capability.generation.check()
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
    let wsk = SoftwareSigner()
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
    private var cardSeq: UInt32 = 0
    var listSeq: Int64 = 0
    public internal(set) var epoch: UInt32 = 0
    var core: HostBridgeCore
    var handler: HostHandler = defaultHostHandler
    var lastArrival: UInt64 = 0
    /// Adversarial tests: sign responses with another key (a member device, not the host).
    package var responseSigner: SoftwareSigner?
    var roster: [ID16: (keys: DemoKeys, scopes: [String])] = [:]
    /// Set by `pump`: the relay and host session a revocation-driven rotation publishes to.
    var bridgeRelay: (relay: FakeRelay, session: RelaySession)?
    /// A rotation in progress. Requests wait for it, so nothing new is sealed under an epoch being retired.
    var rotation: Task<Void, Error>?
    /// Retained across publication failures, including public rotations with an explicitly changed roster.
    var pendingRotation: (remaining: [(DemoKeys, [String])], relay: FakeRelay, session: RelaySession)?
    /// Set BEFORE any rotation suspends (or a revocation removes a member), cleared only after grants, list and epoch install. While set,
    /// no data is sealed; the next pump retries the publication.
    var rotationRequired = false
    /// Tests: runs inside the publication, before the first grant.
    package var publishHook: (@Sendable () async throws -> Void)?
    /// Streams (by request id) that are accepted but not finished: request epoch and next chunk index.
    var streamOpen: [ID16: (device: ID16, epoch: UInt32, next: UInt64)] = [:]
    /// Streams a rotation already ended; their handlers' late answers are discarded.
    var streamEnded: Set<ID16> = []
    /// Chunks the host must post that no request is waiting on (rotation ending open streams).
    var outbox: [(rid: ID16, chunk: Data)] = []

    public init(capability: DemoCapability, context: RealmContext, primary: FakePrimary, name: String = "Laptop", clientHosted: Bool = false,
                hostedBy: String? = nil, workspace: ID16? = nil, wall: any WallClock, entropy: any Entropy) throws {
        guard context.realm == .demo, context.generation === capability.generation else { throw RealmViolation.wrongStore }
        self.workspace = workspace ?? entropy.id16()
        self.capability = capability
        self.primary = primary; self.wall = wall; self.entropy = entropy; self.origin = context.origin
        self.name = name; self.clientHosted = clientHosted; self.hostedBy = hostedBy
        wskPublic = wsk.publicKey
        core = HostBridgeCore(workspace: self.workspace, epoch: 0)
    }

    func wk(_ e: UInt32) -> SymmetricKey {
        if let k = wks[e] { return k }
        let k = SymmetricKey(data: entropy.bytes(32)); wks[e] = k; return k
    }

    /// Epoch 1, card_seq 1, with a fresh CK.
    public func card() async throws -> JSONValue {
        try capability.generation.check()
        cardSeq = max(cardSeq, 1)
        let ck = cks[cardSeq] ?? SymmetricKey(data: entropy.bytes(32)); cks[cardSeq] = ck
        let part = CardSealedPart(name: name, description: "Demo workspace", capabilities: ["tickets", "questions", "drop"], hostedBy: hostedBy)
        let sealed = try Card.sealPart(part, ck: ck, workspace: workspace, cardSeq: cardSeq)
        return try Card.make(delegation: try await primary.delegation(workspace: workspace, wsk: wsk.publicKey, clientHosted: clientHosted),
                             workspace: workspace, wxk: wxk.publicKey, wxkVersion: 1, owner: primary.personID, relayURL: origin,
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
        guard let ck = cks[seq] else { throw Refusal.malformed }
        return try CardKeyWrap.seal(ck: ck, to: keys.kx, deviceID: Identifiers.deviceID(keys.sig), workspace: workspace, cardSeq: seq)
    }

    public func memberList(_ members: [(device: ID16, scopes: [String])], epoch e: UInt32, listSeq seq: Int64) throws -> JSONValue {
        try capability.generation.check()
        let sorted = members.sorted { $0.device.hex < $1.device.hex }
        return try SignedObject.sign([
            "v": 2, "suite": 2, "kind": "member_list", "workspace_id": .string(workspace.hex), "epoch": .int(Int64(e)), "list_seq": .int(seq),
            "issued_ms": .int(wall.nowMs), "members": .array(sorted.map { .object(["device_id": .string($0.device.hex), "scopes": .array($0.scopes.map { .string($0) })]) })],
                                     kind: .memberList, signer: wsk).json
    }

    /// Workspace session with the relay (section 12.2, signed with `WSK`). The login is bound to the transport's own context:
    /// it must be this Demo lifetime's context at this host's origin, or nothing is sent (a forwarding wrapper that reports another
    /// context cannot make `WSK` sign a foreign origin; `RelayClient` signs `transport.context.origin`).
    public func openSession(transport: any RelayTransport) async throws -> RelaySession {
        try capability.generation.check()
        let c = transport.context
        guard c.realm == .demo, c.origin == origin, c.generation === capability.generation else { throw RealmViolation.wrongTransport }
        return try await RelayClient(transport: transport).openSession(kind: .workspace, id: workspace, signer: wsk).session
    }

    /// Publishes the directory entries, the card, the CK wrap and `WK_1` grant for the given devices and then the first list.
    /// Order is section 7.2's: certificates and card, grants, then the list. Returns the workspace session.
    @discardableResult
    public func publishInitial(relay: FakeRelay, transport: any RelayTransport, devices: [(keys: DemoKeys, cert: JSONValue, scopes: [String])]) async throws -> RelaySession {
        await relay.registerOwner(primary.publicKey)
        for d in devices { try await relay.publishCertificate(d.cert) }
        try await relay.publishCard(try await card())
        let session = try await openSession(transport: transport)
        epoch = 1; listSeq = 1
        for d in devices {
            try await relay.putGrant(try grant(for: d.keys, epoch: 1), token: session.token)
            try await relay.putCardKeyWrap(device: Identifiers.deviceID(d.keys.sig), cardSeq: 1, sealed: try cardKeyWrap(for: d.keys), token: session.token)
        }
        try await relay.publishMemberList(try memberList(devices.map { (Identifiers.deviceID($0.keys.sig), $0.scopes) }, epoch: 1, listSeq: 1), token: session.token)
        installEpoch(1)
        setRoster(devices.map { ($0.keys, $0.scopes) })
        return session
    }
}
