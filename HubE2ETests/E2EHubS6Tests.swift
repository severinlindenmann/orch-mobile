import CryptoKit
import XCTest

/// Simulator end to end for the hub scenario S6 (B7): the real app (Debug) pairs with a real local hub from the §6.4 link, lists the
/// workspaces the hub grants, and (with `ORCH_E2E_HUB_SIGN=1`) signs a question answer with the Simulator's Face ID. Skipped unless
/// `TEST_RUNNER_ORCH_E2E_HUB_LINK` is set; `scripts/e2e/hub-s6.sh` (kit scenario hub-S6) sets everything. Environment (un-prefixed names):
///   ORCH_E2E_HUB_LINK         the `orch://hub-pair/...` link from `orch-hub channels pair-code --link`
///   ORCH_E2E_HUB_FINGERPRINT  the fingerprint the admin console shows next to the QR code (8 groups)
///   ORCH_E2E_HUB_PASSWORD     alice's hub password          ORCH_E2E_HUB_TOTP_SECRET  her authenticator secret (base32)
///   ORCH_E2E_HUB_TOTP_LAST    the last 30 s step the driver used (a step works once)
///   ORCH_E2E_HUB_WS           comma list of the 4-character prefixes of the workspaces the list must show
///   ORCH_E2E_HUB_NOT_WS       comma list of prefixes it must NOT show
///   ORCH_E2E_HUB_QUESTION     text of the question to answer          ORCH_E2E_HUB_OPTION  the option to choose
///   ORCH_E2E_HUB_SIGN         "1" to run the sign step              ORCH_E2E_DIR  work dir: events are appended to `<dir>/events`
/// Each result is also printed as `ORCH_E2E_HUB <event>` (a fallback when the simulator cannot write the file).
final class E2EHubS6Tests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testPairListSign() throws {
        guard let link = env["ORCH_E2E_HUB_LINK"], !link.isEmpty else {
            throw XCTSkip("ORCH_E2E_HUB_LINK (TEST_RUNNER_ORCH_E2E_HUB_LINK) is not set: this test needs the hub-S6 lane")
        }
        let password = env["ORCH_E2E_HUB_PASSWORD"] ?? ""
        let secret = env["ORCH_E2E_HUB_TOTP_SECRET"] ?? ""
        XCTAssertFalse(password.isEmpty || secret.isEmpty, "step 0: password and TOTP secret are required")
        let app = XCUIApplication()
        app.launchArguments = ["--hub-pair"]
        app.launch()

        // 1. The link into the pairing screen; the fingerprint is compared with the admin console's before any password.
        let field = app.el("hub.link")
        XCTAssertTrue(field.waitForExistence(timeout: 60), "step 1: the pairing screen (hub.link) did not appear")
        enter(field, link, secure: false, what: "the pairing link")
        app.el("hub.continue").tap()
        let fp = app.el("hub.fingerprint")
        let failure = app.el("hub.failure")
        wait(until: { fp.exists || failure.exists }, timeout: 90)
        XCTAssertFalse(failure.exists, "step 1: the app refused the link: \(failure.label)")
        XCTAssertTrue(fp.exists, "step 1: no fingerprint within 90 s")
        let shown = Self.groups(fp.label), want = Self.groups(env["ORCH_E2E_HUB_FINGERPRINT"] ?? "")
        XCTAssertFalse(want.isEmpty, "step 1: ORCH_E2E_HUB_FINGERPRINT is not set")
        XCTAssertEqual(shown, want, "step 1: the fingerprint on the phone is not the one the hub admin sees")

        // 2. Password and a fresh code.
        enter(app.el("hub.password"), password, secure: true, what: "the password")
        let code = Self.totp(secret: secret, after: Int(env["ORCH_E2E_HUB_TOTP_LAST"] ?? "") ?? 0)
        enter(app.el("hub.totp"), code, secure: false, what: "the authenticator code")
        let pair = app.buttons["hub.pair"]
        wait(until: { pair.exists && pair.isEnabled }, timeout: 10)
        pair.tap()
        let paired = app.el("hub.paired")
        wait(until: { paired.exists || app.el("hub.failure").exists }, timeout: 120)
        XCTAssertFalse(app.el("hub.failure").exists, "step 2: pairing failed: \(app.el("hub.failure").label)")
        XCTAssertTrue(paired.exists, "step 2: not paired within 120 s")
        event("pair ok")

        // 3. The home: exactly the workspaces the hub grants.
        app.buttons["hub.done"].tap()
        let want4 = Self.list(env["ORCH_E2E_HUB_WS"]), not4 = Self.list(env["ORCH_E2E_HUB_NOT_WS"])
        let sections = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'hubhome.ws.'"))
        wait(until: { sections.count >= want4.count || app.el("hubhome.empty").exists || app.el("hubhome.signin").exists }, timeout: 90)
        let got = Set((0..<sections.count).map { String(sections.element(boundBy: $0).identifier.dropFirst("hubhome.ws.".count)) })
        event("list " + got.sorted().joined(separator: ","))
        XCTAssertEqual(got, Set(want4), "step 3: the phone lists \(got.sorted()), the hub grants \(want4.sorted())")
        XCTAssertTrue(got.isDisjoint(with: not4), "step 3: the phone lists a workspace the hub does not grant")

        // 4. Tap-sign (B3): the question, the review, Face ID.
        guard env["ORCH_E2E_HUB_SIGN"] == "1" else { return }
        try signStep(app)
    }

    // MARK: sign (B3)

    @MainActor
    private func signStep(_ app: XCUIApplication) throws {
        let text = env["ORCH_E2E_HUB_QUESTION"] ?? ""
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Question' AND label CONTAINS %@", text)).firstMatch
        var tries = 0
        while !row.exists, tries < 6 { app.swipeDown(); Thread.sleep(forTimeInterval: 5); tries += 1 }
        if !row.exists { print("ORCH_E2E_TREE \(app.debugDescription)") }
        XCTAssertTrue(row.exists, "step 4: the question is not on the phone's list")
        row.tap()
        let choose = app.buttons[env["ORCH_E2E_HUB_OPTION"] ?? ""] // by label: the item's container identifier hides `hubitem.option.<key>` (backlog issue)
        if !choose.waitForExistence(timeout: 60) { print("ORCH_E2E_TREE \(app.debugDescription)") }
        XCTAssertTrue(choose.exists, "step 4: no sign choice for the question")
        choose.tap()
        let confirm = app.buttons["hubsign.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 60), "step 4: the review (hubsign.confirm) did not appear")
        event("faceid wanted")
        confirm.tap()
        let signed = app.el("hubsign.signed")
        wait(until: { signed.exists || app.el("hubsign.failure").exists }, timeout: 120)
        XCTAssertFalse(app.el("hubsign.failure").exists, "step 4: signing failed: \(app.el("hubsign.failure").label)")
        XCTAssertTrue(signed.exists, "step 4: not signed within 120 s")
        event("signed")
        if app.buttons["hubsign.done"].exists { app.buttons["hubsign.done"].tap() }
    }

    // MARK: helpers

    @MainActor
    private func wait(until done: () -> Bool, timeout: TimeInterval) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !done() { Thread.sleep(forTimeInterval: 0.5) }
    }

    /// Types into a field and checks what it holds (typeText can drop characters on a slow simulator); one retry. Secure fields are not read back.
    @MainActor
    private func enter(_ el: XCUIElement, _ text: String, secure: Bool, what: String) {
        XCTAssertTrue(el.waitForExistence(timeout: 30), "\(what): the field did not appear")
        el.tap()
        el.typeText(text)
        if secure {
            // a secure field shows bullets: compare the length, retype once when characters were dropped
            let n = (el.value as? String)?.count ?? 0
            if n != text.count {
                print("ORCH_E2E_NOTE \(what): field holds \(n) of \(text.count) characters, retyping")
                el.press(forDuration: 1.0)
                if XCUIApplication().menuItems["Select All"].waitForExistence(timeout: 3) { XCUIApplication().menuItems["Select All"].tap() }
                el.typeText(text)
                XCTAssertEqual((el.value as? String)?.count ?? 0, text.count, "\(what): the typed text has the wrong length after a retry")
            }
            return
        }
        if (el.value as? String) != text {
            el.press(forDuration: 1.0)
            if XCUIApplication().menuItems["Select All"].waitForExistence(timeout: 3) { XCUIApplication().menuItems["Select All"].tap() }
            el.typeText(text)
            XCTAssertEqual(el.value as? String, text, "\(what): the typed text does not match after a retry")
        }
    }

    /// Appends the event to `<ORCH_E2E_DIR>/events` and prints it.
    private func event(_ line: String) {
        print("ORCH_E2E_HUB \(line)")
        guard let dir = env["ORCH_E2E_DIR"], !dir.isEmpty else { return }
        let fd = open(dir + "/events", O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { print("ORCH_E2E_NOTE could not open \(dir)/events: errno \(errno)"); return }
        defer { close(fd) }
        let bytes = Array((line + "\n").utf8)
        _ = write(fd, bytes, bytes.count)
    }

    static func list(_ s: String?) -> [String] { (s ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty } }

    /// The groups of a fingerprint, whatever the line breaks (the phone shows two rows of four).
    static func groups(_ s: String) -> [String] { s.split(whereSeparator: { $0.isWhitespace }).map { String($0).lowercased() } }

    /// RFC 6238 (SHA-1, 6 digits, 30 s): the code for the smallest step above `last` and not older than the previous step. The hub takes the
    /// previous, current and next step, each once; when the window is used up, wait for the next step.
    static func totp(secret: String, after last: Int) -> String {
        var now = Int(Date().timeIntervalSince1970) / 30
        let step = max(last + 1, now)  // the current step, not the previous one: typing takes seconds and the step may roll over
        while step > now + 1 { Thread.sleep(forTimeInterval: 1); now = Int(Date().timeIntervalSince1970) / 30 }
        let key = SymmetricKey(data: base32(secret))
        var counter = UInt64(step).bigEndian
        let mac = withUnsafeBytes(of: &counter) { Array(HMAC<Insecure.SHA1>.authenticationCode(for: Data($0), using: key)) }
        let off = Int(mac[mac.count - 1] & 15)
        let v = (UInt32(mac[off] & 0x7F) << 24) | (UInt32(mac[off + 1]) << 16) | (UInt32(mac[off + 2]) << 8) | UInt32(mac[off + 3])
        return String(format: "%06d", v % 1_000_000)
    }

    static func base32(_ s: String) -> Data {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, acc = 0
        var out = Data()
        for ch in s.uppercased() where ch != "=" {
            guard let v = alphabet.firstIndex(of: ch) else { continue }
            acc = (acc << 5) | v; bits += 5
            if bits >= 8 { bits -= 8; out.append(UInt8((acc >> bits) & 0xFF)) }
        }
        return out
    }
}

extension XCUIApplication {
    func el(_ id: String) -> XCUIElement { descendants(matching: .any).matching(identifier: id).firstMatch }
}
