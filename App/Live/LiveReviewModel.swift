import Foundation
import Observation
import OrchClient
import OrchCustody
import OrchProtocol

/// The sign sheet's model over the real workspace API (C2b): `review(questionID:)` issues an immutable `ReviewedSnapshot` (kept here,
/// behind the display projection built from that SAME snapshot), `answer(snapshot, option:)` signs inside the session. Arming stays in the
/// view (800 ms after the full scroll). A new review is the only way back from a changed question, lock or background (U7); a persisted
/// answer is only ever settled (U8), never re-signed from here.
@MainActor @Observable
final class LiveReviewModel: QuestionReviewModel {
    private let services: LiveServices
    private let workspace: LiveWorkspace
    /// The realm this review was issued in: a completion after the realm was left signs, stores and applies nothing.
    private let lifetime: RealmLifetime
    private let questionID: String
    private var optionID: String
    @ObservationIgnored private var issued: ReviewedSnapshot?
    @ObservationIgnored private var reviewID: String?
    /// Bumped by every invalidation and every new review request; completions from an older token are dropped.
    @ObservationIgnored private var token = 0
    private(set) var load: ReviewLoad = .loading
    private(set) var review: ReviewValue?
    private(set) var phase: SignPhase = .ready

    init(services: LiveServices, workspace: LiveWorkspace, questionID: String, optionID: String) {
        self.services = services; self.lifetime = services.lifetime; self.workspace = workspace; self.questionID = questionID; self.optionID = optionID
        // U8: reopening an unsettled answer shows exactly what was signed, never re-derived, and never offers to sign again.
        if let pending = services.pendingWrites.first(where: { $0.questionID == questionID }) {
            self.optionID = pending.optionID
            review = pending.review
            reviewID = pending.reviewID
            load = .loaded
            phase = .checking
        }
    }

    private static let readFailure = "The question could not be read from the workspace. Nothing was signed."

    /// Reads the question afresh and keeps the issued snapshot. False when nothing signable was issued.
    private func issue(revision: Int, mine: Int) async -> Bool {
        guard workspace.usable, let qid = ID16(hex: questionID) else { load = .failed(Self.readFailure); return false }
        do {
            let r = try await workspace.api.review(questionID: qid)
            guard workspace.usable, mine == token else { return false }
            // A closed question is a successful read: show who answered and what, and never arm.
            if let resolution = r.question.resolution {
                let q = Mapping.question(r.question, workspaceID: workspace.info.id)
                review = Mapping.reviewValue(q, info: workspace.info, optionID: optionID, revision: revision, isDemo: services.isDemo)
                load = .loaded
                phase = .alreadyAnswered(by: resolution.byDeviceLabel, at: Mapping.date(resolution.atMs))
                return true
            }
            guard let snapshot = r.snapshot, snapshot.answerable, snapshot.options.contains(where: { $0.id == optionID }) else {
                load = .failed(Self.readFailure); return false
            }
            issued = snapshot
            review = Mapping.reviewValue(snapshot, info: workspace.info, optionID: optionID, revision: revision, isDemo: services.isDemo)
            load = .loaded
            return true
        } catch {
            guard workspace.usable, mine == token else { return false }
            #if ORCH_DEV_SANDBOX
            // the fresh `whoami` did not say the host takes Simulator answers (or could not be read): nothing was signed
            if case ViewError.hostRefusesSimulator = error { load = .failed(DevSandboxText.hostRefuses); return false }
            #endif
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
        guard lifetime.isActive, workspace.usable, phase == .ready, let issued, let review, review.optionsRefusal == nil else { return }
        phase = .sending
        self.issued = nil              // one review, one signature: it is consumed by this call
        services.recordSubmission(review)
        await services.applyDemoSignControl(workspace: workspace, questionID: questionID, optionID: optionID)
        guard workspace.usable, lifetime.isActive else { phase = .invalidated; return }
        do {
            let outcome = try await workspace.api.answer(issued, option: optionID)
            guard lifetime.isActive else { phase = .invalidated; return }
            await apply(outcome)
        } catch let e as CustodyError {
            guard lifetime.isActive else { phase = .invalidated; return }
            switch e {
            case .locked: phase = .unlockToContinue; workspace.api.noteCustodyLocked()
            default: phase = .custodyUnavailable
            }
        } catch let committed as AnswerCommitted {
            // SH3: the answer was committed, so it exists: its stored outcome if it has one, else it is being checked. Never "not sent".
            guard lifetime.isActive else { phase = .invalidated; return }
            workspace.noteKeyAlarm(committed.underlying)
            reviewID = committed.reviewID
            if let outcome = try? await workspace.api.writeOutcome(reviewID: committed.reviewID) {
                await apply(outcome)
            } else {
                phase = .checking
                services.startReconcile(workspace: workspace, reviewID: committed.reviewID)
            }
        } catch ViewError.invalidReview {
            phase = .invalidated
        } catch {
            guard lifetime.isActive else { phase = .invalidated; return }
            workspace.noteKeyAlarm(error)
            // The session failed before committing anything. "Nothing was stored" is claimed only once the store CONFIRMS that no
            // answer to this question exists; if it can't be read, the state is unknown: "Checking…".
            switch await services.storedWriteLookup(workspace: workspace, questionID: questionID) {
            case .found(let id):
                reviewID = id
                phase = .checking
                services.startReconcile(workspace: workspace, reviewID: id)
            case .unknown:
                phase = .checking
            case .none:
                // Signing needs the device key: a locked iPhone refuses before anything is signed or stored.
                phase = services.deviceLocked ? .unlockToContinue : .notSent
            }
        }
        // While the answer is only being checked the question stays as it was; the settled outcome refreshes it.
        if phase == .checking { await services.refreshPending() } else { await services.answerSettled(workspace: workspace) }
    }

    private func apply(_ outcome: WriteOutcome) async {
        switch outcome {
        case .landed: phase = .accepted
        case .landedAfterResign: phase = .resentAfterChange
        case .landedUnconfirmed: phase = .landedUnconfirmed
        case .alreadyAnswered(let label, let at): phase = .alreadyAnswered(by: label, at: Mapping.date(at))
        case .needsReview(.changed): phase = .questionChanged
        case .needsReview(.workspaceChanged): phase = .workspaceChanged
        case .needsReview(.notSent): phase = .needsReview
        case .refused, .ticketExists: phase = .refused
        case .checking:
            phase = .checking
            if reviewID == nil { reviewID = await services.storedWrite(workspace: workspace, questionID: questionID) }
            if let id = reviewID { services.startReconcile(workspace: workspace, reviewID: id) }
        }
    }

    func reread() async {
        guard phase == .questionChanged || phase == .needsReview || phase == .workspaceChanged else { return }
        token += 1
        let mine = token
        phase = .rereading
        let ok = await issue(revision: (review?.revision ?? 0) + 1, mine: mine)
        guard mine == token, phase == .rereading else { return }   // invalidated meanwhile: stay invalidated
        phase = ok ? .ready : .invalidated
    }

    /// Settles the stored answer. It never calls `answer` again and never builds a review.
    func checkWhetherReceived() async {
        guard workspace.usable, phase == .checking else { return }
        let id: String?
        if let reviewID { id = reviewID } else { id = await services.storedWrite(workspace: workspace, questionID: questionID) }
        guard let id else { return }
        reviewID = id
        if let outcome = try? await workspace.api.settle(reviewID: id), outcome != .checking {
            await apply(outcome)
            await services.answerSettled(workspace: workspace)
        }
    }

    /// Lock/background/content change. Only unsent or unconfirmed-by-user states are dropped; sending and checking keep going (U8).
    func invalidate() {
        switch phase {
        case .ready, .rereading, .questionChanged, .needsReview, .workspaceChanged, .unlockToContinue, .invalidated, .notSent:
            token += 1
            issued = nil
            phase = .invalidated
            let api = workspace.api
            api.noteReviewsInvalidated()                 // the fence first, synchronously
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
