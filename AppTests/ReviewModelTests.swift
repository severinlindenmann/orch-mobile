import XCTest
@testable import Orch

@MainActor
final class ReviewModelTests: XCTestCase {
    private func makeModel(option: String = "reject", outcome: SignOutcome = .accepted) -> (PreviewWorld, PreviewReviewModel) {
        let world = PreviewWorld(demo: true)
        world.signOutcome = outcome
        return (world, PreviewReviewModel(world: world, questionID: "q1", optionID: option))
    }

    func testBackgroundDuringRereadStaysInvalidated() async {
        let (_, model) = makeModel(outcome: .questionChanged)
        await model.loadReview()
        await model.sign()
        XCTAssertEqual(model.phase, .questionChanged)
        let reread = Task { await model.reread() }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.phase, .rereading)
        model.invalidate()
        await reread.value
        XCTAssertEqual(model.phase, .invalidated)
        XCTAssertEqual(model.review?.revision, 0, "no new signable review was issued after invalidation")
    }

    func testUnlockRetryIssuesFreshReview() async {
        let (_, model) = makeModel(outcome: .locked)
        await model.loadReview()
        await model.sign()
        XCTAssertEqual(model.phase, .unlockToContinue)
        let before = model.review?.revision
        model.retryAfterUnlock()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.review?.revision, (before ?? 0) + 1, "fresh revision forces fresh arming")
    }

    func testInvalidateWhileReadyIsTerminal() async {
        let (_, model) = makeModel()
        await model.loadReview()
        model.invalidate()
        XCTAssertEqual(model.phase, .invalidated)
        await model.sign()
        XCTAssertEqual(model.phase, .invalidated, "cannot sign after invalidation")
    }

    func testSendingAndCheckingSurviveInvalidate() async {
        let (world, model) = makeModel(outcome: .uncertain)
        await model.loadReview()
        await model.sign()
        XCTAssertEqual(model.phase, .checking)
        model.invalidate()
        XCTAssertEqual(model.phase, .checking)
        XCTAssertEqual(world.pendingDecisions.count, 1)
    }

    func testReopenedPendingKeepsSubmittedOptionAndReview() async {
        let (world, model) = makeModel(option: "reject", outcome: .uncertain)
        await model.loadReview()
        await model.sign()
        let signedReview = model.review
        // Reopen with the FIRST option, as the old buggy path did.
        let reopened = PreviewReviewModel(world: world, questionID: "q1", optionID: "approve")
        XCTAssertEqual(reopened.phase, .checking)
        XCTAssertEqual(reopened.review, signedReview)
        XCTAssertEqual(reopened.review?.optionID, "reject")
        await reopened.checkWhetherReceived()
        XCTAssertEqual(world.questions.first { $0.id == "q1" }?.resolution?.optionID, "reject")
    }

    /// Relay `retry_exhausted`: the answer is stored but not delivered. It is not "checking" (nothing keeps polling) and it is never
    /// resent until the person taps Send again, which sends the same stored answer.
    func testNotDeliveredNeedsAnExplicitSendAgain() async {
        let (world, model) = makeModel(option: "reject", outcome: .notDelivered)
        await model.loadReview()
        await model.sign()
        XCTAssertEqual(model.phase, .needsRetry)
        XCTAssertEqual(world.pendingDecisions.first?.outcome, .needsRetry)
        model.invalidate()
        XCTAssertEqual(model.phase, .needsRetry, "a stored answer survives lock/background")
        await model.checkWhetherReceived()
        XCTAssertEqual(model.phase, .needsRetry, "checking is not how it is resolved")
        let reopened = PreviewReviewModel(world: world, questionID: "q1", optionID: "approve")
        XCTAssertEqual(reopened.phase, .needsRetry)
        XCTAssertEqual(reopened.review?.optionID, "reject")
        await reopened.sendAgain()
        XCTAssertEqual(reopened.phase, .accepted)
        XCTAssertEqual(world.questions.first { $0.id == "q1" }?.resolution?.optionID, "reject")
        XCTAssertTrue(world.pendingDecisions.isEmpty)
    }
}
