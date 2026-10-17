import CryptoKit
import Foundation
import OrchClient
import OrchProtocol

/// Limits of the fake relay, all invented for v0 (host-api section 3) and all injectable.
public struct RelayLimits: Sendable {
    public var sessionLifetimeMs: Int64 = 15 * 60_000
    public var bodyLifetimeMs: Int64 = 60_000
    public var pairPostsPerMinutePerWorkspace = 60
    public var pairPostsPerMinutePerAddress = 60
    public var pairPollsPerMinutePerAddress = 120
    public var retryAfterSeconds = 5
    public var maxPairEnvelope = 64 * 1024
    /// Live (unexpired) request mailboxes one device may hold per workspace before the relay answers 429 `quota_exceeded`.
    public var maxLiveMailboxesPerDevice = 128
    public var maxOutstandingChallenges = 1024
    /// Live bearer tokens one device may hold (section 19.1): the next login is 429 `quota_exceeded` until the earliest expires.
    public var maxLiveTokensPerDevice = 8
    /// Pairing POSTs (device requests and host answers) across all workspaces and addresses per minute (section 19.3: 6 000).
    public var pairPostsPerMinuteGlobal = 6_000
    /// Bytes queued in one workspace's pairing mailboxes before a pairing POST is 429 `quota_exceeded`.
    public var maxQueuedPairBytesPerWorkspace = 4 << 20
    /// Bytes queued in every mailbox together before a POST is 503 `overloaded` (section 19.4 P3-D17: 256 MiB).
    public var maxQueuedBytesGlobal = 256 << 20
    /// Concurrent polls of one principal (an address for pairing polls, a device for queue polls): above it 429 `quota_exceeded`.
    public var maxConcurrentPollsPerPrincipal = 6
    /// Concurrent polls of everyone (section 19.4: 4 096): above it 503 `overloaded`.
    public var maxConcurrentPollsGlobal = 4_096
    /// Drop (P3-D39, protocol 19.9): live versions per workspace, blob bytes per workspace, and the other caps of the quota table.
    public var maxDropVersions = 4096
    public var maxDropBytes = 512 << 20
    public var maxDropBlobBytes = 26 << 20
    public var maxDropDocVersions = 1024
    public var dropDeviceBytes = 256 << 20
    public var dropDeviceVersions = 1024
    public var dropWorkspaceDocuments = 256
    public var dropDeviceDocuments = 64
    public var dropWorkspaceHeadBytes = 32 << 20
    public var dropDeviceHeadBytes = 8 << 20
    /// 429 `rate_limited` after this many Drop uploads per device per minute (0: off; the real relay's bucket is 32 per minute).
    public var dropUploadsPerMinute = 0
    /// The most list entries one page carries (the real relay: 64); tests lower it to walk several pages.
    public var dropListPageSize = 64
    /// Open owner question 6 of the relay design: refuse a device's `wk` wraps with 409 `rotation_required` while a rotation is due.
    public var dropRefusesWKWhileRotationDue = false
    /// Global queued bridge bodies (live request copies and response chunks): a post past it is 503 `overloaded` (P3-D17, 256 MiB).
    public var maxQueuedBodyBytes = 256 << 20
    /// Undelivered response bytes per device and per workspace: a host chunk past either is 429 `quota_exceeded` (P3-D17).
    public var maxResponseBytesPerDevice = 2 << 20
    public var maxResponseBytesPerWorkspace = 16 << 20
    /// Long polls (`wait` > 0) per device (429 `quota_exceeded`) and globally (503 `overloaded`) (P3-D17). The fake answers every poll
    /// at once, so only a limit of 0 (or seeded state) ever refuses; the knobs exist for the shared fixtures.
    public var maxLongPollsPerDevice = 6
    public var maxLongPolls = 4096
    /// Bridge posts per second (429 `rate_limited`, P3-D17): a device's own requests, and host chunks per (workspace, target device),
    /// never charged against the device's window (orch-relay 813b0fe). Charged only after the replay/coalescing checks.
    public var devicePostsPerSecond = 20
    public var hostPostsPerSecond = 20
    /// Replay records per device (P3-D17: 4 096 `rid_seen`), then 429 `quota_exceeded` for a new rid.
    public var maxRidRecordsPerDevice = 4096
    public init() {}
}

/// Everything the relay is, as bytes in and bytes out. It holds public keys, signed objects and ciphertext only: no `WK`,
/// `CK`, pairing secret, DEK or authority private key (host-api section 5), and route authorization never opens a bridge
/// envelope. The section 19 directory and membership routes (FakeRelayDirectory.swift) follow orch-relay's checks in order;
/// `publishCertificate`, `publishCard` and `publishRevocation` stand in for the same routes in-process (no address budgets).
/// A reply carried through a `Result` failure (WireReply is not an Error).
struct WireReplyBox: Error { let reply: WireReply; init(_ r: WireReply) { reply = r } }

public actor FakeRelay: RequestSender, InProcessDemoSender {
    var demoDropRejections = 0
    public nonisolated let context: RealmContext
    public nonisolated let origin: String
    let clock: any Clock<Duration>
    let wall: any WallClock
    let entropy: any Entropy
    let faults: any FaultPolicy
    public let limits: RelayLimits

    // MARK: state

    package struct Session: Sendable { package let kind: RelayAuth.Kind; package let id: ID16; package let expiresMs: Int64 }
    struct Stored { let idx: UInt64; let flags: UInt8; let envelope: Data; let receivedMs: Int64; let digest: Data; var arrival: UInt64 = 0 }
    struct Box { var requests: [Stored] = []; var responses: [Stored] = [] }
    struct BoxKey: Hashable { let ws: ID16; let device: ID16?; let offer: ID16?; let rid: ID16 }
    struct Window {
        var stamps: [Int64] = []
        func isActive(_ now: Int64) -> Bool { stamps.contains { $0 > now - 60_000 } }
        mutating func hit(now: Int64, limit: Int, spanMs: Int64 = 60_000) -> Bool {
            stamps.removeAll { $0 <= now - spanMs }
            guard stamps.count < limit else { return false }
            stamps.append(now); return true
        }
    }

    struct DropVersion { let descriptor: JSONValue; let parsed: DropDescriptor; var wraps: [DropWrapRecord]; var blob: Data }
    var drops: [ID16: [DropVersion]] = [:]
    var claims: [ID16: ID16] = [:]
    /// Drop change positions (protocol 19.9): per workspace counter, per object `n`, and the retire time of a retired object.
    var dropCounters: [ID16: UInt64] = [:]
    var dropN: [ID16: UInt64] = [:]
    var dropRetiredMs: [ID16: Int64] = [:]
    /// Tests: the next Drop PUTs are answered early with this refusal (nothing stored), once each.
    var dropScript: [WireReply] = []
    var dropExpirySettled: Set<ID16> = []
    /// Push registration (P3-D40, protocol 19.10): off by default, as on a relay without push (404 `not_found` on the routes).
    public var pushEnabled = false
    struct PushKey: Hashable { let device: ID16, workspace: ID16, env: String, topic: String }
    struct PushReg: Equatable { let id: ID16; let token: String }
    var pushRegs: [PushKey: PushReg] = [:]
    /// Tests: the next push answers (consumed one per request, before any other check) in place of the route.
    var pushScript: [WireReply] = []
    /// Tests: how many register requests were answered 200 / how many were refused, for asserting "refresh is free".
    var pushRegisterCalls = 0
    var pushUnregisterIDs: [ID16] = []
    var dropUploadWindows: [ID16: Window] = [:]
    private var challenges: [Data: Int64] = [:]
    package var sessions: [String: Session] = [:]
    /// Directory accounts: person id -> account `PK`.
    package var owners: [ID16: SigningPublicKey] = [:]
    package var devices: [ID16: DeviceRow] = [:]
    package var revocationRows: [ID16: RevocationRow] = [:]
    /// Accepted recovery submissions ("revocation:" / "certificate:" + SHA-256 of the exact body) -> device.
    package var recoveryReceipts: [String: ID16] = [:]
    package var rateWindows: [String: RateWindow] = [:]
    package var workspaces: [ID16: Workspace] = [:]
    var boxes: [BoxKey: Box] = [:]
    /// Device bridge mailboxes: the replay record of each `(workspace, device, rid)` (P3-D8/D9/D22), with its live bodies.
    struct RidKey: Hashable { let ws: ID16; let device: ID16; let rid: ID16 }
    var rids: [RidKey: RelayRidRecord] = [:]
    /// Pairing answers by (ws, offer, rid) and index: the full-envelope digest, kept 900 s from the first answer, so a re-post is a
    /// stored replay (identical, never stored again: P3-D27) or a `chunk_conflict` (other bytes), even after the body expired.
    private struct PairAnswer { let digest: Data; let keepUntilMs: Int64 }
    private var pairAnswers: [BoxKey: [UInt64: PairAnswer]] = [:]
    /// Per workspace: the last delivery position handed out (`n`) and the host's acknowledged cursor (P3-D10).
    private var positions: [ID16: UInt64] = [:]
    private var cursors: [ID16: UInt64] = [:]
    /// Test seed: a workspace's member devices and list epoch without a signed list (the bridge fixtures are not about lists).
    private var seededMembers: [ID16: (devices: Set<ID16>, epoch: UInt32)] = [:]
    private struct DeviceKey: Hashable { let ws: ID16; let device: ID16 }
    private var hostPosts: [DeviceKey: Window] = [:]
    private var devicePosts: [ID16: Window] = [:]
    /// Tests only: a relay that answers the next new device request with 409 `stale_epoch` after running `then` (e.g. holding the
    /// reply while time passes). With `deliver` it LIES (orch-29 Q14): it queued the request anyway, and later accepts other bytes for
    /// that rid as a new record (an honest relay answers `rid_conflict`). Without it, nothing was queued.
    private var lieNext: (epoch: UInt32, deliver: Bool, forgets: Bool, then: @Sendable () async throws -> Void)?
    private var lyingRids: Set<RidKey> = []
    /// `forgets: false`: it keeps the queued record, so other bytes for the rid are its own 409 `rid_conflict`.
    package func lieWithStaleEpochOnNextRequest(epoch: UInt32, deliver: Bool = true, forgets: Bool = true,
                                                then: @escaping @Sendable () async throws -> Void) {
        lieNext = (epoch, deliver, forgets, then)
    }
    package func ridKeys(workspace: ID16) -> Set<ID16> { Set(rids.keys.filter { $0.ws == workspace }.map(\.rid)) }
    private var pairPostsByWS: [ID16: Window] = [:]
    private var pairPostsByAddress: [String: Window] = [:]
    private var pairPollsByAddress: [String: Window] = [:]
    // The cert_pending queues (P3-D11): one state machine per request (CertQueue), by request id.
    private var certRecords: [ID16: CertQueue.Record] = [:]
    // Accounts (P3-D3): person -> account key and the digest of the request that made it; invites by SHA-256 of the code.
    private var accounts: [ID16: (pk: SigningPublicKey, digest: Data)] = [:]
    private var invites: [Data: Int64] = [:]
    private var pairPostsGlobal = Window()
    private var livePolls: [String: Int] = [:]
    private var livePollsGlobal = 0
    // Fixture seeds (package scope): a workspace key and owner without a published card, and devices known by person only.
    private var seededCards: [ID16: (wsk: SigningPublicKey, owner: ID16)] = [:]
    private var seededDevices: [ID16: (person: ID16, expiresMs: Int64?)] = [:]
    public private(set) var accepted = 0
    private var arrivals: UInt64 = 0
    /// Requests that reached `send`, for tests that prove something was refused before any request.
    public private(set) var requestsReceived = 0
    public internal(set) var rateLimited = 0

    var revoked: Set<ID16> { Set(revocationRows.keys) }

    /// A Demo relay needs the proof that a Demo setup ran (challenge C1) and a Demo context built from that very capability.
    public init(capability: DemoCapability, context: RealmContext, clock: any Clock<Duration>, wall: any WallClock,
                entropy: any Entropy = SystemEntropy(), faults: any FaultPolicy = NoFaults(), limits: RelayLimits = RelayLimits()) throws {
        guard context.realm == .demo, context.generation === capability.generation else { throw RealmViolation.wrongStore }
        self.context = context; self.origin = context.origin
        self.clock = clock; self.wall = wall; self.entropy = entropy; self.faults = faults; self.limits = limits
    }

    /// Tests only (package scope, unreachable from the app): a relay for any context, e.g. a live origin for the relay-auth
    /// vectors or a live-context refusal test. Not part of the public API, so no caller outside the package can build one.
    package init(testingContext context: RealmContext, clock: any Clock<Duration>, wall: any WallClock, entropy: any Entropy = SystemEntropy(),
                 faults: any FaultPolicy = NoFaults(), limits: RelayLimits = RelayLimits()) {
        self.context = context; self.origin = context.origin
        self.clock = clock; self.wall = wall; self.entropy = entropy; self.faults = faults; self.limits = limits
    }

    /// Reset: every table, session and mailbox is dropped. Work suspended in a fault delay refuses on resumption (the
    /// generation is invalid), so nothing it was about to write ever lands. The caller has already invalidated the generation.
    public func retire() {
        challenges = [:]; sessions = [:]; owners = [:]; devices = [:]; revocationRows = [:]; recoveryReceipts = [:]
        rateWindows = [:]
        drops = [:]; claims = [:]; dropCounters = [:]; dropN = [:]; dropRetiredMs = [:]; dropScript = []; workspaces = [:]; boxes = [:]; pairPostsByWS = [:]; pairPostsByAddress = [:]; pairPollsByAddress = [:]
        pairAnswers = [:]
        certRecords = [:]; accounts = [:]; invites = [:]; pairPostsGlobal = Window(); livePolls = [:]; livePollsGlobal = 0
        seededCards = [:]; seededDevices = [:]
        rids = [:]; positions = [:]; cursors = [:]; seededMembers = [:]; hostPosts = [:]; devicePosts = [:]; lyingRids = []
    }

    static let expiredChallengeGraceMs: Int64 = 5 * 60_000

    func checkLive() throws { try context.generation.check() }

    // MARK: directory (in-process stand-ins for the section 19.1 routes)

    /// The relay learns an owner's public key from its directory account; tests and FakeHost register it first.
    public func registerOwner(_ pk: SigningPublicKey) { owners[Identifiers.personID(pk)] = pk }

    /// `PUT /v2/devices/{device}` in-process: realm admission, then the route's checks (an account, a valid certificate, not
    /// revoked, and immutable canonical content: the same certificate again is a retry, other content `cert_conflict`).
    public func publishCertificate(_ cert: JSONValue) throws {
        try checkLive()
        guard let person = cert.object?["o"]?.object?["person_id"]?.string.flatMap({ ID16(hex: $0) }), let owner = owners[person] else {
            throw ClientError.relay(RelayRefusal(status: 403, code: .otherPerson))
        }
        let c: DeviceCertificate
        do { c = try context.admitCertificate(cert, ownerKey: owner, nowMs: wall.nowMs) }
        catch let r as Refusal { throw Self.relayError(r) }
        if revocationRows[c.deviceID] != nil { throw ClientError.relay(RelayRefusal(status: 403, code: .revoked)) }
        if let row = devices[c.deviceID] {
            guard Self.canonical(row.cert.object?["o"]) == Self.canonical(cert.object?["o"]) else {
                throw ClientError.relay(RelayRefusal(status: 409, code: .certConflict))
            }
            completeCertRequests(with: cert, person: person, owner: owner)
            return
        }
        devices[c.deviceID] = DeviceRow(verified: c, cert: cert)
        completeCertRequests(with: cert, person: person, owner: owner)
    }

    /// P3-D11: a stored certificate completes every challenged request whose challenge names exactly its two keys, device and
    /// person (`CertQueue.certificate`); any other request is left as it is.
    private func completeCertRequests(with cert: JSONValue, person: ID16, owner: SigningPublicKey) {
        let now = wall.nowMs
        for (id, var r) in certRecords where r.person == person && r.state == .challenged {
            if CertQueue.certificate(&r, signed: cert, pk: owner, nowMs: now) == .ok(CertQueue.State.signed.rawValue) { certRecords[id] = r }
        }
    }

    /// `PUT /v2/workspaces/{ws}/card` in-process: the first card (no session) or an update, with the route's verification and update
    /// rules; the same verified card again is an idempotent retry (P3-D4).
    public func publishCard(_ card: JSONValue) throws {
        try checkLive()
        do { _ = try cardPut(nil, body: ["card": card], r: nil, now: wall.nowMs, address: nil) }
        catch let f as Fail { throw ClientError.relay(RelayRefusal(status: f.status ?? Self.status(of: f.code), code: f.code)) }
    }

    /// The fake host refreshes queued rotations against relay revocations before retrying.
    func revokedDevices() -> Set<ID16> { revoked }

    /// `POST /v2/revocations` in-process (section 19.5): verified under the person's account key, then applied at once.
    public func publishRevocation(_ record: JSONValue) throws {
        try checkLive()
        guard let o = record.object?["o"]?.object, let person = o["person_id"]?.string.flatMap({ ID16(hex: $0) }),
              let device = o["device_id"]?.string.flatMap({ ID16(hex: $0) }), let owner = owners[person], let row = devices[device] else {
            throw ClientError.relay(RelayRefusal(status: 403, code: .otherPerson))
        }
        let r: Revocation
        do { r = try Revocation.verify(record, personKey: owner, cert: DeviceCertificate.Identity(deviceID: device, personID: row.personID)) }
        catch let e as Refusal { throw Self.relayError(e) }
        revoke(record, r)
    }

    /// P3-D10 holder generation: the in-process stand-in for the host-only `POST /v2/workspaces/{ws}/host/hold` (whose fixtures stay
    /// with orch-core). `gen` renews that generation (the fake renews even an expired lease nobody took over); nil asks for a new one,
    /// which an unexpired lease refuses (`holder_conflict`) unless `takeOver`.
    public func hold(workspace ws: ID16, token: String, gen: UInt64?, takeOver: Bool = false) throws -> UInt64 {
        try checkLive()
        guard try workspaceSession(token) == ws, var w = workspaces[ws], w.card != nil else {
            throw ClientError.relay(RelayRefusal(status: 401, code: .unauthenticated))
        }
        let now = wall.nowMs
        if let gen {
            guard let h = w.holder, h.gen == gen else { throw ClientError.relay(RelayRefusal(status: 409, code: .fenced)) }
        } else if let h = w.holder, h.leaseUntilMs > now, !takeOver {
            throw ClientError.relay(RelayRefusal(status: 409, code: .holderConflict))
        }
        let next = gen ?? ((w.holder?.gen ?? 0) + 1)
        w.holder = Holder(gen: next, leaseUntilMs: now + Self.holderLeaseMs)
        workspaces[ws] = w
        return next
    }

    /// The checks every use of a device's key material shares: a stored certificate of the card's owner, not revoked, valid now
    /// under the owner key (a certificate stored earlier may have expired since).
    func deviceUsable(_ device: ID16, card: CardRow) -> Bool {
        guard let row = devices[device], revocationRows[device] == nil, row.personID == card.ownerPersonID, let owner = owners[card.ownerPersonID] else {
            return false
        }
        return (try? DeviceCertificate.verify(row.cert, personKey: owner, nowMs: wall.nowMs, revoked: [])) != nil
    }

    /// Removes a device's key material and mailboxes from one workspace (revocation, or a list that no longer names it).
    func removeDevice(_ d: ID16, from ws: ID16) {
        if var w = workspaces[ws] {
            w.grants = w.grants.filter { $0.key.device != d }
            w.cardKeys[d] = nil
            workspaces[ws] = w
        }
        boxes = boxes.filter { !($0.key.ws == ws && $0.key.device == d) }
        exhaustRids(ws: ws, devices: [d])
    }

    /// A departed or revoked device keeps nothing at the relay: its request copies end, every body goes, and its chunks' re-store
    /// counts are exhausted (P3-D27), so a re-added device never gets an old answer back. The digests stay for conflict detection.
    func exhaustRids(ws: ID16, devices: Set<ID16>) {
        let now = wall.nowMs
        for (k, var r) in rids where k.ws == ws && devices.contains(k.device) {
            for i in r.copies.indices { r.copies[i].envelope = nil; r.copies[i].expiresMs = min(r.copies[i].expiresMs, now) }
            r.chunks = r.chunks.mapValues { c in
                var c = c
                c.envelope = nil; c.expiresMs = min(c.expiresMs, now); c.restores = RidStore.maxRestores
                return c
            }
            rids[k] = r
        }
    }

    static func relayError(_ r: Refusal) -> ClientError {
        let f = Fail(r)
        return .relay(RelayRefusal(status: status(of: f.code), code: f.code))
    }

    func workspaceSession(_ token: String) throws -> ID16 {
        guard let s = sessions[token], wall.nowMs < s.expiresMs, s.kind == .workspace else { throw ClientError.relay(RelayRefusal(status: 401, code: .unauthenticated)) }
        return s.id
    }

    // MARK: the cert_pending queues (P3-D11; HTTP routes below)

    /// The directory's certificate of a device (what the host polls for after asking the primary).
    public func certificate(device: ID16) -> JSONValue? { devices[device]?.cert }

    /// The relay's verified card of a workspace (the primary checks a request against it).
    public func verifiedCard(workspace: ID16) -> VerifiedCard? { workspaces[workspace]?.card?.verified }

    /// Requests the queue holds that are still open (open or challenged and unexpired): what a primary could still act on.
    public func certRequestQueueSize() -> Int { let now = wall.nowMs; return certRecords.values.filter { $0.isOpen(at: now) }.count }
    /// The queue's state of one request (tests; the host reads it through `GET /v2/cert-requests/{id}`).
    public func certRequestState(_ id: ID16) -> String? { certRecords[id].map { CertQueue.view($0, nowMs: wall.nowMs)["state"]?.string ?? "" } }

    // MARK: inspection (tests; the relay's own storage, not a client API)

    public func hasGrant(workspace: ID16, device: ID16, epoch: UInt32) -> Bool {
        workspaces[workspace]?.grants[.init(device: device, epoch: epoch)] != nil
    }
    public func grantCount(workspace: ID16, device: ID16? = nil) -> Int {
        workspaces[workspace]?.grants.keys.filter { device == nil || $0.device == device }.count ?? 0
    }
    public func hasCardKeyWrap(workspace: ID16, device: ID16, cardSeq: UInt32) -> Bool {
        workspaces[workspace]?.cardKeys[device]?[cardSeq] != nil
    }
    public func cardKeyWrapCount(workspace: ID16) -> Int { workspaces[workspace]?.cardKeys.values.reduce(0) { $0 + $1.count } ?? 0 }
    public func memberListSeq(workspace: ID16) -> Int64? { workspaces[workspace].flatMap { $0.hasList ? $0.listSeq : nil } }
    public func memberListEpoch(workspace: ID16) -> UInt32? { workspaces[workspace]?.currentEpoch }
    public func hasCertificate(_ device: ID16) -> Bool { devices[device] != nil }
    /// Request mailboxes of a device that hold a live request copy (the P3-D17 mailbox quota counts these).
    public func liveMailboxCount(workspace: ID16, device: ID16) -> Int {
        let now = wall.nowMs
        return rids.filter { $0.key.ws == workspace && $0.key.device == device && $0.value.copies.contains { now < $0.expiresMs } }.count
    }
    public func sessionCount() -> Int { sessions.count }
    /// Stored sealed bodies of every mailbox, expired or not (pruning is by time on each request, so this shows what is retained).
    public func storedBodyCount() -> Int {
        boxes.values.reduce(0) { $0 + $1.requests.count + $1.responses.count }
            + rids.values.reduce(0) { $0 + $1.copies.filter { $0.envelope != nil }.count + $1.chunks.values.filter { $0.envelope != nil }.count }
    }
    /// Mailboxes that still hold a body. A bridge rid's metadata (digests, requeue count) outlives its bodies: `ridRecordCount`.
    public func mailboxCount() -> Int {
        boxes.count + rids.values.filter { r in r.copies.contains { $0.envelope != nil } || r.chunks.values.contains { $0.envelope != nil } }.count
    }
    public func ridRecordCount() -> Int { rids.count }
    package func ridRecord(workspace: ID16, device: ID16, rid: ID16) -> RelayRidRecord? { rids[RidKey(ws: workspace, device: device, rid: rid)] }
    package func holderCursor(workspace: ID16) -> UInt64 { cursors[workspace] ?? 0 }
    public func rateWindowCount() -> Int { pairPostsByWS.count + pairPostsByAddress.count + pairPollsByAddress.count + rateWindows.count + hostPosts.count + devicePosts.count }
    public func challengeCount() -> Int { challenges.count }

    /// The host's view of its inbox (P3-D10 delivery): the live request copies above the holder's cursor, in position order,
    /// non-consuming. `after` acknowledges everything up to it (the host's durably completed prefix): the cursor only moves forward
    /// and never past the last position handed out. `arrival` is the copy's position `n`.
    public func pendingRequests(workspace: ID16, after: UInt64? = nil, token: String) throws -> [(device: ID16, rid: ID16, envelope: Data, arrival: UInt64)] {
        try checkLive()
        guard try workspaceSession(token) == workspace else { throw ClientError.relay(RelayRefusal(status: 401, code: .unauthenticated)) }
        if let after {
            guard after <= positions[workspace] ?? 0 else { throw ClientError.relay(RelayRefusal(status: 400, code: .malformed)) }
            cursors[workspace] = max(cursors[workspace] ?? 0, after)
        }
        let now = wall.nowMs, cursor = cursors[workspace] ?? 0
        return rids.filter { $0.key.ws == workspace }
            .flatMap { k, r in
                r.copies.compactMap { c in
                    c.n > cursor && now < c.expiresMs ? c.envelope.map { (device: k.device, rid: k.rid, envelope: $0, arrival: c.n) } : nil
                }
            }
            .sorted { $0.arrival < $1.arrival }
    }

    /// Epoch-0 requests of a pairing offer, for the host.
    public func pendingPairRequests(workspace: ID16, offer: ID16, token: String) throws -> [(rid: ID16, envelope: Data, arrival: UInt64)] {
        guard try workspaceSession(token) == workspace else { throw ClientError.relay(RelayRefusal(status: 401, code: .unauthenticated)) }
        let now = wall.nowMs
        return boxes.filter { $0.key.ws == workspace && $0.key.offer == offer }
            .flatMap { k, v in live(v, now).requests.map { (rid: k.rid, envelope: $0.envelope, arrival: $0.arrival) } }
    }

    func live(_ b: Box, _ now: Int64) -> Box {
        Box(requests: b.requests.filter { $0.receivedMs + limits.bodyLifetimeMs > now },
            responses: b.responses.filter { $0.receivedMs + limits.bodyLifetimeMs > now })
    }

    // MARK: faults

    func fault(_ b: FaultBoundary, _ route: String) async throws -> FaultAction {
        let a = faults.action(at: b, route: route)
        switch a {
        case .delay(let d): try await clock.sleep(for: d); try checkLive(); return .none
        case .drop, .disconnect: throw TransportError.disconnected
        default: return a
        }
    }

    // MARK: HTTP

    public func send(_ request: WireRequest) async throws -> WireReply {
        requestsReceived += 1
        do {
            let r = try request.materialized()
            try checkLive()
            prune()
            let reply = try await dispatch(r)
            _ = try await fault(.afterCommitBeforeResponse, r.method + " " + routePath(r.target))
            return reply
        } catch let v as RealmViolation { throw TransportError.realm(v) }
    }

    /// Time-based retention, applied on every request: expired bodies, boxes left empty, spent challenges, expired sessions and
    /// rate windows with nothing in them. Nothing the relay holds outlives its lifetime by more than the next request.
    private func prune() {
        let now = wall.nowMs
        // A spent-by-time challenge is kept briefly so a late login still answers `expired` rather than `unknown_challenge`.
        challenges = challenges.filter { $0.value + Self.expiredChallengeGraceMs > now }
        sessions = sessions.filter { $0.value.expiresMs > now }
        for (k, b) in boxes {
            let l = live(b, now)
            boxes[k] = (l.requests.isEmpty && l.responses.isEmpty) ? nil : l
        }
        // Bridge rids: a body goes when it expires (never resurrected); the record (digests, requeues) at `keep_until_ms`.
        for (k, var r) in rids {
            if now >= r.keepUntilMs { rids[k] = nil; continue }
            for i in r.copies.indices where now >= r.copies[i].expiresMs { r.copies[i].envelope = nil }
            for (idx, c) in r.chunks where now >= c.expiresMs { r.chunks[idx]?.envelope = nil }
            rids[k] = r
        }
        hostPosts = hostPosts.filter { $0.value.isActive(now) }
        devicePosts = devicePosts.filter { $0.value.isActive(now) }
        pairPostsByWS = pairPostsByWS.filter { $0.value.isActive(now) }
        pairAnswers = pairAnswers.compactMapValues { m in
            let live = m.filter { now < $0.value.keepUntilMs }
            return live.isEmpty ? nil : live
        }
        pairPostsByAddress = pairPostsByAddress.filter { $0.value.isActive(now) }
        pairPollsByAddress = pairPollsByAddress.filter { $0.value.isActive(now) }
        rateWindows = rateWindows.filter { $0.value.endMs > now }
        // cert_pending records stay until expires_ms + 60 s, whatever their state (P3-D11)
        certRecords = certRecords.filter { $0.value.isRetained(at: now) }
        invites = invites.filter { $0.value > now }
    }

    func routePath(_ target: String) -> String { String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }

    func json(_ status: Int, _ fields: [String: JSONValue] = [:], headers: [String: String] = [:]) -> WireReply {
        var h = headers; h["content-type"] = "application/json"
        return try! WireReply(status: status, headers: h, body: (try? canonicalJSON(.object(fields))) ?? Data())
    }
    /// Protocol section 14 relay error: `{"error": code}` and nothing else.
    func refuse(_ status: Int, _ code: RelayRefusal.Code, headers: [String: String] = [:], extra: [String: JSONValue] = [:]) -> WireReply {
        var h = headers; h["content-type"] = "application/json"
        var o = extra; o["error"] = .string(code.rawValue)
        return try! WireReply(status: status, headers: h, body: (try? canonicalJSON(.object(o))) ?? Data())
    }
    /// `Retry-After` is integer delta-seconds, rounded up (section 19.6), never below 1.
    private func retryAfter(untilMs: Int64, now: Int64) -> [String: String] {
        ["retry-after": String(max(1, (max(untilMs - now, 0) + 999) / 1000))]
    }
    func limited(_ now: Int64) -> WireReply {
        rateLimited += 1
        return refuse(429, .rateLimited, headers: ["retry-after": String(max(1, limits.retryAfterSeconds))])
    }

    private func dispatch(_ r: WireRequest) async throws -> WireReply {
        let (path, query) = split(r.target)
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "" else { return refuse(400, .malformed) }
        let seg = Array(parts.dropFirst())
        if seg.first == String(HostAPI.base.dropFirst()) { return try await route(r, Array(seg.dropFirst()), query) }
        return refuse(404, .notFound)
    }

    private func split(_ target: String) -> (String, String?) {
        guard let i = target.firstIndex(of: "?") else { return (target, nil) }
        return (String(target[..<i]), String(target[target.index(after: i)...]))
    }

    /// Strict query: `name=value` pairs, known names only, each at most once, no escapes. `nil` means malformed.
    func queryItems(_ q: String?, allowed: Set<String>) -> [String: String]? {
        guard let q else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&", omittingEmptySubsequences: false) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2, allowed.contains(String(kv[0])), out[String(kv[0])] == nil, !kv[1].contains("%"), !kv[1].isEmpty else { return nil }
            out[String(kv[0])] = String(kv[1])
        }
        return out
    }

    private func route(_ r: WireRequest, _ s: [String], _ query: String?) async throws -> WireReply {
        switch (r.method, s.count) {
        case ("POST", 2) where s[0] == "session" && s[1] == "challenge": return try challenge(r, query)
        case ("POST", 2) where s[0] == "session" && s[1] == "login": return try login(r, query)
        case ("POST", 2) where s[0] == "session" && s[1] == "logout": return logout(r, query)
        case ("POST", 1) where s[0] == "accounts": return account(r, query)
        case (_, 3) where s[0] == "persons" && s[2] == "cert-requests": return r.method == "POST" ? postCertRequest(r, person: s[1], query) : (r.method == "GET" ? pollCertRequests(r, person: s[1], query) : refuse(404, .notFound))
        case ("GET", 2) where s[0] == "cert-requests": return certRequestReply(r, id: s[1], query)
        case ("POST", 3) where s[0] == "cert-requests" && (s[2] == "challenge" || s[2] == "rejection"): return primaryPost(r, id: s[1], kind: s[2], query)
        case (_, 5) where s[0] == "workspaces" && s[2] == "pair": return try await pairing(r, ws: s[1], offer: s[3], rid: s[4], query)
        case (_, 4) where s[0] == "workspaces" && s[2] == "bridge": return try await bridge(r, ws: s[1], rid: s[3], query)
        case (_, _) where Self.directoryRoute(r.method, s) != nil:
            let d = Self.directoryRoute(r.method, s)!
            return try await directory(r, route: d.route, ident: d.ident, query)
        // /v2/drop/...: every Drop route is under /v2 (P3-D1, protocol 19.9); the unprefixed section 10.5/10.6 spellings are gone.
        case (_, _) where s.first == "drop": return try dropRoute(r, s, query)
        case ("POST", 2) where s[0] == "push" && (s[1] == "register" || s[1] == "unregister"): return pushRoute(r, s[1], query)
        default: return refuse(404, .notFound)
        }
    }

    // MARK: sessions (protocol section 12.2)

    /// JSON cap of the session routes (section 19.1): refused 413 before the body is parsed.
    static let sessionJSONCap = 16 << 10

    private func body(_ r: WireRequest, fields: Set<String>) -> [String: JSONValue]? {
        guard let v = try? StrictJSON.parse(r.body, maxBytes: HostAPI.maxJSONBytes), let o = v.object else { return nil }
        return o
    }

    private func challenge(_ r: WireRequest, _ query: String?) throws -> WireReply {
        if r.body.count > Self.sessionJSONCap { return refuse(413, .tooLarge) }
        guard queryItems(query, allowed: []) != nil, let o = body(r, fields: []), o.isEmpty else { return refuse(400, .malformed) }
        let now = wall.nowMs
        challenges = challenges.filter { $0.value > now }
        if challenges.count >= limits.maxOutstandingChallenges {
            // the cap frees when the earliest outstanding challenge expires: Retry-After is that remaining time, rounded up
            rateLimited += 1
            return refuse(429, .rateLimited, headers: retryAfter(untilMs: challenges.values.min() ?? now, now: now))
        }
        let c = entropy.bytes(32)
        let expires = now + RelayAuth.challengeMs
        challenges[c] = expires
        return json(200, ["challenge": .string(B64U.encode(c)), "expires_ms": .int(expires)])
    }

    private func login(_ r: WireRequest, _ query: String?) throws -> WireReply {
        if r.body.count > Self.sessionJSONCap { return refuse(413, .tooLarge) }
        guard queryItems(query, allowed: []) != nil, let o = body(r, fields: []) else { return refuse(400, .malformed) }
        let challenge = o["challenge"]?.string.flatMap { B64U.decode($0, length: 32) }
        // The challenge is consumed on every attempt, including one that is malformed in another field.
        guard Set(o.keys) == ["challenge", "kind", "id", "sig"], let challenge, let kind = o["kind"]?.string,
              let id = o["id"]?.string.flatMap({ ID16(hex: $0) }), let sig = o["sig"]?.string.flatMap({ B64U.decode($0, length: 64) }) else {
            if let challenge { challenges[challenge] = nil }
            return refuse(400, .malformed)
        }
        let now = wall.nowMs
        let k: RelayAuth.Kind? = kind.utf8.elementsEqual("device".utf8) ? .device : (kind.utf8.elementsEqual("workspace".utf8) ? .workspace : nil)
        let pub: SigningPublicKey? = k == .device ? devices[id]?.info?.signingKey : (k == .workspace ? workspaces[id]?.card?.wsk : nil)
        let result: (status: Int, error: String?)
        if let pub {
            let rr = RelayAuth.check(challenges: &challenges, origin: origin, challenge: challenge, kind: kind, id: id, signature: sig, pub: pub, nowMs: now)
            result = (rr.status, rr.error)
        } else if let exp = challenges.removeValue(forKey: challenge) {
            // Unknown identity: same order, same answers, and the challenge is still used up (no identity oracle).
            result = now >= exp ? (401, "expired") : (k == nil ? (400, "malformed") : (401, "bad_signature"))
        } else {
            result = (401, "unknown_challenge")
        }
        if let e = result.error {
            return refuse(result.status, RelayRefusal.Code(rawValue: e) ?? .malformed)
        }
        if k == .device {
            // A revoked device gets no session (it reads its revocation record on the session-less route); neither does an expired
            // or invalid certificate. Revocation is only revealed to the holder of the key: the signature has already verified.
            if revoked.contains(id) { return refuse(403, .revoked) }
            guard let row = devices[id], let owner = owners[row.personID] else { return refuse(401, .badSignature) }
            if let e = row.expiresMs, now >= e { return refuse(400, .certExpired) }
            do { _ = try DeviceCertificate.verify(row.cert, personKey: owner, nowMs: now, revoked: []) }
            catch let e as Refusal { let st = Self.relayError(e); if case .relay(let rr) = st { return refuse(rr.status, rr.code) } }
            // At most eight live tokens per device (section 19.1): a ninth login is refused until the earliest expires. The
            // challenge is consumed and no existing token is touched.
            let live = sessions.values.filter { $0.kind == .device && $0.id == id && $0.expiresMs > now }
            if live.count >= limits.maxLiveTokensPerDevice, let first = live.map(\.expiresMs).min() {
                rateLimited += 1
                return refuse(429, .quotaExceeded, headers: retryAfter(untilMs: first, now: now))
            }
        }
        let token = B64U.encode(entropy.bytes(32))
        let expires = now + limits.sessionLifetimeMs
        sessions[token] = Session(kind: k!, id: id, expiresMs: expires)
        sessions = sessions.filter { $0.value.expiresMs > now }
        return json(200, ["token": .string(token), "expires_ms": .int(expires)])
    }

    /// Idempotent: 200 `{}` for a live, expired, unknown or already-logged-out token alike (section 19.6).
    private func logout(_ r: WireRequest, _ query: String?) -> WireReply {
        if r.body.count > Self.sessionJSONCap { return refuse(413, .tooLarge) }
        guard queryItems(query, allowed: []) != nil, let o = body(r, fields: []), o.isEmpty else { return refuse(400, .malformed) }
        guard let h = r.header("authorization"), h.hasPrefix("Bearer "), h.count > 7 else { return refuse(401, .unauthenticated) }
        sessions[String(h.dropFirst(7))] = nil
        return json(200)
    }

    // MARK: test seeding (package scope: the fixture replay states preconditions the relay would otherwise reach by history)

    package func seedChallenge(_ challenge: Data, expiresMs: Int64) { challenges[challenge] = expiresMs }
    package func seedSession(token: String, kind: RelayAuth.Kind, id: ID16, expiresMs: Int64) {
        sessions[token] = Session(kind: kind, id: id, expiresMs: expiresMs)
    }
    package func seedRevoked(_ device: ID16) {
        revocationRows[device] = RevocationRow(record: .null, personID: devices[device]?.personID ?? device, reason: "lost",
                                               cursor: (revocationRows.values.map(\.cursor).max() ?? 0) + 1)
    }
    /// Any other precondition: the test edits the relay's tables directly, inside the actor.
    package func seed(_ body: @Sendable (isolated FakeRelay) throws -> Void) rethrows { try body(self) }
    /// A workspace's `WSK` and owner as if its card had been published (the card itself is not needed by the routes seeded).
    package func seedWorkspaceKey(_ ws: ID16, wsk: SigningPublicKey, owner: ID16, replacingCard: Bool = false) { seededCards[ws] = (wsk, owner) }
    /// No account for `person` (its key unknown to the relay).
    package func forgetAccount(_ person: ID16) { owners[person] = nil; accounts[person] = nil }
    /// A device of `person` as the directory would know it from a stored certificate (`expiresMs` past = an expired certificate).
    package func seedDevice(_ device: ID16, person: ID16, expiresMs: Int64? = nil) { seededDevices[device] = (person, expiresMs) }
    /// The account key the relay trusts for `person` (a different key than the signer's makes its signatures `bad_signature`).
    package func seedAccount(person: ID16, key: SigningPublicKey, digest: Data = Data()) {
        owners[person] = key
        if !digest.isEmpty { accounts[person] = (key, digest) }
    }
    /// The workspace's holder lease (P3-D10) as if its host had taken `generation` (unexpired unless `leaseUntilMs` says otherwise).
    package func seedHolder(_ ws: ID16, generation: UInt64, leaseUntilMs: Int64 = .max) {
        workspaces[ws, default: Workspace()].holder = Holder(gen: generation, leaseUntilMs: leaseUntilMs)
    }
    package func seedCertRecord(_ r: CertQueue.Record) { certRecords[r.requestID] = r }
    package func certRecord(_ id: ID16) -> CertQueue.Record? { certRecords[id] }
    package func challengedCertRequestCount() -> Int { certRecords.values.filter { $0.challenge != nil }.count }
    package func seedPairResponse(ws: ID16, offer: ID16, rid: ID16, envelope: Data) {
        let (parsed, _) = parseEnvelope(envelope, direction: .toDevice, maxSize: limits.maxPairEnvelope)
        guard let parsed else { return }
        store(BoxKey(ws: ws, device: nil, offer: offer, rid: rid), parsed: parsed, envelope: envelope, response: true)
    }
    package func accountKey(_ person: ID16) -> SigningPublicKey? { accounts[person]?.pk }

    /// A single-use invite (the admin CLI's `orch-relay invite create`, P3-D3): the relay keeps only its SHA-256 and expiry.
    public func createInvite(_ code: String, ttlMs: Int64 = 7 * 24 * 3600 * 1000) {
        invites[Data(SHA256.hash(data: Data(code.utf8)))] = saturatingAdd(wall.nowMs, ttlMs)
    }
    /// Tests: reads the relay's tables inside the actor.
    package func inspect<T: Sendable>(_ body: @Sendable (isolated FakeRelay) -> T) -> T { body(self) }
    package func seedMembership(workspace: ID16, devices: Set<ID16>, epoch: UInt32) { seededMembers[workspace] = (devices, epoch) }
    package func seedRid(workspace: ID16, device: ID16, rid: ID16, record: RelayRidRecord) {
        rids[RidKey(ws: workspace, device: device, rid: rid)] = record
        positions[workspace] = max(positions[workspace] ?? 0, record.copies.map(\.n).max() ?? 0)
    }
    /// Tests: the host's answer for a rid never reached the relay (e.g. the host crashed before posting it). Its chunk digests go,
    /// so a later answer (such as `already_done(unknown)`) can be stored for the same indexes.
    package func forgetResponses(workspace: ID16, device: ID16, rid: ID16) { rids[RidKey(ws: workspace, device: device, rid: rid)]?.chunks = [:] }
    /// The host's acknowledged delivery cursor (P3-D10), as if it had polled that far.
    package func seedHolderCursor(workspace: ID16, cursor: UInt64) {
        cursors[workspace] = cursor; positions[workspace] = max(positions[workspace] ?? 0, cursor)
    }
    package var liveSessionTokens: Set<String> { Set(sessions.keys) }
    package var outstandingChallenges: Set<Data> { Set(challenges.keys) }

    func authenticate(_ r: WireRequest) -> Session? {
        guard let h = r.header("authorization"), h.hasPrefix("Bearer "), let s = sessions[String(h.dropFirst(7))], wall.nowMs < s.expiresMs else { return nil }
        return s
    }

    /// Current membership and non-revocation (section 8.9 and host-api section 3), and the D session's certificate, re-checked at
    /// request time (section 19.4: an expired certificate is 400 `cert_expired`).
    func memberGate(_ s: Session, ws: ID16) -> WireReply? {
        guard s.kind == .device else { return refuse(403, .notEligible) }
        if revoked.contains(s.id) { return refuse(403, .revoked) }
        if let exp = directoryEntry(s.id)?.expiresMs, wall.nowMs >= exp { return refuse(400, .certExpired) }
        guard memberDevices(ws)?.contains(s.id) == true else { return refuse(403, .notEligible) }
        return nil
    }

    /// The devices of the workspace's current list (or of a test seed) and that list's epoch.
    private func memberDevices(_ ws: ID16) -> Set<ID16>? {
        if let seeded = seededMembers[ws] { return seeded.devices }
        guard let w = workspaces[ws], w.hasList else { return nil }
        return Set(w.members.keys)
    }
    private func listEpoch(_ ws: ID16) -> UInt32? { seededMembers[ws]?.epoch ?? workspaces[ws]?.currentEpoch }

    // MARK: accounts, the cert_pending queues and their principals (section 19.1, 19.3; P3-D3, P3-D11)

    static let cap16 = 16 << 10
    static let cap64 = 64 << 10

    /// Strict JSON with exactly `fields` (section 2.3; the caller has checked the route's whole-body cap).
    private func exactBody(_ r: WireRequest, _ fields: Set<String>) -> [String: JSONValue]? {
        guard let v = try? StrictJSON.parse(r.body, maxBytes: HostAPI.maxJSONBytes), let o = v.object,
              o.keys.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 < 0x80 } }), Set(o.keys) == fields else { return nil }
        return o
    }

    /// Section 19.6: a signed object of another deployment suite is 400 `wrong_suite`, before any context check.
    private func otherSuite(_ v: JSONValue?) -> Bool { v.flatMap { SignedObject.suite(of: $0) }.map { $0 != Int64(Suite2.id) } ?? false }

    private func status(of code: RelayRefusal.Code) -> Int {
        switch code {
        case .expired: 410
        case .certExpired: 400
        case .tooLarge: 413
        default: RelayRefusal.statuses(of: code).min() ?? 400
        }
    }

    private func refuse(_ code: RelayRefusal.Code) -> WireReply {
        let st = status(of: code)
        return refuse(st, code, headers: st == 429 || st == 503 ? ["retry-after": String(max(1, limits.retryAfterSeconds))] : [:])
    }

    /// The card's `WSK` and owner of a workspace (a published card, or a fixture seed).
    private func cardKeys(_ ws: ID16) -> (wsk: SigningPublicKey, owner: ID16)? {
        if let s = seededCards[ws] { return s }                  // a fixture seed stands in for (or over) the published card
        if let c = workspaces[ws]?.card { return (c.wsk, c.ownerPersonID) }
        return nil
    }

    /// The person of a device the directory knows and the expiry of its certificate.
    private func directoryEntry(_ device: ID16) -> (person: ID16, expiresMs: Int64?)? {
        if let d = devices[device] { return (d.personID, d.expiresMs) }
        return seededDevices[device]
    }

    /// A current device of `person`: known to the directory for that person, unrevoked, certificate unexpired.
    private func isCurrentDevice(_ d: ID16, of person: ID16) -> Bool {
        guard let e = directoryEntry(d), e.person == person, !revoked.contains(d) else { return false }
        return e.expiresMs.map { wall.nowMs < $0 } ?? true
    }

    /// A device session re-checked now (section 19.4 P3-D2): 401 without a live token, 403 `not_eligible` for another kind of
    /// principal, 403 `revoked`, 400 `cert_expired`. Returns the device and its person.
    private func devicePrincipal(_ r: WireRequest) -> Result<(device: ID16, person: ID16), WireReplyBox> {
        guard let s = authenticate(r) else { return .failure(WireReplyBox(refuse(401, .unauthenticated))) }
        guard s.kind == .device else { return .failure(WireReplyBox(refuse(403, .notEligible))) }
        if revoked.contains(s.id) { return .failure(WireReplyBox(refuse(403, .revoked))) }
        guard let e = directoryEntry(s.id) else { return .failure(WireReplyBox(refuse(403, .notEligible))) }
        if let exp = e.expiresMs, wall.nowMs >= exp { return .failure(WireReplyBox(refuse(400, .certExpired))) }
        return .success((s.id, e.person))
    }

    /// `Orch-Holder` (P3-D10, W(g)) on the pairing answer and cert-request routes: the same strict lease as the section 19 routes
    /// (`FakeRelayDirectory.fence`). A missing header, or one that does not name the current generation of an unexpired lease, is
    /// 409 `fenced` (a host must hold first, orch-29 Q9); an unparsable one 400 `malformed`.
    private func fence(_ r: WireRequest, ws: ID16) -> WireReply? {
        do { try fence(r, ws, now: wall.nowMs); return nil }
        catch let f as Fail { return refuse(f.status ?? Self.status(of: f.code), f.code) }
        catch { return refuse(409, .fenced) }
    }

    /// Concurrent polls (section 19.4 P3-D17): refused, never queued or evicted. Pair with `endPoll`.
    private func beginPoll(_ principal: String) -> WireReply? {
        if livePollsGlobal >= limits.maxConcurrentPollsGlobal { return refuse(.overloaded) }
        if livePolls[principal, default: 0] >= limits.maxConcurrentPollsPerPrincipal { rateLimited += 1; return refuse(.quotaExceeded) }
        livePollsGlobal += 1; livePolls[principal, default: 0] += 1
        return nil
    }
    private func endPoll(_ principal: String) {
        livePollsGlobal = max(0, livePollsGlobal - 1)
        let n = (livePolls[principal] ?? 1) - 1
        livePolls[principal] = n > 0 ? n : nil
    }

    private func waitQuery(_ query: String?, extra: Set<String> = []) -> [String: String]? {
        guard let q = queryItems(query, allowed: extra.union(["wait"])) else { return nil }
        if let w = q["wait"] { guard let v = HostAPI.parseDecimal(w), v <= 25 else { return nil } }
        return q
    }

    /// `POST /v2/accounts` (P3-D3): an account from a single-use invite, the first device certificate (`PK`-signed) and a fresh
    /// login signature by that device. The exact same request again is 200 by digest; the invite and the digest commit together.
    private func account(_ r: WireRequest, _ query: String?) -> WireReply {
        if r.body.count > Self.cap64 { return refuse(413, .tooLarge) }
        guard queryItems(query, allowed: []) != nil, let o = exactBody(r, ["invite", "pk_pub", "device_cert", "challenge", "sig"]) else { return refuse(400, .malformed) }
        if otherSuite(o["device_cert"]) { return refuse(400, .wrongSuite) }
        guard let invite = o["invite"]?.string, !invite.isEmpty, invite.utf8.count <= 256,
              let pk = o["pk_pub"]?.string.flatMap({ B64U.decode($0, length: Suite2.publicKeyLength) }).flatMap({ try? SigningPublicKey(x963: $0) }),
              let cert = o["device_cert"], cert.object != nil,
              let challenge = o["challenge"]?.string.flatMap({ B64U.decode($0, length: 32) }),
              let sig = o["sig"]?.string.flatMap({ B64U.decode($0, length: Suite2.signatureLength) }) else { return refuse(400, .malformed) }
        let person = Identifiers.personID(pk)
        let digest = Data(SHA256.hash(data: r.body))
        if let a = accounts[person], a.digest == digest { return json(200, ["person_id": .string(person.hex)]) }     // exact retry
        let now = wall.nowMs
        // the challenge is consumed on every attempt from here on (section 12.2 order: known, unexpired)
        guard let exp = challenges.removeValue(forKey: challenge) else { return refuse(401, .unknownChallenge) }
        guard now < exp else { return refuse(401, .expired) }
        let inviteKey = Data(SHA256.hash(data: Data(invite.utf8)))
        guard let iexp = invites[inviteKey], now < iexp else { return refuse(403, .notEligible) }
        let dc: DeviceCertificate
        do { dc = try DeviceCertificate.verify(cert, personKey: pk, nowMs: now) }
        catch Refusal.certExpired { return refuse(400, .certExpired) } catch { return refuse(400, .certInvalid) }
        guard let bytes = try? RelayAuth.signedBytes(origin: origin, challenge: challenge, kind: .device, id: dc.deviceID),
              Signature.verify(dc.signingKey, signature: sig, message: bytes) else { return refuse(401, .badSignature) }
        guard accounts[person] == nil, owners[person] == nil || owners[person] == pk else { return refuse(409, .accountExists) }
        if revoked.contains(dc.deviceID) { return refuse(403, .revoked) }
        invites[inviteKey] = nil
        accounts[person] = (pk, digest); owners[person] = pk
        devices[dc.deviceID] = DeviceRow(verified: dc, cert: cert)
        return json(200, ["person_id": .string(person.hex)])
    }

    /// `POST /v2/persons/{person}/cert-requests` (W(g), card owner = person): the host's `cert_request` into the queue.
    private func postCertRequest(_ r: WireRequest, person p: String, _ query: String?) -> WireReply {
        if r.body.count > Self.cap64 { return refuse(413, .tooLarge) }
        guard let person = ID16(hex: p), queryItems(query, allowed: []) != nil else { return refuse(400, .malformed) }
        guard let s = authenticate(r) else { return refuse(401, .unauthenticated) }
        guard s.kind == .workspace else { return refuse(403, .notEligible) }
        if let f = fence(r, ws: s.id) { return f }
        guard let o = exactBody(r, ["request"]), let request = o["request"] else { return refuse(400, .malformed) }
        if otherSuite(request) { return refuse(400, .wrongSuite) }
        guard let card = cardKeys(s.id), card.owner == person else { return refuse(403, .notEligible) }
        guard owners[person] != nil else { return refuse(403, .otherPerson) }            // no account for the person
        switch CertQueue.admit(request, wsk: card.wsk, workspace: s.id, owner: person, isAddressee: { isCurrentDevice($0, of: person) },
                               records: &certRecords, nowMs: wall.nowMs) {
        case .ok(let id): return json(200, ["request_id": .string(id)])
        case .refuse(let c): return refuse(c)
        }
    }

    /// `GET /v2/persons/{person}/cert-requests?wait=s` (D(p), addressee only): the open requests addressed to this device.
    private func pollCertRequests(_ r: WireRequest, person p: String, _ query: String?) -> WireReply {
        guard let person = ID16(hex: p), waitQuery(query) != nil else { return refuse(400, .malformed) }
        let me: (device: ID16, person: ID16)
        switch devicePrincipal(r) { case .success(let x): me = x; case .failure(let b): return b.reply }
        guard me.person == person else { return refuse(403, .notEligible) }
        let principal = "device:" + me.device.hex
        if let busy = beginPoll(principal) { return busy }
        defer { endPoll(principal) }
        let now = wall.nowMs
        let mine = certRecords.values.filter { $0.primary == me.device && $0.person == person && $0.isOpen(at: now) }
            .sorted { $0.requestID.hex < $1.requestID.hex }.map(\.request)
        return json(200, ["requests": .array(mine)])
    }

    /// `POST /v2/cert-requests/{id}/challenge` and `/rejection` (D(p), the addressee): verified under the account `PK`.
    private func primaryPost(_ r: WireRequest, id: String, kind: String, _ query: String?) -> WireReply {
        if r.body.count > Self.cap16 { return refuse(413, .tooLarge) }
        guard let rid = ID16(hex: id), queryItems(query, allowed: []) != nil else { return refuse(400, .malformed) }
        let me: (device: ID16, person: ID16)
        switch devicePrincipal(r) { case .success(let x): me = x; case .failure(let b): return b.reply }
        guard let o = exactBody(r, [kind]), let signed = o[kind] else { return refuse(400, .malformed) }
        if otherSuite(signed) { return refuse(400, .wrongSuite) }
        let now = wall.nowMs
        guard var rec = certRecords[rid], rec.isRetained(at: now) else { return refuse(404, .notFound) }
        guard rec.person == me.person else { return refuse(403, .notEligible) }
        guard rec.primary == me.device else { return refuse(403, .notForThisDevice) }
        guard let pk = owners[rec.person] else { return refuse(403, .otherPerson) }
        let out = kind == "challenge" ? CertQueue.challenge(&rec, signed: signed, pk: pk, nowMs: now) : CertQueue.reject(&rec, signed: signed, pk: pk, nowMs: now)
        certRecords[rid] = rec                      // an expiry observed here is a state change too
        switch out {
        case .ok: return json(200)
        case .refuse(let c): return refuse(c)
        }
    }

    /// `GET /v2/cert-requests/{id}` (W, the requester): `{state, challenge, cert, rejection}`, null when absent.
    private func certRequestReply(_ r: WireRequest, id: String, _ query: String?) -> WireReply {
        guard let rid = ID16(hex: id), queryItems(query, allowed: []) != nil else { return refuse(400, .malformed) }
        guard let s = authenticate(r) else { return refuse(401, .unauthenticated) }
        guard s.kind == .workspace else { return refuse(403, .notEligible) }
        let now = wall.nowMs
        guard let rec = certRecords[rid], rec.isRetained(at: now) else { return refuse(404, .notFound) }
        guard rec.workspace == s.id else { return refuse(403, .notEligible) }
        return json(200, CertQueue.view(rec, nowMs: now))
    }

    /// Bytes queued in the mailboxes of one workspace's pairing offers, or of every mailbox.
    private func queuedBytes(pairOf ws: ID16? = nil) -> Int {
        boxes.filter { ws == nil || ($0.key.ws == ws && $0.key.offer != nil) }.values
            .reduce(0) { $0 + $1.requests.reduce(0) { $0 + $1.envelope.count } + $1.responses.reduce(0) { $0 + $1.envelope.count } }
    }

    // MARK: mailboxes (protocol sections 8.9 and 8.3)

    private func chunkReply(_ stored: [Stored], rid: ID16, after: UInt64?, route: String) async throws -> WireReply {
        var items = stored.filter { after == nil || $0.idx > after! }.sorted { $0.idx < $1.idx }
        var seen = Set<UInt64>(); items = items.filter { seen.insert($0.idx).inserted }
        switch try await fault(.pollDelivery, route) {
        case .duplicate: items = items.flatMap { [$0, $0] }
        case .reorder: items.reverse()
        case .corrupt:
            if let f = items.first {
                var e = f.envelope; if !e.isEmpty { e[e.count - 1] ^= 0x01 }
                items[0] = Stored(idx: f.idx, flags: f.flags, envelope: e, receivedMs: f.receivedMs, digest: f.digest)
            }
        default: break
        }
        let chunks: [JSONValue] = items.map {
            .object(["id": .string(rid.hex), "idx": .int(Int64($0.idx)), "last": .bool($0.flags & 1 != 0), "stream": .bool($0.flags & 2 != 0),
                     "envelope": .string(B64U.encode($0.envelope))])
        }
        return json(200, ["chunks": .array(chunks)])
    }

    private struct Parsed { let parts: Bridge.Parts; var header: Bridge.Header { parts.header } }

    /// Header shape common to every envelope the relay queues: magic, version, suite, direction, flags, seq bound.
    private func parseEnvelope(_ data: Data, direction: Bridge.Direction, maxSize: Int) -> (Parsed?, WireReply?) {
        guard data.count <= maxSize, let p = try? Bridge.Parts(envelope: data) else { return (nil, refuse(400, .malformed)) }
        let h = p.header
        guard h.magic == Bridge.magic, h.version == Bridge.version else { return (nil, refuse(400, .malformed)) }
        guard h.suite == Suite2.id else { return (nil, refuse(400, .wrongSuite)) }
        guard h.direction == direction.rawValue else { return (nil, refuse(400, .malformed)) }
        let f = h.flags
        switch direction {
        case .toHost: guard f & ~Bridge.Flags.stream.rawValue == 0 else { return (nil, refuse(400, .malformed)) }
        case .toDevice:
            guard f & ~0x07 == 0, f & Bridge.Flags.refusal.rawValue == 0 || f & Bridge.Flags.last.rawValue != 0 else { return (nil, refuse(400, .malformed)) }
        }
        // The cursor travels as a JSON integer: nothing above 2^53-1 can be queued or polled.
        guard h.seq <= UInt64(maxSafeInt) else { return (nil, refuse(400, .malformed)) }
        return (Parsed(parts: p), nil)
    }

    private func afterCursor(_ query: String?) -> (UInt64?, Bool) {
        guard let q = queryItems(query, allowed: ["after"]) else { return (nil, false) }
        guard let a = q["after"] else { return (nil, true) }
        guard let v = HostAPI.parseDecimal(a) else { return (nil, false) }
        return (v, true)
    }

    private func store(_ key: BoxKey, parsed: Parsed, envelope: Data, response: Bool) {
        let now = wall.nowMs
        var box = live(boxes[key] ?? Box(), now)
        let digest = parsed.parts.digest
        arrivals += 1
        let item = Stored(idx: parsed.header.seq, flags: parsed.header.flags, envelope: envelope, receivedMs: now, digest: digest, arrival: arrivals)
        if response {
            if !box.responses.contains(where: { $0.digest == digest }) { box.responses.append(item) }
        } else if let i = box.requests.firstIndex(where: { $0.digest == digest }) {
            box.requests[i] = item          // an identical re-send is a new arrival: the host answers it from its record
        } else { box.requests.append(item) }
        boxes[key] = box
    }

    /// `wait` is an integer 0...25 (section 19.6); `after` an exclusive decimal position. Anything else is malformed.
    private func pollQuery(_ query: String?) -> (after: UInt64?, wait: Int, ok: Bool) {
        guard let q = queryItems(query, allowed: ["after", "wait"]) else { return (nil, 0, false) }
        var after: UInt64?, wait = 0
        if let a = q["after"] { guard let v = HostAPI.parseDecimal(a) else { return (nil, 0, false) }; after = v }
        if let w = q["wait"] { guard let v = HostAPI.parseDecimal(w), v <= 25 else { return (nil, 0, false) }; wait = Int(v) }
        return (after, wait, true)
    }

    // Plain loops: the nested reduce form exceeds Xcode 16.4's type-checker time limit.
    private func liveBodyBytes(_ now: Int64) -> Int {
        var total = 0
        for r in rids.values {
            for c in r.copies where now < c.expiresMs { total += c.envelope?.count ?? 0 }
            for c in r.chunks.values where now < c.expiresMs { total += c.envelope?.count ?? 0 }
        }
        for box in boxes.values {
            let l = live(box, now)
            for q in l.requests { total += q.envelope.count }
            for p in l.responses { total += p.envelope.count }
        }
        return total
    }

    private func bridge(_ r: WireRequest, ws: String, rid: String, _ query: String?) async throws -> WireReply {
        // A fault delay on a POST happens before any authoritative check; from here to the store there is no suspension, so
        // membership, revocation, epoch and quota are decided under the state the write happens in.
        let a: FaultAction = r.method == "POST" ? try await fault(.beforeQueue, "POST bridge") : .none
        guard let s = authenticate(r) else { return refuse(401, .unauthenticated) }
        guard let wsID = ID16(hex: ws), let ridID = ID16(hex: rid) else { return refuse(400, .malformed) }
        switch r.method {
        case "POST":
            guard queryItems(query, allowed: []) != nil else { return refuse(400, .malformed) }
            if s.kind == .device, let lie = lieNext {
                lieNext = nil
                if lie.deliver {
                    let reply = devicePost(r, s, ws: wsID, rid: ridID, duplicate: false)
                    guard reply.status == 202 else { return reply }
                    if lie.forgets { lyingRids.insert(RidKey(ws: wsID, device: s.id, rid: ridID)) }
                }
                try await lie.then()
                return refuse(409, .staleEpoch, extra: ["epoch": .int(Int64(lie.epoch))])
            }
            return s.kind == .workspace ? hostPost(r, s, ws: wsID, rid: ridID, duplicate: a == .duplicate)
                                        : devicePost(r, s, ws: wsID, rid: ridID, duplicate: a == .duplicate)
        case "GET":
            let (after, wait, ok) = pollQuery(query)
            guard ok else { return refuse(400, .malformed) }
            if let denied = memberGate(s, ws: wsID) { return denied }
            if wait > 0 {
                if limits.maxLongPollsPerDevice <= 0 { rateLimited += 1; return refuse(429, .quotaExceeded, headers: fixedRetry) }
                if limits.maxLongPolls <= 0 { return refuse(503, .overloaded, headers: fixedRetry) }
            }
            let now = wall.nowMs
            let record = rids[RidKey(ws: wsID, device: s.id, rid: ridID)]
            let stored = (record?.chunks ?? [:]).compactMap { idx, c -> Stored? in
                guard now < c.expiresMs, let e = c.envelope else { return nil }
                return Stored(idx: idx, flags: c.flags, envelope: e, receivedMs: c.expiresMs - limits.bodyLifetimeMs, digest: c.digest)
            }
            return try await chunkReply(stored, rid: ridID, after: after, route: "GET bridge")
        default: return refuse(404, .notFound)
        }
    }

    private var fixedRetry: [String: String] { ["retry-after": String(max(1, limits.retryAfterSeconds))] }

    /// A device request (P3-D8/D9, section 19.3). Order: session and membership, shape, replay store, epoch; budgets only when
    /// something would be queued. An identical resend of a known rid is coalesced (202) while a live copy is undelivered, else
    /// requeued at most once per 10 s (429 with the remaining interval) and at most 8 times (then 409 `retry_exhausted`).
    private func devicePost(_ r: WireRequest, _ s: Session, ws: ID16, rid: ID16, duplicate: Bool) -> WireReply {
        if r.body.count > Bridge.maxRequest { return refuse(400, .tooLarge) }
        let (parsed, err) = parseEnvelope(r.body, direction: .toHost, maxSize: Bridge.maxRequest)
        if let err { return err }
        let h = parsed!.header
        guard h.workspace == ws, h.rid == rid, h.epoch >= 1 else { return refuse(400, .malformed) }   // epoch 0 belongs to the pairing route
        // The header's device must be the session's device (section 8.9), then membership and revocation.
        guard h.device == s.id else { return refuse(403, .notForThisDevice) }
        if let denied = memberGate(s, ws: ws) { return denied }
        let now = wall.nowMs, key = RidKey(ws: ws, device: s.id, rid: rid)
        if lyingRids.contains(key), let old = rids[key], old.digest != RidStore.digest(r.body) {
            rids[key] = nil; lyingRids.remove(key)          // the liar forgets what it delivered (and its answers)
        }
        var record = rids[key]
        let isNew = record.map { now >= $0.keepUntilMs } ?? true
        let result = RidStore.request(&record, raw: r.body, header: h, epoch: listEpoch(ws) ?? 0, nowMs: now, cursor: cursors[ws] ?? 0,
                                      copyLifetimeMs: limits.bodyLifetimeMs, nextN: (positions[ws] ?? 0) + 1)
        // The device's own post rate is charged after the replay and coalescing checks (identical resends are free) and, for a new
        // rid, before its epoch check (orch-relay bridge.post).
        switch result {
        case .queued, .staleEpoch:
            guard devicePosts[s.id, default: Window()].hit(now: now, limit: limits.devicePostsPerSecond, spanMs: 1_000) else {
                rateLimited += 1; return refuse(429, .rateLimited, headers: ["retry-after": "1"])
            }
        default: break
        }
        if case .queued = result, isNew, rids.keys.filter({ $0.device == s.id && $0 != key }).count >= limits.maxRidRecordsPerDevice {
            rateLimited += 1; return refuse(429, .quotaExceeded, headers: fixedRetry)
        }
        switch result {
        case .coalesced: accepted += 1; return json(202)
        case .ridConflict: return refuse(409, .ridConflict)
        case .retryExhausted: return refuse(409, .retryExhausted)
        case .staleEpoch(let e): return refuse(409, .staleEpoch, extra: ["epoch": .int(Int64(e))])
        case .rateLimited(let after): rateLimited += 1; return refuse(429, .rateLimited, headers: ["retry-after": String(max(1, after))])
        case .queued(let n):
            let liveBoxes = rids.filter { $0.key.ws == ws && $0.key.device == s.id && $0.key.rid != rid && $0.value.copies.contains { now < $0.expiresMs } }
            if liveBoxes.count >= limits.maxLiveMailboxesPerDevice { rateLimited += 1; return refuse(429, .quotaExceeded, headers: fixedRetry) }
            if liveBodyBytes(now) + r.body.count > limits.maxQueuedBodyBytes { return refuse(503, .overloaded, headers: fixedRetry) }
            rids[key] = record
            positions[ws] = n
            if duplicate {     // a duplicated delivery of the same POST is an identical resend: coalesced, nothing new queued
                var again = rids[key]
                _ = RidStore.request(&again, raw: r.body, header: h, epoch: listEpoch(ws) ?? 0, nowMs: now, cursor: cursors[ws] ?? 0)
            }
            accepted += 1
            return json(202)
        }
    }

    /// A host response chunk (P3-D22, section 19.3): only for a known, unexpired rid of a current, unrevoked member, at the
    /// request's epoch (an old-epoch chunk only as `LAST | REFUSAL` or as a byte-identical stored replay, which never refreshes a TTL).
    private func hostPost(_ r: WireRequest, _ s: Session, ws: ID16, rid: ID16, duplicate: Bool) -> WireReply {
        guard s.id == ws else { return refuse(403, .notEligible) }
        if let fenced = fence(r, ws: ws) { return fenced }
        if r.body.count > Bridge.maxChunk { return refuse(400, .tooLarge) }
        let (parsed, err) = parseEnvelope(r.body, direction: .toDevice, maxSize: Bridge.maxChunk)
        if let err { return err }
        let h = parsed!.header
        guard h.workspace == ws, h.rid == rid, h.epoch >= 1 else { return refuse(400, .malformed) }
        // The recipient is checked now, after any fault delay and with no suspension before the store: a device revoked or
        // removed while the host's response was in flight gets no mailbox.
        if revoked.contains(h.device) { return refuse(403, .revoked) }
        guard memberDevices(ws)?.contains(h.device) == true else { return refuse(403, .notEligible) }
        let now = wall.nowMs
        let key = RidKey(ws: ws, device: h.device, rid: rid)
        var record = rids[key]
        // The target's remaining undelivered-response budget (P3-D17): stored and re-stored chunks are charged to it.
        func undelivered(_ match: (RidKey) -> Bool) -> Int {
            rids.filter { match($0.key) }.values.reduce(0) { $0 + $1.chunks.values.reduce(0) { $0 + (now < $1.expiresMs ? $1.envelope?.count ?? 0 : 0) } }
        }
        let deviceRoom: Int = limits.maxResponseBytesPerDevice - undelivered({ $0.ws == ws && $0.device == h.device })
        let workspaceRoom: Int = limits.maxResponseBytesPerWorkspace - undelivered({ $0.ws == ws })
        let room: Int = min(deviceRoom, workspaceRoom)
        let result = RidStore.chunk(&record, raw: r.body, header: h, epoch: listEpoch(ws) ?? 0, nowMs: now,
                                    chunkLifetimeMs: limits.bodyLifetimeMs, room: max(room, 0))
        // Charged per (workspace, target device) after the known-rid, stored-replay and re-store checks, before the epoch rule
        // (orch-relay 813b0fe, d3816ea): a live duplicate or an old-epoch data re-post is free.
        switch result {
        case .stored, .restored, .staleEpoch, .quotaExceeded:
            guard hostPosts[DeviceKey(ws: ws, device: h.device), default: Window()].hit(now: now, limit: limits.hostPostsPerSecond, spanMs: 1_000) else {
                rateLimited += 1; return refuse(429, .rateLimited, headers: fixedRetry)
            }
        default: break
        }
        switch result {
        case .replay: return json(202)
        case .expired: return refuse(410, .expired)
        case .chunkConflict: return refuse(409, .chunkConflict)
        case .staleEpoch(let e): return refuse(409, .staleEpoch, extra: ["epoch": .int(Int64(e))])
        case .quotaExceeded: rateLimited += 1; return refuse(429, .quotaExceeded, headers: fixedRetry)
        case .retryExhausted: return refuse(409, .retryExhausted)
        case .stored, .restored:
            if liveBodyBytes(now) + r.body.count > limits.maxQueuedBodyBytes { return refuse(503, .overloaded, headers: fixedRetry) }
            rids[key] = record
            _ = duplicate          // a duplicated delivery is a byte-identical stored replay: nothing more to store
            accepted += 1
            return json(202)
        }
    }

    private func pairing(_ r: WireRequest, ws: String, offer: String, rid: String, _ query: String?) async throws -> WireReply {
        // ORB2 keeps its binary cap and status (section 19.6): 400 `too_large`, before anything is parsed.
        if r.method == "POST", r.body.count > limits.maxPairEnvelope { return refuse(400, .tooLarge) }
        guard let wsID = ID16(hex: ws), let offerID = ID16(hex: offer), let ridID = ID16(hex: rid) else { return refuse(400, .malformed) }
        // As on the bridge route: a POST's fault delay precedes every check, rate budget and write.
        let a: FaultAction = r.method == "POST" ? try await fault(.beforeQueue, "POST pair") : .none
        let now = wall.nowMs
        let key = BoxKey(ws: wsID, device: nil, offer: offerID, rid: ridID)
        switch r.method {
        case "POST":
            guard queryItems(query, allowed: []) != nil else { return refuse(400, .malformed) }
            // the suite gate precedes context checks; a suite-1 envelope has another layout, so only its first eight bytes are read
            if r.body.count >= 8, r.body.prefix(4) == Bridge.magic, r.body[r.body.startIndex + 7] != Suite2.id { return refuse(400, .wrongSuite) }
            let session = authenticate(r)
            if r.header("authorization") != nil && session == nil { return refuse(401, .unauthenticated) }
            // Direction 2 is the host's answer: it needs the workspace's W(g) session. Direction 1 is an unauthenticated epoch-0 request.
            let response = r.body.count >= 6 && r.body[r.body.startIndex + 5] == Bridge.Direction.toDevice.rawValue
            if response {
                guard let session else { return refuse(401, .unauthenticated) }
                guard session.kind == .workspace, session.id == wsID else { return refuse(403, .notEligible) }
                if let f = fence(r, ws: wsID) { return f }
                // Before any charge (orch-relay d3816ea `restorable`): pairing answers are never stored again. An identical re-post is
                // a stored replay, other bytes for an answered index a conflict, whether or not the body has expired.
                if let p = try? Bridge.Parts(envelope: r.body), let seen = pairAnswers[key]?[p.header.seq], now < seen.keepUntilMs {
                    return seen.digest == RidStore.digest(r.body) ? json(202) : refuse(409, .chunkConflict)
                }
            }
            guard pairPostsGlobal.hit(now: now, limit: limits.pairPostsPerMinuteGlobal) else { return limited(now) }
            if !response {
                guard pairPostsByWS[wsID, default: Window()].hit(now: now, limit: limits.pairPostsPerMinutePerWorkspace),
                      pairPostsByAddress[r.clientAddress, default: Window()].hit(now: now, limit: limits.pairPostsPerMinutePerAddress)
                else { return limited(now) }
            }
            if queuedBytes() + r.body.count > limits.maxQueuedBytesGlobal { return refuse(.overloaded) }
            if queuedBytes(pairOf: wsID) + r.body.count > limits.maxQueuedPairBytesPerWorkspace { rateLimited += 1; return refuse(.quotaExceeded) }
            let (parsed, err) = parseEnvelope(r.body, direction: response ? .toDevice : .toHost, maxSize: limits.maxPairEnvelope)
            if let err { return err }
            let h = parsed!.header
            guard h.workspace == wsID, h.rid == ridID, h.stream == offerID, h.epoch == 0 else { return refuse(400, .malformed) }
            guard cardKeys(wsID) != nil else { return refuse(401, .unknownWorkspace) }
            if response { pairAnswers[key, default: [:]][h.seq] = PairAnswer(digest: RidStore.digest(r.body), keepUntilMs: now + RidStore.restoreWindowMs) }
            store(key, parsed: parsed!, envelope: r.body, response: response)
            if a == .duplicate {
                store(key, parsed: parsed!, envelope: r.body, response: response)
                _ = pairPostsByWS[wsID, default: Window()].hit(now: now, limit: Int.max)
            }
            accepted += 1
            return json(202)
        case "GET":
            guard let q = waitQuery(query, extra: ["after"]) else { return refuse(400, .malformed) }
            var after: UInt64?
            if let s = q["after"] { guard let v = HostAPI.parseDecimal(s) else { return refuse(400, .malformed) }; after = v }
            let principal = "address:" + r.clientAddress
            if let busy = beginPoll(principal) { return busy }
            defer { endPoll(principal) }
            guard pairPollsByAddress[r.clientAddress, default: Window()].hit(now: now, limit: limits.pairPollsPerMinutePerAddress) else { return limited(now) }
            let box = live(boxes[key] ?? Box(), now)
            return try await chunkReply(box.responses, rid: ridID, after: after, route: "GET pair")
        default: return refuse(404, .notFound)
        }
    }
}
