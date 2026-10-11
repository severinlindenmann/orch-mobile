import Foundation
import OrchUI

// Display value types for the screens. Names follow docs/host-api-v0.md §1–2 so the real
// OrchClient projections can be mapped onto them later without touching the views.

enum Scope: String, Hashable, Sendable { case look, decide, operate, type }

enum ConnectionState: Hashable, Sendable {
    case online
    case offline(since: Date)
    case reconciling
}

enum WorkspaceLifecycle: Hashable, Sendable {
    case live, removing, removalIncomplete, removed
    var message: String? {
        switch self {
        case .live: nil
        case .removing: "Removing from this iPhone…"
        case .removalIncomplete: "Removal incomplete. Retry Leave in workspace settings."
        case .removed: "Removed from this iPhone."
        }
    }
}

struct WorkspaceInfo: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var host: String
    var hue: Int
    /// Non-nil or `clientHosted` shows the hosted marker; it cannot be hidden.
    var hostedBy: String?
    var clientHosted: Bool
    var scopes: Set<Scope>
    var connection: ConnectionState
    var primaryLabel: String
    var lifecycle: WorkspaceLifecycle = .live
    var notificationsOn: Bool
    /// Q10 key alarm (wk_commit conflict or mismatch): blocks answering and sending until the workspace is removed and paired again.
    var keyAlarm: String?

    var isHosted: Bool { clientHosted || hostedBy != nil }
    var displayName: String { SafeText.inline(name, limit: 40) }
    var displayHost: String { SafeText.inline(host, limit: 40) }
    var allowsTerminal: Bool { scopes.contains(.type) }
}

struct QuestionOption: Hashable, Sendable, Identifiable {
    let id: String
    let label: String
}

struct Resolution: Hashable, Sendable {
    let decisionID: String
    let optionID: String
    let byDeviceLabel: String
    let at: Date
}

extension Resolution {
    /// Shown when the host's recorded answer names no option this question has (or none at all).
    static let unknownAnswer = "The recorded answer can't be shown."
    func answerLabel(in options: [QuestionOption]) -> String? { options.first { $0.id == optionID }?.label }
}

struct Question: Identifiable, Hashable, Sendable {
    let id: String
    let workspaceID: String
    let ticket: String
    var text: String
    var options: [QuestionOption]
    var contentHash: String
    var created: Date
    var resolution: Resolution?
    var isOpen: Bool { resolution == nil }
}

enum TicketState: String, Hashable, Sendable { case open, inProgress, done }
enum TicketKind: String, Hashable, Sendable { case ticket, factoryEpic }

struct Ticket: Identifiable, Hashable, Sendable {
    var id: String { key }
    let key: String
    let workspaceID: String
    var title: String
    var body: String
    var state: TicketState
    var kind: TicketKind
    var epicKey: String?
    var updated: Date
}

struct EpicProgress: Hashable, Sendable {
    let done: Int
    let total: Int
}

struct NeedsYouGroup: Identifiable, Hashable, Sendable {
    var id: String { workspace.id }
    let workspace: WorkspaceInfo
    let questions: [Question]
}

// MARK: Drop

enum DropDirection: String, Hashable, Sendable, CaseIterable { case received, sending }
enum DropKind: String, Hashable, Sendable { case file, note, url }

struct DropItem: Identifiable, Hashable, Sendable {
    let id: String
    let workspaceID: String
    var name: String
    var bytes: Int
    var kind: DropKind
    var direction: DropDirection
    var expires: Date
    var versions: Int
    var unread: Bool
    /// Plain-text content for notes and URLs (URLs are text, never fetched).
    var text: String?
    var from: String
    /// Confirmed by service read-back (PreviewWorld uses a simulated transition).
    var simulatedDone = false
    /// Set for a share job whose destination was removed: it is held back, never sent and never redirected on its own.
    var quarantineJob: String? = nil
    var verified = true
    var alias: String?
    var stopped = false
    var mime: String? = nil
    var hasSignedExpiry = true
    var blocked = false
    var presentationID: String { alias ?? id }
}

struct DropSummary: Hashable, Sendable {
    var newCount: Int
    var lastName: String?
}

struct DropAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var bytes: Int
    /// A labelled sample, not a real pick.
    var isSample = false
    var data: Data = Data()
}

struct DropDraft: Sendable {
    var workspaceID: String
    var attachments: [DropAttachment]
    var note: String
    /// Fixed at 7 days in the prototype (U11).
    var expiryDays = 7
}

enum DropLimits {
    static let maxAttachments = 5
    static let maxBytes = 25 * 1024 * 1024
}

// MARK: Sign sheet

/// Display projection of the session-issued review (U7). The issued review (all options, realm,
/// workspace and generation binding, review identity) stays behind `QuestionReviewSession`.
struct ReviewValue: Hashable, Sendable {
    let workspaceID: String
    let workspaceName: String
    let hue: Int
    let clientHosted: Bool
    let hostedBy: String?
    let questionID: String
    let ticket: String
    let text: String
    let optionID: String
    let optionLabel: String
    let options: [QuestionOption]
    let contentHash: String
    /// Bumped each time the question is re-read after `question_changed`.
    let revision: Int
    var isDemo = false
    /// Non-nil: the sheet refuses to sign (look-alike answers, or answers outside the plain-label allowlist). Computed once.
    let optionsRefusal: SafeText.OptionRefusal?
    /// Computed once: the sheet body reads it on every pass and host text can be long.
    let hasUnsafeContent: Bool

    init(workspaceID: String, workspaceName: String, hue: Int, clientHosted: Bool, hostedBy: String?, questionID: String,
         ticket: String, text: String, optionID: String, optionLabel: String, options: [QuestionOption], contentHash: String,
         revision: Int, isDemo: Bool = false) {
        self.workspaceID = workspaceID; self.workspaceName = workspaceName; self.hue = hue; self.clientHosted = clientHosted
        self.hostedBy = hostedBy; self.questionID = questionID; self.ticket = ticket; self.text = text; self.optionID = optionID
        self.optionLabel = optionLabel; self.options = options; self.contentHash = contentHash; self.revision = revision
        self.isDemo = isDemo
        optionsRefusal = SafeText.optionRefusal(options.map(\.label))
        hasUnsafeContent = SafeText.hasUnsafe(text) || options.contains { SafeText.hasUnsafe($0.label, strictLabel: true) }
            || SafeText.hasUnsafe(workspaceName) || hostedBy.map { SafeText.hasUnsafe($0) } == true
    }

    var isHosted: Bool { clientHosted || hostedBy != nil }
}

/// Opaque session-issued review: the only thing `decide` would accept. Views never see it.
struct QuestionReviewSession: Sendable {
    let identity: UUID
    let realm: String
    let workspaceID: String
    let generation: Int
    let question: Question
    let chosenOptionID: String
    let revision: Int
}

enum ReviewLoad: Hashable, Sendable {
    case loading
    case loaded
    case failed(String)
}

/// `needsRetry`: the relay ended delivery (`retry_exhausted`) and the question is still open; only "Send again" sends it.
enum DecisionOutcomeState: String, Hashable, Sendable { case pending, uncertain, needsRetry, resolved }

struct DecisionStatus: Identifiable, Hashable, Sendable {
    var id: String { decisionID }
    let decisionID: String
    let questionID: String
    let workspaceID: String
    let optionID: String
    let optionLabel: String
    /// The immutable review this decision was signed from; reopening shows exactly this.
    let review: ReviewValue
    var outcome: DecisionOutcomeState
}

enum SignPhase: Hashable, Sendable {
    case ready
    case rereading
    /// Lock, background or content change: a fresh review is required.
    case invalidated
    case sending
    case accepted
    case alreadyAnswered(by: String, at: Date)
    case questionChanged
    case checking
    /// Delivery ended without an answer (relay `retry_exhausted`) and the question is still open. Nothing is sent again unless the
    /// person taps "Send again", which resends the SAME signed answer.
    case needsRetry
    /// The host signed that it recorded the answer and did not apply it (`not_visible`): definite, never sent again.
    case notApplied
    case unlockToContinue
    case custodyUnavailable
    /// The send failed before anything was signed or stored.
    case notSent
}

/// What the fake host does with the next answer (Demo controls and tests).
enum SignOutcome: String, CaseIterable, Hashable, Sendable {
    case accepted, alreadyAnswered, questionChanged, uncertain, notDelivered, locked, custodyUnavailable, loadFails

    /// What the Demo can really do to the next answer (the fake host or the lock); `custodyUnavailable` stays preview-only.
    static var liveCases: [SignOutcome] {
        #if targetEnvironment(simulator)
        [.accepted, .alreadyAnswered, .questionChanged, .uncertain, .locked, .loadFails]
        #else
        [.accepted, .alreadyAnswered, .questionChanged, .uncertain, .loadFails]
        #endif
    }

    var title: String {
        switch self {
        case .accepted: "Accepted"
        case .alreadyAnswered: "Already answered"
        case .questionChanged: "Question changed"
        case .uncertain: "Response lost (checking)"
        case .notDelivered: "Not delivered (send again)"
        case .locked: "iPhone locked"
        case .custodyUnavailable: "Key unavailable"
        case .loadFails: "Review fails to load"
        }
    }
}

// MARK: Pairing

enum PairingAlarm: Hashable, Sendable {
    case echoWrongKey
    case r1Attack(primaryLabel: String)
    case substitution
}

/// Fixed app text only: the host never supplies refusal wording.
enum PairingRefusal: String, Hashable, Sendable {
    case rejectedOnHost, rejectedOnPrimary, linkUsed, otherPerson, invalidLink, relayNotConnected, timedOut
    case alreadyMember, clockWrong, couldNotVerify, keysUnavailable
}

enum PairingState: Hashable, Sendable {
    case entry
    case connecting
    case comparingHost(sas: String)
    case waitingPrimary(primaryLabel: String, deadline: Date)
    case comparingPrimary(primaryLabel: String, certCode: String, expires: Date)
    case joining
    case ready(workspaceName: String)
    case expired
    case alarm(PairingAlarm)
    case refused(PairingRefusal)
    /// The primary device declined to sign this iPhone (a PK-signed rejection the client verified, never the host's word alone).
    case denied
}

enum PairingScenario: String, CaseIterable, Hashable, Sendable {
    case firstTime, primaryOffline, r1Attack, echoWrongKey, rejectOnHost, linkUsed, existingCert

    var title: String {
        switch self {
        case .firstTime: "First time"
        case .primaryOffline: "Primary offline"
        case .r1Attack: "R1 attack"
        case .echoWrongKey: "Wrong key echoed"
        case .rejectOnHost: "Rejected on host"
        case .linkUsed: "Link already used"
        case .existingCert: "Existing certificate"
        }
    }
}

// MARK: Settings

enum LeaveServerStatus: Hashable, Sendable {
    case done
    case pendingOffline
    case finishOnMac
}

struct LeaveReport: Hashable, Sendable {
    let workspaceName: String
    let server: LeaveServerStatus
    /// The local wipe did not finish: the workspace is still listed and nothing is reported as removed. Leave can be tried again.
    var incomplete = false
}

enum NotificationStatus: String, Hashable, Sendable { case notAsked, allowed, denied }
