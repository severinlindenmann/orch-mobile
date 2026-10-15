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
    /// C2b: this workspace takes answers from this iPhone (the session's person-event policy and the host's support). Answering also
    /// needs the realm's `writes` capability.
    var writeSupport: Bool = false

    var isHosted: Bool { clientHosted || hostedBy != nil }
    var displayName: String { SafeText.inline(name, limit: 40) }
    var displayHost: String { SafeText.inline(host, limit: 40) }
    var allowsTerminal: Bool { scopes.contains(.type) }
}

struct QuestionOption: Hashable, Sendable, Identifiable {
    let id: String
    let label: String
    /// Bound into the question hash with the label, so it is shown wherever the label is (host 11A.14 14.5).
    var cost: String? = nil
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
    /// The last list walk did not complete: a cached copy is not shown as current and cannot be opened until a complete walk succeeds.
    var outdated = false
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

/// Display projection of ONE `ReviewedSnapshot` (U7, C2b codex 13/14): the sheet renders, SafeText checks and the session signs the same
/// immutable value. EVERY option is here in hash order (key, label, cost) with the selected key; the unbound context is kept apart from
/// what is signed. Any re-read is a new snapshot and a new `revision`, so arming starts over.
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
    /// All options, in the order the hash binds them.
    let options: [QuestionOption]
    let contentHash: String
    /// Bumped each time the question is re-read after `question_changed`.
    let revision: Int
    var isDemo = false
    /// Unbound context (shown under "Not signed").
    var why: String? = nil
    var recommended: String? = nil
    var to: [String] = []
    var blocking: Bool = false
    /// Signed details: the recomputed `qid`, `hash` and the ticket uid (empty for a projection that did not come from a snapshot).
    var qid: String = ""
    var hash: String = ""
    var ticketUID: String = ""
    /// Non-nil: the sheet refuses to sign (fail closed). SafeText over EVERY label and EVERY cost, selected or not, and every key.
    let optionsRefusal: SafeText.OptionRefusal?
    /// Computed once: the sheet body reads it on every pass and host text can be long.
    let hasUnsafeContent: Bool

    init(workspaceID: String, workspaceName: String, hue: Int, clientHosted: Bool, hostedBy: String?, questionID: String,
         ticket: String, text: String, optionID: String, optionLabel: String, options: [QuestionOption], contentHash: String,
         revision: Int, isDemo: Bool = false, why: String? = nil, recommended: String? = nil, to: [String] = [], blocking: Bool = false,
         qid: String = "", hash: String = "", ticketUID: String = "") {
        self.workspaceID = workspaceID; self.workspaceName = workspaceName; self.hue = hue; self.clientHosted = clientHosted
        self.hostedBy = hostedBy; self.questionID = questionID; self.ticket = ticket; self.text = text; self.optionID = optionID
        self.optionLabel = optionLabel; self.options = options; self.contentHash = contentHash; self.revision = revision
        self.isDemo = isDemo; self.why = why; self.recommended = recommended; self.to = to; self.blocking = blocking
        self.qid = qid; self.hash = hash; self.ticketUID = ticketUID
        optionsRefusal = SafeText.boundRefusal(labels: options.map(\.label), costs: options.map(\.cost), keys: options.map(\.id))
        hasUnsafeContent = SafeText.hasUnsafe(text) || options.contains { SafeText.hasUnsafe($0.label, strictLabel: true) }
            || options.contains { $0.cost.map { SafeText.hasUnsafe($0, strictLabel: true) } == true }
            || SafeText.hasUnsafe(workspaceName) || hostedBy.map { SafeText.hasUnsafe($0) } == true
    }

    var isHosted: Bool { clientHosted || hostedBy != nil }

    /// The rows the sheet renders, one per option, in hash order: exactly the snapshot's strings (SheetProjectionTests).
    var rows: [SignRow] { options.map { SignRow(key: $0.id, label: $0.label, cost: $0.cost, selected: $0.id == optionID) } }
}

/// One option row of the sign sheet.
struct SignRow: Hashable, Sendable {
    let key: String, label: String
    let cost: String?
    let selected: Bool
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

/// A signed answer this iPhone is still sending or settling (C2b `pendingWrites`).
enum PendingWriteState: String, Hashable, Sendable { case sending, checking }

struct PendingWrite: Identifiable, Hashable, Sendable {
    var id: String { reviewID }
    let reviewID: String
    let questionID: String
    let workspaceID: String
    let optionID: String
    let optionLabel: String
    /// The immutable review this answer was signed from; reopening shows exactly this.
    let review: ReviewValue
    var state: PendingWriteState
}

enum SignPhase: Hashable, Sendable {
    case ready
    case rereading
    /// Lock, background or content change: a fresh review is required.
    case invalidated
    case sending
    case accepted
    /// Landed after an automatic re-sign: "The workspace changed; sent again".
    case resentAfterChange
    /// Sent and recorded; the question has since changed or can't be shown.
    case landedUnconfirmed
    case alreadyAnswered(by: String, at: Date)
    case questionChanged
    case checking
    /// Not sent (the window passed, or the workspace changed so it could not be re-signed safely): review again.
    case needsReview
    /// The host refused it for good: nothing was applied and nothing is sent again.
    case refused
    case unlockToContinue
    case custodyUnavailable
    /// The send failed before anything was signed or stored.
    case notSent
}

/// What the fake host does with the next answer (Demo controls and tests).
enum SignOutcome: String, CaseIterable, Hashable, Sendable {
    case accepted, alreadyAnswered, questionChanged, uncertain, workspaceChanged, held, locked, custodyUnavailable, loadFails

    /// What the Demo can really do to the next answer (the fake host or the lock); `custodyUnavailable` stays preview-only.
    static var liveCases: [SignOutcome] {
        #if targetEnvironment(simulator)
        [.accepted, .alreadyAnswered, .questionChanged, .uncertain, .workspaceChanged, .held, .locked, .loadFails]
        #else
        [.accepted, .alreadyAnswered, .questionChanged, .uncertain, .workspaceChanged, .held, .loadFails]
        #endif
    }

    var title: String {
        switch self {
        case .accepted: "Accepted"
        case .alreadyAnswered: "Already answered"
        case .questionChanged: "Question changed"
        case .uncertain: "Response lost (checking)"
        case .workspaceChanged: "Members changed (sent again)"
        case .held: "Host holds it (checking)"
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
    /// An unattributed refusal (protocol-v2 section 8.3, G3b): "The pairing was refused", naming nobody.
    case refused
    case rejectedOnHost, rejectedOnPrimary, linkUsed, otherPerson, invalidLink, relayNotConnected, timedOut
    case alreadyMember, clockWrong, couldNotVerify, keysUnavailable
    /// Fresh keys could not be drawn for this attempt (G3b): another pairing may use the current ones, or that could not be confirmed.
    case keysInUse
    /// Live could not be prepared on this iPhone (the install record or the keychain): nothing was added.
    case liveNotPrepared
    /// The invitation's relay is not the one this iPhone uses, or is not an https relay: refused before any network access.
    case originRefused
}

/// What Settings shows about the active realm. No secrets, tokens or workspace keys.
struct RealmSummary: Equatable, Sendable {
    var name: String
    /// The reviewed relay origin (Live only), read-only.
    var origin: String?
    var custody: String
    var connection: String
    var lastChecked: Date?
    var build: String
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
    /// "Denied by the owner": the owner's PK-signed rejection of exactly this attempt verified (G3b). `owner` is a short tag of the
    /// pinned owner's person id (from the link's pk_pin), never the host-supplied primary label.
    case denied(owner: String)
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
    /// Why the local wipe failed (only with `incomplete`), shown so a genuine failure is diagnosable.
    var failure: String?
}

/// Server-side cleanup of a workspace that is already gone from this iPhone (U9). Holds no key material.
struct PendingServerCleanup: Codable, Hashable, Sendable, Identifiable {
    var id: String { "\(ws)/\(generation)" }
    let ws: String
    let generation: Int64
    let since: Date
}

enum NotificationStatus: String, Hashable, Sendable { case notAsked, allowed, denied }
