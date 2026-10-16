import Foundation
import OrchProtocol

// B10 phase 1: "Approve on your phone". The display projections of an approval request (the Mac's unsigned hint) and of one gate the phone has
// RECOMPUTED. The issued review stays behind the model (as for answers and creations); the screens never build or sign an event.

/// An open request from `phone.requests`. Everything here is the host's word (the key, the title and the generation are not proven by
/// anything) and grants no authority. `uid` is only the way to ask the host for the gate; the phone checks that the gate names it.
struct ApprovalRequest: Identifiable, Hashable, Sendable {
    let id: String
    let workspaceID: String
    let uid: String
    /// Per host, not signed.
    let ref: String
    /// Per host, not signed.
    let title: String
    let gate: String
    /// Per host, not signed.
    let gateGen: Int64
    let expires: Date

    static let origin = "Requested from your Mac (not verified)"
    var gateName: String { gate == "plan" ? "plan" : "requirements" }
}

struct ApprovalGroup: Identifiable, Hashable, Sendable {
    var id: String { workspace.id }
    let workspace: WorkspaceInfo
    let requests: [ApprovalRequest]
}

/// One recomputed gate, as the review screen shows it. A new review is a new `revision`.
struct ApprovalReviewValue: Equatable, Sendable {
    let revision: Int
    let workspaceID: String
    let gate: String
    /// Per host, not signed (shown with `perHost`).
    let ticketKey: String
    let ticketTitle: String
    let gateGen: Int64
    let policyWords: String?
    /// Verified: recomputed from the texts and the gate input.
    let content: GateReview.Content
    static let perHost = "per host, not signed"
}

enum ApprovalChoice: Equatable, Sendable {
    case approve
    case changes(text: String)
}

enum ApprovalReviewResult: Equatable, Sendable {
    case reviewed(ApprovalReviewValue)
    case failed(String)
}

/// What a decision ended as (result copy is the contract's, (e)).
enum ApprovalPhase: Equatable, Sendable {
    case approved
    case changesRequested
    /// `gate.stale` and friends: the gate moved while the person looked. Reopen.
    case changed
    /// `device.invalid`: this phone can no longer sign.
    case cannotSign
    /// `op.not_allowed`: the workspace does not allow it on the phone.
    case notAllowed
    case unlockToContinue
    case checking
    case invalidated
    /// The typed text cannot be sent as typed (empty, too long or a character section 11.3 refuses).
    case textProblem(String)
    case notSent(String)

    var message: String {
        switch self {
        case .approved: "Approved."
        case .changesRequested: "Changes requested."
        case .changed: "This changed while you looked. Reopen it."
        case .cannotSign: "This phone can no longer sign. Pair it again."
        case .notAllowed: "This workspace does not allow this on the phone."
        case .unlockToContinue: "Unlock to continue."
        case .checking: "Checking whether it was received."
        case .invalidated: "This is no longer current. Reopen it."
        case .textProblem(let t): t
        case .notSent(let t): t
        }
    }
    var isFinal: Bool {
        switch self { case .approved, .changesRequested: true; default: false }
    }
}
