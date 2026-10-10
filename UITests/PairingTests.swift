import XCTest

final class PairingTests: XCTestCase {
    @MainActor
    func testPasteToReadyThroughDemoPanels() {
        let app = launch("pair")
        let field = app.textFields["pair.paste"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("https://relay.demo.invalid/app/pair#test")
        app.buttons["pair.submit"].tap()

        let sas = app.el("pair.sas")
        XCTAssertTrue(sas.waitForExistence(timeout: 10))
        XCTAssertFalse(app.el("pair.certCode").exists, "host and primary codes never coexist")
        // Demo host panel: Approve stays disabled until "I compared the codes".
        app.buttons["demo.hostPanel.show"].tap()
        let approve = app.buttons["demo.hostPanel.approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 5))
        XCTAssertFalse(approve.isEnabled)
        app.switches["demo.hostPanel.compared"].flip()
        XCTAssertTrue(approve.waitForEnabled())
        approve.tap()
        

        XCTAssertTrue(app.el("pair.openPrimary").waitForExistence(timeout: 10))
        XCTAssertFalse(app.el("pair.sas").exists, "SAS is cleared on cert_pending")
        app.buttons["demo.primaryPanel.show"].tap()
        app.buttons["demo.primaryPanel.open"].tap()
        let primaryApprove = app.buttons["demo.primaryPanel.approve"]
        XCTAssertTrue(primaryApprove.waitForExistence(timeout: 5))
        XCTAssertFalse(primaryApprove.isEnabled)
        app.switches["demo.primaryPanel.compared"].flip()
        XCTAssertTrue(primaryApprove.waitForEnabled())
        // The phone shows the cert code behind the panel; dismiss it to compare.
        app.buttons["demo.primaryPanel.close"].tap()
        XCTAssertTrue(app.el("pair.certCode").waitForExistence(timeout: 5))
        app.buttons["demo.primaryPanel.show"].tap()
        app.switches["demo.primaryPanel.compared"].flip()
        app.buttons["demo.primaryPanel.approve"].tap()
        XCTAssertTrue(app.el("pair.ready").waitForExistence(timeout: 10))
    }

    @MainActor
    func testInvalidLinkIsRefusedWithFixedText() {
        let app = launch("pair")
        let field = app.textFields["pair.paste"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("https://evil.example/app/pair#x")
        app.buttons["pair.submit"].tap()
        XCTAssertTrue(app.el("pair.refused").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This isn't an orch pairing link"].exists)
    }

    @MainActor
    func testScanShowsCameraUnavailable() {
        let app = launch("pair")
        app.buttons["pair.scan"].tap()
        XCTAssertTrue(app.el("pair.scan.unavailable").waitForExistence(timeout: 5))
    }

    @MainActor
    func testR1AlarmHidesBothCodes() {
        let app = launch("pair/r1")
        XCTAssertTrue(app.el("pair.alarm").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Reject on Demo Mac'")).firstMatch.exists)
        XCTAssertFalse(app.el("pair.sas").exists)
        XCTAssertFalse(app.el("pair.certCode").exists)
    }

    @MainActor
    func testWrongKeyAlarmHidesBothCodes() {
        let app = launch("pair/wrongKey")
        XCTAssertTrue(app.el("pair.alarm").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Reject on your Mac (host)'")).firstMatch.exists)
        XCTAssertFalse(app.el("pair.sas").exists)
        XCTAssertFalse(app.el("pair.certCode").exists)
    }

    @MainActor
    func testCodeExpiryClearsCodeAndDisablesApprovalEverywhere() {
        let app = launch("pair/certCode")
        XCTAssertTrue(app.el("pair.certCode").waitForExistence(timeout: 10))
        app.buttons["demo.primaryPanel.show"].tap()
        XCTAssertTrue(app.buttons["demo.primaryPanel.approve"].waitForExistence(timeout: 5))
        app.buttons["demo.primaryPanel.expire"].tap()
        XCTAssertTrue(app.el("demo.primaryPanel.none").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["demo.primaryPanel.approve"].exists)
        app.buttons["demo.primaryPanel.close"].tap()
        XCTAssertTrue(app.el("pair.expired").waitForExistence(timeout: 5))
        XCTAssertFalse(app.el("pair.certCode").exists)
    }

    @MainActor
    func testCertPendingExpires() {
        let app = launch("pair/certPending")
        XCTAssertTrue(app.el("pair.openPrimary").waitForExistence(timeout: 10))
        app.buttons["demo.primaryPanel.show"].tap()
        app.buttons["demo.primaryPanel.elapse"].tap()
        XCTAssertTrue(app.el("pair.expired").waitForExistence(timeout: 5))
        XCTAssertFalse(app.el("pair.openPrimary").exists)
    }

    @MainActor
    func testScannerSaysNotAvailableInThisBuild() {
        let app = launch("pair")
        app.buttons["pair.scan"].tap()
        XCTAssertTrue(app.staticTexts["Scanning isn't available in this build"].waitForExistence(timeout: 5))
    }
}
