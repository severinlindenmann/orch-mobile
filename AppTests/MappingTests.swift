import XCTest
import OrchProtocol
@testable import Orch

final class MappingTests: XCTestCase {
    func testHexIsLowercaseAndFixedWidth() {
        XCTAssertEqual(Mapping.hex(Data([0x00, 0x0a, 0xff])), "000aff")
    }

    func testScopesIgnoreUnknownNames() {
        XCTAssertEqual(Mapping.scopes(["look", "decide", "drop:read", "bogus"]), [.look, .decide])
    }

    func testClosedStateAlwaysYieldsAResolution() {
        let full = Mapping.resolution(state: "closed", decisionID: "d1", optionID: "yes", byLabel: "Demo Mac", atMs: 2_000, createdMs: 1_000)
        XCTAssertEqual(full?.optionID, "yes")
        XCTAssertEqual(full?.byDeviceLabel, "Demo Mac")
        let missingOption = Mapping.resolution(state: "closed", decisionID: "d1", optionID: nil, byLabel: "Demo Mac", atMs: 2_000, createdMs: 1_000)
        XCTAssertNotNil(missingOption, "a closed question is never shown as open")
        XCTAssertEqual(missingOption?.optionID, "")
        let nothing = Mapping.resolution(state: "closed", decisionID: nil, optionID: nil, byLabel: nil, atMs: nil, createdMs: 1_000)
        XCTAssertEqual(nothing?.byDeviceLabel, Mapping.unknownActor)
        XCTAssertNil(Mapping.resolution(state: "open", decisionID: nil, optionID: nil, byLabel: nil, atMs: nil, createdMs: 1_000))
    }

    func testTicketStates() {
        XCTAssertEqual(Mapping.ticketState("done"), .done)
        XCTAssertEqual(Mapping.ticketState("in_progress"), .inProgress)
        XCTAssertEqual(Mapping.ticketState("open"), .open)
        XCTAssertEqual(Mapping.ticketState("surprise"), .open)
    }

    private let opts = [QuestionOption(id: "yes", label: "Ship it"), QuestionOption(id: "no", label: "Hold")]

    private func q(state: String, optionID: String?, byLabel: String? = "Demo Mac") -> Question {
        Mapping.question(id: "aa", workspaceID: "ws", ticket: "ORC-1", text: "Ship?", options: opts, contentHash: "00ff", createdMs: 1_000,
                         state: state, decisionID: state == "closed" ? "d1" : nil, optionID: optionID, byLabel: byLabel,
                         atMs: state == "closed" ? 2_000 : nil)
    }

    func testQuestionOpenOrClosedFollowsHostState() {
        let open = q(state: "open", optionID: nil)
        XCTAssertTrue(open.isOpen)
        XCTAssertEqual(open.created, Mapping.date(1_000))
        XCTAssertEqual(open.options, opts)
        let closed = q(state: "closed", optionID: "no")
        XCTAssertFalse(closed.isOpen)
        XCTAssertEqual(closed.resolution?.optionID, "no")
        XCTAssertEqual(closed.resolution?.answerLabel(in: closed.options), "Hold")
        XCTAssertEqual(closed.resolution?.at, Mapping.date(2_000))
    }

    func testClosedQuestionWithoutOptionIDStaysClosedWithFallbackLabel() {
        let closed = q(state: "closed", optionID: nil, byLabel: "")
        XCTAssertFalse(closed.isOpen, "a missing option_id never reopens a closed question")
        XCTAssertNil(closed.resolution?.answerLabel(in: closed.options), "the view shows Resolution.unknownAnswer")
        XCTAssertEqual(closed.resolution?.byDeviceLabel, Mapping.unknownActor)
        XCTAssertFalse(Resolution.unknownAnswer.isEmpty)
        XCTAssertNil(Mapping.answerOptionID(nil))
        XCTAssertNil(Mapping.answerOptionID(.object([:])))
        XCTAssertEqual(Mapping.answerOptionID(.object(["option_id": .string("yes")])), "yes")
    }

    func testTicketMapping() {
        let t = Mapping.ticket(key: "ORC-2", workspaceID: "ws", title: "T", body: "B", state: "in_progress", kind: "factory_epic",
                               epicKey: nil, updatedMs: 3_000)
        XCTAssertEqual(t.state, .inProgress)
        XCTAssertEqual(t.kind, .factoryEpic)
        XCTAssertEqual(t.updated, Mapping.date(3_000))
        let odd = Mapping.ticket(key: "ORC-3", workspaceID: "ws", title: "T", body: "B", state: "archived", kind: "other",
                                 epicKey: "ORC-2", updatedMs: 3_000)
        XCTAssertEqual(odd.state, Mapping.unknownTicketState)
        XCTAssertEqual(odd.kind, .ticket)
        XCTAssertEqual(odd.epicKey, "ORC-2")
    }

    func testReviewValueUsesChosenOptionAndFallsBackToItsID() {
        let info = WorkspaceInfo(id: "ws", name: "Laptop", host: "Mac", hue: 1, hostedBy: nil, clientHosted: false, scopes: [.decide],
                                 connection: .online, primaryLabel: "Mac", notificationsOn: true)
        let question = q(state: "open", optionID: nil)
        let v = Mapping.reviewValue(question, info: info, optionID: "yes", revision: 2, isDemo: true)
        XCTAssertEqual(v.optionLabel, "Ship it")
        XCTAssertEqual(v.revision, 2)
        XCTAssertEqual(v.contentHash, "00ff")
        XCTAssertTrue(v.isDemo)
        XCTAssertEqual(Mapping.reviewValue(question, info: info, optionID: "gone", revision: 0, isDemo: false).optionLabel, "gone")
    }

    func testOptionCostTravelsThroughTheMapping() {
        let opt = QuestionOption(id: "fast", label: "Fast", cost: "1 day")
        XCTAssertEqual(opt.cost, "1 day")
        XCTAssertNil(QuestionOption(id: "a", label: "A").cost)
        let info = WorkspaceInfo(id: "ws", name: "Laptop", host: "Mac", hue: 1, hostedBy: nil, clientHosted: false, scopes: [.decide],
                                 connection: .online, primaryLabel: "Mac", notificationsOn: true)
        let question = Mapping.question(id: "q", workspaceID: "ws", ticket: "MOB-0001", text: "T", options: [opt], contentHash: "00", createdMs: 1,
                                        state: "open", decisionID: nil, optionID: nil, byLabel: nil, atMs: nil)
        let v = Mapping.reviewValue(question, info: info, optionID: "fast", revision: 0, isDemo: true)
        XCTAssertEqual(v.options.first { $0.id == "fast" }?.cost, "1 day")
    }

    func testDateIsMilliseconds() {
        XCTAssertEqual(Mapping.date(1_500).timeIntervalSince1970, 1.5, accuracy: 0.0001)
    }

    @MainActor
    func testReleaseStyleOptionsHaveNoLiveSeed() {
        let release = LaunchOptions.parse(arguments: ["orch", "--demo-seed", "--ui-preview"], debug: false)
        XCTAssertFalse(release.demoSeed)
        XCTAssertFalse(release.uiPreview)
        let debug = LaunchOptions.parse(arguments: ["orch", "--demo-seed", "--ui-preview"], debug: true)
        XCTAssertTrue(debug.demoSeed)
        XCTAssertTrue(debug.uiPreview)
    }

    @MainActor
    func testUnknownAliasesResolveToNothingBeforeAnyWorkspace() {
        let services = LiveServices(options: LaunchOptions.parse(arguments: ["orch"], debug: true))
        XCTAssertNil(services.resolveQuestion("q1"))
        XCTAssertNil(services.resolveWorkspace("laptop"))
        XCTAssertTrue(services.workspaces.isEmpty)
        XCTAssertFalse(services.isDemo)
    }

    /// Under the Release configuration (scripts/check-release-flags.sh) the default initialiser must ignore every debug flag.
    func testDefaultInitIgnoresDebugFlagsInRelease() {
        let all = ["orch", "--ui-testing", "--demo", "--demo-seed", "--ui-preview", "--push-harness", "--initial-route", "pair",
                   "--seed-share-quarantine", "--hold-share-import", "--share-demo-targets"]
        let options = LaunchOptions(arguments: all)
        #if DEBUG
        XCTAssertTrue(options.demoSeed && options.uiPreview && options.demo)
        #else
        XCTAssertFalse(options.demoSeed || options.uiPreview || options.demo || options.uiTesting || options.pushHarness)
        XCTAssertNil(options.initialRoute)
        XCTAssertFalse(options.seedShareQuarantine || options.holdShareImport || options.shareDemoTargets)
        #endif
    }
}
