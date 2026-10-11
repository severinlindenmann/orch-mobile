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
        app.buttons["settings.leave.confirm"].firstMatch.tap()
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
        let confirm = app.buttons["settings.leave.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 90))
        confirm.tap()
        XCTAssertTrue(app.el("settings.leave.server").waitForExistence(timeout: 30))
        XCTAssertTrue(app.el("settings.leave.server").label.contains("Finish on your Mac"))
    }

    @MainActor
    func testLeftWorkspaceCanBePairedAgainAsNewGeneration() {
        let app = launch("settings/workspace/laptop")
        XCTAssertTrue(app.buttons["settings.leave"].waitForExistence(timeout: 90))
        app.buttons["settings.leave"].tap()
        let confirm = app.buttons["settings.leave.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
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
        addUIInterruptionMonitor(withDescription: "notifications") { alert in
            for label in ["Allow", "OK"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
        let app = launch("settings/workspace/laptop")
        let send = app.buttons["demo.push"]
        XCTAssertTrue(send.waitForExistence(timeout: 90))
        send.tap()
        app.tap()   // lets the interruption monitor handle a permission prompt
        let result = app.el("demo.push.result")
        XCTAssertTrue(result.waitForExistence(timeout: 30))
        let ok = NSPredicate(format: "label CONTAINS 'Local notification scheduled'")
        expectation(for: ok, evaluatedWith: result)
        waitForExpectations(timeout: 30)
    }

    @MainActor
    func testSettingsDemoControlSchedulesNotification() {
        let app = launch("settings")
        // The first use may raise the system permission prompt; allow it.
        addUIInterruptionMonitor(withDescription: "notifications") { alert in
            for label in ["Allow", "OK"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
        let send = app.buttons["demo.sendNotification"]
        var tries = 0
        while !send.exists && tries < 6 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(send.waitForExistence(timeout: 90))
        send.tap()
        let result = app.el("demo.sendNotification.result")
        XCTAssertTrue(result.waitForExistence(timeout: 30))
        let settled = NSPredicate(format: "label CONTAINS 'scheduled' OR label CONTAINS 'iOS Settings'")
        expectation(for: settled, evaluatedWith: result)
        waitForExpectations(timeout: 60)
    }

    @MainActor
    func testOfflineLeaveStillRemovesLocally() {
        let app = launch("settings/workspace/laptop")
        let offline = app.switches["demo.offline"]
        XCTAssertTrue(offline.waitForExistence(timeout: 90))
        offline.switches.firstMatch.exists ? offline.switches.firstMatch.tap() : offline.tap()
        if (offline.value as? String) != "1" { offline.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(offline.value as? String, "1")
        app.buttons["settings.leave"].tap()
        let confirm = app.buttons["settings.leave.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        XCTAssertTrue(app.el("settings.leave.done").waitForExistence(timeout: 30))
        XCTAssertFalse(app.el("settings.leave.incomplete").exists)
        XCTAssertTrue(app.el("settings.leave.server").label.contains("pending"))
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
