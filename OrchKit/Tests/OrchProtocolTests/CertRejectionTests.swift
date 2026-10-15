import CryptoKit
import Foundation
import Testing
@testable import OrchProtocol

/// `cert_rejection` (P3-D11): the vectors' `p3` cases with op `rejection`, and the primary ledger's signing of one.
@Suite struct CertRejectionTests {
    var s2: JSONValue { Vectors.suite2 }
    var cases: [JSONValue] { s2["p3"]["cases"].items.filter { $0["op"].str == "rejection" } }

    @Test func p3RejectionVectors() throws {
        #expect(cases.count == 7)
        var ok = 0
        for c in cases {
            let name = c["name"].str, a = c["args"]
            let request = try #require(a["request"].object, "\(name)")
            do {
                let v = try CertRejection.check(a["signed"], pk: a["pk_pub"].sigPub, request: request)
                let want = c["expect"]["result"]["ok"]
                #expect(!want.isNull, "\(name) accepted")
                #expect(v.requestID.hex == want["request_id"].str && v.workspace.hex == want["workspace_id"].str && v.person.hex == want["person_id"].str, "\(name)")
                ok += 1
            } catch let r as Refusal {
                #expect(r.rawValue == c["expect"]["result"]["refuse"].str, "\(name): \(r)")
            }
        }
        #expect(ok == 1)
    }

    @Test func signedRejectionVerifiesOnlyUnderPK() throws {
        let pk = SoftwareSigner(), other = SoftwareSigner()
        let person = Identifiers.personID(pk.publicKey), rid = ID16(bytes: Data(repeating: 1, count: 16))!, ws = ID16(bytes: Data(repeating: 2, count: 16))!
        let att = String(repeating: "c", count: 32), dev = ID16(bytes: Data(repeating: 3, count: 16))!, hash = Data(repeating: 4, count: 32)
        func sign(_ r: ID16) throws -> SignedObject {
            try CertRejection.sign(requestID: r, workspace: ws, person: person, offer: ws, attempt: att, device: dev, dkHash: hash, expiresMs: 9, primary: pk)
        }
        let s = try sign(rid)
        let v = try CertRejection.verify(s.json, pk: pk.publicKey)
        #expect(v.requestID == rid && v.workspace == ws && v.person == person && v.attempt == att && v.device == dev && v.dkHash == hash)
        #expect(throws: Refusal.badSignature) { try CertRejection.verify(s.json, pk: other.publicKey) }
        // a cert_challenge label over the same bytes is not a rejection (domain separation)
        let forged = try Signature.sign(pk, label: Label.sigCertChallenge, message: canonicalJSON(.object(s.object)))
        #expect(throws: Refusal.badSignature) { try CertRejection.verify(SignedObject(object: s.object, signature: forged).json, pk: pk.publicKey) }
        // a re-signature of the same object is a different signature over the same canonical object
        let again = try sign(rid)
        #expect(again.signature != s.signature)
        #expect(SignedObject.sameCanonicalObject(again.json, s.json))
        let otherRequest = try sign(ws)
        #expect(!SignedObject.sameCanonicalObject(otherRequest.json, s.json))
    }

    @Test func ledgerSignsRejectionOnlyForAnAcceptedUnsignedRequest() throws {
        var ledger = PrimaryLedger()
        let pk = SoftwareSigner()
        let rid = ID16(bytes: Data(repeating: 7, count: 16))!
        #expect(throws: Refusal.unknownRequest) { try ledger.signRejection(requestID: rid, primary: pk) }
    }
}
