import XCTest

extension XCTestCase {
    @MainActor
    func launch(_ route: String? = nil, demo: Bool = true, dark: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["--ui-testing"]
        if demo { args.append("--demo") }
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
}

extension XCUIElement {
    /// Form toggles: tap the switch itself (right edge), not the label.
    func flip() {
        coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }
}

extension XCUIElement {
    func waitForEnabled(_ timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if exists && isEnabled { return true }; Thread.sleep(forTimeInterval: 0.2) }
        return false
    }
}
