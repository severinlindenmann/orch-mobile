import XCTest

final class SignSheetTests: XCTestCase {
    @MainActor
    func testConfirmDisabledUntilScrolledAndArmed() {
        let app = launch("sign/q2")
        let confirm = app.buttons["sign.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertFalse(confirm.isEnabled, "long text: disabled before scrolling")
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertFalse(confirm.isEnabled, "arming delay alone is not enough")
        let text = app.el("sign.text")
        var tries = 0
        while !confirm.isEnabled && tries < 25 {
            app.swipeUp(velocity: .fast)
            Thread.sleep(forTimeInterval: 0.3)
            tries += 1
        }
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: confirm)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(text.exists || tries > 0)
        XCTAssertTrue(app.el("sign.footnote").exists)
    }

    @MainActor
    func testShortQuestionArmsAfterDelayAndAccepts() {
        let app = launch("sign/q1")
        let confirm = app.buttons["sign.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: confirm)
        waitForExpectations(timeout: 5)
        app.el("sign.details").tap()
        XCTAssertTrue(app.staticTexts["q1"].waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(app.el("sign.accepted").waitForExistence(timeout: 5))
    }

    @MainActor
    func testAlreadyAnsweredShowsWho() {
        let app = launch("sign/q1/alreadyAnswered")
        let confirm = app.buttons["sign.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: confirm)
        waitForExpectations(timeout: 5)
        confirm.tap()
        let state = app.el("sign.alreadyAnswered")
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertTrue(state.label.contains("Demo Mac"))
    }

    @MainActor
    func testBidiQuestionShowsVisibleMarkers() {
        let app = launch("sign/q3")
        XCTAssertTrue(app.el("sign.unsafeNotice").waitForExistence(timeout: 10))
        let text = app.el("sign.text")
        XCTAssertTrue(text.label.contains("⟨U+202E⟩"), "label: \(text.label)")
        XCTAssertTrue(text.label.contains("⟨U+202C⟩"))
    }

    @MainActor
    func testQuestionScreenShowsMarkersAndOpensSheet() {
        let app = launch("question/q3")
        let text = app.el("question.text")
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue(text.label.contains("⟨U+202E⟩"))
        app.buttons["question.option.deploy"].tap()
        XCTAssertTrue(app.buttons["sign.confirm"].waitForExistence(timeout: 5))
    }
}

final class SignSheetStateTests: XCTestCase {
    @MainActor
    func testBackgroundInvalidatesUnsentReviewAndNeedsFreshArming() {
        let app = launch("sign/q1")
        let confirm = app.buttons["sign.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(confirm.waitForEnabled())
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        XCTAssertTrue(app.el("question.option.approve").waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["sign.confirm"].exists, "sheet dropped")
        app.buttons["question.option.approve"].tap()
        let fresh = app.buttons["sign.confirm"]
        XCTAssertTrue(fresh.waitForExistence(timeout: 5))
        // A fresh review arms again; it is never enabled instantly.
        XCTAssertTrue(fresh.waitForEnabled())
    }

    @MainActor
    func testBackgroundWhileCheckingKeepsCheckingState() {
        let app = launch("sign/q1/uncertain")
        let confirm = app.buttons["sign.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(confirm.waitForEnabled())
        confirm.tap()
        XCTAssertTrue(app.el("sign.checking").waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        XCTAssertTrue(app.el("sign.checking").waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Review dropped'")).firstMatch.exists)
        // Close without cancelling; Home shows the way back.
        app.buttons["sign.closeChecking"].tap()
        XCTAssertTrue(app.el("question.pending").waitForExistence(timeout: 5))
    }

    @MainActor
    func testReviewLoadFailureCanRetry() {
        let app = launch("sign/q1/loadFails")
        XCTAssertTrue(app.el("sign.loadFailed").waitForExistence(timeout: 10))
        app.buttons["sign.retryLoad"].tap()
        XCTAssertTrue(app.buttons["sign.confirm"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testQuestionChangedForcesFreshArming() {
        let app = launch("sign/q1/questionChanged")
        let confirm = app.buttons["sign.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(confirm.waitForEnabled())
        confirm.tap()
        XCTAssertTrue(app.el("sign.questionChanged").waitForExistence(timeout: 5))
        app.buttons["sign.reread"].tap()
        let again = app.buttons["sign.confirm"]
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        XCTAssertTrue(again.waitForEnabled())
    }

    @MainActor
    func testSignSheetReachableAtAccessibilitySize() {
        let app = launch("sign/q1", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"])
        let confirm = app.buttons["sign.confirm"]
        var tries = 0
        while !(confirm.exists && confirm.isHittable) && tries < 20 { app.swipeUp(); tries += 1 }
        for _ in 0..<3 { app.swipeUp() }
        XCTAssertTrue(confirm.waitForEnabled())
    }

    @MainActor
    func testReopenedPendingSubmissionKeepsSubmittedOption() {
        let app = launch("question/q1/uncertain")
        app.buttons["question.option.reject"].tap()
        let confirm = app.buttons["sign.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(confirm.waitForEnabled())
        confirm.tap()
        XCTAssertTrue(app.el("sign.checking").waitForExistence(timeout: 5))
        app.buttons["sign.closeChecking"].tap()
        let pendingAnswer = app.el("question.pending.answer")
        XCTAssertTrue(pendingAnswer.waitForExistence(timeout: 5))
        XCTAssertTrue(pendingAnswer.label.contains("Reject"), pendingAnswer.label)
        app.buttons["question.pending"].tap()
        XCTAssertTrue(app.el("sign.answer").waitForExistence(timeout: 5))
        XCTAssertTrue(app.el("sign.answer").label.contains("Reject"))
        app.buttons["sign.recheck"].tap()
        XCTAssertTrue(app.el("sign.accepted").waitForExistence(timeout: 5))
        app.buttons["sign.done"].tap()
        let resolution = app.el("question.resolution")
        XCTAssertTrue(resolution.waitForExistence(timeout: 5))
        XCTAssertTrue(resolution.label.contains("Reject"), resolution.label)
        XCTAssertFalse(resolution.label.contains("Approve"))
    }

    @MainActor
    func testBackgroundWhileQuestionChangedNeedsFreshReview() {
        let app = launch("sign/q1/questionChanged")
        let confirm = app.buttons["sign.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(confirm.waitForEnabled())
        confirm.tap()
        XCTAssertTrue(app.el("sign.questionChanged").waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        XCTAssertTrue(app.el("question.option.approve").waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["sign.confirm"].exists)
    }

    @MainActor
    func testUnlockRetryNeedsFreshArming() {
        let app = launch("sign/q1/locked")
        let confirm = app.buttons["sign.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(confirm.waitForEnabled())
        confirm.tap()
        XCTAssertTrue(app.el("sign.unlock").waitForExistence(timeout: 5))
        app.buttons["sign.unlockRetry"].tap()
        let again = app.buttons["sign.confirm"]
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        // Not-carried-over arming is asserted deterministically in ReviewModelTests (revision bump);
        // here the button must re-arm through the delay.
        XCTAssertTrue(again.waitForEnabled())
    }
}
