import XCTest
@testable import Orch

final class LaunchOptionsTests: XCTestCase {
    func testLaunchFlags() {
        let defaults = LaunchOptions(arguments: ["orch"])
        XCTAssertFalse(defaults.demo)
        XCTAssertFalse(defaults.uiTesting)
        let flags = LaunchOptions(arguments: ["orch", "--ui-testing", "--demo"])
        #if DEBUG
        XCTAssertTrue(flags.demo)
        XCTAssertTrue(flags.uiTesting)
        #else
        XCTAssertFalse(flags.demo)
        XCTAssertFalse(flags.uiTesting)
        #endif
        XCTAssertEqual(LaunchOptions(arguments: ["orch", "--demo=false", "--unknown"]), defaults)
    }
}
