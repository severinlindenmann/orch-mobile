import Foundation

/// Launch flags. Release builds ignore every one of them; the hub launch arguments (`--hub-pair`, `--hub-fake`, `--hub-sign`) are read
/// by `HubLaunch` and exist only in DEBUG.
struct LaunchOptions: Equatable, Sendable {
    let uiTesting: Bool
    /// DEBUG-only `--appearance dark|light`, so UI tests do not depend on simulator state.
    let appearance: String?
    /// DEBUG-only `--push-harness`: shows the NSE test harness instead of the hub (push simulator tests, see UITests/HubPushNSETests).
    let pushHarness: Bool
    /// DEBUG-only `--push-material <base64url>`: `hub:` + the b64u of a test hub push material item, installed into the `.push` keychain group.
    let pushMaterial: String?

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        #if DEBUG
        self = Self.parse(arguments: arguments, debug: true)
        #else
        self = Self.parse(arguments: arguments, debug: false)
        #endif
    }

    private init(uiTesting: Bool, appearance: String?, pushHarness: Bool = false, pushMaterial: String? = nil) {
        self.uiTesting = uiTesting
        self.appearance = appearance
        self.pushHarness = pushHarness
        self.pushMaterial = pushMaterial
    }

    /// Release builds (`debug == false`) ignore every flag.
    static func parse(arguments: [String], debug: Bool) -> LaunchOptions {
        guard debug else { return LaunchOptions(uiTesting: false, appearance: nil) }
        var appearance: String?
        if let i = arguments.firstIndex(of: "--appearance"), arguments.indices.contains(i + 1) { appearance = arguments[i + 1] }
        var material: String?
        if let i = arguments.firstIndex(of: "--push-material"), arguments.indices.contains(i + 1) { material = arguments[i + 1] }
        return LaunchOptions(uiTesting: arguments.contains("--ui-testing"), appearance: appearance,
                             pushHarness: arguments.contains("--push-harness"), pushMaterial: material)
    }
}
