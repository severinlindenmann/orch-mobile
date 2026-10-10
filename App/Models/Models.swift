import Foundation

// Display value types for the screens. Names follow docs/host-api-v0.md §1–2 so the real
// OrchClient projections can be mapped onto them later without touching the views.

enum Scope: String, Hashable, Sendable { case look, decide, operate, type }

enum ConnectionState: Hashable, Sendable {
    case online
    case offline(since: Date)
    case reconciling
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
    var notificationsOn: Bool

    var isHosted: Bool { clientHosted || hostedBy != nil }
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
}

struct DropSummary: Hashable, Sendable {
    var newCount: Int
    var lastName: String?
}

struct DropAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var bytes: Int
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

/// One immutable review value (U7): everything the sheet shows is what gets signed.
struct ReviewValue: Hashable, Sendable {
    let workspaceID: String
    let workspaceName: String
    let hue: Int
    let hostedBy: String?
    let questionID: String
    let ticket: String
    let text: String
    let optionID: String
    let optionLabel: String
    let contentHash: String
    /// Bumped each time the question is re-read after `question_changed`.
    let revision: Int
    var isDemo = false
}

enum SignPhase: Hashable, Sendable {
    case ready
    case sending
    case accepted
    case alreadyAnswered(by: String, at: Date)
    case questionChanged
    case checking
    case unlockToContinue
    case custodyUnavailable
}

/// What the fake host does with the next answer (Demo controls and tests).
enum SignOutcome: String, CaseIterable, Hashable, Sendable {
    case accepted, alreadyAnswered, questionChanged, uncertain, locked, custodyUnavailable
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
}

enum PairingScenario: String, CaseIterable, Hashable, Sendable {
    case firstTime, primaryOffline, r1Attack, echoWrongKey, rejectOnHost, linkUsed, existingCert
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
}

enum NotificationStatus: String, Hashable, Sendable { case notAsked, allowed, denied }
