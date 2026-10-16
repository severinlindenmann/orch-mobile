import XCTest
import OrchProtocol
@testable import Orch

/// C2b increment 5: the Simulator convenience lane is compiled only into a Debug Simulator build, and only the OrchDevSandbox variant turns
/// it on. This test runs in the normal `Orch` app in both configurations (`scripts/check-release-flags.sh` runs it under Release).
@MainActor final class LaneAbsenceTests: XCTestCase {
    func testPhoneActorTakesConvenienceOnlyWhereTheLaneIsCompiled() throws {
        let id = try XCTUnwrap(ID16(hex: "00112233445566778899aabbccddeeff"))
        #if DEBUG && targetEnvironment(simulator)
        XCTAssertNoThrow(try PhoneActor(person: id, device: id, auth: .convenience))
        #else
        XCTAssertThrowsError(try PhoneActor(person: id, device: id, auth: .convenience))
        #endif
        // the two credentials every build knows
        XCTAssertNoThrow(try PhoneActor(person: id, device: id, auth: .secureEnclaveUnlocked))
        XCTAssertNoThrow(try PhoneActor(person: id, device: id, auth: .passphrase))
        for other in F1Auth.allCases where ![.secureEnclaveUnlocked, .passphrase, .convenience].contains(other) {
            XCTAssertThrowsError(try PhoneActor(person: id, device: id, auth: other))
        }
    }

    /// The normal app never enables the lane: its Live origin rule is `https` only, the variant's is not compiled in.
    func testTheNormalAppAcceptsOnlyHTTPSLiveOrigins() {
        #if !ORCH_DEV_SANDBOX
        XCTAssertTrue(LiveServices.isLiveOrigin("https://relay.example.org"))
        XCTAssertFalse(LiveServices.isLiveOrigin("http://127.0.0.1:8123"))
        XCTAssertFalse(LiveServices.isLiveOrigin("http://[::1]:8123"))
        #endif
    }
}
