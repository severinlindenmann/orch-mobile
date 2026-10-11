import XCTest

/// Decision T2: drives the REAL installed share extension process through a genuine UIActivityViewController
/// (presented by the DEBUG fixture screen). Nothing here reproduces the compose view inside the app.
final class ShareExtensionTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Presents the system share sheet for `fixtureButton` and picks orch's extension.
    @MainActor
    private func openExtension(_ app: XCUIApplication, fixtureButton: String, useMore: Bool = false) {
        XCTAssertTrue(app.buttons[fixtureButton].waitForExistence(timeout: 90))
        app.buttons[fixtureButton].tap()
        let orch = app.cells["orch"]
        if useMore || !orch.waitForExistence(timeout: 90) {
            // The extension may be hidden behind "More" on a fresh runtime: open it, find orch in the list, enable it.
            let more = app.cells["More"]
            XCTAssertTrue(more.exists, "neither orch nor More is offered in the share sheet")
            more.tap()
            // "Apps" list: the row is a table cell. (A bare label query also matches the app's own "orch" back button.)
            let row = app.tables.cells.containing(.staticText, identifier: "orch").firstMatch
            guard row.waitForExistence(timeout: 90) else {
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.lifetime = .keepAlways; add(shot)
                add(XCTAttachment(string: app.debugDescription))
                XCTFail("orch is not listed in the More (Apps) list"); return
            }
            row.tap()
            return
        }
        orch.tap()
    }

    @MainActor
    private func stage(fixture: String, expectKinds: [String], file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        let app = launch("share-fixture", extra: ["--hold-share-import", "--share-demo-targets"])
        openExtension(app, fixtureButton: fixture)
        // The extension's own UI: destination first, then Save to send.
        let laptop = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'share.destination.' AND label CONTAINS 'Laptop'")).firstMatch
        XCTAssertTrue(laptop.waitForExistence(timeout: 15), app.debugDescription, file: file, line: line)
        let save = app.buttons["share.save"]
        XCTAssertFalse(save.isEnabled, "Save is disabled until a destination is chosen", file: file, line: line)
        laptop.tap()
        XCTAssertTrue(save.isEnabled, file: file, line: line)
        save.tap()
        XCTAssertTrue(app.staticTexts["Saved. Open orch to send."].waitForExistence(timeout: 15), file: file, line: line)
        app.buttons["share.done"].tap()
        // Back in the app: the extension-written READY job is on disk, not yet imported.
        let inspect = app.buttons["share.fixture.inspect"]
        XCTAssertTrue(inspect.waitForExistence(timeout: 90), file: file, line: line)
        inspect.tap()
        let status = app.staticTexts["share.fixture.status"]
        let expected = "ready jobs: 1 items: " + expectKinds.sorted().joined(separator: ",")
        XCTAssertTrue(status.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(status.label, expected, file: file, line: line)
        return app
    }

    @MainActor
    private func assertImported(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["share.fixture.import"].tap()
        app.buttons["share.fixture.drop"].tap()
        XCTAssertTrue(app.segmentedControls["drop.direction"].waitForExistence(timeout: 90)); app.segmentedControls["drop.direction"].buttons["Sending"].tap()
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'drop.item.share-' AND label CONTAINS 'Sent (confirmed)'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 90), app.debugDescription, file: file, line: line)
        XCTAssertTrue(app.staticTexts["drop.status"].waitForExistence(timeout: 10))
        let confirmed = NSPredicate(format: "label == %@", "Share import confirmed; plaintext cleanup complete")
        expectation(for: confirmed, evaluatedWith: app.staticTexts["drop.status"])
        waitForExpectations(timeout: 30)
        // Plaintext is deleted after confirmed import and cleanup.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["share.fixture.inspect"].tap()
        XCTAssertEqual(app.staticTexts["share.fixture.status"].label, "ready jobs: 0 items: ", file: file, line: line)
    }

    @MainActor func testExtensionCanBeSelectedFromMore() {
        let app = launch("share-fixture", extra: ["--hold-share-import", "--share-demo-targets"])
        openExtension(app, fixtureButton: "share.fixture.text", useMore: true)
        XCTAssertTrue(app.buttons["share.cancel"].waitForExistence(timeout: 15))
        app.buttons["share.cancel"].tap()
    }

    @MainActor func testFileItemIsStagedByTheExtensionAndImported() {
        let app = stage(fixture: "share.fixture.file", expectKinds: ["file"])
        assertImported(app)
    }

    @MainActor func testTextItemIsStagedByTheExtensionAndImported() {
        let app = stage(fixture: "share.fixture.text", expectKinds: ["text"])
        assertImported(app)
    }

    @MainActor func testURLItemIsStagedAsTextAndImported() {
        let app = stage(fixture: "share.fixture.url", expectKinds: ["url"])
        assertImported(app)
        // The link is shown as text, never opened.
        app.buttons["share.fixture.drop"].tap()
        XCTAssertTrue(app.segmentedControls["drop.direction"].waitForExistence(timeout: 90)); app.segmentedControls["drop.direction"].buttons["Sending"].tap()
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'drop.item.share-' AND label CONTAINS 'Sent (confirmed)'")).firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["drop.item.text"].waitForExistence(timeout: 5))
    }

    @MainActor func testMixedFileTextAndLink() {
        let app = launch("share-fixture", extra: ["--hold-share-import", "--share-demo-targets"])
        openExtension(app, fixtureButton: "share.fixture.mixed")
        let laptop = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'share.destination.' AND label CONTAINS 'Laptop'")).firstMatch
        XCTAssertTrue(laptop.waitForExistence(timeout: 15))
        laptop.tap()
        app.buttons["share.save"].tap()
        XCTAssertTrue(app.staticTexts["Saved. Open orch to send."].waitForExistence(timeout: 15))
        app.buttons["share.done"].tap()
        app.buttons["share.fixture.inspect"].tap()
        let label = app.staticTexts["share.fixture.status"].label
        XCTAssertTrue(label.hasPrefix("ready jobs: 1 items: "), label)
        XCTAssertGreaterThanOrEqual(label.split(separator: ",").count, 2, label)
    }

    @MainActor func testCancelLeavesNothingStaged() {
        let app = launch("share-fixture", extra: ["--hold-share-import", "--share-demo-targets"])
        openExtension(app, fixtureButton: "share.fixture.file")
        XCTAssertTrue(app.buttons["share.cancel"].waitForExistence(timeout: 15))
        app.buttons["share.cancel"].tap()
        let inspect = app.buttons["share.fixture.inspect"]
        XCTAssertTrue(inspect.waitForExistence(timeout: 90))
        // Cancelling the extension returns to the system share sheet; close it.
        let close = app.buttons["Close"]
        if close.waitForExistence(timeout: 5) { close.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap() }
        sleep(2)
        inspect.tap()
        XCTAssertEqual(app.staticTexts["share.fixture.status"].label, "ready jobs: 0 items: ")
    }

    @MainActor func testQuarantinedJobAsksForAnotherDestinationAndNeverRedirectsItself() {
        let app = launch("drop", extra: ["--seed-share-quarantine", "--share-demo-targets"])
        XCTAssertTrue(app.segmentedControls["drop.direction"].waitForExistence(timeout: 90)); app.segmentedControls["drop.direction"].buttons["Sending"].tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'drop.item.share-q-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 90))
        XCTAssertTrue(row.label.contains("Choose another destination"), row.label)
        row.tap()
        let target = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'drop.redirect.' AND label CONTAINS 'Laptop'")).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'drop.item.share-' AND NOT identifier BEGINSWITH 'drop.item.share-q-'")).firstMatch.waitForExistence(timeout: 90))
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'drop.item.share-q-'")).firstMatch.exists)
    }
}
