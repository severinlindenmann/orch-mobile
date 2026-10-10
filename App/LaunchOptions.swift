import Foundation

struct LaunchOptions: Equatable, Sendable {
    let uiTesting: Bool
    let demo: Bool

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        #if DEBUG
        uiTesting = arguments.contains("--ui-testing")
        demo = arguments.contains("--demo")
        #else
        uiTesting = false
        demo = false
        #endif
    }
}
