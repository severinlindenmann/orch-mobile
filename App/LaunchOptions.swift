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
    /// DEBUG-only: seed a quarantined share job (destination removed) so UI tests can reach the redirect flow.
    let seedShareQuarantine: Bool
    /// DEBUG-only: no automatic share import on activation, so a test can observe the extension-written job first.
    let holdShareImport: Bool
    /// DEBUG-only: offer Demo workspaces to the share extension (they are never offered otherwise).
    let shareDemoTargets: Bool

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        #if DEBUG
        self = Self.parse(arguments: arguments, debug: true)
        #else
        self = Self.parse(arguments: arguments, debug: false)
        #endif
    }

    private init(uiTesting: Bool, demo: Bool, initialRoute: String?, appearance: String?, pushHarness: Bool = false, pushMaterial: String? = nil,
                 seedShareQuarantine: Bool = false, holdShareImport: Bool = false, shareDemoTargets: Bool = false) {
        self.pushHarness = pushHarness
        self.pushMaterial = pushMaterial
        self.uiTesting = uiTesting
        self.demo = demo
        self.initialRoute = initialRoute
        self.appearance = appearance
        self.seedShareQuarantine = seedShareQuarantine
        self.holdShareImport = holdShareImport
        self.shareDemoTargets = shareDemoTargets
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
                             pushHarness: arguments.contains("--push-harness"), pushMaterial: material,
                             seedShareQuarantine: arguments.contains("--seed-share-quarantine"),
                             holdShareImport: arguments.contains("--hold-share-import"),
                             shareDemoTargets: arguments.contains("--share-demo-targets"))
    }
}
