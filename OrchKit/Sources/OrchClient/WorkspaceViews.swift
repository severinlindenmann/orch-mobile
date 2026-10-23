import Foundation
import OrchCustody
import OrchProtocol

public protocol WorkspaceAPI: Sendable {
    func start() async
    func setForeground(_ value: Bool) async
    func refreshViews() async
    func invalidateReviews() async
    /// Settles one answer that is still being checked (joins its driver; reads first, never re-signs on its own).
    func settle(reviewID: String) async throws -> WriteOutcome
    var verifiedReceiptMs: Int64? { get async }
    /// - Throws: `StoreError.removalStateUnknown` if removal status cannot be verified.
    ///   Retry when coordination is available; this error does not confirm removal.
    func snapshot() async throws -> WorkspaceSnapshot
    /// - Throws: `StoreError.removalStateUnknown` if removal status cannot be verified.
    ///   Retry when coordination is available; this error does not confirm removal.
    func review(questionID: ID16) async throws -> QuestionReview
    /// C2b: signs the answer `option` to exactly `snapshot` (an `answer` person event over column R) and settles it. Options only: a
    /// question without options is answered on the Mac (`invalidOption`). `writesUnavailable` when this session may not write.
    func answer(_ snapshot: ReviewedSnapshot, option: String) async throws -> WriteOutcome
    /// - Throws: `StoreError.removalStateUnknown` if removal status cannot be verified.
    ///   Retry when coordination is available; this error does not confirm removal.
    func pendingWrites() async throws -> [WriteStatus]
    /// The stored final outcome of one review (nil while it is still being settled).
    func writeOutcome(reviewID: String) async throws -> WriteOutcome?
    /// Where one review stands in the store, distinguishing "no such row" from "landed, confirming read still missing".
    func reviewStanding(reviewID: String) async throws -> ReviewStanding
    /// Whether this workspace takes answers from this iPhone now (a person-event policy and a host that serves them).
    func writesAvailable() async -> Bool
    /// The same for one write op (`answer`, `new_ticket`).
    func writesAvailable(op: String) async -> Bool
    /// C2b creation: reviews a new ticket (type, title through `prepareText(oneLine: true)`, a fresh `workspace.show` for the advertised
    /// next key, a uid made once). Title violations are thrown as `PhoneEvents.Failure`; `writesUnavailable` when this session may not
    /// create here.
    func reviewCreation(type: String, title: String) async throws -> CreationReview
    /// Signs and sends exactly `review` and settles it. `disclosedKey`: the next key the sheet disclosed when it armed (nil: none; then the
    /// key is never changed by an automatic re-sign).
    func create(_ review: CreationReview, disclosedKey: String?) async throws -> WriteOutcome
    /// B10 phase 1: the person's own open "approve on your phone" requests (`phone.requests`; the host's word, no authority). Nothing signs
    /// from a request: the review below is read and RECOMPUTED on the phone whatever the request said.
    func phoneRequests() async throws -> [PhoneRequest]
    /// Reads the gate (`ticket.get` + `gate.input`), recomputes the section and gate hashes, and builds the review of a requirements or plan
    /// gate. `GateReviewError.doesNotMatch` when anything differs, `cannotSignNow` when the host refuses `gate.input`; nothing can be signed then.
    func reviewGate(ref: String, gate: String) async throws -> GateReviewSnapshot
    /// Signs (one Face ID per signature) and sends `gate.approved` or `gate.changes_requested` for exactly `review`, and settles it like an answer.
    func decideGate(_ review: GateReviewSnapshot, choice: GateChoice) async throws -> WriteOutcome
    /// Lifecycle signals that end the eligibility for an automatic re-sign (scenePhase inactive, protected data going away, custody lock,
    /// background, reviews invalidated). Synchronous and nonisolated: they reach the session's lifecycle fence at once, with no actor hop.
    func noteInactive()
    func noteProtectedDataUnavailable()
    func noteCustodyLocked()
    func noteBackground()
    func noteReviewsInvalidated()
    func events() async -> AsyncStream<WorkspaceEvent>
    /// The durable key alarm (Q10), read at launch.
    func keyAlarm() async -> WorkspaceKeyAlarm?
    #if DEBUG && targetEnvironment(simulator)
    /// The Simulator dev-sandbox lane (host 11A.17), for the `OrchDevSandbox` App only.
    func devSandboxStatus() async -> DevSandboxStatus
    func devSandboxCheck() async -> DevSandboxCheck
    #endif
}

extension WorkspaceAPI {
    #if DEBUG && targetEnvironment(simulator)
    public func devSandboxStatus() async -> DevSandboxStatus { DevSandboxStatus(laneActive: false, sandbox: nil) }
    public func devSandboxCheck() async -> DevSandboxCheck { .unknown }
    #endif
    public func keyAlarm() async -> WorkspaceKeyAlarm? { nil }
    public func writesAvailable() async -> Bool { false }
    public func writesAvailable(op: String) async -> Bool { false }
    public func reviewCreation(type: String, title: String) async throws -> CreationReview { throw ViewError.writesUnavailable }
    public func create(_ review: CreationReview, disclosedKey: String?) async throws -> WriteOutcome { throw ViewError.writesUnavailable }
    public func phoneRequests() async throws -> [PhoneRequest] { [] }
    public func reviewGate(ref: String, gate: String) async throws -> GateReviewSnapshot { throw ViewError.writesUnavailable }
    public func decideGate(_ review: GateReviewSnapshot, choice: GateChoice) async throws -> WriteOutcome { throw ViewError.writesUnavailable }
    public func writeOutcome(reviewID: String) async throws -> WriteOutcome? { nil }
    public func reviewStanding(reviewID: String) async throws -> ReviewStanding { .unsettled }
    public func noteInactive() {}
    public func noteProtectedDataUnavailable() {}
    public func noteCustodyLocked() {}
    public func noteBackground() {}
    public func noteReviewsInvalidated() {}
}
/// Where a stored review stands. Only `gone` and a final non-landing `final` outcome make a creation marker stale.
public enum ReviewStanding: Equatable, Sendable {
    /// No row: nothing is pending.
    case gone
    /// Still being sent or settled (active), or the standing is not known.
    case unsettled
    /// A landing whose confirming read has not succeeded yet (the ticket exists; `landed` or `landed_unconfirmed` with no outcome).
    case landedUnconfirmed
    /// The stored final outcome.
    case final(WriteOutcome)
}
public enum ViewError: Error, Equatable, Sendable { case offline, malformed, invalidReview, invalidOption, invalidDraft, readDeferred, http(Int, String)
    /// Writes from this phone are not offered (Live until C2b): nothing was signed, sealed or sent.
    case writesUnavailable
    /// The Simulator dev-sandbox lane only: the host did not confirm `relay.dev` in a fresh `whoami` (or the read failed). Nothing was signed.
    case hostRefusesSimulator
}
public enum ConnectionState: Equatable, Sendable { case online, offline, reconciling }
/// Q10: a key state that blocks the workspace until the person removes it and pairs again (never "retry later").
public enum WorkspaceKeyAlarm: Equatable, Sendable {
    /// Two WSK-verified member lists committed one epoch to different keys (durable local alarm `wk_commit_conflict`).
    case conflict(epoch: UInt32)
    /// The relay serves only a grant whose key the verified list does not commit (`wkCommitMismatch`).
    case mismatch(epoch: UInt32)

    /// The alarm an error from a workspace call stands for, if any.
    public init?(error: Error) {
        switch error {
        case Refusal.wkCommitConflict: self = .conflict(epoch: 0)
        case SessionError.wkCommitMismatch(let e): self = .mismatch(epoch: e)
        default: return nil
        }
    }
}
public enum WorkspaceEvent: Equatable, Sendable { case snapshot(WorkspaceSnapshot), invalidated, connection(ConnectionState), removed
    /// A sealed reader refusal ended the cached view: the person updates orch or pairs again; nothing cached is current.
    case readerRefused
    /// The host's write signal (`whoami.relay`) was read, or cleared: `writesAvailable()` may answer differently now. No view read follows.
    case writeSupportChanged
}
public struct QuestionOption: Equatable, Sendable {
    /// The option's `key` (host section 0.8 `Question.options`); what a decision binds.
    public let id: String, label: String
    /// Bound into the question hash, so the phone must show them (11A.14 14.5, design #1123 rev 4): the cost, the one-line text under
    /// the title and the `[label, value]` facts.
    public let cost: String?
    public let text: String?
    public let facts: [F1Fact]
    public init(id: String, label: String, cost: String? = nil, text: String? = nil, facts: [F1Fact] = []) {
        self.id = id; self.label = label; self.cost = cost; self.text = text; self.facts = facts
    }
    init(_ o: F1QuestionOption) { self.init(id: o.key, label: o.label, cost: o.cost, text: o.text, facts: o.facts) }
}
public struct QuestionResolution: Equatable, Sendable {
    /// The id of the `question.answered` event that counts (`answer.id`, v1.7), as the host names it.
    public let decisionID: String
    /// `answer.signer.device`: the device that signed the counting answer (H12d-2); nil when the host did not send it.
    public let byDeviceID: String?
    public let byPerson: String
    public let answer: JSONValue
    public let byDeviceLabel: String
    public let atMs: Int64
}
/// A question of one ticket as the phone shows it: the host's F1 values (11A.14 14.5) mapped into the view type the App has always had.
/// `questionID` is the question's `qid` (32 hex, a function of workspace, ticket uid and `Q<n>`), `contentHash` the 32 bytes of its
/// `sha256:` hash. The phone recomputes both before it shows a question (`F1Question.reviewed`'s check), so a host cannot hand it a
/// text under another hash.
public struct Question: Equatable, Sendable {
    public let questionID: ID16
    /// The ticket key (display) and uid (what is bound), and the question's id on the ticket (`Q1`).
    public let ticket: String, ticketUID: String, number: String
    public let text: String
    /// The kind of the closed registry (`choice` or `text`); a text question has no options.
    public let kind: F1QuestionKind
    public let options: [QuestionOption]
    /// Hash-bound content a signing surface shows as it is: `why`, `details`, the recommended option key and whether a text of the
    /// person's own may replace the options (`allow_other`).
    public let why: String?, details: String?, recommended: String?
    public let allowOther: Bool
    public let contentHash: Data
    public let createdMs: Int64
    public let state: String
    public let blocking: Bool
    public let resolution: QuestionResolution?
    package let wire: JSONValue

    /// From the F1 question of a `ticket.get` (verified against the paired workspace id) and the ticket facts it came with. A question
    /// whose `qid` or `hash` the phone cannot reproduce from the verbatim `text`, `options` and `spec` and the ticket uid is refused
    /// (`F1QuestionRefusal` when the hash is the reason).
    package init(_ q: F1Question, ticketKey: String, ticketUID: String, workspace: ID16, createdMs: Int64,
                 deviceLabel: (_ device: String?, _ person: String) -> String) throws {
        guard q.state != .stale else { throw ViewError.malformed }
        let (myQid, myHash) = try q.verified(ticketUID: ticketUID, workspace: workspace)
        guard let id = ID16(hex: myQid), let hash = Hex.decode(String(myHash.dropFirst("sha256:".count)), length: 32) else { throw ViewError.malformed }
        var resolution: QuestionResolution?
        if let a = q.answer {
            guard q.state == .answered, let by = q.answeredBy, by.utf8Equal(a.by), let atMs = HostTime.ms(a.at) else { throw ViewError.malformed }
            let answer: JSONValue
            if let o = a.option { answer = ["option_id": .string(o)] } else if let t = a.text { answer = ["text": .string(t)] } else { throw ViewError.malformed }
            if let o = a.option { guard q.options.contains(where: { $0.key.utf8Equal(o) }) else { throw ViewError.malformed } }
            resolution = QuestionResolution(decisionID: a.id, byDeviceID: a.signerDevice, byPerson: a.by, answer: answer, byDeviceLabel: deviceLabel(a.signerDevice, a.by), atMs: atMs)
        }
        guard (q.state == .answered) == (resolution != nil) else { throw ViewError.malformed }
        questionID = id; ticket = ticketKey; self.ticketUID = ticketUID; number = q.id; text = q.text
        kind = q.kind; options = q.options.map(QuestionOption.init); why = q.why; details = q.details; recommended = q.recommended; allowOther = q.allowOther
        contentHash = hash; self.createdMs = createdMs; state = resolution == nil ? "open" : "closed"; blocking = q.blocking; self.resolution = resolution
        wire = Self.encode(id: id, ticket: ticketKey, uid: ticketUID, number: q.id, content: q.content, hash: hash, createdMs: createdMs,
                           state: state, blocking: q.blocking, resolution: resolution)
    }

    /// The stored form (a decision keeps the review it signed): `Question(wire:)` reads it back and checks it the same way. `options` and
    /// `spec` are stored VERBATIM (what the hash covers); the typed fields above are derived from them on load.
    private static func encode(id: ID16, ticket: String, uid: String, number: String, content: F1Question.Content, hash: Data, createdMs: Int64,
                               state: String, blocking: Bool, resolution: QuestionResolution?) -> JSONValue {
        var o: [String: JSONValue] = ["question_id": .string(id.hex), "ticket": .string(ticket), "ticket_uid": .string(uid), "number": .string(number),
                                      "text": .string(content.text), "options": content.optionsWire, "spec": content.specWire,
                                      "content_hash": .string(B64U.encode(hash)), "created_ms": .int(createdMs), "state": .string(state),
                                      "blocking": .bool(blocking), "resolution": .null]
        if let r = resolution {
            o["resolution"] = ["decision_id": .string(r.decisionID), "by_device_id": r.byDeviceID.map(JSONValue.string) ?? .null, "by_person": .string(r.byPerson),
                               "answer": r.answer, "by_device_label": .string(r.byDeviceLabel), "at_ms": .int(r.atMs)]
        }
        return .object(o)
    }

    package init(wire value: JSONValue, workspace: ID16) throws {
        let m = try fields(value, ["question_id", "ticket", "ticket_uid", "number", "text", "options", "spec", "content_hash", "created_ms", "state", "blocking", "resolution"])
        guard let id = m.idField("question_id"), let ticket = m["ticket"]?.string, validTicketKey(ticket), let uid = m["ticket_uid"]?.string, ULID.isValid(uid),
              let number = m["number"]?.string, let hash = m.b64uField("content_hash", length: 32), let created = m["created_ms"]?.int, validViewTime(created),
              let state = m["state"]?.string, ["open", "closed"].contains(state), let blocking = m["blocking"]?.bool else { throw ViewError.malformed }
        // The stored form is re-checked like a host view: the same parser and limits, and the F1 hash recomputed from the ticket uid and the
        // stored text, options and spec. A stored review that no longer reproduces is refused.
        let optionsValue = m["options"]
        let content = try F1Question.Content(text: m["text"], options: optionsValue?.array?.isEmpty == true ? nil : optionsValue, spec: m["spec"])
        guard let myQid = try? F1Question.questionID(question: number, ticketUID: uid, workspace: workspace), ID16(hex: myQid) == id,
              let myHash = try? F1Question.questionHash(qid: myQid, ticketUID: uid, content: content),
              Hex.decode(String(myHash.dropFirst("sha256:".count)), length: 32) == hash else { throw ViewError.malformed }
        var resolution: QuestionResolution?
        if m["resolution"] != .null {
            let r = try fields(m["resolution"]!, ["decision_id", "by_device_id", "by_person", "answer", "by_device_label", "at_ms"])
            guard let d = r["decision_id"]?.string, let p = r["by_person"]?.string, let answer = r["answer"], let l = r["by_device_label"]?.string,
                  let at = r["at_ms"]?.int, validViewTime(at) else { throw ViewError.malformed }
            resolution = QuestionResolution(decisionID: d, byDeviceID: r["by_device_id"]?.string, byPerson: p, answer: answer, byDeviceLabel: l, atMs: at)
        }
        guard (state == "closed") == (resolution != nil) else { throw ViewError.malformed }
        questionID = id; self.ticket = ticket; ticketUID = uid; self.number = number; text = content.text; kind = content.kind
        options = content.options.map(QuestionOption.init); why = content.why; details = content.details; recommended = content.recommended; allowOther = content.allowOther
        contentHash = hash; createdMs = created; self.state = state; self.blocking = blocking; self.resolution = resolution; wire = value
    }
}
public struct QuestionReview: Equatable, Sendable {
    public let question: Question
    public let realm: Realm
    public let workspaceID: ID16
    public let generation: Int64
    package let token: UUID
    /// The F1 gate (`F1Question.reviewed`) of an OPEN question, with the `doc.head` and `members_v` of the same `ticket.get`: what a person
    /// event signs (C2b). nil for a closed question.
    package let reviewed: F1Question.Reviewed?
    #if DEBUG && targetEnvironment(simulator)
    /// The fresh `whoami` read that opened this review on the dev-sandbox lane (`freshDevGrant`); nil on every other lane.
    package var devGrant: DevSandboxGrant?
    #endif
    package init(question: Question, realm: Realm, workspaceID: ID16, generation: Int64, token: UUID, reviewed: F1Question.Reviewed? = nil) {
        self.question = question; self.realm = realm; self.workspaceID = workspaceID; self.generation = generation; self.token = token; self.reviewed = reviewed
    }
}
public struct Ticket: Equatable, Sendable {
    public let key: String, title: String, body: String, state: String, kind: String
    public let epicKey: String?
    public let updatedMs: Int64
    package let wire: JSONValue
    /// From a `ticket.query` row. The R2 phone reads titles only (no ticket body travels, host 11A.5 J5): `body` is empty. Host statuses
    /// map to the three the App shows: backlog and open are `open`; in progress, waiting and testing are `in_progress`; done and closed are `done`.
    package init(row r: TicketRow) {
        key = r.key; title = r.title; body = ""
        switch r.status {
        case "done", "closed": state = "done"
        case "in_progress", "waiting", "testing": state = "in_progress"
        default: state = "open"
        }
        kind = r.type == "epic" ? "factory_epic" : "ticket"
        epicKey = r.epic ?? r.parent
        updatedMs = r.updatedMs
        wire = ["key": .string(r.key), "uid": .string(r.uid), "title": .string(r.title), "state": .string(state), "kind": .string(kind),
                "epic_key": epicKey.map(JSONValue.string) ?? .null, "updated_ms": .int(r.updatedMs)]
    }
}
/// An open question shown as "cannot verify": the ticket key, the question's id on it and a plain reason. Its text is never shown as content.
public struct CannotVerifyQuestion: Equatable, Sendable {
    public let ticket: String, question: String, reason: String
    public init(ticket: String, question: String, reason: String) { self.ticket = ticket; self.question = question; self.reason = reason }
}
public struct WorkspaceMember: Equatable, Sendable { public let deviceID: ID16; public let label: String }
public struct WorkspaceSnapshot: Equatable, Sendable {
    public let workspaceID: ID16
    public let revision: Int64, checkedMs: Int64
    public let questions: [Question], tickets: [Ticket], members: [WorkspaceMember]
    /// `workspace.show`: the host's name for the workspace and its advisory next ticket key (`nil` when this device may not create one).
    public let name: String, nextKey: String?
    /// Open questions this phone cannot show or sign ("cannot verify": unreadable, an unknown kind or key, a failing limit or hash check, or
    /// a typed question until the phone has its input): each with a plain reason, never answerable. The ticket stays.
    public let cannotVerify: [CannotVerifyQuestion]
    /// "N questions need your Mac".
    public var macOnlyCount: Int { cannotVerify.count }
    /// The ticket list is cut (page cap, or fewer rows than the host's `total`): more tickets exist than are shown.
    public let ticketsIncomplete: Bool
    package init(workspace: ID16, revision: Int64, checkedMs: Int64, questions: [Question], tickets: [Ticket], members: [WorkspaceMember],
                 name: String, nextKey: String?, cannotVerify: [CannotVerifyQuestion] = [], ticketsIncomplete: Bool = false) throws {
        guard revision >= 1, validViewTime(checkedMs),
              Set(questions.map(\.questionID)).count == questions.count, Set(tickets.map(\.key)).count == tickets.count else { throw ViewError.malformed }
        workspaceID = workspace; self.revision = revision; self.checkedMs = checkedMs; self.questions = questions; self.tickets = tickets
        self.members = members; self.name = name; self.nextKey = nextKey
        self.cannotVerify = cannotVerify; self.ticketsIncomplete = ticketsIncomplete
    }
}
package func fields(_ v: JSONValue, _ keys: Set<String>) throws -> [String: JSONValue] {
    guard let m = v.object, m.exactly(keys) else { throw ViewError.malformed }; return m
}
/// THE ticket key shape (host section 0.1 `Key`): `[A-Z][A-Z0-9]{1,9}-[0-9]{4,}`. Every view parser and every stored form uses this one function.
package func validTicketKey(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard let dash = u.firstIndex(of: 0x2D), (2...10).contains(dash), (4...12).contains(u.count - dash - 1), let f = u.first, f >= 0x41, f <= 0x5A else { return false }
    return u[..<dash].allSatisfy { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) } && u[(dash + 1)...].allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
}
/// ONLY for the advisory `next_key` of a `ticket.key_not_next` refusal (never bound, never a reservation): the R2 vector itself carries
/// `DEMO-42`, so the hint is checked loosely and capped in length. Nothing else may use it.
package func advisoryKeyHint(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard u.count <= 64, let dash = u.firstIndex(of: 0x2D), dash >= 1, u.count - dash - 1 >= 1, let f = u.first, f >= 0x41, f <= 0x5A else { return false }
    return u[..<dash].allSatisfy { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) } && u[(dash + 1)...].allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
}
private func unsafeDraft(_ s: String) -> Bool {
    s.unicodeScalars.contains { c in
        if c.value == 10 { return false }
        switch c.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned: return true
        default: return c.properties.isDefaultIgnorableCodePoint
        }
    }
}

/// Value-only UI gate. The UI records scroll completion and supplies elapsed monotonic time;
/// changing selection/review resets arming. No signing or custody is exposed here.
public struct ReviewArming: Sendable {
    public let review: QuestionReview
    public private(set) var optionID: String?
    private var reachedEnd = false
    private var armedAt: Duration?
    public init(review: QuestionReview) { self.review = review }
    public mutating func select(_ option: String, now: Duration) {
        optionID = review.question.options.contains { $0.id.utf8Equal(option) } ? option : nil
        armedAt = reachedEnd && optionID != nil ? now : nil
    }
    public mutating func scrollToEnd(now: Duration) { reachedEnd = true; if optionID != nil { armedAt = now } }
    public func canConfirm(now: Duration) -> Bool { armedAt.map { now - $0 >= .milliseconds(800) } ?? false }
    public mutating func invalidate() { reachedEnd = false; armedAt = nil; optionID = nil }
}

private func validViewTime(_ value: Int64) -> Bool { (0...maxSafeInt).contains(value) }
private func validOptionID(_ value: String) -> Bool {
    (1...64).contains(value.utf8.count) && value.utf8.allSatisfy {
        (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
    }
}
