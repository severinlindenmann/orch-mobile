import Foundation

struct LaunchOptions: Equatable, Sendable {
    /// Reserved for UI-test-only behavior; nothing reads it yet.
    let uiTesting: Bool
    let demo: Bool

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        #if DEBUG
        self = Self.parse(arguments: arguments, debug: true)
        #else
        self = Self.parse(arguments: arguments, debug: false)
        #endif
    }

    private init(uiTesting: Bool, demo: Bool) {
        self.uiTesting = uiTesting
        self.demo = demo
    }

    /// Release builds (`debug == false`) ignore every flag.
    static func parse(arguments: [String], debug: Bool) -> LaunchOptions {
        guard debug else { return LaunchOptions(uiTesting: false, demo: false) }
        return LaunchOptions(uiTesting: arguments.contains("--ui-testing"),
                             demo: arguments.contains("--demo"))
    }
}
