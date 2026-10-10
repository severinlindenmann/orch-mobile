import XCTest

final class HomeTests: XCTestCase {
    @MainActor
    func testDemoHomeShowsTwoCardsAndNeedsYou() {
        let app = launch()
        XCTAssertTrue(app.el("home.needsYou").waitForExistence(timeout: 10))
        XCTAssertTrue(app.el("home.workspace.laptop").exists)
        XCTAssertTrue(app.el("home.workspace.client-vm").exists)
        XCTAssertTrue(app.el("home.drop").exists)
        XCTAssertTrue(app.el("Demo mode, simulated").exists)
        XCTAssertTrue(app.el("simulation.notice").exists)
    }

    @MainActor
    func testNeedsYouListGroupedByWorkspace() {
        let app = launch("needs-you")
        XCTAssertTrue(app.el("question.q1").waitForExistence(timeout: 10))
        XCTAssertTrue(app.el("question.q2").exists)
        XCTAssertTrue(app.el("question.q3").exists)
        XCTAssertTrue(app.staticTexts["Laptop"].exists)
        XCTAssertTrue(app.staticTexts["Client VM"].exists)
    }

    @MainActor
    func testEmptyDemoKeepsSettingsReachable() {
        let app = launch("empty")
        XCTAssertTrue(app.el("home.empty").waitForExistence(timeout: 10))
        app.buttons["empty.settings"].tap()
        let reset = app.el("settings.reset")
        var tries = 0
        while !reset.exists && tries < 6 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(reset.exists)
    }

    @MainActor
    func testWelcomeOffersDemoAndPair() {
        let app = launch(demo: false)
        XCTAssertTrue(app.buttons["welcome.demo"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["welcome.pair"].exists)
        app.buttons["welcome.demo"].tap()
        XCTAssertTrue(app.el("home.workspace.laptop").waitForExistence(timeout: 5))
    }
}
