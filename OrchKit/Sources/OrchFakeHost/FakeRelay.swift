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
    public var maxDropVersions = 1024
    public var maxDropBytes = 100 << 20
    public init() {}
}

/// Everything the relay is, as bytes in and bytes out. It holds public keys, signed objects and ciphertext only: no `WK`,
/// `CK`, pairing secret, DEK or authority private key (host-api section 5), and route authorization never opens a bridge
/// envelope. The `publish*`, `putGrant` and `putCardKeyWrap` methods stand in for orch-publish and the host's authenticated
/// uploads (protocol section 12.1 is not modelled); each runs the relay's full checks.
/// A reply carried through a `Result` failure (WireReply is not an Error).
struct WireReplyBox: Error { let reply: WireReply; init(_ r: WireReply) { reply = r } }

public actor FakeRelay: RequestSender {
    private var demoDropRejections = 0
    public nonisolated let context: RealmContext
    public nonisolated let origin: String
    let clock: any Clock<Duration>
    let wall: any WallClock
    let entropy: any Entropy
    let faults: any FaultPolicy
    public let limits: RelayLimits

    // MARK: state

    private struct Session { let kind: RelayAuth.Kind; let id: ID16; let expiresMs: Int64 }
    private struct Stored { let idx: UInt64; let flags: UInt8; let envelope: Data; let receivedMs: Int64; let digest: Data; var arrival: UInt64 = 0 }
    private struct Box { var requests: [Stored] = []; var responses: [Stored] = [] }
    private struct BoxKey: Hashable { let ws: ID16; let device: ID16?; let offer: ID16?; let rid: ID16 }
    private struct Window {
        var stamps: [Int64] = []
        func isActive(_ now: Int64) -> Bool { stamps.contains { $0 > now - 60_000 } }
        mutating func hit(now: Int64, limit: Int) -> Bool {
            stamps.removeAll { $0 <= now - 60_000 }
            guard stamps.count < limit else { return false }
            stamps.append(now); return true
        }
    }
    private struct Workspace {
        var card: VerifiedCard?
        var cardJSON: JSONValue?
        var abandonedEpoch: UInt32 = 0
        var list: MemberList?
        var listJSON: JSONValue?
        var grants: [MemberList.Directory.GrantKey: JSONValue] = [:]
        var cardKeys: [ID16: [UInt32: Data]] = [:]
    }

    private struct DropVersion { let descriptor: JSONValue; let parsed: DropDescriptor; var wraps: [DropWrapRecord]; let blob: Data }
    private var drops: [ID16: [DropVersion]] = [:]
    private var claims: [ID16: ID16] = [:]
    private var challenges: [Data: Int64] = [:]
    private var sessions: [String: Session] = [:]
    private var owners: [ID16: SigningPublicKey] = [:]
    private var certs: [ID16: JSONValue] = [:]
    private var certInfo: [ID16: DeviceCertificate] = [:]
    private var revoked: Set<ID16> = []
    private var revocations: [ID16: JSONValue] = [:]
    private var workspaces: [ID16: Workspace] = [:]
    private var boxes: [BoxKey: Box] = [:]
    private var pairPostsByWS: [ID16: Window] = [:]
    private var pairPostsByAddress: [String: Window] = [:]
    private var pairPollsByAddress: [String: Window] = [:]
    // The cert_pending queues (P3-D11): one state machine per request (CertQueue), by request id.
    private var certRecords: [ID16: CertQueue.Record] = [:]
    // Accounts (P3-D3): person -> account key and the digest of the request that made it; invites by SHA-256 of the code.
    private var accounts: [ID16: (pk: SigningPublicKey, digest: Data)] = [:]
    private var invites: [Data: Int64] = [:]
    // Holder generations (P3-D10) of workspaces whose host took one. A workspace without one takes unfenced host writes (see
    // `fence`): the FakeHost does not hold yet (host_hold.json stays with the host-only PR2 leftovers).
    private var holders: [ID16: UInt64] = [:]
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
    public private(set) var rateLimited = 0

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
        challenges = [:]; sessions = [:]; owners = [:]; certs = [:]; certInfo = [:]; revoked = []; revocations = [:]
        drops = [:]; claims = [:]; workspaces = [:]; boxes = [:]; pairPostsByWS = [:]; pairPostsByAddress = [:]; pairPollsByAddress = [:]
        certRecords = [:]; accounts = [:]; invites = [:]; holders = [:]; pairPostsGlobal = Window(); livePolls = [:]; livePollsGlobal = 0
        seededCards = [:]; seededDevices = [:]
    }

    static let expiredChallengeGraceMs: Int64 = 5 * 60_000

    private func checkLive() throws { try context.generation?.check() }

    // MARK: directory (stand-in for orch-publish)

    /// The relay learns an owner's public key from a card or a certificate it verifies; tests and FakeHost register it first.
    public func registerOwner(_ pk: SigningPublicKey) { owners[Identifiers.personID(pk)] = pk }

    public func publishCertificate(_ cert: JSONValue) throws {
        try checkLive()
        guard let person = cert.object?["o"]?.object?["person_id"]?.string.flatMap({ ID16(hex: $0) }), let owner = owners[person] else {
            throw ClientError.relay(RelayRefusal(status: 403, code: .otherPerson))
        }
        let c: DeviceCertificate
        do { c = try context.admitCertificate(cert, ownerKey: owner, nowMs: wall.nowMs) }
        catch let r as Refusal { throw Self.relayError(r) }
        certs[c.deviceID] = cert; certInfo[c.deviceID] = c
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

    public func publishCard(_ card: JSONValue) throws {
        try checkLive()
        guard let person = card.object?["o"]?.object?["owner_person_id"]?.string.flatMap({ ID16(hex: $0) }), let owner = owners[person] else {
            throw ClientError.relay(RelayRefusal(status: 403, code: .otherPerson))
        }
        do {
            let v = try Card.verify(card, ownerKey: owner)
            // The card names the relay it lives on; a relay accepts only its own origin (section 7.1 form, byte exact).
            guard v.relayURL == origin else { throw Refusal.malformed }
            try Card.checkRelayUpdate(previous: workspaces[v.workspace]?.card?.head, next: v)
            workspaces[v.workspace, default: Workspace()].card = v
            workspaces[v.workspace, default: Workspace()].cardJSON = card
        } catch let r as Refusal { throw Self.relayError(r) }
    }

    /// The fake host refreshes queued rotations against relay revocations before retrying.
    func revokedDevices() -> Set<ID16> { revoked }

    public func publishRevocation(_ record: JSONValue) throws {
        try checkLive()
        guard let o = record.object?["o"]?.object, let person = o["person_id"]?.string.flatMap({ ID16(hex: $0) }),
              let device = o["device_id"]?.string.flatMap({ ID16(hex: $0) }), let owner = owners[person], let cert = certInfo[device] else {
            throw ClientError.relay(RelayRefusal(status: 403, code: .otherPerson))
        }
        do { _ = try Revocation.verify(record, personKey: owner, cert: cert.identity) }
        catch let r as Refusal { throw Self.relayError(r) }
        revoked.insert(device); revocations[device] = record
        // A revoked device keeps nothing at the relay: no session, no grant or card-key wrap, no queued request (host-api section 3).
        sessions = sessions.filter { !($0.value.kind == .device && $0.value.id == device) }
        for ws in Array(workspaces.keys) { removeDevice(device, from: ws) }
    }

    /// The checks every host upload of key material to a device shares, run immediately before the write with no suspension in
    /// between: a certificate that exists, belongs to the card's owner, has not been revoked and is unexpired now, checked against
    /// the owner key (a certificate stored earlier may have expired since it was published).
    private func checkUploadTarget(_ device: ID16, card: VerifiedCard) throws {
        guard let info = certInfo[device], let cert = certs[device] else { throw ClientError.relay(RelayRefusal(status: 403, code: .notEligible)) }
        guard !revoked.contains(device) else { throw ClientError.relay(RelayRefusal(status: 403, code: .revoked)) }
        guard info.personID == card.ownerPersonID, let owner = owners[card.ownerPersonID] else {
            throw ClientError.relay(RelayRefusal(status: 403, code: .otherPerson))
        }
        do { _ = try DeviceCertificate.verify(cert, personKey: owner, nowMs: wall.nowMs, revoked: []) }
        catch let r as Refusal { throw Self.relayError(r) }
    }

    /// A WK grant uploaded by the workspace's host (section 7.3). The sealed key is opaque here. Membership is not required at
    /// upload time: section 7.2 puts grants before the list that names the device, so the list check (`missing_grant`) is where
    /// grants and members meet.
    public func putGrant(_ grant: JSONValue, token: String) async throws {
        // The fault point (and any delay) comes first, before a single authoritative check: after it there is no suspension,
        // so the session, card, certificate, revocation and epoch it checks are the ones the write happens under.
        _ = try await fault(.beforeGrantPublication, "putGrant")
        try checkLive()
        let ws = try workspaceSession(token)
        guard let w = workspaces[ws], let card = w.card else { throw ClientError.relay(RelayRefusal(status: 401, code: .unknownWorkspace)) }
        let o: [String: JSONValue]
        do { o = try SignedObject.parse(grant).verify(kind: .wkGrant, key: card.wsk) } catch let r as Refusal { throw Self.relayError(r) }
        guard Set(o.keys) == ["v", "suite", "kind", "workspace_id", "device_id", "epoch", "sealed"],
              let gws = o["workspace_id"]?.string.flatMap({ ID16(hex: $0) }), let dev = o["device_id"]?.string.flatMap({ ID16(hex: $0) }),
              let epoch = o["epoch"]?.int, epoch >= 1, epoch <= Int64(UInt32.max),
              o["sealed"]?.string.flatMap({ B64U.decode($0) }).map({ $0.count <= WKGrant.maxSealedBytes }) == true else {
            throw ClientError.relay(RelayRefusal(status: 400, code: .malformed))
        }
        guard gws == ws else { throw ClientError.relay(RelayRefusal(status: 409, code: .otherWorkspace)) }
        try checkUploadTarget(dev, card: card)
        // A grant can advance by one from the current list or the last explicitly retired rotation attempt.
        let current = max(w.list?.epoch ?? 0, w.abandonedEpoch)
        guard UInt32(epoch) > w.abandonedEpoch, UInt32(epoch) <= current &+ 1 else { throw ClientError.relay(RelayRefusal(status: 409, code: .badEpoch)) }
        workspaces[ws]?.grants[.init(device: dev, epoch: UInt32(epoch))] = grant
    }

    /// Provisional host-api v0 retirement: authenticated, bounded, and idempotent.
    private func abandonRotation(_ r: WireRequest, workspace: String, query: String?) -> WireReply {
        guard let session = authenticate(r), session.kind == .workspace else { return refuse(401, .unauthenticated) }
        guard let ws = ID16(hex: workspace), ws == session.id else { return refuse(403, .otherWorkspace) }
        guard query == nil, var w = workspaces[ws], let card = w.card else { return refuse(400, .malformed) }
        let epoch: UInt32
        do {
            epoch = try RotationAbandon.verify(StrictJSON.parse(r.body, maxBytes: HostAPI.maxJSONBytes), workspace: ws, key: card.wsk)
        } catch Refusal.badSignature { return refuse(403, .badSignature) }
        catch { return refuse(400, .malformed) }
        let current = max(w.list?.epoch ?? 0, w.abandonedEpoch)
        guard epoch == current || (current < UInt32.max && epoch == current + 1) else { return refuse(409, .badEpoch) }
        w.abandonedEpoch = max(w.abandonedEpoch, epoch)
        w.grants = w.grants.filter { $0.key.epoch != epoch }
        workspaces[ws] = w
        return json(200, [:])
    }

    /// `CK` for one card sequence, sealed to one device (host-api section 3). Only for certified, unrevoked, unexpired devices of
    /// the card's owner. No suspension: the checks and the write are one step.
    public func putCardKeyWrap(device: ID16, cardSeq: UInt32, sealed: Data, token: String) throws {
        try checkLive()
        let ws = try workspaceSession(token)
        guard let card = workspaces[ws]?.card else { throw ClientError.relay(RelayRefusal(status: 401, code: .unknownWorkspace)) }
        guard cardSeq >= 1, cardSeq <= card.cardSeq, sealed.count <= 1024, !sealed.isEmpty else {
            throw ClientError.relay(RelayRefusal(status: 400, code: .malformed))
        }
        try checkUploadTarget(device, card: card)
        workspaces[ws]?.cardKeys[device, default: [:]][cardSeq] = sealed
    }

    /// Section 7.2 as the relay applies it: signature, shape, then checks 3 to 9 with the directory it holds.
    public func publishMemberList(_ list: JSONValue, token: String) throws {
        try checkLive()
        let ws = try workspaceSession(token)
        guard let w = workspaces[ws], let card = w.card, let owner = owners[card.ownerPersonID] else {
            throw ClientError.relay(RelayRefusal(status: 401, code: .unknownWorkspace))
        }
        do {
            let parsed = try MemberList.verify(list, wsk: card.wsk)
            let dir = MemberList.Directory(ownerKey: owner, certs: certs, revoked: revoked, grants: Set(w.grants.keys))
            // Provisional skip-epoch amendment; real relay use requires §7.2/reference/vector updates.
            try parsed.checkRelayUpdate(cardWorkspace: ws, previous: w.list, directory: dir, nowMs: wall.nowMs, abandonedThrough: w.abandonedEpoch)
            let left = Set((w.list?.members ?? []).map(\.deviceID)).subtracting(parsed.members.map(\.deviceID))
            workspaces[ws]?.list = parsed; workspaces[ws]?.listJSON = list
            for d in left { removeDevice(d, from: ws) }
        } catch let r as Refusal { throw Self.relayError(r) }
    }

    /// On acceptance of a list the relay deletes the mailboxes, grants and (later) push subscriptions of departed devices.
    private func removeDevice(_ d: ID16, from ws: ID16) {
        if var w = workspaces[ws] {
            w.grants = w.grants.filter { $0.key.device != d }
            w.cardKeys[d] = nil
            workspaces[ws] = w
        }
        boxes = boxes.filter { !($0.key.ws == ws && $0.key.device == d) }
    }

    static func relayError(_ r: Refusal) -> ClientError {
        let status: Int
        switch r {
        case .badSignature: status = 401
        case .revoked, .otherPerson, .scopeExceeded, .notForThisDevice: status = 403
        case .otherWorkspace, .wskChanged, .delegationChanged, .staleCard, .wxkChangedWithoutVersion, .badWxkVersion, .staleList,
             .badEpoch, .rotationRequired, .missingGrant: status = 409
        default: status = 400
        }
        let code = RelayRefusal.Code(rawValue: r.rawValue) ?? .malformed
        return .relay(RelayRefusal(status: status, code: code))
    }

    private func workspaceSession(_ token: String) throws -> ID16 {
        guard let s = sessions[token], wall.nowMs < s.expiresMs, s.kind == .workspace else { throw ClientError.relay(RelayRefusal(status: 401, code: .unauthenticated)) }
        return s.id
    }

    // MARK: the cert_pending queues (P3-D11; HTTP routes below)

    /// The directory's certificate of a device (what the host polls for after asking the primary).
    public func certificate(device: ID16) -> JSONValue? { certs[device] }

    /// The relay's verified card of a workspace (the primary checks a request against it).
    public func verifiedCard(workspace: ID16) -> VerifiedCard? { workspaces[workspace]?.card }

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
    public func memberListSeq(workspace: ID16) -> Int64? { workspaces[workspace]?.list?.listSeq }
    public func hasCertificate(_ device: ID16) -> Bool { certs[device] != nil }
    public func liveMailboxCount(workspace: ID16, device: ID16) -> Int {
        let now = wall.nowMs
        return boxes.filter { $0.key.ws == workspace && $0.key.device == device && !live($0.value, now).requests.isEmpty }.count
    }
    public func sessionCount() -> Int { sessions.count }
    /// Stored sealed bodies of every mailbox, expired or not (pruning is by time on each request, so this shows what is retained).
    public func storedBodyCount() -> Int { boxes.values.reduce(0) { $0 + $1.requests.count + $1.responses.count } }
    public func mailboxCount() -> Int { boxes.count }
    public func rateWindowCount() -> Int { pairPostsByWS.count + pairPostsByAddress.count + pairPollsByAddress.count }
    public func challengeCount() -> Int { challenges.count }

    /// The host's view of its inbox: requests waiting for it, non-consuming, until their body lifetime ends.
    public func pendingRequests(workspace: ID16, token: String) throws -> [(device: ID16, rid: ID16, envelope: Data, arrival: UInt64)] {
        try checkLive()
        guard try workspaceSession(token) == workspace else { throw ClientError.relay(RelayRefusal(status: 401, code: .unauthenticated)) }
        let now = wall.nowMs
        return boxes.filter { $0.key.ws == workspace && $0.key.device != nil && $0.key.offer == nil }
            .flatMap { k, v in live(v, now).requests.map { (device: k.device!, rid: k.rid, envelope: $0.envelope, arrival: $0.arrival) } }
    }

    /// Epoch-0 requests of a pairing offer, for the host.
    public func pendingPairRequests(workspace: ID16, offer: ID16, token: String) throws -> [(rid: ID16, envelope: Data, arrival: UInt64)] {
        guard try workspaceSession(token) == workspace else { throw ClientError.relay(RelayRefusal(status: 401, code: .unauthenticated)) }
        let now = wall.nowMs
        return boxes.filter { $0.key.ws == workspace && $0.key.offer == offer }
            .flatMap { k, v in live(v, now).requests.map { (rid: k.rid, envelope: $0.envelope, arrival: $0.arrival) } }
    }

    private func live(_ b: Box, _ now: Int64) -> Box {
        Box(requests: b.requests.filter { $0.receivedMs + limits.bodyLifetimeMs > now },
            responses: b.responses.filter { $0.receivedMs + limits.bodyLifetimeMs > now })
    }

    // MARK: faults

    private func fault(_ b: FaultBoundary, _ route: String) async throws -> FaultAction {
        let a = faults.action(at: b, route: route)
        switch a {
        case .delay(let d): try await clock.sleep(for: d); try checkLive(); return .none
        case .drop, .disconnect: throw TransportError.disconnected
        default: return a
        }
    }

    // MARK: HTTP

    public func send(_ r: WireRequest) async throws -> WireReply {
        requestsReceived += 1
        do {
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
        pairPostsByWS = pairPostsByWS.filter { $0.value.isActive(now) }
        pairPostsByAddress = pairPostsByAddress.filter { $0.value.isActive(now) }
        pairPollsByAddress = pairPollsByAddress.filter { $0.value.isActive(now) }
        // cert_pending records stay until expires_ms + 60 s, whatever their state (P3-D11)
        certRecords = certRecords.filter { $0.value.isRetained(at: now) }
        invites = invites.filter { $0.value > now }
    }

    private func routePath(_ target: String) -> String { String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }

    private func json(_ status: Int, _ fields: [String: JSONValue] = [:], headers: [String: String] = [:]) -> WireReply {
        var h = headers; h["content-type"] = "application/json"
        return try! WireReply(status: status, headers: h, body: (try? canonicalJSON(.object(fields))) ?? Data())
    }
    /// Protocol section 14 relay error: `{"error": code}` and nothing else.
    private func refuse(_ status: Int, _ code: RelayRefusal.Code, headers: [String: String] = [:], extra: [String: JSONValue] = [:]) -> WireReply {
        var h = headers; h["content-type"] = "application/json"
        var o = extra; o["error"] = .string(code.rawValue)
        return try! WireReply(status: status, headers: h, body: (try? canonicalJSON(.object(o))) ?? Data())
    }
    /// `Retry-After` is integer delta-seconds, rounded up (section 19.6), never below 1.
    private func retryAfter(untilMs: Int64, now: Int64) -> [String: String] {
        ["retry-after": String(max(1, (max(untilMs - now, 0) + 999) / 1000))]
    }
    private func limited(_ now: Int64) -> WireReply {
        rateLimited += 1
        return refuse(429, .rateLimited, headers: ["retry-after": String(max(1, limits.retryAfterSeconds))])
    }

    private func dispatch(_ r: WireRequest) async throws -> WireReply {
        let (path, query) = split(r.target)
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "" else { return refuse(400, .malformed) }
        let seg = Array(parts.dropFirst())
        if seg.first == String(HostAPI.base.dropFirst()) { return try await route(r, Array(seg.dropFirst()), query) }
        // TODO(orch-4e): the Drop PUT/claim routes keep their protocol section 10.6 spelling here and the Drop GET/list routes now sit under
        // /v2; protocol-v2 section 19 does not list Drop (or push registration) yet. Open question for orch-4e: final Drop paths.
        if seg.first == "drop" { return try dropRoute(r, seg, query, protocolRoute: true) }
        return refuse(404, .notFound)
    }

    private func split(_ target: String) -> (String, String?) {
        guard let i = target.firstIndex(of: "?") else { return (target, nil) }
        return (String(target[..<i]), String(target[target.index(after: i)...]))
    }

    /// Strict query: `name=value` pairs, known names only, each at most once, no escapes. `nil` means malformed.
    private func queryItems(_ q: String?, allowed: Set<String>) -> [String: String]? {
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
        case ("POST", 2) where s[0] == "drop" && s[1] == "list": return try dropRoute(r, s, query)
        case ("POST", 1) where s[0] == "accounts": return account(r, query)
        case (_, 3) where s[0] == "persons" && s[2] == "cert-requests": return r.method == "POST" ? postCertRequest(r, person: s[1], query) : (r.method == "GET" ? pollCertRequests(r, person: s[1], query) : refuse(404, .notFound))
        case ("GET", 2) where s[0] == "cert-requests": return certRequestReply(r, id: s[1], query)
        case ("POST", 3) where s[0] == "cert-requests" && (s[2] == "challenge" || s[2] == "rejection"): return primaryPost(r, id: s[1], kind: s[2], query)
        case (_, 5) where s[0] == "workspaces" && s[2] == "pair": return try await pairing(r, ws: s[1], offer: s[3], rid: s[4], query)
        case (_, 4) where s[0] == "workspaces" && s[2] == "bridge": return try await bridge(r, ws: s[1], rid: s[3], query)
        case ("POST", 3) where s[0] == "workspaces" && s[2] == "rotation-abandon": return abandonRotation(r, workspace: s[1], query: query)
        case ("GET", 3) where s[0] == "workspaces" && s[2] == "grants": return try grants(r, ws: s[1], query)
        case ("GET", 3) where s[0] == "workspaces" && s[2] == "members": return try memberListReply(r, ws: s[1], query)
        case ("GET", 3) where s[0] == "workspaces" && s[2] == "card": return try cardReply(r, ws: s[1], query)
        case ("GET", 3) where s[0] == "workspaces" && s[2] == "card-key": return try cardKeyReply(r, ws: s[1], query)
        case ("GET", 3) where s[0] == "devices" && s[2] == "revocation": return try revocationReply(r, device: s[1], query)
        case (_, _) where s.first == "drop": return try dropRoute(r, s, query)
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
        let pub: SigningPublicKey? = k == .device ? certInfo[id]?.signingKey : (k == .workspace ? workspaces[id]?.card?.wsk : nil)
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
            do { _ = try DeviceCertificate.verify(certs[id]!, personKey: owners[certInfo[id]!.personID]!, nowMs: now, revoked: []) }
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
    package func seedRevoked(_ device: ID16) { revoked.insert(device) }
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
    package func seedHolder(_ ws: ID16, generation: UInt64) { holders[ws] = generation }
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
    package var liveSessionTokens: Set<String> { Set(sessions.keys) }
    package var outstandingChallenges: Set<Data> { Set(challenges.keys) }

    private func authenticate(_ r: WireRequest) -> Session? {
        guard let h = r.header("authorization"), h.hasPrefix("Bearer "), let s = sessions[String(h.dropFirst(7))], wall.nowMs < s.expiresMs else { return nil }
        return s
    }

    /// Current membership and non-revocation (section 8.9 and host-api section 3).
    private func memberGate(_ s: Session, ws: ID16) -> WireReply? {
        guard s.kind == .device else { return refuse(403, .notEligible) }
        if revoked.contains(s.id) { return refuse(403, .revoked) }
        guard workspaces[ws]?.list?.members.contains(where: { $0.deviceID == s.id }) == true else { return refuse(403, .notEligible) }
        return nil
    }

    // MARK: fetch routes

    private func grants(_ r: WireRequest, ws: String, _ query: String?) throws -> WireReply {
        guard let s = authenticate(r) else { return refuse(401, .unauthenticated) }
        guard let id = ID16(hex: ws), let q = queryItems(query, allowed: ["epoch"]) else { return refuse(400, .malformed) }
        var epoch: UInt32?
        if let e = q["epoch"] {
            guard let v = HostAPI.parseDecimal(e), v >= 1, v <= UInt64(UInt32.max) else { return refuse(400, .malformed) }
            epoch = UInt32(v)
        }
        if let denied = memberGate(s, ws: id) { return denied }
        let mine = (workspaces[id]?.grants ?? [:]).filter { $0.key.device == s.id && (epoch == nil || $0.key.epoch == epoch) }
            .sorted { $0.key.epoch < $1.key.epoch }.map(\.value)
        guard !mine.isEmpty else { return refuse(404, .notFound) }
        return json(200, ["grants": .array(mine)])
    }

    private func memberListReply(_ r: WireRequest, ws: String, _ query: String?) throws -> WireReply {
        guard let s = authenticate(r) else { return refuse(401, .unauthenticated) }
        guard let id = ID16(hex: ws), queryItems(query, allowed: []) != nil else { return refuse(400, .malformed) }
        if let denied = memberGate(s, ws: id) { return denied }
        guard let l = workspaces[id]?.listJSON else { return refuse(404, .notFound) }
        return json(200, ["member_list": l])
    }

    private func cardReply(_ r: WireRequest, ws: String, _ query: String?) throws -> WireReply {
        guard let s = authenticate(r) else { return refuse(401, .unauthenticated) }
        guard let id = ID16(hex: ws), queryItems(query, allowed: []) != nil else { return refuse(400, .malformed) }
        if let denied = memberGate(s, ws: id) { return denied }
        guard let c = workspaces[id]?.cardJSON else { return refuse(404, .notFound) }
        return json(200, ["card": c])
    }

    private func cardKeyReply(_ r: WireRequest, ws: String, _ query: String?) throws -> WireReply {
        guard let s = authenticate(r) else { return refuse(401, .unauthenticated) }
        guard let id = ID16(hex: ws), let q = queryItems(query, allowed: ["card_seq"]), let sq = q["card_seq"],
              let seq = HostAPI.parseDecimal(sq), seq >= 1, seq <= UInt64(UInt32.max) else { return refuse(400, .malformed) }
        if let denied = memberGate(s, ws: id) { return denied }
        guard let sealed = workspaces[id]?.cardKeys[s.id]?[UInt32(seq)] else { return refuse(404, .notFound) }
        return json(200, ["workspace_id": .string(id.hex), "device_id": .string(s.id.hex), "card_seq": .int(Int64(seq)),
                          "sealed": .string(B64U.encode(sealed))])
    }

    /// A revocation record is a public, PK-signed object, so the route takes no session: a revoked device has none.
    private func revocationReply(_ r: WireRequest, device: String, _ query: String?) throws -> WireReply {
        guard let d = ID16(hex: device), queryItems(query, allowed: []) != nil else { return refuse(400, .malformed) }
        guard let rec = revocations[d] else { return refuse(404, .notFound) }
        return json(200, ["record": rec])
    }


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
        if let c = certInfo[device] { return (c.personID, c.expiresMs) }
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

    /// `Orch-Holder` (P3-D10): once a workspace's host holds a generation, every host write must carry exactly it (409 `fenced`
    /// for a missing, stale or unparsable one). A workspace whose host never took a hold is not fenced (FakeHost simplification).
    private func fence(_ r: WireRequest, ws: ID16) -> WireReply? {
        let h = r.header("orch-holder")
        if let current = holders[ws] {
            guard let h, let g = HostAPI.parseDecimal(h), g == current else { return refuse(409, .fenced) }
            return nil
        }
        if let h, HostAPI.parseDecimal(h) == nil { return refuse(400, .malformed) }
        return nil
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
        certs[dc.deviceID] = cert; certInfo[dc.deviceID] = dc
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

    private func bridge(_ r: WireRequest, ws: String, rid: String, _ query: String?) async throws -> WireReply {
        // A fault delay on a POST happens before any authoritative check; from here to the store there is no suspension, so
        // membership, revocation, epoch and quota are decided under the state the write happens in.
        let a: FaultAction = r.method == "POST" ? try await fault(.beforeQueue, "POST bridge") : .none
        guard let s = authenticate(r) else { return refuse(401, .unauthenticated) }
        guard let wsID = ID16(hex: ws), let ridID = ID16(hex: rid) else { return refuse(400, .malformed) }
        switch r.method {
        case "POST":
            guard queryItems(query, allowed: []) != nil else { return refuse(400, .malformed) }
            // Responses come only from the workspace's host session; requests only from a device session.
            let response = s.kind == .workspace
            let (parsed, err) = parseEnvelope(r.body, direction: response ? .toDevice : .toHost,
                                              maxSize: response ? Bridge.maxChunk : Bridge.maxRequest)
            if let err { return err }
            let h = parsed!.header
            guard h.workspace == wsID, h.rid == ridID else { return refuse(400, .malformed) }
            guard h.epoch >= 1 else { return refuse(400, .malformed) }      // epoch 0 belongs to the pairing route
            let key: BoxKey
            if response {
                guard s.id == wsID else { return refuse(403, .notForThisDevice) }
                // The recipient is checked now, after any fault delay and with no suspension before the store: a device revoked or
                // removed while the host's response was in flight gets no mailbox.
                if revoked.contains(h.device) { return refuse(403, .revoked) }
                guard workspaces[wsID]?.list?.members.contains(where: { $0.deviceID == h.device }) == true else { return refuse(403, .notEligible) }
                key = BoxKey(ws: wsID, device: h.device, offer: nil, rid: ridID)
            } else {
                // The header's device must be the session's device (section 8.9), then membership and revocation.
                guard h.device == s.id, s.kind == .device else { return refuse(403, .notForThisDevice) }
                if let denied = memberGate(s, ws: wsID) { return denied }
                key = BoxKey(ws: wsID, device: s.id, offer: nil, rid: ridID)
                let now = wall.nowMs
                let liveBoxes = boxes.filter { $0.key.ws == wsID && $0.key.device == s.id && $0.key.rid != ridID && !live($0.value, now).requests.isEmpty }
                if liveBoxes.count >= limits.maxLiveMailboxesPerDevice { rateLimited += 1; return refuse(429, .quotaExceeded, headers: ["retry-after": String(limits.retryAfterSeconds)]) }
            }
            store(key, parsed: parsed!, envelope: r.body, response: response)
            if a == .duplicate { store(key, parsed: parsed!, envelope: r.body, response: response) }
            accepted += 1
            return json(202)
        case "GET":
            let (after, ok) = afterCursor(query)
            guard ok else { return refuse(400, .malformed) }
            if let denied = memberGate(s, ws: wsID) { return denied }
            let box = live(boxes[BoxKey(ws: wsID, device: s.id, offer: nil, rid: ridID)] ?? Box(), wall.nowMs)
            return try await chunkReply(box.responses, rid: ridID, after: after, route: "GET bridge")
        default: return refuse(404, .notFound)
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



extension FakeRelay {
    private func dropAllowed(_ s: Session, workspace ws: ID16, write: Bool) -> Bool {
        if s.kind == .workspace { return s.id == ws }
        guard memberGate(s, ws: ws) == nil, let card = workspaces[ws]?.card,
              (try? checkUploadTarget(s.id, card: card)) != nil,
              let scopes = workspaces[ws]?.list?.members.first(where: { $0.deviceID == s.id })?.scopeStrings else { return false }
        return scopes.contains(write ? "operate" : "look")
    }

    private func dropVisible(_ v: DropVersion, _ s: Session) -> Bool {
        guard drops[v.parsed.object]?.last?.parsed.expiresMs.map({ $0 > wall.nowMs }) ?? true,
              dropAllowed(s, workspace: claims[v.parsed.object] ?? v.parsed.space, write: false) else { return false }
        if claims[v.parsed.object] != nil { return true }
        switch v.parsed.recipients {
        case .inbox: return v.wraps.contains { $0.target == v.parsed.space && $0.targetKind == .wxk }
        case .ids(let ids): return ids.contains(v.parsed.space) || ids.contains(s.id) || v.parsed.authorID == s.id
        }
    }

    /// Deterministic Demo control; applies only to the next encrypted Drop PUT.
    public func demoRejectNextDrop() throws {
        try checkLive()
        demoDropRejections += 1
    }

    private func dropRoute(_ r: WireRequest, _ path: [String], _ query: String?, protocolRoute: Bool = false) throws -> WireReply {
        if r.method == "PUT", demoDropRejections > 0 {
            demoDropRejections -= 1
            return refuse(403, .notEligible)      // the Demo control "reject next upload": a refusal in section 14 form
        }
        guard protocolRoute ? (r.method == "PUT" || r.method == "POST" && path.last == "claim") : (r.method == "GET" || path == ["drop", "list"]) else { return refuse(404, .notFound) }
        guard let session = authenticate(r) else { return refuse(401, .unauthenticated) }
        guard query == nil else { return refuse(400, .malformed) }
        drops = drops.filter { $0.value.last?.parsed.expiresMs.map { $0 > wall.nowMs } ?? true }
        claims = claims.filter { drops[$0.key] != nil }
        if path == ["drop", "list"], r.method == "POST" {
            guard let o = try? StrictJSON.parse(r.body, maxBytes: 1024).object,
                  Set(o.keys) == ["workspace_id", "direction"],
                  let ws = o["workspace_id"]?.string.flatMap(ID16.init(hex:)),
                  let direction = o["direction"]?.string, ["received", "sending"].contains(direction) else { return refuse(400, .malformed) }
            guard dropAllowed(session, workspace: ws, write: false) else { return refuse(403, .notEligible) }
            let entries = drops.values.compactMap(\.last).filter {
                (claims[$0.parsed.object] ?? $0.parsed.space) == ws && dropVisible($0, session) && (direction == "sending" ? $0.parsed.authorID == session.id : $0.parsed.authorID != session.id)
            }.sorted { $0.parsed.object.hex < $1.parsed.object.hex }.map { v -> JSONValue in
                ["descriptor": v.descriptor, "wraps": .array(v.wraps.map(\.json))]
            }
            return json(200, ["objects": .array(entries)])
        }
        guard path.count >= 3, let id = ID16(hex: path[1]) else { return refuse(400, .malformed) }
        if path.count == 3, path[2] == "versions", r.method == "PUT" {
            var state = DropDocument.State(current: drops[id]?.last?.parsed.version ?? 0, head: drops[id]?.last?.parsed.raw)
            if DropDocument.checkPut(state: &state, ifMatch: r.header("if-match"), descriptor: [:]).status == 428 {
                return refuse(428, .preconditionRequired)
            }
            guard let o = try? StrictJSON.parse(r.body, maxBytes: 36 << 20).object,
                  Set(o.keys) == ["descriptor", "wraps", "blob"],
                  let signed = o["descriptor"], let raw = signed.object?["o"]?.object,
                  let d = try? DropDescriptor(object: raw), d.object == id, d.spaceKind == "workspace",
                  let wr = o["wraps"]?.array, !wr.isEmpty, wr.count <= 1024,
                  let blob = o["blob"]?.string.flatMap({ B64U.decode($0) }), blob.count <= 26 << 20 else { return refuse(400, .malformed) }
            guard d.authorID == session.id, (d.authorKind == "device") == (session.kind == .device),
                  dropAllowed(session, workspace: d.space, write: true) else { return refuse(403, .notEligible) }
            let key = session.kind == .device ? certInfo[session.id]?.signingKey : workspaces[session.id]?.card?.wsk
            guard let key, (try? DropDescriptor.verify(signed, authorKey: key)) != nil else { return refuse(401, .badSignature) }
            guard d.matches(blob: blob), d.contentLen == Int64(blob.count), d.expiresMs.map({ $0 > wall.nowMs && $0 <= DropUpload.addMs(wall.nowMs, 604800000) }) ?? (d.objectKind == "document") else { return refuse(400, .malformed) }
            guard let wraps = try? wr.map(DropWrapRecord.init(json:)) else { return refuse(400, .malformed) }
            guard wraps.allSatisfy({ $0.object == id && $0.version == d.version }) else { return refuse(400, .malformed) }
            let reply = DropDocument.checkPut(state: &state, ifMatch: r.header("if-match"), descriptor: d.raw)
            guard reply.status == 201 else { return try WireReply(status: reply.status, body: canonicalJSON(["error": "version_conflict", "current": .int(Int64(reply.current ?? 0))])) }
            let all = drops.values.flatMap { $0 }
            guard all.count < limits.maxDropVersions, all.reduce(0, { $0 + $1.blob.count }) + blob.count <= limits.maxDropBytes else { return refuse(429, .quotaExceeded, headers: ["retry-after": String(limits.retryAfterSeconds)]) }
            drops[id, default: []].append(DropVersion(descriptor: signed, parsed: d, wraps: wraps, blob: blob))
            return json(201, ["version": .int(Int64(d.version))])
        }
        if path.count == 3, path[2] == "claim", r.method == "POST" {
            guard session.kind == .workspace, var versions = drops[id], var v = versions.last else { return refuse(403, .notEligible) }
            guard v.parsed.recipients == .inbox else { return refuse(403, .notEligible) }
            guard let claim = try? StrictJSON.parse(r.body, maxBytes: 64 << 10) else { return refuse(400, .malformed) }
            guard claim.object?["o"]?.object?["workspace_id"] == .string(session.id.hex) else { return refuse(403, .notEligible) }
            var stored = DropClaim.Stored(object: id, version: v.parsed.version, state: claims[id].map { .claimed(by: $0) } ?? .inbox, wraps: v.wraps)
            let result = DropClaim.check(stored: &stored, claim: claim, cards: workspaces.compactMapValues { $0.card?.wsk }, epochs: workspaces.compactMapValues { $0.list?.epoch })
            if result.status == 200 {
                claims[id] = result.claimedBy
                for i in versions.indices { versions[i].wraps = [] }
                v.wraps = stored.wraps; versions[versions.count - 1] = v; drops[id] = versions
            }
            var fields: [String: JSONValue] = [:]
            if let e = result.error { fields["error"] = .string(e) }
            if let by = result.claimedBy { fields["claimed_by"] = .string(by.hex) }
            else if result.error == "already_claimed" { fields["claimed_by"] = .null }      // section 14: `claimed_by` is always present
            return result.status == 200 ? json(200, fields) : try WireReply(status: result.status, body: canonicalJSON(.object(fields)))
        }
        guard path.count == 5, path[2] == "versions", r.method == "GET", let n = HostAPI.parseDecimal(path[3]), n > 0,
              let versions = drops[id], n <= versions.count else { return refuse(404, .notFound) }
        let v = versions[Int(n) - 1]
        guard dropVisible(v, session) else { return refuse(403, .notEligible) }
        switch path[4] {
        case "descriptor": return json(200, ["descriptor": v.descriptor])
        case "wraps": return json(200, ["wraps": .array(v.wraps.map(\.json)), "claimed_by": claims[id].map { .string($0.hex) } ?? .null])
        case "blob": return try WireReply(status: 200, headers: [:], body: v.blob)
        default: return refuse(404, .notFound)
        }
    }

    func rewrapSource(object: ID16, version: UInt32, workspace: ID16, token: String) throws -> (DropDescriptor, [DropWrapRecord]) {
        guard try workspaceSession(token) == workspace, let versions = drops[object], version > 0, version <= versions.count else { throw DropError.unauthorized }
        let v = versions[Int(version) - 1]
        let addressed = v.parsed.space == workspace || (v.parsed.recipients == .inbox && v.wraps.contains { $0.targetKind == .wxk && $0.target == workspace })
        guard (claims[object].map { $0 == workspace } ?? addressed), v.parsed.expiresMs.map({ $0 > wall.nowMs }) ?? true else { throw DropError.unauthorized }
        if case .ids(let ids) = v.parsed.recipients, !ids.contains(workspace) { throw DropError.unauthorized }
        return (v.parsed, v.wraps)
    }

    func putRewrap(_ wrap: DropWrapRecord, token: String) throws {
        let ws = try workspaceSession(token)
        let (descriptor, _) = try rewrapSource(object: wrap.object, version: wrap.version, workspace: ws, token: token)
        guard descriptor.recipients != .inbox || claims[wrap.object] == ws else { throw DropError.unavailableKey }
        guard wrap.targetKind == .wk, wrap.target == ws, wrap.keyVersion == workspaces[ws]?.list?.epoch else { throw Refusal.malformed }
        let i = Int(wrap.version) - 1
        drops[wrap.object]?[i].wraps.removeAll { $0.targetKind == .wk && $0.target == ws && $0.keyVersion == wrap.keyVersion }
        drops[wrap.object]?[i].wraps.append(wrap)
    }
}
