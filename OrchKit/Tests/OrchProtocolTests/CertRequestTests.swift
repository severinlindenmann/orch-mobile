import CryptoKit
import Foundation
import Testing
@testable import OrchProtocol

@Suite struct CertRequestVectorTests {
    var s2: JSONValue { Vectors.suite2 }
    var cr: JSONValue { s2["cert_request"] }
    func verifiedCard(_ c: JSONValue) throws -> VerifiedCard { try Card.verify(c, ownerKey: s2["keys"]["person_alice.sig"]["pub"].sigPub) }

    func innerMatches(_ a: CertRequest.Accepted, _ want: JSONValue) -> Bool {
        a.inner.deviceID.hex == want["device_id"].str && B64U.encode(a.inner.dkKx.x963) == want["dk_kx_pub"].str
            && B64U.encode(a.inner.dkSig.x963) == want["dk_sig_pub"].str && a.inner.label == want["label"].str
            && a.inner.offerID.hex == want["offer_id"].str && a.inner.scopesMax == want["scopes_max"].items.map(\.str)
    }

    @Test func requestCases() throws {
        let cases = cr["cases"].items
        #expect(cases.count == 10)
        let primary = try testAgreer("primary.kx"), me = s2["ids"]["device_primary"].id
        var ok = 0
        for c in cases {
            let name = c["name"].str
            let card = try verifiedCard(c["card"])
            var ledger = PrimaryLedger()
            for st in c["steps"].items {
                do {
                    let a = try CertRequest.openAsPrimary(st["signed"], card: card, myPerson: c["person_id"].id, me: me, myKey: primary,
                                                          ledger: &ledger, nowMs: st["now_ms"].i64)
                    ok += 1
                    #expect(!st["expect"]["ok"].isNull, "\(name) accepted")
                    #expect(innerMatches(a, st["expect"]["ok"]), "\(name)")
                    #expect(a.clientHostedWarning == (st["expect"]["warning"].str == "client_hosted"), "\(name)")
                } catch let r as Refusal {
                    #expect(r.rawValue == st["expect"]["refuse"].str, "\(name)")
                }
            }
        }
        #expect(ok == 4)
    }

    @Test func ledgerOpenCases() throws {
        let cases = cr["open_cases"].items
        #expect(cases.count == 5)
        let primary = try testAgreer("primary.kx"), me = s2["ids"]["device_primary"].id, alice = s2["ids"]["person_alice"].id
        let pk = try testSigner("person_alice.sig")
        let card = try verifiedCard(cr["cases"][0]["card"])
        var signedCerts = 0
        for c in cases {
            let name = c["name"].str
            var ledger = PrimaryLedger()
            var lastOpened: ID16?
            for st in c["steps"].items {
                switch st["op"].str {
                case "open":
                    let a = try CertRequest.openAsPrimary(st["signed"], card: card, myPerson: alice, me: me, myKey: primary, ledger: &ledger, nowMs: st["now_ms"].i64)
                    #expect(innerMatches(a, st["expect"]["ok"]), "\(name)")
                    lastOpened = a.requestID
                case "reject":
                    ledger.reject(requestID: st["request_id"].id)
                case "challenge":
                    _ = try ledger.issueChallenge(requestID: st["request_id"].id, primaryNonce: st["primary_nonce"].hexData, primary: pk)
                case "sign":
                    let want = st["expect"]
                    let wantO = want["ok"]["o"]
                    do {
                        let cert = try ledger.signCertificate(requestID: st["request_id"].id, labelSealed: wantO["label_sealed"].b64Data, createdMs: st["now_ms"].i64,
                                                              expiresMs: wantO["expires_ms"].int, scopesMax: wantO["scopes_max"].items.map(\.str), primary: pk)
                        signedCerts += 1
                        #expect(JSONValue.object(cert.object) == wantO, "\(name)")
                        _ = try DeviceCertificate.verify(cert.json, personKey: pk.publicKey, nowMs: st["now_ms"].i64)
                    } catch let r as Refusal {
                        #expect(r.rawValue == want["refuse"].str, "\(name)")
                    }
                default: Issue.record("unknown op \(st["op"].str)")
                }
            }
            _ = lastOpened
        }
        #expect(signedCerts == 1)
    }

    @Test func challengeCodeAndCertificate() throws {
        let pk = try testSigner("person_alice.sig"), primary = try testAgreer("primary.kx"), me = s2["ids"]["device_primary"].id
        let alice = s2["ids"]["person_alice"].id
        let card = try verifiedCard(cr["cases"][0]["card"])
        let reqStep = cr["cases"][0]["steps"][0]
        var ledger = PrimaryLedger()
        let accepted = try CertRequest.openAsPrimary(reqStep["signed"], card: card, myPerson: alice, me: me, myKey: primary, ledger: &ledger, nowMs: reqStep["now_ms"].i64)
        // the challenge the primary signs
        let ch = try ledger.issueChallenge(requestID: accepted.requestID, primaryNonce: cr["primary_nonce"].hexData, primary: pk)
        #expect(JSONValue.object(ch.object) == cr["challenge"]["o"])
        #expect(Data(Label.sigCertChallenge.utf8) + (try canonicalJSON(.object(ch.object))) == cr["signed_bytes_challenge"].hexData)
        #expect(Signature.verify(pk.publicKey, signature: cr["challenge"]["sig"].b64Data, message: cr["signed_bytes_challenge"].hexData))
        // a second challenge for the same request is refused (the code must not change under the human)
        #expect(throws: Refusal.replayed) { try ledger.issueChallenge(requestID: accepted.requestID, primaryNonce: Data(count: 32), primary: pk) }
        #expect(throws: CryptoFailure.invalidLength) { var l = ledger; _ = try l.issueChallenge(requestID: accepted.requestID, primaryNonce: Data(count: 31), primary: pk) }
        #expect(throws: Refusal.unknownRequest) { try ledger.issueChallenge(requestID: .random(), primaryNonce: Data(count: 32), primary: pk) }
        // the phone's check
        let phoneSig = s2["keys"]["phone.sig"]["pub"].sigPub, phoneKx = s2["keys"]["phone.kx"]["pub"].kxPub
        let ws = s2["ids"]["workspace_a"].id, dev = s2["ids"]["device_phone"].id
        let ok = try CertChallenge.check(cr["challenge"], pk: pk.publicKey, workspace: ws, device: dev, dkSig: phoneSig, dkKx: phoneKx, nowMs: 1_790_000_000_000)
        #expect(ok.certCode == cr["cert_code"].str)
        // the R1 attack: a challenge that names another key raises the alarm
        let attack = CertChallengeDrop.notMyKey
        #expect(throws: attack) { try CertChallenge.check(cr["attack_challenge"], pk: pk.publicKey, workspace: ws, device: dev, dkSig: phoneSig, dkKx: phoneKx, nowMs: 1_790_000_000_000) }
        #expect(attack.raisesAlarm && !CertChallengeDrop.challengeExpired.raisesAlarm)
        #expect(throws: CertChallengeDrop.challengeExpired) { try CertChallenge.check(cr["challenge"], pk: pk.publicKey, workspace: ws, device: dev, dkSig: phoneSig, dkKx: phoneKx, nowMs: 1_790_000_600_000) }
        #expect(throws: CertChallengeDrop.challengeSignature) { try CertChallenge.check(cr["challenge"], pk: SoftwareSigner().publicKey, workspace: ws, device: dev, dkSig: phoneSig, dkKx: phoneKx, nowMs: 0) }
        #expect(throws: CertChallengeDrop.notForThisWorkspace) { try CertChallenge.check(cr["challenge"], pk: pk.publicKey, workspace: .random(), device: dev, dkSig: phoneSig, dkKx: phoneKx, nowMs: 0) }
        #expect(throws: CertChallengeDrop.notMyKey) { try CertChallenge.check(cr["challenge"], pk: pk.publicKey, workspace: ws, device: .random(), dkSig: phoneSig, dkKx: phoneKx, nowMs: 0) }
        #expect(throws: CertChallengeDrop.notMyKey) { try CertChallenge.check(cr["challenge"], pk: pk.publicKey, workspace: ws, device: dev, dkSig: s2["keys"]["laptop.sig"]["pub"].sigPub, dkKx: phoneKx, nowMs: 0) }
        // a challenge signed under another kind's label, or with an extra field, is not a challenge
        var extra = cr["challenge"]["o"].object!; extra["x"] = 1
        let resigned = try SignedObject.sign(extra, kind: .certChallenge, signer: pk)
        #expect(throws: CertChallengeDrop.challengeSignature) { try CertChallenge.check(resigned.json, pk: pk.publicKey, workspace: ws, device: dev, dkSig: phoneSig, dkKx: phoneKx, nowMs: 0) }
        // the certificate: exactly the keys of the stored challenge, once
        let want = cr["signed_cert"]["ok"]["o"]
        let cert = try ledger.signCertificate(requestID: accepted.requestID, labelSealed: want["label_sealed"].b64Data, createdMs: want["created_ms"].i64,
                                              expiresMs: nil, scopesMax: want["scopes_max"].items.map(\.str), primary: pk)
        #expect(JSONValue.object(cert.object) == want)
        #expect(Signature.verify(pk.publicKey, signature: cr["signed_cert"]["ok"]["sig"].b64Data, label: Label.sigDeviceCert, message: try canonicalJSON(want)))
        let parsed = try DeviceCertificate.verify(cert.json, personKey: pk.publicKey, nowMs: want["created_ms"].i64)
        #expect(parsed.signingKey == phoneSig && parsed.agreementKey == phoneKx)
        #expect(throws: Refusal.alreadySigned) {
            try ledger.signCertificate(requestID: accepted.requestID, labelSealed: Data(), createdMs: want["created_ms"].i64, expiresMs: nil, scopesMax: ["look"], primary: pk)
        }
        #expect(cr["sign_again"]["refuse"].str == Refusal.alreadySigned.rawValue)
    }

    @Test func primaryNeverMakesADropScopedCertificateOrForAnotherPerson() throws {
        let pk = try testSigner("person_alice.sig"), primary = try testAgreer("primary.kx"), me = s2["ids"]["device_primary"].id
        let card = try verifiedCard(cr["cases"][0]["card"]), step = cr["cases"][0]["steps"][0]
        var ledger = PrimaryLedger()
        let a = try CertRequest.openAsPrimary(step["signed"], card: card, myPerson: s2["ids"]["person_alice"].id, me: me, myKey: primary, ledger: &ledger, nowMs: step["now_ms"].i64)
        _ = try ledger.issueChallenge(requestID: a.requestID, primaryNonce: Data(repeating: 7, count: 32), primary: pk)
        let drop = "drop:" + s2["ids"]["shared_space"].str
        for scopes in [[drop], [], ["decide"], ["look", "type"], ["look", "decide", "operate", "type", "x"]] {
            #expect(throws: Refusal.scopeExceeded) { var l = ledger; _ = try l.signCertificate(requestID: a.requestID, labelSealed: Data(), createdMs: 0, expiresMs: nil, scopesMax: scopes, primary: pk) }
        }
        #expect(throws: Refusal.otherPerson) { var l = ledger; _ = try l.signCertificate(requestID: a.requestID, labelSealed: Data(), createdMs: 0, expiresMs: nil, scopesMax: ["look"], primary: SoftwareSigner()) }
        #expect(throws: Refusal.malformed) { var l = ledger; _ = try l.signCertificate(requestID: a.requestID, labelSealed: Data(), createdMs: 5, expiresMs: 5, scopesMax: ["look"], primary: pk) }
        #expect(throws: Refusal.expired) { var l = ledger; _ = try l.signCertificate(requestID: a.requestID, labelSealed: Data(), createdMs: 1_790_000_600_000, expiresMs: nil, scopesMax: ["look"], primary: pk) }
        // a request with a drop scope never reaches a challenge
        #expect(throws: Refusal.unknownRequest) { var l = ledger; _ = try l.signCertificate(requestID: .random(), labelSealed: Data(), createdMs: 0, expiresMs: nil, scopesMax: ["look"], primary: pk) }
    }

    @Test func hostBuiltRequestRoundTrip() throws {
        let wsk = SoftwareSigner(), owner = SoftwareSigner(), primaryKx = SoftwareKeyAgreer()
        let ws = ID16.random(), me = ID16.random(), person = Identifiers.personID(owner.publicKey)
        let deleg = try WorkspaceDelegation.sign(workspace: ws, wsk: wsk.publicKey, clientHosted: false, issuedMs: 1, owner: owner)
        let ck = SymmetricKey(size: .bits256), wxk = SoftwareKeyAgreer()
        let sealed = try Card.sealPart(.init(name: "n", description: "d", capabilities: [], hostedBy: nil), ck: ck, workspace: ws, cardSeq: 1)
        let card = try Card.verify(Card.make(delegation: deleg, workspace: ws, wxk: wxk.publicKey, wxkVersion: 1, owner: person, relayURL: "https://r.example", cardSeq: 1, issuedMs: 1, sealed: sealed, ck: ck, wsk: wsk), ownerKey: owner.publicKey)
        let dkSig = SoftwareSigner(), dkKx = SoftwareKeyAgreer()
        let inner = CertRequestInner(deviceID: Identifiers.deviceID(dkSig.publicKey), dkSig: dkSig.publicKey, dkKx: dkKx.publicKey, label: "iPhone", scopesMax: ["look", "decide"], offerID: .random())
        let req = try CertRequest.make(wsk: wsk, requestID: .random(), workspace: ws, person: person, primary: me, primaryKey: primaryKx.publicKey, inner: inner, createdMs: 1_000)
        var ledger = PrimaryLedger()
        let a = try CertRequest.openAsPrimary(req.json, card: card, myPerson: person, me: me, myKey: primaryKx, ledger: &ledger, nowMs: 2_000)
        #expect(a.inner == inner && !a.clientHostedWarning)
        // the host cannot make the primary open a request for a key that does not derive the device id
        let bad = CertRequestInner(deviceID: .random(), dkSig: dkSig.publicKey, dkKx: dkKx.publicKey, label: "x", scopesMax: ["look"], offerID: .random())
        let badReq = try CertRequest.make(wsk: wsk, requestID: .random(), workspace: ws, person: person, primary: me, primaryKey: primaryKx.publicKey, inner: bad, createdMs: 1_000)
        var l2 = PrimaryLedger()
        #expect(throws: Refusal.malformed) { try CertRequest.openAsPrimary(badReq.json, card: card, myPerson: person, me: me, myKey: primaryKx, ledger: &l2, nowMs: 2_000) }
        #expect(l2 == PrimaryLedger())                                                                  // a refusal leaves the ledger alone
        // lifetime beyond 10 minutes, and created too far in the future, are expired
        var o = req.object; o["expires_ms"] = .int(1_000 + CertRequest.lifetimeMs + 1)
        let long = try SignedObject.sign(o, kind: .certRequest, signer: wsk)
        #expect(throws: Refusal.expired) { try CertRequest.openAsPrimary(long.json, card: card, myPerson: person, me: me, myKey: primaryKx, ledger: &l2, nowMs: 2_000) }
        #expect(throws: Refusal.expired) { try CertRequest.openAsPrimary(req.json, card: card, myPerson: person, me: me, myKey: primaryKx, ledger: &l2, nowMs: 1_000 - 300_001) }
        _ = try CertRequest.openAsPrimary(req.json, card: card, myPerson: person, me: me, myKey: primaryKx, ledger: &l2, nowMs: 1_000 - 300_000)
    }

    @Test func relayAuth() throws {
        let ra = s2["relay_auth"]
        let id = ra["id"].id, challenge = ra["challenge"].hexData
        let bytes = try RelayAuth.signedBytes(origin: ra["origin"].str, challenge: challenge, kind: .device, id: id)
        #expect(bytes == ra["signed_bytes"].hexData)
        let phone = try testSigner("phone.sig")
        #expect(Signature.verify(phone.publicKey, signature: ra["sig"].hexData, message: bytes))
        let fresh = try RelayAuth.sign(phone, origin: ra["origin"].str, challenge: challenge, kind: .device, id: id)
        #expect(Signature.verify(phone.publicKey, signature: fresh, message: bytes))
        #expect(try RelayAuth.signedBytes(origin: ra["origin"].str, challenge: challenge, kind: .workspace, id: id) != bytes)
        #expect(try RelayAuth.signedBytes(origin: "https://other.example", challenge: challenge, kind: .device, id: id) != bytes)
        #expect(throws: CryptoFailure.invalidLength) { try RelayAuth.signedBytes(origin: "https://r\u{e9}.example", challenge: challenge, kind: .device, id: id) }
        #expect(throws: CryptoFailure.invalidLength) { try RelayAuth.signedBytes(origin: "x", challenge: Data(count: 31), kind: .device, id: id) }
        let cases = ra["cases"].items
        #expect(cases.count == 6)
        for c in cases {
            var state: [Data: Int64] = [:]
            for (k, v) in c["state"]["challenges"].object! { state[Hex.decode(k)!] = v.int! }
            for st in c["steps"].items {
                let r = RelayAuth.check(challenges: &state, origin: c["origin"].str, challenge: c["challenge"].hexData, kind: st["kind"].str, id: st["id"].id,
                                        signature: st["sig"].hexData, pub: st["pub"].sigPub, nowMs: st["now_ms"].i64)
                #expect(r.status == st["expect"]["status"].int.map(Int.init) && r.error == st["expect"]["error"].string, "\(c["name"].str)")
            }
            #expect(state.isEmpty, "\(c["name"].str): the challenge is removed whatever happens")
        }
    }
}
