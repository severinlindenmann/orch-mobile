import Foundation

struct LaunchOptions: Equatable, Sendable {
    let uiTesting: Bool
    let demo: Bool
    /// DEBUG-only deep route for UI tests and screenshots (A13), e.g. `pair/sas`, `sign/q2`.
    let initialRoute: String?
    /// DEBUG-only `--appearance dark|light`, so UI tests do not depend on simulator state.
    let appearance: String?

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        #if DEBUG
        self = Self.parse(arguments: arguments, debug: true)
        #else
        self = Self.parse(arguments: arguments, debug: false)
        #endif
    }

    private init(uiTesting: Bool, demo: Bool, initialRoute: String?, appearance: String?) {
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
        return LaunchOptions(uiTesting: arguments.contains("--ui-testing"),
                             demo: arguments.contains("--demo"), initialRoute: route, appearance: appearance)
    }
}
