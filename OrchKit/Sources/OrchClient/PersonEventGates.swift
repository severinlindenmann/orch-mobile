import Foundation
import OrchCustody
import OrchProtocol
import OrchStore

// MARK: B10 phase 1: gate decisions on the phone (requirements and plan)

/// What the person chose on the review screen. Never pre-selected from a hint: the phone offers both and the person picks.
public enum GateChoice: Equatable, Sendable {
    case approve
    /// `text`: what the person typed (1 to 4096 UTF-8 bytes after normalisation, section 11.3).
    case changes(text: String)
    var opName: String { if case .approve = self { return "approve" } else { return "changes" } }
}

/// Why a gate review could not be built. Nothing was signed.
public enum GateReviewError: Error, Equatable, Sendable {
    /// Not requirements or plan: not offered on the phone.
    case notOffered
    /// A recomputed hash, a section text, the generation or the identity G names does not match what the host said: "This changed or does
    /// not match. Reopen." There is no way to sign it.
    case doesNotMatch
    /// The host refused `gate.input` (a gate that cannot be hashed right now answers `invalid.input`) or the reads cannot be built from:
    /// "This can't be signed right now." Never a fallback to unverified data.
    case cannotSignNow(code: String)
}

/// One gate, read fresh and RECOMPUTED on the phone, with what the review screen shows. Everything signed comes from `verified`; the
/// ticket key, title, generation label and rule are the host's word and are labelled so. Equality is byte equality plus the token.
public struct GateReviewSnapshot: Sendable, Equatable {
    package let verified: GateReview.Verified
    package let token: UUID
    public let content: GateReview.Content
    /// Per host, not signed.
    public let ticketKey: String
    public let ticketTitle: String
    public let policyWords: String?
    public let realm: Realm
    public let workspaceID: ID16
    public let generation: Int64

    public var gate: String { verified.gate }
    public var gateGen: Int64 { verified.gen }
    public var ticketUID: String { verified.ticketUID }
    /// The exact wording the screen shows next to a host-stated value.
    public static let perHost = "per host, not signed"

    public static func == (a: GateReviewSnapshot, b: GateReviewSnapshot) -> Bool {
        a.token == b.token && a.verified == b.verified && a.ticketKey.bytesEqual(b.ticketKey) && a.ticketTitle.bytesEqual(b.ticketTitle)
            && a.workspaceID == b.workspaceID && a.generation == b.generation && a.realm == b.realm
    }
}

/// `pe_reviews.snapshot` of a gate decision: what was verified and chosen, enough to rebuild (and re-verify) the unsigned event.
struct StoredGate: Sendable {
    let approve: Bool
    let text: String?
    let ticketKey: String
    let verified: GateReview.Verified

    init(_ s: GateReviewSnapshot, choice: GateChoice, text: PhoneEvents.PreparedText?) {
        approve = { if case .approve = choice { return true } else { return false } }()
        self.text = text?.value; ticketKey = s.ticketKey; verified = s.verified
    }

    func bytes() throws -> Data {
        var o: [String: JSONValue] = ["kind": "gate", "decision": .string(approve ? "approve" : "changes"), "ticket_key": .string(ticketKey),
                                      "uid": .string(verified.ticketUID), "gate": .string(verified.gate), "gen": .int(verified.gen),
                                      "hash": .string(verified.hash), "policy_hash": .string(verified.policyHash), "based_on": .string(verified.basedOn),
                                      "roster_v": .int(verified.rosterV), "input": verified.input, "workspace": .string(verified.workspace.hex),
                                      "texts": .object(verified.texts.mapValues(JSONValue.string))]
        if let text { o["text"] = .string(text) }
        return try canonicalJSON(.object(o))
    }

    /// Reads it back and RECOMPUTES it: a stored snapshot that no longer verifies is never signed again.
    init(bytes: Data) throws {
        guard let o = try StrictJSON.parse(bytes).object, o["kind"]?.string == "gate", let d = o["decision"]?.string, ["approve", "changes"].contains(d),
              let key = o["ticket_key"]?.string, let uid = o["uid"]?.string, let gate = o["gate"]?.string, let gen = o["gen"]?.int,
              let hash = o["hash"]?.string, let ph = o["policy_hash"]?.string, let base = o["based_on"]?.string, let roster = o["roster_v"]?.int,
              let input = o["input"], let ws = o["workspace"]?.string.flatMap({ ID16(hex: $0) }), let texts = o["texts"]?.object else { throw ViewError.malformed }
        var t: [String: String] = [:]
        for (k, v) in texts { guard let s = v.string else { throw ViewError.malformed }; t[k] = s }
        do {
            verified = try GateReview.verify(ticketUID: uid, gate: gate, workspace: ws, claimedHash: hash, claimedPolicyHash: ph, gen: gen, input: input,
                                             sectionTexts: t, basedOn: base, rosterV: roster)
        } catch { throw ViewError.malformed }
        approve = d == "approve"; text = o["text"]?.string; ticketKey = key
        guard approve == (text == nil) else { throw ViewError.malformed }
    }

    func unsigned(rosterV: Int64? = nil, id: String, actor: PhoneActor, workspace: ID16) throws -> PhoneEvents.UnsignedPhoneEvent {
        let v = rosterV.map { verified.withRoster($0) } ?? verified
        let prepared = try text.map { try PhoneEvents.prepareText($0, oneLine: false) }
        if let prepared, let text, !prepared.value.bytesEqual(text) { throw WriteGateError.bytesChanged }
        return try PhoneEvents.unsignedGateDecision(v, approve: approve, text: prepared, id: id, actor: actor, workspace: workspace)
    }

    var eventKind: SignedPhoneEvent.Kind { approve ? .gateApproved : .gateChangesRequested }
    var op: String { approve ? "approve" : "changes" }
    /// What the pending-writes list shows for it.
    var summary: StoredGateReview { StoredGateReview(ticketKey: ticketKey, gate: verified.gate, gateGen: verified.gen, approve: approve, text: text) }
}

/// A gate decision still being sent or settled (`pendingWrites`): exactly what was signed.
public struct StoredGateReview: Equatable, Sendable {
    public let ticketKey: String, gate: String
    public let gateGen: Int64
    public let approve: Bool
    public let text: String?
}

extension WorkspaceSession {
    /// The reviews event kind of a stored row: gates read it from the stored event itself (`gate.approved` or `gate.changes_requested`).
    static func eventKind(dbKind: String, event: Data) -> SignedPhoneEvent.Kind {
        switch dbKind {
        case "new_ticket": return .ticketCreated
        case "gate":
            let type = (try? StrictJSON.parse(event))?.object?["type"]?.string
            return type == "gate.changes_requested" ? .gateChangesRequested : .gateApproved
        default: return .questionAnswered
        }
    }

    /// The relay op a stored row is submitted under (`answer`, `new_ticket`, `approve`, `changes`).
    static func opName(dbKind: String, event: Data) -> String {
        dbKind == "gate" ? R2.writeOp(for: eventKind(dbKind: dbKind, event: event)) : dbKind
    }

    // MARK: requests

    /// `phone.requests`: the person's own open hints (unsigned; nothing here is authority). A read failure is thrown; the list is never cached.
    package func openPhoneRequests() async throws -> [PhoneRequest] {
        try await ensureCurrent()
        guard hostWritesAllowed("approve") else { throw ViewError.writesUnavailable }
        return try await phoneRequests().requests
    }

    // MARK: reviewing a gate

    /// Reads `ticket.get` and `gate.input` for `ref` (a key or uid) and `gate`, recomputes every hash on the phone and builds the review.
    /// A mismatch of any kind is `doesNotMatch` and nothing can be signed from it. Only requirements and plan are offered.
    package func reviewGate(ref: String, gate: String) async throws -> GateReviewSnapshot {
        try await ensureCurrent()
        guard GateReview.isPhoneGate(gate) else { throw GateReviewError.notOffered }
        guard hostWritesAllowed("approve"), hostWritesAllowed("changes"), policy != nil else { throw ViewError.writesUnavailable }
        let lifecycle = reviewLifecycle
        let get = try await ticketGet(ref)
        // a ref that is a ticket uid must be the ticket the host answered with (a key is the host's word and is resolved by it)
        if ULID.isValid(ref), !get.uid.bytesEqual(ref) { throw GateReviewError.doesNotMatch }
        let input: GateInputResult
        do { input = try await gateInput(ref: get.uid, gate: gate) }
        catch ClientError.host(let refusal) { throw GateReviewError.cannotSignNow(code: refusal.code) }
        catch ViewError.malformed { throw GateReviewError.cannotSignNow(code: "invalid.input") }
        try await ensureCurrent()
        guard foreground, lifecycle == reviewLifecycle else { throw ViewError.invalidReview }
        guard input.uid.bytesEqual(get.uid), input.gate.bytesEqual(gate) else { throw GateReviewError.doesNotMatch }
        guard let texts = get.sections else { throw GateReviewError.cannotSignNow(code: "invalid.input") }
        // the generation both reads state must agree (a gate that moved between the two reads is a changed gate)
        if let g = get.gates[gate]?.gen, g != input.gen { throw GateReviewError.doesNotMatch }
        let verified: GateReview.Verified
        do {
            verified = try GateReview.verify(ticketUID: get.uid, gate: gate, workspace: workspace, claimedHash: input.hash, claimedPolicyHash: input.policyHash,
                                             gen: input.gen, input: input.input, sectionTexts: texts, basedOn: get.headHash, rosterV: get.membersV)
        } catch { throw GateReviewError.doesNotMatch }
        lifecycleFence.reviewedAgain()
        if gateReviews.count >= 32 { gateReviews.removeAll() }
        var persons: [String: String] = [:]
        for d in get.gates["requirements"]?.decisions ?? [] { persons[d.id] = d.person }
        let snap = GateReviewSnapshot(verified: verified, token: UUID(), content: GateReview.content(of: verified, persons: persons), ticketKey: get.key, ticketTitle: get.title,
                                      policyWords: get.gates[gate]?.policyWords, realm: cfg.context.realm, workspaceID: workspace, generation: generation)
        gateReviews[snap.token] = snap
        return snap
    }

    // MARK: deciding

    /// Signs (Face ID, once per signature) and sends the person's choice on exactly `s`, then settles it like an answer. The review token is
    /// consumed before anything suspends, so a double tap signs once. A text for a request for changes goes through `prepareText` first.
    package func decideGate(_ s: GateReviewSnapshot, choice: GateChoice) async throws -> WriteOutcome {
        try await ensureCurrent()
        guard let policy, hostWritesAllowed(choice.opName) else { throw ViewError.writesUnavailable }
        guard GateReview.isPhoneGate(s.gate) else { throw GateReviewError.notOffered }
        var prepared: PhoneEvents.PreparedText?
        if case .changes(let text) = choice {
            // everything about the text is decided before the review is used up: a refused text leaves the review to try again
            let t = try PhoneEvents.prepareText(text, oneLine: false)
            guard !t.value.isEmpty else { throw PhoneEvents.Failure.emptyText }
            guard t.value.utf8.count <= PhoneEvents.maxAnswerTextBytes else { throw PhoneEvents.Failure.textTooLong }
            prepared = t
        }
        guard s.workspaceID == workspace, s.generation == generation, s.realm == cfg.context.realm, foreground,
              let held = gateReviews[s.token], held == s else { throw ViewError.invalidReview }
        gateReviews[s.token] = nil
        let reviewID = cfg.entropy.id16().hex
        guard let ticket = lifecycleFence.issue(review: reviewID) else { throw lifecycleFence.isLocked ? CustodyError.locked : ViewError.invalidReview }
        do { try await beginGate(s, choice: choice, text: prepared, reviewID: reviewID, policy: policy, ticket: ticket) }
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

    private func beginGate(_ s: GateReviewSnapshot, choice: GateChoice, text: PhoneEvents.PreparedText?, reviewID: String, policy: PersonEventPolicy,
                           ticket: LifecycleFence.Ticket) async throws {
        let actor = try policy.actor(person: try storedPerson(), device: cfg.deviceID)
        let offset = try await clockOffsetMs()
        guard lifecycleFence.valid(ticket) else { throw WriteGateError.lifecycleEnded }
        let now = cfg.wall.nowMs
        let id = try ULID.make(timeMs: saturatingAddMs(now, offset), random: cfg.entropy.bytes(ULID.randomLength))
        let stored = StoredGate(s, choice: choice, text: text)
        let unsigned = try stored.unsigned(id: id, actor: actor, workspace: workspace)
        let build = Self.attemptBuild(.insertGate(review: reviewID, log: s.ticketUID, question: "gate:\(s.ticketUID):\(s.gate)", snapshot: try stored.bytes(), nowMs: now),
                                      unsigned: unsigned, origin: "tap", signer: cfg.identity.sig, actor: actor, pub: cfg.identity.publicKeys.sig,
                                      workspace: workspace, clock: WriteClock(wallMs: now, offsetMs: offset, monoMs: 0), fence: lifecycleFence,
                                      ticket: ticket, hook: crashHook)
        _ = try await prepare(logical: cfg.entropy.id16(), plaintext: Data(), write: build)
    }

    // MARK: settlement

    /// The log rule (plan 4) for a gate decision: this attempt's event id is among the gate's decisions (landed, `src: log`), or a
    /// successful read shows it absent (C-review). A failed read is unresolved.
    func gateLogRead(_ a: AttemptRec, _ rv: ReviewRec, absent code: String) async throws -> Evidence {
        do {
            let snap = try StoredGate(bytes: rv.snapshot)
            let get = try await ticketGet(snap.verified.ticketUID)
            guard get.uid.bytesEqual(snap.verified.ticketUID), let g = get.gates[snap.verified.gate] else { return .unresolved }
            if let d = g.decisions.first(where: { $0.id.bytesEqual(a.idem) }) { return .landed(seq: d.seq, src: "log") }
            return .definite(code: code, cls: .cReview, src: "log")
        } catch is CancellationError { throw CancellationError() }
        catch { return .unresolved }
    }

    /// Step 2 of plan 4 for a gate decision: a fresh `ticket.get` lists the landed attempt among the gate's decisions (`.landed` /
    /// `.landedAfterResign`), or a successful read shows something else (`landed_unconfirmed`, never downgraded).
    func confirmGate(_ rv: ReviewRec, _ a: AttemptRec) async throws -> WriteOutcome {
        let snap = try StoredGate(bytes: rv.snapshot)
        let key = snap.ticketKey
        let seq = a.landedSeq
        let outcome: WriteOutcome
        do {
            let get = try await ticketGet(snap.verified.ticketUID)
            let d = get.uid.bytesEqual(snap.verified.ticketUID) ? get.gates[snap.verified.gate]?.decisions.first(where: { $0.id.bytesEqual(a.idem) }) : nil
            if let d { outcome = a.origin == "auto" ? .landedAfterResign(seq: seq ?? d.seq, key: key) : .landed(seq: seq ?? d.seq, key: key) }
            else { outcome = .landedUnconfirmed(seq: seq, reason: .changed) }
        } catch is CancellationError { throw CancellationError() }
        catch ClientError.host(.host(let code, _, _, _)) where code.bytesEqual("not_found") {
            outcome = .landedUnconfirmed(seq: seq, reason: .unavailable)
        } catch {
            scheduleSettle(rv.review)
            guard let seq else { return .checking }
            return a.origin == "auto" ? .landedAfterResign(seq: seq, key: key) : .landed(seq: seq, key: key)
        }
        let state: String
        if case .landedUnconfirmed = outcome { state = "landed_unconfirmed" } else { state = "landed" }
        let encoded = String(decoding: try canonicalJSON(Self.encodeOutcome(outcome)), as: UTF8.self)
        try await cfg.container.database().execute("UPDATE pe_reviews SET state=?, outcome=? WHERE review=? AND outcome IS NULL",
                                                   [.text(state), .text(encoded), .text(rv.review)])
        emit(.invalidated)
        return outcome
    }

    /// C-auto (`members.stale`): the same decision on the same gate, signed again with the new roster, only when a fresh read RECOMPUTES to
    /// exactly the verified gate the person saw (same hash, generation and policy) and only the roster, id and signature change.
    func autoResignGate(_ rv: ReviewRec, _ a: AttemptRec, policy: PersonEventPolicy, ticket: LifecycleFence.Ticket) async throws -> Bool {
        let snap = try StoredGate(bytes: rv.snapshot)
        let attempts = try await loadAttempts(rv.review)
        let earlierUnresolved = attempts.contains { $0.idem != a.idem && $0.dispatched && ($0.state == "signed" || $0.state == "sent") }
        let freshRoster: Int64
        let freshGate: GateReview.Verified
        do {
            let get = try await ticketGet(snap.verified.ticketUID)
            let input = try await gateInput(ref: get.uid, gate: snap.verified.gate)
            guard let texts = get.sections, get.gates[snap.verified.gate]?.gen == input.gen else { return false }
            freshGate = try GateReview.verify(ticketUID: get.uid, gate: snap.verified.gate, workspace: workspace, claimedHash: input.hash,
                                              claimedPolicyHash: input.policyHash, gen: input.gen, input: input.input, sectionTexts: texts,
                                              basedOn: get.headHash, rosterV: get.membersV)
            freshRoster = get.membersV
        } catch is CancellationError { throw CancellationError() } catch { return false }
        // what the person approved is what the host has now (the hash binds the content; the generation and policy are compared too)
        guard freshGate.hash.bytesEqual(snap.verified.hash), freshGate.gen == snap.verified.gen, freshGate.policyHash.bytesEqual(snap.verified.policyHash),
              lifecycleFence.valid(ticket) else { return false }
        let actor = try policy.actor(person: try storedPerson(), device: cfg.deviceID)
        let offset = try await clockOffsetMs()
        let now = cfg.wall.nowMs
        let id = try ULID.make(timeMs: saturatingAddMs(now, offset), random: cfg.entropy.bytes(ULID.randomLength))
        let proposed = try snap.unsigned(rosterV: freshRoster, id: id, actor: actor, workspace: workspace)
        let previousEvent = try restore(a, rv)
        var previous = previousEvent.event; previous["sig"] = nil
        let shown = GateDisplay(gate: snap.verified.gate, gen: snap.verified.gen, hash: snap.verified.hash, policyHash: snap.verified.policyHash,
                                approve: snap.approve, text: snap.text)
        let freshShown = GateDisplay(gate: freshGate.gate, gen: freshGate.gen, hash: freshGate.hash, policyHash: freshGate.policyHash,
                                     approve: snap.approve, text: snap.text)
        let input = AutoResignInput(lastClass: .cAuto, lastAnswerWasRefusedForExactIdem: true, earlierIdemUnresolved: earlierUnresolved,
                                    reviewed: .gate(shown), fresh: .gate(freshShown), previous: previous, proposed: proposed.event, previousLog: previousEvent.log,
                                    proposedLog: proposed.log, keyAssignedDisclosed: false, foregroundAndUnlockedSinceTap: lifecycleFence.valid(ticket),
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
