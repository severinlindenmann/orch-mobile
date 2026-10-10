import Foundation

struct LaunchOptions: Equatable, Sendable {
    let uiTesting: Bool
    let demo: Bool
    /// DEBUG-only deep route for UI tests and screenshots (A13), e.g. `pair/sas`, `sign/q2`.
    let initialRoute: String?

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        #if DEBUG
        self = Self.parse(arguments: arguments, debug: true)
        #else
        self = Self.parse(arguments: arguments, debug: false)
        #endif
    }

    private init(uiTesting: Bool, demo: Bool, initialRoute: String?) {
        self.uiTesting = uiTesting
        self.demo = demo
        self.initialRoute = initialRoute
    }

    /// Release builds (`debug == false`) ignore every flag.
    static func parse(arguments: [String], debug: Bool) -> LaunchOptions {
        guard debug else { return LaunchOptions(uiTesting: false, demo: false, initialRoute: nil) }
        var route: String?
        if let i = arguments.firstIndex(of: "--initial-route"), arguments.indices.contains(i + 1) {
            route = arguments[i + 1]
        }
        return LaunchOptions(uiTesting: arguments.contains("--ui-testing"),
                             demo: arguments.contains("--demo"), initialRoute: route)
    }
}
