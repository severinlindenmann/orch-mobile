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
        try cfg.context.generation?.check()          // a Demo reset ends every session built from the old capability
        do {
            if try await cfg.container.index.isRemoved(ws: cfg.workspace.hex, generation: cfg.generation) { throw SessionError.staleGeneration }
            _ = try await cfg.container.database()
        } catch is StoreError { throw SessionError.staleGeneration }
    }

    // MARK: keys and epochs

    private func wkPurpose(_ e: UInt32) -> String { "wk.\(e)" }

    public func currentEpoch() async throws -> UInt32 { UInt32(clamping: try await cfg.container.epochHighWater()) }

    private func loadKeys() async throws {
        let hwm = try await currentEpoch()
        guard hwm >= 1 else { return }
        for e in 1...hwm where keys[e] == nil {
            if let d = try? cfg.vault.get(ws: cfg.workspace.hex, purpose: wkPurpose(e)), d.count == 32 { keys[e] = SymmetricKey(data: d) }
        }
    }

    /// Stores `WK_e` (vault first, then the high-water mark, so the mark never runs ahead of its key). An epoch's key never changes.
    package func install(epoch: UInt32, key: SymmetricKey) async throws {
        try await ensureCurrent()
        guard epoch >= 1 else { throw SessionError.noKeyForEpoch(epoch) }
        if let existing = try? cfg.vault.get(ws: cfg.workspace.hex, purpose: wkPurpose(epoch)) {
            guard existing == key.rawBytes else { throw SessionError.grantConflict }
        } else {
            try cfg.vault.put(key.rawBytes, ws: cfg.workspace.hex, purpose: wkPurpose(epoch))
        }
        keys[epoch] = key
        try await cfg.container.raiseEpochHighWater(Int64(epoch))
    }

    package func install(_ grant: VerifiedWKGrant) async throws { try await install(epoch: grant.epoch, key: grant.wk) }

    /// Fetches every grant for this device, verifies each with the pinned `WSK` and installs the valid ones. The epoch never
    /// moves backwards. Fails if nothing valid arrived.
    @discardableResult
    package func refreshGrants() async throws -> UInt32 {
        try await ensureCurrent()
        let raw: [JSONValue] = try await withRelay { s in
            try await RelayClient(transport: cfg.transport).grants(workspace: cfg.workspace, session: s)
        }
        var firstError: Error?
        var installed = false
        for g in raw {
            do {
                let v = try WKGrant.open(g, wsk: cfg.wsk, workspace: cfg.workspace, device: cfg.deviceID, deviceKey: cfg.identity.kx)
                try await install(v); installed = true
            } catch { firstError = firstError ?? error }
        }
        if !installed, let e = firstError { throw e }
        return try await currentEpoch()
    }

    // MARK: relay session

    private func withRelay<T: Sendable>(_ body: (RelaySession) async throws -> T) async throws -> T {
        for attempt in 0..<2 {
            let s = try await relaySession()
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
    }

    private func row(from r: SQLRow) -> Row? {
        guard let rid = r.text("rid").flatMap({ ID16(hex: $0) }), let logical = r.text("logical").flatMap({ ID16(hex: $0) }),
              let seq = r.int("seq"), let epoch = r.int("epoch"), let env = r.blob("envelope"), let pt = r.blob("plaintext"),
              let stream = r.int("stream"), let off = r.int("offset_adopted"), let sent = r.int("sent_ms"), let created = r.int("created_ms")
        else { return nil }
        return Row(rid: rid, logical: logical, seq: UInt64(seq), epoch: UInt32(epoch), envelope: env, plaintext: pt, stream: stream != 0,
                   offsetAdopted: off != 0, sentMs: sent, createdMs: created)
    }

    private func loadRow(_ rid: ID16) async throws -> Row? {
        let rows = try await cfg.container.database().query("SELECT * FROM bridge_requests WHERE rid=?", [.text(rid.hex)])
        return rows.first.flatMap(row(from:))
    }

    private func deleteRow(_ rid: ID16) async throws {
        try await cfg.container.database().execute("DELETE FROM bridge_requests WHERE rid=?", [.text(rid.hex)])
    }

    public func clockOffsetMs() async throws -> Int64 {
        try await cfg.container.database().query("SELECT value FROM meta WHERE key='clock_offset_ms'").first?.int("value") ?? 0
    }

    package func setClockOffset(_ v: Int64) async throws { try await setOffset(v) }

    private func setOffset(_ v: Int64) async throws {
        try await cfg.container.database().execute("INSERT INTO meta(key,value) VALUES('clock_offset_ms', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.int(v)])
    }

    /// Allocates the next seq, seals the request and stores the exact envelope in ONE synchronous transaction: nothing is
    /// sent until this returns, and a crash after it leaves a record that can be re-sent unchanged.
    private func prepare(logical: ID16, plaintext: Data, minSeq: UInt64 = 0) async throws -> Row {
        try await ensureCurrent()
        guard plaintext.count + Bridge.overhead <= Bridge.maxRequest else { throw SessionError.tooLarge }
        try await loadKeys()
        let epoch = try await currentEpoch()
        guard epoch >= 1, let wk = keys[epoch] else { throw SessionError.noKeyForEpoch(epoch) }
        let offset = try await clockOffsetMs()
        let now = cfg.wall.nowMs
        let (ws, dev, identity, entropy) = (cfg.workspace, cfg.deviceID, cfg.identity, cfg.entropy)
        let rid = entropy.id16(), salt = entropy.bytes(16)
        let db = try await cfg.container.database()
        return try await db.transaction { tx in
            let stored = try tx.query("SELECT value FROM meta WHERE key='next_seq'").first?.int("value") ?? 1
            let seq = max(UInt64(stored), minSeq, 1)
            guard seq <= UInt64(maxSafeInt) else { throw SessionError.tooLarge }
            let ts = saturatingAddMs(now, offset)
            let h = Bridge.Header(direction: .toHost, workspace: ws, device: dev, rid: rid, seq: seq, tsMs: UInt64(max(ts, 0)), epoch: epoch, salt: salt)
            guard let key = Bridge.channelKey(header: h, wk: wk) else { throw SessionError.noKeyForEpoch(epoch) }
            let env = try Bridge.seal(header: h, channelKey: key, signer: identity.sig, plaintext: plaintext)
            try tx.execute("INSERT INTO bridge_requests(rid, logical, seq, epoch, envelope, plaintext, stream, offset_adopted, sent_ms, created_ms) VALUES(?,?,?,?,?,?,0,0,?,?)",
                           [.text(rid.hex), .text(logical.hex), .int(Int64(seq)), .int(Int64(epoch)), .blob(env), .blob(plaintext), .int(now), .int(now)])
            try tx.execute("INSERT INTO meta(key,value) VALUES('next_seq', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.int(Int64(seq) + 1)])
            return Row(rid: rid, logical: logical, seq: seq, epoch: epoch, envelope: env, plaintext: plaintext, stream: false,
                       offsetAdopted: false, sentMs: now, createdMs: now)
        }
    }

    public func pendingRequests() async throws -> [PendingRequestInfo] {
        try await cfg.container.database().query("SELECT * FROM bridge_requests ORDER BY seq").compactMap(row(from:))
            .map { PendingRequestInfo(rid: $0.rid, logical: $0.logical, seq: $0.seq, epoch: $0.epoch, createdMs: $0.createdMs) }
    }

    /// The stored sealed envelope of a pending request (tests and diagnostics).
    package func storedEnvelope(rid: ID16) async throws -> Data? { try await loadRow(rid)?.envelope }

    package func nextSeq() async throws -> UInt64 {
        UInt64(try await cfg.container.database().query("SELECT value FROM meta WHERE key='next_seq'").first?.int("value") ?? 1)
    }

    public func pinFailures() async throws -> Int {
        Int(try await cfg.container.database().query("SELECT value FROM meta WHERE key='pin_failures'").first?.int("value") ?? 0)
    }

    private func recordPinFailure() async throws {
        try await cfg.container.database().execute("INSERT INTO meta(key,value) VALUES('pin_failures', 1) ON CONFLICT(key) DO UPDATE SET value=value+1")
    }

    /// Gives up on a pending request (the caller decided it no longer matters).
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
    /// request (new rid/seq/salt, same logical bytes) after `stale_epoch` (with a verified higher grant), a first
    /// `stale_timestamp` (offset adopted) or `stale_sequence`. A timeout leaves the request pending for `resend`.
    package func exchange(meta: JSONValue, data: Data = Data()) async throws -> BridgeResponse {
        let plaintext = try Bridge.frame(meta: meta, data: data)
        let logical = cfg.entropy.id16()
        let first = try await prepare(logical: logical, plaintext: plaintext)
        return try await drive(first, isResend: false)
    }

    /// Re-sends a pending request's stored envelope unchanged (same rid, seq, salt): the host replays its recorded answer while
    /// the rid record lives (received_at + 900 s).
    package func resend(rid: ID16) async throws -> BridgeResponse {
        guard let r = try await loadRow(rid) else { throw SessionError.unknownRequest }
        if cfg.wall.nowMs - r.createdMs >= Self.hostWindowMs {
            try await deleteRow(rid); throw SessionError.uncertain(logical: r.logical)
        }
        return try await drive(r, isResend: true)
    }

    private func drive(_ start: Row, isResend: Bool) async throws -> BridgeResponse {
        var row = start
        var resend = isResend
        for _ in 0..<Self.maxAttempts {
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
                try await deleteRow(row.rid)
                switch refusal {
                case .staleEpoch(let e) where fetch:
                    let have = try await refreshGrants()
                    guard have >= e else { throw SessionError.epochUnavailable(wanted: e) }
                case .staleTimestamp where offsetAdopted && !resend:
                    break                                     // offset persisted by collect; re-seal with it
                case .staleTimestamp where resend, .alreadyDone(status: "unknown"):
                    throw SessionError.uncertain(logical: row.logical)
                case .staleSequence(let high):
                    row = try await prepare(logical: row.logical, plaintext: row.plaintext, minSeq: high + 1)
                    resend = false
                    continue
                default:
                    throw ClientError.host(refusal)
                }
                row = try await prepare(logical: row.logical, plaintext: row.plaintext)
                resend = false
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
