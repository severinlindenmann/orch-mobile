import XCTest

final class SettingsTests: XCTestCase {
    @MainActor
    func testLeaveFlowConfirmationText() {
        let app = launch("settings/workspace/laptop")
        let leave = app.buttons["settings.leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 10))
        leave.tap()
        let message = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'even if you are offline'")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(message.label.contains("may stay pending"))
        app.buttons["settings.leave.confirm"].tap()
        XCTAssertTrue(app.el("settings.leave.done").waitForExistence(timeout: 5))
        XCTAssertTrue(app.el("settings.leave.server").label.contains("Notifications"))
    }

    @MainActor
    func testLeaveWithoutScopeSaysFinishOnMac() {
        let app = launch("settings/workspace/client-vm")
        app.buttons["settings.leave"].tap()
        let confirm = app.buttons["settings.leave.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        XCTAssertTrue(app.el("settings.leave.server").waitForExistence(timeout: 5))
        XCTAssertTrue(app.el("settings.leave.server").label.contains("Finish on your Mac"))
    }

    @MainActor
    func testRevocationExplanationIsDistinct() {
        let app = launch("settings")
        let revocation = app.el("settings.revocation")
        var tries = 0
        while !revocation.exists && tries < 6 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(revocation.waitForExistence(timeout: 5))
        XCTAssertTrue(revocation.label.contains("Revocation is different from leaving"))
        let reset = app.el("settings.reset")
        tries = 0
        while !reset.exists && tries < 6 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(reset.exists)
    }
}
