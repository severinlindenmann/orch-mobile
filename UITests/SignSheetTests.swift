import XCTest

/// The sign sheet on the real stack: QuestionReview from the session, decide(review, optionID:) signed inside the session and accepted
/// (or refused) by the Demo host. The "Next answer ends as" control acts on the fake host or the lock, not on the app.
final class SignSheetTests: XCTestCase {
    @MainActor
    func testConfirmDisabledUntilScrolledAndArmed() {
        let app = launch("sign/q2")
        let confirm = app.buttons["sign.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 60))
        XCTAssertFalse(confirm.isEnabled, "long text: disabled before scrolling")
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertFalse(confirm.isEnabled, "arming delay alone is not enough")
        var tries = 0
        while !confirm.isEnabled && tries < 25 {
            app.swipeUp(velocity: .fast)
            Thread.sleep(forTimeInterval: 0.3)
            tries += 1
        }
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: confirm)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.el("sign.footnote").exists)
    }

    @MainActor
    func testSignedDecisionIsAcceptedByDemoHost() {
        let app = launch("sign/q1")
        let confirm = app.buttons["sign.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 60))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: confirm)
        waitForExpectations(timeout: 5)
        app.el("sign.details").tap()
        confirm.tap()
        XCTAssertTrue(app.el("sign.accepted").waitForExistence(timeout: 30))
        app.buttons["sign.done"].tap()
        // The host recorded the decision: the question is answered by this device, with the signed option.
        let resolution = app.el("question.resolution")
        XCTAssertTrue(resolution.waitForExistence(timeout: 30))
        XCTAssertTrue(resolution.label.contains("Demo iPhone"), resolution.label)
        XCTAssertTrue(resolution.label.contains("Approve"), resolution.label)
    }

    @MainActor
    func testAlreadyAnsweredShowsWho() {
        let app = launch("sign/q1/alreadyAnswered")
        let confirm = app.buttons["sign.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 60))
        XCTAssertTrue(confirm.waitForEnabled())
        confirm.tap()
        let state = app.el("sign.alreadyAnswered")
        XCTAssertTrue(state.waitForExistence(timeout: 30))
        XCTAssertTrue(state.label.contains("Demo Mac"), state.label)
    }

    @MainActor
    func testBidiQuestionShowsVisibleMarkers() {
        let app = launch("sign/q3")
        XCTAssertTrue(app.el("sign.unsafeWarning").waitForExistence(timeout: 60))
        XCTAssertFalse(app.el("sign.unsafeNotice").exists, "one warning only while signing is possible")
        let text = app.el("sign.text")
        XCTAssertTrue(text.label.contains("⟨U+202E⟩"), "label: \(text.label)")
        XCTAssertTrue(text.label.contains("⟨U+202C⟩"))
    }

    @MainActor
    func testQuestionScreenShowsMarkersAndOpensSheet() {
        let app = launch("question/q3")
        let text = app.el("question.text")
        XCTAssertTrue(text.waitForExistence(timeout: 60))
        XCTAssertTrue(text.label.contains("⟨U+202E⟩"))
        app.buttons["question.option.deploy"].tap()
        XCTAssertTrue(app.buttons["sign.confirm"].waitForExistence(timeout: 30))
    }
}

final class SignSheetStateTests: XCTestCase {
    @MainActor
    func testBackgroundInvalidatesUnsentReviewAndNeedsFreshArming() {
        let app = launch("sign/q1")
        let confirm = app.buttons["sign.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 60))
        XCTAssertTrue(confirm.waitForEnabled())
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        XCTAssertTrue(app.el("question.option.approve").waitForExistence(timeout: 60))
        XCTAssertFalse(app.buttons["sign.confirm"].exists, "sheet dropped")
        app.buttons["question.option.approve"].tap()
        let fresh = app.buttons["sign.confirm"]
        XCTAssertTrue(fresh.waitForExistence(timeout: 30))
        // A fresh review arms again; it is never enabled instantly.
        XCTAssertTrue(fresh.waitForEnabled())
    }

    @MainActor
    func testLostResponseChecksThenReconcilesWithoutSigningAgain() {
        let app = launch("sign/q1/uncertain")
        let confirm = app.buttons["sign.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 60))
        XCTAssertTrue(confirm.waitForEnabled())
        confirm.tap()
        // "Checking" is transient: foreground reconcile may settle the lost response before it is rendered. Wait for either.
        let checking = app.el("sign.checking"), accepted = app.el("sign.accepted")
        let settle = { (t: TimeInterval) -> Bool in
            let end = Date().addingTimeInterval(t)
            while Date() < end { if checking.exists || accepted.exists { return true }; Thread.sleep(forTimeInterval: 0.25) }
            return checking.exists || accepted.exists
        }
        XCTAssertTrue(settle(60), "neither checking nor accepted after the lost response")
        if !accepted.exists {
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 1)
            app.activate()
            XCTAssertTrue(settle(30))
        }
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Review dropped'")).firstMatch.exists)
        // Reconcile reads what the host has: the stored decision was applied exactly once. The background reconcile may settle
        // first; either way the sheet ends accepted, never signed a second time (a second signature would end as alreadyAnswered/refused).
        let recheck = app.buttons["sign.recheck"]
        if !accepted.exists && recheck.exists && recheck.isHittable { recheck.tap() }
        XCTAssertTrue(accepted.waitForExistence(timeout: 60))
        XCTAssertFalse(app.el("sign.alreadyAnswered").exists, "a second signature would be answered as already answered")
        XCTAssertFalse(app.el("sign.refused").exists)
        // Exactly once: the host holds a single answer from this device with the signed option.
        app.buttons["sign.done"].tap()
        let resolution = app.el("question.resolution")
        XCTAssertTrue(resolution.waitForExistence(timeout: 30))
        XCTAssertTrue(resolution.label.contains("Demo iPhone") && resolution.label.contains("Approve"), resolution.label)
    }

    @MainActor
    func testReviewLoadFailureCanRetry() {
        let app = launch("sign/q1/loadFails")
        XCTAssertTrue(app.el("sign.loadFailed").waitForExistence(timeout: 60))
        // In a full run the first tap can land while the sheet is still settling and is swallowed (the failure
        // view stays up). Retry the tap while the failure view is still showing; the outcome asserted is unchanged.
        let retry = app.buttons["sign.retryLoad"]
        let confirm = app.buttons["sign.confirm"]
        var attempts = 0
        while !confirm.exists && attempts < 3 {
            if retry.waitForExistence(timeout: 5), retry.isHittable { retry.tap() }
            _ = confirm.waitForExistence(timeout: 10)
            attempts += 1
        }
        XCTAssertTrue(confirm.waitForExistence(timeout: 30))
    }

    @MainActor
    func testQuestionChangedForcesFreshArming() {
        let app = launch("sign/q1/questionChanged")
        let confirm = app.buttons["sign.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 60))
        XCTAssertTrue(confirm.waitForEnabled())
        confirm.tap()
        XCTAssertTrue(app.el("sign.questionChanged").waitForExistence(timeout: 30))
        app.buttons["sign.reread"].tap()
        let again = app.buttons["sign.confirm"]
        XCTAssertTrue(again.waitForExistence(timeout: 30))
        // The re-read shows the new text and arms from scratch.
        XCTAssertTrue(app.el("sign.text").label.contains("Edited at the Mac."))
        XCTAssertTrue(again.waitForEnabled())
    }

    @MainActor
    func testSignSheetReachableAtAccessibilitySize() {
        let app = launch("sign/q1", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"])
        let confirm = app.buttons["sign.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 60))
        var tries = 0
        while !(confirm.exists && confirm.isHittable) && tries < 20 { app.swipeUp(); tries += 1 }
        for _ in 0..<3 { app.swipeUp() }
        XCTAssertTrue(confirm.waitForEnabled())
    }

    @MainActor
    func testReopenedPendingSubmissionKeepsSubmittedOption() {
        let app = launch("question/q1/uncertain")
        let reject = app.buttons["question.option.reject"]
        XCTAssertTrue(reject.waitForExistence(timeout: 60))
        reject.tap()
        let confirm = app.buttons["sign.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 30))
        XCTAssertTrue(confirm.waitForEnabled())
        confirm.tap()
        XCTAssertTrue(app.el("sign.checking").waitForExistence(timeout: 60))
        app.buttons["sign.closeChecking"].tap()
        let pendingAnswer = app.el("question.pending.answer")
        XCTAssertTrue(pendingAnswer.waitForExistence(timeout: 10))
        XCTAssertTrue(pendingAnswer.label.contains("Reject"), pendingAnswer.label)
        app.buttons["question.pending"].tap()
        XCTAssertTrue(app.el("sign.answer").waitForExistence(timeout: 10))
        XCTAssertTrue(app.el("sign.answer").label.contains("Reject"))
        app.buttons["sign.recheck"].tap()
        XCTAssertTrue(app.el("sign.accepted").waitForExistence(timeout: 30))
        app.buttons["sign.done"].tap()
        let resolution = app.el("question.resolution")
        XCTAssertTrue(resolution.waitForExistence(timeout: 30))
        XCTAssertTrue(resolution.label.contains("Reject"), resolution.label)
        XCTAssertFalse(resolution.label.contains("Approve"))
    }

    @MainActor
    func testBackgroundWhileQuestionChangedNeedsFreshReview() {
        let app = launch("sign/q1/questionChanged")
        let confirm = app.buttons["sign.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 60))
        XCTAssertTrue(confirm.waitForEnabled())
        confirm.tap()
        XCTAssertTrue(app.el("sign.questionChanged").waitForExistence(timeout: 30))
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        XCTAssertTrue(app.el("question.option.approve").waitForExistence(timeout: 60))
        XCTAssertFalse(app.buttons["sign.confirm"].exists)
    }

    @MainActor
    func testUnlockRetryNeedsFreshArming() {
        let app = launch("sign/q1/locked")
        let confirm = app.buttons["sign.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 60))
        XCTAssertTrue(confirm.waitForEnabled())
        confirm.tap()
        XCTAssertTrue(app.el("sign.unlock").waitForExistence(timeout: 30))
        app.buttons["sign.unlockRetry"].tap()
        let again = app.buttons["sign.confirm"]
        XCTAssertTrue(again.waitForExistence(timeout: 30))
        // Not-carried-over arming is asserted deterministically in ReviewModelTests (revision bump);
        // here the button must re-arm through the delay.
        XCTAssertTrue(again.waitForEnabled())
    }
}
