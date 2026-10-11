import XCTest

final class DropTests: XCTestCase {
    @MainActor
    func testReceivedAndSending() {
        let app = launch("drop")
        XCTAssertTrue(app.el("drop.item.d-readme").waitForExistence(timeout: 60))
        app.segmentedControls["drop.direction"].buttons["Sending"].tap()
        XCTAssertTrue(app.el("drop.item.d-sending").waitForExistence(timeout: 5))
    }

    @MainActor
    func testComposeNeedsDestinationFirst() {
        let app = launch("drop/compose")
        let send = app.buttons["drop.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 60))
        XCTAssertFalse(send.isEnabled)
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'drop.destination.' AND label CONTAINS 'Laptop'")).firstMatch.tap()
        app.textFields["drop.note"].tap()
        app.textFields["drop.note"].typeText("hello")
        XCTAssertTrue(send.isEnabled)
        send.tap()
        XCTAssertTrue(app.segmentedControls["drop.direction"].waitForExistence(timeout: 5))
        let note = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'note.txt' AND label CONTAINS 'Sent (confirmed)'")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 30))
    }

    @MainActor
    func testRealFileTransferIsConfirmed() {
        let app = launch("drop/compose")
        XCTAssertTrue(app.el("drop.demoLabel").waitForExistence(timeout: 60))
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'drop.destination.' AND label CONTAINS 'Laptop'")).firstMatch.tap()
        app.buttons["drop.sample"].tap()
        app.buttons["drop.send"].tap()
        let done = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Sent (confirmed)'")).firstMatch
        let combined = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Sent (confirmed)'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 60) || combined.waitForExistence(timeout: 2))
    }
}

extension DropTests {
    @MainActor
    func testVerifiedPreviewEmptyNoteAndLiteralURL() {
        let app = launch("drop")
        let readme = app.el("drop.item.d-readme")
        XCTAssertTrue(readme.waitForExistence(timeout: 90)); readme.tap()
        XCTAssertTrue(app.buttons["drop.open"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["drop.open"].isEnabled)
        app.buttons["drop.open"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.el("drop.item.d-empty").tap()
        XCTAssertTrue(app.staticTexts["This file is empty."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["drop.open"].isEnabled)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.el("drop.item.d-note").tap()
        XCTAssertTrue(app.el("drop.item.text").waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.el("drop.item.d-url").tap()
        XCTAssertTrue(app.el("drop.item.text").waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["drop.open"].isEnabled)
    }

    @MainActor
    func testInboxClaimAndLookOnlyDenial() {
        let app = launch("drop")
        XCTAssertTrue(app.el("drop.item.d-deploy").waitForExistence(timeout: 90))
        app.el("drop.item.d-deploy").tap()
        XCTAssertTrue(app.buttons["drop.claim"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["drop.claim"].isEnabled)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.reveal(app.buttons["drop.demo.inbox"], timeout: 15))
        app.buttons["drop.demo.inbox"].tap()
        let encrypted = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'drop.item.' AND label CONTAINS 'Encrypted item'")).firstMatch
        XCTAssertTrue(encrypted.waitForExistence(timeout: 15)); encrypted.tap()
        XCTAssertTrue(app.buttons["drop.claim"].isEnabled)
        app.buttons["drop.claim"].tap()
        XCTAssertTrue(app.staticTexts["claim.txt"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["drop.open"].isEnabled)
    }

    @MainActor
    func testFailedUploadRetryAndStop() {
        let app = launch("drop")
        XCTAssertTrue(app.reveal(app.buttons["drop.demo.reject"], timeout: 90))
        for retry in [true, false] {
            XCTAssertTrue(app.reveal(app.buttons["drop.demo.reject"], timeout: 15))
            app.buttons["drop.demo.reject"].tap()
            app.buttons["drop.compose"].tap()
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'drop.destination.' AND label CONTAINS 'Laptop'")).firstMatch.tap()
            app.buttons["drop.sample"].tap()
            app.buttons["drop.send"].tap()
            let action = app.buttons[retry ? "drop.retry" : "drop.stop"].firstMatch
            XCTAssertTrue(action.waitForExistence(timeout: 30)); action.tap()
            let status = app.staticTexts["drop.status"]
            expectation(for: NSPredicate(format: "label CONTAINS %@", retry ? "Sent (confirmed)" : "Stopped sending"), evaluatedWith: status)
            waitForExpectations(timeout: 30)
        }
    }

    @MainActor
    func testForegroundResumesPendingUpload() {
        let app = launch("drop")
        XCTAssertTrue(app.reveal(app.buttons["drop.demo.pending"], timeout: 90))
        app.buttons["drop.demo.pending"].tap()
        let status = app.staticTexts["drop.status"]
        expectation(for: NSPredicate(format: "label CONTAINS 'retry later'"), evaluatedWith: status)
        waitForExpectations(timeout: 20)
        XCUIDevice.shared.press(.home)
        app.activate()
        for _ in 0..<3 { app.swipeDown() }
        app.segmentedControls["drop.direction"].buttons["Sending"].tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'note.txt' AND label CONTAINS 'Sent (confirmed)'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
    }

    @MainActor
    func testForegroundExpiryRemovesVerifiedRows() {
        let app = launch("drop")
        XCTAssertTrue(app.el("drop.item.d-readme").waitForExistence(timeout: 90))
        XCTAssertTrue(app.reveal(app.buttons["drop.demo.expire"], timeout: 15))
        app.buttons["drop.demo.expire"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.el("drop.item.d-readme"))
        waitForExpectations(timeout: 20)
    }
}
