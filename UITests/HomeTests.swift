import XCTest

final class HomeTests: XCTestCase {
    @MainActor
    func testSeededDemoHomeShowsTwoCardsAndNeedsYou() {
        let app = launch()
        XCTAssertTrue(app.el("home.needsYou").waitForExistence(timeout: 90))
        XCTAssertTrue(app.workspaceCard("Laptop").exists)
        XCTAssertTrue(app.workspaceCard("Client VM").exists)
        XCTAssertTrue(app.el("home.drop").exists)
        XCTAssertTrue(app.el("Demo mode, simulated").exists)
        let notice = app.el("simulation.notice")
        XCTAssertTrue(notice.exists)
        XCTAssertTrue(notice.label.contains("Demo — simulated workspace"), notice.label)
    }

    @MainActor
    func testNeedsYouListGroupedByWorkspace() {
        let app = launch("needs-you")
        XCTAssertTrue(app.questionRow("Enable mobile access?").waitForExistence(timeout: 90))
        XCTAssertTrue(app.questionRow("Review recovery step 1").exists)
        XCTAssertTrue(app.questionRow("Deploy invoice").exists)
        XCTAssertTrue(app.staticTexts["Laptop"].exists)
        XCTAssertTrue(app.staticTexts["Client VM"].exists)
    }

    @MainActor
    func testEmptyDemoKeepsSettingsReachable() {
        let app = launch(seed: false)
        XCTAssertTrue(app.el("home.empty").waitForExistence(timeout: 60))
        app.buttons["empty.settings"].tap()
        let reset = app.el("settings.reset")
        var tries = 0
        while !reset.exists && tries < 6 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(reset.exists)
    }

    @MainActor
    func testWelcomeOffersDemoAndPair() {
        let app = launch(demo: false)
        XCTAssertTrue(app.buttons["welcome.demo"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.buttons["welcome.pair"].exists)
        app.buttons["welcome.demo"].tap()
        XCTAssertTrue(app.el("home.empty").waitForExistence(timeout: 60), "Try Demo starts the Demo realm; it has no workspaces until paired")
    }

    @MainActor
    func testPreviewFallbackStillShowsSeededWorld() {
        let app = launch(extra: ["--ui-preview"])
        XCTAssertTrue(app.el("home.needsYou").waitForExistence(timeout: 60))
        XCTAssertTrue(app.el("home.workspace.laptop").exists)
    }
}
