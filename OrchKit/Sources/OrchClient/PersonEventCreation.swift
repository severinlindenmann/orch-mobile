import Foundation
import OrchCustody
import OrchProtocol
import OrchStore

// MARK: public surface (C2b creation, increment 3)

/// One reviewed creation (host 11A.14 14.1 `ticket.created`, R2 title-only): the type and title the person typed, the owner from this
/// device's certificate, the store's advertised next key from a fresh `workspace.show`, and the new ticket's uid, a ULID made ONCE for
/// this review (every attempt keeps it, 14.4 "one review = one uid"). The creation sheet renders exactly this value, discloses
/// "The key is assigned when sent (next: KEY)", and `create` signs it. Equality is byte equality plus the review token.
public struct CreationReview: Sendable, Equatable {
    package let token: UUID
    public let ticketType: String
    package let preparedTitle: PhoneEvents.PreparedText
    /// The prepared title (LF, NFC, checked): exactly what is signed.
    public var title: String { preparedTitle.value }
    /// The owner: this device's person (`p_…`), from its certificate.
    public let owner: String
    /// `workspace.show` -> `next_key` at review time (strict key shape): advisory, never a reservation.
    public let nextKey: String
    /// The new ticket's uid (the event's `log`).
    public let uid: String
    package let rosterV: Int64
    public let workspaceName: String
    public let realm: Realm
    public let workspaceID: ID16
    public let generation: Int64

    /// The disclosure the creation sheet shows before Sign (14.4 item 4: the consent for a changed key on an automatic re-sign).
    public var disclosure: String { Self.disclosure(nextKey: nextKey) }
    public static func disclosure(nextKey: String) -> String { "The key is assigned when sent (next: \(nextKey))" }

    public static func == (a: CreationReview, b: CreationReview) -> Bool {
        a.token == b.token && a.ticketType.bytesEqual(b.ticketType) && a.title.bytesEqual(b.title) && a.owner.bytesEqual(b.owner)
            && a.nextKey.bytesEqual(b.nextKey) && a.uid.bytesEqual(b.uid) && a.rosterV == b.rosterV && a.workspaceID == b.workspaceID
            && a.generation == b.generation && a.realm == b.realm && a.workspaceName.bytesEqual(b.workspaceName)
    }
}

/// A creation still being sent or settled (`pendingWrites`): what was reviewed, and the key its current attempt carries.
public struct StoredCreationReview: Equatable, Sendable {
    public let ticketType: String, title: String, owner: String, uid: String, key: String
    public init(ticketType: String, title: String, owner: String, uid: String, key: String) {
        self.ticketType = ticketType; self.title = title; self.owner = owner; self.uid = uid; self.key = key
    }
}

// MARK: internals

/// `pe_reviews.snapshot` of a creation: what the sheet showed (type, title, owner), the key it disclosed and signed first, the roster.
struct StoredCreation: Sendable {
    let ticketType: String, title: String, owner: String, key: String
    let rosterV: Int64

    init(_ r: CreationReview) {
        ticketType = r.ticketType; title = r.title; owner = r.owner; key = r.nextKey; rosterV = r.rosterV
    }

    init(bytes: Data) throws {
        guard let o = try StrictJSON.parse(bytes).object, Set(o.keys) == ["kind", "ticket_type", "title", "owner", "key", "roster_v"],
              o["kind"]?.string == "new_ticket", let t = o["ticket_type"]?.string, let title = o["title"]?.string, let owner = o["owner"]?.string,
              let key = o["key"]?.string, let roster = o["roster_v"]?.int else { throw ViewError.malformed }
        ticketType = t; self.title = title; self.owner = owner; self.key = key; rosterV = roster
    }

    func bytes() throws -> Data {
        try canonicalJSON(["kind": "new_ticket", "ticket_type": .string(ticketType), "title": .string(title), "owner": .string(owner),
                           "key": .string(key), "roster_v": .int(rosterV)])
    }

    /// The unsigned event of this review with the given key, roster and id (the title is prepared again: it was prepared when reviewed,
    /// so this is the identity; anything else fails).
    func unsigned(uid: String, key: String, rosterV: Int64, id: String, actor: PhoneActor, workspace: ID16) throws -> PhoneEvents.UnsignedPhoneEvent {
        let prepared = try PhoneEvents.prepareText(title, oneLine: true)
        guard prepared.value.bytesEqual(title), actor.personID.bytesEqual(owner) else { throw WriteGateError.bytesChanged }
        return try PhoneEvents.unsignedCreate(ticketUID: uid, key: key, ticketType: ticketType, title: prepared, id: id, rosterV: rosterV,
                                              actor: actor, workspace: workspace)
    }

    /// What the sheet displayed, in the shape `AutoResign` compares.
    func display() throws -> CreationDisplay {
        CreationDisplay(ticketType: ticketType, title: try PhoneEvents.prepareText(title, oneLine: true), owner: owner)
    }
}

/// The key prefix (`MOB` of `MOB-0002`).
func keyPrefix(_ key: String) -> Substring { key.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? "" }

extension WorkspaceSession {
    // MARK: reviewing a creation

    /// Reviews a new ticket: the title through `prepareText(oneLine: true)` (its violations are thrown as `PhoneEvents.Failure`), the type
    /// one of the five, and a fresh `workspace.show` whose strict `next_key` the sheet discloses. The uid is made here, once.
    package func reviewCreation(type: String, title: String) async throws -> CreationReview {
        try await ensureCurrent()
        guard let policy, hostWritesAllowed("new_ticket") else { throw ViewError.writesUnavailable }
        guard let ticketType = PhoneEvents.ticketTypes.first(where: { $0.bytesEqual(type) }) else { throw PhoneEvents.Failure.badType }
        let prepared = try PhoneEvents.prepareText(title, oneLine: true)
        let n = prepared.value.unicodeScalars.count
        guard n >= 1, n <= PhoneEvents.maxTitleScalars else { throw PhoneEvents.Failure.titleLength }
        let lifecycle = reviewLifecycle
        let show = try await workspaceShow()
        try await ensureCurrent()
        guard foreground, lifecycle == reviewLifecycle else { throw ViewError.invalidReview }
        // `next_key` is null for a principal that may not create (no `decide`): nothing to review
        guard show.id.bytesEqual(workspace.hex), let key = show.nextKey, validTicketKey(key) else { throw ViewError.writesUnavailable }
        let actor = try policy.actor(person: try storedPerson(), device: cfg.deviceID)
        let offset = try await clockOffsetMs()
        let uid = try ULID.make(timeMs: saturatingAddMs(cfg.wall.nowMs, offset), random: cfg.entropy.bytes(ULID.randomLength))
        lifecycleFence.reviewedAgain()
        if creationReviews.count >= 32 { creationReviews.removeAll() }
        let review = CreationReview(token: UUID(), ticketType: ticketType, preparedTitle: prepared, owner: actor.personID, nextKey: key, uid: uid,
                                    rosterV: show.membersV, workspaceName: show.name, realm: cfg.context.realm, workspaceID: workspace,
                                    generation: generation)
        creationReviews[review.token] = review
        return review
    }

    // MARK: creating

    /// Signs and sends the reviewed creation. `disclosedKey` is the next key the sheet disclosed when it armed ("The key is assigned when
    /// sent (next: KEY)"); it must be the review's, and it is stored as `pe_reviews.key_disclosed` (no disclosure: no automatic re-sign
    /// with another key). The review token is consumed before anything suspends, so a double tap signs once.
    package func create(_ r: CreationReview, disclosedKey: String?) async throws -> WriteOutcome {
        try await ensureCurrent()
        guard let policy, hostWritesAllowed("new_ticket") else { throw ViewError.writesUnavailable }
        guard r.workspaceID == workspace, r.generation == generation, r.realm == cfg.context.realm, foreground,
              let held = creationReviews[r.token], held == r else { throw ViewError.invalidReview }
        if let disclosedKey, !disclosedKey.bytesEqual(r.nextKey) { throw ViewError.invalidReview }
        creationReviews[r.token] = nil
        let reviewID = cfg.entropy.id16().hex
        guard let ticket = lifecycleFence.issue(review: reviewID) else { throw lifecycleFence.isLocked ? CustodyError.locked : ViewError.invalidReview }
        do { try await beginCreate(r, disclosedKey: disclosedKey, reviewID: reviewID, policy: policy, ticket: ticket) }
        catch {
            lifecycleFence.revoke(review: reviewID)
            noteIfLocked(error)
            switch error {
            case WriteGateError.notCurrent, WriteGateError.lifecycleEnded:
                throw lifecycleFence.isLocked ? CustodyError.locked : ViewError.invalidReview
            default: throw error
            }
        }
        do { return try await reviewDriver(reviewID) }
        catch { noteIfLocked(error); throw AnswerCommitted(reviewID: reviewID, underlying: error) }
    }

    private func beginCreate(_ r: CreationReview, disclosedKey: String?, reviewID: String, policy: PersonEventPolicy,
                             ticket: LifecycleFence.Ticket) async throws {
        let actor = try policy.actor(person: try storedPerson(), device: cfg.deviceID)
        guard actor.personID.bytesEqual(r.owner) else { throw ViewError.invalidReview }
        let offset = try await clockOffsetMs()
        guard lifecycleFence.valid(ticket) else { throw WriteGateError.lifecycleEnded }
        let now = cfg.wall.nowMs
        let id = try ULID.make(timeMs: saturatingAddMs(now, offset), random: cfg.entropy.bytes(ULID.randomLength))
        let stored = StoredCreation(r)
        let unsigned = try stored.unsigned(uid: r.uid, key: r.nextKey, rosterV: r.rosterV, id: id, actor: actor, workspace: workspace)
        let build = Self.attemptBuild(.insertCreation(review: reviewID, log: r.uid, snapshot: try stored.bytes(), keyDisclosed: disclosedKey, nowMs: now),
                                      unsigned: unsigned, origin: "tap", signer: cfg.identity.sig, actor: actor, pub: cfg.identity.publicKeys.sig,
                                      workspace: workspace, clock: WriteClock(wallMs: now, offsetMs: offset, monoMs: 0), fence: lifecycleFence,
                                      ticket: ticket, hook: crashHook)
        _ = try await prepare(logical: cfg.entropy.id16(), plaintext: Data(), write: build)
    }

    // MARK: settlement of a creation

    /// The explicit log rule for a creation (plan 4): the review's own uid exists with this attempt's key (landed, `src: log`, seq 1: the
    /// creation is the first event of its log); it exists with another key (`ticket.exists`: settled by the retry note); or a successful
    /// read shows it absent (C-review). A failed read is unresolved.
    func creationLogRead(_ a: AttemptRec, _ rv: ReviewRec, absent code: String) async throws -> Evidence {
        do {
            let get = try await ticketGet(rv.log)
            guard get.uid.bytesEqual(rv.log) else { return .unresolved }
            if let k = a.key, get.key.bytesEqual(k) { return .landed(seq: 1, src: "log") }
            return .definite(code: "ticket.exists", cls: .d, src: "log")
        } catch is CancellationError { throw CancellationError() }
        catch ClientError.host(.host(let c, _, _, _)) where c.bytesEqual("not_found") {
            return .definite(code: code, cls: .cReview, src: "log")
        } catch { return .unresolved }
    }

    /// `ticket.exists` (the retry note): every earlier attempt was already settled by `outcome.get` (the review loop reads them before any
    /// final refusal). What is left is attribution by the review's OWN uid: the phone made it for this review alone, so a ticket at that
    /// uid whose key is one of this review's dispatched attempts' keys is that attempt's landing. Only when nothing can be attributed is it
    /// `.ticketExists(key)` (the key when the ticket can be read, else nil). A failed read decides nothing (false: stays checking).
    func applyTicketExists(_ rv: ReviewRec, _ a: AttemptRec, code: String, src: String) async throws -> Bool {
        let key: String?
        do {
            let get = try await ticketGet(rv.log)
            guard get.uid.bytesEqual(rv.log) else { return false }
            let attempts = try await loadAttempts(rv.review)
            if let mine = attempts.first(where: { $0.dispatched && $0.key.map { get.key.bytesEqual($0) } == true }) {
                try await recordLanding(rv, mine, seq: nil, src: "log")
                return true
            }
            key = get.key
        } catch is CancellationError { throw CancellationError() }
        catch ClientError.host(.host(let c, _, _, _)) where c.bytesEqual("not_found") { key = nil }
        catch { return false }
        try await recordDefinite(rv, a, code: code, cls: .d, src: src, outcome: .ticketExists(key: key))
        return true
    }

    /// Step 2 of plan 4 for a creation: a fresh `ticket.get(uid)` shows the ticket with the landed attempt's key (`.landed` /
    /// `.landedAfterResign`), or a successful read shows something else (`landed_unconfirmed`, never downgraded). A failed read leaves the
    /// review `landed` with no outcome yet.
    func confirmCreation(_ rv: ReviewRec, _ a: AttemptRec) async throws -> WriteOutcome {
        let seq = a.landedSeq ?? 1
        let outcome: WriteOutcome
        do {
            let get = try await ticketGet(rv.log)
            if get.uid.bytesEqual(rv.log), let k = a.key, get.key.bytesEqual(k) {
                outcome = a.origin == "auto" ? .landedAfterResign(seq: seq, key: k) : .landed(seq: seq, key: k)
            } else {
                outcome = .landedUnconfirmed(seq: a.landedSeq, reason: .changed)
            }
        } catch is CancellationError { throw CancellationError() }
        catch ClientError.host(.host(let code, _, _, _)) where code.bytesEqual("not_found") {
            outcome = .landedUnconfirmed(seq: a.landedSeq, reason: .unavailable)
        } catch {
            scheduleSettle(rv.review)
            guard let k = a.key else { return .checking }
            return a.origin == "auto" ? .landedAfterResign(seq: seq, key: k) : .landed(seq: seq, key: k)
        }
        let state: String
        if case .landedUnconfirmed = outcome { state = "landed_unconfirmed" } else { state = "landed" }
        let encoded = String(decoding: try canonicalJSON(Self.encodeOutcome(outcome)), as: UTF8.self)
        try await cfg.container.database().execute("UPDATE pe_reviews SET state=?, outcome=? WHERE review=? AND outcome IS NULL",
                                                   [.text(state), .text(encoded), .text(rv.review)])
        emit(.invalidated)
        return outcome
    }

    // MARK: automatic re-sign of a creation (14.4; key races included)

    /// C-auto (`ticket.key_not_next`, `members.stale`): one fresh `workspace.show` gives the advertised `next_key` (strict shape) and
    /// `members_v`; the displayed type, title and owner must be byte-equal to the review, the key keeps the disclosed prefix, and only
    /// `roster_v`, `id` and `key` change (the uid stays). The same eligibility, fence and limit (3, key races included) as an answer.
    func autoResignCreation(_ rv: ReviewRec, _ a: AttemptRec, policy: PersonEventPolicy, ticket: LifecycleFence.Ticket) async throws -> Bool {
        let snap = try StoredCreation(bytes: rv.snapshot)
        let attempts = try await loadAttempts(rv.review)
        let earlierUnresolved = attempts.contains { $0.idem != a.idem && $0.dispatched && ($0.state == "signed" || $0.state == "sent") }
        let show: WorkspaceShowResult
        do { show = try await workspaceShow() } catch is CancellationError { throw CancellationError() } catch { return false }
        guard show.id.bytesEqual(workspace.hex), let key = show.nextKey, validTicketKey(key) else { return false }
        // the disclosure named a key of this workspace's prefix: a key under another prefix is not what the person consented to
        guard keyPrefix(key) == keyPrefix(rv.keyDisclosed ?? snap.key) else { return false }
        guard lifecycleFence.valid(ticket) else { return false }
        let actor = try policy.actor(person: try storedPerson(), device: cfg.deviceID)
        let offset = try await clockOffsetMs()
        let now = cfg.wall.nowMs
        let id = try ULID.make(timeMs: saturatingAddMs(now, offset), random: cfg.entropy.bytes(ULID.randomLength))
        let proposed = try snap.unsigned(uid: rv.log, key: key, rosterV: show.membersV, id: id, actor: actor, workspace: workspace)
        let previousEvent = try restore(a, rv)
        var previous = previousEvent.event; previous["sig"] = nil
        // displayed fields: the review's (as stored) against what the phone shows now (its certificate's person as owner)
        let fresh = CreationDisplay(ticketType: snap.ticketType, title: try PhoneEvents.prepareText(snap.title, oneLine: true), owner: actor.personID)
        let input = AutoResignInput(lastClass: .cAuto, lastAnswerWasRefusedForExactIdem: true, earlierIdemUnresolved: earlierUnresolved,
                                    reviewed: .creation(try snap.display()), fresh: .creation(fresh),
                                    previous: previous, proposed: proposed.event, previousLog: previousEvent.log, proposedLog: proposed.log,
                                    keyAssignedDisclosed: rv.keyDisclosed != nil, foregroundAndUnlockedSinceTap: lifecycleFence.valid(ticket),
                                    autoResignsSoFar: Int(rv.resigns))
        guard AutoResign.decide(input) == .allow else { return false }
        let build = Self.attemptBuild(.resign(review: rv.review, expectIdem: a.idem, expectVer: rv.ver), unsigned: proposed, origin: "auto",
                                      signer: cfg.identity.sig, actor: actor, pub: cfg.identity.publicKeys.sig, workspace: workspace,
                                      clock: WriteClock(wallMs: now, offsetMs: offset, monoMs: 0), fence: lifecycleFence, ticket: ticket,
                                      hook: crashHook)
        _ = try await prepare(logical: cfg.entropy.id16(), plaintext: Data(), write: build)
        return true
    }
}
