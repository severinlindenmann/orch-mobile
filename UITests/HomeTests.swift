import XCTest

final class HomeTests: XCTestCase {
    @MainActor
    func testDemoHome() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--demo"]
        app.launch()
        XCTAssertTrue(app.buttons["home.needsYou"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["home.workspace.laptop"].exists)
        XCTAssertTrue(app.buttons["home.workspace.client-vm"].exists)
    }
}
