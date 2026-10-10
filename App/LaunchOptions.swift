import Foundation

struct LaunchOptions: Equatable, Sendable {
    let uiTesting: Bool
    let demo: Bool
    /// DEBUG-only deep route for UI tests and screenshots (A13), e.g. `pair/sas`, `sign/q2`.
    let initialRoute: String?
    /// DEBUG-only `--appearance dark|light`, so UI tests do not depend on simulator state.
    let appearance: String?
    /// DEBUG-only `--push-harness`: shows the NSE test harness instead of Home (push simulator tests, see UITests/PushNSETests).
    let pushHarness: Bool
    /// DEBUG-only `--push-material <base64url>`: a test `PushMaterial` item for the fixture workspace A, installed into the `.push` keychain group.
    let pushMaterial: String?

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        #if DEBUG
        self = Self.parse(arguments: arguments, debug: true)
        #else
        self = Self.parse(arguments: arguments, debug: false)
        #endif
    }

    private init(uiTesting: Bool, demo: Bool, initialRoute: String?, appearance: String?, pushHarness: Bool = false, pushMaterial: String? = nil) {
        self.pushHarness = pushHarness
        self.pushMaterial = pushMaterial
        self.uiTesting = uiTesting
        self.demo = demo
        self.initialRoute = initialRoute
        self.appearance = appearance
    }

    /// Release builds (`debug == false`) ignore every flag.
    static func parse(arguments: [String], debug: Bool) -> LaunchOptions {
        guard debug else { return LaunchOptions(uiTesting: false, demo: false, initialRoute: nil, appearance: nil) }
        var route: String?
        var appearance: String?
        if let i = arguments.firstIndex(of: "--appearance"), arguments.indices.contains(i + 1) { appearance = arguments[i + 1] }
        if let i = arguments.firstIndex(of: "--initial-route"), arguments.indices.contains(i + 1) {
            route = arguments[i + 1]
        }
        var material: String?
        if let i = arguments.firstIndex(of: "--push-material"), arguments.indices.contains(i + 1) { material = arguments[i + 1] }
        return LaunchOptions(uiTesting: arguments.contains("--ui-testing"),
                             demo: arguments.contains("--demo"), initialRoute: route, appearance: appearance,
                             pushHarness: arguments.contains("--push-harness"), pushMaterial: material)
    }
}
