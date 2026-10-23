#if DEBUG
import XCTest
import OrchClient
@testable import Orch

/// The DEBUG hub pairing screen's model over the in-process fake hub: scan/paste -> fingerprint -> password and code -> paired, and the
/// refusal texts a person reads. The checks themselves are covered in OrchKit (HubPairingTests, HubVectorTests).
@MainActor
final class HubPairingModelTests: XCTestCase {
    private func wait(_ m: HubPairingModel, until done: (HubPairingState) -> Bool) async {
        for _ in 0..<200 where !done(m.state) { try? await Task.sleep(for: .milliseconds(25)) }
    }

    func testFakeHubFlowReachesPaired() async throws {
        let m = HubPairingModel.fake(script: nil)
        let hub = try XCTUnwrap(m.fake)
        XCTAssertEqual(m.state, .idle)
        m.start()
        await wait(m) { if case .confirm = $0 { return true }; return false }
        guard case .confirm(let preview) = m.state else { return XCTFail("no confirm: \(m.state)") }
        XCTAssertEqual(preview.hubID, hub.hubID)
        XCTAssertEqual(preview.host, "hub.dev.orch.example")
        XCTAssertEqual(hub.log, ["GET /api/v1/hub/card"], "no password before the card and the signed origin verified")
        m.password = hub.password; m.totp = hub.totp
        m.pair()
        XCTAssertEqual(m.password, "", "the password leaves the model at once")
        await wait(m) { if case .paired = $0 { return true }; return false }
        guard case .paired(let s) = m.state else { return XCTFail("not paired: \(m.state)") }
        XCTAssertEqual(s.hubID, hub.hubID)
    }

    func testWrongPasswordShowsAFailureAndKeepsNothing() async throws {
        let m = HubPairingModel.fake(script: "confirm")
        await wait(m) { if case .confirm = $0 { return true }; return false }
        m.password = "wrong"; m.totp = "000000"
        m.pair()
        await wait(m) { if case .failed = $0 { return true }; return false }
        XCTAssertEqual(m.state, .failed(.badCredentials))
        m.tryAgain()
        XCTAssertEqual(m.state, .idle)
    }

    func testEveryFailureHasAPlainSentenceAndNoSecrets() {
        let all: [HubPairingFailure] = [.badLink, .alreadyPaired, .otherHub, .otherOrigin, .cardRefused("dev_refused"), .cardRefused("x"),
                                        .badCredentials, .rateLimited, .pairingCodeRejected, .noSession, .hubRefused("x"),
                                        .verification("x"), .network, .custody]
        for f in all {
            let t = HubPairingScreen.text(f)
            XCTAssertFalse(t.isEmpty)
            XCTAssertFalse(t.contains("ab12-cd34-ef56"))
        }
        XCTAssertEqual(HubPairingScreen.fingerprintRows("38d8 abed 52cc fb53 8da4 01fd 54e6 4bdc"), "38d8 abed 52cc fb53\n8da4 01fd 54e6 4bdc")
    }
}
#endif
