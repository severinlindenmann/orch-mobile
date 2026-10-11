import CryptoKit
import Foundation
import OrchCustody
import OrchProtocol
import OrchStore

/// Tests only: thrown by a lifecycle hook to simulate the process dying at that point (nothing after it runs, nothing is cleaned up).
package struct PairingCrash: Error, Equatable { package init() {} }

/// The phone's pairing state machine (host-api section 6, U5). One coordinator drives one pairing at a time. Screens see only this
/// type: they never hold a key, a secret or a FakeHost. Every send is preceded by a persisted record; every verified answer is
/// pinned before a code is shown; nothing is installed until the certificate, the card (with its `CK`), the member list and the
/// `WK` grant all verified.
///
/// Lifecycle ownership: `start` reserves it before its first await (state `parsing`), `token` is bumped by every supersession (cancel,
/// finish, alarm) and checked after every await, `installing` marks the one installer that may touch the container and the vault, and
/// `commitJoin` is the single linearization point of a join (conditional on the pairing row still being owned). Persistence and erasure
/// are serialized by `gate`, so an erase never interleaves with a save.
public actor PairingCoordinator {
    let cfg: PairingConfig
    private var record: PairingRecord?
    private var identity: DeviceIdentity?
    private var current: PairingState = .idle
    /// Observation barrier for tests; time-derived changes need not have been published yet.
    internal var lastPublishedState: PairingState { current }
    private var alarmRow: PairingAlarm?
    private var token = 0
    private var busy = false
    /// An installer is running (container, session, grants, commit). Cancel waits for it before erasing anything.
    private var installing = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    /// A cancel or dismiss is in progress: no new start until it has finished.
    private var lifecycleBusy = false
    /// Simulated process death (tests): the instance does nothing more.
    private var dead = false
    private var gateHeld = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    /// False after a restart until a fresh verified answer arrives: a comparison is never shown from stored state alone.
    private var reverified = true
    // schedule (wall milliseconds); not persisted: after a restart the stored request is polled at once
    private var nextPostMs: Int64 = 0
    private var nextGetMs: Int64 = 0
    private var retryNotBeforeMs: Int64 = 0
    private var failures = 0
    private var streams: [Int: AsyncStream<PairingState>.Continuation] = [:]
    private var nextStreamID = 0
    private var wakers: [Int: AsyncStream<Void>.Continuation] = [:]
    /// Tests only: runs at named lifecycle points; throwing `PairingCrash` kills the instance there, a suspension holds it there.
    package var hook: (@Sendable (String) async throws -> Void)?
    package func setHook(_ h: (@Sendable (String) async throws -> Void)?) { hook = h }

    // Intervals (host-api section 3): pair_status no faster than every 5 s, 10 s in cert_pending; 20/40/60 s after a transport failure
    // or 429, with Retry-After as a minimum.
    static let statusIntervalMs: Int64 = 5_000
    static let certPendingIntervalMs: Int64 = 10_000
    static let getIntervalMs: Int64 = 5_000
    static let backoffMs: [Int64] = [20_000, 40_000, 60_000]
    static let firstAnswerDeadlineMs: Int64 = 60_000
    static let preApprovalCapMs: Int64 = 600_000
    static let certificationMs: Int64 = CertRequest.lifetimeMs
    /// After a challenge expired the phone waits this long for a last `approved`/`expired`; the code is hidden and no deadline is extended.
    static let certificationGraceMs: Int64 = 60_000
    static let joiningCapMs: Int64 = 60_000
    /// Retrying a timed-out join ends here, counted from the first `approved` (or at the certificate's own expiry, whichever is first).
    static let joinRetryWindowMs: Int64 = 600_000
    static let pairResendMs: Int64 = 15_000
    static let statusResendMs: Int64 = 30_000

    private let elapsedMs: @Sendable () -> Int64
    private var wallAnchorMs: Int64
    private var elapsedAnchorMs: Int64 = 0

    private static func elapsed<C: Clock<Duration>>(_ clock: C) -> @Sendable () -> Int64 {
        let anchor = clock.now
        return {
            let d = anchor.duration(to: clock.now).components
            return saturatingAdd(d.seconds * 1000, d.attoseconds / 1_000_000_000_000_000)
        }
    }

    public init(_ config: PairingConfig) {
        cfg = config
        wallAnchorMs = config.wall.nowMs
        elapsedMs = Self.elapsed(config.clock)
    }

    // Monotonic elapsed time bounds every active deadline, even if wall time moves backwards.
    // Persisted absolute deadlines retain their original bounds on resume; monotonic instants cannot cross a reboot.
    private var nowMs: Int64 {
        let elapsed = elapsedMs()
        wallAnchorMs = max(cfg.wall.nowMs, saturatingAdd(wallAnchorMs, elapsed - elapsedAnchorMs))
        elapsedAnchorMs = elapsed
        return wallAnchorMs
    }

    // MARK: realm boundary

    /// The transport's context (realm, origin, Demo generation), the index's realm and the vault group must be the pairing context's own.
    /// Checked before any custody access, store access or I/O, and again before every poll.
    private func checkConfig() throws {
        let t = cfg.transport.context
        guard t.realm == cfg.context.realm, t.origin == cfg.context.origin, t.generation === cfg.context.generation else {
            throw RealmViolation.wrongTransport
        }
        guard cfg.vault.group == .keys, cfg.index.layout.realm == cfg.context.realm.rawValue else { throw RealmViolation.wrongStore }
        try cfg.context.generation?.check()
    }

    /// Custody and vault access of a Demo context are one step against `DemoGeneration.invalidate`.
    private func perform<T>(_ body: () throws -> T) throws -> T {
        try cfg.context.generation.map { try $0.perform(body) } ?? body()
    }

    private func violation(_ error: Error) -> PairingFailure {
        if let v = error as? RealmViolation { return .realm(v) }
        return .custody
    }

    // MARK: serialization of persistence and erasure

    private func lockGate() async {
        if !gateHeld { gateHeld = true; return }
        await withCheckedContinuation { gateWaiters.append($0) }
    }

    private func unlockGate() {
        if gateWaiters.isEmpty { gateHeld = false } else { gateWaiters.removeFirst().resume() }
    }

    private func drainInstall() async {
        if installing { await withCheckedContinuation { drainWaiters.append($0) } }
    }

    private func signalWake() { for c in wakers.values { c.yield() } }

    private func crashPoint(_ name: String) async throws {
        if let h = hook { try await h(name) }
    }

    // MARK: observation

    /// The state as of now: a challenge's code is hidden the instant it expires, whatever was last polled.
    public var state: PairingState { derive(at: nowMs) }

    /// A fresh single-consumer stream: the current state first, then every change.
    public func states() -> AsyncStream<PairingState> {
        let id = nextStreamID; nextStreamID += 1
        let (stream, cont) = AsyncStream<PairingState>.makeStream(bufferingPolicy: .bufferingNewest(16))
        streams[id] = cont
        cont.onTermination = { [weak self] _ in Task { await self?.dropStream(id) } }
        cont.yield(state)
        return stream
    }

    private func dropStream(_ id: Int) { streams[id] = nil }

    private func publish(_ s: PairingState) {
        current = s
        for c in streams.values { c.yield(s) }
    }

    /// Lists the pairings a restart finds in the index (a pending one to resume, or a terminal alarm to show again).
    public static func pending(in index: WorkspaceIndex) async throws -> [PairingRow] { try await index.pairings() }

    // MARK: start

    private enum StoredCert {
        case missing
        /// The vault could not be read (locked): nothing is assumed.
        case unreadable
        /// Present but not authentic, not for this device's keys, or not parseable.
        case corrupt
        case violation(RealmViolation)
        /// Authentic and for this device; `valid` is false once it expired (the owner binding stays).
        case present(owner: SigningPublicKey, cert: JSONValue, valid: Bool)
    }

    /// Strict link and realm validation, then the persisted record, then connecting. Nothing is sent when the link names an origin the
    /// realm may not reach, when the workspace is already here, or when an existing certificate belongs to another person.
    ///
    /// The lifecycle is reserved before the first await: a `cancel()` during the index lookups is honoured (the call returns
    /// `.cancelled`, creates nothing and removes keys it made).
    public func start(link: PairingLink) async -> PairingState {
        guard !dead, record == nil, !lifecycleBusy, !isBusyWithPairing else { return current }
        token += 1
        let mine = token
        publish(.parsing)
        try? await crashPoint("start.reserved")          // test seam, like `resume.row`: the lifecycle is held and nothing else has happened
        do { try checkConfig(); try cfg.context.admit(origin: link.origin) } catch { return fail(violation(error), mine) }
        let ws = link.workspace
        do {
            if try await cfg.index.workspaces().contains(where: { $0.ws == ws.hex }) { return fail(.alreadyMember, mine) }
            guard mine == token else { return self.current }
            if try await cfg.index.pairing(ws: ws.hex) != nil { return fail(.verification(reason: "pairing_in_progress"), mine) }
            guard mine == token else { return self.current }
            try await crashPoint("start.index")
        } catch is PairingCrash { dead = true; return self.current } catch { return fail(.custody, mine) }
        guard mine == token else { return self.current }
        // device keys: existing identity is kept (D-1); new keys are created only now and remembered as ours to remove on cancel
        let created: Bool
        let id: DeviceIdentity
        do {
            created = try perform { cfg.custody.status(realm: cfg.context.realm) == .missing }
            id = try cfg.context.deviceIdentity(custody: cfg.custody, createIfMissing: true)
        } catch { return fail(violation(error), mine) }
        identity = id
        let deviceID = Identifiers.deviceID(id.publicKeys.sig)
        // an existing certificate must belong to the owner the link pins; otherwise nothing is sent
        var existing: JSONValue?
        switch storedCertificate() {
        case .missing: break
        case .unreadable, .corrupt:
            await dropNewKeys(created); return fail(.custody, mine)
        case .violation(let v): await dropNewKeys(created); return fail(.realm(v), mine)
        case .present(let owner, let cert, let valid):
            if Identifiers.pkPin(owner) != link.pkPin { await dropNewKeys(created); return fail(.otherPerson, mine) }
            existing = valid ? cert : nil          // an expired certificate keeps the owner binding but is not presented
        }
        let now = nowMs
        let generation: Int64
        do {
            generation = try await cfg.index.nextGeneration(ws: ws.hex)
            try await crashPoint("start.keys")
        } catch is PairingCrash { dead = true; return self.current } catch { await dropNewKeys(created); return fail(.custody, mine) }
        guard mine == token else { await dropNewKeys(created); return self.current }
        var r = PairingRecord(generation: generation, origin: link.origin, ws: ws, offer: link.offer, secret: link.secret, wskPin: link.wskPin,
                              pkPin: link.pkPin, deviceID: deviceID, label: cfg.deviceLabel, createdKeys: created, existingCert: existing,
                              startedMs: now, lastProgressMs: now)
        r.seq = 1
        record = r
        nextPostMs = now; nextGetMs = now; failures = 0; retryNotBeforeMs = 0
        switch await save(mine) {
        case .saved: break
        case .superseded:
            // cancelled while saving: the cancel erased what it could see; make sure nothing of this pairing is left
            if record == nil || record?.generation != generation { _ = await purgeResidue(ws: ws, createdKeys: created, keepRow: false, gate: true) }
            return self.current
        case .failed:
            _ = await finish(.failed(.custody), mine); return self.current
        }
        publish(.connecting(origin: link.origin))
        return self.current
    }

    private var isBusyWithPairing: Bool { if case .idle = current { return false }; return !current.isTerminal }

    private func dropNewKeys(_ created: Bool) async {
        guard created else { return }
        _ = await removeKeysIfUnused(excluding: nil)
    }

    /// After a restart: revalidate expiry, custody and generation, show no comparison, then poll the stored request. A terminal alarm
    /// comes back as the same alarm, and its secrets are cleaned (again) first.
    public func resume(ws: ID16) async -> PairingState {
        guard !dead, record == nil, !lifecycleBusy, !isBusyWithPairing else { return current }
        // Ownership is reserved before the first await, exactly like `start`: `parsing` makes a concurrent start/resume return at once
        // and lets a cancel() during the lookups end this call; every suspension below re-checks `mine`.
        let previous = current
        token += 1
        let mine = token
        publish(.parsing)
        try? await crashPoint("resume.row")
        func giveBack() -> PairingState { if mine == token { publish(previous) }; return current }
        do { try checkConfig() } catch { return fail(violation(error), mine) }
        let row: PairingRow
        do {
            guard let r = try await cfg.index.pairing(ws: ws.hex) else { return giveBack() }
            row = r
        } catch { return fail(.custody, mine) }
        guard mine == token else { return current }
        reverified = true
        if let t = row.terminal {
            if t == "cleanup" {
                _ = await purgeResidue(ws: ws, createdKeys: row.createdKeys, keepRow: false, gate: true)
                return giveBack()
            }
            if t.hasPrefix("alarm:"), let kind = PairingAlarmKind(rawValue: String(t.dropFirst(6))) {
                _ = await purgeResidue(ws: ws, createdKeys: row.createdKeys, keepRow: true, gate: true)
                guard mine == token else { return current }
                alarmRow = PairingAlarm(kind: kind, primaryLabel: row.detail)
                publish(.alarm(alarmRow!)); return current
            }
            _ = await purgeResidue(ws: ws, createdKeys: row.createdKeys, keepRow: false, gate: true)
            return giveBack()
        }
        let r: PairingRecord
        switch readRecord(ws: ws.hex) {
        case .transient:
            return fail(.custody, mine)             // locked or unavailable: the pairing stays exactly as it is, to be resumed later
        case .found(let rec) where rec.ws == ws && rec.generation == row.generation:
            r = rec
        default:
            _ = await purgeResidue(ws: ws, createdKeys: row.createdKeys, keepRow: false, gate: true)
            return fail(.custody, mine)
        }
        guard (try? cfg.context.admit(origin: r.origin)) != nil else { return await endResumed(r, mine) }
        try? await crashPoint("resume.custody")
        guard mine == token else { return current }
        let removal = await cfg.index.removalStatus(ws: ws.hex, generation: r.generation)
        guard mine == token else { return current }
        switch removal {
        case .unknown: return fail(.custody, mine)
        case .removed: return await endResumed(r, mine)
        case .notRemoved: break
        }
        guard (-Bridge.maxOffsetMs...Bridge.maxOffsetMs).contains(r.offsetMs) else { return await endResumed(r, mine) }
        let id: DeviceIdentity
        do { id = try cfg.context.deviceIdentity(custody: cfg.custody, createIfMissing: false) }
        catch CustodyError.missing { return await endResumed(r, mine) }
        catch CustodyError.orphaned { return await endResumed(r, mine) }
        catch { return fail(.custody, mine) }            // locked, unavailable, stale Demo: the pairing is preserved untouched
        guard Identifiers.deviceID(id.publicKeys.sig) == r.deviceID else { return await endResumed(r, mine) }
        guard mine == token else { return current }
        identity = id
        record = r
        pinDeadlines()
        reverified = false
        let now = nowMs
        nextPostMs = now; nextGetMs = now; failures = 0; retryNotBeforeMs = 0
        if let end = await expireIfNeeded(now) { return end }
        guard mine == token else { return current }
        // the comparison UI is cleared; the next verified answer shows it again
        publish(r.phase == .joining ? .joining : .connecting(origin: r.origin))
        return current
    }

    private func endResumed(_ r: PairingRecord, _ mine: Int) async -> PairingState {
        guard mine == token else { return current }
        record = r
        return await finish(.failed(.custody), mine)
    }

    private enum RecordRead { case found(PairingRecord), missing, corrupt, transient }

    /// Only `notFound` is a missing record. A locked or unavailable keychain is transient: nothing may be purged on its account.
    private func readRecord(ws: String) -> RecordRead {
        let data: Data
        do { data = try vault().get(ws: ws, purpose: "pairing") }
        catch VaultError.notFound { return .missing }
        catch { return .transient }
        return PairingRecord.decode(data).map { .found($0) } ?? .corrupt
    }

    // MARK: cancel / dismiss

    /// Local cancellation from any pre-ready state. Erases the secret, `K_pair`, pending envelopes, challenges, codes and uncommitted
    /// installs; new device keys only if nothing else uses them. It cannot un-use the offer or retract a certificate already issued.
    /// During `start` it stops the start; during an install it waits for the installer, which then rolls back (or, if it already
    /// committed, undoes the join with a tombstone) before anything is erased.
    public func cancel() async {
        guard !dead else { return }
        if record == nil, case .parsing = current { token += 1; publish(.cancelled); return }
        guard record != nil, !current.isTerminal else { return }
        lifecycleBusy = true; defer { lifecycleBusy = false }
        token += 1
        await drainInstall()
        _ = await eraseAll()
        record = nil
        publish(.cancelled)
        signalWake()
    }

    /// The person has read a terminal state or an alarm: the alarm row goes away (with whatever secret it still has).
    public func dismiss() async {
        guard !dead else { return }
        lifecycleBusy = true; defer { lifecycleBusy = false }
        if record != nil { token += 1; await drainInstall(); _ = await eraseAll(); record = nil }
        for row in (try? await cfg.index.pairings()) ?? [] where row.terminal != nil {
            if let ws = ID16(hex: row.ws) { _ = await purgeResidue(ws: ws, createdKeys: row.createdKeys, keepRow: false, gate: true) }
        }
        alarmRow = nil
        token += 1
        publish(.idle)
        signalWake()
    }

    // MARK: driving

    /// Runs until a terminal state or cancellation: sleeps on the injected clock until the next request or the earliest deadline is due,
    /// then polls. After `failed(.joiningTimedOut)` it does not spin: it waits for `retryJoin()`, `cancel()` or the end of the retry window.
    public func run() async {
        while !dead, record != nil, !current.isTerminal {
            if Task.isCancelled { return }
            let now = nowMs
            if case .failed(.joiningTimedOut) = current {
                let end = record.flatMap { hardJoinEndMs($0) } ?? now
                await waitForWake(until: end)
                if Task.isCancelled { return }
                await poll()
                continue
            }
            var wake = max(nextDueMs() - now, 0)
            if let r = record, let d = earliestDeadlineMs(r) { wake = min(wake, max(d - now, 0)) }
            if wake > 0 {
                do { try await cfg.clock.sleep(for: .milliseconds(wake)) } catch { return }
            }
            await poll()
        }
    }

    /// Suspends until `signalWake()` or the wall deadline (on the injected clock), whichever is first.
    private func waitForWake(until endMs: Int64) async {
        let id = nextStreamID; nextStreamID += 1
        let (stream, cont) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakers[id] = cont
        defer { wakers[id] = nil }
        let wait = max(endMs - nowMs, 0)
        let clock = cfg.clock
        await withTaskGroup(of: Void.self) { g in
            g.addTask { try? await clock.sleep(for: .milliseconds(wait)) }
            g.addTask { for await _ in stream { return } }
            await g.next()
            g.cancelAll()
        }
    }

    private func nextDueMs() -> Int64 {
        guard let r = record else { return .max }
        if r.phase == .joining { return max(retryNotBeforeMs, 0) }
        if r.inflight?.posted == true { return max(nextGetMs, retryNotBeforeMs) }
        return max(nextPostMs, retryNotBeforeMs)
    }

    /// The earliest local deadline of the stored pairing: a longer Retry-After never delays it.
    private func earliestDeadlineMs(_ r: PairingRecord) -> Int64? {
        let now = nowMs
        var ds: [Int64] = []
        switch r.phase {
        case .connecting, .comparingHost:
            if r.wskPub == nil { ds.append(r.startedMs + Self.firstAnswerDeadlineMs) }
            ds.append(r.startedMs + Self.preApprovalCapMs)
        case .waitingPrimary, .comparingPrimary:
            if let exp = challengeExpiryLocalMs(r), exp > now { ds.append(exp) }       // the code disappears
            ds.append(certificationEndMs(r))
        case .joining:
            if current != .failed(.joiningTimedOut) { ds.append((r.joinStartedMs ?? now) + Self.joiningCapMs) }
            ds.append(hardJoinEndMs(r))
        }
        return ds.min()
    }

    /// One step of whatever is due now. Never throws; the outcome is the state. Calls overlap-safe: a second call while one is running
    /// returns at once, so a status request is never created while another is in flight.
    public func poll() async {
        guard !dead, !busy, record != nil, !current.isTerminal else { return }
        busy = true; defer { busy = false }
        let mine = token
        do { try checkConfig() } catch { _ = fail(violation(error), mine); return }
        var now = nowMs
        if await expireIfNeeded(now) != nil { return }
        guard mine == token, let r0 = record else { return }
        // the join's 60 s cap is enforced before any backoff: a backoff that crosses it never postpones the timeout
        if r0.phase == .joining, now - (r0.joinStartedMs ?? now) >= Self.joiningCapMs {
            if current != .failed(.joiningTimedOut) { publish(.failed(.joiningTimedOut)) }
            return
        }
        if now < retryNotBeforeMs { refreshState(now); return }
        if r0.phase == .joining { await join(mine); return }
        // 1. a request is created and persisted before it is sent
        if record?.inflight == nil {
            guard now >= nextPostMs else { refreshState(now); return }
            guard await makeRequest(now, mine) else { return }
            if mine != token { return }
        }
        // 2. POST (once; a lost POST is re-sent as the same bytes after the backoff)
        if record?.inflight?.posted == false {
            guard await post(mine) else { return }
            if mine != token { return }
            now = nowMs
        } else if now < nextGetMs { refreshState(now); return }
        // 3. GET the mailbox: once with each POST, then at most every 5 s while awaiting the answer
        await fetch(mine)
    }

    // MARK: request / post / fetch

    private func context() -> PairingWire.Context? {
        guard let r = record, let id = identity, let secret = r.secret else { return nil }
        let pubs = id.publicKeys
        return PairingWire.Context(workspace: r.ws, device: r.deviceID, offer: r.offer, secret: SymmetricKey(data: secret), wskPin: r.wskPin,
                                   pkPin: r.pkPin, dkSig: pubs.sig, dkKx: pubs.kx, offsetMs: r.offsetMs)
    }

    private func makeRequest(_ now: Int64, _ mine: Int) async -> Bool {
        guard var r = record, let id = identity, let c = context() else { return false }
        // `pair` until a `pending` was accepted (that is what pins the host's nonce); a clock correction, which also teaches the
        // host's key, must be answered with another `pair`, not a `pair_status` for a pairing the host never saw
        let isPair = r.sasNonce == nil
        let op: PairingWire.Op = isPair ? .pair(label: r.label, cert: r.existingCert) : .status
        let rid = cfg.entropy.id16()
        do {
            let env = try PairingWire.request(op, context: c, signer: id.sig, rid: rid, seq: r.seq, tsMs: saturatingAdd(now, r.offsetMs), salt: cfg.entropy.bytes(16))
            r.seq += 1
            r.inflight = PairingRecord.Inflight(rid: rid, isPair: isPair, envelope: env, posted: false, nextIdx: 0, offsetAdopted: false, createdMs: now)
            record = r
            return await persist(mine)
        } catch { _ = await finish(.failed(.custody), mine); return false }
    }

    private func route() -> PairRoute? {
        guard let r = record, let f = r.inflight else { return nil }
        return PairRoute(workspaceID: r.ws, offerID: r.offer, requestID: f.rid)
    }

    private func post(_ mine: Int) async -> Bool {
        guard let rt = route(), let env = record?.inflight?.envelope else { return false }
        do {
            let reply = try await cfg.transport.pairingPost(env, route: rt)
            guard mine == token else { return false }
            if reply.status == 202 {
                record?.inflight?.posted = true
                record?.lastPostMs = nowMs
                failures = 0
                nextGetMs = nowMs        // GET once with each POST
                return await persist(mine)
            }
            transportFailure(reply)
            return false
        } catch let t as TransportError {
            guard mine == token else { return false }
            if case .realm(let v) = t { _ = await finish(.failed(.realm(v)), mine) } else { transportFailure(nil) }
            return false
        } catch { if mine == token { transportFailure(nil) }; return false }
    }

    private func transportFailure(_ reply: WireReply?) {
        failures += 1
        let step = Self.backoffMs[min(failures - 1, Self.backoffMs.count - 1)]
        var wait = step
        if let reply, case .adapter(.rateLimited(let ra)) = HostAPI.failure(of: reply), let ra { wait = max(wait, Int64(ra) * 1000) }
        else if let reply, let ra = HostAPI.retryAfter(reply) { wait = max(wait, Int64(ra) * 1000) }
        retryNotBeforeMs = nowMs + wait
        refreshState(nowMs)
    }

    private func fetch(_ mine: Int) async {
        guard let rt = route(), let f = record?.inflight, let c = context() else { return }
        let after: UInt64? = f.nextIdx == 0 ? nil : f.nextIdx - 1
        let chunks: [HostAPI.Chunk]
        do {
            let reply = try await cfg.transport.pairingPoll(route: rt, after: after)
            guard mine == token else { return }
            guard reply.status == 200 else { transportFailure(reply); return }
            chunks = try HostAPI.chunks(reply.body).sorted { $0.idx < $1.idx }
        } catch let t as TransportError {
            guard mine == token else { return }
            if case .realm(let v) = t { _ = await finish(.failed(.realm(v)), mine) } else { transportFailure(nil) }
            return
        } catch { if mine == token { transportFailure(nil) }; return }
        failures = 0
        let now = nowMs
        // the deadlines are re-checked after the await: an answer that arrives past a cap does not extend it
        if await expireIfNeeded(now) != nil { return }
        guard mine == token else { return }
        var pend: [ID16: Bridge.PendingRequest] = [f.rid: Bridge.PendingRequest(next: f.nextIdx, stream: false, epoch: 0, offsetAdopted: f.offsetAdopted)]
        for ch in chunks where ch.id == f.rid {
            var cc = c; cc.offsetMs = record?.offsetMs ?? c.offsetMs
            let (outcome, table) = PairingWire.check(ch.envelope, context: cc, pending: pend,
                                                     mailbox: .init(id: ch.id, index: ch.idx, last: ch.last, stream: ch.stream), nowMs: now)
            switch outcome {
            case .drop(let why, let alarm, let label):
                if let kind = alarm { _ = await raiseAlarm(kind, primaryLabel: label ?? record?.primaryLabel, mine); return }
                _ = why                                         // silence: nothing else changes
            case .accept(let a):
                pend = table
                await apply(a, now: now, mine)
                return
            }
        }
        nextGetMs = now + Self.getIntervalMs
        // a request that has been unanswered for long enough is replaced by a fresh one (never two in flight)
        let limit = f.isPair ? Self.pairResendMs : Self.statusResendMs
        if now - f.createdMs >= limit {
            record?.inflight = nil
            nextPostMs = max(now, (record?.lastPostMs ?? 0) + interval())
            guard await persist(mine) else { return }
        }
        refreshState(now)
    }

    private func interval() -> Int64 {
        switch record?.phase {
        case .waitingPrimary?, .comparingPrimary?: Self.certPendingIntervalMs
        default: Self.statusIntervalMs
        }
    }

    // MARK: answers

    private func apply(_ a: PairingWire.Accepted, now: Int64, _ mine: Int) async {
        guard var r = record else { return }
        reverified = true
        r.inflight = nil
        r.lastProgressMs = now
        if r.wskPub == nil { r.wskPub = a.wskPub.x963 } else if r.wskPub != a.wskPub.x963 { r.wskPub = nil }
        guard r.wskPub != nil else { _ = await raiseAlarm(.pinSubstitution, primaryLabel: r.primaryLabel, mine); return }
        switch a.body {
        case .refusal(let code, _):
            if code == "stale_timestamp" {
                if a.clockWrong { _ = await finish(.failed(.clockWrong), mine); return }
                if let off = a.offsetMs, (-Bridge.maxOffsetMs...Bridge.maxOffsetMs).contains(off) { r.offsetMs = off; record = r; pinDeadlines(); nextPostMs = now; _ = await persist(mine); return }
                _ = await finish(.failed(.clockWrong), mine); return
            }
            switch code {
            case "pairing_closed": _ = await finish(.failed(.linkUsed), mine)
            case "other_person": _ = await finish(.failed(.otherPerson), mine)
            default: _ = await finish(.failed(.hostRefused(code: code)), mine)
            }
        case .pending(let nonce, _):
            if r.phase != .connecting && r.phase != .comparingHost { _ = await raiseAlarm(.regression, primaryLabel: r.primaryLabel, mine); return }
            if let pinned = r.sasNonce, pinned != nonce { _ = await raiseAlarm(.pinSubstitution, primaryLabel: r.primaryLabel, mine); return }
            r.sasNonce = nonce
            r.phase = .comparingHost
            record = r; pinDeadlines(); failures = 0; nextPostMs = r.lastPostMs + interval()
            guard await persist(mine) else { return }
            publish(derive(at: now))
        case .certPending(let label, let pk, let challenge):
            // the host's pending answer must have been seen first: it is what put a code on the phone for the person to compare
            guard r.sasNonce != nil else { _ = await raiseAlarm(.regression, primaryLabel: label, mine); return }
            if r.phase == .joining { _ = await raiseAlarm(.regression, primaryLabel: label, mine); return }
            if let pinned = r.pkPub, pinned != pk.x963 { _ = await raiseAlarm(.pinSubstitution, primaryLabel: label, mine); return }
            r.pkPub = pk.x963
            r.primaryLabel = label
            if r.certPendingSinceMs == nil { r.certPendingSinceMs = now }
            if let ch = challenge {
                if let pinned = r.challenge {
                    // an identical repeat is allowed; any substitution alarms
                    guard pinned == ch.signed else { _ = await raiseAlarm(.pinSubstitution, primaryLabel: label, mine); return }
                } else { r.challenge = ch.signed }
                r.phase = .comparingPrimary
            } else {
                if r.challenge != nil { _ = await raiseAlarm(.regression, primaryLabel: label, mine); return }
                r.phase = .waitingPrimary
            }
            record = r; pinDeadlines(); failures = 0; nextPostMs = r.lastPostMs + interval()
            guard await persist(mine) else { return }
            publish(derive(at: now))
        case .approved(let scopes, let cert, let certificate, let pk, let epoch):
            guard r.sasNonce != nil else { _ = await raiseAlarm(.regression, primaryLabel: r.primaryLabel, mine); return }
            if let pinned = r.pkPub, pinned != pk.x963 { _ = await raiseAlarm(.pinSubstitution, primaryLabel: r.primaryLabel, mine); return }
            // when a challenge was shown, the certificate must be for exactly the keys (and person) it named
            if let ch = r.challenge?.object?["o"]?.object {
                guard ch.b64uField("dk_sig_pub") == certificate.signingKey.x963, ch.b64uField("dk_kx_pub") == certificate.agreementKey.x963,
                      ch.idField("person_id") == certificate.personID, ch.idField("device_id") == certificate.deviceID
                else { _ = await raiseAlarm(.pinSubstitution, primaryLabel: r.primaryLabel, mine); return }
            }
            // realm and owner policy on top of the wire's signature checks (a live realm takes no Demo authority and the reverse)
            if let refusal = admissionFailure(cert: cert, owner: pk, offsetMs: r.offsetMs, now: now) { _ = await finish(.failed(refusal), mine); return }
            r.pkPub = pk.x963
            r.approved = .init(scopes: scopes, cert: cert, epoch: epoch)
            r.phase = .joining
            r.joinStartedMs = now
            r.approvedMs = now
            r.secret = nil                                  // `S` is not needed for the join: gone from the record the moment approval is pinned
            record = r; pinDeadlines(); failures = 0; retryNotBeforeMs = 0
            guard await persist(mine) else { return }
            publish(.joining)
        case .rejected: _ = await finish(.rejected, mine)
        case .expired: _ = await finish(.expired(r.certPendingSinceMs != nil ? .certification : .beforeApproval), mine)
        }
    }

    /// `RealmContext.admitCertificate` for a certificate that came off the wire (or out of a stored record), at host time.
    private func admissionFailure(cert: JSONValue, owner: SigningPublicKey, offsetMs: Int64, now: Int64) -> PairingFailure? {
        do { _ = try cfg.context.admitCertificate(cert, ownerKey: owner, nowMs: saturatingAdd(now, offsetMs)); return nil }
        catch let v as RealmViolation { return .realm(v) }
        catch Refusal.otherPerson { return .otherPerson }
        catch { return .verification(reason: "certificate") }
    }

    // MARK: deadlines

    /// The challenge's expiry on the phone's own clock: the signed deadline minus the adopted offset (host time = local + offset).
    /// Never later than the 10 minutes `cert_pending` itself can last, whatever the challenge claims.
    private func challengeExpiryLocalMs(_ r: PairingRecord) -> Int64? {
        guard let exp = r.challengeExpiresMs else { return nil }
        let local = exp.subtractingReportingOverflow(r.offsetMs)
        let e = local.overflow ? exp : local.partialValue
        let cap = saturatingAdd(r.certPendingSinceMs ?? r.lastProgressMs, Self.certificationMs)
        return min(e, cap, r.challengeDeadlineMs ?? Int64.max)
    }

    /// When a pairing in `cert_pending` ends here: the (clamped) challenge expiry or the 10 minutes of `cert_pending`, plus the grace
    /// that is only for the terminal transition. The code is hidden at the expiry itself.
    private func certificationEndMs(_ r: PairingRecord) -> Int64 {
        let base = challengeExpiryLocalMs(r) ?? saturatingAdd(r.certPendingSinceMs ?? r.lastProgressMs, Self.certificationMs)
        return saturatingAdd(base, Self.certificationGraceMs)
    }

    /// The end of the join retries: 10 minutes after the first `approved`, or the certificate's own expiry if that comes first.
    func hardJoinEndMs(_ r: PairingRecord) -> Int64 {
        var end = saturatingAdd(r.approvedMs ?? r.joinStartedMs ?? r.lastProgressMs, Self.joinRetryWindowMs)
        // `expires_ms` is host time; the phone's deadlines are local: convert through the adopted offset (host = local + offset)
        if let e = r.approved?.cert.object?["o"]?.object?["expires_ms"]?.int {
            let local = e.subtractingReportingOverflow(r.offsetMs)
            end = min(end, local.overflow ? e : local.partialValue)
        }
        return min(end, r.joinDeadlineMs ?? Int64.max)
    }

    private func pinDeadlines() {
        guard var r = record else { return }
        r.challengeDeadlineMs = challengeExpiryLocalMs(r)
        if r.approved != nil { r.joinDeadlineMs = hardJoinEndMs(r) }
        record = r
    }

    /// Revalidates the local deadlines. Returns the terminal state if one was reached.
    private func expireIfNeeded(_ now: Int64) async -> PairingState? {
        guard let r = record else { return nil }
        switch r.phase {
        case .connecting, .comparingHost:
            if r.wskPub == nil && now - r.startedMs >= Self.firstAnswerDeadlineMs { return await finish(.failed(.linkUsed)) }
            if now - r.startedMs >= Self.preApprovalCapMs { return await finish(.expired(.beforeApproval)) }
        case .waitingPrimary, .comparingPrimary:
            if now >= certificationEndMs(r) { return await finish(.expired(.certification)) }
        case .joining:
            if now >= hardJoinEndMs(r) { return await finish(.expired(.afterApproval)) }
        }
        return nil
    }

    // MARK: derived state

    private func derive(at now: Int64) -> PairingState {
        if current.isTerminal || current == .idle || current == .parsing { return current }
        if case .failed = current { return current }
        guard let r = record else { return current }
        if !reverified, r.phase != .joining { return .connecting(origin: r.origin) }
        switch r.phase {
        case .connecting: return .connecting(origin: r.origin)
        case .joining: return .joining
        case .comparingHost:
            guard let nonce = r.sasNonce, let wsk = r.wskPub.flatMap({ try? SigningPublicKey(x963: $0) }), let id = identity,
                  let code = try? Identifiers.pairingCode(workspace: r.ws, offer: r.offer, dkSig: id.publicKeys.sig, dkKx: id.publicKeys.kx, wsk: wsk, sasNonce: nonce)
            else { return .connecting(origin: r.origin) }
            return .comparingHost(code: code)
        case .waitingPrimary, .comparingPrimary:
            // host-supplied text is shown only if it is plain and short (the same rule as in the alarm instruction)
            let label = PairingAlarm.safeLabel(r.primaryLabel)
            let expLocal = challengeExpiryLocalMs(r)
            let deadline = expLocal ?? saturatingAdd(r.certPendingSinceMs ?? now, Self.certificationMs)
            if r.phase == .comparingPrimary, let exp = expLocal {
                if now < exp, let o = r.challenge?.object?["o"], let code = try? Identifiers.certCode(challengeObject: o) {
                    return .comparingPrimary(code: code, primaryLabel: label, expiresMs: exp)
                }
                return .waitingPrimary(primaryLabel: label, deadlineMs: deadline, challengeExpired: true)
            }
            return .waitingPrimary(primaryLabel: label, deadlineMs: deadline, challengeExpired: false)
        }
    }

    private func refreshState(_ now: Int64) {
        let s = derive(at: now)
        if s != current { publish(s) }
    }

    // MARK: terminal states

    /// A failure before there is a record. `mine` ties it to the call that reserved the lifecycle: a superseded call changes nothing.
    private func fail(_ f: PairingFailure, _ mine: Int) -> PairingState {
        guard mine == token else { return current }
        publish(.failed(f)); return current
    }

    @discardableResult
    private func finish(_ s: PairingState, _ mine: Int? = nil) async -> PairingState {
        if let mine, mine != token { return current }
        token += 1
        let t = token
        await drainInstall()
        _ = await eraseAll()
        guard t == token else { return current }          // a cancel interleaved: it owns the final state
        record = nil
        publish(s)
        signalWake()
        return s
    }

    private func raiseAlarm(_ kind: PairingAlarmKind, primaryLabel: String?, _ mine: Int) async -> PairingState {
        guard mine == token else { return current }
        token += 1
        let t = token
        let alarm = PairingAlarm(kind: kind, primaryLabel: primaryLabel)
        if let r = record {
            // the alarm row persists (no secret in it) and is written first, so a crash leaves the alarm and recovery finishes the erasure
            await lockGate()
            do {
                try await cfg.index.savePairing(PairingRow(ws: r.ws.hex, offer: r.offer.hex, generation: r.generation, origin: r.origin, phase: "alarm",
                                                           terminal: "alarm:" + kind.rawValue, detail: alarm.primaryLabel, startedMs: r.startedMs,
                                                           updatedMs: nowMs, createdKeys: r.createdKeys))
            } catch {}
            unlockGate()
            do { try await crashPoint("alarm.saved") } catch { dead = true; return current }
            await drainInstall()
            _ = await purgeResidue(ws: r.ws, createdKeys: r.createdKeys, keepRow: true, gate: true)
        }
        guard t == token else { return current }
        record = nil
        alarmRow = alarm
        publish(.alarm(alarm))
        signalWake()
        return current
    }

    // MARK: persistence and erasure

    private func vault() -> RealmVault { cfg.vault.scoped(to: cfg.context.realm) }

    private enum SaveResult { case saved, superseded, failed }

    /// Writes the record and its discovery row, serialized with erasure and only while `mine` still owns the lifecycle.
    private func save(_ mine: Int) async -> SaveResult {
        await lockGate(); defer { unlockGate() }
        guard mine == token, let r = record else { return .superseded }
        do {
            try perform { try vault().put(try r.encode(), ws: r.ws.hex, purpose: "pairing") }
            try await cfg.index.savePairing(PairingRow(ws: r.ws.hex, offer: r.offer.hex, generation: r.generation, origin: r.origin,
                                                       phase: r.phase.rawValue, startedMs: r.startedMs, updatedMs: nowMs, createdKeys: r.createdKeys))
            return .saved
        } catch { return .failed }
    }

    /// True if saved and still current; false means the caller stops (a failed save already ended the pairing).
    private func persist(_ mine: Int) async -> Bool {
        switch await save(mine) {
        case .saved: return mine == token
        case .superseded: return false
        case .failed: _ = await finish(.failed(.custody), mine); return false
        }
    }

    /// Removes everything of one workspace's pairing that is not a committed workspace: the vault items (record, uncommitted grants),
    /// the directory, the new device keys nothing else uses, and (unless `keepRow`) the discovery row. A failure leaves a `cleanup` row
    /// behind, so the next launch retries; nothing is swallowed. Returns whether everything is gone.
    @discardableResult
    private func purgeResidue(ws: ID16, createdKeys: Bool, keepRow: Bool, gate: Bool) async -> Bool {
        if gate { await lockGate() }
        defer { if gate { unlockGate() } }
        var ok = true
        let committed = ((try? await cfg.index.workspaces()) ?? []).contains { $0.ws == ws.hex }
        if (try? await cfg.index.workspaces()) == nil { ok = false }
        if !committed {
            do { try perform { try vault().wipe(ws: ws.hex) } } catch { ok = false }
            await cfg.index.containers.suspendAll(ws: ws.hex)
            if let dir = try? cfg.index.layout.wsDir(ws.hex), FileManager.default.fileExists(atPath: dir.path) {
                do { try FileManager.default.removeItem(at: dir) } catch { ok = false }
            }
        } else {
            do { try perform { try vault().delete(ws: ws.hex, purpose: "pairing") } } catch { ok = false }       // a committed join keeps its grants
        }
        if createdKeys, !(await removeKeysIfUnused(excluding: ws.hex)) { ok = false }
        if keepRow { return ok }
        if ok {
            do { try await cfg.index.deletePairing(ws: ws.hex) } catch { ok = false }
        }
        if !ok, let row = try? await cfg.index.pairing(ws: ws.hex) {
            var r = row; r.terminal = row.terminal?.hasPrefix("alarm:") == true ? row.terminal : "cleanup"; r.detail = row.detail
            try? await cfg.index.savePairing(r)
        }
        return ok
    }

    /// Cancel and every terminal: secrets, rows, uncommitted installs, and new device keys nothing else uses.
    @discardableResult
    private func eraseAll() async -> Bool {
        guard let r = record else { return true }
        await lockGate()
        defer { unlockGate() }
        // make sure a failed erasure is remembered even when the row was never written (a crash during `start`)
        let ok = await purgeResidue(ws: r.ws, createdKeys: r.createdKeys, keepRow: false, gate: false)
        if !ok, (try? await cfg.index.pairing(ws: r.ws.hex)) == nil {
            try? await cfg.index.savePairing(PairingRow(ws: r.ws.hex, offer: r.offer.hex, generation: r.generation, origin: r.origin, phase: "cleanup",
                                                        terminal: "cleanup", startedMs: r.startedMs, updatedMs: nowMs, createdKeys: r.createdKeys))
        }
        return ok
    }

    /// Deletes device keys this pairing created, but only when nothing else uses them: no workspace, no other live pairing, no stored
    /// certificate. A failure to delete is reported, not swallowed.
    private func removeKeysIfUnused(excluding ws: String?) async -> Bool {
        guard case .missing = storedCertificate(identityAvailable: false) else { return true }
        let others = (try? await cfg.index.pairings().filter { $0.ws != ws && ($0.terminal == nil || $0.terminal == "cleanup") }.count) ?? 1
        let workspaces = (try? await cfg.index.workspaces().count) ?? 1
        guard workspaces == 0, others == 0 else { return true }
        do { try perform { try cfg.custody.delete(realm: cfg.context.realm) }; return true }
        catch CustodyError.missing { return true } catch { return false }
    }

    // MARK: stored certificate (D-1: kept after leaving the last workspace)

    private func storedCertificate(identityAvailable: Bool = true) -> StoredCert {
        let data: Data
        do { data = try vault().get(purpose: "device.cert") }
        catch VaultError.notFound { return .missing }
        catch { return .unreadable }
        guard let v = try? StrictJSON.parse(data), let o = v.object, o.exactly(["cert", "pk_pub"]), let cert = o["cert"], let pk = o.sigKeyField("pk_pub")
        else { return .corrupt }
        guard identityAvailable else { return .present(owner: pk, cert: cert, valid: true) }
        guard let id = identity ?? (try? cfg.context.deviceIdentity(custody: cfg.custody, createIfMissing: false)) else { return .unreadable }
        do {
            let dc = try cfg.context.admitCertificate(cert, ownerKey: pk, nowMs: nowMs)
            guard dc.signingKey == id.publicKeys.sig, dc.agreementKey == id.publicKeys.kx else { return .corrupt }
            return .present(owner: pk, cert: cert, valid: true)
        } catch Refusal.certExpired {
            // authentic (the signature was checked first) but past its end: the owner stays bound, the keys must still be ours
            guard let c = cert.object?["o"]?.object, c.b64uField("dk_sig_pub") == id.publicKeys.sig.x963, c.b64uField("dk_kx_pub") == id.publicKeys.kx.x963
            else { return .corrupt }
            return .present(owner: pk, cert: cert, valid: false)
        } catch let r as RealmViolation { return .violation(r)
        } catch Refusal.otherPerson {
            return .present(owner: pk, cert: cert, valid: true)     // the pinned owner differs: the link check below decides
        } catch { return .corrupt }
    }

    /// Stores a certificate this iPhone already holds from a previous pairing (D-1: kept after leaving the last workspace), after
    /// verifying it for exactly this device's keys and this realm (`RealmContext.admitCertificate`).
    public func adoptCertificate(_ cert: JSONValue, owner: SigningPublicKey) throws {
        try checkConfig()
        let id = try identity ?? cfg.context.deviceIdentity(custody: cfg.custody, createIfMissing: true)
        let dc = try cfg.context.admitCertificate(cert, ownerKey: owner, nowMs: nowMs)
        guard dc.signingKey == id.publicKeys.sig, dc.agreementKey == id.publicKeys.kx else { throw Refusal.certInvalid }
        try storeCertificate(cert, owner: owner)
    }

    func storeCertificate(_ cert: JSONValue, owner: SigningPublicKey) throws {
        let data = try canonicalJSON(["cert": cert, "pk_pub": .string(B64U.encode(owner.x963))])
        try perform { try vault().put(data, purpose: "device.cert") }
    }

    // MARK: retry

    /// After `failed(.joiningTimedOut)`: the stored approval is still there; try the join again for another 60 s, until the retry window
    /// ends (10 minutes after the approval, or the certificate's expiry), when everything is erased.
    public func retryJoin() async {
        guard !dead, var r = record, case .failed(.joiningTimedOut) = current else { return }
        let mine = token
        let now = nowMs
        if now >= hardJoinEndMs(r) { await finish(.expired(.afterApproval), mine); return }
        r.joinStartedMs = now
        record = r; retryNotBeforeMs = 0; failures = 0
        guard await persist(mine) else { return }
        publish(.joining)
        signalWake()
    }

    /// Tests: the end of the join retries for the stored pairing, on the phone's clock.
    package func joinEndForTest() -> Int64? { record.map { hardJoinEndMs($0) } }

    // MARK: launch recovery

    /// Reconciles the discovery rows, the vault and the directories after a crash or restart. Idempotent; run it before `resume`.
    ///   - `cleanup` rows and alarm rows: finish erasing their secrets, directories and new keys (an alarm row itself stays until dismissed);
    ///   - a pending row without its vault record, or whose workspace is already committed: erase the leftovers and the row;
    ///   - vault items of a workspace that is neither committed nor pending: removed;
    ///   - a committed workspace's leftover `pairing` record: removed;
    ///   - directories of neither: removed.
    /// Returns whether everything is clean (a failed deletion is retried at the next launch).
    @discardableResult
    public func recover() async -> Bool {
        guard !dead else { return false }
        do { try checkConfig() } catch { return false }
        var clean = true
        guard let rows = try? await cfg.index.pairings(), let wss = try? await cfg.index.workspaces() else { return false }
        let committed = Set(wss.map(\.ws))
        var live: Set<String> = []
        for row in rows {
            guard let ws = ID16(hex: row.ws) else { continue }
            if let t = row.terminal {
                live.insert(row.ws)
                if t == "cleanup" { clean = await purgeResidue(ws: ws, createdKeys: row.createdKeys, keepRow: false, gate: true) && clean }
                else { clean = await purgeResidue(ws: ws, createdKeys: row.createdKeys, keepRow: true, gate: true) && clean }
                continue
            }
            switch await cfg.index.removalStatus(ws: row.ws, generation: row.generation) {
            case .unknown: live.insert(row.ws); clean = false; continue
            case .removed:
                clean = await purgeResidue(ws: ws, createdKeys: row.createdKeys, keepRow: false, gate: true) && clean
                continue
            case .notRemoved: break
            }
            let read = readRecord(ws: row.ws)
            if case .transient = read { live.insert(row.ws); clean = false; continue }     // locked: keep it, retry at the next launch
            var hasRecord = false
            if case .found = read { hasRecord = true }
            if committed.contains(row.ws) || !hasRecord {
                clean = await purgeResidue(ws: ws, createdKeys: row.createdKeys, keepRow: false, gate: true) && clean
            } else { live.insert(row.ws) }
        }
        let known = committed.union(live)
        if let ids = try? cfg.vault.ids() {
            let strays = Set(ids.filter { $0.realm == cfg.context.realm }.compactMap(\.ws)).subtracting(known)
            for ws in strays {
                do { try vault().wipe(ws: ws) } catch { clean = false }
            }
            // a committed workspace keeps its grants, but its pairing record is leftover
            for ws in committed where !live.contains(ws) {
                if (try? vault().get(ws: ws, purpose: "pairing")) != nil {
                    do { try vault().delete(ws: ws, purpose: "pairing") } catch { clean = false }
                }
            }
        } else { clean = false }
        if let dirs = try? FileManager.default.contentsOfDirectory(at: cfg.index.layout.wsRoot, includingPropertiesForKeys: nil) {
            for d in dirs where !known.contains(d.lastPathComponent) {
                do { try FileManager.default.removeItem(at: d) } catch { clean = false }
            }
        }
        return clean
    }
}

// MARK: joining (host-api section 6: approved -> login, grant, list, card + CK, atomic install)

struct JoinFailure: Error { let reason: String }
struct JoinPending: Error {}
private enum JoinDeadlineError: Error { case expired, timedOut }

extension PairingCoordinator {
    typealias JoinPendingError = JoinPending
    /// The pure checks of a join, in the order the specification gives them. Everything here is verified before anything is written.
    struct VerifiedJoin {
        let card: VerifiedCard
        let cardJSON: JSONValue
        let part: CardSealedPart
        let hosted: HostedMarker
        let list: MemberList
        let listJSON: JSONValue
        let grants: [VerifiedWKGrant]
        let epoch: UInt32
    }

    /// Card: PK delegation against the pinned owner, pinned `WSK`, the link's workspace, `relay_url` byte-equal to the reviewed origin,
    /// a first-contact snapshot. Member list: signature with the pinned `WSK`, this device with scopes exactly the approved ones, list
    /// epoch >= approved epoch, installed grant epoch equal to the list epoch. The card name is shown only after `CK` verified.
    static func verify(cardJSON: JSONValue, listJSON: JSONValue, grantJSONs: [JSONValue], cardKey: HostAPI.CardKey, identity: DeviceIdentity,
                       deviceID: ID16, workspace: ID16, origin: String, wsk: SigningPublicKey, pk: SigningPublicKey,
                       approved: PairingRecord.Approved) throws -> VerifiedJoin {
        let card: VerifiedCard
        do { card = try Card.verify(cardJSON, ownerKey: pk) } catch let r as Refusal { throw JoinFailure(reason: "card_" + r.rawValue) }
        guard card.workspace == workspace, card.wsk == wsk else { throw JoinFailure(reason: "card_identity") }
        guard card.relayURL.utf8Equal(origin) else { throw JoinFailure(reason: "card_origin") }
        do { try Card.checkSnapshot(known: nil, next: card) } catch { throw JoinFailure(reason: "card_snapshot") }
        guard cardKey.workspace == workspace, cardKey.device == deviceID, cardKey.cardSeq == card.cardSeq else { throw JoinFailure(reason: "card_key_target") }
        let ck: SymmetricKey
        let part: CardSealedPart
        do {
            ck = try CardKeyWrap.open(sealed: cardKey.sealed, device: identity.kx, deviceID: deviceID, workspace: workspace, cardSeq: card.cardSeq)
            part = try Card.openSealedPart(of: card, ck: ck)
        } catch { throw JoinFailure(reason: "card_key") }
        let list: MemberList
        do {
            list = try MemberList.verify(listJSON, wsk: wsk)
            try list.checkSnapshot(cardWorkspace: card.workspace, known: nil)
        } catch { throw JoinFailure(reason: "member_list") }
        guard let me = list.members.first(where: { $0.deviceID == deviceID }), let scopes = me.scopeStrings,
              scopes.count == approved.scopes.count, zip(scopes, approved.scopes).allSatisfy({ $0.utf8Equal($1) })
        else { throw JoinFailure(reason: "member_scopes") }
        guard list.epoch >= approved.epoch else { throw JoinFailure(reason: "member_epoch") }
        var grants: [VerifiedWKGrant] = []
        for g in grantJSONs {
            if let v = try? WKGrant.open(g, wsk: wsk, workspace: workspace, device: deviceID, deviceKey: identity.kx) { grants.append(v) }
        }
        guard let top = grants.map(\.epoch).max() else { throw JoinFailure(reason: "grant") }
        guard top == list.epoch else { if top < list.epoch { throw JoinPending() }; throw JoinFailure(reason: "grant_epoch") }
        return VerifiedJoin(card: card, cardJSON: cardJSON, part: part, hosted: Card.hostedMarker(card: card, sealedPart: part), list: list,
                            listJSON: listJSON, grants: grants, epoch: top)
    }

    func join(_ mine: Int) async {
        guard mine == token else { return }
        guard let r = record, let id = identity, let approved = r.approved, let pkData = r.pkPub, let pk = try? SigningPublicKey(x963: pkData),
              let wskData = r.wskPub, let wsk = try? SigningPublicKey(x963: wskData) else { _ = await finish(.failed(.custody), mine); return }
        let now = nowMs
        if now - (r.joinStartedMs ?? now) >= Self.joiningCapMs {
            // retryable until the window ends: the approval and the pins stay; nothing is installed
            if current != .failed(.joiningTimedOut) { publish(.failed(.joiningTimedOut)) }
            return
        }
        if let refusal = admissionFailure(cert: approved.cert, owner: pk, offsetMs: r.offsetMs, now: now) { _ = await finish(.failed(refusal), mine); return }
        do {
            try checkConfig()
            try await crashPoint("join.begin")
            guard mine == token else { return }
            let client = RelayClient(transport: cfg.transport)
            let opened = try await client.openDeviceSession(identity: id, deviceID: r.deviceID)
            guard mine == token else { return }
            let s = opened.session
            var grantJSONs = try await client.grants(workspace: r.ws, session: s)
            let listJSON = try await client.memberList(workspace: r.ws, session: s)
            // card, then the wrap of that very sequence; a missing wrap or a card race refetches both and stays joining
            var cardJSON = try await client.card(workspace: r.ws, session: s)
            guard mine == token else { return }
            guard let seq = cardJSON.object?["o"]?.object?.u32Field("card_seq") else { throw JoinFailure(reason: "card_shape") }
            let wrap: HostAPI.CardKey
            do { wrap = try await client.cardKey(workspace: r.ws, cardSequence: seq, session: s) }
            catch ClientError.adapter(.notFound) {
                cardJSON = try await client.card(workspace: r.ws, session: s)
                throw JoinPending()
            }
            guard mine == token else { return }
            var verified: VerifiedJoin
            do {
                verified = try Self.verify(cardJSON: cardJSON, listJSON: listJSON, grantJSONs: grantJSONs, cardKey: wrap, identity: id, deviceID: r.deviceID,
                                           workspace: r.ws, origin: r.origin, wsk: wsk, pk: pk, approved: approved)
            } catch is JoinPending {
                // a rotation raced the fetches: one more look at the grants
                grantJSONs = try await client.grants(workspace: r.ws, session: s)
                guard mine == token else { return }
                verified = try Self.verify(cardJSON: cardJSON, listJSON: listJSON, grantJSONs: grantJSONs, cardKey: wrap, identity: id, deviceID: r.deviceID,
                                           workspace: r.ws, origin: r.origin, wsk: wsk, pk: pk, approved: approved)
            }
            guard mine == token else { return }
            try checkJoinDeadline(r)
            try await install(verified, record: r, identity: id, wsk: wsk, pk: pk, approved: approved, mine: mine)
        } catch {
            await joinError(error, now: now, mine)
        }
    }

    /// Every error continuation of a join checks that it still owns the lifecycle before it changes any state.
    private func joinError(_ error: Error, now: Int64, _ mine: Int) async {
        if error is PairingCrash { dead = true; return }
        if error is CancellationError { return }
        guard mine == token else { return }
        switch error {
        case JoinDeadlineError.expired: _ = await finish(.expired(.afterApproval), mine)
        case JoinDeadlineError.timedOut: publish(.failed(.joiningTimedOut))
        case let f as JoinFailure: _ = await finish(.failed(.verification(reason: f.reason)), mine)
        case is JoinPending: joinRetry(now)
        case StoreError.removalStateUnknown: joinRetry(now)
        case let t as TransportError:
            if case .realm(let v) = t { _ = await finish(.failed(.realm(v)), mine) } else { joinRetry(now) }
        case let v as RealmViolation: _ = await finish(.failed(.realm(v)), mine)
        case let e as ClientError:
            switch e {
            case .adapter(.notFound), .adapter(.rateLimited), .adapter(.unauthenticated), .adapter(.quotaExceeded): joinRetry(now)
            case .relay(let rr) where rr.code == .revoked: _ = await finish(.failed(.verification(reason: "revoked")), mine)
            default: joinRetry(now)
            }
        default: _ = await finish(.failed(.verification(reason: "install")), mine)
        }
    }

    private func checkJoinDeadline(_ r: PairingRecord) throws {
        let now = nowMs
        if now >= hardJoinEndMs(r) { throw JoinDeadlineError.expired }
        if now - (r.joinStartedMs ?? now) >= Self.joiningCapMs { throw JoinDeadlineError.timedOut }
    }

    private func joinRetry(_ now: Int64) {
        failures += 1
        retryNotBeforeMs = now + 2_000                      // short: the whole join has a 60 s cap
    }

    /// The installer. It is the only code that touches the container, the session and the grants of a pairing; `installing` makes
    /// cancel wait for it. Up to `commitJoin` it can be abandoned (rollback); `commitJoin` is the linearization point (it also checks
    /// that the pairing row is still owned); after it, a lifecycle that was superseded is undone by a tombstoned wipe. The stored
    /// certificate is written before the commit and put back if this join wrote it and does not complete.
    private func install(_ v: VerifiedJoin, record r: PairingRecord, identity id: DeviceIdentity, wsk: SigningPublicKey, pk: SigningPublicKey,
                         approved: PairingRecord.Approved, mine: Int) async throws {
        installing = true
        defer {
            installing = false
            let w = drainWaiters; drainWaiters = []
            for c in w { c.resume() }
        }
        let wsHex = r.ws.hex
        let vault = cfg.vault.scoped(to: cfg.context.realm)
        let priorCert: Data? = try? vault.get(purpose: "device.cert")
        var wroteCert = false
        var container: WorkspaceContainer?
        func restoreCert() {
            guard wroteCert else { return }
            if let p = priorCert { try? vault.put(p, purpose: "device.cert") } else { try? vault.delete(purpose: "device.cert") }
        }
        func rollback() async {
            await container?.close()
            restoreCert()
            // Keep the approval for a retryable timeout. Terminal/cancel cleanup owns the pairing record.
            for item in (try? cfg.vault.ids()) ?? [] where item.realm == cfg.context.realm && item.ws == wsHex && item.purpose != "pairing" {
                try? cfg.vault.delete(item)
            }
            await cfg.index.containers.suspendAll(ws: wsHex)
            if let dir = try? cfg.index.layout.wsDir(wsHex) { try? FileManager.default.removeItem(at: dir) }
        }
        var committed = false
        do {
            try await crashPoint("install.begin")
            guard mine == token else { return }
            try storeCertificate(approved.cert, owner: pk)
            wroteCert = true
            let c = try await WorkspaceContainer(index: cfg.index, ws: wsHex, generation: r.generation)
            container = c
            try await crashPoint("install.container")
            guard mine == token else { await rollback(); return }
            let wcfg = WorkspaceSessionConfig(context: cfg.context, workspace: r.ws, generation: r.generation, identity: id, wsk: wsk, container: c,
                                              vault: vault, transport: cfg.transport, clock: cfg.clock, wall: cfg.wall, entropy: cfg.entropy)
            let session = try await WorkspaceSession(wcfg)
            for g in v.grants.sorted(by: { $0.epoch < $1.epoch }) {
                try await session.install(g)
                try await crashPoint("install.grant")
                guard mine == token else { await rollback(); return }
            }
            try await crashPoint("install.precommit")
            guard mine == token else { await rollback(); return }
            let profile = WorkspaceProfile(ws: wsHex, name: v.part.name, description: v.part.description, origin: r.origin,
                                           clientHosted: v.card.delegation.clientHosted, hostedMarker: v.hosted.marker, hostedBy: v.hosted.hostedBy,
                                           wskPub: B64U.encode(wsk.x963), pkPub: B64U.encode(pk.x963), ownerPerson: v.card.ownerPersonID.hex,
                                           cardSeq: Int64(v.card.cardSeq), listSeq: v.list.listSeq, epoch: Int64(v.epoch), scopes: approved.scopes,
                                           card: String(decoding: try canonicalJSON(v.cardJSON), as: UTF8.self), joinedMs: nowMs)
            // the linearization point: the ownership check and the commit are one transaction
            try checkJoinDeadline(r)
            try await cfg.index.commitJoin(generation: r.generation, profile: profile)
            committed = true
            try await crashPoint("install.committed")
            if mine != token {
                // cancelled while committing: undo the join (tombstone, row, secrets, files, certificate), leave no workspace behind
                await container?.close()
                restoreCert()
                try? await LocalWipe(index: cfg.index, hooks: PairingWipeHooks(vault: vault)).wipe(ws: wsHex, generation: r.generation)
                return
            }
            try? vault.delete(ws: wsHex, purpose: "pairing")
            token += 1
            record = nil
            let joined = JoinedWorkspace(workspace: r.ws, generation: r.generation, name: v.part.name, hosted: v.hosted, scopes: approved.scopes,
                                         epoch: v.epoch, origin: r.origin, session: session)
            publish(.ready(JoinedHandle(joined: joined)))
            signalWake()
        } catch {
            if error is PairingCrash { throw error }
            if committed {
                // a failure after the commit (not a crash): the workspace is complete in the index; only leftovers remain
                try? vault.delete(ws: wsHex, purpose: "pairing")
                throw error
            }
            if case StoreError.removalStateUnknown = error {
                // Uncertainty is not permission to erase files, grants or the approved pairing.
                await container?.close()
                restoreCert()
            } else {
                await rollback()
            }
            throw error
        }
    }
}

/// Removes the secrets of a workspace when a committed join is undone by a cancel that arrived while committing.
struct PairingWipeHooks: WipeHooks {
    let vault: RealmVault
    func purgeSecrets(realm: String, ws: String) async throws { try vault.wipe(ws: ws) }
}
