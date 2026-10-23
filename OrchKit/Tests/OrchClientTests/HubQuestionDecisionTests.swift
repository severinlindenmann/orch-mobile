import Foundation
import OrchProtocol
import OrchTestVectors
import Testing
@testable import OrchClient

/// The hub path (design #1123 rev 4): the phone hashes the RAW question from the hub content (`text`, `options`, `spec` verbatim) and
/// offers an answer only when it equals the row hash. Frozen core fixtures, form `hub_needs`.
@Suite struct HubQuestionDecisionTests {
    func forms() throws -> [JSONValue] {
        let q = try StrictJSON.parse(OrchTestVectors.Vectors.f1("questions"), maxBytes: .max, maxDepth: 64)
        return q.object?["forms"]?.array ?? []
    }
    func item(_ f: JSONValue, edit: (inout [String: JSONValue]) -> Void = { _ in }) -> (o: [String: JSONValue], content: JSONValue) {
        let row = f.object!["hub_needs"]!.object!["row"]!.object!
        var content = f.object!["hub_needs"]!.object!["content"]!.object!
        edit(&content)
        var o = row
        o["log"] = row["log"]
        return (o, .object(content))
    }
    func decision(_ f: JSONValue, edit: (inout [String: JSONValue]) -> Void = { _ in }) -> HubItemDecision? {
        let (o, c) = item(f, edit: edit)
        return HubViewParse.decision(o, content: c, kind: "question", workspace: ID16(hex: "0123456789abcdef0123456789abcdef"))
    }

    /// The frozen `choice_full` question carries details, why, a recommendation, option text and facts: the buttons show none of them, so
    /// no decision is offered (answered on the Mac) until D-mob-2.
    @Test func aQuestionWithPartsTheButtonsDoNotShowOffersNothing() throws {
        #expect(try decision(forms()[0]) == nil)
    }

    /// A plain choice question (re-hashed here from the fixture: only key/title options) is still offered, and only for the right item id.
    @Test func aPlainVerifiedChoiceQuestionIsOffered() throws {
        let ws = ID16(hex: "0123456789abcdef0123456789abcdef")!, log = "01J9ZK4Q7M3R8T2V6X0B5N1C9D"
        let options: JSONValue = [["key": "yes", "label": "Yes"], ["key": "no", "label": "No"]]
        let content = try F1Question.Content(text: "Ship it?", options: options, spec: ["kind": "choice"])
        let qid = try F1Question.questionID(question: "Q3", ticketUID: log, workspace: ws)
        let hash = try F1Question.questionHash(qid: qid, ticketUID: log, content: content)
        let row: [String: JSONValue] = ["item_id": .string(qid), "log": .string(log), "hash": .string(hash)]
        let c: JSONValue = ["question": "Q3", "text": "Ship it?", "options": options, "spec": ["kind": "choice"]]
        guard let d = HubViewParse.decision(row, content: c, kind: "question", workspace: ws), case .question(_, let opts) = d.kind else { Issue.record("no decision"); return }
        #expect(opts.map(\.key) == ["yes", "no"])
        // another workspace, or an item id that is not this question's id: nothing
        #expect(HubViewParse.decision(row, content: c, kind: "question", workspace: ID16(hex: String(repeating: "1", count: 32))) == nil)
        var other = row; other["item_id"] = .string(String(repeating: "a", count: 32))
        #expect(HubViewParse.decision(other, content: c, kind: "question", workspace: ws) == nil)
        // each part the buttons do not show turns the same question into "nothing offered", even with a matching hash
        for (name, spec, opts) in [("details", ["kind": "choice", "details": "More."] as JSONValue, options),
                                   ("why", ["kind": "choice", "why": "Because."], options),
                                   ("recommended", ["kind": "choice", "recommended": "yes"], options),
                                   ("text", ["kind": "choice"], [["key": "yes", "label": "Yes", "text": "Go."], ["key": "no", "label": "No"]]),
                                   ("facts", ["kind": "choice"], [["key": "yes", "label": "Yes", "facts": [["A", "1"]]], ["key": "no", "label": "No"]])] as [(String, JSONValue, JSONValue)] {
            let cc = try F1Question.Content(text: "Ship it?", options: opts, spec: spec)
            let h = try F1Question.questionHash(qid: qid, ticketUID: log, content: cc)
            var r = row; r["hash"] = .string(h)
            let body: JSONValue = ["question": "Q3", "text": "Ship it?", "options": opts, "spec": spec]
            #expect(HubViewParse.decision(r, content: body, kind: "question", workspace: ws) == nil, "\(name)")
        }
    }

    @Test func aTextQuestionOffersNoAnswerButton() throws {
        #expect(try decision(forms()[1]) == nil)
    }

    @Test func anyChangedBoundFieldOffersNothing() throws {
        let f = try forms()[0]
        func spec(_ e: @escaping (inout [String: JSONValue]) -> Void) -> (inout [String: JSONValue]) -> Void {
            { c in var s = c["spec"]!.object!; e(&s); c["spec"] = .object(s) }
        }
        #expect(decision(f, edit: { $0["text"] = "Another question?" }) == nil)
        #expect(decision(f, edit: spec { $0["why"] = "other" }) == nil)
        #expect(decision(f, edit: spec { $0["recommended"] = "api" }) == nil)
        #expect(decision(f, edit: spec { $0["allow_other"] = nil }) == nil)
        #expect(decision(f, edit: spec { $0["kind"] = "date" }) == nil)
        #expect(decision(f, edit: { $0["spec"] = nil }) == nil)                         // the old option-only shape
        #expect(decision(f, edit: { var o = $0["options"]!.array!; o.reverse(); $0["options"] = .array(o) }) == nil)
        #expect(decision(f, edit: { var o = $0["options"]!.array!; var x = o[0].object!; x["text"] = "changed"; o[0] = .object(x); $0["options"] = .array(o) }) == nil)
    }
}
