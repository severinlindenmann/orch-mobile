import XCTest

/// Real-process evidence for the hub push path of the notification service extension (design B4): the DEBUG push harness installs a hub
/// push material item (the push key only), a HOST script (`scripts/hub-push-nse-test.sh`) plays the APNs sender with `xcrun simctl push`, and the test reads
/// what the EXTENSION wrote: its marker and the notifications the OS delivered. A visible notification alone proves nothing: the marker must show the
/// extension ran, else the test records UNVERIFIED and skips. Handshake files: `ready-N`, `sent-N`, `checked-N`.
final class HubPushNSETests: XCTestCase {
    private var app: XCUIApplication!
    private var dir: URL!

    private func touch(_ name: String, _ text: String = "") { try? Data(text.utf8).write(to: dir.appendingPathComponent(name)) }
    private func waitFile(_ name: String, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) { return true }; Thread.sleep(forTimeInterval: 0.3) }
        return false
    }
    @MainActor private func text(_ id: String) -> String { app.staticTexts[id].exists ? app.staticTexts[id].label : "" }
    @MainActor private func refresh() -> String { app.buttons["push.refresh"].tap(); Thread.sleep(forTimeInterval: 1.0); return text("push.marker") }

    @MainActor
    private func send(_ n: Int, settle: TimeInterval) throws -> String {
        XCUIDevice.shared.press(.home)
        touch("ready-\(n)")
        guard waitFile("sent-\(n)", timeout: 90) else { throw XCTSkip("UNVERIFIED: the host driver never sent fixture \(n)") }
        Thread.sleep(forTimeInterval: settle)
        app.activate()
        _ = app.staticTexts["push.marker"].waitForExistence(timeout: 10)
        return refresh()
    }

    @MainActor
    func testHubPushesAreOpenedWithThePushKeyAndShowFixedText() throws {
        guard let path = ProcessInfo.processInfo.environment["ORCH_PUSH_DIR"] else {
            throw XCTSkip("UNVERIFIED: not run through scripts/hub-push-nse-test.sh (no ORCH_PUSH_DIR)")
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
        app.tap()
        let end = Date().addingTimeInterval(20)
        while Date() < end, !text("push.status").contains("material installed") { Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertTrue(text("push.status").contains("material installed"), "harness did not install the hub material: \(text("push.status"))")

        for (i, e) in expectations.enumerated() {
            var marker = try send(i + 1, settle: i == 0 ? 6 : 5)
            if i == 0, marker.contains("marker: none") { Thread.sleep(forTimeInterval: 8); marker = refresh() }
            let delivered = text("push.delivered")
            let evidence = "marker=[\(marker)] \(delivered)"
            let attachment = XCTAttachment(string: evidence); attachment.lifetime = .keepAlways; add(attachment)
            touch("checked-\(i + 1)", evidence)
            if i == 0, marker.contains("marker: none") { throw XCTSkip("UNVERIFIED: simctl push did not launch the notification service extension (no NSE-written marker). \(evidence)") }
            XCTAssertTrue(marker.contains("count=\(i + 1)") && marker.contains("outcome=\(e["outcome"]!)"), "\(e["name"]!): expected \(e["outcome"]!), marker \(marker)")
            if e["body"] == "generic" {
                XCTAssertTrue(delivered.contains("|New activity in orch|"), "\(e["name"]!): a drop must show the generic text: \(delivered)")
            } else {
                XCTAssertTrue(delivered.contains("[\(e["title"]!)|\(e["body"]!)|"), "\(e["name"]!): expected the hub label and fixed text: \(delivered)")
            }
        }
    }
}
