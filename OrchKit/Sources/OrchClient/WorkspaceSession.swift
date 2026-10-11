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
    /// Q10: a WSK-verified grant whose key the verified member list held for its epoch does not commit. It is not kept.
    case wkCommitMismatch(UInt32)
    case epochUnavailable(wanted: UInt32)
    case tooLarge
    case unknownRequest
    /// The relay answered 409 `retry_exhausted` for this rid (protocol-v2 section 19.6) and polling while the relay retained it found no
    /// answer. Terminal: the attempt is durably `uncertain` and nothing is re-sent or re-signed automatically; only an explicit user
    /// action (`retryDecision`, or submitting the same draft again) may reissue it after reading authoritative state.
    case retryExhausted(logical: ID16)
    /// The relay refused a new rid with its unsigned `stale_epoch` hint (P3-D8) and the refetch of the signed list and grants is
    /// rate limited (at most 3 per minute, then 20, 40, 60 s). The request was not queued; it stays pending.
    case epochRefetchDeferred(retryAfterMs: Int64)
    /// The relay refused a new rid with its unsigned `stale_epoch` hint, but the signed member list and grants do not (yet) confirm a
    /// newer epoch. Nothing was queued; the request stays pending until the signed list arrives. `hint` is unsigned data only.
    case awaitingSignedEpoch(hint: UInt32?)
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
    /// Epochs asked for with no usable key in custody (not re-read until something is stored or a list accepted). Bounded: it only
    /// holds epochs something asked for, and is cleared beyond `maxAbsentKeys`.
    private var absentKeys: Set<UInt32> = []
    static let maxAbsentKeys = 64
    private var relay: (session: RelaySession, expiresMs: Int64)?
    /// A bounded number of re-sends of one logical request within a single call (stale epoch, offset, sequence).
    static let maxAttempts = 4
    static let hostWindowMs: Int64 = 900_000
    /// A byte-identical re-send is only made while the host surely still holds the rid record: the host's 900 s window minus
    /// this margin (clock skew between the two walls, polling and queue delays). Later than that it is `uncertain`, not re-sent.
    static let resendSafetyMarginMs: Int64 = 600_000
    static var resendWindowMs: Int64 { hostWindowMs - resendSafetyMarginMs }
    /// A same-rid re-seal after the relay's unsigned `stale_epoch` hint is made only this soon after the first copy (orch-29 Q14):
    /// later, a copy a lying relay held could still be delivered after the re-seal, so the request is reconciled instead.
    static let resealWindowMs: Int64 = 240_000
    /// Bounds the refetches the relay's unsigned `stale_epoch` hint can trigger (P3-D8), on `cfg.clock`.
    private var epochHintLimiter = EpochRefetchLimiter()
    private let sessionAge: () -> Duration
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
        sessionAge = Self.marker(c.clock)
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

    /// The epoch this device's keys are confirmed up to: the high-water mark of epochs a verified member list committed (with the
    /// committed key in custody) or an explicit `install` made current. A stored grant for a later epoch does not raise it. Sealing
    /// additionally needs the head list at exactly this epoch (`sealingKey`).
    public func currentEpoch() async throws -> UInt32 { UInt32(clamping: try await cfg.container.epochHighWater()) }

    /// A key this device READS with (responses, Drop wraps of older epochs), loaded lazily per epoch: any WSK-verified grant's key in
    /// custody at or below the confirmed epoch, except one that a verified list held for its epoch does not commit (Q10).
    private func readKey(_ e: UInt32) async throws -> SymmetricKey? {
        guard e >= 1, e <= (try await currentEpoch()) else { return nil }
        if let k = keys[e] { return k }
        if absentKeys.contains(e) { return nil }
        if absentKeys.count >= Self.maxAbsentKeys { absentKeys.removeAll() }
        guard let d = try? cfg.vault.get(ws: cfg.workspace.hex, purpose: wkPurpose(e)), d.count == 32 else { absentKeys.insert(e); return nil }
        let k = SymmetricKey(data: d)
        if let c = try await cfg.container.wkCommit(epoch: Int64(e)), !WKCommit.matches(c, workspace: cfg.workspace, epoch: e, wk: k) {
            absentKeys.insert(e); return nil
        }
        keys[e] = k
        return k
    }

    /// Q10 (one `WK` per epoch, ever): the key this device SEALS under. Only the head list's epoch, only once the epoch is current,
    /// and only a key in custody that the head list's `wk_commit` commits. While the `wk_commit_conflict` alarm stands this throws
    /// `Refusal.wkCommitConflict` (re-pair; it never clears by itself); anything else blocks sending with `noKeyForEpoch`. There is
    /// no fallback to another key or epoch.
    func sealingKey() async throws -> (epoch: UInt32, key: SymmetricKey) {
        if try await cfg.container.wkCommitConflictEpoch() != nil { throw Refusal.wkCommitConflict }
        let epoch = try await currentEpoch()
        guard epoch >= 1, let head = try await cfg.container.memberListHead(), head.epoch == Int64(epoch),
              let commit = try await cfg.container.wkCommit(epoch: Int64(epoch)), let wk = try await readKey(epoch),
              WKCommit.matches(commit, workspace: cfg.workspace, epoch: epoch, wk: wk) else { throw SessionError.noKeyForEpoch(epoch) }
        return (epoch, wk)
    }

    /// `sealingKey`, with ONE bounded recovery when no committed key is usable: fetch and accept the member list and the grants, then
    /// try once more. This is what lets a device whose head was reset (migration 12 drops the pre-Q10 head, which has no `wk_commit`)
    /// or whose grant arrived late send again without waiting for a `stale_epoch` or a Drop fetch.
    func sealingKeyRecovering() async throws -> (epoch: UInt32, key: SymmetricKey) {
        do { return try await sealingKey() }
        catch SessionError.noKeyForEpoch {
            _ = try await refreshGrants(forceList: true)
            return try await sealingKey()
        }
    }

    /// What blocks this workspace's keys for good until the person re-pairs, if anything: the durable `wk_commit_conflict` alarm. The
    /// App reads it at launch; a transient `wkCommitMismatch` is reported where it happens.
    public func keyAlarm() async -> WorkspaceKeyAlarm? {
        guard let e = try? await cfg.container.wkCommitConflictEpoch() else { return nil }
        return .conflict(epoch: UInt32(clamping: e))
    }

    /// The local alarm `wk_commit_conflict` (Q10): the epoch at which two WSK-verified member lists committed to different keys, if
    /// that was ever seen. Durable; while it stands nothing is sealed.
    public func wkCommitConflictEpoch() async throws -> UInt32? {
        try await cfg.container.wkCommitConflictEpoch().map { UInt32(clamping: $0) }
    }

    /// Keeps a WSK-verified `WK_e` in custody without making `e` current. Q10: when this device holds a verified list at `e`, its
    /// `wk_commit` decides: only the committed key is kept (it replaces an uncommitted one stored earlier) and any other is refused
    /// (`wkCommitMismatch`). Without a list for `e` the first key stays (`grantConflict` for another) until a list decides; nothing is
    /// sealed under it before then (`sealingKey`).
    private func store(epoch: UInt32, key: SymmetricKey) async throws {
        try await ensureCurrent()
        guard epoch >= 1 else { throw SessionError.noKeyForEpoch(epoch) }
        let existing = try? cfg.vault.get(ws: cfg.workspace.hex, purpose: wkPurpose(epoch))
        if let commit = try await cfg.container.wkCommit(epoch: Int64(epoch)) {
            guard WKCommit.matches(commit, workspace: cfg.workspace, epoch: epoch, wk: key) else { throw SessionError.wkCommitMismatch(epoch) }
            if existing != key.rawBytes { try cfg.vault.put(key.rawBytes, ws: cfg.workspace.hex, purpose: wkPurpose(epoch)) }
        } else if let existing {
            guard existing == key.rawBytes else { throw SessionError.grantConflict }
        } else {
            try cfg.vault.put(key.rawBytes, ws: cfg.workspace.hex, purpose: wkPurpose(epoch))
        }
        keys[epoch] = key
        absentKeys.remove(epoch)
    }

    /// Stores `WK_e` (vault first, then the high-water mark, so the mark never runs ahead of its key) and makes `e` current.
    package func install(epoch: UInt32, key: SymmetricKey) async throws {
        try await store(epoch: epoch, key: key)
        try await cfg.container.raiseEpochHighWater(Int64(epoch))
    }

    package func install(_ grant: VerifiedWKGrant) async throws { try await install(epoch: grant.epoch, key: grant.wk) }

    /// Fetches every grant for this device and verifies each with the pinned `WSK`. Q10: the verified member list decides which key
    /// an epoch has, so whenever a grant (or `confirmedEpoch`, a higher `stale_epoch` refusal that already passed section 8.8) is
    /// above the list held, the list is fetched and accepted BEFORE any grant is stored; a grant it does not commit is not kept
    /// (`store`). The current epoch moves only to an epoch a held verified list commits, with that committed key in custody, never
    /// above the head list: no epoch advance from unsigned data, and a grant uploaded ahead of its list is kept but not used. The
    /// epoch never moves backwards. Fails if no grant verified.
    /// `forceList` fetches the list even when no grant is above the held head (send-path recovery). If a grant the held list does
    /// not commit is the reason the head epoch has no usable key, this throws `wkCommitMismatch` instead of returning quietly.
    @discardableResult
    package func refreshGrants(confirmedEpoch: UInt32? = nil, forceList: Bool = false) async throws -> UInt32 {
        try await ensureCurrent()
        let raw: [JSONValue] = try await withRelay { s in
            try await RelayClient(transport: cfg.transport).grants(workspace: cfg.workspace, session: s)
        }
        var firstError: Error?
        var verified: [VerifiedWKGrant] = []
        for g in raw {
            do { verified.append(try WKGrant.open(g, wsk: cfg.wsk, workspace: cfg.workspace, device: cfg.deviceID, deviceKey: cfg.identity.kx)) }
            catch { firstError = firstError ?? error }
        }
        if verified.isEmpty, let e = firstError { throw e }
        guard let top = verified.map(\.epoch).max() else { return try await currentEpoch() }
        let held = try await cfg.container.memberListHead()?.epoch ?? 0
        if forceList || Int64(max(top, confirmedEpoch ?? 0)) > held {
            let list = try await withRelay { s in try await RelayClient(transport: cfg.transport).memberList(workspace: cfg.workspace, session: s) }
            _ = try await acceptMemberList(list)
        }
        var stored: [UInt32] = [], mismatched: Set<UInt32> = []
        for v in verified {
            do { try await store(epoch: v.epoch, key: v.wk); stored.append(v.epoch) }
            catch SessionError.grantConflict { continue }                                   // not kept; a list will decide
            catch SessionError.wkCommitMismatch(let e) { mismatched.insert(e) }             // not kept; surfaced below if it matters
        }
        let head = try await cfg.container.memberListHead()?.epoch ?? 0
        for e in stored.sorted(by: >) where Int64(e) <= head {
            guard let c = try await cfg.container.wkCommit(epoch: Int64(e)), let k = try? cfg.vault.get(ws: cfg.workspace.hex, purpose: wkPurpose(e)),
                  WKCommit.matches(c, workspace: cfg.workspace, epoch: e, wk: SymmetricKey(data: k)) else { continue }
            try await cfg.container.raiseEpochHighWater(Int64(e))
            break
        }
        let now = try await currentEpoch()
        if Int64(now) < head, head <= Int64(UInt32.max), mismatched.contains(UInt32(head)) { throw SessionError.wkCommitMismatch(UInt32(head)) }
        return now
    }

    /// Every member list this device acts on goes through here: the signature with the pinned `WSK`, this workspace, an epoch not
    /// below the confirmed one, and the persisted head of the last accepted list (P3-D6): an older `list_seq` is `stale_list`, other
    /// content under the same `list_seq` a conflict, a falling epoch `bad_epoch`. Q10: another `wk_commit` than one held for the
    /// list's epoch raises the durable local alarm `wk_commit_conflict` (checked first, whatever the order). The head and the epoch's
    /// commitment are recorded in the same transaction.
    package func acceptMemberList(_ raw: JSONValue) async throws -> MemberList {
        try await ensureCurrent()
        let m = try MemberList.verify(raw, wsk: cfg.wsk)
        guard m.workspace == cfg.workspace else { throw SessionError.badResponse }
        guard Int64(m.epoch) >= (try await cfg.container.epochHighWater()) else { throw Refusal.badEpoch }
        guard let o = raw.object?["o"]?.object, let bytes = try? canonicalJSON(.object(o)) else { throw Refusal.malformed }
        // Every listed person has a member device of that person (P3-D6); the owner rule binds first lists (checked at join).
        let bound = Set(m.members.map(\.personID))
        guard Set(m.persons).isSubset(of: bound) else { throw Refusal.otherPerson }
        do {
            try await cfg.container.acceptMemberListHead(listSeq: m.listSeq, epoch: Int64(m.epoch), digest: Data(SHA256.hash(data: bytes)),
                                                         wkCommit: m.wkCommit, members: m.members.map(\.deviceID.hex))
        } catch let e as MemberListHeadError {
            switch e {
            case .rollback: throw Refusal.staleList
            case .conflict: throw Refusal.conflictingSnapshot
            case .epochFell: throw Refusal.badEpoch
            case .rotationRequired: throw Refusal.rotationRequired
            case .wkCommitConflict: keys.removeAll(); absentKeys.removeAll(); throw Refusal.wkCommitConflict
            }
        }
        keys.removeAll(); absentKeys.removeAll()          // a newly held commitment re-decides which keys are usable
        return m
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

    /// The durable marker of a logical request whose delivery the relay ended with 409 `retry_exhausted`. It lives in `meta` so that it
    /// is written in the SAME transaction as the attempt's `uncertain` state: no crash can leave an uncertain attempt without it, so
    /// automatic reconciliation can never reissue it. Only an explicit retry (which replaces the attempt) or a final outcome removes it.
    static func exhaustedKey(_ logical: ID16) -> String { "exhausted:" + logical.hex }

    /// Puts an earlier attempt of the same rid back, durably `uncertain` (a same-rid re-seal the host answered with `rid_conflict`).
    private func restoreUncertain(_ o: Row) async throws {
        try await cfg.container.database().execute(
            "UPDATE bridge_requests SET seq=?, epoch=?, envelope=?, sent_ms=?, created_ms=?, state='uncertain' WHERE rid=?",
            [.int(Int64(o.seq)), .int(Int64(o.epoch)), .blob(o.envelope), .int(o.sentMs), .int(o.createdMs), .text(o.rid.hex)])
    }

    private func markExhausted(_ row: Row) async throws {
        try await cfg.container.database().transaction { tx in
            try tx.execute("UPDATE bridge_requests SET state='uncertain' WHERE rid=?", [.text(row.rid.hex)])
            try tx.execute("INSERT INTO meta(key,value) VALUES(?,1) ON CONFLICT(key) DO NOTHING", [.text(Self.exhaustedKey(row.logical))])
            try tx.execute("UPDATE decisions SET state='exhausted' WHERE id=? AND state<>'resolved'", [.text(row.logical.hex)])
        }
    }

    package func isExhausted(_ logical: ID16) async throws -> Bool {
        try await !cfg.container.database().query("SELECT value FROM meta WHERE key=?", [.text(Self.exhaustedKey(logical))]).isEmpty
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
    private func prepare(logical: ID16, plaintext: Data, minSeq: UInt64 = 0, replacing old: ID16? = nil, reconciled: Bool = false,
                         clearExhausted: Bool = false, reuseRid: Bool = false, decision: (QuestionReview, String)? = nil) async throws -> Row {
        let lifecycle = reviewLifecycle
        try Task.checkCancellation()
        try await ensureCurrent()
        guard plaintext.count + Bridge.overhead <= Bridge.maxRequest else { throw SessionError.tooLarge }
        let (epoch, wk) = try await sealingKeyRecovering()
        let offset = try await clockOffsetMs()
        let now = cfg.wall.nowMs
        let (ws, dev, identity, entropy, hook) = (cfg.workspace, cfg.deviceID, cfg.identity, cfg.entropy, crashHook)
        // `reuseRid`: the relay refused the old attempt as a NEW rid (unsigned stale_epoch hint); the new seal keeps its rid.
        let rid = reuseRid ? (old ?? entropy.id16()) : entropy.id16(), salt = entropy.bytes(16)
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
            var firstCreated = now                       // a same-rid re-seal keeps the first copy's time (the 240 s bound)
            if reuseRid, let old {                       // same key: delete first; a crash anywhere in here rolls both back
                firstCreated = try tx.query("SELECT created_ms FROM bridge_requests WHERE rid=?", [.text(old.hex)]).first?.int("created_ms") ?? now
                try tx.execute("DELETE FROM bridge_requests WHERE rid=?", [.text(old.hex)])
                try hook?("replace.deleted")
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
                           [.text(rid.hex), .text(logical.hex), .int(Int64(seq)), .int(Int64(epoch)), .blob(env), .blob(plaintext), .int(now), .int(firstCreated)])
            try tx.execute("INSERT INTO meta(key,value) VALUES('next_seq', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.int(Int64(seq) + 1)])
            if reuseRid { try hook?("replace.inserted") }
            if let old, !reuseRid {
                try hook?("replace.inserted")
                try tx.execute("DELETE FROM bridge_requests WHERE rid=?", [.text(old.hex)])
                try hook?("replace.deleted")
            }
            // An explicit retry replaces the exhausted attempt and its marker together.
            if clearExhausted { try tx.execute("DELETE FROM meta WHERE key=?", [.text(Self.exhaustedKey(logical))]) }
            return Row(rid: rid, logical: logical, seq: seq, epoch: epoch, envelope: env, plaintext: plaintext, stream: false,
                       offsetAdopted: false, sentMs: now, createdMs: firstCreated, uncertain: false)
        }
        if let old, old != rid { monotonicAge[old] = nil }
        ridLogical[rid] = logical
        if !(reuseRid && monotonicAge[rid] != nil) { monotonicAge[rid] = Self.marker(cfg.clock) }
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
        try await cfg.container.database().transaction { tx in
            try tx.execute("DELETE FROM meta WHERE key=?", [.text(Self.exhaustedKey(logical))])
            return try tx.execute("DELETE FROM bridge_requests WHERE logical=? AND state='uncertain'", [.text(logical.hex)])
        }
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

    /// The device context with the read keys of `epochs` (loaded lazily, Q10-checked).
    package func context(epochs: Set<UInt32>) async throws -> Bridge.DeviceContext {
        var wk: [UInt32: SymmetricKey] = [:]
        for e in epochs { if let k = try await readKey(e) { wk[e] = k } }
        return Bridge.DeviceContext(workspace: cfg.workspace, device: cfg.deviceID, wsk: cfg.wsk, wk: wk, offsetMs: try await clockOffsetMs())
    }

    /// Section 8.8 for one chunk against this session's own keys, pin and offset, with an explicit pending table.
    package func check(response envelope: Data, mailbox: Bridge.MailboxPosition, pending: [ID16: Bridge.PendingRequest], nowMs: Int64)
        async throws -> (outcome: Bridge.ResponseOutcome, pending: [ID16: Bridge.PendingRequest]) {
        try await ensureCurrent()
        var epochs = Set(pending.values.map(\.epoch))
        if let h = try? Bridge.Parts(envelope: envelope).header { epochs.insert(h.epoch) }
        return Bridge.checkResponse(envelope, context: try await context(epochs: epochs), pending: pending, mailbox: mailbox, nowMs: nowMs)
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

    /// The relay's answer to a device post (protocol-v2 sections 19.3 and 19.6). Only 202 and 429 promise anything about the rid; the
    /// device then keeps polling THAT rid and never reissues the operation under a new one.
    private enum Posted {
        case accepted
        /// 429 (requeue interval or a quota): keep polling the same rid; the refusal is reported if no answer comes. (A 503 queued
        /// nothing and is surfaced at once; the request stays pending for a byte-identical `resend`.)
        case throttled(RelayRefusal)
        /// 409 `retry_exhausted`: terminal. Keep polling while the relay retains a queued copy, then surface it (no reissue).
        case exhausted
        /// 409 `stale_epoch` for a NEW rid: nothing was queued. An unsigned hint (P3-D8).
        case staleEpochHint(RelayRefusal)
        /// 410 `expired`: the relay no longer knows the rid. Its outcome cannot be known from the bridge.
        case expired
    }

    private func drive(_ start: Row, isResend: Bool) async throws -> BridgeResponse {
        var row = start
        var original: Row?          // the attempt before a same-rid re-seal: restored if the host answers rid_conflict
        for _ in 0..<Self.maxAttempts {
            try Task.checkCancellation()
            try await ensureCurrent()
            if try await pinFailures() >= 3 { throw SessionError.pairAgain }
            let posted = try await post(row)
            switch posted {
            case .staleEpochHint(let hint):
                // P3-D8. The relay refused this rid as NEW, so nothing was queued and the host never saw it. The hint is unsigned:
                // it only triggers a bounded refetch of the signed list and grants, and the epoch moves only to what they confirm.
                // A resend is never re-signed (U8); a first attempt is re-sealed under a new rid only if the SIGNED list confirms
                // an epoch above the attempt's, which the host would refuse anyway (section 8.6 step 9).
                if isResend { try await markUncertain(row.rid); throw SessionError.uncertain(logical: row.logical) }
                let confirmed = try await refetchForEpochHint()
                // No signed list confirms a newer epoch (yet): the request stays pending; the hint is only data.
                guard confirmed > row.epoch else { throw SessionError.awaitingSignedEpoch(hint: hint.epoch) }
                // Bounded (orch-29 Q14): only within 240 s of the first copy; later the request is reconciled, never re-sealed.
                guard ageMs(row) < Self.resealWindowMs else { try await markUncertain(row.rid); throw SessionError.uncertain(logical: row.logical) }
                if original == nil { original = row }
                // Re-sealed under the SAME rid (orch-29 Q14, provisional): the relay's "never queued" is unsigned. An honest relay
                // recorded nothing and accepts the new bytes; if a lying relay had delivered the first copy, the host knows the rid
                // with other bytes and answers `rid_conflict`, which ends uncertain below. Nothing can run twice.
                row = try await prepare(logical: row.logical, plaintext: row.plaintext, replacing: row.rid, reuseRid: true)
                continue
            case .expired:
                try await markUncertain(row.rid); throw SessionError.uncertain(logical: row.logical)
            case .accepted, .throttled, .exhausted:
                break
            }
            // After 202, 429 and even retry_exhausted the device polls the SAME rid for an answer (section 19.6).
            switch try await collect(row) {
            case .response(let r):
                try await ensureCurrent()
                try await retireCompletedAttempt(row)
                return r
            case .timeout:
                switch posted {
                case .exhausted:
                    // Terminal: never reissued under a new rid automatically. Durable `uncertain` keeps the exact bytes for an
                    // explicit, state-checked user retry.
                    try await markExhausted(row); throw SessionError.retryExhausted(logical: row.logical)
                case .throttled(let r): throw ClientError.relay(r)          // still pending: `resend` re-sends the same bytes
                default: throw SessionError.noResponse(rid: row.rid)
                }
            case .refusal(let refusal, let fetch, let offsetAdopted):
                // A sealed, host-signed answer for this rid: the host refused it WITHOUT running it. Only these re-sign under a new
                // rid (section 8.5, v1 section 5.1/5.3), and only on the first attempt of a call; never on a resend (U8).
                switch refusal {
                case .alreadyDone(status: "unknown"):
                    try await markUncertain(row.rid); throw SessionError.uncertain(logical: row.logical)
                case .ridConflict:
                    // The host holds other bytes for this rid: a same-rid re-seal after the relay's hint whose first copy a lying
                    // relay did deliver. The relay misbehaved: uncertain, and the ORIGINAL attempt (its bytes, seq and epoch) is
                    // what is kept, so an answer to it can still be verified (orch-29 Q14).
                    if let o = original { try await restoreUncertain(o) } else { try await markUncertain(row.rid) }
                    throw SessionError.uncertain(logical: row.logical)
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
                    // Terminal host refusals, `not_visible` among them (a restricted ticket, P3-D14; P3 hosts refuse it): the host
                    // did not run the request. Nothing is re-sent or re-signed; the typed refusal is surfaced (fail closed).
                    try await retireCompletedAttempt(row)
                    throw ClientError.host(refusal)
                }
            }
        }
        throw SessionError.epochUnavailable(wanted: 0)
    }

    /// The bounded answer to the relay's unsigned `stale_epoch` hint: refetch the signed grants and member list (P3-D8). Returns the
    /// confirmed epoch; never raises it from the hint. A newer confirmed epoch resets the limiter (a relay cannot forge one).
    private func refetchForEpochHint() async throws -> UInt32 {
        let before = try await currentEpoch()          // read before the limiter decides, so no suspension separates admit and fetch
        let now = sessionAge()
        guard epochHintLimiter.admit(at: now) else {
            let until = epochHintLimiter.nextAllowed(at: now) ?? now
            let c = (until - now).components
            throw SessionError.epochRefetchDeferred(retryAfterMs: max(1, c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000))
        }
        let after = try await refreshGrants(forceList: true)       // the signed list, even if no grant is above the held head (Q10)
        if after > before { epochHintLimiter.reset() }
        return after
    }

    /// Tests: the limiter's state.
    package func epochHintLimiterState() -> EpochRefetchLimiter { epochHintLimiter }

    /// Decision attempts stay durable until their validated outcome commits in finishDecision.
    private func retireCompletedAttempt(_ row: Row) async throws {
        let deleted = try await cfg.container.database().execute(
            "DELETE FROM bridge_requests WHERE rid=? AND NOT EXISTS (SELECT 1 FROM decisions WHERE id=?)",
            [.text(row.rid.hex), .text(row.logical.hex)])
        if deleted > 0 { monotonicAge[row.rid] = nil }
    }

    private func post(_ row: Row) async throws -> Posted {
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
        if reply.status == 202 { _ = try HostAPI.expect(reply, status: 202); return .accepted }
        let failure = HostAPI.failure(of: reply)
        guard case .relay(let r) = failure else { throw failure }
        switch (r.status, r.code) {
        case (429, _): return .throttled(r)
        case (409, .retryExhausted): return .exhausted
        case (409, .staleEpoch): return .staleEpochHint(r)
        case (410, .expired): return .expired
        default: throw ClientError.relay(r)
        }
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
        return try await cfg.container.database().query(
            "SELECT d.*, EXISTS(SELECT 1 FROM meta WHERE key='exhausted:'||d.id) AS exhausted FROM decisions d WHERE d.state <> 'resolved' ORDER BY d.rowid").compactMap { r in
            guard let id = r.text("id").flatMap(ID16.init(hex:)), let q = r.text("question").flatMap(ID16.init(hex:)), let o = r.text("option_id") else { return nil }
            // The relay's terminal retry_exhausted: only the user's explicit retry (`retryDecision`) sends it again.
            if r.int("exhausted") == 1 || r.text("state") == "exhausted" {
                return DecisionStatus(decisionID: id, questionID: q, optionID: o, state: .needsRetry)
            }
            return DecisionStatus(decisionID: id, questionID: q, optionID: o, state: r.text("state") == "uncertain" ? .uncertain : .pending)
        }
    }
    /// - Throws: `StoreError.removalStateUnknown` if removal status cannot be verified.
    ///   Retry when coordination is available; this error does not confirm removal.
    public func reconcileDecision(_ id: ID16) async throws -> DecisionOutcome {
        guard foreground, !preparingDecisions.contains(id) || decisionDrivers[id] != nil else { throw ViewError.offline }
        return try await driveDecision(id)
    }
    /// The explicit user retry of a decision whose bridge delivery ended in the relay's terminal 409 `retry_exhausted` (protocol-v2
    /// section 19.6). Like reconciliation it reads the question first (an answer already recorded is final) and only while the
    /// question is still open with the same content does it send the SAME signed decision again, under a new rid. Automatic
    /// reconciliation (`reconcileDecision`, `recoverDecisions`) never does this for an exhausted decision.
    /// - Throws: `StoreError.removalStateUnknown` if removal status cannot be verified.
    public func retryDecision(_ id: ID16) async throws -> DecisionOutcome {
        guard foreground, !preparingDecisions.contains(id) || decisionDrivers[id] != nil else { throw ViewError.offline }
        return try await driveDecision(id, explicit: true)
    }
    private func recoverDecisions() {
        guard foreground, recovery == nil else { return }
        let identity = UUID(); recoveryIdentity = identity
        recovery = Task {
            defer { if self.recoveryIdentity == identity { self.recovery = nil; self.recoveryIdentity = nil } }
            do {
                for row in try await self.pendingDecisions() {
                    guard self.foreground, !Task.isCancelled else { return }
                    _ = try? await self.reconcileDecision(row.decisionID)       // read-only for an exhausted decision
                }
            } catch { self.emit(.connection(.offline)) }
        }
    }

    private func driveDecision(_ id: ID16, first: Row? = nil, explicit: Bool = false) async throws -> DecisionOutcome {
        if let t = decisionDrivers[id] { return try await t.value }
        let t = Task { try await self.performDecision(id, first: first, explicit: explicit) }
        decisionDrivers[id] = t
        defer { decisionDrivers[id] = nil }
        return try await t.value
    }
    private func performDecision(_ id: ID16, first: Row?, explicit: Bool) async throws -> DecisionOutcome {
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
        // Derived from the marker written atomically with the attempt's state, not from `decisions.state` alone (written with it).
        let exhausted = try await isExhausted(id) || record.text("state") == "exhausted"
        do {
            result = try await decisionNetwork(id, qid: qid, op: op, old: old, first: first, reissue: explicit || !exhausted)
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
            // A terminal relay retry_exhausted stays `exhausted` until an explicit retry; anything else is `uncertain`.
            let needsRetry = try await isExhausted(id)
            try await db.execute("UPDATE decisions SET state=? WHERE id=?", [.text(needsRetry ? "exhausted" : "uncertain"), .text(id.hex)])
            return needsRetry ? .needsRetry : .uncertain
        }
        return try await finishDecision(id, result)
    }
    private func decisionNetwork(_ id: ID16, qid: ID16, op: JSONValue, old: Row?, first: Row?, reissue: Bool) async throws -> DecisionOutcome {
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
                // After the relay's terminal retry_exhausted only the user's explicit retry may reissue (section 19.6).
                guard reissue else { throw SessionError.retryExhausted(logical: id) }
                // Only this authoritative open-state reconciliation can replace an uncertain row.
                // The old row and its state survive until the replacement commits atomically.
                let next = try await prepare(logical: id, plaintext: Bridge.frame(meta: op, data: Data()), replacing: old?.rid, reconciled: true,
                                             clearExhausted: true)
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
        } catch ClientError.host(.notVisible) {
            return .notApplied           // sealed, terminal and definite: recorded, did not apply (orch-29 Q2)
        }
    }
    private func finishDecision(_ id: ID16, _ result: DecisionOutcome) async throws -> DecisionOutcome {
        try await ensureCurrent()
        let attempts = try await cfg.container.database().query("SELECT rid FROM bridge_requests WHERE logical=?", [.text(id.hex)])
        let encoded = try canonicalJSON(encodeOutcome(result))
        try await cfg.container.database().transaction { tx in
            try tx.execute("UPDATE decisions SET state='resolved',outcome=? WHERE id=?", [.blob(encoded), .text(id.hex)])
            try tx.execute("DELETE FROM bridge_requests WHERE logical=?", [.text(id.hex)])
            try tx.execute("DELETE FROM meta WHERE key=?", [.text(Self.exhaustedKey(id))])
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
                let next = try await prepare(logical: draft.creationID, plaintext: plaintext, replacing: old.rid, reconciled: true, clearExhausted: true)
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
    case .needsRetry: ["kind": "needs_retry"]
    case .notApplied: ["kind": "not_applied"]
    case .alreadyAnswered(let label, let at): ["kind": "already_answered", "label": .string(label), "at": .int(at)]
    case .questionChanged(let hash): ["kind": "question_changed", "hash": .string(B64U.encode(hash))]
    }
}
private func decodeOutcome(_ v: JSONValue) throws -> DecisionOutcome {
    guard let m = v.object else { throw ViewError.malformed }
    switch m["kind"]?.string {
    case "accepted": return .accepted
    case "not_applied": return .notApplied
    case "already_answered": guard let l = m["label"]?.string, let a = m["at"]?.int else { throw ViewError.malformed }; return .alreadyAnswered(label: l, at: a)
    case "question_changed": guard let h = m.b64uField("hash", length: 32) else { throw ViewError.malformed }; return .questionChanged(hash: h)
    default: throw ViewError.malformed
    }
}

extension WorkspaceSession {
    package func dropRelaySession() async throws -> RelaySession { try await ensureCurrent(); return try await relaySession() }
    /// A key to READ a Drop wrap of `epoch` with (any verified grant's, checked against a held `wk_commit`).
    package func dropKey(_ epoch: UInt32) async throws -> SymmetricKey {
        try await ensureCurrent()
        guard let key = try await readKey(epoch) else { throw SessionError.noKeyForEpoch(epoch) }
        return key
    }

    /// The key to SEAL a new Drop wrap under: the same rule as the bridge (`sealingKey`), at exactly `epoch`.
    package func dropSealKey(_ epoch: UInt32) async throws -> SymmetricKey {
        try await ensureCurrent()
        let s = try await sealingKeyRecovering()
        guard s.epoch == epoch else { throw SessionError.noKeyForEpoch(epoch) }
        return s.key
    }
}
