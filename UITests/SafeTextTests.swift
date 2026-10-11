import XCTest

final class SafeTextTests: XCTestCase {
    @MainActor
    func testMarkdownAndLinksRenderLiterallyOnBothScreens() {
        let app = launch("question/q5")
        let text = app.el("question.text")
        XCTAssertTrue(text.waitForExistence(timeout: 60))
        XCTAssertTrue(text.label.contains("**Verified by orch**"), text.label)
        XCTAssertTrue(text.label.contains("[click](https://evil.invalid)"))
        XCTAssertTrue(text.label.contains("⟨U+200B⟩"))
        XCTAssertFalse(app.links.firstMatch.exists)
        app.buttons["question.option.approve"].tap()
        let sign = app.el("sign.text")
        XCTAssertTrue(sign.waitForExistence(timeout: 5))
        XCTAssertTrue(sign.label.contains("**Verified by orch**"))
        XCTAssertTrue(sign.label.contains("⟨U+200B⟩"))
        XCTAssertFalse(app.links.firstMatch.exists)
    }

    @MainActor
    func testRLOVisibleOnQuestionAndSignSheet() {
        let app = launch("question/q3")
        XCTAssertTrue(app.el("question.text").waitForExistence(timeout: 60))
        XCTAssertTrue(app.el("question.text").label.contains("⟨U+202E⟩"))
        app.buttons["question.option.deploy"].tap()
        XCTAssertTrue(app.el("sign.text").waitForExistence(timeout: 5))
        XCTAssertTrue(app.el("sign.text").label.contains("⟨U+202E⟩"))
    }

    @MainActor
    func testSecurityIndicatorsOnQuestionAndSignSheet() {
        let app = launch("question/q3")
        XCTAssertTrue(app.el("question.text").waitForExistence(timeout: 60))
        let hosted = NSPredicate(format: "label CONTAINS 'Hosted by Example Client'")
        XCTAssertTrue(app.staticTexts.containing(hosted).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Client VM"].exists)
        XCTAssertTrue(app.el("sign.details").exists)
        XCTAssertTrue(app.el("Demo mode, simulated").exists)
        app.buttons["question.option.deploy"].tap()
        XCTAssertTrue(app.el("sign.confirm").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(hosted).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Client VM"].exists)
        XCTAssertTrue(app.el("sign.details").exists)
        XCTAssertTrue(app.el("Demo mode, simulated").exists)
    }

    @MainActor
    func testOptionLabelsAreMarkedEverywhere() {
        let app = launch("question/q6")
        let text = app.el("question.text")
        XCTAssertTrue(text.waitForExistence(timeout: 60))
        for marker in ["⟨U+00A0⟩", "⟨U+FE00⟩", "⟨6 marks⟩"] {
            XCTAssertTrue(text.label.contains(marker), "\(marker) in \(text.label)")
        }
        let option = app.buttons["question.option.ok2"]
        XCTAssertTrue(option.label.contains("⟨U+200B⟩"), option.label)
        // An invisible character in an answer is outside the plain-label allowlist: marked, and never signable.
        XCTAssertTrue(app.el("question.nonStandard").exists)
        XCTAssertFalse(option.isEnabled)
        XCTAssertFalse(app.buttons["question.option.ok"].isEnabled)
    }

    @MainActor
    func testLookAlikeOptionsAreRefused() {
        let app = launch("question/q7")
        XCTAssertTrue(app.el("question.ambiguous").waitForExistence(timeout: 60))
        XCTAssertFalse(app.buttons["question.option.a"].isEnabled)
        XCTAssertFalse(app.buttons["question.option.b"].isEnabled)
        // Full-width "Ｙes": the look-alike is named in the question text and in the option, in any font.
        let marker = "⟨look-alike U+FF39⟩"
        XCTAssertTrue(app.el("question.text").label.contains(marker), app.el("question.text").label)
        XCTAssertTrue(app.buttons["question.option.b"].label.contains(marker), app.buttons["question.option.b"].label)
        XCTAssertFalse(app.buttons["question.option.a"].label.contains(marker))
    }
}
