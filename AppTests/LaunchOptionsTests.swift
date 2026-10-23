import XCTest
@testable import Orch

final class LaunchOptionsTests: XCTestCase {
    private let all = ["orch", "--ui-testing", "--push-harness"]

    func testDebugParsesFlags() {
        let flags = LaunchOptions.parse(arguments: all, debug: true)
        XCTAssertTrue(flags.pushHarness)
        XCTAssertTrue(flags.uiTesting)
        let defaults = LaunchOptions.parse(arguments: ["orch"], debug: true)
        XCTAssertFalse(defaults.pushHarness)
        XCTAssertFalse(defaults.uiTesting)
        XCTAssertEqual(LaunchOptions.parse(arguments: ["orch", "--push-harness=false", "--unknown"], debug: true), defaults)
    }

    func testReleaseIgnoresAllFlags() {
        let flags = LaunchOptions.parse(arguments: all, debug: false)
        XCTAssertFalse(flags.pushHarness)
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
