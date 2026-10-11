import XCTest
@testable import Orch

final class MappingTests: XCTestCase {
    func testHexIsLowercaseAndFixedWidth() {
        XCTAssertEqual(Mapping.hex(Data([0x00, 0x0a, 0xff])), "000aff")
    }

    func testScopesIgnoreUnknownNames() {
        XCTAssertEqual(Mapping.scopes(["look", "decide", "drop:read", "bogus"]), [.look, .decide])
    }

    func testDateIsMilliseconds() {
        XCTAssertEqual(Mapping.date(1_500).timeIntervalSince1970, 1.5, accuracy: 0.0001)
    }

    @MainActor
    func testReleaseStyleOptionsHaveNoLiveSeed() {
        let release = LaunchOptions.parse(arguments: ["orch", "--demo-seed", "--ui-preview"], debug: false)
        XCTAssertFalse(release.demoSeed)
        XCTAssertFalse(release.uiPreview)
        let debug = LaunchOptions.parse(arguments: ["orch", "--demo-seed", "--ui-preview"], debug: true)
        XCTAssertTrue(debug.demoSeed)
        XCTAssertTrue(debug.uiPreview)
    }

    @MainActor
    func testUnknownAliasesResolveToNothingBeforeAnyWorkspace() {
        let services = LiveServices(options: LaunchOptions.parse(arguments: ["orch"], debug: true))
        XCTAssertNil(services.resolveQuestion("q1"))
        XCTAssertNil(services.resolveWorkspace("laptop"))
        XCTAssertTrue(services.workspaces.isEmpty)
        XCTAssertFalse(services.isDemo)
    }

    /// Under the Release configuration (scripts/check-release-flags.sh) the default initialiser must ignore every debug flag.
    func testDefaultInitIgnoresDebugFlagsInRelease() {
        let all = ["orch", "--ui-testing", "--demo", "--demo-seed", "--ui-preview", "--push-harness", "--initial-route", "pair",
                   "--seed-share-quarantine", "--hold-share-import", "--share-demo-targets"]
        let options = LaunchOptions(arguments: all)
        #if DEBUG
        XCTAssertTrue(options.demoSeed && options.uiPreview && options.demo)
        #else
        XCTAssertFalse(options.demoSeed || options.uiPreview || options.demo || options.uiTesting || options.pushHarness)
        XCTAssertNil(options.initialRoute)
        XCTAssertFalse(options.seedShareQuarantine || options.holdShareImport || options.shareDemoTargets)
        #endif
    }
}
