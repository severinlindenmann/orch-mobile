import XCTest

final class TabTests: XCTestCase {
    @MainActor
    func testTabBarReachesQuestionsDropAndSettings() {
        let app = launch()
        XCTAssertTrue(app.el("home.needsYou").waitForExistence(timeout: 90))
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.exists)
        for name in ["Home", "Questions", "Drop", "Settings"] { XCTAssertTrue(tabs.buttons[name].exists, name) }
        tabs.buttons["Questions"].tap()
        XCTAssertTrue(app.el("needsYou.list").waitForExistence(timeout: 10))
        tabs.buttons["Drop"].tap()
        XCTAssertTrue(app.segmentedControls["drop.direction"].waitForExistence(timeout: 10))
        tabs.buttons["Settings"].tap()
        XCTAssertTrue(app.el("settings.deviceLabel").waitForExistence(timeout: 10))
        tabs.buttons["Home"].tap()
        XCTAssertTrue(app.buttons["home.add"].waitForExistence(timeout: 10))
    }
}
