import XCTest
import OrchClient
import OrchProtocol
@testable import Orch

/// Q10 key alarm in the App: read at launch, raised by any workspace call that fails on it, shown instead of "try again", and the
/// way out (remove the workspace from this iPhone, then pair again) stays available.
private actor AlarmedWorkspace: WorkspaceAPI {
    var alarm: WorkspaceKeyAlarm?
    init(alarm: WorkspaceKeyAlarm?) { self.alarm = alarm }
    func lift() { alarm = nil }
    var verifiedReceiptMs: Int64? { nil }
    func start() {}
    func setForeground(_ value: Bool) {}
    func refreshViews() {}
    func invalidateReviews() {}
    func reconcile(decisionID: ID16) throws -> DecisionOutcome { throw ViewError.offline }
    func retry(decisionID: ID16) throws -> DecisionOutcome { throw Refusal.wkCommitConflict }
    func snapshot() throws -> WorkspaceSnapshot { throw ViewError.offline }
    func review(questionID: ID16) throws -> QuestionReview { throw Refusal.wkCommitConflict }
    func decide(_ review: QuestionReview, optionID: String) throws -> DecisionOutcome { throw Refusal.wkCommitConflict }
    func pendingDecisions() -> [OrchClient.DecisionStatus] { [] }
    func newTicket(_ draft: NewTicketSubmission) throws -> OrchClient.Ticket { throw SessionError.wkCommitMismatch(2) }
    func events() async -> AsyncStream<WorkspaceEvent> { AsyncStream { $0.finish() } }
    func keyAlarm() -> WorkspaceKeyAlarm? { alarm }
}

@MainActor
final class KeyAlarmTests: XCTestCase {
    private let options = LaunchOptions.parse(arguments: ["--ui-testing"], debug: true)

    private func workspace(_ services: LiveServices, api: AlarmedWorkspace) -> LiveWorkspace {
        let id = SystemEntropy().id16()
        let info = WorkspaceInfo(id: id.hex, name: "Test", host: "Mac", hue: 0, hostedBy: nil, clientHosted: false,
                                 scopes: [.look, .operate, .decide], connection: .online, primaryLabel: "Mac", notificationsOn: true)
        let ws = LiveWorkspace(workspaceID: id, generation: 1, api: api, info: info)
        services.register(ws)
        return ws
    }

    func testTheDurableAlarmIsReadAtLaunchAndBlocksAnswering() async {
        let services = LiveServices(options: options)
        let ws = workspace(services, api: AlarmedWorkspace(alarm: .conflict(epoch: 3)))
        XCTAssertNil(ws.info.keyAlarm)
        XCTAssertNil(ws.info.answerBlock)
        await ws.checkKeyAlarm()
        XCTAssertEqual(ws.info.keyAlarm, LiveWorkspace.keyAlarmMessage)
        XCTAssertEqual(ws.info.answerBlock, LiveWorkspace.keyAlarmMessage)
        XCTAssertTrue(LiveWorkspace.keyAlarmMessage.contains("pair again"))
        XCTAssertTrue(LiveWorkspace.keyAlarmMessage.contains("clears when your Mac issues a new key"))
        XCTAssertFalse(LiveWorkspace.keyAlarmMessage.localizedCaseInsensitiveContains("retry"))
    }

    /// G2b D2: the block is per epoch; once the session holds a verified list at a higher epoch it reports no alarm, and the App clears it.
    func testTheAlarmClearsAfterAHigherEpochList() async {
        let services = LiveServices(options: options)
        let api = AlarmedWorkspace(alarm: .conflict(epoch: 1))
        let ws = workspace(services, api: api)
        await ws.checkKeyAlarm()
        XCTAssertEqual(ws.info.keyAlarm, LiveWorkspace.keyAlarmMessage)
        await api.lift()                                   // what WorkspaceSession.keyAlarm() returns after the epoch-2 list
        await ws.checkKeyAlarm()
        XCTAssertNil(ws.info.keyAlarm)
        XCTAssertNil(ws.info.answerBlock)
    }

    func testNoAlarmLeavesTheWorkspaceAlone() async {
        let services = LiveServices(options: options)
        let ws = workspace(services, api: AlarmedWorkspace(alarm: nil))
        await ws.checkKeyAlarm()
        XCTAssertNil(ws.info.keyAlarm)
        XCTAssertFalse(ws.noteKeyAlarm(ViewError.offline))
        XCTAssertFalse(ws.noteKeyAlarm(SessionError.noKeyForEpoch(1)))       // transient: not the alarm
        XCTAssertNil(ws.info.keyAlarm)
    }

    func testCallErrorsRaiseTheAlarm() async {
        for error in [Refusal.wkCommitConflict as any Error, SessionError.wkCommitMismatch(4)] {
            let services = LiveServices(options: options)
            let ws = workspace(services, api: AlarmedWorkspace(alarm: nil))
            XCTAssertTrue(ws.noteKeyAlarm(error))
            XCTAssertEqual(ws.info.keyAlarm, LiveWorkspace.keyAlarmMessage)
        }
    }

    func testNewTicketShowsTheAlarmNotTryAgain() async throws {
        let services = LiveServices(options: options)
        let ws = workspace(services, api: AlarmedWorkspace(alarm: nil))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        ws.draftURL = dir.appendingPathComponent("draft.json")
        let result = await ws.createTicket(title: "Ticket", body: "Body")
        XCTAssertEqual(result, .failed(LiveWorkspace.keyAlarmMessage))
        XCTAssertEqual(ws.info.keyAlarm, LiveWorkspace.keyAlarmMessage)
    }

    /// The way out: the alarm never takes the workspace out of the settings list or its lifecycle, so "Remove from this iPhone"
    /// (settings.leave, never disabled) stays reachable.
    func testTheAlarmedWorkspaceCanStillBeRemoved() async {
        let services = LiveServices(options: options)
        let ws = workspace(services, api: AlarmedWorkspace(alarm: .conflict(epoch: 1)))
        await ws.checkKeyAlarm()
        XCTAssertEqual(ws.info.lifecycle, .live)
        XCTAssertTrue(ws.usable)
        // the settings screen lists it (and with it the Remove button), alarm included
        XCTAssertEqual(services.workspaces.first { $0.id == ws.info.id }?.keyAlarm, LiveWorkspace.keyAlarmMessage)
    }
}
