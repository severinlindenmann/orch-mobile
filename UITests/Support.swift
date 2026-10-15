import XCTest

extension XCTestCase {
    /// Launches the app on the real Demo stack. `seed` pairs the two Demo workspaces (Laptop, Client VM) at launch, playing the Demo
    /// humans' explicit approvals on a fast Demo clock; without it the Demo is empty and tests pair through the Demo panels.
    @MainActor
    func launch(_ route: String? = nil, demo: Bool = true, seed: Bool = true, dark: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["--ui-testing"]
        if demo { args.append("--demo") }
        if demo && seed { args.append("--demo-seed") }
        if let route { args += ["--initial-route", route] }
        args += ["--appearance", dark ? "dark" : "light"]
        app.launchArguments = args + extra
        app.launch()
        return app
    }
}

extension XCUIApplication {
    /// Any element type with this identifier.
    func el(_ id: String) -> XCUIElement { descendants(matching: .any).matching(identifier: id).firstMatch }

    /// Workspace card on Home by workspace name (ids are real workspace ids).
    func workspaceCard(_ name: String) -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'home.workspace.' AND label CONTAINS %@", name)).firstMatch
    }

    /// A question row in a list by (part of) its text; ids are real question ids.
    func questionRow(_ text: String) -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'question.' AND label CONTAINS %@", text)).firstMatch
    }
}

extension XCUIElement {
    /// Form toggles: tap the switch itself (right edge), not the label.
    func flip() {
        coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    func waitForEnabled(_ timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if exists && isEnabled { return true }; Thread.sleep(forTimeInterval: 0.2) }
        return false
    }
}

extension XCUIApplication {
    /// Panels are lazy lists: rows below the fold do not exist until scrolled to.
    @discardableResult
    func reveal(_ element: XCUIElement, timeout: TimeInterval = 60) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if element.exists && element.isHittable { return true }
            if element.exists { swipeUp() } else if !element.waitForExistence(timeout: 2) { swipeUp() }
        }
        return element.exists
    }
}

/// Pairing through the Demo panels, one explicit human action per step. The real coordinator polls on its own schedule (5 to 10 s).
extension XCTestCase {
    static let slow: TimeInterval = 60

    /// From the pairing entry: "Use Demo invitation", then the code on the phone is compared on the Demo host panel.
    @MainActor
    func startDemoInvitation(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["pair.demoInvitation"].waitForExistence(timeout: Self.slow))
        app.buttons["pair.demoInvitation"].tap()
    }

    /// Host side: shown code equals the phone's; approve only after "I compared the codes".
    @MainActor
    func approveOnDemoHost(_ app: XCUIApplication) {
        let sas = app.el("pair.sas")
        XCTAssertTrue(sas.waitForExistence(timeout: Self.slow))
        XCTAssertFalse(app.el("pair.certCode").exists, "host and primary codes never coexist")
        app.buttons["demo.hostPanel.show"].tap()
        let code = app.el("demo.hostPanel.code")
        XCTAssertTrue(code.waitForExistence(timeout: Self.slow), "the host derives its own code")
        let approve = app.buttons["demo.hostPanel.approve"]
        XCTAssertTrue(app.reveal(approve, timeout: 10))
        XCTAssertFalse(approve.isEnabled)
        app.switches["demo.hostPanel.compared"].flip()
        XCTAssertTrue(approve.waitForEnabled())
        approve.tap()
    }

    /// Primary side: open the request, compare the second code, approve.
    @MainActor
    func openRequestOnDemoPrimary(_ app: XCUIApplication) {
        XCTAssertTrue(app.el("pair.openPrimary").waitForExistence(timeout: Self.slow))
        XCTAssertFalse(app.el("pair.sas").exists, "SAS is cleared on cert_pending")
        app.buttons["demo.primaryPanel.show"].tap()
        let open = app.buttons["demo.primaryPanel.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
    }
}
