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
        return HubViewParse.decision(o, content: c, kind: "question")
    }

    @Test func aVerifiedChoiceQuestionOffersItsOptionsWithTheBoundFields() throws {
        let f = try forms()[0]
        guard let d = decision(f), case .question(_, let opts) = d.kind else { Issue.record("no decision"); return }
        #expect(opts.map(\.key) == ["csv", "api", "other"])
        #expect(opts[0].text == "One file a month, checked by hand" && opts[0].facts.count == 2 && opts[0].cost == "\u{BD} day")
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
