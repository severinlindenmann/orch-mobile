import XCTest

/// Captures every main screen in light and dark as kept attachments (exported to docs/screens/).
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
        ("14-pair-entry", "pair/entry", true),
        ("15-pair-connecting", "pair/connecting", true),
        ("16-pair-compare-host", "pair/sas", true),
        ("17-pair-cert-pending", "pair/certPending", true),
        ("18-pair-compare-primary", "pair/certCode", true),
        ("19-pair-joining", "pair/joining", true),
        ("20-pair-ready", "pair/ready", true),
        ("21-pair-expired", "pair/expired", true),
        ("22-pair-alarm-r1", "pair/r1", true),
        ("23-pair-alarm-wrong-key", "pair/wrongKey", true),
        ("24-pair-refused", "pair/refused", true),
        ("25-drop", "drop", true),
        ("26-drop-compose", "drop/compose", true),
        ("27-drop-item", "drop/item/d-note", true),
        ("28-settings", "settings", true),
        ("29-workspace-settings", "settings/workspace/laptop", true),
        ("33-question-unsafe-options", "question/q6", true),
        ("34-empty-home", "empty", true)
    ]

    @MainActor
    func testCaptureAllScreens() {
        for dark in [false, true] {
            for shot in shots {
                let app = launch(shot.route, demo: shot.demo, dark: dark)
                Thread.sleep(forTimeInterval: 1.5)
                assertScheme(app, dark: dark)
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "\(shot.name)-\(dark ? "dark" : "light")"
                attachment.lifetime = .keepAlways
                add(attachment)
                app.terminate()
            }
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
        let list: [(String, String?)] = [("40-ax-home", nil), ("41-ax-sign-sheet", "sign/q1"), ("42-ax-pair-compare", "pair/sas"),
                                         ("43-ax-workspace", "workspace/laptop")]
        for dark in [false, true] {
            for (name, route) in list {
                let app = launch(route, dark: dark, extra: ax)
                Thread.sleep(forTimeInterval: 1.5)
                assertScheme(app, dark: dark)
                let a = XCTAttachment(screenshot: app.screenshot())
                a.name = "\(name)-\(dark ? "dark" : "light")"; a.lifetime = .keepAlways; add(a)
                app.terminate()
            }
        }
    }

    @MainActor
    func testCapturePairingPanels() {
        for dark in [false, true] {
            let app = launch("pair/sas", dark: dark)
            app.buttons["demo.hostPanel.show"].tap()
            Thread.sleep(forTimeInterval: 1)
            var a = XCTAttachment(screenshot: app.screenshot())
            a.name = "30-demo-host-panel-\(dark ? "dark" : "light")"; a.lifetime = .keepAlways; add(a)
            app.terminate()
            let app2 = launch("pair/certCode", dark: dark)
            app2.buttons["demo.primaryPanel.show"].tap()
            Thread.sleep(forTimeInterval: 1)
            a = XCTAttachment(screenshot: app2.screenshot())
            a.name = "31-demo-primary-panel-\(dark ? "dark" : "light")"; a.lifetime = .keepAlways; add(a)
            app2.terminate()
        }
    }
}
