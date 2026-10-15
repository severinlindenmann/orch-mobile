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
    /// A Live install is on record (running, or failed to start): the Home is Live's, never Welcome.
    var liveInstalled: Bool { get }
    /// Why the Live runtime is not running (nil when it is, or when Live is not in use).
    var liveProblem: String? { get }
    /// Committed workspaces that could not be verified at restore (kept on disk, not shown): "Leave and pair again".
    var skippedWorkspaceCount: Int { get }
    /// A transient Live notice (for example "the owner could not be recorded yet").
    var liveNotice: String? { get }
}

extension HomeModel {
    var liveInstalled: Bool { false }
    var liveProblem: String? { nil }
    var skippedWorkspaceCount: Int { 0 }
    var liveNotice: String? { nil }
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
    /// Open questions this iPhone cannot show or sign (unreadable, failing a check, or free text): they are answered on the Mac.
    var macOnlyCount: Int { get }
    /// The ticket list is cut: more tickets exist on the host than are listed.
    var ticketsIncomplete: Bool { get }
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
    var macOnlyCount: Int { 0 }
    var ticketsIncomplete: Bool { false }
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
    /// After delivery ended (`needsRetry`): the person's explicit "Send again" of the same signed answer.
    func sendAgain() async
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
    /// The app left the foreground: codes are hidden and polling is paused; false again on return (the original deadlines still apply).
    var obscured: Bool { get }
    /// The verified scopes of the joined workspace (Live ready screen).
    var joinedScopes: [String] { get }
}

extension PairingFlowModel {
    var obscured: Bool { false }
    var joinedScopes: [String] { [] }
}

@MainActor
protocol DropModel: AnyObject, Observable {
    var dropStatus: String? { get }
    var dropRefreshRevision: Int { get }
    func canSend(to workspaceID: String) -> Bool
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
    /// Settings -> Demo controls: asks for permission if needed, then schedules a delayed Demo question notification.
    func demoSendNotification() async
    func refreshNotificationStatus() async
    func openNotificationSettings()
    /// Permission, APNs environment and registration outcome as one line (no secrets).
    var pushDiagnostics: String { get }
    /// Locally removed workspaces whose server-side cleanup is still pending (retried when online).
    var pendingServerCleanups: [PendingServerCleanup] { get }
    func retryServerCleanup() async
    /// Leave = "Remove from this iPhone": local wipe first, server cleanup reported separately (U9).
    func leave(workspaceID: String, simulateOffline: Bool) async -> LeaveReport
    func resetThisiPhone()
    func exitDemo()
    func resetDemoData()
    /// What the active realm is, for Settings (no secrets, no tokens). nil without a realm.
    var realmSummary: RealmSummary? { get }
    /// Leave Live: wipes the Live realm from this iPhone, then Welcome (or Demo). The server side is never claimed removed.
    func leaveLive(thenDemo: Bool)
}

extension SettingsModel {
    var realmSummary: RealmSummary? { nil }
    func leaveLive(thenDemo: Bool) {}
}

/// Entry point screens receive (A4): never FakeHost or custody.
@MainActor
protocol AppServices: AnyObject {
    /// What the active realm offers. Screens gate features on these, never on `isDemo`.
    var capabilities: RealmCapabilities { get }
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
    func canSend(to workspaceID: String) -> Bool { workspaces.contains { $0.id == workspaceID && $0.lifecycle == .live && $0.scopes.contains(.operate) } }
    var dropStatus: String? { nil }
    var dropRefreshRevision: Int { 0 }
    func refreshDrop() async {}
    func verifyDropRow(_ id: String) async {}
 }
