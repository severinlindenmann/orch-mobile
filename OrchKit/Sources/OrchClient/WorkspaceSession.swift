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
    /// Tests only: called inside the replacement transaction, between the insert of the new attempt and the delete of the old.
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

    private func ensureCurrent() async throws {
        do {
            try cfg.context.generation?.check()          // a Demo reset ends every session built from the old capability
            try await cfg.container.index.requireNotRemoved(ws: cfg.workspace.hex, generation: cfg.generation)
            _ = try await cfg.container.database()
        } catch {
            if case StoreError.removalStateUnknown = error { throw error }
            cancelAll()
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
            catch ClientError.adapter(.unauthenticated) where attempt == 0 { relay = nil }
        }
        throw ClientError.adapter(.unauthenticated)
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
    private func prepare(logical: ID16, plaintext: Data, minSeq: UInt64 = 0, replacing old: ID16? = nil) async throws -> Row {
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
        let row = try await db.transaction { tx in
            if let old, try tx.query("SELECT 1 AS x FROM bridge_requests WHERE rid=? AND state='pending'", [.text(old.hex)]).isEmpty {
                throw SessionError.unknownRequest
            }
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
                try await deleteRow(row.rid)
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
                    try await deleteRow(row.rid)
                    throw ClientError.host(refusal)
                }
            }
        }
        throw SessionError.epochUnavailable(wanted: 0)
    }

    private func post(_ row: Row) async throws {
        let route = BridgeRoute(workspaceID: cfg.workspace, requestID: row.rid)
        let reply = try await withRelay { s in try await cfg.transport.bridgePost(row.envelope, route: route, session: s) }
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
