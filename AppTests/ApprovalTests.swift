import XCTest
import OrchClient
import OrchProtocol
@testable import Orch

/// B10 phase 1 in the App: the list of requests, the copy of every result (contract (e)), and the rule that a request never signs by itself.
private actor ApprovalStub: WorkspaceAPI {
    var requests: [PhoneRequest] = []
    var reviewError: (any Error)?
    private(set) var reviewed: [String] = []
    func setRequests(_ r: [PhoneRequest]) { requests = r }
    func setReviewError(_ e: (any Error)?) { reviewError = e }
    var verifiedReceiptMs: Int64? { nil }
    func start() {}
    func setForeground(_ value: Bool) {}
    func refreshViews() {}
    func invalidateReviews() {}
    func settle(reviewID: String) throws -> WriteOutcome { .checking }
    func snapshot() throws -> WorkspaceSnapshot { throw ViewError.offline }
    func review(questionID: ID16) throws -> QuestionReview { throw ViewError.offline }
    func answer(_ snapshot: ReviewedSnapshot, option: String) throws -> WriteOutcome { throw ViewError.offline }
    func pendingWrites() -> [WriteStatus] { [] }
    func events() async -> AsyncStream<WorkspaceEvent> { AsyncStream { $0.finish() } }
    func phoneRequests() async throws -> [PhoneRequest] { requests }
    func reviewGate(ref: String, gate: String) async throws -> GateReviewSnapshot {
        reviewed.append(ref)
        throw reviewError ?? ViewError.offline
    }
}

@MainActor
final class ApprovalTests: XCTestCase {
    private let options = LaunchOptions.parse(arguments: ["--ui-testing"], debug: true)
    private let uid = "01J9ZK4Q7M3R8T2V6X0B5N1C9D"

    private func workspace(_ api: ApprovalStub) -> (LiveServices, LiveWorkspace) {
        let services = LiveServices(options: options)
        let id = SystemEntropy().id16()
        let info = WorkspaceInfo(id: id.hex, name: "Test", host: "Mac", hue: 0, hostedBy: nil, clientHosted: false,
                                 scopes: [.look, .operate, .decide], connection: .online, primaryLabel: "Mac", notificationsOn: true)
        let ws = LiveWorkspace(workspaceID: id, generation: 1, api: api, info: info)
        services.register(ws)
        return (services, ws)
    }

    private func request(_ id: String, expiresInMs: Int64, gate: String = "requirements") -> PhoneRequest {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return PhoneRequest(id: id, uid: uid, ref: "MOB-0001", title: "Seeds", gate: gate, gateGen: 2, createdMs: now - 1000, expiresMs: now + expiresInMs)
    }

    func testTheListShowsOpenRequestsAndDropsExpiredOnes() async {
        let api = ApprovalStub()
        await api.setRequests([request("ph_01M4JM4RKG79RG3QTWCP60NNNG", expiresInMs: 60_000), request("ph_01M4JM4RKG79RG3QTWCP60NNNH", expiresInMs: -1)])
        let (services, ws) = workspace(api)
        await ws.refreshApprovals()
        XCTAssertEqual(ws.approvals.map(\.id), ["ph_01M4JM4RKG79RG3QTWCP60NNNG"])
        XCTAssertEqual(services.approvalGroups.map(\.requests.count), [1])
        XCTAssertEqual(ApprovalRequest.origin, "Requested from your Mac (not verified)")
        XCTAssertEqual(ApprovalReviewValue.perHost, "per host, not signed")
    }

    func testAReadThatFailsLeavesNoStaleList() async {
        let api = ApprovalStub()
        await api.setRequests([request("ph_01M4JM4RKG79RG3QTWCP60NNNG", expiresInMs: 60_000)])
        let (services, ws) = workspace(api)
        defer { withExtendedLifetime(services) {} }
        await ws.refreshApprovals()
        XCTAssertEqual(ws.approvals.count, 1)
        await api.setRequests([])
        await ws.refreshApprovals()
        XCTAssertTrue(ws.approvals.isEmpty)
    }

    func testReviewingReadsTheGateByTheTicketUIDNotByTheHintsWords() async {
        let api = ApprovalStub()
        await api.setReviewError(GateReviewError.doesNotMatch)
        await api.setRequests([request("ph_01M4JM4RKG79RG3QTWCP60NNNG", expiresInMs: 60_000, gate: "plan")])
        let (services, ws) = workspace(api)
        defer { withExtendedLifetime(services) {} }
        await ws.refreshApprovals()
        let result = await ws.reviewApproval(ws.approvals[0])
        XCTAssertEqual(result, .failed("This changed or does not match. Reopen."))
        let asked = await api.reviewed
        XCTAssertEqual(asked, [uid])
    }

    func testEveryRefusalHasItsOwnPlainCopyAndNothingSigns() async {
        let cases: [(any Error, String)] = [
            (GateReviewError.doesNotMatch, "This changed or does not match. Reopen."),
            (GateReviewError.cannotSignNow(code: "invalid.input"), "This can't be signed right now. Try again later."),
            (GateReviewError.notOffered, "Only requirements and plan are approved on the phone."),
            (ViewError.writesUnavailable, "This workspace does not allow this on the phone."),
            (ViewError.offline, "The workspace could not be read. Nothing was signed."),
        ]
        for (error, copy) in cases {
            let api = ApprovalStub()
            await api.setReviewError(error)
            await api.setRequests([request("ph_01M4JM4RKG79RG3QTWCP60NNNG", expiresInMs: 60_000)])
            let (services, ws) = workspace(api)
        defer { withExtendedLifetime(services) {} }
            await ws.refreshApprovals()
            let r = await ws.reviewApproval(ws.approvals[0])
            XCTAssertEqual(r, .failed(copy))
        }
    }

    func testADecisionWithoutAHeldReviewSignsNothing() async {
        let (services, ws) = workspace(ApprovalStub())
        defer { withExtendedLifetime(services) {} }
        let value = ApprovalReviewValue(revision: 1, workspaceID: ws.info.id, gate: "requirements", ticketKey: "MOB-0001", ticketTitle: "t", gateGen: 1,
                                        policyWords: nil, content: GateReview.Content(gate: "requirements", sections: [], acceptance: [], tasks: [], rows: [],
                                                                                       fullReview: false, fullReviewReasons: [], rawLines: []))
        let phase = await ws.decide(value, choice: .approve)
        XCTAssertEqual(phase, ApprovalPhase.invalidated)
    }

    func testResultCopyIsTheContractsAndHasNoStrengthWords() {
        XCTAssertEqual(ApprovalPhase.approved.message, "Approved.")
        XCTAssertEqual(ApprovalPhase.changesRequested.message, "Changes requested.")
        XCTAssertEqual(ApprovalPhase.changed.message, "This changed while you looked. Reopen it.")
        XCTAssertEqual(ApprovalPhase.cannotSign.message, "This phone can no longer sign. Pair it again.")
        XCTAssertEqual(ApprovalPhase.notAllowed.message, "This workspace does not allow this on the phone.")
        let all: [ApprovalPhase] = [.approved, .changesRequested, .changed, .cannotSign, .notAllowed, .unlockToContinue, .checking, .invalidated]
        for p in all {
            for word in ["secure", "safe", "verified", "protected", "trusted", "tamper"] {
                XCTAssertFalse(p.message.localizedCaseInsensitiveContains(word), p.message)
            }
        }
    }

    func testANotificationTapOpensTheApprovalsListOnce() {
        let inbox = PushRouteInbox.shared
        _ = inbox.takeApprovals()
        XCTAssertFalse(inbox.takeApprovals())
        inbox.openApprovals()
        XCTAssertTrue(inbox.takeApprovals())
        XCTAssertFalse(inbox.takeApprovals())
    }
}
