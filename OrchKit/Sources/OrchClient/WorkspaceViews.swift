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
public enum WorkspaceEvent: Equatable, Sendable { case snapshot(WorkspaceSnapshot), invalidated, connection(ConnectionState), removed }
public struct QuestionOption: Equatable, Sendable { public let id: String, label: String }
public struct QuestionResolution: Equatable, Sendable {
    public let decisionID: ID16, byDeviceID: ID16
    public let answer: JSONValue
    public let byDeviceLabel: String
    public let atMs: Int64
}
public struct Question: Equatable, Sendable {
    public let questionID: ID16
    public let ticket: String, text: String
    public let options: [QuestionOption]
    public let contentHash: Data
    public let createdMs: Int64
    public let state: String
    public let resolution: QuestionResolution?
    package let wire: JSONValue
    package init(_ value: JSONValue) throws {
        let m = try fields(value, ["question_id", "ticket", "text", "options", "content_hash", "created_ms", "state", "resolution"])
        guard let id = m.idField("question_id"), let ticket = m["ticket"]?.string, validTicketKey(ticket),
              let text = m["text"]?.string, let opts = m["options"]?.array, !opts.isEmpty,
              let hash = m.b64uField("content_hash", length: 32), let created = m["created_ms"]?.int, validViewTime(created),
              let state = m["state"]?.string, ["open", "closed"].contains(state) else { throw ViewError.malformed }
        let options = try opts.map { v -> QuestionOption in
            let o = try fields(v, ["id", "label"])
            guard let id = o["id"]?.string, validOptionID(id), let label = o["label"]?.string else { throw ViewError.malformed }
            return QuestionOption(id: id, label: label)
        }
        guard Set(options.map { Data($0.id.utf8) }).count == options.count,
              Set(options.map { $0.label.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping }).count == options.count,
              try Decisions.questionHash(questionID: id, ticket: ticket, text: text, options: .array(opts)) == hash else { throw ViewError.malformed }
        var resolution: QuestionResolution?
        if m["resolution"] != .null {
            let r = try fields(m["resolution"]!, ["decision_id", "answer", "by_device_id", "by_device_label", "at_ms"])
            guard let d = r.idField("decision_id"), let by = r.idField("by_device_id"), let label = r["by_device_label"]?.string,
                  let at = r["at_ms"]?.int, validViewTime(at), let answer = r["answer"], let a = answer.object,
                  a.exactly(["option_id"]), let option = a["option_id"]?.string,
                  options.contains(where: { $0.id.utf8Equal(option) }) else { throw ViewError.malformed }
            resolution = QuestionResolution(decisionID: d, byDeviceID: by, answer: answer, byDeviceLabel: label, atMs: at)
        }
        guard (state == "closed") == (resolution != nil) else { throw ViewError.malformed }
        questionID = id; self.ticket = ticket; self.text = text; self.options = options; contentHash = hash
        createdMs = created; self.state = state; self.resolution = resolution; wire = value
    }
}
public struct QuestionReview: Equatable, Sendable {
    public let question: Question
    public let realm: Realm
    public let workspaceID: ID16
    public let generation: Int64
    package let token: UUID
    package init(question: Question, realm: Realm, workspaceID: ID16, generation: Int64, token: UUID) {
        self.question = question; self.realm = realm; self.workspaceID = workspaceID; self.generation = generation; self.token = token
    }
}
public struct Ticket: Equatable, Sendable {
    public let key: String, title: String, body: String, state: String, kind: String
    public let epicKey: String?
    public let updatedMs: Int64
    package let wire: JSONValue
    package init(_ v: JSONValue) throws {
        let m = try fields(v, ["key", "title", "body", "state", "kind", "epic_key", "updated_ms"])
        guard let k = m["key"]?.string, validTicketKey(k), let t = m["title"]?.string, let b = m["body"]?.string,
              let s = m["state"]?.string, ["open", "in_progress", "done"].contains(s),
              let kind = m["kind"]?.string, ["ticket", "factory_epic"].contains(kind), let at = m["updated_ms"]?.int, validViewTime(at),
              m["epic_key"] == .null || m["epic_key"]?.string.map(validTicketKey) == true else { throw ViewError.malformed }
        key = k; title = t; body = b; state = s; self.kind = kind; epicKey = m["epic_key"]?.string; updatedMs = at; wire = v
    }
}
public struct WorkspaceMember: Equatable, Sendable { public let deviceID: ID16; public let label: String }
public struct WorkspaceSnapshot: Equatable, Sendable {
    public let workspaceID: ID16
    public let revision: Int64, checkedMs: Int64
    public let questions: [Question], tickets: [Ticket], members: [WorkspaceMember]
    package init(_ v: JSONValue, workspace: ID16) throws {
        let m = try fields(v, ["host_api", "workspace_id", "revision", "checked_ms", "questions", "tickets", "members"])
        guard m["host_api"] == 0, m.idField("workspace_id") == workspace, let rev = m["revision"]?.int, rev >= 1,
              let at = m["checked_ms"]?.int, validViewTime(at), let qs = m["questions"]?.array, let ts = m["tickets"]?.array,
              let ms = m["members"]?.array else { throw ViewError.malformed }
        workspaceID = workspace; revision = rev; checkedMs = at; questions = try qs.map(Question.init); tickets = try ts.map(Ticket.init)
        guard Set(questions.map(\.questionID)).count == questions.count,
              Set(tickets.map(\.key)).count == tickets.count else { throw ViewError.malformed }
        members = try ms.map { v in
            let m = try fields(v, ["device_id", "label"])
            guard let id = m.idField("device_id"), let l = m["label"]?.string else { throw ViewError.malformed }
            return WorkspaceMember(deviceID: id, label: l)
        }
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
