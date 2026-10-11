import Foundation
import Observation

// View-model protocols for the screens. They sit next to host-api-v0 §1 names
// (snapshot, review, decide, pendingDecisions, events) so real wiring replaces only the implementations.

@MainActor
protocol HomeModel: AnyObject, Observable {
    var isDemo: Bool { get }
    var workspaces: [WorkspaceInfo] { get }
    /// Cross-workspace, grouped by workspace, oldest question first within and across groups (U3).
    var needsYou: [NeedsYouGroup] { get }
    var needsYouCount: Int { get }
    var oldestWaiting: (question: Question, workspace: WorkspaceInfo)? { get }
    func waitingCount(in workspaceID: String) -> Int
    var lastChecked: Date { get }
    /// U8: submissions persisted before send and not yet resolved.
    var pendingDecisions: [DecisionStatus] { get }
    var dropSummary: DropSummary { get }
    func enterDemo()
}

@MainActor
protocol WorkspaceModel: AnyObject, Observable {
    var info: WorkspaceInfo { get }
    var waiting: [Question] { get }
    var answered: [Question] { get }
    var tickets: [Ticket] { get }
    func ticket(key: String) -> Ticket?
    func epicProgress(for epicKey: String) -> EpicProgress
    func children(of epicKey: String) -> [Ticket]
    func question(id: String) -> Question?
    /// Only a workspace this iPhone may operate can take new tickets.
    var canCreateTickets: Bool { get }
    /// One `creationID` per exact draft (persisted with it until a verified result): a retry of the same fields creates once.
    func createTicket(title: String, body: String) async -> TicketCreation
}

enum TicketCreation: Hashable, Sendable {
    case created(key: String)
    case failed(String)
}

extension WorkspaceModel {
    var canCreateTickets: Bool { false }
    func createTicket(title: String, body: String) async -> TicketCreation { .failed("Not available here.") }
}

@MainActor
protocol QuestionReviewModel: AnyObject, Observable {
    var load: ReviewLoad { get }
    /// Display projection; nil until `loadReview()` has succeeded. The issued review stays behind it.
    var review: ReviewValue? { get }
    var phase: SignPhase { get }
    /// Authoritative re-read of the question (never cached push text).
    func loadReview() async
    /// Signs and sends. Only reachable from the sign sheet after arming.
    func sign() async
    /// After `question_changed`: re-read and issue a fresh immutable review.
    func reread() async
    /// After a lost response: reconcile first, never re-sign a changed answer.
    func checkWhetherReceived() async
    /// Terminal: lock/background/content change. A fresh model (fresh review) is required afterwards.
    func invalidate()
    /// Issues a fresh review (new revision): the old one and its arming are never reused.
    func retryAfterUnlock()
}

@MainActor
protocol PairingFlowModel: AnyObject, Observable {
    var state: PairingState { get }
    var isDemo: Bool { get }
    var hostLabel: String { get }
    /// What the host's own screen shows (Demo host panel only).
    var demoHostCode: String { get }
    var demoPrimaryCertCode: String { get }
    var demoPrimaryHasChallenge: Bool { get }
    /// The pairing link the Demo host's Remote tab shows (empty until the Demo host makes one).
    var demoOfferLink: String { get }
    func submitLink(_ text: String)
    func useDemoInvitation()
    /// Demo host panel: a new single-use pairing link, to paste on the entry screen.
    func demoNewLink()
    func cancel()
    /// The screen went away: an unfinished pairing is cancelled; after a join nothing reaches the coordinator or the joined workspace.
    func screenClosed()
    func hostApprove()
    func hostReject()
    func primaryOpenRequest()
    func primaryApprove()
    func primaryReject()
    /// Both clocks are model transitions: expiry clears codes and disables approval everywhere.
    func primaryTimeElapses()
    func codeTimeElapses()
}

@MainActor
protocol DropModel: AnyObject, Observable {
    var dropStatus: String? { get }
    func refreshDrop() async
    func verifyDropRow(_ id: String) async
    var workspaces: [WorkspaceInfo] { get }
    func items(_ direction: DropDirection) -> [DropItem]
    func item(id: String) -> DropItem?
    func send(_ draft: DropDraft)
    func items(workspace: String) -> [DropItem]
    func markRead(id: String)
    /// A quarantined share job goes to a destination the user picked (never automatic).
    func redirectQuarantined(id: String, to workspaceID: String)
}

@MainActor
protocol SettingsModel: AnyObject, Observable {
    var isDemo: Bool { get }
    var deviceLabel: String { get set }
    var custody: String { get }
    var notificationStatus: NotificationStatus { get }
    var workspaces: [WorkspaceInfo] { get }
    var pairingScenario: PairingScenario { get set }
    var signOutcome: SignOutcome { get set }
    func setNotifications(_ on: Bool, workspaceID: String)
    /// Demo: the host seals a push, the PushSimulator turns it into a local notification labelled as simulated. Result text for the UI.
    var demoPushResult: String? { get }
    func demoSendPush(workspaceID: String)
    /// Leave = "Remove from this iPhone": local wipe first, server cleanup reported separately (U9).
    func leave(workspaceID: String, simulateOffline: Bool) async -> LeaveReport
    func resetThisiPhone()
    func exitDemo()
    func resetDemoData()
}

/// Entry point screens receive (A4): never FakeHost or custody.
@MainActor
protocol AppServices: AnyObject {
    var home: any HomeModel { get }
    var drop: any DropModel { get }
    var settings: any SettingsModel { get }
    func workspace(_ id: String) -> any WorkspaceModel
    func review(workspaceID: String, questionID: String, optionID: String) -> any QuestionReviewModel
    func makePairing(start: PairingState?) -> any PairingFlowModel
    func workspaceID(forQuestion id: String) -> String?
    /// Debug routes and Demo aliases ("laptop", "q1") to the real ids; unknown input maps to itself.
    func resolveWorkspace(_ raw: String) -> String?
    func resolveQuestion(_ raw: String) -> (workspaceID: String, questionID: String)?
}

extension PairingFlowModel {
    func screenClosed() {}
}

extension AppServices {
    func resolveWorkspace(_ raw: String) -> String? { raw }
    func resolveQuestion(_ raw: String) -> (workspaceID: String, questionID: String)? {
        workspaceID(forQuestion: raw).map { ($0, raw) }
    }
}

 extension DropModel {
    var dropStatus: String? { nil }
    func refreshDrop() async {}
    func verifyDropRow(_ id: String) async {}
 }
