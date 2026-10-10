import XCTest
@testable import Orch

final class LaunchOptionsTests: XCTestCase {
    private let all = ["orch", "--ui-testing", "--demo"]

    func testDebugParsesFlags() {
        let flags = LaunchOptions.parse(arguments: all, debug: true)
        XCTAssertTrue(flags.demo)
        XCTAssertTrue(flags.uiTesting)
        let defaults = LaunchOptions.parse(arguments: ["orch"], debug: true)
        XCTAssertFalse(defaults.demo)
        XCTAssertFalse(defaults.uiTesting)
        XCTAssertEqual(LaunchOptions.parse(arguments: ["orch", "--demo=false", "--unknown"], debug: true), defaults)
    }

    func testReleaseIgnoresAllFlags() {
        let flags = LaunchOptions.parse(arguments: all, debug: false)
        XCTAssertFalse(flags.demo)
        XCTAssertFalse(flags.uiTesting)
    }

    func testDefaultInitMatchesBuildConfiguration() {
        #if DEBUG
        XCTAssertEqual(LaunchOptions(arguments: all), LaunchOptions.parse(arguments: all, debug: true))
        #else
        XCTAssertEqual(LaunchOptions(arguments: all), LaunchOptions.parse(arguments: all, debug: false))
        #endif
    }
}
