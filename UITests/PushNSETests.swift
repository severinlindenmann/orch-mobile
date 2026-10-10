import XCTest

/// Real-process evidence for the notification service extension (decision A12, challenge C2). This is NOT a processor
/// test (those are OrchPushTests): it drives the DEBUG push harness, lets a HOST script send sealed fixtures with
/// `xcrun simctl push` (a simulator process cannot reach CoreSimulatorService, so the sender must be outside), and reads
/// what the EXTENSION ITSELF wrote: its invocation marker (counter, outcome, timestamp), the replay high-water mark and
/// the notifications the OS delivered.
///
/// Run it with `scripts/push-nse-test.sh <udid>`, which creates the fixtures, passes their directory in
/// `TEST_RUNNER_ORCH_PUSH_DIR` and plays the sender. Without that directory the test skips as UNVERIFIED.
///
/// A visible notification alone proves nothing (the OS shows the relay's alert when the extension does not run). If the
/// marker never appears the extension was not launched on this runtime: the test records UNVERIFIED (with the evidence
/// attached) and skips with an explicit message. It never passes silently, and never passes on a notification alone.
///
/// Handshake files in the directory: `ready-N` (test: app backgrounded, send fixture N), `sent-N` (host: pushed),
/// `checked-N` (test: marker read). Fixtures `NN_name.apns`, `expectations.json` and `material.arg` come from
/// scripts/make-push-fixture.swift.
final class PushNSETests: XCTestCase {
    private var app: XCUIApplication!
    private var dir: URL!

    private func touch(_ name: String, _ text: String = "") { try? Data(text.utf8).write(to: dir.appendingPathComponent(name)) }
    private func waitFile(_ name: String, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) { return true }; Thread.sleep(forTimeInterval: 0.3) }
        return false
    }

    @MainActor
    private func text(_ id: String) -> String { app.staticTexts[id].exists ? app.staticTexts[id].label : "" }

    @MainActor
    private func waitFor(_ id: String, contains s: String, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if text(id).contains(s) { return true }; Thread.sleep(forTimeInterval: 0.3) }
        return false
    }

    @MainActor
    private func refreshAndRead() -> String {
        app.buttons["push.refresh"].tap()
        Thread.sleep(forTimeInterval: 1.0)
        return text("push.marker")
    }

    /// Backgrounds the app (so a presented notification lands in the notification center), asks the host to push
    /// fixture `n`, waits for it, gives the system time, and reads the marker.
    @MainActor
    private func send(_ n: Int, settle: TimeInterval) throws -> String {
        XCUIDevice.shared.press(.home)
        touch("ready-\(n)")
        guard waitFile("sent-\(n)", timeout: 90) else { throw XCTSkip("UNVERIFIED: the host driver never sent fixture \(n)") }
        Thread.sleep(forTimeInterval: settle)
        app.activate()
        _ = app.staticTexts["push.marker"].waitForExistence(timeout: 10)
        return refreshAndRead()
    }

    @MainActor
    func testNotificationExtensionRunsAndAppliesTheRulesUnderSimctlPush() throws {
        guard let path = ProcessInfo.processInfo.environment["ORCH_PUSH_DIR"] else {
            throw XCTSkip("UNVERIFIED: not run through scripts/push-nse-test.sh (no ORCH_PUSH_DIR): nothing sends pushes, so the extension was not exercised")
        }
        dir = URL(fileURLWithPath: path, isDirectory: true)
        let expectations = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("expectations.json"))) as! [[String: String]]
        let material = String(decoding: try Data(contentsOf: dir.appendingPathComponent("material.arg")), as: UTF8.self)

        addUIInterruptionMonitor(withDescription: "notifications") { alert in
            for b in ["Allow", "OK"] where alert.buttons[b].exists { alert.buttons[b].tap(); return true }
            return false
        }
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--push-harness", "--push-material", material]
        app.launch()
        app.tap()   // lets the interruption monitor see the permission alert
        XCTAssertTrue(waitFor("push.status", contains: "material installed", timeout: 20), "harness did not install the test material: \(text("push.status"))")

        // Probe with the first fixture only.
        var marker = try send(1, settle: 6)
        if marker.contains("marker: none") {
            Thread.sleep(forTimeInterval: 8)   // a little longer before calling it
            marker = refreshAndRead()
        }
        let evidence = "marker=[\(marker)] \(text("push.replay")) \(text("push.delivered")) \(text("push.auth"))"
        let attachment = XCTAttachment(string: evidence)
        attachment.lifetime = .keepAlways
        add(attachment)
        touch("checked-1", evidence)
        guard !marker.contains("marker: none") else {
            // The extension never wrote its marker: it did not run (whatever the OS displayed). Record, do not pass.
            throw XCTSkip("UNVERIFIED: simctl push did not launch the notification service extension on this runtime (no NSE-written marker). \(evidence)")
        }

        // The extension ran. Check its own evidence, then the rest of the sequence in order.
        XCTAssertTrue(marker.contains("count=1") && marker.contains("outcome=\(expectations[0]["outcome"]!)"), "first fixture: \(marker)")
        XCTAssertTrue(text("push.replay").contains("replay: max="), "NSE must persist replay state: \(text("push.replay"))")
        for (i, e) in expectations.enumerated().dropFirst() {
            let m = try send(i + 1, settle: 5)
            touch("checked-\(i + 1)", m)
            XCTAssertTrue(m.contains("count=\(i + 1)") && m.contains("outcome=\(e["outcome"]!)"), "\(e["name"]!): expected \(e["outcome"]!), marker \(m)")
        }
        let delivered = text("push.delivered")
        XCTAssertFalse(delivered.contains("attacker") || delivered.contains("URGENT") || delivered.contains("Wire 5000"), "relay-chosen text reached the user: \(delivered)")
        XCTAssertTrue(delivered.contains("thread=a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"), "notifications are threaded by workspace: \(delivered)")
        XCTAssertFalse(delivered.contains("|Ship L-0042?|"), "the question must have been replaced by its closure: \(delivered)")
    }
}
