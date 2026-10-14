import XCTest

/// Visual follow-ups (Codex P2): writes before/after screenshots of Drop, Pairing and Settings to $P2_SHOTS (TEST_RUNNER_P2_SHOTS).
/// $P2_SIZES (comma list of default,xl,ax5; default "default") picks Dynamic Type sizes. Skips silently without $P2_SHOTS.
final class VisualP2Shots: LargeTextBase {
    @MainActor
    func testShots() throws {
        let env = ProcessInfo.processInfo.environment
        let dir = try XCTUnwrap(env["P2_SHOTS"], "P2_SHOTS not set")
        let sizes = (env["P2_SIZES"] ?? "default").split(separator: ",").map(String.init)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func snap(_ app: XCUIApplication, _ name: String) {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir + "/" + name + ".png"))
        }
        for size in sizes {
            let extra = size == "default" ? [] : ["-UIPreferredContentSizeCategoryName", (Size.allCases.first { $0.tag == size } ?? .xl).rawValue]
            for dark in [false, true] {
                let tag = "\(size)-\(dark ? "dark" : "light")"
                func open(_ route: String, seed: Bool = true) -> XCUIApplication {
                    let app = launch(route, seed: seed, dark: dark, extra: extra)
                    XCTAssertTrue(app.el("debug.scheme").waitForExistence(timeout: 120))
                    return app
                }
                let drop = open("drop")
                XCTAssertTrue(drop.segmentedControls["drop.direction"].waitForExistence(timeout: 90))
                snap(drop, "drop-\(tag)"); drop.terminate()
                let pair = open("pair", seed: false)
                XCTAssertTrue(pair.buttons["pair.demoInvitation"].waitForExistence(timeout: 60))
                snap(pair, "pairing-\(tag)"); pair.terminate()
                let settings = open("settings")
                XCTAssertTrue(settings.el("settings.deviceLabel").waitForExistence(timeout: 90))
                snap(settings, "settings-top-\(tag)")
                scrollToEnd(settings)
                snap(settings, "settings-end-\(tag)"); settings.terminate()
                let ws = open("settings/workspace/laptop")
                XCTAssertTrue(ws.el("workspace.header").waitForExistence(timeout: 90))
                scrollToEnd(ws)
                snap(ws, "demo-controls-\(tag)"); ws.terminate()
            }
        }
    }
}
