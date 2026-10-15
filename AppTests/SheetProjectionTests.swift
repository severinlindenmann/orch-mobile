import XCTest
import OrchClient
import OrchFakeHost
import OrchProtocol
@testable import Orch

/// C2b (codex 13/14): the sign sheet renders exactly the snapshot it signs. The rows model is compared with the reviewed options by UTF-8
/// bytes, in order (never Swift's canonical string equality), and SafeText fails closed on any label or cost, selected or not.
@MainActor
final class SheetProjectionTests: XCTestCase {
    private struct Deadline: Error {}

    /// A Demo realm with one question whose options carry costs, one of them canonically equivalent to another spelling.
    private func snapshot(costs: [String?]) async throws -> (LiveServices, LiveWorkspace, ReviewedSnapshot) {
        let services = LiveServices(options: .parse(arguments: ["--ui-testing", "--demo", "--demo-seed"], debug: true))
        await services.boot()
        let ws = try XCTUnwrap(services.live.first { $0.info.scopes.contains(.decide) })
        let host = try XCTUnwrap(services.demo?.entry(for: ws.workspaceID)?.host)
        let options = zip(["now", "later", "never"], costs).map { DemoOptionSeed($0.0, $0.0.capitalized, cost: $0.1) }
        let qid = try await host.demoAskQuestion(DemoQuestionSeed(ticket: "MOB-0001", text: "When?", options: options, createdAgoMs: 1000))
        await ws.api.refreshViews()
        let review = try await ws.api.review(questionID: qid)
        return (services, ws, try XCTUnwrap(review.snapshot))
    }

    func testRowsAreTheSnapshotsOptionsByteForByteInHashOrder() async throws {
        // "e\u{301}" and "\u{E9}" are canonically equivalent: the projection must keep the exact bytes it was given
        let (services, ws, s) = try await snapshot(costs: ["2 days", "caf\u{E9}", nil])
        let value = Mapping.reviewValue(s, info: ws.info, optionID: "later", revision: 0, isDemo: true)
        XCTAssertEqual(value.rows.count, s.options.count)
        for (row, opt) in zip(value.rows, s.options) {
            XCTAssertEqual(Array(row.key.utf8), Array(opt.id.utf8))
            XCTAssertEqual(Array(row.label.utf8), Array(opt.label.utf8))
            XCTAssertEqual(row.cost.map { Array($0.utf8) }, opt.cost.map { Array($0.utf8) })
        }
        XCTAssertEqual(value.rows.map(\.key), ["now", "later", "never"])
        XCTAssertEqual(value.rows.filter(\.selected).map(\.key), ["later"])
        XCTAssertNotEqual(Array("caf\u{E9}".utf8), Array("cafe\u{301}".utf8))
        // the signed details come from the same snapshot
        XCTAssertEqual(value.qid, s.qid)
        XCTAssertEqual(value.hash, s.hash)
        XCTAssertEqual(value.ticketUID, s.ticketUID)
        // a re-read is a new snapshot: same content, another review
        let reread = try await ws.api.review(questionID: s.question.questionID)
        let again = try XCTUnwrap(reread.snapshot)
        XCTAssertTrue(again.sameContent(s))
        XCTAssertNotEqual(again, s)
        services.resetThisiPhone(); await services.waitForReset()
    }

    func testAnUnsafeUnselectedCostRefusesTheWholeSheet() async throws {
        let (services, ws, s) = try await snapshot(costs: ["2 days", nil, "\u{0441}heap"])     // Cyrillic es: a look-alike, on an UNSELECTED option
        let value = Mapping.reviewValue(s, info: ws.info, optionID: "now", revision: 0, isDemo: true)
        XCTAssertNotNil(value.optionsRefusal, "an unsafe cost anywhere disables Sign")
        let clean = try await snapshot(costs: ["2 days", nil, "cheap"])
        XCTAssertNil(Mapping.reviewValue(clean.2, info: clean.1.info, optionID: "now", revision: 0, isDemo: true).optionsRefusal)
        services.resetThisiPhone(); await services.waitForReset()
        clean.0.resetThisiPhone(); await clean.0.waitForReset()
    }

    func testRefusalCoversKeysAndCostsDirectly() {
        func value(_ options: [Orch.QuestionOption]) -> ReviewValue {
            ReviewValue(workspaceID: "w", workspaceName: "W", hue: 0, clientHosted: false, hostedBy: nil, questionID: "q", ticket: "MOB-0001",
                        text: "t", optionID: options[0].id, optionLabel: options[0].label, options: options, contentHash: "h", revision: 0)
        }
        XCTAssertNil(value([Orch.QuestionOption(id: "a", label: "A", cost: "1 h"), Orch.QuestionOption(id: "b", label: "B")]).optionsRefusal)
        XCTAssertNotNil(value([Orch.QuestionOption(id: "a", label: "A"), Orch.QuestionOption(id: "b", label: "B", cost: "1\u{200B}h")]).optionsRefusal)
        XCTAssertNotNil(value([Orch.QuestionOption(id: "a", label: "A"), Orch.QuestionOption(id: "b\u{202E}", label: "B")]).optionsRefusal)
        XCTAssertNotNil(value([Orch.QuestionOption(id: "a", label: "A"), Orch.QuestionOption(id: "b", label: "\u{0410}")]).optionsRefusal)
    }
}
