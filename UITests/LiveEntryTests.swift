import XCTest

/// Live entry (B2b): Welcome -> scan or paste -> review -> Connect -> pairing, orch:// opens, the Demo switch, Leave Live.
///
/// These run the real app with `--live-test-relay`: Live on a temporary disk and an in-memory keychain behind a relay that never
/// answers. The pairing therefore stays at "Connecting"; a completed Live join needs a live-realm host (real relay end to end, PR C),
/// because the Demo fakes sign with Demo authorities that a live realm refuses by design.
final class LiveEntryTests: XCTestCase {
    private let id = String(repeating: "a", count: 32)
    private var pin: String { String(repeating: "A", count: 43) }
    private var fragment: String { "v2.\(id).\(id).\(pin).\(pin).\(pin)" }
    private var pasteLink: String { "https://relay.example.org/app/pair#\(fragment)" }
    private var otherLink: String { "https://other.example.org/app/pair#\(fragment)" }
    private var orchLink: String { "orch://pair?relay=https%3A%2F%2Frelay.example.org#\(fragment)" }

    @MainActor
    private func launchLive(_ extra: [String] = []) -> XCUIApplication {
        launch(demo: false, seed: false, extra: ["--live-test-relay"] + extra)
    }

    @MainActor
    private func paste(_ app: XCUIApplication, _ text: String) {
        let field = app.el("live.paste")
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap()
        field.typeText(text)
        app.buttons["live.review"].tap()
    }

    @MainActor
    func testPasteReviewConnectPairingLeaveLive() {
        let app = launchLive()
        XCTAssertTrue(app.buttons["welcome.pair"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["Connect to orch on your Mac. Your Mac approves this iPhone."].exists)
        app.buttons["welcome.pair"].tap()
        paste(app, pasteLink)
        // Review: the reviewed origin is read-only text; nothing has connected yet.
        let origin = app.el("review.origin")
        XCTAssertTrue(origin.waitForExistence(timeout: 10))
        XCTAssertEqual(origin.label, "https://relay.example.org")
        app.buttons["review.connect"].tap()
        // Live pairing over the real coordinator (the relay never answers): the pairing screen's connecting state.
        XCTAssertTrue(app.el("pair.connecting").waitForExistence(timeout: 30))
        app.buttons["pair.cancel"].tap()
        // Live is installed now: Home is Live's (never Welcome), with the way to pair again.
        XCTAssertTrue(app.el("home.liveEmpty").waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["welcome.demo"].exists)
        app.buttons["live.settings"].tap()
        XCTAssertTrue(app.el("settings.realm").waitForExistence(timeout: 10))
        XCTAssertEqual(app.el("settings.realm.origin").label.contains("https://relay.example.org"), true)
        let leave = app.buttons["settings.leaveLive"]
        var tries = 0
        while !leave.exists && tries < 8 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(leave.exists)
        leave.tap()
        app.buttons["settings.leaveLive.confirm"].firstMatch.tap()
        XCTAssertTrue(app.buttons["welcome.demo"].waitForExistence(timeout: 30), "Leave Live returns to Welcome")
        XCTAssertTrue(app.el("realm.notice").label.contains("finish removing it on your Mac"))
    }

    @MainActor
    func testADifferentOriginIsRefusedOnAnExistingLiveInstall() {
        let app = launchLive()
        XCTAssertTrue(app.buttons["welcome.pair"].waitForExistence(timeout: 60))
        app.buttons["welcome.pair"].tap()
        paste(app, pasteLink)
        app.buttons["review.connect"].tap()
        XCTAssertTrue(app.el("pair.connecting").waitForExistence(timeout: 30))
        app.buttons["pair.cancel"].tap()
        XCTAssertTrue(app.el("home.liveEmpty").waitForExistence(timeout: 30))
        app.buttons["live.pair"].tap()
        paste(app, otherLink)
        XCTAssertTrue(app.el("invitation.refused").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["This iPhone uses a different relay"].exists)
        XCTAssertFalse(app.el("review.connect").exists)
        app.buttons["invitation.close"].tap()
        XCTAssertTrue(app.el("home.liveEmpty").waitForExistence(timeout: 10))
    }

    @MainActor
    func testAnInvalidPasteStaysOnTheEntryWithAnInlineError() {
        let app = launchLive()
        XCTAssertTrue(app.buttons["welcome.pair"].waitForExistence(timeout: 60))
        app.buttons["welcome.pair"].tap()
        paste(app, "https://evil.example/app/pair#x")
        XCTAssertTrue(app.el("live.paste.error").waitForExistence(timeout: 10))
        XCTAssertFalse(app.el("review.connect").exists)
    }

    @MainActor
    func testTheScannerExplainsWhenThereIsNoCameraAndOffersPaste() {
        let app = launchLive()
        XCTAssertTrue(app.buttons["welcome.pair"].waitForExistence(timeout: 60))
        app.buttons["welcome.pair"].tap()
        XCTAssertTrue(app.buttons["live.scan"].waitForExistence(timeout: 30))
        app.buttons["live.scan"].tap()
        XCTAssertTrue(app.el("scan.unavailable").waitForExistence(timeout: 10), "the Simulator has no camera")
        app.buttons["scan.paste"].tap()
        XCTAssertTrue(app.el("live.paste").waitForExistence(timeout: 10))
    }

    @MainActor
    func testAnOrchLinkOpenedAtLaunchLandsOnTheReviewScreenAndDoesNotConnect() {
        let app = launchLive(["--open-url", orchLink])
        XCTAssertTrue(app.el("review.origin").waitForExistence(timeout: 60))
        XCTAssertEqual(app.el("review.origin").label, "https://relay.example.org")
        XCTAssertFalse(app.el("pair.connecting").exists)
        app.buttons["live.cancel"].tap()
        XCTAssertTrue(app.buttons["welcome.pair"].waitForExistence(timeout: 10), "dismissing the review changes nothing")
    }

    @MainActor
    func testALiveLinkOpenedDuringDemoIsHeldAndNeverSwitchesWithoutConfirmation() {
        let app = launch(demo: true, seed: false, extra: ["--live-test-relay", "--open-url", orchLink])
        XCTAssertTrue(app.el("switch.title").waitForExistence(timeout: 60))
        XCTAssertFalse(app.el("review.connect").exists, "no way to connect from here")
        app.buttons["switch.keep"].tap()
        XCTAssertTrue(app.el("home.empty").waitForExistence(timeout: 10), "still in the Demo, nothing was wiped")
        XCTAssertFalse(app.buttons["welcome.demo"].exists)
    }

    @MainActor
    func testTheConfirmedSwitchLeavesDemoAndLandsOnTheReviewOfTheHeldLink() {
        let app = launch(demo: true, seed: false, extra: ["--live-test-relay", "--open-url", orchLink])
        XCTAssertTrue(app.buttons["switch.leave"].waitForExistence(timeout: 60))
        app.buttons["switch.leave"].tap()
        app.buttons["switch.leave.confirm"].firstMatch.tap()
        XCTAssertTrue(app.el("review.origin").waitForExistence(timeout: 60), "after the wipe the held link is reviewed, not connected")
        XCTAssertFalse(app.el("pair.connecting").exists)
    }
}
