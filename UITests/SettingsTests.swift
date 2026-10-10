import XCTest

final class SettingsTests: XCTestCase {
    @MainActor
    func testLeaveWipesTheWorkspaceFromThisIPhone() {
        let app = launch("settings/workspace/laptop")
        let leave = app.buttons["settings.leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 90))
        leave.tap()
        let message = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'even if you are offline'")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(message.label.contains("may stay pending"))
        app.buttons["settings.leave.confirm"].tap()
        XCTAssertTrue(app.el("settings.leave.done").waitForExistence(timeout: 30))
        XCTAssertTrue(app.el("settings.leave.server").label.contains("Notifications"))
        app.buttons["settings.leave.close"].tap()
        // Gone from Home, including its waiting questions; the other workspace is untouched.
        XCTAssertTrue(app.workspaceCard("Client VM").waitForExistence(timeout: 10))
        XCTAssertFalse(app.workspaceCard("Laptop").exists)
        XCTAssertFalse(app.questionRow("Enable mobile access?").exists)
    }

    @MainActor
    func testLeaveWithoutScopeSaysFinishOnMac() {
        let app = launch("settings/workspace/client-vm")
        XCTAssertTrue(app.buttons["settings.leave"].waitForExistence(timeout: 90))
        app.buttons["settings.leave"].tap()
        let confirm = app.buttons["settings.leave.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 90))
        confirm.tap()
        XCTAssertTrue(app.el("settings.leave.server").waitForExistence(timeout: 30))
        XCTAssertTrue(app.el("settings.leave.server").label.contains("Finish on your Mac"))
    }

    @MainActor
    func testLeftWorkspaceCanBePairedAgainAsNewGeneration() {
        let app = launch("settings/leave/laptop")
        let confirm = app.buttons["settings.leave.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 90))
        confirm.tap()
        XCTAssertTrue(app.el("settings.leave.done").waitForExistence(timeout: 30))
        app.buttons["settings.leave.close"].tap()
        XCTAssertTrue(app.buttons["home.add"].waitForExistence(timeout: 10))
        app.buttons["home.add"].tap()
        startDemoInvitation(app)
        approveOnDemoHost(app)
    }

    @MainActor
    func testDemoNotificationGoesThroughPushSimulator() {
        let app = launch("settings/workspace/laptop")
        let send = app.buttons["demo.push"]
        XCTAssertTrue(send.waitForExistence(timeout: 90))
        send.tap()
        let result = app.el("demo.push.result")
        XCTAssertTrue(result.waitForExistence(timeout: 30))
        let ok = NSPredicate(format: "label CONTAINS 'Local notification scheduled'")
        expectation(for: ok, evaluatedWith: result)
        waitForExpectations(timeout: 30)
    }

    @MainActor
    func testRevocationExplanationIsDistinct() {
        let app = launch("settings", seed: false)
        let revocation = app.el("settings.revocation")
        var tries = 0
        while !revocation.exists && tries < 6 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(revocation.waitForExistence(timeout: 60))
        XCTAssertTrue(revocation.label.contains("Revocation is different from leaving"))
        let reset = app.el("settings.reset")
        tries = 0
        while !reset.exists && tries < 6 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(reset.exists)
    }

    @MainActor
    func testLeaveDemoReturnsToWelcome() {
        let app = launch("settings", seed: false)
        let leave = app.buttons["demo.leave"]
        var tries = 0
        while !leave.exists && tries < 8 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(leave.waitForExistence(timeout: 60))
        leave.tap()
        XCTAssertTrue(app.buttons["welcome.demo"].waitForExistence(timeout: 30))
    }
}
