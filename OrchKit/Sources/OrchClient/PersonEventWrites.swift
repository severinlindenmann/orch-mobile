import Foundation
import OrchCustody
import OrchProtocol
import OrchStore

// MARK: public surface (C2b answers)

/// The one immutable value a sign sheet renders, checks with SafeText, and signs (codex 14): the F1 gate's `Reviewed` of one fresh
/// `ticket.get`, with the review token that issued it. Every option is here in hash order, cost included. Equality is byte equality of the
/// reviewed content (never Swift's canonical string equivalence) plus the token: any re-read is a new snapshot and re-arms the sheet.
public struct ReviewedSnapshot: Sendable, Equatable {
    package let reviewed: F1Question.Reviewed
    package let token: UUID
    /// The display question of the same read (ticket key, resolution, labels).
    public let question: Question
    public let realm: Realm
    public let workspaceID: ID16
    public let generation: Int64
    /// `cj` of the reviewed content: what equality compares. Nil when it cannot be encoded: such a snapshot equals nothing, itself
    /// included (fail closed: it can never pass the session's `held == s` check, so it is never signed).
    package let contentBytes: Data?
    #if DEBUG && targetEnvironment(simulator)
    /// The sandbox id (id8) of the fresh read behind this review when it is on the dev-sandbox lane; nil otherwise. Display only.
    public internal(set) var devSandbox: String?
    #endif

    package init(reviewed: F1Question.Reviewed, token: UUID, question: Question, realm: Realm, workspaceID: ID16, generation: Int64) {
        self.reviewed = reviewed; self.token = token; self.question = question; self.realm = realm; self.workspaceID = workspaceID
        self.generation = generation
        contentBytes = try? canonicalJSON(["q": reviewed.question.openWire, "uid": .string(reviewed.ticketUID), "base": .string(reviewed.basedOn),
                                           "roster": .int(reviewed.rosterV), "qid": .string(reviewed.qid), "hash": .string(reviewed.hash)])
    }

    /// The hashed options themselves, exactly as reviewed (what the sign sheet's rows are checked against, byte for byte).
    public var reviewedOptions: [F1QuestionOption] { reviewed.question.options }
    /// EVERY option, in the order the hash binds them: key, label and cost exactly as reviewed.
    public var options: [QuestionOption] { reviewed.question.options.map { QuestionOption(id: $0.key, label: $0.label, cost: $0.cost) } }
    public var text: String { reviewed.text }
    /// Unbound context (shown under "Not signed").
    public var why: String? { reviewed.question.why }
    public var recommended: String? { reviewed.question.recommended }
    public var to: [String] { reviewed.question.to }
    public var blocking: Bool { reviewed.question.blocking }
    /// Signed details.
    public var qid: String { reviewed.qid }
    public var hash: String { reviewed.hash }
    public var ticketUID: String { reviewed.ticketUID }
    public var ticketKey: String { question.ticket }
    /// A question without options is answered on the Mac (free text stays out of C2b).
    public var answerable: Bool { !reviewed.question.options.isEmpty }

    public static func == (a: ReviewedSnapshot, b: ReviewedSnapshot) -> Bool { a.token == b.token && a.sameContent(b) }
    /// Same reviewed content, whatever review issued it (never true for content that could not be encoded).
    public func sameContent(_ o: ReviewedSnapshot) -> Bool {
        guard let mine = contentBytes, let theirs = o.contentBytes else { return false }
        return mine == theirs
    }
}

extension QuestionReview {
    /// The signable snapshot of an OPEN question (nil for a closed one).
    public var snapshot: ReviewedSnapshot? {
        reviewed.map { r in
            var s = ReviewedSnapshot(reviewed: r, token: token, question: question, realm: realm, workspaceID: workspaceID, generation: generation)
            #if DEBUG && targetEnvironment(simulator)
            s.devSandbox = devGrant?.sandbox
            #endif
            return s
        }
    }
}

public enum NeedsReviewReason: Equatable, Sendable {
    /// Nothing was sent (the window passed before the first send, or the eligibility for an automatic re-sign ended): review again.
    case notSent
    /// The host refused it as C-review (`question.stale`, `event.bad_base`, `event.expired`, ...): the content changed.
    case changed(code: String)
    /// A C-auto refusal (`members.stale`) whose automatic re-sign was not allowed (a displayed field changed, the app left the foreground,
    /// the limit was reached).
    case workspaceChanged
}

public enum LandedUnconfirmedReason: String, Equatable, Sendable {
    /// The question has since changed (restored, re-asked) and no longer shows this answer.
    case changed
    /// The confirming read failed or the question cannot be shown.
    case unavailable
}

/// What an answer ended as. A landing is final: nothing later turns it into anything else.
public enum WriteOutcome: Equatable, Sendable {
    case landed(seq: Int64, key: String)
    /// Landed after an automatic re-sign ("The workspace changed; sent again").
    case landedAfterResign(seq: Int64, key: String)
    /// Sent and recorded; the question has since changed or can't be shown.
    case landedUnconfirmed(seq: Int64?, reason: LandedUnconfirmedReason)
    /// Unknown so far: settled by reading (never re-signed).
    case checking
    case needsReview(NeedsReviewReason)
    case refused(code: String)
    case alreadyAnswered(label: String, at: Int64)
    /// Creation only (increment 3).
    case ticketExists(key: String?)
}

public enum WriteState: Equatable, Sendable {
    /// Signed and stored, not yet handed to the relay.
    case sending
    /// Possibly sent; being settled.
    case checking
}

public struct WriteStatus: Equatable, Sendable {
    public let reviewID: String
    public let questionID: ID16?
    public let option: String?
    public let state: WriteState
    /// What was reviewed and signed, read back from `pe_reviews.snapshot` (qid and hash recomputed): a sheet reopened after a relaunch
    /// shows exactly this, never the current cached question. Nil if the stored snapshot no longer checks.
    public let review: StoredReview?
    /// A creation still being sent or settled: what was reviewed and the key its current attempt carries (nil for answers).
    public let creation: StoredCreationReview?

    public init(reviewID: String, questionID: ID16?, option: String?, state: WriteState, review: StoredReview?, creation: StoredCreationReview? = nil) {
        self.reviewID = reviewID; self.questionID = questionID; self.option = option; self.state = state; self.review = review; self.creation = creation
    }
}

/// The reviewed content of a stored answer (SH5): exactly the strings that were signed.
public struct StoredReview: Equatable, Sendable {
    public let ticketKey: String, ticketUID: String, qid: String, hash: String, text: String
    /// Every option, in hash order.
    public let options: [QuestionOption]
    public let option: String
    public let why: String?, recommended: String?
    public let to: [String]
    public let blocking: Bool
    /// The hash's hex digits (the `sha256:` prefix removed).
    public var contentHashHex: String { hash.hasPrefix("sha256:") ? String(hash.dropFirst(7)) : hash }
}

/// `answer` failed AFTER its attempt was committed: an answer exists and is being settled (`writeOutcome`, `settle`). It is never
/// "nothing was signed". Any other error from `answer` means nothing durable exists.
public struct AnswerCommitted: Error {
    public let reviewID: String
    public let underlying: any Error
}

// MARK: internals

/// Builds, signs and inserts a NEW attempt inside `prepare`'s transaction: returns the framed plaintext (no `rd` yet) and the attempt id.
struct WriteBuild: Sendable {
    let body: @Sendable (SQLiteTransaction) throws -> (plaintext: Data, attempt: String)
}

enum WriteGateError: Error, Equatable {
    /// The event's age left the sending window (both edges, plan 3.5): nothing more is sent.
    case windowPassed
    /// The attempt is no longer its review's current one, or the review is not active (a CAS lost).
    case notCurrent
    /// The first dispatch of an automatic re-sign without its eligibility token.
    case eligibilityLost
    /// No policy, or the host does not take this write (increment 4 signal): nothing is signed or sent.
    case unavailable
    /// The lifecycle was invalidated between the caller's checks and the effect (`LifecycleFence`): nothing was signed, or a first
    /// dispatch was stopped (a charged attempt stays dispatched and is settled).
    case lifecycleEnded
    /// The stored event no longer re-binds to its reviewed snapshot, or the framed bytes are not the event's meta.
    case bytesChanged
}

/// The clock facts of one window check (plan 3.5).
struct WriteClock: Sendable {
    let wallMs: Int64, offsetMs: Int64, monoMs: Int64

    /// age = max(host age, wall age since signing, monotonic age since signing); send only if age <= 840 s and the id is at most 300 s ahead.
    func holds(ulidMs: Int64, signedWallMs: Int64) -> Bool {
        let hostNow = saturatingAddMs(wallMs, offsetMs)
        let age = max(hostNow - ulidMs, wallMs - signedWallMs, monoMs)
        return age <= ULID.outboxMaxAgeMs && ulidMs - hostNow <= ULID.windowFutureMs
    }
}

/// `pe_reviews.snapshot`: what was reviewed, re-checked (qid and hash recomputed) whenever it is read back.
struct StoredSnapshot: Sendable {
    let question: F1Question
    let ticketUID: String, ticketKey: String, basedOn: String, qid: String
    let rosterV: Int64
    let option: String

    init(_ s: ReviewedSnapshot, option: String) {
        question = s.reviewed.question; ticketUID = s.reviewed.ticketUID; ticketKey = s.question.ticket; basedOn = s.reviewed.basedOn
        qid = s.reviewed.qid; rosterV = s.reviewed.rosterV; self.option = option
    }

    init(bytes: Data) throws {
        guard let o = try StrictJSON.parse(bytes).object, let q = o["question"], let uid = o["ticket_uid"]?.string, let key = o["ticket_key"]?.string,
              let base = o["based_on"]?.string, let qid = o["qid"]?.string, let roster = o["roster_v"]?.int, let option = o["option"]?.string
        else { throw ViewError.malformed }
        question = try F1Question(q); ticketUID = uid; ticketKey = key; basedOn = base; self.qid = qid; rosterV = roster; self.option = option
    }

    func bytes() throws -> Data {
        try canonicalJSON(["question": question.openWire, "ticket_uid": .string(ticketUID), "ticket_key": .string(ticketKey), "based_on": .string(basedOn),
                           "qid": .string(qid), "roster_v": .int(rosterV), "option": .string(option)])
    }

    func reviewed(workspace: ID16, rosterV: Int64? = nil) throws -> F1Question.Reviewed {
        try question.reviewed(ticketUID: ticketUID, workspace: workspace, basedOn: basedOn, rosterV: rosterV ?? self.rosterV)
    }

    var locator: WorkspaceSession.QuestionLocator { WorkspaceSession.QuestionLocator(key: ticketKey, uid: ticketUID, number: question.id) }
}

struct AttemptRec: Sendable {
    let idem: String, review: String, origin: String, state: String, auth: String
    let n: Int64
    let event: Data
    let ulidMs: Int64, signedWallMs: Int64
    let dispatched: Bool
    let evidence: String
    /// A creation's key (NULL for an answer).
    let key: String?

    init?(_ r: SQLRow) {
        guard let idem = r.text("idem"), let review = r.text("review"), let origin = r.text("origin"), let state = r.text("state"),
              let auth = r.text("auth"), let n = r.int("n"), let event = r.blob("event"), let u = r.int("ulid_ms"), let w = r.int("signed_wall_ms"),
              let d = r.int("dispatched") else { return nil }
        self.idem = idem; self.review = review; self.origin = origin; self.state = state; self.auth = auth; self.n = n; self.event = event
        ulidMs = u; signedWallMs = w; dispatched = d != 0; evidence = r.text("evidence") ?? "[]"; key = r.text("key")
    }

    /// The landed seq the evidence names, if any.
    var landedSeq: Int64? {
        guard let a = (try? StrictJSON.parse(Data(evidence.utf8)))?.array else { return nil }
        return a.reversed().compactMap { $0.object?["seqs"]?.array?.first?.int }.first
    }
}

struct ReviewRec: Sendable {
    let review: String, kind: String, log: String, state: String, currentIdem: String
    let question: String?
    let snapshot: Data
    let ver: Int64, resigns: Int64
    let landedIdem: String?
    let outcome: String?
    /// The next key the creation sheet disclosed when it armed ("The key is assigned when sent (next: KEY)"); NULL for answers.
    let keyDisclosed: String?
    var isCreation: Bool { kind == "new_ticket" }
    var eventKind: SignedPhoneEvent.Kind { isCreation ? .ticketCreated : .questionAnswered }

    init?(_ r: SQLRow) {
        guard let review = r.text("review"), let kind = r.text("kind"), let log = r.text("log"), let state = r.text("state"),
              let cur = r.text("current_idem"), let snap = r.blob("snapshot"), let ver = r.int("ver"), let resigns = r.int("resigns") else { return nil }
        self.review = review; self.kind = kind; self.log = log; self.state = state; currentIdem = cur; question = r.text("question")
        snapshot = snap; self.ver = ver; self.resigns = resigns; landedIdem = r.text("landed_idem"); outcome = r.text("outcome")
        keyDisclosed = r.text("key_disclosed")
    }
}

/// What one step of settlement learned about one attempt.
enum Evidence: Sendable {
    case landed(seq: Int64, src: String)
    case definite(code: String, cls: PhoneRetryClass, src: String)
    case unresolved
    case windowPassed
    /// Not sent and may not be any more (eligibility or host support ended before the first dispatch).
    case notSent
}

enum AttemptKind {
    case insert(review: String, log: String, question: String, snapshot: Data, nowMs: Int64)
    /// A creation's first attempt: the review keyed by its phone-made uid (`log`), with the disclosed key.
    case insertCreation(review: String, log: String, snapshot: Data, keyDisclosed: String?, nowMs: Int64)
    case resign(review: String, expectIdem: String, expectVer: Int64)
}

extension WorkspaceSession {
    // MARK: policy and host support

    /// Whether the host takes this write. Demo: the FakeHost serves `answer` and `new_ticket`. Live: the host said so in its column-R
    /// `whoami.relay` (op at version 1 and `r6_ready`); no signal, or one cleared by a failed read, a background or an epoch change, means no.
    /// Checked for a new signature and for the first dispatch only; a resend or a settlement read never asks.
    func hostWritesAllowed(_ kind: String) -> Bool {
        guard let policy else { return false }
        #if DEBUG && targetEnvironment(simulator)
        // the dev-sandbox lane takes answers only, and only while the last read (cached: UI and the first dispatch) carried `relay.dev`
        if policy.lane == .devSandbox { return Self.devSandboxAdmits(support: hostSupport, kind: kind) }
        #endif
        return Self.hostAdmits(realm: policy.realm, support: hostSupport, kind: kind)
    }
    #if DEBUG && targetEnvironment(simulator)
    static func devSandboxAdmits(support: HostWriteSupport?, kind: String) -> Bool { kind == "answer" && support?.allows(kind) == true && support?.dev != nil }
    #endif
    /// The rule itself (pure, so the Live branch is tested without a Secure Enclave): Demo unchanged; Live needs the host's signal.
    static func hostAdmits(realm: Realm, support: HostWriteSupport?, kind: String) -> Bool {
        switch realm {
        case .demo: return kind == "answer" || kind == "new_ticket"
        case .live: return support?.allows(kind) == true
        }
    }

    /// The UI may offer answers here: a policy, and a host that takes them.
    public func writesAvailable() -> Bool { hostWritesAllowed("answer") }
    /// The same for one write op (`answer`, `new_ticket`).
    public func writesAvailable(op: String) -> Bool { hostWritesAllowed(op) }

    // MARK: eligibility (codex 11)

    // Synchronous and nonisolated: they reach the fence at once, also while the actor is busy or suspended inside a write.

    /// scenePhase `.inactive`: no signature and no first dispatch for anything checked before it, no automatic re-sign for any review.
    public nonisolated func noteInactive() { lifecycleFence.invalidate(.inactive) }
    /// `protectedDataWillBecomeUnavailable`.
    public nonisolated func noteProtectedDataUnavailable() { lifecycleFence.invalidate(.protectedDataLost) }
    /// The custody reported `.locked`.
    public nonisolated func noteCustodyLocked() { lifecycleFence.invalidate(.custodyLocked) }
    /// The fence half of `setForeground(false)`, callable before the actor hop.
    public nonisolated func noteBackground() { lifecycleFence.invalidate(.background) }
    /// The fence half of `invalidateReviews()`, callable before the actor hop.
    public nonisolated func noteReviewsInvalidated() { lifecycleFence.invalidate(.reviewsInvalidated) }

    /// SH1: the session itself reacts to a lock anywhere in its write path (signing, the device key behind the bridge seal, the vault),
    /// whatever the App does with the error.
    nonisolated func noteIfLocked(_ error: Error) {
        switch error {
        case CustodyError.locked, VaultError.locked: noteCustodyLocked()
        default: break
        }
    }

    func monotonicMs(_ idem: String) -> Int64 {
        guard let m = attemptMonotonic[idem] else { return 0 }
        let c = m().components
        return c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000
    }

    // MARK: the write gate (plan 3.3)

    /// A row without an attempt never carries a write meta, in Live and Demo alike (C2b increment 3 retired the v0 creation op).
    func refuseUnattachedWrite(_ plaintext: Data) throws {
        guard let meta = try? Bridge.unframe(plaintext).meta.object, let op = meta["op"]?.string,
              R2.allOps.first(where: { $0.key.utf8.elementsEqual(op.utf8) })?.value.kind == .write else { return }
        throw ViewError.writesUnavailable
    }

    /// Inside the transaction that re-seals a write row: the attempt is still current and sendable, the framed bytes are its event's, and
    /// the window holds.
    static func revalidate(_ tx: SQLiteTransaction, attempt: String, plaintext: Data, clock: WriteClock, workspace: ID16) throws {
        guard let r = try tx.query("SELECT a.state, a.event, a.ulid_ms, a.signed_wall_ms, r.current_idem, r.state AS rstate, r.log, r.kind FROM pe_attempts a JOIN pe_reviews r ON r.review = a.review WHERE a.idem=?",
                                   [.text(attempt)]).first,
              let st = r.text("state"), st == "signed" || st == "sent", r.text("current_idem") == attempt, r.text("rstate") == "active",
              let bytes = r.blob("event"), let log = r.text("log"), let ulid = r.int("ulid_ms"), let signed = r.int("signed_wall_ms")
        else { throw WriteGateError.notCurrent }
        guard clock.holds(ulidMs: ulid, signedWallMs: signed) else { throw WriteGateError.windowPassed }
        let kind: SignedPhoneEvent.Kind = r.text("kind") == "new_ticket" ? .ticketCreated : .questionAnswered
        try checkFramed(plaintext, event: try PhoneEvents.restore(bytes: bytes, kind: kind, log: log, workspace: workspace))
    }

    /// The framed meta minus `rd` must be byte-equal to `cj(R2.writeMeta(event))`, and carry no data.
    static func checkFramed(_ plaintext: Data, event e: SignedPhoneEvent) throws {
        let (meta, data) = try Bridge.unframe(plaintext)
        guard data.isEmpty, var m = meta.object else { throw WriteGateError.bytesChanged }
        m["rd"] = nil
        if var args = m["args"]?.object { args["rd"] = nil; m["args"] = .object(args) }
        guard try canonicalJSON(.object(m)) == canonicalJSON(R2.writeMeta(e)) else { throw WriteGateError.bytesChanged }
    }

    /// Every POST of a write row passes here (`post`), whoever started it: the first send, `resend`, a re-seal of any kind. Returns the
    /// permit `bridgePost` carries.
    /// For an attempt not yet dispatched it also returns the lifecycle ticket captured here, which `post` re-validates right before
    /// `bridgePost` (the invariant's second check).
    func writeGate(_ row: Row, attempt: String) async throws -> (WritePermit, LifecycleFence.Ticket?) {
        guard let policy else { throw WriteGateError.unavailable }
        try await ensureCurrent()
        guard foreground else { throw ViewError.offline }
        let db = try await cfg.container.database()
        guard let r = try await db.query("SELECT a.*, r.current_idem, r.state AS rstate, r.kind, r.log, r.snapshot FROM pe_attempts a JOIN pe_reviews r ON r.review = a.review WHERE a.idem=?",
                                         [.text(attempt)]).first, let a = AttemptRec(r), let log = r.text("log"), let kind = r.text("kind"),
              let snapBytes = r.blob("snapshot") else { throw WriteGateError.notCurrent }
        guard a.auth.utf8.elementsEqual(policy.auth.rawValue.utf8) else { throw WriteGateError.unavailable }
        guard a.state == "signed" || a.state == "sent", r.text("current_idem") == attempt, r.text("rstate") == "active" else { throw WriteGateError.notCurrent }
        let clock = WriteClock(wallMs: cfg.wall.nowMs, offsetMs: try await clockOffsetMs(), monoMs: monotonicMs(attempt))
        guard clock.holds(ulidMs: a.ulidMs, signedWallMs: a.signedWallMs) else { throw WriteGateError.windowPassed }
        var ticket: LifecycleFence.Ticket?
        if !a.dispatched {
            guard hostWritesAllowed(kind) else { throw WriteGateError.unavailable }
            #if DEBUG && targetEnvironment(simulator)
            // a first dispatch on the dev-sandbox lane comes from a grant-bearing review: an answer signed as `convenience` (signing needed the
            // fresh read). It does not read again: the window is seconds, and the host's own gate decides.
            if policy.lane == .devSandbox { guard kind == "answer", a.auth == F1Auth.convenience.rawValue else { throw WriteGateError.unavailable } }
            #endif
            // the first dispatch of an automatic attempt needs its review's eligibility token. A tap's needs a usable lifecycle that did not
            // end for ITS review since the Sign tap (#84 SHOULD-B, one rule): a tap stopped before its first charge is never sent later,
            // whichever of the fence and the actor hop got there first. (After a relaunch no token ever existed: the crash-recovery send of
            // the same signed bytes stays.)
            if a.origin == "auto" {
                guard let t = lifecycleFence.ticket(review: a.review) else { throw WriteGateError.eligibilityLost }
                ticket = t
            } else {
                guard let t = lifecycleFence.tapTicket(review: a.review) else { throw WriteGateError.lifecycleEnded }
                ticket = t
            }
        }
        // MUST 4 (Opus, increment 1): the stored event re-binds to its reviewed snapshot byte for byte (only `id`, and for an automatic
        // re-sign `roster_v`, differ from the review), then validates in full, then the framed bytes are exactly its meta.
        let eventKind: SignedPhoneEvent.Kind = kind == "new_ticket" ? .ticketCreated : .questionAnswered
        let e = try PhoneEvents.restore(bytes: a.event, kind: eventKind, log: log, workspace: workspace)
        let actor = try policy.actor(person: try storedPerson(), device: cfg.deviceID)
        let expected: PhoneEvents.UnsignedPhoneEvent
        if eventKind == .ticketCreated {
            // a creation: only `roster_v`, `id` and (an automatic re-sign's) `key` differ from the review; the uid is the review's
            let snap = try StoredCreation(bytes: snapBytes)
            let roster = a.origin == "auto" ? (e.event["roster_v"]?.int ?? -1) : snap.rosterV
            let key = a.origin == "auto" ? (e.event["key"]?.string ?? "") : snap.key
            expected = try snap.unsigned(uid: log, key: key, rosterV: roster, id: attempt, actor: actor, workspace: workspace)
        } else {
            let snap = try StoredSnapshot(bytes: snapBytes)
            let roster = a.origin == "auto" ? (e.event["roster_v"]?.int ?? -1) : snap.rosterV
            expected = try PhoneEvents.unsignedAnswer(try snap.reviewed(workspace: workspace, rosterV: roster), option: snap.option, text: nil,
                                                      id: attempt, actor: actor, workspace: workspace)
        }
        var unsigned = e.event; unsigned["sig"] = nil
        guard try canonicalJSON(.object(unsigned)) == canonicalJSON(.object(expected.event)), expected.log.bytesEqual(e.log) else {
            throw WriteGateError.bytesChanged
        }
        try PhoneEvents.validateSigned(e, kind: eventKind, actor: actor, workspace: workspace, pub: cfg.identity.publicKeys.sig)
        try Self.checkFramed(row.plaintext, event: e)
        return (policy.permit(workspace: workspace), ticket)
    }

    // MARK: beginning an attempt (plan 3.2)

    /// The transaction body of a new attempt: CAS, sign (`pe.sign`, counted), validate, frame, window, insert. Nothing here suspends.
    static func attemptBuild(_ kind: AttemptKind, unsigned: PhoneEvents.UnsignedPhoneEvent, origin: String, signer: any Signer, actor: PhoneActor,
                             pub: SigningPublicKey, workspace: ID16, clock: WriteClock, fence: LifecycleFence, ticket: LifecycleFence.Ticket,
                             hook: (@Sendable (String) throws -> Void)?) -> WriteBuild {
        WriteBuild { tx in
            let review: String
            switch kind {
            case .insert(let rv, let log, let question, let snapshot, let nowMs):
                // one active review per question: a double tap or a second sheet never signs twice
                guard try tx.query("SELECT 1 AS x FROM pe_reviews WHERE question=? AND state='active'", [.text(question)]).isEmpty else {
                    throw WriteGateError.notCurrent
                }
                try tx.execute("INSERT INTO pe_reviews(review, kind, log, question, snapshot, current_idem, ver, state, created_ms) VALUES(?,'answer',?,?,?,?,1,'active',?)",
                               [.text(rv), .text(log), .text(question), .blob(snapshot), .text(unsigned.id), .int(nowMs)])
                review = rv
            case .insertCreation(let rv, let log, let snapshot, let keyDisclosed, let nowMs):
                // one review = one uid: a uid any review of this store already holds is never signed again under another review
                guard try tx.query("SELECT 1 AS x FROM pe_reviews WHERE log=? AND kind='new_ticket'", [.text(log)]).isEmpty else {
                    throw WriteGateError.notCurrent
                }
                try tx.execute("INSERT INTO pe_reviews(review, kind, log, question, snapshot, key_disclosed, current_idem, ver, state, created_ms) VALUES(?,'new_ticket',?,NULL,?,?,?,1,'active',?)",
                               [.text(rv), .text(log), .blob(snapshot), keyDisclosed.map(SQLValue.text) ?? .null, .text(unsigned.id), .int(nowMs)])
                review = rv
            case .resign(let rv, let expectIdem, let expectVer):
                guard let r = try tx.query("SELECT current_idem, ver, state FROM pe_reviews WHERE review=?", [.text(rv)]).first,
                      r.text("current_idem") == expectIdem, r.int("ver") == expectVer, r.text("state") == "active" else { throw WriteGateError.notCurrent }
                guard try tx.execute("UPDATE pe_attempts SET state='superseded' WHERE idem=? AND state='c_auto'", [.text(expectIdem)]) == 1 else {
                    throw WriteGateError.notCurrent
                }
                try tx.execute("DELETE FROM bridge_requests WHERE attempt=?", [.text(expectIdem)])
                try tx.execute("UPDATE pe_reviews SET current_idem=?, ver=ver+1, resigns=resigns+1 WHERE review=?", [.text(unsigned.id), .text(rv)])
                review = rv
            }
            let n = (try tx.query("SELECT COALESCE(MAX(n), 0) AS m FROM pe_attempts WHERE review=?", [.text(review)]).first?.int("m") ?? 0) + 1
            try hook?("pe.presign")
            // the invariant's first check, synchronous and immediately before the signature: the lifecycle the caller checked still holds
            guard fence.valid(ticket) else { throw WriteGateError.lifecycleEnded }
            try hook?("pe.sign")
            let e = try PhoneEvents.sign(unsigned, signer: signer)
            try hook?("pe.signed")
            try PhoneEvents.validateSigned(e, kind: unsigned.kind, actor: actor, workspace: workspace, pub: pub)
            let meta = try R2.writeMeta(e)
            _ = try R2.checkMeta(meta, data: Data())
            let plaintext = try Bridge.frame(meta: meta, data: Data())
            guard let ulid = ULID.timeMs(of: e.id), clock.holds(ulidMs: ulid, signedWallMs: clock.wallMs) else { throw WriteGateError.windowPassed }
            let key: SQLValue = e.event["key"]?.string.map(SQLValue.text) ?? .null
            try tx.execute("INSERT INTO pe_attempts(idem, review, n, origin, event, digest, key, auth, ulid_ms, signed_wall_ms, signed_offset_ms, state) VALUES(?,?,?,?,?,?,?,?,?,?,?,'signed')",
                           [.text(e.id), .text(review), .int(n), .text(origin), .blob(e.bytes), .text(e.digest), key, .text(actor.auth.rawValue), .int(ulid),
                            .int(clock.wallMs), .int(clock.offsetMs)])
            return (plaintext, e.id)
        }
    }

    // MARK: answer

    /// Signs and sends the person's answer to `snapshot` (option only: a question without options is answered on the Mac). The review
    /// token is consumed before anything suspends, so a double tap signs once.
    package func answer(_ s: ReviewedSnapshot, option: String) async throws -> WriteOutcome {
        try await ensureCurrent()
        guard let policy, hostWritesAllowed("answer") else { throw ViewError.writesUnavailable }
        // free text stays on the Mac (C2b is options only), whatever review the snapshot came from
        guard s.answerable, let chosen = s.reviewed.question.options.first(where: { $0.key.bytesEqual(option) }) else { throw ViewError.invalidOption }
        guard s.workspaceID == workspace, s.generation == generation, s.realm == cfg.context.realm, foreground,
              let held = reviews[s.token]?.snapshot, held == s else { throw ViewError.invalidReview }
        #if DEBUG && targetEnvironment(simulator)
        // dev-sandbox lane: only a review that carries the fresh `relay.dev` read signs (the session's own copy, not the caller's)
        if policy.lane == .devSandbox { guard reviews[s.token]?.devGrant != nil else { throw ViewError.hostRefusesSimulator } }
        #endif
        reviews[s.token] = nil
        let reviewID = cfg.entropy.id16().hex
        // the tap's checks end here: its ticket (with the review's eligibility token) is what the signing transaction re-validates
        // a lock the custody reported is surfaced as the lock it is ("Unlock to continue"), not as an expired review
        guard let ticket = lifecycleFence.issue(review: reviewID) else { throw lifecycleFence.isLocked ? CustodyError.locked : ViewError.invalidReview }
        do { try await beginAnswer(s, chosen: chosen.key, reviewID: reviewID, policy: policy, ticket: ticket) }
        catch {
            // nothing durable: no attempt was committed
            lifecycleFence.revoke(review: reviewID)
            noteIfLocked(error)
            switch error {
            case WriteGateError.notCurrent, WriteGateError.lifecycleEnded:
                throw lifecycleFence.isLocked ? CustodyError.locked : ViewError.invalidReview
            default: throw error
            }
        }
        // committed: from here on the review is settled, whatever happens (an error here leaves it to settlement)
        do { return try await reviewDriver(reviewID) }
        catch { noteIfLocked(error); throw AnswerCommitted(reviewID: reviewID, underlying: error) }
    }

    /// The tap's attempt, signed and committed (or nothing at all).
    private func beginAnswer(_ s: ReviewedSnapshot, chosen: String, reviewID: String, policy: PersonEventPolicy, ticket: LifecycleFence.Ticket) async throws {
        let actor = try policy.actor(person: try storedPerson(), device: cfg.deviceID)
        let offset = try await clockOffsetMs()
        guard lifecycleFence.valid(ticket) else { throw WriteGateError.lifecycleEnded }
        let now = cfg.wall.nowMs
        let id = try ULID.make(timeMs: saturatingAddMs(now, offset), random: cfg.entropy.bytes(ULID.randomLength))
        let unsigned = try PhoneEvents.unsignedAnswer(s.reviewed, option: chosen, text: nil, id: id, actor: actor, workspace: workspace)
        let snapshot = try StoredSnapshot(s, option: chosen).bytes()
        let build = Self.attemptBuild(.insert(review: reviewID, log: s.reviewed.ticketUID, question: s.reviewed.qid, snapshot: snapshot, nowMs: now),
                                      unsigned: unsigned, origin: "tap", signer: cfg.identity.sig, actor: actor, pub: cfg.identity.publicKeys.sig,
                                      workspace: workspace, clock: WriteClock(wallMs: now, offsetMs: offset, monoMs: 0), fence: lifecycleFence,
                                      ticket: ticket, hook: crashHook)
        _ = try await prepare(logical: cfg.entropy.id16(), plaintext: Data(), write: build)
    }

    /// Settles one review (the UI's "check", recovery): joins its driver.
    package func settle(reviewID: String) async throws -> WriteOutcome {
        guard foreground else { throw ViewError.offline }
        return try await reviewDriver(reviewID)
    }

    /// Reviews still being sent or settled.
    package func pendingWrites() async throws -> [WriteStatus] {
        try await ensureCurrent()
        return try await cfg.container.database().query(
            "SELECT r.review, r.kind, r.question, r.snapshot, r.log, a.event, a.key, a.dispatched FROM pe_reviews r JOIN pe_attempts a ON a.idem = r.current_idem WHERE r.state='active' ORDER BY r.created_ms, r.review"
        ).compactMap { r in
            guard let id = r.text("review") else { return nil }
            let state: WriteState = r.int("dispatched") == 1 ? .checking : .sending
            if r.text("kind") == "new_ticket" {
                let c = r.blob("snapshot").flatMap { try? StoredCreation(bytes: $0) }
                return WriteStatus(reviewID: id, questionID: nil, option: nil, state: state, review: nil,
                                   creation: c.map { StoredCreationReview(ticketType: $0.ticketType, title: $0.title, owner: $0.owner,
                                                                          uid: r.text("log") ?? "", key: r.text("key") ?? $0.key) })
            }
            let snap = r.blob("snapshot").flatMap { try? StoredSnapshot(bytes: $0) }
            let review = snap.flatMap { s in r.blob("event").flatMap { e in r.text("log").flatMap { storedReview(s, event: e, log: $0) } } }
            return WriteStatus(reviewID: id, questionID: r.text("question").flatMap(ID16.init(hex:)), option: snap?.option, state: state, review: review)
        }
    }

    /// What was reviewed, shown back only when it still binds: the recomputed qid is the stored one and the recomputed hash is the one
    /// the attempt signed. Anything else shows no review (nil), never a different text under the signed answer.
    private func storedReview(_ snap: StoredSnapshot, event: Data, log: String) -> StoredReview? {
        guard let r = try? snap.reviewed(workspace: workspace), r.qid == snap.qid,
              let signed = try? PhoneEvents.restore(bytes: event, kind: .questionAnswered, log: log, workspace: workspace),
              signed.event["hash"]?.string == r.hash else { return nil }
        return StoredReview(ticketKey: snap.ticketKey, ticketUID: r.ticketUID, qid: r.qid, hash: r.hash, text: r.text,
                            options: r.question.options.map { QuestionOption(id: $0.key, label: $0.label, cost: $0.cost) }, option: snap.option,
                            why: r.question.why, recommended: r.question.recommended, to: r.question.to, blocking: r.question.blocking)
    }

    #if DEBUG
    func debugAttemptCount() async throws -> Int {
        try await cfg.container.database().query("SELECT COUNT(*) AS n FROM pe_attempts").first?.int("n").map(Int.init) ?? 0
    }
    #endif

    /// The stored final outcome of a review, if it has one.
    package func writeOutcome(reviewID: String) async throws -> WriteOutcome? {
        try await loadReview(reviewID)?.outcome.flatMap { try? Self.decodeOutcome($0) }
    }

    package func reviewStanding(reviewID: String) async throws -> ReviewStanding {
        guard let rv = try await loadReview(reviewID) else { return .gone }
        if let o = rv.outcome, let outcome = try? Self.decodeOutcome(o) { return .final(outcome) }
        return rv.state == "landed" || rv.state == "landed_unconfirmed" ? .landedUnconfirmed : .unsettled
    }

    // MARK: drivers

    func reviewDriver(_ id: String) async throws -> WriteOutcome {
        if let t = reviewDrivers[id] { return try await t.value }
        guard !closed else { throw SessionError.staleGeneration }
        try crashHook?("pe.driver")              // tests count driver starts here
        let t = Task { try await self.runReview(id) }
        reviewDrivers[id] = t
        defer { reviewDrivers[id] = nil }
        return try await t.value
    }

    func recoverWrites() {
        guard foreground, !closed, writeRecovery == nil else { return }
        writeRecovery = Task {
            defer { self.writeRecovery = nil }
            guard let ids = try? await self.activeReviews() else { return }
            for id in ids {
                guard self.foreground, !Task.isCancelled else { return }
                _ = try? await self.reviewDriver(id)
            }
        }
    }

    private func activeReviews() async throws -> [String] {
        try await ensureCurrent()
        // active reviews, and landings whose confirming read has not succeeded yet
        return try await cfg.container.database().query("SELECT review FROM pe_reviews WHERE state='active' OR (state='landed' AND outcome IS NULL) ORDER BY created_ms")
            .compactMap { $0.text("review") }
    }

    /// Unresolved past the send window (or reads failing): try again after 10 s, 60 s, then every 300 s, while in the foreground.
    func scheduleSettle(_ id: String) {
        guard foreground, !closed, settleRetries[id] == nil else { return }
        let stage = settleStage[id, default: 0]
        settleStage[id] = stage + 1
        let delay: Duration = stage == 0 ? .seconds(10) : (stage == 1 ? .seconds(60) : .seconds(300))
        let clock = cfg.clock
        settleRetries[id] = Task {
            do { try await clock.sleep(for: delay) } catch { return }
            self.settleRetries[id] = nil
            guard self.foreground, !self.closed else { return }
            _ = try? await self.reviewDriver(id)
        }
    }

    func loadReview(_ id: String) async throws -> ReviewRec? {
        try await cfg.container.database().query("SELECT * FROM pe_reviews WHERE review=?", [.text(id)]).first.flatMap(ReviewRec.init)
    }

    func loadAttempts(_ review: String) async throws -> [AttemptRec] {
        try await cfg.container.database().query("SELECT * FROM pe_attempts WHERE review=? ORDER BY n", [.text(review)]).compactMap(AttemptRec.init)
    }

    /// The newest bridge row of an attempt.
    func attemptRow(_ idem: String) async throws -> Row? {
        try await cfg.container.database().query("SELECT * FROM bridge_requests WHERE attempt=? ORDER BY seq DESC", [.text(idem)]).first.flatMap(row(from:))
    }

    // MARK: the review loop (plan 4)

    /// Earlier attempts of the review that may still land: possibly sent (dispatched) and not settled as landed or definitely refused
    /// for themselves (`sent`; `c_auto` and `superseded` included: a host that misreported a refusal may still commit it, plan 4).
    static func mayStillLand(_ a: AttemptRec, current: String) -> Bool {
        a.idem != current && a.dispatched && (a.state == "sent" || a.state == "c_auto" || a.state == "superseded")
    }

    /// What reading the earlier attempts found: one landed (recorded; it wins), at least one still unresolved (no refusal of the
    /// review may be final in this pass: it may still land), or none of them can land any more.
    enum EarlierRead { case landed, unresolved, clear }

    /// Reads every earlier attempt that may still land (oldest first, each against its OWN event): a landing is recorded and wins.
    /// A definite refusal of a `sent` one is recorded as its own evidence. `skip` holds the attempts already read in this pass.
    private func settleEarlier(_ rv: ReviewRec, _ attempts: [AttemptRec], skip: inout Set<String>) async throws -> EarlierRead {
        var unresolved = false
        for e in attempts where Self.mayStillLand(e, current: rv.currentIdem) && !skip.contains(e.idem) {
            skip.insert(e.idem)
            let ev = try await settleByReading(e, rv)
            switch ev {
            case .landed: try await apply(ev, rv, e); return .landed
            case .definite where e.state == "sent": if try await !apply(ev, rv, e) { unresolved = true }
            case .definite: break
            default: unresolved = true
            }
        }
        return unresolved ? .unresolved : .clear
    }

    /// MUST-1: before a refusal finishes the review, every earlier attempt that may still land is read once more. A landing wins
    /// (`continue`); a read that did not settle one of them (a transient failure) keeps the review checking, never refused.
    private func earlierAllowFinal(_ rv: ReviewRec, _ attempts: [AttemptRec]) async throws -> EarlierRead {
        var fresh: Set<String> = []
        return try await settleEarlier(rv, attempts, skip: &fresh)
    }

    func runReview(_ id: String) async throws -> WriteOutcome {
        var reseals = 0, sends = 0
        var readEarlier: Set<String> = []
        for _ in 0..<12 {
            try Task.checkCancellation()
            try await ensureCurrent()
            guard let rv = try await loadReview(id) else { throw SessionError.unknownRequest }
            switch rv.state {
            case "landed", "landed_unconfirmed":
                if let o = rv.outcome, let decoded = try? Self.decodeOutcome(o) { return decoded }
                return try await confirmLanding(rv)
            case "active": break
            default: return rv.outcome.flatMap { try? Self.decodeOutcome($0) } ?? .needsReview(.notSent)
            }
            let attempts = try await loadAttempts(id)
            // An earlier possibly sent attempt is settled first, against its OWN event: a late landing of any attempt wins.
            if try await settleEarlier(rv, attempts, skip: &readEarlier) == .landed { continue }
            guard let a = attempts.first(where: { $0.idem == rv.currentIdem }) else { throw SessionError.unknownRequest }
            let ev: Evidence
            var retryRead = false
            switch a.state {
            case "signed":
                ev = try await send(a)
                // charged but unanswered: settle it by reading in the next pass
                if sends < 1, try await loadAttempts(id).first(where: { $0.idem == a.idem })?.state == "sent" { sends += 1; retryRead = true }
            case "sent":
                let read = try await settleByReading(a, rv)
                if case .unresolved = read, reseals < 2, try await inWindow(a) {
                    reseals += 1
                    ev = try await reseal(a)
                    retryRead = true
                } else { ev = read }
            case "c_auto":
                if try await tryAutoResign(rv, a) { continue }
                // final: every earlier attempt that may still land is read once more first (a late landing wins)
                switch try await earlierAllowFinal(rv, attempts) {
                case .landed: continue
                case .unresolved: scheduleSettle(id); return .checking
                case .clear: break
                }
                try await finishReview(rv, state: "needs_review", outcome: .needsReview(.workspaceChanged))
                continue
            default:
                // a terminal attempt under an active review (a crash between the two writes): finish from its class
                try await finishReview(rv, state: "needs_review", outcome: .needsReview(.notSent))
                continue
            }
            switch ev {
            case .landed: try await apply(ev, rv, a)
            case .definite(_, let cls, _):
                // before a final refusal (C-review or D) settles the review, every earlier attempt that may still land is read once more
                if cls != .cAuto {
                    switch try await earlierAllowFinal(rv, attempts) {
                    case .landed: continue
                    case .unresolved: scheduleSettle(id); return .checking
                    case .clear: break
                    }
                }
                // `question.answered` whose answerer could not be read: not final either
                if try await !apply(ev, rv, a) { scheduleSettle(id); return .checking }
            case .notSent:
                // never sent, so it is discarded; but the review's "not sent" is final only once no earlier attempt may still land
                switch try await earlierAllowFinal(rv, attempts) {
                case .landed: continue
                case .unresolved: scheduleSettle(id); return .checking
                case .clear: try await discardUnsent(rv, a)
                }
            case .windowPassed:
                if !a.dispatched {
                    switch try await earlierAllowFinal(rv, attempts) {
                    case .landed: continue
                    case .unresolved: scheduleSettle(id); return .checking
                    case .clear: try await discardUnsent(rv, a); continue
                    }
                }
                scheduleSettle(id)
                return .checking
            case .unresolved:
                if retryRead { continue }
                scheduleSettle(id)
                return .checking
            }
        }
        scheduleSettle(id)
        return .checking
    }

    private func inWindow(_ a: AttemptRec) async throws -> Bool {
        WriteClock(wallMs: cfg.wall.nowMs, offsetMs: try await clockOffsetMs(), monoMs: monotonicMs(a.idem)).holds(ulidMs: a.ulidMs, signedWallMs: a.signedWallMs)
    }

    func restore(_ a: AttemptRec, _ rv: ReviewRec) throws -> SignedPhoneEvent {
        try PhoneEvents.restore(bytes: a.event, kind: rv.eventKind, log: rv.log, workspace: workspace)
    }

    /// The first send of a signed attempt, through the gate.
    private func send(_ a: AttemptRec) async throws -> Evidence {
        guard let row = try await attemptRow(a.idem), let rv = try await loadReview(a.review) else { return .unresolved }
        do {
            let resp = try await runDriver(row, isResend: false)
            return try evidence(response: resp, a, rv)
        } catch WriteGateError.lifecycleEnded {
            // SHOULD-1: the fence stopped the first dispatch before the charge committed: never sent, and never sent later either
            // (`notSent`, discarded). Charged (the window after the charge): the driver stops, the attempt is settled later.
            if try await loadAttempts(a.review).first(where: { $0.idem == a.idem })?.dispatched == false { return .notSent }
            throw WriteGateError.lifecycleEnded
        } catch { return try evidence(error: error, a) }
    }

    /// The same signed bytes under a new rid (orch-52 Q5), only while the window holds; the gate checks it again.
    private func reseal(_ a: AttemptRec) async throws -> Evidence {
        guard let row = try await attemptRow(a.idem), let rv = try await loadReview(a.review) else { return .unresolved }
        do {
            let next = try await prepare(logical: row.logical, plaintext: row.plaintext, replacing: row.rid, reconciled: true)
            let resp = try await runDriver(next, isResend: false)
            return try evidence(response: resp, a, rv)
        } catch { noteIfLocked(error); return try evidence(error: error, a) }
    }

    private func evidence(response: BridgeResponse, _ a: AttemptRec, _ rv: ReviewRec) throws -> Evidence {
        guard let r = try? Self.result(of: response), let w = try? WriteResult(parsing: r, expecting: try restore(a, rv)) else { return .unresolved }
        return .landed(seq: w.seq, src: "write")
    }

    /// A direct answer to the write. Landed evidence (`seqs`) first; a definite class only for C and D; everything else is unresolved.
    private func evidence(error: Error, _ a: AttemptRec) throws -> Evidence {
        switch error {
        case is CancellationError: throw error
        case ViewError.offline: throw error
        case WriteGateError.windowPassed: return .windowPassed
        // the lifecycle ended at the gate or right before `bridgePost`: the driver stops; a charged attempt is settled later
        case WriteGateError.lifecycleEnded: throw error
        case WriteGateError.eligibilityLost, WriteGateError.unavailable, WriteGateError.bytesChanged: return a.dispatched ? .unresolved : .notSent
        case ClientError.host(let refusal):
            if case .host(_, _, let seqs?, _) = refusal { return seqs.count == 1 ? .landed(seq: seqs[0], src: "write") : .unresolved }
            let cls = R2.retryClass(of: refusal, context: PhoneRefusalContext(eventID: a.idem, hostNowMs: cfg.wall.nowMs, admitted: true))
            return cls.isDefinite ? .definite(code: refusal.code, cls: cls, src: "write") : .unresolved
        default: return .unresolved
        }
    }

    /// `outcome.get`, then the log where the spec says so. Positive evidence first; failed, malformed or pending reads stay unresolved.
    func settleByReading(_ a: AttemptRec, _ rv: ReviewRec) async throws -> Evidence {
        let e = try restore(a, rv)
        do {
            let o = try await outcomeGet(idem: a.idem)
            switch o.state {
            case .committed:
                guard let r = o.result, let w = try? WriteResult(parsing: r, expecting: e) else { return .unresolved }
                return .landed(seq: w.seq, src: "outcome")
            case .failed, .partial:
                if let s = o.seqs { return s.count == 1 ? .landed(seq: s[0], src: "outcome") : .unresolved }
                guard let code = o.errorCode else { return .unresolved }
                let cls = PhoneRetryTable.classify(code, PhoneRefusalContext(eventID: a.idem, hostNowMs: try await hostNowMs()))
                return cls.isDefinite ? .definite(code: code, cls: cls, src: "outcome") : .unresolved
            case .pending: return .unresolved
            }
        } catch ClientError.host(.host(let code, _, _, _)) where code.bytesEqual("outcome.unknown_idem") {
            guard try await hostNowMs() >= saturatingAddMs(a.ulidMs, PhoneRetryTable.unknownIdemBoundMs) else { return .unresolved }
            return try await logRead(a, rv, absent: code)
        } catch ClientError.host(.host(let code, _, _, _)) where code.bytesEqual("idem.expired") {
            return try await logRead(a, rv, absent: code)
        } catch is CancellationError { throw CancellationError() }
        catch { return .unresolved }
    }

    func hostNowMs() async throws -> Int64 { saturatingAddMs(cfg.wall.nowMs, try await clockOffsetMs()) }

    /// The explicit log rule (plan 4, codex 9): the question's answer is this event (landed, `src: log`), or the read shows it absent
    /// (C-review). A failed read is unresolved.
    private func logRead(_ a: AttemptRec, _ rv: ReviewRec, absent code: String) async throws -> Evidence {
        if rv.isCreation { return try await creationLogRead(a, rv, absent: code) }
        do {
            let snap = try StoredSnapshot(bytes: rv.snapshot)
            let get = try await ticketGet(snap.ticketUID)
            guard get.uid.bytesEqual(snap.ticketUID), let q = get.questions.first(where: { $0.question?.id.bytesEqual(snap.question.id) == true })?.question
            else { return .unresolved }
            if let ans = q.answer, ans.id.bytesEqual(a.idem) { return .landed(seq: ans.seq, src: "log") }
            return .definite(code: code, cls: .cReview, src: "log")
        } catch is CancellationError { throw CancellationError() }
        catch { return .unresolved }
    }

    // MARK: recording evidence (one transaction each)

    static func appendEvidence(_ tx: SQLiteTransaction, idem: String, _ item: [String: JSONValue]) throws -> String {
        let old = try tx.query("SELECT evidence FROM pe_attempts WHERE idem=?", [.text(idem)]).first?.text("evidence") ?? "[]"
        var list = (try? StrictJSON.parse(Data(old.utf8)))?.array ?? []
        list.append(.object(item))
        let new = String(decoding: try canonicalJSON(.array(list)), as: UTF8.self)
        // append-only: the new text extends the old one (the trigger enforces it too)
        guard new.utf8.starts(with: old.utf8.dropLast()) else { throw ViewError.malformed }
        return new
    }

    /// Records the evidence. False: nothing was recorded because it cannot be decided yet (`question.answered` whose answerer could not
    /// be read: the answer may be one of this review's own attempts), so the review stays checking.
    @discardableResult
    private func apply(_ ev: Evidence, _ rv: ReviewRec, _ a: AttemptRec) async throws -> Bool {
        switch ev {
        case .landed(let seq, let src): try await recordLanding(rv, a, seq: seq, src: src)
        case .definite(let code, let cls, let src):
            switch cls {
            case .d where rv.isCreation && code.bytesEqual("ticket.exists"):
                return try await applyTicketExists(rv, a, code: code, src: src)
            case .d where !rv.isCreation && code.bytesEqual("question.answered"):
                // who answered? If it was this very event, that is our landing
                let snap = try StoredSnapshot(bytes: rv.snapshot)
                let read: Question?
                do {
                    if let qid = ID16(hex: snap.qid) { read = try await readQuestion(qid, hint: snap.locator).question } else { read = nil }
                } catch is CancellationError { throw CancellationError() }
                catch ClientError.host(.host(let c, _, _, _)) where c.bytesEqual("not_found") { read = nil }   // a successful "gone"
                catch { return false }                                                                       // transient: undecided
                if let q = read, let r = q.resolution {
                    // the counting answer is one of THIS review's attempts (this one, or an earlier one delivered late): that is our
                    // landing, and it wins over the refusal of the later attempt
                    if let mine = try await loadAttempts(rv.review).first(where: { r.decisionID.bytesEqual($0.idem) }) {
                        try await recordLanding(rv, mine, seq: nil, src: "log"); return true
                    }
                    try await recordDefinite(rv, a, code: code, cls: cls, src: src, outcome: .alreadyAnswered(label: r.byDeviceLabel, at: r.atMs))
                } else {
                    try await recordDefinite(rv, a, code: code, cls: cls, src: src, outcome: .refused(code: code))
                }
            case .cReview: try await recordDefinite(rv, a, code: code, cls: cls, src: src, outcome: .needsReview(.changed(code: code)))
            case .cAuto: try await recordDefinite(rv, a, code: code, cls: cls, src: src, outcome: nil)
            default: try await recordDefinite(rv, a, code: code, cls: cls, src: src, outcome: .refused(code: code))
            }
        default: break
        }
        return true
    }

    /// A landing is final: the attempt `landed`, the review `landed` with it, every other open attempt superseded and every bridge row of
    /// the review deleted, in one transaction.
    func recordLanding(_ rv: ReviewRec, _ a: AttemptRec, seq: Int64?, src: String) async throws {
        let now = cfg.wall.nowMs, hook = crashHook
        var built: [String: JSONValue] = ["src": .string(src), "at": .int(now)]
        if let seq { built["seqs"] = [.int(seq)] }
        let item = built
        try await cfg.container.database().transaction { tx in
            let evidence = try Self.appendEvidence(tx, idem: a.idem, item)
            try tx.execute("UPDATE pe_attempts SET state='landed', evidence=? WHERE idem=?", [.text(evidence), .text(a.idem)])
            try hook?("pe.evidence")
            try tx.execute("UPDATE pe_reviews SET state='landed', landed_idem=?, outcome=NULL WHERE review=? AND state NOT IN ('landed','landed_unconfirmed')",
                           [.text(a.idem), .text(rv.review)])
            try tx.execute("UPDATE pe_attempts SET state='superseded' WHERE review=? AND idem<>? AND state IN ('signed','sent')", [.text(rv.review), .text(a.idem)])
            try tx.execute("DELETE FROM bridge_requests WHERE attempt IN (SELECT idem FROM pe_attempts WHERE review=?)", [.text(rv.review)])
        }
        for x in try await loadAttempts(rv.review) { attemptMonotonic[x.idem] = nil }
        settleStage[rv.review] = nil
    }

    /// Definite, zero landed for this attempt: its class and evidence, its bridge rows gone; the review finishes unless it is C-auto.
    func recordDefinite(_ rv: ReviewRec, _ a: AttemptRec, code: String, cls: PhoneRetryClass, src: String, outcome: WriteOutcome?) async throws {
        let state = cls == .cAuto ? "c_auto" : (cls == .cReview ? "c_review" : "d")
        let reviewState = cls == .cReview ? "needs_review" : "refused"
        let now = cfg.wall.nowMs, hook = crashHook
        let encoded = try outcome.map { String(decoding: try canonicalJSON(Self.encodeOutcome($0)), as: UTF8.self) }
        try await cfg.container.database().transaction { tx in
            let evidence = try Self.appendEvidence(tx, idem: a.idem, ["src": .string(src), "code": .string(code), "at": .int(now)])
            guard try tx.execute("UPDATE pe_attempts SET state=?, evidence=? WHERE idem=? AND state IN ('signed','sent')",
                                 [.text(state), .text(evidence), .text(a.idem)]) == 1 else { return }
            try hook?("pe.evidence")
            try tx.execute("DELETE FROM bridge_requests WHERE attempt=?", [.text(a.idem)])
            if let encoded, a.idem == rv.currentIdem {
                try tx.execute("UPDATE pe_reviews SET state=?, outcome=? WHERE review=? AND state='active'", [.text(reviewState), .text(encoded), .text(rv.review)])
            }
        }
        attemptMonotonic[a.idem] = nil
        if outcome != nil { emit(.invalidated) }
    }

    private func finishReview(_ rv: ReviewRec, state: String, outcome: WriteOutcome) async throws {
        let encoded = String(decoding: try canonicalJSON(Self.encodeOutcome(outcome)), as: UTF8.self)
        try await cfg.container.database().execute("UPDATE pe_reviews SET state=?, outcome=? WHERE review=? AND state='active'",
                                                   [.text(state), .text(encoded), .text(rv.review)])
        emit(.invalidated)
    }

    /// Never sent and may not be sent any more: the attempt and all its bridge rows go together (CAS on `dispatched=0`), and the review
    /// asks for a new one ("Not sent; review again").
    func discardUnsent(_ rv: ReviewRec, _ a: AttemptRec) async throws {
        let encoded = String(decoding: try canonicalJSON(Self.encodeOutcome(.needsReview(.notSent))), as: UTF8.self)
        try await cfg.container.database().transaction { tx in
            guard try tx.execute("UPDATE pe_attempts SET state='discarded' WHERE idem=? AND dispatched=0 AND state='signed'", [.text(a.idem)]) == 1 else { return }
            try tx.execute("DELETE FROM bridge_requests WHERE attempt=?", [.text(a.idem)])
            try tx.execute("UPDATE pe_reviews SET state='needs_review', outcome=? WHERE review=? AND state='active'", [.text(encoded), .text(rv.review)])
        }
        attemptMonotonic[a.idem] = nil
        emit(.invalidated)
    }

    /// Step 2 of plan 4: a fresh log read confirms the landing (its seq is the log's, never made up), or a SUCCESSFUL read showing
    /// something else makes the review `landed_unconfirmed` (never downgraded). A failed read leaves the review `landed` with no outcome
    /// yet: the confirmation is tried again later.
    private func confirmLanding(_ rv: ReviewRec) async throws -> WriteOutcome {
        guard let idem = rv.landedIdem, let a = try await loadAttempts(rv.review).first(where: { $0.idem == idem }) else { throw SessionError.unknownRequest }
        if rv.isCreation { return try await confirmCreation(rv, a) }
        let snap = try StoredSnapshot(bytes: rv.snapshot)
        let seq = a.landedSeq
        let outcome: WriteOutcome
        do {
            let get = try await ticketGet(snap.ticketUID)
            let q = get.uid.bytesEqual(snap.ticketUID) ? get.questions.first(where: { $0.question?.id.bytesEqual(snap.question.id) == true })?.question : nil
            if let q, let ans = q.answer, ans.id.bytesEqual(idem) {
                let s = seq ?? ans.seq
                outcome = a.origin == "auto" ? .landedAfterResign(seq: s, key: snap.ticketKey) : .landed(seq: s, key: snap.ticketKey)
            } else {
                outcome = .landedUnconfirmed(seq: seq, reason: q == nil ? .unavailable : .changed)
            }
        } catch is CancellationError { throw CancellationError() }
        catch ClientError.host(.host(let code, _, _, _)) where code.bytesEqual("not_found") {
            // a successful answer from the host: the ticket can't be shown any more
            outcome = .landedUnconfirmed(seq: seq, reason: .unavailable)
        } catch {
            // transient: stays `landed` with outcome NULL, confirmed on a later pass; meanwhile it reads as landed (its seq known) or checking
            scheduleSettle(rv.review)
            guard let seq else { return .checking }
            return a.origin == "auto" ? .landedAfterResign(seq: seq, key: snap.ticketKey) : .landed(seq: seq, key: snap.ticketKey)
        }
        let state: String
        if case .landedUnconfirmed = outcome { state = "landed_unconfirmed" } else { state = "landed" }
        let encoded = String(decoding: try canonicalJSON(Self.encodeOutcome(outcome)), as: UTF8.self)
        try await cfg.container.database().execute("UPDATE pe_reviews SET state=?, outcome=? WHERE review=? AND outcome IS NULL",
                                                   [.text(state), .text(encoded), .text(rv.review)])
        emit(.invalidated)
        return outcome
    }

    // MARK: automatic re-sign (plan 3.4)

    func tryAutoResign(_ rv: ReviewRec, _ a: AttemptRec) async throws -> Bool {
        // the review's ticket, bound to its eligibility token: re-validated after the fresh read and inside the signing transaction
        // the fence's ticket already requires the foreground (and an unlocked, protected-data lifecycle)
        guard let policy, let ticket = lifecycleFence.ticket(review: rv.review), rv.resigns < Int64(AutoResign.maxPerReview),
              hostWritesAllowed(rv.kind) else { return false }
        #if DEBUG && targetEnvironment(simulator)
        // dev-sandbox lane: a fresh `relay.dev` read first; without a grant nothing is signed again (the answer goes back to review)
        if policy.lane == .devSandbox, await freshDevGrant() == nil { return false }
        #endif
        do {
            if rv.isCreation { return try await autoResignCreation(rv, a, policy: policy, ticket: ticket) }
            return try await autoResign(rv, a, policy: policy, ticket: ticket)
        }
        catch {
            // SH1: a lock (or any lifecycle end) inside the re-sign ends the eligibility here, whatever the App does: no later re-sign
            noteIfLocked(error)
            switch error {
            case WriteGateError.notCurrent, WriteGateError.eligibilityLost, WriteGateError.lifecycleEnded, CustodyError.locked, VaultError.locked:
                lifecycleFence.revoke(review: rv.review)
                return false
            default: throw error
            }
        }
    }

    private func autoResign(_ rv: ReviewRec, _ a: AttemptRec, policy: PersonEventPolicy, ticket: LifecycleFence.Ticket) async throws -> Bool {
        let snap = try StoredSnapshot(bytes: rv.snapshot)
        let attempts = try await loadAttempts(rv.review)
        let earlierUnresolved = attempts.contains { $0.idem != a.idem && $0.dispatched && ($0.state == "signed" || $0.state == "sent") }
        let stored = try snap.reviewed(workspace: workspace)
        guard let qid = ID16(hex: snap.qid) else { return false }
        let fresh: F1Question.Reviewed
        do {
            guard let f = try await readQuestion(qid, hint: snap.locator).reviewed else { return false }
            fresh = f
        } catch is CancellationError { throw CancellationError() } catch { return false }
        guard lifecycleFence.valid(ticket) else { return false }
        let actor = try policy.actor(person: try storedPerson(), device: cfg.deviceID)
        let offset = try await clockOffsetMs()
        let now = cfg.wall.nowMs
        let id = try ULID.make(timeMs: saturatingAddMs(now, offset), random: cfg.entropy.bytes(ULID.randomLength))
        let proposed = try PhoneEvents.unsignedAnswer(try snap.reviewed(workspace: workspace, rosterV: fresh.rosterV), option: snap.option, text: nil,
                                                      id: id, actor: actor, workspace: workspace)
        let previousEvent = try restore(a, rv)
        var previous = previousEvent.event; previous["sig"] = nil
        let input = AutoResignInput(lastClass: .cAuto, lastAnswerWasRefusedForExactIdem: true, earlierIdemUnresolved: earlierUnresolved,
                                    reviewed: .answer(try AnswerDisplay(stored, option: snap.option, text: nil)),
                                    fresh: .answer(try AnswerDisplay(fresh, option: snap.option, text: nil)),
                                    previous: previous, proposed: proposed.event, previousLog: previousEvent.log, proposedLog: proposed.log,
                                    keyAssignedDisclosed: false, foregroundAndUnlockedSinceTap: lifecycleFence.valid(ticket), autoResignsSoFar: Int(rv.resigns))
        guard AutoResign.decide(input) == .allow else { return false }
        let build = Self.attemptBuild(.resign(review: rv.review, expectIdem: a.idem, expectVer: rv.ver), unsigned: proposed, origin: "auto",
                                      signer: cfg.identity.sig, actor: actor, pub: cfg.identity.publicKeys.sig, workspace: workspace,
                                      clock: WriteClock(wallMs: now, offsetMs: offset, monoMs: 0), fence: lifecycleFence, ticket: ticket,
                                      hook: crashHook)
        _ = try await prepare(logical: cfg.entropy.id16(), plaintext: Data(), write: build)
        return true
    }

    // MARK: outcome codec (`pe_reviews.outcome`)

    static func encodeOutcome(_ o: WriteOutcome) -> JSONValue {
        switch o {
        case .landed(let seq, let key): ["kind": "landed", "seq": .int(seq), "key": .string(key)]
        case .landedAfterResign(let seq, let key): ["kind": "landed_after_resign", "seq": .int(seq), "key": .string(key)]
        case .landedUnconfirmed(let seq, let reason): ["kind": "landed_unconfirmed", "seq": seq.map(JSONValue.int) ?? .null, "reason": .string(reason.rawValue)]
        case .checking: ["kind": "checking"]
        case .needsReview(let r):
            switch r {
            case .notSent: ["kind": "needs_review", "reason": "not_sent"]
            case .changed(let code): ["kind": "needs_review", "reason": "changed", "code": .string(code)]
            case .workspaceChanged: ["kind": "needs_review", "reason": "workspace_changed"]
            }
        case .refused(let code): ["kind": "refused", "code": .string(code)]
        case .alreadyAnswered(let label, let at): ["kind": "already_answered", "label": .string(label), "at": .int(at)]
        case .ticketExists(let key): ["kind": "ticket_exists", "key": key.map(JSONValue.string) ?? .null]
        }
    }

    static func decodeOutcome(_ text: String) throws -> WriteOutcome {
        guard let m = try StrictJSON.parse(Data(text.utf8)).object, let kind = m["kind"]?.string else { throw ViewError.malformed }
        switch kind {
        case "landed": guard let s = m["seq"]?.int, let k = m["key"]?.string else { throw ViewError.malformed }; return .landed(seq: s, key: k)
        case "landed_after_resign": guard let s = m["seq"]?.int, let k = m["key"]?.string else { throw ViewError.malformed }; return .landedAfterResign(seq: s, key: k)
        case "landed_unconfirmed":
            guard let r = m["reason"]?.string.flatMap(LandedUnconfirmedReason.init(rawValue:)) else { throw ViewError.malformed }
            return .landedUnconfirmed(seq: m["seq"]?.int, reason: r)
        case "checking": return .checking
        case "needs_review":
            switch m["reason"]?.string {
            case "not_sent": return .needsReview(.notSent)
            case "changed": return .needsReview(.changed(code: m["code"]?.string ?? ""))
            case "workspace_changed": return .needsReview(.workspaceChanged)
            default: throw ViewError.malformed
            }
        case "refused": return .refused(code: m["code"]?.string ?? "")
        case "already_answered": guard let l = m["label"]?.string, let a = m["at"]?.int else { throw ViewError.malformed }; return .alreadyAnswered(label: l, at: a)
        case "ticket_exists": return .ticketExists(key: m["key"]?.string)
        default: throw ViewError.malformed
        }
    }
}
