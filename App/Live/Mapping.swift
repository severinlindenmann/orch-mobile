import Foundation
import OrchClient
import OrchProtocol

// Maps library view values (host-api section 2: `state` strings, ID16, millisecond times, content hash bytes) to the App's display
// models. Every text field is passed through unchanged: sanitising happens only in SafeText at render time.

enum Mapping {
    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func question(_ q: OrchClient.Question, workspaceID: String) -> Question {
        var resolution: Resolution?
        if let r = q.resolution, let option = r.answer.object?["option_id"]?.string {
            resolution = Resolution(decisionID: r.decisionID.hex, optionID: option, byDeviceLabel: r.byDeviceLabel, at: date(r.atMs))
        }
        return Question(id: q.questionID.hex, workspaceID: workspaceID, ticket: q.ticket, text: q.text,
                        options: q.options.map { QuestionOption(id: $0.id, label: $0.label) },
                        contentHash: hex(q.contentHash), created: date(q.createdMs), resolution: resolution)
    }

    static func ticket(_ t: OrchClient.Ticket, workspaceID: String) -> Ticket {
        let state: TicketState = switch t.state { case "done": .done; case "in_progress": .inProgress; default: .open }
        return Ticket(key: t.key, workspaceID: workspaceID, title: t.title, body: t.body, state: state,
                      kind: t.kind == "factory_epic" ? .factoryEpic : .ticket, epicKey: t.epicKey, updated: date(t.updatedMs))
    }

    static func scopes(_ names: [String]) -> Set<Scope> {
        Set(names.compactMap { Scope(rawValue: $0) })
    }

    static func reviewValue(_ review: QuestionReview, info: WorkspaceInfo, optionID: String, revision: Int, isDemo: Bool) -> ReviewValue {
        let q = question(review.question, workspaceID: info.id)
        return ReviewValue(
            workspaceID: info.id, workspaceName: info.name, hue: info.hue, clientHosted: info.clientHosted, hostedBy: info.hostedBy,
            questionID: q.id, ticket: q.ticket, text: q.text, optionID: optionID,
            optionLabel: q.options.first { $0.id == optionID }?.label ?? optionID,
            options: q.options, contentHash: q.contentHash, revision: revision, isDemo: isDemo)
    }
}
