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
