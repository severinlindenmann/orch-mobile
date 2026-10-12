import CryptoKit
import Foundation
import Testing
@testable import OrchProtocol

/// G3b (orch-relay 04da0e7, P3-D28): cert_binding.primary through the primary's section 8.4 step 2 (the clear attempt binding must
/// equal the sealed inner), and cert_binding.earlier_attempt_keys through dk_hash.
@Suite struct CertBindingVectorTests {
    var s2: JSONValue { Vectors.suite2 }

    @Test func primaryChecksTheClearBindingAgainstTheInner() throws {
        let cases = s2["cert_binding"]["primary"].items
        #expect(cases.count == 7)
        let primary = try testAgreer("primary.kx"), me = s2["ids"]["device_primary"].id
        var ok = 0
        for c in cases {
            let name = c["name"].str
            let card = try Card.verify(c["card"], ownerKey: s2["keys"]["person_alice.sig"]["pub"].sigPub)
            var ledger = PrimaryLedger()
            for st in c["steps"].items {
                do {
                    let a = try CertRequest.openAsPrimary(st["signed"], card: card, myPerson: c["person_id"].id, me: me, myKey: primary,
                                                          ledger: &ledger, nowMs: st["now_ms"].i64)
                    let want = st["expect"]["ok"]
                    #expect(!want.isNull, "\(name) accepted")
                    #expect(a.inner.attempt == want["attempt"].str && a.inner.offerID.hex == want["offer_id"].str, "\(name)")
                    #expect(a.inner.deviceID.hex == want["device_id"].str && a.inner.label == want["label"].str, "\(name)")
                    ok += 1
                } catch let r as Refusal {
                    #expect(r.rawValue == st["expect"]["refuse"].str, "\(name): \(r)")
                }
            }
            if ok == 0 { #expect(ledger == PrimaryLedger(), "\(name): a refusal leaves the ledger alone") }
        }
        #expect(ok == 1)
    }

    @Test func dkHashOfAnEarlierAttempt() throws {
        let k = s2["cert_binding"]["earlier_attempt_keys"]
        let sig = try SoftwareSigner(testScalar: scalar(fromSeed: k["sig_seed"].hexData))
        let kx = try SoftwareKeyAgreer(testScalar: scalar(fromSeed: k["kx_seed"].hexData))
        #expect(Identifiers.deviceID(sig.publicKey).hex == k["device_id"].str)
        #expect(B64U.encode(Identifiers.dkHash(sig: sig.publicKey, kx: kx.publicKey)) == k["dk_hash"].str)
        #expect(Identifiers.isAttempt(s2["cert_binding"]["attempts"]["current"].str))
        #expect(!Identifiers.isAttempt("B9D179923176BA29616B3A03E527091B") && !Identifiers.isAttempt("b9d1"))
    }
}
