import XCTest

/// Simulator end to end (batch B3): pairs the OrchDevSandbox variant with a throwaway `dev-pair up` sandbox through relay.dev, answers the
/// question the script created and waits for the settled "answered" state. Skipped unless `TEST_RUNNER_ORCH_E2E_LINK` is set
/// (xcodebuild hands `TEST_RUNNER_<NAME>` to the runner as `<NAME>`); the kit scenario `e2e/scenarios/sim-pair-answer.sh` sets it.
///
/// Environment (read as the un-prefixed names):
///   ORCH_E2E_LINK   the pairing link (`https://relay.dev.severin.io/app/pair#v2.<ws>.<offer>.<S>.<wsk_pin>.<pk_pin>`)
///   ORCH_E2E_CODES  file the host reads (`dev-pair up --expect-code-from`); one line `<offer_id> <sas|cert_code> <CODE>` is appended per code
///   ORCH_E2E_NONCE  the nonce the question carries
/// Every code is also printed as `ORCH_E2E_CODE <offer_id> <phase> <CODE>` (a fallback the script can relay when the file is not writable).
final class E2EPairAnswerTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPairAndAnswer() throws {
        guard let link = env["ORCH_E2E_LINK"], !link.isEmpty else {
            throw XCTSkip("ORCH_E2E_LINK (TEST_RUNNER_ORCH_E2E_LINK) is not set: this test needs a running dev-pair sandbox")
        }
        let nonce = env["ORCH_E2E_NONCE"] ?? ""
        let codesPath = env["ORCH_E2E_CODES"] ?? ""
        guard let offerID = Self.offerID(inLink: link) else {
            XCTFail("step 0: the link has no v2.<ws>.<offer>.<S>.<wsk_pin>.<pk_pin> fragment")
            return
        }
        XCTAssertFalse(nonce.isEmpty, "step 0: ORCH_E2E_NONCE is not set")

        let app = XCUIApplication()
        app.launchArguments = []
        app.launch()

        // 1. Enter the link (typed into the Live entry field; the scanner has no camera, the paste button asks the user).
        try startPairing(app)
        let field = app.el("live.paste")
        XCTAssertTrue(field.waitForExistence(timeout: 30), "step 1: the Live entry (live.paste) did not appear")
        field.tap()
        field.typeText(link)
        if app.buttons["live.keyboardDone"].waitForExistence(timeout: 5) { app.buttons["live.keyboardDone"].tap() }
        let review = app.buttons["live.review"]
        expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: review)
        waitForExpectations(timeout: 15)
        review.tap()
        if app.el("invitation.refused").waitForExistence(timeout: 3) {
            XCTFail("step 1: the variant refused the link as an invitation: \(app.el("invitation.refused").label)")
            return
        }
        if app.el("live.paste.error").exists {
            XCTFail("step 1: the link was rejected inline: \(app.el("live.paste.error").label)")
            return
        }

        // 2. Review: nothing connects until Connect.
        let connect = app.buttons["review.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 20), "step 2: the review screen (review.connect) did not appear")
        connect.tap()

        // 3. Pairing: the SAS, then (after the host approves) the certification code. Both are reported to the script.
        let sas = app.el("pair.sas")
        let sasEnd = Date().addingTimeInterval(90)
        while Date() < sasEnd, !sas.exists, !app.el("pair.refused").exists, !app.el("pair.alarm").exists { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertTrue(sas.exists, "step 3: the SAS did not appear within 90 s (pairing state: \(pairingState(app)))")
        report(offerID, "sas", Self.code(from: sas.label), to: codesPath)
        // The SAS shows until the host approves; the cert code appears when the primary step starts (dev-pair plays the primary).
        let cert = app.el("pair.certCode")
        let ready = app.el("pair.ready")
        let end = Date().addingTimeInterval(240)
        while Date() < end, !cert.exists, !ready.exists, !app.el("pair.refused").exists, !app.el("pair.alarm").exists { Thread.sleep(forTimeInterval: 0.5) }
        if app.el("pair.refused").exists || app.el("pair.alarm").exists {
            XCTFail("step 3: pairing was refused or alarmed after the SAS (state: \(pairingState(app)))")
            return
        }
        if cert.exists {
            report(offerID, "cert_code", Self.code(from: cert.label), to: codesPath)
        } else if !ready.exists {
            XCTFail("step 3: neither the certification code nor the joined state appeared within 240 s (state: \(pairingState(app)))")
            return
        }
        XCTAssertTrue(ready.waitForExistence(timeout: 240), "step 3: pairing did not finish (pair.ready) within 240 s (state: \(pairingState(app)))")
        let done = app.buttons["pair.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "step 3: no Done button after the join")
        done.tap()

        // 4. The joined workspace: the DEV SANDBOX banner.
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'home.workspace.'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 60), "step 4: no workspace card on Home after the join")
        card.tap()
        XCTAssertTrue(app.el("devsandbox.banner").waitForExistence(timeout: 60), "step 4: no DEV SANDBOX banner in the joined workspace")
        XCTAssertFalse(app.el("devsandbox.notSandbox").exists, "step 4: the host does not say this is a dev sandbox")

        // 5. The question carrying the nonce (<= 180 s; the workspace is re-opened every 30 s to read afresh).
        let row = app.questionRow(nonce)
        let waitEnd = Date().addingTimeInterval(180)
        var lastReopen = Date()
        while Date() < waitEnd, !row.exists {
            Thread.sleep(forTimeInterval: 1)
            if Date().timeIntervalSince(lastReopen) > 30 { lastReopen = Date(); reopenWorkspace(app) }
        }
        if !row.exists {
            let macOnly = app.el("ws.macOnly")
            XCTFail("step 5: no open question with the nonce within 180 s"
                + (macOnly.exists ? " (the workspace says \"\(macOnly.label)\": the phone cannot answer a free-text question, give the question options)" : ""))
            return
        }
        row.tap()

        // 6. Answer: the option labelled `e2e-ok-<nonce>` if there is one, else the first option; convenience signing.
        let wanted = NSPredicate(format: "identifier BEGINSWITH 'question.option.' AND NOT (identifier BEGINSWITH 'question.option.cost.')")
        let options = app.descendants(matching: .any).matching(wanted)
        XCTAssertTrue(options.firstMatch.waitForExistence(timeout: 30), "step 6: the question shows no options to choose from (free text is answered on the Mac)")
        let named = options.matching(NSPredicate(format: "label CONTAINS %@", "e2e-ok-\(nonce)")).firstMatch
        (named.exists ? named : options.firstMatch).tap()
        let confirm = app.buttons["sign.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 60), "step 6: the sign sheet (sign.confirm) did not appear: \(signState(app))")
        XCTAssertTrue(arm(app, confirm), "step 6: Sign and send never became enabled")
        confirm.tap()

        // 7. Settled.
        let accepted = app.el("sign.accepted")
        let settle = Date().addingTimeInterval(120)
        while Date() < settle, !accepted.exists, !app.el("sign.resent").exists, !app.el("sign.landedUnconfirmed").exists {
            if app.buttons["sign.recheck"].exists, app.buttons["sign.recheck"].isHittable { app.buttons["sign.recheck"].tap() }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(accepted.exists || app.el("sign.resent").exists || app.el("sign.landedUnconfirmed").exists,
                      "step 7: the answer was not settled within 120 s: \(signState(app))")
        if app.buttons["sign.done"].exists { app.buttons["sign.done"].tap() }
        let resolution = app.el("question.resolution")
        XCTAssertTrue(resolution.waitForExistence(timeout: 60), "step 7: the question never showed the answered state (question.resolution)")
        XCTAssertTrue(resolution.label.contains("Answered by"), "step 7: unexpected resolution: \(resolution.label)")
    }

    // MARK: Helpers

    /// Welcome (fresh install) -> pair; an install that already has Live (a local re-run) is left first.
    @MainActor
    private func startPairing(_ app: XCUIApplication) throws {
        let pair = app.buttons["welcome.pair"]
        if pair.waitForExistence(timeout: 60) { pair.tap(); return }
        // A previous run left Live installed: remove it through Settings, then pair again.
        if !app.buttons["live.settings"].exists, app.buttons["home.settings"].exists { app.buttons["home.settings"].tap() } else { app.buttons["live.settings"].tap() }
        let leave = app.buttons["settings.leaveLive"]
        var tries = 0
        while !(leave.exists && leave.isHittable) && tries < 12 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(leave.exists, "step 0: neither Welcome nor a way to leave the previous Live install")
        leave.tap()
        app.buttons["settings.leaveLive.confirm"].firstMatch.tap()
        XCTAssertTrue(pair.waitForExistence(timeout: 60), "step 0: Welcome did not return after leaving the previous Live install")
        pair.tap()
    }

    @MainActor
    private func reopenWorkspace(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        guard back.exists, back.isHittable else { return }
        back.tap()
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'home.workspace.'")).firstMatch
        if card.waitForExistence(timeout: 10) { card.tap() }
    }

    @MainActor
    private func arm(_ app: XCUIApplication, _ confirm: XCUIElement, timeout: TimeInterval = 40) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        var swipes = 0
        while Date() < end {
            if confirm.exists && confirm.isEnabled { return true }
            if swipes < 12 { app.swipeUp(velocity: .fast); swipes += 1 }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return confirm.exists && confirm.isEnabled
    }

    @MainActor
    private func pairingState(_ app: XCUIApplication) -> String {
        for id in ["pair.connecting", "pair.sas", "pair.openPrimary", "pair.certCode", "pair.certCodeHidden", "pair.joining", "pair.ready",
                   "pair.refused", "pair.alarm", "pair.obscured", "invitation.refused"] where app.el(id).exists { return id }
        return "unknown"
    }

    @MainActor
    private func signState(_ app: XCUIApplication) -> String {
        for id in ["sign.loading", "sign.loadFailed", "sign.refused", "sign.sending", "sign.checking", "sign.accepted", "sign.alreadyAnswered",
                   "sign.refused.host", "sign.questionChanged", "sign.needsReview", "sign.notSent", "sign.custody", "sign.workspaceChanged"]
            where app.el(id).exists { return id }
        return "unknown"
    }

    /// `<offer_id> <phase> <CODE>` to the script's file (append + flush; the simulator may not be able to write it) and to stdout.
    private func report(_ offerID: String, _ phase: String, _ code: String, to path: String) {
        XCTAssertFalse(code.isEmpty, "the \(phase) code could not be read from the screen")
        print("ORCH_E2E_CODE \(offerID) \(phase) \(code)")
        guard !path.isEmpty else { return }
        let line = Array("\(offerID) \(phase) \(code)\n".utf8)
        // POSIX open: the path is usually the script's FIFO (no seeking; a non-blocking open fails at once when nobody reads it).
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NONBLOCK, 0o600)
        guard fd >= 0 else {
            print("ORCH_E2E_NOTE could not open \(path): errno \(errno) (the stdout line is the fallback)")
            return
        }
        defer { close(fd) }
        if write(fd, line, line.count) != line.count {
            print("ORCH_E2E_NOTE could not write \(path): errno \(errno) (the stdout line is the fallback)")
        }
    }

    /// The offer id: the third dot-separated part of the `v2.` fragment.
    static func offerID(inLink link: String) -> String? {
        guard let hash = link.firstIndex(of: "#") else { return nil }
        let parts = link[link.index(after: hash)...].split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 6, parts[0] == "v2", !parts[2].isEmpty else { return nil }
        return String(parts[2])
    }

    /// The code from a CodeDisplay label (`"<title>. Code 1 2 3 4 5 6."`): the characters after "Code ", spaces removed.
    static func code(from label: String) -> String {
        guard let r = label.range(of: "Code ", options: .backwards) else { return "" }
        return label[r.upperBound...].filter { !$0.isWhitespace && $0 != "." }
    }
}

extension XCUIApplication {
    func el(_ id: String) -> XCUIElement { descendants(matching: .any).matching(identifier: id).firstMatch }
    func questionRow(_ text: String) -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'question.' AND label CONTAINS %@", text)).firstMatch
    }
}
