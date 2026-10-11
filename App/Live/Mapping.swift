import Foundation
import OrchClient
import OrchProtocol

// Maps library view values (host-api section 2: `state` strings, ID16, millisecond times, content hash bytes) to the App's display
// models. Every text field is passed through unchanged: sanitising happens only in SafeText at render time.

enum Mapping {
    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static let unknownActor = "Unknown device"

    /// Open or closed comes from the host's `state`. A closed question always has a resolution here, even if its answer cannot be read:
    /// it is then shown as answered by whoever the host named (or by an unknown device) without an answer label.
    static func resolution(state: String, decisionID: String?, optionID: String?, byLabel: String?, atMs: Int64?, createdMs: Int64) -> Resolution? {
        guard state == "closed" else { return nil }
        return Resolution(decisionID: decisionID ?? "", optionID: optionID ?? "",
                          byDeviceLabel: (byLabel?.isEmpty == false ? byLabel : nil) ?? unknownActor, at: date(atMs ?? createdMs))
    }

    /// Ticket states the host may send (host-api section 2). The library refuses any other value, so the explicit fallback below is
    /// never reached from a verified snapshot; should it be, the ticket is shown as open rather than hidden or shown as done.
    static func ticketState(_ s: String) -> TicketState {
        switch s {
        case "done": return .done
        case "in_progress": return .inProgress
        case "open": return .open
        default: return unknownTicketState
        }
    }
    static let unknownTicketState: TicketState = .open

    /// The answer the host recorded, as the library hands it over (`{"option_id": ...}`); nil when it cannot be read.
    static func answerOptionID(_ answer: JSONValue?) -> String? { answer?.object?["option_id"]?.string }

    static func question(_ q: OrchClient.Question, workspaceID: String) -> Question {
        let r = q.resolution
        return question(id: q.questionID.hex, workspaceID: workspaceID, ticket: q.ticket, text: q.text,
                        options: q.options.map { QuestionOption(id: $0.id, label: $0.label) }, contentHash: hex(q.contentHash),
                        createdMs: q.createdMs, state: q.state, decisionID: r?.decisionID.hex, optionID: answerOptionID(r?.answer),
                        byLabel: r?.byDeviceLabel, atMs: r?.atMs)
    }

    /// The field-level mapping behind `question(_:workspaceID:)` (the library's values cannot be built outside it, so tests use this).
    static func question(id: String, workspaceID: String, ticket: String, text: String, options: [QuestionOption], contentHash: String,
                         createdMs: Int64, state: String, decisionID: String?, optionID: String?, byLabel: String?, atMs: Int64?) -> Question {
        Question(id: id, workspaceID: workspaceID, ticket: ticket, text: text, options: options, contentHash: contentHash,
                 created: date(createdMs),
                 resolution: resolution(state: state, decisionID: decisionID, optionID: optionID, byLabel: byLabel, atMs: atMs, createdMs: createdMs))
    }

    static func ticket(_ t: OrchClient.Ticket, workspaceID: String) -> Ticket {
        ticket(key: t.key, workspaceID: workspaceID, title: t.title, body: t.body, state: t.state, kind: t.kind, epicKey: t.epicKey,
               updatedMs: t.updatedMs)
    }

    static func ticket(key: String, workspaceID: String, title: String, body: String, state: String, kind: String, epicKey: String?,
                       updatedMs: Int64) -> Ticket {
        Ticket(key: key, workspaceID: workspaceID, title: title, body: body, state: ticketState(state),
               kind: kind == "factory_epic" ? .factoryEpic : .ticket, epicKey: epicKey, updated: date(updatedMs))
    }

    static func scopes(_ names: [String]) -> Set<Scope> {
        Set(names.compactMap { Scope(rawValue: $0) })
    }

    static func reviewValue(_ review: QuestionReview, info: WorkspaceInfo, optionID: String, revision: Int, isDemo: Bool) -> ReviewValue {
        reviewValue(question(review.question, workspaceID: info.id), info: info, optionID: optionID, revision: revision, isDemo: isDemo)
    }

    static func reviewValue(_ q: Question, info: WorkspaceInfo, optionID: String, revision: Int, isDemo: Bool) -> ReviewValue {
        ReviewValue(
            workspaceID: info.id, workspaceName: info.name, hue: info.hue, clientHosted: info.clientHosted, hostedBy: info.hostedBy,
            questionID: q.id, ticket: q.ticket, text: q.text, optionID: optionID,
            optionLabel: q.options.first { $0.id == optionID }?.label ?? optionID,
            options: q.options, contentHash: q.contentHash, revision: revision, isDemo: isDemo)
    }
}
