import CryptoKit
import Foundation
import OrchCustody
import OrchProtocol
import OrchStore

public enum SessionError: Error, Equatable, Sendable {
    /// The workspace generation was removed or replaced; nothing may be sent or stored for it.
    case staleGeneration
    case noKeyForEpoch(UInt32)
    /// No sealed response yet. The request is persisted; `resend` sends the stored envelope again, byte for byte.
    case noResponse(rid: ID16)
    /// The outcome of a logical request cannot be known from the bridge alone (host answered `already_done(unknown)`, the
    /// host's record window ended, or an unknown-rid resend was refused as stale). The caller reconciles by reading state;
    /// nothing is ever re-signed silently.
    case uncertain(logical: ID16)
    case badResponse
    /// Three host-signature failures with a key that opens the tag: pair again (protocol 8.8).
    case pairAgain
    case grantConflict
    case epochUnavailable(wanted: UInt32)
    case tooLarge
    case unknownRequest
}

/// A fully verified response to one request.
public struct BridgeResponse: Equatable, Sendable {
    public let status: Int
    public let headers: [String: String]
    public let data: Data
}

public struct PendingRequestInfo: Equatable, Sendable {
    public let rid: ID16, logical: ID16
    public let seq: UInt64
    public let epoch: UInt32
    public let createdMs: Int64
}

/// A logical request whose outcome cannot be known from the bridge. Durable until reconciliation resolves it (slice 3 reads the
/// state, then calls `resolveUncertain`). It carries the immutable operation bytes: the logical id and the exact signed
/// plaintext (framed meta and data) the device sent. Nothing is ever re-signed from it by the session itself.
public struct UncertainRequestInfo: Equatable, Sendable {
    public let rid: ID16, logical: ID16
    public let seq: UInt64
    public let epoch: UInt32
    public let createdMs: Int64
    public let plaintext: Data
}

/// Everything a WorkspaceSession is built from. A session is bound to one `(realm, workspace, generation)` for life.
public struct WorkspaceSessionConfig: Sendable {
    public var context: RealmContext
    public var workspace: ID16
    public var generation: Int64
    public var deviceID: ID16
    public var identity: DeviceIdentity
    /// The `WSK` pinned at pairing.
    public var wsk: SigningPublicKey
    public var container: WorkspaceContainer
    public var vault: RealmVault
    public var transport: any RelayTransport
    public var clock: any Clock<Duration>
    public var wall: any WallClock
    public var entropy: any Entropy
    public var pollInterval: Duration
    public var responseTimeout: Duration

    public init(context: RealmContext, workspace: ID16, generation: Int64, identity: DeviceIdentity, wsk: SigningPublicKey,
                container: WorkspaceContainer, vault: RealmVault, transport: any RelayTransport, clock: any Clock<Duration>,
                wall: any WallClock, entropy: any Entropy = SystemEntropy(), pollInterval: Duration = .milliseconds(500),
                responseTimeout: Duration = .seconds(30)) {
        self.context = context; self.workspace = workspace; self.generation = generation
        self.deviceID = Identifiers.deviceID(identity.publicKeys.sig); self.identity = identity; self.wsk = wsk
        self.container = container; self.vault = vault; self.transport = transport; self.clock = clock; self.wall = wall
        self.entropy = entropy; self.pollInterval = pollInterval; self.responseTimeout = responseTimeout
    }
}

/// One workspace's bridge client (host-api section 1). It owns seq allocation, pending rid records with their exact
/// envelopes, epochs, clock offset and polling. Screens never see it: sending and signing are `package`, and the request
/// is durable before it is sent (a single synchronous transaction allocates the seq and stores the sealed envelope).
public actor WorkspaceSession {
    private var reviews: [UUID: QuestionReview] = [:]
    private var reviewLifecycle: UInt64 = 0
    private var preparingDecisions: Set<ID16> = []
    private var viewsStarted = false
    private var decisionDrivers: [ID16: Task<DecisionOutcome, Error>] = [:]
    private var snapshotTask: Task<WorkspaceSnapshot, Error>?
    private var subscribers: [UUID: AsyncStream<WorkspaceEvent>.Continuation] = [:]
    private var poller: Task<Void, Never>?
    private var hintRefresh: Task<Void, Never>?
    private var foreground = true
    private var lastRevision: Int64?
    private var cachedSnapshot: WorkspaceSnapshot?
    private var connectionState: ConnectionState = .offline
    private var hintIdentity: UUID?
    private var recovery: Task<Void, Never>?
    private var recoveryIdentity: UUID?
    public private(set) var verifiedReceiptMs: Int64?
    let cfg: WorkspaceSessionConfig
    private var keys: [UInt32: SymmetricKey] = [:]
    private var relay: (session: RelaySession, expiresMs: Int64)?
    /// A bounded number of re-sends of one logical request within a single call (stale epoch, offset, sequence).
    static let maxAttempts = 4
    static let hostWindowMs: Int64 = 900_000
    /// A byte-identical re-send is only made while the host surely still holds the rid record: the host's 900 s window minus
    /// this margin (clock skew between the two walls, polling and queue delays). Later than that it is `uncertain`, not re-sent.
    static let resendSafetyMarginMs: Int64 = 600_000
    static var resendWindowMs: Int64 { hostWindowMs - resendSafetyMarginMs }
    /// One driver Task per logical request: a concurrent resend of the same request joins it instead of racing it.
    private var inflight: [ID16: Task<BridgeResponse, Error>] = [:]
    private var ridLogical: [ID16: ID16] = [:]
    /// Monotonic age of requests created or loaded by this process; the persisted wall time is the cross-restart fallback.
    private var monotonicAge: [ID16: () -> Duration] = [:]
    /// Tests only: injects failures inside atomic decision preparation and attempt replacement.
    package var crashHook: (@Sendable (String) throws -> Void)?
    package func setCrashHook(_ h: (@Sendable (String) throws -> Void)?) { crashHook = h }
    static let maxResponseBytes = 8 << 20

    public init(_ config: WorkspaceSessionConfig) async throws {
        let c = config
        let storeRealm = await c.container.index.layout.realm
        guard c.vault.realm == c.context.realm, storeRealm == c.context.realm.rawValue else {
            throw RealmViolation.wrongStore
        }
        try c.context.admit(identity: c.identity)
        cfg = c
    }

    public nonisolated var workspace: ID16 { cfg.workspace }
    public nonisolated var generation: Int64 { cfg.generation }

    // MARK: generation

    func ensureCurrent() async throws {
        do {
            try cfg.context.generation?.check()          // a Demo reset ends every session built from the old capability
            try await cfg.container.index.requireNotRemoved(ws: cfg.workspace.hex, generation: cfg.generation)
            _ = try await cfg.container.database()
        } catch {
            // Availability failures are not authoritative evidence of removal.
            switch error {
            case StoreError.workspaceRemoved, RealmViolation.staleGeneration: break
            default: throw error
            }
            cancelAll()
            invalidateReviews()
            poller?.cancel(); poller = nil
            for c in subscribers.values { c.yield(.removed); c.finish() }
            subscribers.removeAll()
            throw error is StoreError ? SessionError.staleGeneration : error
        }
    }

    /// Ends all in-flight work of this session (the workspace was removed or the generation replaced). Drivers see the
    /// cancellation at their next suspension point and send nothing more.
    package func cancelAll() {
        for t in inflight.values { t.cancel() }
    }

    // MARK: keys and epochs

    private func wkPurpose(_ e: UInt32) -> String { "wk.\(e)" }

    /// The epoch this device seals under: the high-water mark of CONFIRMED epochs (a verified member list, a verified higher
    /// `stale_epoch` refusal, or an explicit `install`). A stored grant for a later epoch does not raise it.
    public func currentEpoch() async throws -> UInt32 { UInt32(clamping: try await cfg.container.epochHighWater()) }

    private func loadKeys() async throws {
        let hwm = try await currentEpoch()
        guard hwm >= 1 else { return }
        for e in 1...hwm where keys[e] == nil {
            if let d = try? cfg.vault.get(ws: cfg.workspace.hex, purpose: wkPurpose(e)), d.count == 32 { keys[e] = SymmetricKey(data: d) }
        }
    }

    /// Keeps `WK_e` in custody without making `e` current. An epoch's key never changes.
    private func store(epoch: UInt32, key: SymmetricKey) async throws {
        try await ensureCurrent()
        guard epoch >= 1 else { throw SessionError.noKeyForEpoch(epoch) }
        if let existing = try? cfg.vault.get(ws: cfg.workspace.hex, purpose: wkPurpose(epoch)) {
            guard existing == key.rawBytes else { throw SessionError.grantConflict }
        } else {
            try cfg.vault.put(key.rawBytes, ws: cfg.workspace.hex, purpose: wkPurpose(epoch))
        }
        keys[epoch] = key
    }

    /// Stores `WK_e` (vault first, then the high-water mark, so the mark never runs ahead of its key) and makes `e` current.
    package func install(epoch: UInt32, key: SymmetricKey) async throws {
        try await store(epoch: epoch, key: key)
        try await cfg.container.raiseEpochHighWater(Int64(epoch))
    }

    package func install(_ grant: VerifiedWKGrant) async throws { try await install(epoch: grant.epoch, key: grant.wk) }

    /// Fetches every grant for this device, verifies each with the pinned `WSK` and stores the valid ones. The current epoch
    /// moves only to an epoch CONFIRMED by the verified member list (or by `confirmedEpoch`, a higher `stale_epoch` refusal
    /// that already passed section 8.8): a grant uploaded ahead of its list (section 7.2 order) is kept but not used, so the
    /// device never seals under an epoch the host has not reached. The epoch never moves backwards. Fails if nothing valid arrived.
    @discardableResult
    package func refreshGrants(confirmedEpoch: UInt32? = nil) async throws -> UInt32 {
        try await ensureCurrent()
        let raw: [JSONValue] = try await withRelay { s in
            try await RelayClient(transport: cfg.transport).grants(workspace: cfg.workspace, session: s)
        }
        var firstError: Error?
        var opened: [UInt32] = []
        for g in raw {
            do {
                let v = try WKGrant.open(g, wsk: cfg.wsk, workspace: cfg.workspace, device: cfg.deviceID, deviceKey: cfg.identity.kx)
                try await store(epoch: v.epoch, key: v.wk); opened.append(v.epoch)
            } catch { firstError = firstError ?? error }
        }
        if opened.isEmpty, let e = firstError { throw e }
        guard let top = opened.max() else { return try await currentEpoch() }
        var confirmed = confirmedEpoch ?? 0
        if confirmed < top {
            let list = try await withRelay { s in try await RelayClient(transport: cfg.transport).memberList(workspace: cfg.workspace, session: s) }
            let m = try MemberList.verify(list, wsk: cfg.wsk)
            guard m.workspace == cfg.workspace else { throw SessionError.badResponse }
            confirmed = max(confirmed, m.epoch)
        }
        if let target = opened.filter({ $0 <= confirmed }).max() { try await cfg.container.raiseEpochHighWater(Int64(target)) }
        return try await currentEpoch()
    }

    // MARK: relay session

    /// Runs `body` with a relay session. Generation is checked again AFTER any login (which suspends), immediately before the
    /// body (a post, a poll, a grant fetch) is dispatched, so a workspace removed during the login sends nothing.
    private func withRelay<T: Sendable>(_ body: (RelaySession) async throws -> T) async throws -> T {
        for attempt in 0..<2 {
            let s = try await relaySession()
            try await ensureCurrent()
            try Task.checkCancellation()
            do { return try await body(s) }
            catch ClientError.relay(let r) where r.code == .unauthenticated && attempt == 0 { relay = nil }
        }
        throw ClientError.relay(RelayRefusal(status: 401, code: .unauthenticated))
    }

    private func relaySession() async throws -> RelaySession {
        if let r = relay, cfg.wall.nowMs < r.expiresMs - 30_000 { return r.session }
        let o = try await RelayClient(transport: cfg.transport)
            .openDeviceSession(identity: cfg.identity, deviceID: cfg.deviceID)
        relay = (o.session, o.expiresMs)
        return o.session
    }

    // MARK: durable requests

    private struct Row {
        let rid: ID16, logical: ID16
        let seq: UInt64
        let epoch: UInt32
        let envelope: Data, plaintext: Data
        let stream: Bool
        let offsetAdopted: Bool
        let sentMs: Int64, createdMs: Int64
        let uncertain: Bool
    }

    private func row(from r: SQLRow) -> Row? {
        guard let rid = r.text("rid").flatMap({ ID16(hex: $0) }), let logical = r.text("logical").flatMap({ ID16(hex: $0) }),
              let seq = r.int("seq"), let epoch = r.int("epoch"), let env = r.blob("envelope"), let pt = r.blob("plaintext"),
              let stream = r.int("stream"), let off = r.int("offset_adopted"), let sent = r.int("sent_ms"), let created = r.int("created_ms"),
              let state = r.text("state")
        else { return nil }
        return Row(rid: rid, logical: logical, seq: UInt64(seq), epoch: UInt32(epoch), envelope: env, plaintext: pt, stream: stream != 0,
                   offsetAdopted: off != 0, sentMs: sent, createdMs: created, uncertain: state == "uncertain")
    }

    private func loadRow(_ rid: ID16) async throws -> Row? {
        let rows = try await cfg.container.database().query("SELECT * FROM bridge_requests WHERE rid=?", [.text(rid.hex)])
        return rows.first.flatMap(row(from:))
    }

    private func deleteRow(_ rid: ID16) async throws {
        monotonicAge[rid] = nil
        try await cfg.container.database().execute("DELETE FROM bridge_requests WHERE rid=?", [.text(rid.hex)])
    }

    /// Durable `uncertain`: the row stays, with its immutable operation bytes, until `resolveUncertain`.
    private func markUncertain(_ rid: ID16) async throws {
        try await cfg.container.database().execute("UPDATE bridge_requests SET state='uncertain' WHERE rid=?", [.text(rid.hex)])
    }

    public func clockOffsetMs() async throws -> Int64 {
        try await cfg.container.database().query("SELECT value FROM meta WHERE key='clock_offset_ms'").first?.int("value") ?? 0
    }

    package func setClockOffset(_ v: Int64) async throws { try await setOffset(v) }

    private func setOffset(_ v: Int64) async throws {
        try await cfg.container.database().execute("INSERT INTO meta(key,value) VALUES('clock_offset_ms', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.int(v)])
    }

    private static func marker(_ c: some Clock<Duration>) -> () -> Duration {
        let start = c.now
        return { start.duration(to: c.now) }
    }

    /// Allocates the next seq, seals the request and stores the exact envelope in ONE synchronous transaction: nothing is
    /// sent until this returns, and a crash after it leaves a record that can be re-sent unchanged. With `replacing`, the
    /// refused attempt is deleted in the SAME transaction (and only if it is still there): the logical request is never
    /// without a durable attempt, and two drivers cannot both replace one row.
    private func prepare(logical: ID16, plaintext: Data, minSeq: UInt64 = 0, replacing old: ID16? = nil, reconciled: Bool = false, decision: (QuestionReview, String)? = nil) async throws -> Row {
        let lifecycle = reviewLifecycle
        try Task.checkCancellation()
        try await ensureCurrent()
        guard plaintext.count + Bridge.overhead <= Bridge.maxRequest else { throw SessionError.tooLarge }
        try await loadKeys()
        let epoch = try await currentEpoch()
        guard epoch >= 1, let wk = keys[epoch] else { throw SessionError.noKeyForEpoch(epoch) }
        let offset = try await clockOffsetMs()
        let now = cfg.wall.nowMs
        let (ws, dev, identity, entropy, hook) = (cfg.workspace, cfg.deviceID, cfg.identity, cfg.entropy, crashHook)
        let rid = entropy.id16(), salt = entropy.bytes(16)
        let db = try await cfg.container.database()
        if decision != nil { guard foreground, lifecycle == reviewLifecycle else { throw ViewError.offline } }
        let row = try await db.transaction { tx in
            var plaintext = plaintext
            if let (review, option) = decision {
                let op = try Decisions.makeOp(workspace: ws, questionID: review.question.questionID,
                    contentHash: review.question.contentHash, decisionID: logical,
                    answer: ["option_id": .string(option)], signer: identity.sig)
                plaintext = try Bridge.frame(meta: op, data: Data())
                try tx.execute("INSERT INTO decisions(id,question,option_id,review,operation,dispatched) VALUES(?,?,?,?,?,0)",
                    [.text(logical.hex), .text(review.question.questionID.hex), .text(option),
                     .blob(try canonicalJSON(review.question.wire)), .blob(try canonicalJSON(op))])
                try hook?("decision.inserted")
            }
            if let old, try tx.query("SELECT 1 AS x FROM bridge_requests WHERE rid=? AND (state='pending' OR ?=1)", [.text(old.hex), .int(reconciled ? 1 : 0)]).isEmpty {
                throw SessionError.unknownRequest
            }
            try tx.execute("DELETE FROM bridge_charges WHERE created_ms <= ?", [.int(now - Self.hostWindowMs)])
            let stored = try tx.query("SELECT value FROM meta WHERE key='next_seq'").first?.int("value") ?? 1
            let seq = max(UInt64(stored), minSeq, 1)
            guard seq <= UInt64(maxSafeInt) else { throw SessionError.tooLarge }
            let ts = saturatingAddMs(now, offset)
            let h = Bridge.Header(direction: .toHost, workspace: ws, device: dev, rid: rid, seq: seq, tsMs: UInt64(max(ts, 0)), epoch: epoch, salt: salt)
            guard let key = Bridge.channelKey(header: h, wk: wk) else { throw SessionError.noKeyForEpoch(epoch) }
            let env = try Bridge.seal(header: h, channelKey: key, signer: identity.sig, plaintext: plaintext)
            try tx.execute("INSERT INTO bridge_requests(rid, logical, seq, epoch, envelope, plaintext, stream, offset_adopted, sent_ms, created_ms, state) VALUES(?,?,?,?,?,?,0,0,?,?,'pending')",
                           [.text(rid.hex), .text(logical.hex), .int(Int64(seq)), .int(Int64(epoch)), .blob(env), .blob(plaintext), .int(now), .int(now)])
            try tx.execute("INSERT INTO meta(key,value) VALUES('next_seq', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.int(Int64(seq) + 1)])
            if let old {
                try hook?("replace.inserted")
                try tx.execute("DELETE FROM bridge_requests WHERE rid=?", [.text(old.hex)])
                try hook?("replace.deleted")
            }
            return Row(rid: rid, logical: logical, seq: seq, epoch: epoch, envelope: env, plaintext: plaintext, stream: false,
                       offsetAdopted: false, sentMs: now, createdMs: now, uncertain: false)
        }
        if let old { monotonicAge[old] = nil }
        ridLogical[rid] = logical
        monotonicAge[rid] = Self.marker(cfg.clock)
        return row
    }

    public func pendingRequests() async throws -> [PendingRequestInfo] {
        try await cfg.container.database().query("SELECT * FROM bridge_requests WHERE state='pending' ORDER BY seq").compactMap(row(from:))
            .map { PendingRequestInfo(rid: $0.rid, logical: $0.logical, seq: $0.seq, epoch: $0.epoch, createdMs: $0.createdMs) }
    }

    /// Requests whose outcome the bridge cannot tell. Durable across restarts until `resolveUncertain`.
    public func uncertainRequests() async throws -> [UncertainRequestInfo] {
        try await cfg.container.database().query("SELECT * FROM bridge_requests WHERE state='uncertain' ORDER BY seq").compactMap(row(from:))
            .map { UncertainRequestInfo(rid: $0.rid, logical: $0.logical, seq: $0.seq, epoch: $0.epoch, createdMs: $0.createdMs, plaintext: $0.plaintext) }
    }

    /// Reconciliation decided the outcome (by reading state): the uncertain record may go. Nothing else deletes it.
    @discardableResult
    package func resolveUncertain(logical: ID16) async throws -> Int {
        try await cfg.container.database().execute("DELETE FROM bridge_requests WHERE logical=? AND state='uncertain'", [.text(logical.hex)])
    }

    /// The stored sealed envelope of a request (tests and diagnostics).
    package func storedEnvelope(rid: ID16) async throws -> Data? { try await loadRow(rid)?.envelope }

    package func nextSeq() async throws -> UInt64 {
        UInt64(try await cfg.container.database().query("SELECT value FROM meta WHERE key='next_seq'").first?.int("value") ?? 1)
    }

    /// Consecutive host-signature failures against the pinned `WSK` (reset by any verified response).
    public func pinFailures() async throws -> Int {
        Int(try await cfg.container.database().query("SELECT value FROM meta WHERE key='pin_failures'").first?.int("value") ?? 0)
    }

    private func recordPinFailure() async throws {
        try await cfg.container.database().execute("INSERT INTO meta(key,value) VALUES('pin_failures', 1) ON CONFLICT(key) DO UPDATE SET value=value+1")
    }

    private func resetPinFailures() async throws {
        try await cfg.container.database().execute("UPDATE meta SET value=0 WHERE key='pin_failures' AND value<>0")
    }

    /// Gives up on a request (the caller decided it no longer matters).
    package func discard(rid: ID16) async throws { try await deleteRow(rid) }

    // MARK: response validation (protocol 8.8)

    package func context() async throws -> Bridge.DeviceContext {
        try await loadKeys()
        return Bridge.DeviceContext(workspace: cfg.workspace, device: cfg.deviceID, wsk: cfg.wsk, wk: keys, offsetMs: try await clockOffsetMs())
    }

    /// Section 8.8 for one chunk against this session's own keys, pin and offset, with an explicit pending table.
    package func check(response envelope: Data, mailbox: Bridge.MailboxPosition, pending: [ID16: Bridge.PendingRequest], nowMs: Int64)
        async throws -> (outcome: Bridge.ResponseOutcome, pending: [ID16: Bridge.PendingRequest]) {
        try await ensureCurrent()
        return Bridge.checkResponse(envelope, context: try await context(), pending: pending, mailbox: mailbox, nowMs: nowMs)
    }

    // MARK: exchange

    package enum Collected: Sendable {
        case response(BridgeResponse)
        case refusal(HostRefusal, fetchGrants: Bool, offsetAdopted: Bool)
        case timeout
    }

    /// Sends one logical request and returns its verified response. Persisted before the first byte leaves; re-sent as a NEW
    /// request (new rid/seq/salt, same logical bytes) only when the host REFUSED the previous attempt without running it:
    /// `stale_epoch` (with a verified higher grant), a first `stale_timestamp` (offset adopted) or `stale_sequence`. The
    /// refused attempt is replaced atomically. A timeout leaves the request pending for `resend`.
    package func exchange(meta: JSONValue, data: Data = Data()) async throws -> BridgeResponse {
        let plaintext = try Bridge.frame(meta: meta, data: data)
        let logical = cfg.entropy.id16()
        let first = try await prepare(logical: logical, plaintext: plaintext)
        return try await runDriver(first, isResend: false)
    }

    /// Re-sends a pending request's stored envelope unchanged (same rid, seq, salt): the host replays its recorded answer while
    /// the rid record lives. Never re-signs: when the host's record may be gone (age, taken as the larger of the monotonic and
    /// the persisted wall age, past 900 s minus a 600 s safety margin) or the host answers with a refusal that would need a new
    /// seq, timestamp or epoch, the request becomes durably `uncertain` (U8) and nothing is sent again.
    package func resend(rid: ID16) async throws -> BridgeResponse {
        if let l = ridLogical[rid], let t = inflight[l] { return try await t.value }
        guard let r = try await loadRow(rid) else { throw SessionError.unknownRequest }
        if let t = inflight[r.logical] { return try await t.value }          // another caller started it while we loaded
        if r.uncertain { throw SessionError.uncertain(logical: r.logical) }
        ridLogical[rid] = r.logical
        if ageMs(r) >= Self.resendWindowMs {
            try await markUncertain(rid); throw SessionError.uncertain(logical: r.logical)
        }
        if let t = inflight[r.logical] { return try await t.value }
        return try await runDriver(r, isResend: true)
    }

    private func ageMs(_ r: Row) -> Int64 {
        let wall = max(cfg.wall.nowMs - r.createdMs, 0)
        guard let m = monotonicAge[r.rid] else { return wall }
        let c = m().components
        return max(wall, c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)
    }

    /// One driver Task per logical request. The map is read and written without a suspension in between, so two callers can
    /// never both start a driver for the same request.
    private func runDriver(_ row: Row, isResend: Bool) async throws -> BridgeResponse {
        let logical = row.logical
        if let t = inflight[logical] { return try await t.value }
        let t = Task { () -> BridgeResponse in
            let result: Result<BridgeResponse, Error>
            do { result = .success(try await self.drive(row, isResend: isResend)) } catch { result = .failure(error) }
            self.finished(logical)
            return try result.get()
        }
        inflight[logical] = t
        return try await t.value
    }

    private func finished(_ logical: ID16) {
        inflight[logical] = nil
        for (rid, l) in ridLogical where l == logical { ridLogical[rid] = nil }
    }

    private func drive(_ start: Row, isResend: Bool) async throws -> BridgeResponse {
        var row = start
        for _ in 0..<Self.maxAttempts {
            try Task.checkCancellation()
            try await ensureCurrent()
            if try await pinFailures() >= 3 { throw SessionError.pairAgain }
            try await post(row)
            switch try await collect(row) {
            case .response(let r):
                try await ensureCurrent()
                try await retireCompletedAttempt(row)
                return r
            case .timeout:
                throw SessionError.noResponse(rid: row.rid)
            case .refusal(let refusal, let fetch, let offsetAdopted):
                switch refusal {
                case .alreadyDone(status: "unknown"):
                    try await markUncertain(row.rid); throw SessionError.uncertain(logical: row.logical)
                case _ where isResend && refusal.needsNewSignature:
                    // A re-send would have to be re-signed with a new seq, timestamp or epoch. Never silently (U8).
                    try await markUncertain(row.rid); throw SessionError.uncertain(logical: row.logical)
                case .staleEpoch(let e) where fetch:
                    let have = try await refreshGrants(confirmedEpoch: e)        // the refused attempt stays until the new one is durable
                    guard have >= e else { throw SessionError.epochUnavailable(wanted: e) }
                    row = try await prepare(logical: row.logical, plaintext: row.plaintext, replacing: row.rid)
                case .staleTimestamp where offsetAdopted:
                    row = try await prepare(logical: row.logical, plaintext: row.plaintext, replacing: row.rid)    // offset persisted by collect
                case .staleSequence(let high):
                    row = try await prepare(logical: row.logical, plaintext: row.plaintext, minSeq: high + 1, replacing: row.rid)
                default:
                    try await retireCompletedAttempt(row)
                    throw ClientError.host(refusal)
                }
            }
        }
        throw SessionError.epochUnavailable(wanted: 0)
    }

    /// Decision attempts stay durable until their validated outcome commits in finishDecision.
    private func retireCompletedAttempt(_ row: Row) async throws {
        let deleted = try await cfg.container.database().execute(
            "DELETE FROM bridge_requests WHERE rid=? AND NOT EXISTS (SELECT 1 FROM decisions WHERE id=?)",
            [.text(row.rid.hex), .text(row.logical.hex)])
        if deleted > 0 { monotonicAge[row.rid] = nil }
    }

    private func post(_ row: Row) async throws {
        let route = BridgeRoute(workspaceID: cfg.workspace, requestID: row.rid)
        let reply = try await withRelay { s in
            let db = try await cfg.container.database()
            let decision = try await db.query("SELECT dispatched FROM decisions WHERE id=?", [.text(row.logical.hex)]).first
            if decision != nil { guard foreground else { throw ViewError.offline } }
            // Charge resends too. Mark the dispatch boundary durably before handing bytes to transport.
            // A crash at this boundary is conservatively an attempted send, never a detached signature.
            try await db.transaction { tx in
                try tx.execute("INSERT INTO bridge_charges(rid,created_ms) VALUES(?,?)", [.text(UUID().uuidString), .int(cfg.wall.nowMs)])
                if decision != nil { try tx.execute("UPDATE decisions SET dispatched=1 WHERE id=?", [.text(row.logical.hex)]) }
            }
            try await ensureCurrent()
            if Task.isCancelled || (decision != nil && !foreground) {
                if decision?.int("dispatched") == 0 {
                    try await db.execute("UPDATE decisions SET dispatched=0 WHERE id=?", [.text(row.logical.hex)])
                }
                throw CancellationError()
            }
            return try await cfg.transport.bridgePost(row.envelope, route: route, session: s)
        }
        _ = try HostAPI.expect(reply, status: 202)
    }

    private func collect(_ row: Row) async throws -> Collected {
        let route = BridgeRoute(workspaceID: cfg.workspace, requestID: row.rid)
        var progress = Bridge.PendingRequest(next: 0, stream: row.stream, epoch: row.epoch, offsetAdopted: row.offsetAdopted)
        var table: [ID16: Bridge.PendingRequest] = [row.rid: progress]
        var first: (status: Int, headers: [String: String])?
        var body = Data()
        var waited = Duration.zero
        var counted = Set<UInt64>()       // one pin failure per chunk, however often a poll shows it again
        while true {
            let after: UInt64? = progress.next == 0 ? nil : progress.next - 1
            let reply = try await withRelay { s in try await cfg.transport.bridgePoll(route: route, after: after, session: s) }
            let chunks = try HostAPI.chunks(try HostAPI.expect(reply)).sorted { $0.idx < $1.idx }
            var advanced = false
            for c in chunks {
                guard let current = table[row.rid] else { break }
                let pos = Bridge.MailboxPosition(id: c.id, index: c.idx, last: c.last, stream: c.stream)
                let (outcome, newTable) = try await check(response: c.envelope, mailbox: pos, pending: table, nowMs: cfg.wall.nowMs)
                switch outcome {
                case .drop(let why):
                    if case .hostSignature(let pin) = why, pin, counted.insert(c.idx).inserted { try await recordPinFailure() }
                    continue
                case .accept(let a):
                    table = newTable
                    advanced = true
                    try await resetPinFailures()            // a verified host answer ends the run of failures
                    if let off = a.offsetMs { try await setOffset(off) }
                    if a.clockWrong { throw SessionError.badResponse }
                    if a.refusal {
                        guard a.last, let refusal = HostRefusal(meta: a.meta) else { throw SessionError.badResponse }
                        return .refusal(refusal, fetchGrants: a.fetchGrants, offsetAdopted: a.offsetMs != nil)
                    }
                    if first == nil {
                        guard let m = a.meta.object, Set(m.keys) == ["status", "headers"], let st = m["status"]?.int, (100...599).contains(st),
                              let hs = m["headers"]?.object else { throw SessionError.badResponse }
                        var headers: [String: String] = [:]
                        for (k, v) in hs { guard let s = v.string else { throw SessionError.badResponse }; headers[k] = s }
                        first = (Int(st), headers)
                    } else if a.meta.object?.isEmpty != true { throw SessionError.badResponse }
                    body.append(a.data)
                    if body.count > Self.maxResponseBytes { throw SessionError.tooLarge }
                    _ = current
                    if a.last, let f = first { return .response(BridgeResponse(status: f.status, headers: f.headers, data: body)) }
                }
                progress = table[row.rid] ?? progress
            }
            if advanced { continue }
            if waited >= cfg.responseTimeout { return .timeout }
            try await cfg.clock.sleep(for: cfg.pollInterval)
            waited += cfg.pollInterval
        }
    }
}

private func saturatingAddMs(_ a: Int64, _ b: Int64) -> Int64 {
    let (r, o) = a.addingReportingOverflow(b); return o ? (b > 0 ? .max : .min) : r
}

private extension HostRefusal {
    var needsNewSignature: Bool {
        switch self {
        case .staleEpoch, .staleTimestamp, .staleSequence: true
        default: false
        }
    }
}

// MARK: unsigned workspace boundary and durable §13 ledger
extension WorkspaceSession {
    private func viewJSON(_ response: BridgeResponse, status: Int = 200) throws -> JSONValue {
        let headers = try HeaderMap.normalize(response.headers.map { (name: $0.key, value: $0.value) })
        guard headers["content-type"] == "application/json" else { throw ViewError.malformed }
        let v = try StrictJSON.parse(response.data)
        guard response.status == status else {
            let m = try fields(v, ["host_api", "error"])
            guard m["host_api"] == 0, let error = m["error"]?.string else { throw ViewError.malformed }
            throw ViewError.http(response.status, error)
        }
        return v
    }
    private func getView(_ path: String) async throws -> JSONValue {
        try viewJSON(await exchange(meta: ["op": "http", "method": "GET", "path": .string(path), "headers": [:]]))
    }
    package func snapshotView() async throws -> WorkspaceSnapshot {
        try await ensureCurrent()
        if let snapshotTask { return try await snapshotTask.value }
        let task = Task { () throws -> WorkspaceSnapshot in
            guard try await self.readBudgetAvailable() else { throw ViewError.readDeferred }
            let v = try await self.getView("/v2/snapshot")
            let snapshot = try WorkspaceSnapshot(v, workspace: self.workspace)
            try await self.ensureCurrent()
            self.verifiedReceiptMs = self.cfg.wall.nowMs
            self.cachedSnapshot = snapshot
            self.connectionState = .online
            return snapshot
        }
        snapshotTask = task
        defer { snapshotTask = nil }
        return try await task.value
    }
    private func readQuestion(_ id: ID16) async throws -> Question {
        let m = try fields(await getView("/v2/questions/" + id.hex), ["host_api", "workspace_id", "question"])
        guard m["host_api"] == 0, m.idField("workspace_id") == workspace else { throw ViewError.malformed }
        let q = try Question(m["question"]!)
        guard q.questionID == id else { throw ViewError.malformed }
        return q
    }
    package func reviewQuestion(_ id: ID16) async throws -> QuestionReview {
        try await ensureCurrent()
        let lifecycle = reviewLifecycle
        let q = try await readQuestion(id)
        try await ensureCurrent()
        guard foreground, lifecycle == reviewLifecycle else { throw ViewError.invalidReview }
        reviews = reviews.filter { $0.value.question.questionID != id || $0.value.question.contentHash == q.contentHash }
        if reviews.count >= 128 { reviews.removeAll() }
        let review = QuestionReview(question: q, realm: cfg.context.realm, workspaceID: workspace, generation: generation, token: UUID())
        reviews[review.token] = review
        return review
    }
    package func startViews() {
        guard !viewsStarted else { return }
        viewsStarted = true
        recoverDecisions()
        startPoller()
    }

    /// Call on lock/background, even if there are no stream subscribers.
    public func setForeground(_ value: Bool) {
        foreground = value
        if value {
            startPoller()
            recoverDecisions()
        } else {
            reviewLifecycle &+= 1
            reviews.removeAll()
            poller?.cancel(); poller = nil
            snapshotTask?.cancel()
            cancelAll()
            hintRefresh?.cancel(); hintRefresh = nil; hintIdentity = nil
            recovery?.cancel(); recovery = nil; recoveryIdentity = nil
            for t in decisionDrivers.values { t.cancel() }
        }
    }
    public func invalidateReviews() { reviewLifecycle &+= 1; reviews.removeAll(); emit(.invalidated) }

    package func submit(_ review: QuestionReview, optionID: String) async throws -> DecisionOutcome {
        try await ensureCurrent()
        guard foreground, reviews[review.token] == review, review.workspaceID == workspace,
              review.generation == generation, review.realm == cfg.context.realm else { throw ViewError.invalidReview }
        guard review.question.options.contains(where: { $0.id.utf8Equal(optionID) }) else { throw ViewError.invalidOption }
        // Offline work remains unsigned. Reconfirm reachability/open state before entering custody;
        // the host still performs CAS because it can change again after this read.
        let current: Question
        do { current = try await readQuestion(review.question.questionID) }
        catch { try await ensureCurrent(); throw ViewError.offline }
        try await ensureCurrent()
        guard foreground, reviews[review.token] == review else { throw ViewError.invalidReview }
        if let r = current.resolution {
            reviews[review.token] = nil
            return .alreadyAnswered(label: r.byDeviceLabel, at: r.atMs)
        }
        guard current.contentHash == review.question.contentHash else {
            invalidateReviews(); return .questionChanged(hash: current.contentHash)
        }
        // Consume before any suspension: double-tapping can never mint a second signature.
        reviews[review.token] = nil
        let id = cfg.entropy.id16()
        preparingDecisions.insert(id)
        defer { preparingDecisions.remove(id) }
        let first: Row
        do { first = try await prepare(logical: id, plaintext: Data(), decision: (review, optionID)) }
        catch { try await ensureCurrent(); throw ViewError.offline }
        return try await driveDecision(id, first: first)
    }
    /// - Throws: `StoreError.removalStateUnknown` if removal status cannot be verified.
    ///   Retry when coordination is available; this error does not confirm removal.
    public func pendingDecisions() async throws -> [DecisionStatus] {
        try await ensureCurrent()
        return try await cfg.container.database().query("SELECT * FROM decisions WHERE state <> 'resolved' ORDER BY rowid").compactMap { r in
            guard let id = r.text("id").flatMap(ID16.init(hex:)), let q = r.text("question").flatMap(ID16.init(hex:)), let o = r.text("option_id") else { return nil }
            return DecisionStatus(decisionID: id, questionID: q, optionID: o, state: r.text("state") == "uncertain" ? .uncertain : .pending)
        }
    }
    /// - Throws: `StoreError.removalStateUnknown` if removal status cannot be verified.
    ///   Retry when coordination is available; this error does not confirm removal.
    public func reconcileDecision(_ id: ID16) async throws -> DecisionOutcome {
        guard foreground, !preparingDecisions.contains(id) || decisionDrivers[id] != nil else { throw ViewError.offline }
        return try await driveDecision(id)
    }
    private func recoverDecisions() {
        guard foreground, recovery == nil else { return }
        let identity = UUID(); recoveryIdentity = identity
        recovery = Task {
            defer { if self.recoveryIdentity == identity { self.recovery = nil; self.recoveryIdentity = nil } }
            do {
                for row in try await self.pendingDecisions() {
                    guard self.foreground, !Task.isCancelled else { return }
                    _ = try? await self.reconcileDecision(row.decisionID)
                }
            } catch { self.emit(.connection(.offline)) }
        }
    }

    private func driveDecision(_ id: ID16, first: Row? = nil) async throws -> DecisionOutcome {
        if let t = decisionDrivers[id] { return try await t.value }
        let t = Task { try await self.performDecision(id, first: first) }
        decisionDrivers[id] = t
        defer { decisionDrivers[id] = nil }
        return try await t.value
    }
    private func performDecision(_ id: ID16, first: Row?) async throws -> DecisionOutcome {
        try await ensureCurrent()
        guard let record = try await cfg.container.database().query("SELECT * FROM decisions WHERE id=?", [.text(id.hex)]).first,
              let bytes = record.blob("operation"), let qid = record.text("question").flatMap(ID16.init(hex:)) else { throw SessionError.unknownRequest }
        let op = try StrictJSON.parse(bytes)
        if let outcome = record.blob("outcome") { return try decodeOutcome(StrictJSON.parse(outcome)) }
        let attempts = try await cfg.container.database().query("SELECT * FROM bridge_requests WHERE logical=? ORDER BY seq DESC", [.text(id.hex)])
        let old = attempts.first.flatMap(row(from:))
        guard foreground else { throw ViewError.offline }
        guard old != nil, first != nil || record.int("dispatched") == 1 else {
            try await cfg.container.database().transaction { tx in
                try tx.execute("DELETE FROM decisions WHERE id=?", [.text(id.hex)])
                try tx.execute("DELETE FROM bridge_requests WHERE logical=?", [.text(id.hex)])
            }
            throw ViewError.offline
        }
        let result: DecisionOutcome
        do {
            result = try await decisionNetwork(id, qid: qid, op: op, old: old, first: first)
        } catch {
            try await ensureCurrent()
            let db = try await cfg.container.database()
            if try await db.query("SELECT dispatched FROM decisions WHERE id=?", [.text(id.hex)]).first?.int("dispatched") == 0 {
                try await db.transaction { tx in
                    try tx.execute("DELETE FROM decisions WHERE id=?", [.text(id.hex)])
                    try tx.execute("DELETE FROM bridge_requests WHERE logical=?", [.text(id.hex)])
                }
                throw ViewError.offline
            }
            try await db.execute("UPDATE decisions SET state='uncertain' WHERE id=?", [.text(id.hex)])
            return .uncertain
        }
        return try await finishDecision(id, result)
    }
    private func decisionNetwork(_ id: ID16, qid: ID16, op: JSONValue, old: Row?, first: Row?) async throws -> DecisionOutcome {
        var response: BridgeResponse?
        do {
            if let first { response = try await runDriver(first, isResend: false) }
            if response == nil, let old, !old.uncertain {
                do { response = try await resend(rid: old.rid) }
                catch SessionError.uncertain { /* authoritative re-read below */ }
            }
            if response == nil {
                // Only previously dispatched decisions can reach authoritative reconciliation.
                emit(.connection(.reconciling))
                let q = try await readQuestion(qid)
                if let r = q.resolution {
                    let result: DecisionOutcome = r.decisionID == id && r.answer == op.object?["answer"]
                        ? .accepted : .alreadyAnswered(label: r.byDeviceLabel, at: r.atMs)
                    return result
                }
                guard q.contentHash == op.object?["content_hash"]?.string.flatMap({ B64U.decode($0) }) else {
                    return .questionChanged(hash: q.contentHash)
                }
                // Only this authoritative open-state reconciliation can replace an uncertain row.
                // The old row and its state survive until the replacement commits atomically.
                let next = try await prepare(logical: id, plaintext: Bridge.frame(meta: op, data: Data()), replacing: old?.rid, reconciled: true)
                response = try await runDriver(next, isResend: false)
            }
            let m = try fields(viewJSON(response!), ["host_api", "decision_id", "question"])
            guard m["host_api"] == 0, m.idField("decision_id") == id else { throw ViewError.malformed }
            let closed = try Question(m["question"]!)
            guard closed.questionID == qid, let r = closed.resolution, r.decisionID == id, r.answer == op.object?["answer"] else { throw ViewError.malformed }
            return .accepted
        } catch ClientError.host(.alreadyAnswered) {
            let q = try await readQuestion(qid)
            guard let r = q.resolution else { throw ViewError.malformed }
            return r.decisionID == id && r.answer == op.object?["answer"]
                ? .accepted : .alreadyAnswered(label: r.byDeviceLabel, at: r.atMs)
        } catch ClientError.host(.questionChanged(let hash)) {
            return .questionChanged(hash: hash)
        }
    }
    private func finishDecision(_ id: ID16, _ result: DecisionOutcome) async throws -> DecisionOutcome {
        try await ensureCurrent()
        let attempts = try await cfg.container.database().query("SELECT rid FROM bridge_requests WHERE logical=?", [.text(id.hex)])
        let encoded = try canonicalJSON(encodeOutcome(result))
        try await cfg.container.database().transaction { tx in
            try tx.execute("UPDATE decisions SET state='resolved',outcome=? WHERE id=?", [.blob(encoded), .text(id.hex)])
            try tx.execute("DELETE FROM bridge_requests WHERE logical=?", [.text(id.hex)])
        }
        for attempt in attempts {
            if let rid = attempt.text("rid").flatMap(ID16.init(hex:)) { monotonicAge[rid] = nil }
        }
        if case .questionChanged = result { invalidateReviews() }
        emit(.invalidated)
        return result
    }
    package func createTicket(_ draft: NewTicketSubmission) async throws -> Ticket {
        try draft.validate()
        try await ensureCurrent()
        guard foreground else { throw ViewError.offline }
        let plaintext = try Bridge.frame(meta: draft.meta, data: Data())
        let db = try await cfg.container.database()
        let old = try await db.query("SELECT * FROM bridge_requests WHERE logical=? ORDER BY seq DESC", [.text(draft.creationID.hex)]).first.flatMap(row(from:))
        if let old, old.plaintext != plaintext { throw ViewError.invalidDraft }
        let response: BridgeResponse
        if let old {
            do { response = try await resend(rid: old.rid) }
            catch SessionError.uncertain {
                // new_ticket is idempotent by (device, creationID); preserve exact draft bytes.
                let next = try await prepare(logical: draft.creationID, plaintext: plaintext, replacing: old.rid, reconciled: true)
                response = try await runDriver(next, isResend: false)
            }
        } else {
            let first = try await prepare(logical: draft.creationID, plaintext: plaintext)
            response = try await runDriver(first, isResend: false)
        }
        let m = try fields(viewJSON(response, status: 201), ["host_api", "creation_id", "ticket"])
        guard m["host_api"] == 0, m.idField("creation_id") == draft.creationID else { throw ViewError.malformed }
        let ticket = try Ticket(m["ticket"]!)
        guard ticket.title.utf8Equal(draft.title), ticket.body.utf8Equal(draft.body),
              ticket.epicKey.map({ Data($0.utf8) }) == draft.epicKey.map({ Data($0.utf8) }) else { throw ViewError.malformed }
        emit(.invalidated)
        return ticket
    }
    private func emit(_ event: WorkspaceEvent) {
        if case .connection(let state) = event { connectionState = state }
        for c in subscribers.values { c.yield(event) }
        if case .invalidated = event, foreground, !subscribers.isEmpty, hintRefresh == nil {
            let identity = UUID(); hintIdentity = identity
            hintRefresh = Task {
                await self.refreshViews()
                if self.hintIdentity == identity { self.hintRefresh = nil; self.hintIdentity = nil }
            }
        }
    }
    package func eventStream() -> AsyncStream<WorkspaceEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<WorkspaceEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        subscribers[id] = continuation
        if let cachedSnapshot { continuation.yield(.snapshot(cachedSnapshot)) }
        continuation.yield(.connection(connectionState))
        startViews()
        continuation.onTermination = { @Sendable _ in Task { await self.removeSubscriber(id) } }
        startPoller()
        return stream
    }
    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
        if subscribers.isEmpty { poller?.cancel(); poller = nil }
    }
    private func startPoller() {
        guard foreground, !subscribers.isEmpty, poller == nil else { return }
        poller = Task { await self.pollViews() }
    }
    /// Verified push/reconnect hint. Concurrent reads share snapshotTask.
    public func refreshViews() async {
        guard foreground else { return }
        do {
            let s = try await snapshotView()
            guard foreground, !Task.isCancelled else { return }
            emit(.snapshot(s)); emit(.connection(.online))
        } catch { if foreground && !Task.isCancelled { emit(.connection(.offline)) } }
    }
    private func readBudgetAvailable() async throws -> Bool {
        // Advisory read budget: admitted reads, mutation preflight/reconciliation and protocol retries can
        // overshoot this check. The 64-slot margin reserves room for mutations; it is not a hard rate limiter.
        let charged = try await cfg.container.database().query("SELECT COUNT(*) AS n FROM bridge_charges WHERE created_ms > ?", [.int(cfg.wall.nowMs - Self.hostWindowMs)]).first?.int("n") ?? 0
        return charged < 960
    }
    private func pollViews() async {
        var delay: Int64 = 15
        while !Task.isCancelled && foreground && !subscribers.isEmpty {

            // Imported host v1 defaults: 1024 per device, 16384 global. Reserve 64 slots for mutations.
            if (try? await readBudgetAvailable()) == true {
                do {
                    let s = try await snapshotView()
                    if Task.isCancelled { return }
                    delay = lastRevision == s.revision ? min(delay * 2, 60) : 15
                    lastRevision = s.revision
                    emit(.snapshot(s)); emit(.connection(.online))
                } catch ClientError.relay(let r) where r.status == 429 || r.status == 503 {
                    delay = max(min(delay * 2, 60), Int64(r.retryAfter ?? 0)); emit(.connection(.offline))
                } catch { if Task.isCancelled { return }; delay = min(delay * 2, 60); emit(.connection(.offline)) }
            } else { delay = 60 }
            do { try await cfg.clock.sleep(for: .seconds(delay)) } catch { return }
        }
    }
}

private func encodeOutcome(_ o: DecisionOutcome) -> JSONValue {
    switch o {
    case .accepted: ["kind": "accepted"]
    case .uncertain: ["kind": "uncertain"]
    case .alreadyAnswered(let label, let at): ["kind": "already_answered", "label": .string(label), "at": .int(at)]
    case .questionChanged(let hash): ["kind": "question_changed", "hash": .string(B64U.encode(hash))]
    }
}
private func decodeOutcome(_ v: JSONValue) throws -> DecisionOutcome {
    guard let m = v.object else { throw ViewError.malformed }
    switch m["kind"]?.string {
    case "accepted": return .accepted
    case "already_answered": guard let l = m["label"]?.string, let a = m["at"]?.int else { throw ViewError.malformed }; return .alreadyAnswered(label: l, at: a)
    case "question_changed": guard let h = m.b64uField("hash", length: 32) else { throw ViewError.malformed }; return .questionChanged(hash: h)
    default: throw ViewError.malformed
    }
}

extension WorkspaceSession {
    package func dropRelaySession() async throws -> RelaySession { try await ensureCurrent(); return try await relaySession() }
    package func dropKey(_ epoch: UInt32) async throws -> SymmetricKey {
        try await ensureCurrent(); try await loadKeys()
        guard let key = keys[epoch] else { throw SessionError.noKeyForEpoch(epoch) }
        return key
    }
}
