import XCTest

final class HomeTests: XCTestCase {
    @MainActor
    func testDemoHomeShowsTwoCardsAndNeedsYou() {
        let app = launch()
        XCTAssertTrue(app.el("home.needsYou").waitForExistence(timeout: 10))
        XCTAssertTrue(app.el("home.workspace.laptop").exists)
        XCTAssertTrue(app.el("home.workspace.client-vm").exists)
        XCTAssertTrue(app.el("home.drop").exists)
        XCTAssertTrue(app.staticTexts["Demo"].exists || app.el("Demo mode").exists)
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
    func testWelcomeOffersDemoAndPair() {
        let app = launch(demo: false)
        XCTAssertTrue(app.buttons["welcome.demo"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["welcome.pair"].exists)
        app.buttons["welcome.demo"].tap()
        XCTAssertTrue(app.el("home.workspace.laptop").waitForExistence(timeout: 5))
    }
}
