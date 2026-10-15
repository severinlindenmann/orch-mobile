import Testing
@testable import OrchUI

@Suite struct SignerLineTests {
    @Test func convenienceSaysThereWasNoPresence() {
        #expect(SignerAuthLabel.text(forWire: "convenience") == "convenience (no presence)")
        #expect(SignerAuthLabel.convenience == "convenience (no presence)")
    }
    @Test func everyKnownValueHasALabelAndAnUnknownOneHasNone() {
        for a in ["passphrase", "secure-enclave", "secure-enclave-unlocked", "convenience", "webauthn", "tpm", "windows-hello"] {
            #expect(SignerAuthLabel.text(forWire: a) != nil)
        }
        #expect(SignerAuthLabel.text(forWire: "bogus") == nil)
        #expect(SignerAuthLabel.text(forWire: "Convenience") == nil)
        #expect(SignerAuthLabel.text(forWire: "") == nil)
    }
    @Test func theDeviceIsShortened() {
        #expect(SignerAuthLabel.shortDevice("d_c65032f21d43401cc223b05723c1e5b4") == "d_c65032f2…")
    }
}
