import XCTest

/// Owner e2e step 16: Dynamic Type XL, XXXL and AX5 in light and dark on the real Demo stack. Every screen asserts reachability and
/// layout (not only screenshots): essential controls hittable after scrolling, nothing wider than the screen, no "…" in option labels
/// or the hosted marker, nothing hidden behind the tab bar. Screenshots are written to STEP16_SHOTS (default /private/tmp/claude-501/step16-shots).
class LargeTextBase: XCTestCase {
    enum Size: String, CaseIterable {
        case xl = "UICTContentSizeCategoryXL"
        case xxxl = "UICTContentSizeCategoryXXXL"
        case ax5 = "UICTContentSizeCategoryAccessibilityXXXL"
        var tag: String { switch self { case .xl: "xl"; case .xxxl: "xxxl"; case .ax5: "ax5" } }
        var isAX: Bool { self == .ax5 }
    }

    override func setUp() { continueAfterFailure = true }

    @MainActor
    func open(_ route: String?, _ size: Size, dark: Bool, seed: Bool = true) -> XCUIApplication {
        let app = launch(route, seed: seed, dark: dark, extra: ["-UIPreferredContentSizeCategoryName", size.rawValue])
        XCTAssertTrue(app.el("debug.scheme").waitForExistence(timeout: 120), "scheme marker")
        XCTAssertEqual(app.el("debug.scheme").value as? String, dark ? "dark" : "light")
        return app
    }

    @MainActor
    func shot(_ app: XCUIApplication, _ screen: String, _ size: Size, dark: Bool) {
        let name = "step16-\(screen)-\(size.tag)-\(dark ? "dark" : "light")"
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let dir = ProcessInfo.processInfo.environment["STEP16_SHOTS"] ?? "/private/tmp/claude-501/step16-shots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir + "/" + name + ".png"))
    }

    // MARK: Assertions

    @MainActor
    func assertFitsWidth(_ app: XCUIApplication, _ element: XCUIElement, _ what: String) {
        guard element.exists else { XCTFail("\(what) missing"); return }
        let f = element.frame, w = app.frame.width
        XCTAssertGreaterThanOrEqual(f.minX, -1, "\(what) starts left of the screen")
        XCTAssertLessThanOrEqual(f.maxX, w + 1, "\(what) runs past the right edge (\(f))")
        XCTAssertGreaterThan(f.width, 20, "\(what) squeezed to \(f.width) pt")
    }

    @MainActor
    func assertNoEllipsis(_ element: XCUIElement, _ what: String) {
        XCTAssertFalse(element.label.contains("…"), "\(what) truncated: \(element.label)")
        XCTAssertFalse(element.label.contains("..."), "\(what) truncated: \(element.label)")
    }

    /// The element can be scrolled into view and tapped.
    @MainActor
    func assertReachable(_ app: XCUIApplication, _ element: XCUIElement, _ what: String) {
        XCTAssertTrue(scrollReveal(app, element), "\(what) not found")
        XCTAssertTrue(element.isHittable, "\(what) not hittable")
        assertFitsWidth(app, element, what)
    }

    /// Scrolls with a drag from the middle (the default swipe starts at 80 % height, which can be a pinned footer or the tab bar).
    @MainActor
    func scrollReveal(_ app: XCUIApplication, _ element: XCUIElement, max: Int = 30) -> Bool {
        var tries = 0
        while !(element.exists && element.isHittable) && tries < max {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
            tries += 1
        }
        return element.exists
    }

    /// Nothing hides behind the tab bar: after scrolling to the end the element sits above it.
    @MainActor
    func assertAboveTabBar(_ app: XCUIApplication, _ element: XCUIElement, _ what: String) {
        let bar = app.tabBars.firstMatch
        guard bar.exists, element.exists else { return }
        XCTAssertLessThanOrEqual(element.frame.maxY, bar.frame.minY + 1, "\(what) is covered by the tab bar")
        XCTAssertTrue(element.isHittable, "\(what) under the tab bar is not hittable")
    }

    /// Swipes until the screen stops changing (bounded).
    @MainActor
    func scrollToEnd(_ app: XCUIApplication, max: Int = 16) {
        var last = app.screenshot().pngRepresentation
        for _ in 0..<max {
            app.swipeUp(velocity: .fast)
            let now = app.screenshot().pngRepresentation
            if now == last { break }
            last = now
        }
    }
}

final class LargeTextXLTests: LargeTextBase {
    @MainActor func testXL() { LargeTextRunner.run(self, .xl) }
}

final class LargeTextXXXLTests: LargeTextBase {
    @MainActor func testXXXL() { LargeTextRunner.run(self, .xxxl) }
}

final class LargeTextAX5Tests: LargeTextBase {
    @MainActor func testAX5() { LargeTextRunner.run(self, .ax5) }
}

enum LargeTextRunner {
    @MainActor
    static func run(_ t: LargeTextBase, _ size: LargeTextBase.Size) {
        for dark in [false, true] {
            home(t, size, dark: dark)
            questionOptions(t, size, dark: dark)
            signNormal(t, size, dark: dark)
            signUnsafe(t, size, dark: dark)
            drop(t, size, dark: dark)
            pairing(t, size, dark: dark)
            settings(t, size, dark: dark)
            workspaceSettings(t, size, dark: dark)
        }
    }

    @MainActor
    static func home(_ t: LargeTextBase, _ size: LargeTextBase.Size, dark: Bool) {
        let app = t.open(nil, size, dark: dark)
        XCTAssertTrue(app.el("home.needsYou").waitForExistence(timeout: 90))
        t.assertFitsWidth(app, app.el("home.needsYou"), "needs-you strip")
        t.shot(app, "home", size, dark: dark)
        t.assertReachable(app, app.workspaceCard("Laptop"), "Laptop card")
        t.assertReachable(app, app.workspaceCard("Client VM"), "Client VM card")
        let drop = app.el("home.drop")
        t.assertReachable(app, drop, "Drop card")
        t.scrollToEnd(app)
        t.assertAboveTabBar(app, drop, "last Home row")
        t.shot(app, "home-end", size, dark: dark)
        app.terminate()
    }

    @MainActor
    static func questionOptions(_ t: LargeTextBase, _ size: LargeTextBase.Size, dark: Bool) {
        let app = t.open("question/q1", size, dark: dark)
        let approve = app.buttons["question.option.approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 60))
        for id in ["approve", "reject"] {
            let option = app.buttons["question.option.\(id)"]
            t.assertReachable(app, option, "option \(id)")
            t.assertNoEllipsis(option, "option \(id)")
        }
        t.shot(app, "question", size, dark: dark)
        app.terminate()
        let unsafe = t.open("question/q6", size, dark: dark)
        XCTAssertTrue(unsafe.el("question.text").waitForExistence(timeout: 60))
        t.shot(unsafe, "question-unsafe-options", size, dark: dark)
        unsafe.terminate()
    }

    @MainActor
    static func signNormal(_ t: LargeTextBase, _ size: LargeTextBase.Size, dark: Bool) {
        let app = t.open("sign/q1", size, dark: dark)
        let confirm = app.buttons["sign.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 60))
        t.assertFitsWidth(app, app.el("sign.text"), "question text")
        t.assertFitsWidth(app, app.el("sign.answer"), "selected answer")
        t.assertNoEllipsis(app.el("sign.answer"), "selected answer")
        t.shot(app, "sign-sheet", size, dark: dark)
        scrollSignSheetToEnd(app, confirm)
        XCTAssertTrue(confirm.isEnabled, "Sign enabled after scrolling to the end")
        XCTAssertTrue(confirm.isHittable, "Sign hittable at the end")
        t.assertFitsWidth(app, confirm, "Sign button")
        let cancel = app.buttons["sign.cancel"]
        t.assertReachable(app, cancel, "Cancel")
        t.shot(app, "sign-sheet-end", size, dark: dark)
        app.terminate()
    }

    @MainActor
    static func scrollSignSheetToEnd(_ app: XCUIApplication, _ confirm: XCUIElement) {
        var tries = 0
        while !(confirm.isEnabled && confirm.isHittable) && tries < 30 {
            // Drag from the upper-middle: the default swipe starts at 80 % height, which can be the pinned footer.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
            tries += 1
        }
        _ = confirm.waitForEnabled(10)
    }

    @MainActor
    static func signUnsafe(_ t: LargeTextBase, _ size: LargeTextBase.Size, dark: Bool) {
        let app = t.open("sign/q3", size, dark: dark)
        let warning = app.el("sign.unsafeWarning")
        XCTAssertTrue(warning.waitForExistence(timeout: 60))
        let text = app.el("sign.text")
        XCTAssertTrue(text.label.contains("⟨U+202E⟩"), "hidden-character chips in the signed text: \(text.label)")
        XCTAssertTrue(text.label.contains("⟨U+202C⟩"))
        t.assertFitsWidth(app, text, "unsafe question text")
        let header = app.el("workspace.header")
        XCTAssertTrue(header.exists, "workspace header")
        XCTAssertTrue(header.label.lowercased().contains("hosted by"), "hosted marker: \(header.label)")
        t.assertNoEllipsis(header, "workspace host marker")
        t.assertFitsWidth(app, header, "workspace header")
        XCTAssertGreaterThan(header.frame.width, 100, "host marker squeezed: \(header.frame)")
        XCTAssertLessThan(header.frame.height, app.frame.height * 0.5, "host marker column too tall: \(header.frame)")
        t.shot(app, "sign-unsafe", size, dark: dark)
        let confirm = app.buttons["sign.confirm"]
        scrollSignSheetToEnd(app, confirm)
        XCTAssertTrue(confirm.isHittable && confirm.isEnabled, "Sign reachable at the end")
        XCTAssertTrue(warning.isHittable, "unsafe warning visible next to Sign")
        XCTAssertFalse(app.el("sign.unsafeNotice").exists, "one warning only")
        t.assertReachable(app, app.buttons["sign.cancel"], "Cancel")
        t.shot(app, "sign-unsafe-end", size, dark: dark)
        app.terminate()
        // Unsafe option labels: the sheet refuses and Cancel stays reachable.
        let refused = t.open("sign/q6", size, dark: dark)
        let notice = refused.el("sign.refused")
        XCTAssertTrue(notice.waitForExistence(timeout: 60), "unsafe options are refused")
        t.assertReachable(refused, refused.buttons["sign.cancel"], "Cancel on the refused sheet")
        XCTAssertFalse(refused.buttons["sign.confirm"].exists)
        t.shot(refused, "sign-refused", size, dark: dark)
        refused.terminate()
    }

    @MainActor
    static func drop(_ t: LargeTextBase, _ size: LargeTextBase.Size, dark: Bool) {
        let app = t.open("drop", size, dark: dark)
        let segments = app.segmentedControls["drop.direction"]
        XCTAssertTrue(segments.waitForExistence(timeout: 90))
        t.assertFitsWidth(app, segments, "direction control")
        let compose = app.buttons["drop.compose"]
        XCTAssertTrue(compose.exists && compose.isHittable, "Send button reachable")
        t.shot(app, "drop", size, dark: dark)
        t.scrollToEnd(app)
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'drop.item.'"))
        if rows.count > 0 { t.assertAboveTabBar(app, rows.element(boundBy: rows.count - 1), "last drop row") }
        t.shot(app, "drop-end", size, dark: dark)
        app.terminate()
        let sheet = t.open("drop/compose", size, dark: dark)
        let cancel = sheet.buttons["drop.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 60))
        XCTAssertTrue(cancel.isHittable, "Cancel visible on the compose sheet")
        t.shot(sheet, "drop-compose", size, dark: dark)
        t.assertReachable(sheet, sheet.buttons["drop.send"], "Send on the compose sheet")
        sheet.terminate()
    }

    @MainActor
    static func pairing(_ t: LargeTextBase, _ size: LargeTextBase.Size, dark: Bool) {
        let app = t.open("pair", size, dark: dark, seed: false)
        let demo = app.buttons["pair.demoInvitation"]
        XCTAssertTrue(demo.waitForExistence(timeout: 60))
        t.assertReachable(app, demo, "Use Demo invitation")
        t.assertReachable(app, app.buttons["pair.cancel"], "Cancel pairing")
        t.shot(app, "pairing", size, dark: dark)
        demo.tap()
        let sas = app.el("pair.sas")
        XCTAssertTrue(sas.waitForExistence(timeout: LargeTextBase.slow))
        t.assertFitsWidth(app, sas, "pairing code")
        t.assertNoEllipsis(sas, "pairing code")
        t.shot(app, "pairing-compare", size, dark: dark)
        t.assertReachable(app, app.buttons["pair.cancel"], "Cancel while comparing")
        app.terminate()
    }

    @MainActor
    static func settings(_ t: LargeTextBase, _ size: LargeTextBase.Size, dark: Bool) {
        let app = t.open("settings", size, dark: dark)
        XCTAssertTrue(app.el("settings.deviceLabel").waitForExistence(timeout: 90))
        t.shot(app, "settings", size, dark: dark)
        let reset = app.el("settings.reset")
        t.assertReachable(app, reset, "Reset this iPhone")
        t.scrollToEnd(app)
        t.assertAboveTabBar(app, reset, "last Settings row")
        t.shot(app, "settings-end", size, dark: dark)
        app.terminate()
    }

    @MainActor
    static func workspaceSettings(_ t: LargeTextBase, _ size: LargeTextBase.Size, dark: Bool) {
        let app = t.open("settings/workspace/laptop", size, dark: dark)
        let leave = app.buttons["settings.leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 90))
        t.shot(app, "settings-workspace", size, dark: dark)
        t.assertReachable(app, leave, "Leave")
        t.assertReachable(app, app.buttons["demo.push"], "Demo controls: push")
        t.scrollToEnd(app)
        t.shot(app, "settings-demo-controls", size, dark: dark)
        t.assertReachable(app, leave, "Leave after the Demo controls")
        app.terminate()
        let hosted = t.open("settings/workspace/client-vm", size, dark: dark)
        XCTAssertTrue(hosted.buttons["settings.leave"].waitForExistence(timeout: 90))
        let header = hosted.el("workspace.header")
        XCTAssertTrue(header.exists)
        XCTAssertTrue(header.label.lowercased().contains("hosted by"), header.label)
        t.assertNoEllipsis(header, "workspace host marker")
        XCTAssertGreaterThan(header.frame.width, 100, "host marker squeezed: \(header.frame)")
        t.assertReachable(hosted, hosted.buttons["settings.leave"], "Leave (hosted workspace)")
        t.shot(hosted, "settings-hosted", size, dark: dark)
        hosted.terminate()
    }
}
