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
    }

    @MainActor
    func testSimulatedTransferTerminates() {
        let app = launch("drop/compose")
        XCTAssertTrue(app.el("drop.demoLabel").waitForExistence(timeout: 60))
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'drop.destination.' AND label CONTAINS 'Laptop'")).firstMatch.tap()
        app.buttons["drop.sample"].tap()
        app.buttons["drop.send"].tap()
        let done = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Sent (simulated)'")).firstMatch
        let combined = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Sent (simulated)'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 60) || combined.waitForExistence(timeout: 2))
    }
}
