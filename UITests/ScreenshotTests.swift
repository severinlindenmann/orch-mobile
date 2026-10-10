import XCTest

/// Captures every main screen in light and dark as kept attachments (exported to docs/screens/). Everything runs on the real Demo
/// stack; pairing screens are reached by really pairing through the Demo panels.
final class ScreenshotTests: XCTestCase {
    private let shots: [(name: String, route: String?, demo: Bool)] = [
        ("01-welcome", nil, false),
        ("02-home", nil, true),
        ("03-needs-you", "needs-you", true),
        ("04-workspace-questions", "workspace/laptop", true),
        ("05-workspace-tickets", "workspace/laptop/tickets", true),
        ("06-ticket-factory-epic", "ticket/laptop/FAC-1", true),
        ("07-workspace-files", "workspace/laptop/files", true),
        ("08-workspace-terminal", "workspace/laptop/terminal", true),
        ("09-workspace-hosted", "workspace/client-vm", true),
        ("10-question", "question/q1", true),
        ("11-sign-sheet", "sign/q1", true),
        ("12-sign-sheet-long", "sign/q2", true),
        ("13-sign-sheet-bidi", "sign/q3", true),
        ("14-pair-entry", "pair", true),
        ("25-drop", "drop", true),
        ("26-drop-compose", "drop/compose", true),
        ("27-drop-item", "drop/item/d-note", true),
        ("28-settings", "settings", true),
        ("29-workspace-settings", "settings/workspace/laptop", true),
        ("33-question-unsafe-options", "question/q6", true)
    ]

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String, dark: Bool) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(name)-\(dark ? "dark" : "light")"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testCaptureAllScreens() {
        for dark in [false, true] {
            for shot in shots {
                let app = launch(shot.route, demo: shot.demo, seed: shot.demo, dark: dark)
                XCTAssertTrue(app.el("debug.scheme").waitForExistence(timeout: 120), "scheme marker")
                Thread.sleep(forTimeInterval: 1.5)
                assertScheme(app, dark: dark)
                capture(app, shot.name, dark: dark)
                app.terminate()
            }
            // Empty Demo home.
            let app = launch(seed: false, dark: dark)
            XCTAssertTrue(app.el("home.empty").waitForExistence(timeout: 60))
            Thread.sleep(forTimeInterval: 1)
            capture(app, "34-empty-home", dark: dark)
            app.terminate()
        }
    }

    @MainActor
    func assertScheme(_ app: XCUIApplication, dark: Bool) {
        let marker = app.el("debug.scheme")
        XCTAssertTrue(marker.waitForExistence(timeout: 5), "scheme marker")
        XCTAssertEqual(marker.value as? String, dark ? "dark" : "light")
    }

    @MainActor
    func testCaptureAccessibilitySizes() {
        let ax = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"]
        let list: [(String, String?)] = [("40-ax-home", nil), ("41-ax-sign-sheet", "sign/q1"), ("43-ax-workspace", "workspace/laptop")]
        for dark in [false, true] {
            for (name, route) in list {
                let app = launch(route, dark: dark, extra: ax)
                XCTAssertTrue(app.el("debug.scheme").waitForExistence(timeout: 120))
                Thread.sleep(forTimeInterval: 1.5)
                assertScheme(app, dark: dark)
                capture(app, name, dark: dark)
                app.terminate()
            }
        }
    }

    /// The whole pairing, screen by screen, on the real coordinator.
    @MainActor
    func testCapturePairingScreens() {
        for dark in [false, true] {
            let app = launch("pair", seed: false, dark: dark)
            startDemoInvitation(app)
            XCTAssertTrue(app.el("pair.sas").waitForExistence(timeout: Self.slow))
            Thread.sleep(forTimeInterval: 0.5)
            capture(app, "16-pair-compare-host", dark: dark)
            app.buttons["demo.hostPanel.show"].tap()
            XCTAssertTrue(app.el("demo.hostPanel.code").waitForExistence(timeout: Self.slow))
            Thread.sleep(forTimeInterval: 0.5)
            capture(app, "30-demo-host-panel", dark: dark)
            app.switches["demo.hostPanel.compared"].flip()
            XCTAssertTrue(app.buttons["demo.hostPanel.approve"].waitForEnabled())
            app.buttons["demo.hostPanel.approve"].tap()
            XCTAssertTrue(app.el("pair.openPrimary").waitForExistence(timeout: Self.slow))
            Thread.sleep(forTimeInterval: 0.5)
            capture(app, "17-pair-cert-pending", dark: dark)
            app.buttons["demo.primaryPanel.show"].tap()
            app.buttons["demo.primaryPanel.open"].tap()
            XCTAssertTrue(app.el("demo.primaryPanel.code").waitForExistence(timeout: Self.slow))
            Thread.sleep(forTimeInterval: 0.5)
            capture(app, "31-demo-primary-panel", dark: dark)
            app.switches["demo.primaryPanel.compared"].flip()
            app.buttons["demo.primaryPanel.close"].tap()
            XCTAssertTrue(app.el("pair.certCode").waitForExistence(timeout: 5))
            capture(app, "18-pair-compare-primary", dark: dark)
            app.buttons["demo.primaryPanel.show"].tap()
            app.switches["demo.primaryPanel.compared"].flip()
            app.buttons["demo.primaryPanel.approve"].tap()
            XCTAssertTrue(app.el("pair.ready").waitForExistence(timeout: Self.slow))
            capture(app, "20-pair-ready", dark: dark)
            app.terminate()

            let alarm = launch("pair/wrongKey", seed: false, dark: dark)
            startDemoInvitation(alarm)
            XCTAssertTrue(alarm.el("pair.alarm").waitForExistence(timeout: Self.slow))
            capture(alarm, "23-pair-alarm-wrong-key", dark: dark)
            alarm.terminate()

            let used = launch("pair/linkUsed", seed: false, dark: dark)
            startDemoInvitation(used)
            XCTAssertTrue(used.el("pair.refused").waitForExistence(timeout: Self.slow))
            capture(used, "24-pair-refused", dark: dark)
            used.terminate()
        }
    }
}
