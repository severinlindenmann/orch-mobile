import Foundation
import Observation
import OrchClient
import OrchCustody
import OrchProtocol

/// The sign sheet's model over the real workspace API: `review(questionID:)` issues an immutable `QuestionReview` (kept here, behind the
/// display projection), `decide(review, optionID:)` signs inside the session. Arming stays in the view (800 ms after the full scroll).
/// A new review is the only way back from `question_changed`, lock or background (U7); a persisted submission is only ever reconciled (U8).
@MainActor @Observable
final class LiveReviewModel: QuestionReviewModel {
    private let services: LiveServices
    private let workspace: LiveWorkspace
    private let questionID: String
    private var optionID: String
    @ObservationIgnored private var issued: QuestionReview?
    @ObservationIgnored private var decisionID: ID16?
    /// Bumped by every invalidation and every new review request; completions from an older token are dropped.
    @ObservationIgnored private var token = 0
    private(set) var load: ReviewLoad = .loading
    private(set) var review: ReviewValue?
    private(set) var phase: SignPhase = .ready

    init(services: LiveServices, workspace: LiveWorkspace, questionID: String, optionID: String) {
        self.services = services; self.workspace = workspace; self.questionID = questionID; self.optionID = optionID
        // U8: reopening an unresolved submission shows exactly what was signed, never re-derived, and never offers to sign again.
        if let pending = services.pendingDecisions.first(where: { $0.questionID == questionID && $0.outcome != .resolved }) {
            self.optionID = pending.optionID
            review = pending.review
            decisionID = ID16(hex: pending.decisionID)
            load = .loaded
            phase = pending.outcome == .needsRetry ? .needsRetry : .checking
        }
    }

    private static let readFailure = "The question could not be read from the workspace. Nothing was signed."

    /// Reads the question afresh and keeps the issued review. False when nothing signable was issued.
    private func issue(revision: Int, mine: Int) async -> Bool {
        guard workspace.usable, let qid = ID16(hex: questionID) else { load = .failed(Self.readFailure); return false }
        do {
            let r = try await workspace.api.review(questionID: qid)
            guard workspace.usable, mine == token else { return false }
            guard r.question.options.contains(where: { $0.id == optionID }) else { load = .failed(Self.readFailure); return false }
            issued = r
            review = Mapping.reviewValue(r, info: workspace.info, optionID: optionID, revision: revision, isDemo: services.isDemo)
            load = .loaded
            // A closed question is a successful read: show who answered and what, and never arm.
            if let resolution = r.question.resolution { phase = .alreadyAnswered(by: resolution.byDeviceLabel, at: Mapping.date(resolution.atMs)) }
            return true
        } catch {
            guard workspace.usable, mine == token else { return false }
            load = .failed(workspace.noteKeyAlarm(error) ? LiveWorkspace.keyAlarmMessage : Self.readFailure)
            return false
        }
    }

    func loadReview() async {
        guard issued == nil, phase == .ready else { return }
        token += 1
        let mine = token
        load = .loading
        if services.takeDemoReadFailure() { load = .failed(Self.readFailure); return }
        _ = await issue(revision: 0, mine: mine)
    }

    func sign() async {
        guard workspace.usable, phase == .ready, let issued, let review, review.optionsRefusal == nil else { return }
        phase = .sending
        self.issued = nil              // one review, one signature: it is consumed by this call
        services.recordSubmission(review)
        await services.applyDemoSignControl(workspace: workspace, questionID: questionID, optionID: optionID)
        guard workspace.usable else { phase = .invalidated; return }
        do {
            let outcome = try await workspace.api.decide(issued, optionID: optionID)
            await apply(outcome)
        } catch let e as CustodyError {
            switch e {
            case .locked: phase = .unlockToContinue
            default: phase = .custodyUnavailable
            }
        } catch ViewError.invalidReview {
            phase = .invalidated
        } catch {
            workspace.noteKeyAlarm(error)
            // Post-persist failures leave a stored submission that must be reconciled; pre-persist ones signed nothing.
            if let status = await services.storedDecision(workspace: workspace, questionID: questionID) {
                decisionID = status
                phase = .checking
                services.startReconcile(workspace: workspace, decisionID: status)
            } else if services.deviceLocked {
                // Signing needs the device key: a locked iPhone refuses before anything is signed or stored.
                phase = .unlockToContinue
            } else {
                phase = .notSent
            }
        }
        // While the answer is only being checked the question stays as it was; the settled outcome refreshes it.
        if phase == .checking { await services.refreshPending() } else { await services.decisionSettled(workspace: workspace) }
    }

    private func apply(_ outcome: DecisionOutcome) async {
        switch outcome {
        case .accepted: phase = .accepted
        case .alreadyAnswered(let label, let at): phase = .alreadyAnswered(by: label, at: Mapping.date(at))
        case .questionChanged: phase = .questionChanged
        case .uncertain:
            phase = .checking
            if let id = await services.storedDecision(workspace: workspace, questionID: questionID) {
                decisionID = id
                services.startReconcile(workspace: workspace, decisionID: id)
            }
        case .notApplied: phase = .notApplied
        case .needsRetry:
            phase = .needsRetry
            if decisionID == nil { decisionID = await services.storedDecision(workspace: workspace, questionID: questionID) }
        }
    }

    /// The explicit "Send again" after delivery ended: the session reads the question first and resends the same signed decision
    /// only while it is still open. Never a new signature.
    func sendAgain() async {
        guard workspace.usable, phase == .needsRetry else { return }
        let id: ID16?
        if let decisionID { id = decisionID } else { id = await services.storedDecision(workspace: workspace, questionID: questionID) }
        guard let id else { return }
        decisionID = id
        phase = .sending
        do {
            await apply(try await workspace.api.retry(decisionID: id))
        } catch {
            phase = .needsRetry          // still stored and exhausted: nothing was lost, the person may try again
        }
        if phase == .checking { await services.refreshPending() } else { await services.decisionSettled(workspace: workspace) }
    }

    func reread() async {
        guard phase == .questionChanged else { return }
        token += 1
        let mine = token
        phase = .rereading
        let ok = await issue(revision: (review?.revision ?? 0) + 1, mine: mine)
        guard mine == token, phase == .rereading else { return }   // invalidated meanwhile: stay invalidated
        phase = ok ? .ready : .invalidated
    }

    /// Reconciles the stored decision. It never calls `decide` again and never builds a review.
    func checkWhetherReceived() async {
        guard workspace.usable, phase == .checking else { return }
        let id: ID16?
        if let decisionID { id = decisionID } else { id = await services.storedDecision(workspace: workspace, questionID: questionID) }
        guard let id else { return }
        decisionID = id
        if let outcome = try? await workspace.api.reconcile(decisionID: id), outcome != .uncertain {
            await apply(outcome)
            await services.decisionSettled(workspace: workspace)
        }
    }

    /// Lock/background/content change. Only unsent or unconfirmed-by-user states are dropped; sending and checking keep going (U8).
    func invalidate() {
        switch phase {
        case .ready, .rereading, .questionChanged, .unlockToContinue, .invalidated, .notSent:
            token += 1
            issued = nil
            phase = .invalidated
            let api = workspace.api
            Task { await api.invalidateReviews() }
        default: break
        }
        if load == .loading { token += 1 }
    }

    func retryAfterUnlock() {
        guard phase == .unlockToContinue else { return }
        token += 1
        let mine = token
        phase = .rereading
        Task {
            // The person unlocks the phone (Demo: the simulated lock releases by itself); a new review is read only after that.
            var waited = 0
            while services.deviceLocked, waited < 100 { try? await Task.sleep(for: .milliseconds(100)); waited += 1 }
            guard mine == token, phase == .rereading else { return }
            let ok = await issue(revision: (review?.revision ?? 0) + 1, mine: mine)
            guard mine == token, phase == .rereading else { return }
            phase = ok ? .ready : .invalidated
        }
    }
}
