import XCTest

/// Pairing on the real client stack: the PairingCoordinator talks to the in-process Demo relay, host and primary; the Demo panels play
/// the humans (explicit approvals only).
final class PairingTests: XCTestCase {
    @MainActor
    func testPasteToReadyThroughDemoPanels() {
        let app = launch("pair", seed: false)
        // The Demo host's Remote tab makes the link; the person pastes it on the phone.
        XCTAssertTrue(app.buttons["demo.hostPanel.show"].waitForExistence(timeout: Self.slow))
        app.buttons["demo.hostPanel.show"].tap()
        let newLink = app.buttons["demo.hostPanel.newLink"]
        XCTAssertTrue(app.reveal(newLink, timeout: 10))
        newLink.tap()
        let link = app.el("demo.hostPanel.link")
        XCTAssertTrue(app.reveal(link, timeout: 30))
        let text = link.label
        XCTAssertTrue(text.hasPrefix("https://relay.demo.invalid/app/pair#v2."), text)
        app.buttons["demo.hostPanel.close"].tap()
        let field = app.textFields["pair.paste"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(text)
        app.buttons["pair.submit"].tap()

        approveOnDemoHost(app)
        openRequestOnDemoPrimary(app)
        let primaryApprove = app.buttons["demo.primaryPanel.approve"]
        XCTAssertTrue(primaryApprove.waitForExistence(timeout: Self.slow), "the primary shows its own code after the phone's poll")
        XCTAssertFalse(primaryApprove.isEnabled)
        app.switches["demo.primaryPanel.compared"].flip()
        XCTAssertTrue(primaryApprove.waitForEnabled())
        // The phone shows the cert code behind the panel; dismiss it to compare.
        app.buttons["demo.primaryPanel.close"].tap()
        let phoneCode = app.el("pair.certCode")
        XCTAssertTrue(phoneCode.waitForExistence(timeout: 5))
        app.buttons["demo.primaryPanel.show"].tap()
        app.switches["demo.primaryPanel.compared"].flip()
        app.buttons["demo.primaryPanel.approve"].tap()
        XCTAssertTrue(app.el("pair.ready").waitForExistence(timeout: Self.slow))
        app.buttons["pair.done"].tap()
        XCTAssertTrue(app.workspaceCard("Laptop").waitForExistence(timeout: 10))
    }

    @MainActor
    func testDemoInvitationPairsAndWorkspaceHasRealContent() {
        let app = launch("pair", seed: false)
        startDemoInvitation(app)
        approveOnDemoHost(app)
        openRequestOnDemoPrimary(app)
        XCTAssertTrue(app.el("demo.primaryPanel.code").waitForExistence(timeout: Self.slow))
        app.switches["demo.primaryPanel.compared"].flip()
        app.buttons["demo.primaryPanel.approve"].tap()
        XCTAssertTrue(app.el("pair.ready").waitForExistence(timeout: Self.slow))
        app.buttons["pair.done"].tap()
        XCTAssertTrue(app.workspaceCard("Laptop").waitForExistence(timeout: 10))
        XCTAssertTrue(app.el("home.needsYou").waitForExistence(timeout: Self.slow), "questions come from the host's verified snapshot")
    }

    @MainActor
    func testInvalidLinkIsRefusedWithFixedText() {
        let app = launch("pair", seed: false)
        let field = app.textFields["pair.paste"]
        XCTAssertTrue(field.waitForExistence(timeout: 60))
        field.tap()
        field.typeText("https://evil.example/app/pair#x")
        app.buttons["pair.submit"].tap()
        XCTAssertTrue(app.el("pair.refused").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This isn't an orch pairing link"].exists)
    }

    @MainActor
    func testForeignOriginWithValidShapeIsRefused() {
        let app = launch("pair", seed: false)
        let field = app.textFields["pair.paste"]
        XCTAssertTrue(field.waitForExistence(timeout: 60))
        field.tap()
        let id = String(repeating: "a", count: 32), pin = String(repeating: "A", count: 43)
        field.typeText("https://relay.example.com/app/pair#v2.\(id).\(id).\(pin).\(pin).\(pin)")
        app.buttons["pair.submit"].tap()
        XCTAssertTrue(app.el("pair.refused").waitForExistence(timeout: 10), "Demo may reach only the in-process relay")
    }

    @MainActor
    func testScanShowsCameraUnavailable() {
        let app = launch("pair", seed: false)
        app.buttons["pair.scan"].tap()
        XCTAssertTrue(app.el("pair.scan.unavailable").waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["Scanning isn't available in this build"].exists)
    }

    @MainActor
    func testR1AlarmHidesBothCodes() {
        let app = launch("pair/r1", seed: false)
        startDemoInvitation(app)
        approveOnDemoHost(app)
        openRequestOnDemoPrimary(app)
        XCTAssertTrue(app.el("pair.alarm").waitForExistence(timeout: Self.slow))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Reject on Demo Mac'")).firstMatch.exists)
        XCTAssertFalse(app.el("pair.sas").exists)
        XCTAssertFalse(app.el("pair.certCode").exists)
    }

    @MainActor
    func testWrongKeyAlarmHidesBothCodes() {
        let app = launch("pair/wrongKey", seed: false)
        startDemoInvitation(app)
        XCTAssertTrue(app.el("pair.alarm").waitForExistence(timeout: Self.slow))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Reject on your Mac (host)'")).firstMatch.exists)
        XCTAssertFalse(app.el("pair.sas").exists)
        XCTAssertFalse(app.el("pair.certCode").exists)
    }

    @MainActor
    func testLinkUsedByAnotherIsRefused() {
        let app = launch("pair/linkUsed", seed: false)
        startDemoInvitation(app)
        XCTAssertTrue(app.el("pair.refused").waitForExistence(timeout: Self.slow))
        XCTAssertTrue(app.staticTexts["This link was already used"].exists)
    }

    @MainActor
    func testRejectOnHostRefuses() {
        let app = launch("pair", seed: false)
        startDemoInvitation(app)
        XCTAssertTrue(app.el("pair.sas").waitForExistence(timeout: Self.slow))
        app.buttons["demo.hostPanel.show"].tap()
        XCTAssertTrue(app.buttons["demo.hostPanel.reject"].waitForExistence(timeout: Self.slow))
        app.buttons["demo.hostPanel.reject"].tap()
        XCTAssertTrue(app.el("pair.refused").waitForExistence(timeout: Self.slow))
    }

    @MainActor
    func testCodeExpiryClearsCodeAndDisablesApprovalEverywhere() {
        let app = launch("pair", seed: false)
        startDemoInvitation(app)
        approveOnDemoHost(app)
        openRequestOnDemoPrimary(app)
        let expire = app.buttons["demo.primaryPanel.expire"]
        XCTAssertTrue(app.reveal(expire))
        expire.tap()
        XCTAssertTrue(app.el("demo.primaryPanel.none").waitForExistence(timeout: Self.slow))
        XCTAssertFalse(app.buttons["demo.primaryPanel.approve"].exists)
        app.buttons["demo.primaryPanel.close"].tap()
        XCTAssertTrue(app.el("pair.expired").waitForExistence(timeout: Self.slow))
        XCTAssertFalse(app.el("pair.certCode").exists)
    }

    @MainActor
    func testCertPendingExpires() {
        let app = launch("pair/primaryOffline", seed: false)
        startDemoInvitation(app)
        approveOnDemoHost(app)
        XCTAssertTrue(app.el("pair.openPrimary").waitForExistence(timeout: Self.slow))
        app.buttons["demo.primaryPanel.show"].tap()
        app.buttons["demo.primaryPanel.elapse"].tap()
        XCTAssertTrue(app.el("pair.expired").waitForExistence(timeout: Self.slow))
        XCTAssertFalse(app.el("pair.openPrimary").exists)
    }
}
