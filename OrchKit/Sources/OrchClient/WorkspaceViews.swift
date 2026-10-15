import Foundation
import OrchCustody
import OrchProtocol

public protocol WorkspaceAPI: Sendable {
    func start() async
    func setForeground(_ value: Bool) async
    func refreshViews() async
    func invalidateReviews() async
    /// - Throws: `StoreError.removalStateUnknown` if removal status cannot be verified.
    ///   Retry when coordination is available; this error does not confirm removal.
    func reconcile(decisionID: ID16) async throws -> DecisionOutcome
    /// The person's explicit "Send again" for a `needsRetry` decision (relay `retry_exhausted`). Reads the question first.
    func retry(decisionID: ID16) async throws -> DecisionOutcome
    var verifiedReceiptMs: Int64? { get async }
    /// - Throws: `StoreError.removalStateUnknown` if removal status cannot be verified.
    ///   Retry when coordination is available; this error does not confirm removal.
    func snapshot() async throws -> WorkspaceSnapshot
    /// - Throws: `StoreError.removalStateUnknown` if removal status cannot be verified.
    ///   Retry when coordination is available; this error does not confirm removal.
    func review(questionID: ID16) async throws -> QuestionReview
    /// - Throws: `StoreError.removalStateUnknown` if removal status cannot be verified.
    ///   Retry when coordination is available; this error does not confirm removal.
    func decide(_ review: QuestionReview, optionID: String) async throws -> DecisionOutcome
    /// - Throws: `StoreError.removalStateUnknown` if removal status cannot be verified.
    ///   Retry when coordination is available; this error does not confirm removal.
    func pendingDecisions() async throws -> [DecisionStatus]
    /// - Throws: `StoreError.removalStateUnknown` if removal status cannot be verified.
    ///   Retry when coordination is available; this error does not confirm removal.
    func newTicket(_ draft: NewTicketSubmission) async throws -> Ticket
    func events() async -> AsyncStream<WorkspaceEvent>
    /// The durable key alarm (Q10), read at launch.
    func keyAlarm() async -> WorkspaceKeyAlarm?
}

extension WorkspaceAPI {
    public func keyAlarm() async -> WorkspaceKeyAlarm? { nil }
}
public enum ViewError: Error, Equatable, Sendable { case offline, malformed, invalidReview, invalidOption, invalidDraft, readDeferred, http(Int, String) }
public enum DecisionOutcome: Equatable, Sendable {
    case accepted, alreadyAnswered(label: String, at: Int64), questionChanged(hash: Data), uncertain
    /// The relay ended delivery with 409 `retry_exhausted` (protocol-v2 section 19.6) and the question is still open: nothing is sent
    /// again until the person asks for it (`retry(decisionID:)`). Not "checking": automatic reconciliation only reads.
    case needsRetry
    /// The host signed that it recorded the decision and did NOT apply it (`not_visible`, orch-29 Q2): definite, never re-sent.
    case notApplied
}
public enum DecisionState: Equatable, Sendable { case pending, uncertain, needsRetry }
public struct DecisionStatus: Equatable, Sendable {
    public let decisionID: ID16, questionID: ID16
    public let optionID: String
    public let state: DecisionState
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
public enum WorkspaceEvent: Equatable, Sendable { case snapshot(WorkspaceSnapshot), invalidated, connection(ConnectionState), removed }
public struct QuestionOption: Equatable, Sendable {
    /// The option's `key` (host section 0.8 `Question.options`); what a decision binds.
    public let id: String, label: String
    /// Bound into the question hash, so the phone must show it (11A.14 14.5).
    public let cost: String?
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
    public let options: [QuestionOption]
    public let contentHash: Data
    public let createdMs: Int64
    public let state: String
    public let blocking: Bool
    public let resolution: QuestionResolution?
    package let wire: JSONValue

    /// From the F1 question of a `ticket.get` (verified against the paired workspace id) and the ticket facts it came with. A question
    /// whose `qid` or `hash` the phone cannot reproduce from its own text, options and the ticket uid is refused.
    package init(_ q: F1Question, ticketKey: String, ticketUID: String, workspace: ID16, createdMs: Int64,
                 deviceLabel: (_ device: String?, _ person: String) -> String) throws {
        guard let text = q.text, let hostQid = q.qid, let hostHash = q.hash, q.state != .stale,
              let myQid = try? F1Question.questionID(question: q.id, ticketUID: ticketUID, workspace: workspace),
              let myHash = try? F1Question.questionHash(qid: myQid, ticketUID: ticketUID, text: text, options: q.options),
              myQid.utf8Equal(hostQid), myHash.utf8Equal(hostHash),
              let id = ID16(hex: myQid), let hash = Hex.decode(String(myHash.dropFirst("sha256:".count)), length: 32) else { throw ViewError.malformed }
        var resolution: QuestionResolution?
        if let a = q.answer {
            guard q.state == .answered, let by = q.answeredBy, by.utf8Equal(a.by), let atMs = HostTime.ms(a.at) else { throw ViewError.malformed }
            let answer: JSONValue
            if let o = a.option { answer = ["option_id": .string(o)] } else if let t = a.text { answer = ["text": .string(t)] } else { throw ViewError.malformed }
            if let o = a.option { guard q.options.contains(where: { $0.key.utf8Equal(o) }) else { throw ViewError.malformed } }
            resolution = QuestionResolution(decisionID: a.id, byDeviceID: a.signerDevice, byPerson: a.by, answer: answer,
                                            byDeviceLabel: deviceLabel(a.signerDevice, a.by), atMs: atMs)
        }
        guard (q.state == .answered) == (resolution != nil) else { throw ViewError.malformed }
        questionID = id; ticket = ticketKey; self.ticketUID = ticketUID; number = q.id; self.text = text
        options = q.options.map { QuestionOption(id: $0.key, label: $0.label, cost: $0.cost) }
        contentHash = hash; self.createdMs = createdMs; state = resolution == nil ? "open" : "closed"; blocking = q.blocking; self.resolution = resolution
        wire = Self.encode(id: id, ticket: ticketKey, uid: ticketUID, number: q.id, text: text, options: options, hash: hash, createdMs: createdMs,
                           state: state, blocking: q.blocking, resolution: resolution)
    }

    /// The stored form (a decision keeps the review it signed): `Question(wire:)` reads it back and checks it the same way.
    private static func encode(id: ID16, ticket: String, uid: String, number: String, text: String, options: [QuestionOption], hash: Data, createdMs: Int64,
                               state: String, blocking: Bool, resolution: QuestionResolution?) -> JSONValue {
        var o: [String: JSONValue] = ["question_id": .string(id.hex), "ticket": .string(ticket), "ticket_uid": .string(uid), "number": .string(number),
                                      "text": .string(text), "options": .array(options.map { opt in
                                          var m: [String: JSONValue] = ["id": .string(opt.id), "label": .string(opt.label)]
                                          if let c = opt.cost { m["cost"] = .string(c) }
                                          return .object(m)
                                      }), "content_hash": .string(B64U.encode(hash)), "created_ms": .int(createdMs), "state": .string(state),
                                      "blocking": .bool(blocking), "resolution": .null]
        if let r = resolution {
            o["resolution"] = ["decision_id": .string(r.decisionID), "by_device_id": r.byDeviceID.map(JSONValue.string) ?? .null, "by_person": .string(r.byPerson),
                               "answer": r.answer, "by_device_label": .string(r.byDeviceLabel), "at_ms": .int(r.atMs)]
        }
        return .object(o)
    }

    package init(wire value: JSONValue, workspace: ID16) throws {
        let m = try fields(value, ["question_id", "ticket", "ticket_uid", "number", "text", "options", "content_hash", "created_ms", "state", "blocking", "resolution"])
        guard let id = m.idField("question_id"), let ticket = m["ticket"]?.string, validTicketKey(ticket), let uid = m["ticket_uid"]?.string, ULID.isValid(uid),
              let number = m["number"]?.string, let text = m["text"]?.string, let opts = m["options"]?.array,
              let hash = m.b64uField("content_hash", length: 32), let created = m["created_ms"]?.int, validViewTime(created),
              let state = m["state"]?.string, ["open", "closed"].contains(state), let blocking = m["blocking"]?.bool else { throw ViewError.malformed }
        let options = try opts.map { v -> QuestionOption in
            let o = v.object ?? [:]
            guard Set(o.keys).isSubset(of: ["id", "label", "cost"]), let id = o["id"]?.string, let label = o["label"]?.string else { throw ViewError.malformed }
            return QuestionOption(id: id, label: label, cost: o["cost"]?.string)
        }
        // The stored form is re-checked like a host view: option keys byte-unique and clean, labels distinct (NFC and case), and the F1 hash
        // recomputed from the ticket uid, text and options. A stored review that no longer reproduces is refused.
        let f1 = options.map { F1QuestionOption(key: $0.id, label: $0.label, cost: $0.cost) }
        guard Set(f1.map { Data($0.key.utf8) }).count == f1.count, F1Question.labelsDistinct(f1),
              f1.allSatisfy({ F1Text.isClean($0.key, oneLine: true) && !$0.key.isEmpty }),
              let myQid = try? F1Question.questionID(question: number, ticketUID: uid, workspace: workspace), ID16(hex: myQid) == id,
              let myHash = try? F1Question.questionHash(qid: myQid, ticketUID: uid, text: text, options: f1),
              Hex.decode(String(myHash.dropFirst("sha256:".count)), length: 32) == hash else { throw ViewError.malformed }
        var resolution: QuestionResolution?
        if m["resolution"] != .null {
            let r = try fields(m["resolution"]!, ["decision_id", "by_device_id", "by_person", "answer", "by_device_label", "at_ms"])
            guard let d = r["decision_id"]?.string, let p = r["by_person"]?.string, let answer = r["answer"], let l = r["by_device_label"]?.string,
                  let at = r["at_ms"]?.int, validViewTime(at) else { throw ViewError.malformed }
            resolution = QuestionResolution(decisionID: d, byDeviceID: r["by_device_id"]?.string, byPerson: p, answer: answer, byDeviceLabel: l, atMs: at)
        }
        guard (state == "closed") == (resolution != nil) else { throw ViewError.malformed }
        questionID = id; self.ticket = ticket; ticketUID = uid; self.number = number; self.text = text; self.options = options; contentHash = hash
        createdMs = created; self.state = state; self.blocking = blocking; self.resolution = resolution; wire = value
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
    package init(question: Question, realm: Realm, workspaceID: ID16, generation: Int64, token: UUID, reviewed: F1Question.Reviewed? = nil) {
        self.question = question; self.realm = realm; self.workspaceID = workspaceID; self.generation = generation; self.token = token; self.reviewed = reviewed
    }
}
public struct Ticket: Equatable, Sendable {
    public let key: String, title: String, body: String, state: String, kind: String
    public let epicKey: String?
    public let updatedMs: Int64
    package let wire: JSONValue
    /// The creation reply of the (interim, v0) new-ticket op.
    package init(_ v: JSONValue) throws {
        let m = try fields(v, ["key", "title", "body", "state", "kind", "epic_key", "updated_ms"])
        guard let k = m["key"]?.string, validTicketKey(k), let t = m["title"]?.string, let b = m["body"]?.string,
              let s = m["state"]?.string, ["open", "in_progress", "done"].contains(s),
              let kind = m["kind"]?.string, ["ticket", "factory_epic"].contains(kind), let at = m["updated_ms"]?.int, validViewTime(at),
              m["epic_key"] == .null || m["epic_key"]?.string.map(validTicketKey) == true else { throw ViewError.malformed }
        key = k; title = t; body = b; state = s; self.kind = kind; epicKey = m["epic_key"]?.string; updatedMs = at; wire = v
    }
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
public struct WorkspaceMember: Equatable, Sendable { public let deviceID: ID16; public let label: String }
public struct WorkspaceSnapshot: Equatable, Sendable {
    public let workspaceID: ID16
    public let revision: Int64, checkedMs: Int64
    public let questions: [Question], tickets: [Ticket], members: [WorkspaceMember]
    /// `workspace.show`: the host's name for the workspace and its advisory next ticket key (`nil` when this device may not create one).
    public let name: String, nextKey: String?
    package init(workspace: ID16, revision: Int64, checkedMs: Int64, questions: [Question], tickets: [Ticket], members: [WorkspaceMember],
                 name: String, nextKey: String?) throws {
        guard revision >= 1, validViewTime(checkedMs),
              Set(questions.map(\.questionID)).count == questions.count, Set(tickets.map(\.key)).count == tickets.count else { throw ViewError.malformed }
        workspaceID = workspace; self.revision = revision; self.checkedMs = checkedMs; self.questions = questions; self.tickets = tickets
        self.members = members; self.name = name; self.nextKey = nextKey
    }
}
public struct NewTicketSubmission: Equatable, Sendable {
    public let creationID: ID16
    public let title: String, body: String
    public let epicKey: String?
    public init(creationID: ID16, title: String, body: String, epicKey: String? = nil) {
        self.creationID = creationID; self.title = title; self.body = body; self.epicKey = epicKey
    }
    package var meta: JSONValue { ["op": "new_ticket", "host_api": 0, "creation_id": .string(creationID.hex),
                                  "title": .string(title), "body": .string(body), "epic_key": epicKey.map(JSONValue.string) ?? .null] }
    package func validate() throws {
        guard (1...200).contains(title.unicodeScalars.count), body.unicodeScalars.count <= 20_000,
              !unsafeDraft(title), !unsafeDraft(body), epicKey.map(validTicketKey) ?? true else { throw ViewError.invalidDraft }
    }
}
package func fields(_ v: JSONValue, _ keys: Set<String>) throws -> [String: JSONValue] {
    guard let m = v.object, m.exactly(keys) else { throw ViewError.malformed }; return m
}
package func validTicketKey(_ s: String) -> Bool {
    s.range(of: "^[A-Z][A-Z0-9]*-[1-9][0-9]*$", options: .regularExpression) == s.startIndex..<s.endIndex
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
