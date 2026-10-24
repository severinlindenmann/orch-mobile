import Foundation
import OrchProtocol
import XCTest
@testable import Orch

final class APNsTokenStoreTests: XCTestCase {
    func testTokenStoredPerInstallationAndChangeDetected() {
        let defaults = UserDefaults(suiteName: "orch.test.\(UUID().uuidString)")!
        defaults.set("legacy", forKey: "orch.apns.token")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("apns-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let s = APNsTokenStore(url: url, legacyDefaults: defaults)
        XCTAssertNil(defaults.string(forKey: "orch.apns.token"), "the old UserDefaults copy is removed")
        XCTAssertNil(s.stored)
        XCTAssertTrue(s.save(deviceToken: Data([1, 2, 3]), environment: .sandbox))
        XCTAssertEqual(s.stored, .init(token: B64U.encode(Data([1, 2, 3])), environment: .sandbox))
        XCTAssertFalse(s.save(deviceToken: Data([1, 2, 3]), environment: .sandbox), "same token: nothing to re-register")
        XCTAssertTrue(s.save(deviceToken: Data([1, 2, 3]), environment: .production), "environment change counts")
        XCTAssertTrue(s.save(deviceToken: Data([9]), environment: .production))
        XCTAssertEqual(try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        s.clear()
        XCTAssertNil(s.stored)
    }

    func testEnvironmentFollowsTheSigningNotTheBuildConfiguration() {
        // The test host runs on the Simulator: no APNs environment, whatever the configuration says.
        XCTAssertNil(APNsEnvironment.current)
        XCTAssertEqual(APNsEnvironment.resolve(provisioningProfile: nil, isSimulator: false), .production)
    }

    func testReleaseIgnoresPushHarnessFlags() {
        let args = ["orch", "--push-harness", "--push-material", "x:y"]
        XCTAssertFalse(LaunchOptions.parse(arguments: args, debug: false).pushHarness)
        XCTAssertNil(LaunchOptions.parse(arguments: args, debug: false).pushMaterial)
        XCTAssertTrue(LaunchOptions.parse(arguments: args, debug: true).pushHarness)
    }
}
