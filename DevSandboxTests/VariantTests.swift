import XCTest
import OrchClient
import OrchProtocol
@testable import OrchDevSandbox

/// The OrchDevSandbox variant (host 11A.17): what only this build does. Runs on the Simulator with the lane compiled in.
@MainActor final class VariantTests: XCTestCase {
    func testTheLaneIsCompiledIn() throws {
        let id = try XCTUnwrap(ID16(hex: "00112233445566778899aabbccddeeff"))
        XCTAssertNoThrow(try PhoneActor(person: id, device: id, auth: .convenience))
    }

    func testBannerAndRefusalTextsAreExact() {
        XCTAssertEqual(DevSandboxText.banner("a1b2c3d4"), "DEV SANDBOX: convenience signing · a1b2c3d4")
        XCTAssertEqual(DevSandboxText.hostRefuses, "This host does not accept Simulator answers")
        XCTAssertEqual(DevSandboxText.footnote,
                       "Signed with this Simulator's software key (convenience, no presence check). Only this throwaway dev sandbox accepts it.")
        XCTAssertEqual(DevSandboxText.notASandbox, "Not a dev sandbox. Remove this Simulator on your Mac.")
    }

    func testWriteBlockOnTheLaneShowsTheExactRefusal() {
        // the lane is on but the last read carried no `relay.dev`: the exact text; off the lane the old text stays
        XCTAssertEqual(QuestionScreen.writeBlock(writes: true, writeSupport: false, simulatorLane: true), "This host does not accept Simulator answers")
        XCTAssertEqual(QuestionScreen.writeBlock(writes: true, writeSupport: false), "Your Mac's orch doesn't accept answers from iPhone yet. Answer on your Mac.")
        XCTAssertNil(QuestionScreen.writeBlock(writes: true, writeSupport: true, simulatorLane: true))
    }

    func testTheVariantTalksToTheDevRelayAndALoopbackRelayOnly() {
        XCTAssertTrue(LiveServices.isLiveOrigin("https://relay.dev.severin.io"))
        XCTAssertTrue(LiveServices.isLiveOrigin("http://127.0.0.1:8123"))
        XCTAssertTrue(LiveServices.isLiveOrigin("http://[::1]:8123"))
        XCTAssertFalse(LiveServices.isLiveOrigin("https://relay.example.org"))
        XCTAssertFalse(LiveServices.isLiveOrigin("https://tix.severin.io"))
        XCTAssertFalse(LiveServices.isLiveOrigin("http://relay.dev.severin.io"))
        XCTAssertFalse(LiveServices.isLiveOrigin("http://localhost:8123"))
        XCTAssertFalse(LiveServices.isLiveOrigin("http://127.0.0.1"))      // a loopback origin needs its port
    }

    func testNotADevSandboxBlocksAnswersAndNamesTheWay() {
        var info = WorkspaceInfo(id: "w", name: "n", host: "h", hue: 0, hostedBy: nil, clientHosted: false, scopes: [.decide], connection: .online,
                                 primaryLabel: "p", notificationsOn: false)
        XCTAssertNil(info.answerBlock)
        info.notADevSandbox = true
        XCTAssertEqual(info.answerBlock, "Not a dev sandbox. Remove this Simulator on your Mac.")
    }

    func testTheVariantIsItsOwnApp() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "io.severin.orch.devsandbox")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "OrchKeychainGroupBase") as? String, "io.severin.orch.devsandbox")
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes"))        // no `orch://` claim
    }
}
