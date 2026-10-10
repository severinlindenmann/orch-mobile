import CryptoKit
import Foundation
import Testing
@testable import OrchProtocol

@Suite struct CardVectorTests {
    var s2: JSONValue { Vectors.suite2 }
    var card: JSONValue { s2["card"] }

    func head(_ stored: JSONValue) throws -> Card.Head {
        let o = stored["o"], d = stored["delegation"]
        return Card.Head(workspace: o["workspace_id"].id, ownerPersonID: o["owner_person_id"].id, wsk: o["wsk_pub"].sigPub, wxk: o["wxk_pub"].kxPub,
                         wxkVersion: o["wxk_version"].u32, cardSeq: o["card_seq"].u32, delegationObject: d.object!, objectDigest: VerifiedCard.digest(o.object!))
    }

    @Test func updateCases() throws {
        let cases = card["cases"].items
        #expect(cases.count == 16)
        var ok = 0
        for c in cases {
            let name = c["name"].str
            do {
                let v = try Card.verify(c["card"], ownerKey: c["owner_pk_pub"].sigPub)
                try Card.checkRelayUpdate(previous: c["stored"].isNull ? nil : try head(c["stored"]), next: v)
                ok += 1
                #expect(!c["expect"]["ok"].isNull, "\(name) accepted")
                #expect(JSONValue.object(v.object) == c["expect"]["ok"], "\(name)")
            } catch let r as Refusal {
                #expect(r.rawValue == c["expect"]["refuse"].str, "\(name)")
            }
        }
        #expect(ok == 3)
    }

    @Test func signedBytesAndSealedPart() throws {
        let c = card
        let base = try Card.verify(c["card"], ownerKey: s2["keys"]["person_alice.sig"]["pub"].sigPub)
        #expect(Data(Label.sigCardWSK.utf8) + (try canonicalJSON(.object(base.object))) == c["signed_bytes_wsk"].hexData)
        #expect(Data(Label.sigWSDelegation.utf8) + (try canonicalJSON(.object(base.delegation.object))) == c["signed_bytes_delegation"].hexData)
        let ck = c["card_key"].key
        #expect(KDF.kCard(ck: ck, workspace: base.workspace, cardSeq: 1).rawBytes == c["k_card"].hexData)
        #expect(Card.sealedAAD(workspace: base.workspace, cardSeq: 1) == c["aad"].hexData)
        #expect(Card.ckCommit(workspace: base.workspace, cardSeq: 1, ck: ck) == base.ckCommit)
        #expect(B64U.encode(base.ckCommit) == c["ck_commit"].str)
        let pt = c["sealed_part_plaintext"]
        let part = CardSealedPart(name: pt["name"].str, description: pt["description"].str, capabilities: pt["capabilities"].items.map(\.str), hostedBy: nil)
        #expect(try Card.sealPart(part, ck: ck, workspace: base.workspace, cardSeq: 1) == c["sealed_part"].hexData)
        #expect(base.sealed == c["sealed_part"].hexData)
        #expect(try Card.openSealedPart(of: base, ck: ck) == part)
        let next = try Card.verify(c["card_seq_2"], ownerKey: s2["keys"]["person_alice.sig"]["pub"].sigPub)
        #expect(next.cardSeq == 2 && next.wxkVersion == 2)
        try Card.checkRelayUpdate(previous: base.head, next: next)
        #expect(throws: Refusal.staleCard) { try Card.checkRelayUpdate(previous: next.head, next: base) }
        // a wrong or foreign CK never opens the part, and nothing falls back to a plaintext name
        #expect(throws: CryptoFailure.authenticationFailed) { try Card.openSealedPart(of: base, ck: SymmetricKey(size: .bits256)) }
        #expect(throws: CryptoFailure.authenticationFailed) { try Card.openSealedPart(of: next, ck: ck) }      // ck of seq 1 vs seq 2
    }

    @Test func hostedMarkerCases() {
        let cases = card["hosted_marker"].items
        #expect(cases.count == 4)
        for c in cases {
            let sp = c["sealed_part"]
            let m = HostedMarker.decide(delegationClientHosted: c["delegation"]["client_hosted"].bool!, hostedBy: sp["hosted_by"].string)
            #expect(m.marker == c["expect"]["marker"].bool && m.hostedBy == c["expect"]["hosted_by"].string, "\(c["name"].str)")
        }
        #expect(HostedMarker.decide(delegationClientHosted: false, hostedBy: "") == .init(marker: true, hostedBy: "(unknown)"))
        #expect(HostedMarker.decide(delegationClientHosted: true, hostedBy: "") == .init(marker: true, hostedBy: "(unknown)"))
    }

    @Test func cardKeyWrapToPhone() throws {
        let w = card["card_key_wrap_to_phone"]
        let phone = try testAgreer("phone.kx"), ws = s2["ids"]["workspace_a"].id, dev = s2["ids"]["device_phone"].id
        let ck = card["card_key"].key
        let eph = try SoftwareKeyAgreer(testScalar: scalar(fromSeed: w["eph_seed"].hexData))
        let sealed = try Sealing.seal(ephemeral: eph, to: phone.publicKey, recipientID: dev, purpose: .card, object: ws, epoch: 1, extra: Data(), plaintext: ck.rawBytes)
        #expect(sealed == w["sealed"].hexData)
        #expect(try CardKeyWrap.open(sealed: w["sealed"].hexData, device: phone, deviceID: dev, workspace: ws, cardSeq: 1).rawBytes == ck.rawBytes)
        // bound to device, workspace and card_seq
        #expect(throws: CryptoFailure.self) { try CardKeyWrap.open(sealed: w["sealed"].hexData, device: phone, deviceID: dev, workspace: ws, cardSeq: 2) }
        #expect(throws: CryptoFailure.self) { try CardKeyWrap.open(sealed: w["sealed"].hexData, device: phone, deviceID: ID16.random(), workspace: ws, cardSeq: 1) }
        #expect(throws: CryptoFailure.self) { try CardKeyWrap.open(sealed: w["sealed"].hexData, device: phone, deviceID: dev, workspace: ID16.random(), cardSeq: 1) }
        #expect(throws: CryptoFailure.self) { try CardKeyWrap.open(sealed: w["sealed"].hexData, device: try testAgreer("laptop.kx"), deviceID: dev, workspace: ws, cardSeq: 1) }
        let fresh = try CardKeyWrap.seal(ck: ck, to: phone.publicKey, deviceID: dev, workspace: ws, cardSeq: 1)
        #expect(try CardKeyWrap.open(sealed: fresh, device: phone, deviceID: dev, workspace: ws, cardSeq: 1).rawBytes == ck.rawBytes)
    }

    @Test func relayURLForms() {
        for ok in ["https://relay.dev.severin.io", "https://relay.example:8443", "https://a", "https://a-b.c1", "http://localhost", "http://localhost:8080",
                   "http://127.0.0.1:1", "http://[::1]", "http://[::1]:9"] { #expect(RelayURL.isValid(ok), "\(ok)") }
        for bad in ["", "https://", "https://Relay.example", "https://relay.example/", "https://relay.example/x", "https://relay.example:0",
                    "https://relay.example:", "https://relay.example:123456", "https://relay.example:08", "https://-a", "https://a-", "http://relay.example",
                    "http://localhost/", "http://localhost:", "http://[::1", "https://[::1]", "ftp://a", "https://u@a", "https://a b", "https://\u{212A}.example",
                   "HTTPS://a", " https://a"] { #expect(!RelayURL.isValid(bad), "\(bad)") }
    }

    @Test func mutatedCardsAreRefused() throws {
        let alice = s2["keys"]["person_alice.sig"]["pub"].sigPub
        let base = card["card"].object!
        func top(_ edit: (inout [String: JSONValue]) -> Void) -> JSONValue { var c = base; edit(&c); return .object(c) }
        func with(o edit: (inout [String: JSONValue]) -> Void) -> JSONValue { top { var o = $0["o"]!.object!; edit(&o); $0["o"] = .object(o) } }
        #expect(throws: Refusal.malformed) { try Card.verify(top { $0["extra"] = 1 }, ownerKey: alice) }
        #expect(throws: Refusal.malformed) { try Card.verify(top { $0["sealed"] = "AA==" }, ownerKey: alice) }
        #expect(throws: Refusal.malformed) { try Card.verify(with(o: { $0["extra"] = 1 }), ownerKey: alice) }
        #expect(throws: Refusal.malformed) { try Card.verify(with(o: { $0["v"] = 3 }), ownerKey: alice) }
        #expect(throws: Refusal.malformed) { try Card.verify(with(o: { $0["kind"] = "carD" }), ownerKey: alice) }
        #expect(throws: Refusal.wrongSuite) { try Card.verify(with(o: { $0["suite"] = 1 }), ownerKey: alice) }
        #expect(throws: Refusal.malformed) { try Card.verify(with(o: { $0["card_seq"] = 0 }), ownerKey: alice) }
        #expect(throws: Refusal.malformed) { try Card.verify(with(o: { $0["wxk_version"] = 0 }), ownerKey: alice) }
        #expect(throws: Refusal.malformed) { try Card.verify(with(o: { $0["card_seq"] = 4_294_967_296 }), ownerKey: alice) }
        #expect(throws: Refusal.malformed) { try Card.verify(with(o: { $0["card_seq"] = "1" }), ownerKey: alice) }
        #expect(throws: Refusal.malformed) { try Card.verify(with(o: { $0["wxk_pub"] = .string(B64U.encode(Data(count: 65))) }), ownerKey: alice) }
        #expect(throws: Refusal.malformed) { try Card.verify(with(o: { $0["ck_commit"] = .string(B64U.encode(Data(count: 31))) }), ownerKey: alice) }
        #expect(throws: Refusal.malformed) { try Card.verify(with(o: { $0["relay_url"] = "https://Relay.example" }), ownerKey: alice) }
        #expect(throws: Refusal.badSignature) { try Card.verify(with(o: { $0["card_seq"] = 9 }), ownerKey: alice) }
        #expect(throws: Refusal.badSignature) { try Card.verify(top { $0["sig"] = .string(B64U.encode(Data(count: 64))) }, ownerKey: alice) }
        #expect(throws: Refusal.otherPerson) { try Card.verify(card["card"], ownerKey: s2["keys"]["person_bob.sig"]["pub"].sigPub) }
        // an oversized sealed part is refused before any hashing
        #expect(throws: Refusal.malformed) { try Card.verify(top { $0["sealed"] = .string(B64U.encode(Data(count: Card.maxSealedBytes + 1))) }, ownerKey: alice) }
    }

    @Test func builtCardsRoundTripAndRotate() throws {
        let owner = SoftwareSigner(), wsk = SoftwareSigner(), wxk1 = SoftwareKeyAgreer(), wxk2 = SoftwareKeyAgreer()
        let ws = ID16.random(), ownerID = Identifiers.personID(owner.publicKey), ck1 = SymmetricKey(size: .bits256), ck2 = SymmetricKey(size: .bits256)
        let deleg = try WorkspaceDelegation.sign(workspace: ws, wsk: wsk.publicKey, clientHosted: true, issuedMs: 5, owner: owner)
        func make(seq: UInt32, wxk: SoftwareKeyAgreer, version: UInt32, ck: SymmetricKey, hosted: String?) throws -> JSONValue {
            let part = CardSealedPart(name: "N", description: "D", capabilities: ["tickets"], hostedBy: hosted)
            return try Card.make(delegation: deleg, workspace: ws, wxk: wxk.publicKey, wxkVersion: version, owner: ownerID, relayURL: "https://r.example",
                                 cardSeq: seq, issuedMs: 10, sealed: Card.sealPart(part, ck: ck, workspace: ws, cardSeq: seq), ck: ck, wsk: wsk)
        }
        let c1 = try Card.verify(make(seq: 1, wxk: wxk1, version: 1, ck: ck1, hosted: nil), ownerKey: owner.publicKey)
        let part = try Card.openSealedPart(of: c1, ck: ck1)
        #expect(part.name == "N" && Card.hostedMarker(card: c1, sealedPart: part) == .init(marker: true, hostedBy: "(unknown)"))   // flag true, name null
        try Card.checkRelayUpdate(previous: nil, next: c1)
        let c2 = try Card.verify(make(seq: 2, wxk: wxk2, version: 2, ck: ck2, hosted: "Client AG"), ownerKey: owner.publicKey)
        try Card.checkRelayUpdate(previous: c1.head, next: c2)                                                  // a WXK rotation signed by WSK alone
        #expect(throws: Refusal.badWxkVersion) { try Card.checkRelayUpdate(previous: c1.head, next: try Card.verify(make(seq: 3, wxk: wxk2, version: 3, ck: ck2, hosted: nil), ownerKey: owner.publicKey)) }
        #expect(throws: Refusal.wxkChangedWithoutVersion) { try Card.checkRelayUpdate(previous: c1.head, next: try Card.verify(make(seq: 3, wxk: wxk2, version: 1, ck: ck2, hosted: nil), ownerKey: owner.publicKey)) }
        #expect(throws: Refusal.badWxkVersion) { try Card.checkRelayUpdate(previous: c1.head, next: try Card.verify(make(seq: 3, wxk: wxk1, version: 2, ck: ck2, hosted: nil), ownerKey: owner.publicKey)) }
        // sealed part with an extra field or the wrong types is malformed
        let bad = try ZeroNonceGCM.seal(key: KDF.kCard(ck: ck1, workspace: ws, cardSeq: 1), plaintext: canonicalJSON(["name": "n", "description": "d", "capabilities": ["a"], "hosted_by": .null, "x": 1]),
                                        aad: Card.sealedAAD(workspace: ws, cardSeq: 1))
        let c3 = try Card.verify(Card.make(delegation: deleg, workspace: ws, wxk: wxk1.publicKey, wxkVersion: 1, owner: ownerID, relayURL: "https://r.example", cardSeq: 1, issuedMs: 1, sealed: bad, ck: ck1, wsk: wsk), ownerKey: owner.publicKey)
        #expect(throws: Refusal.malformed) { try Card.openSealedPart(of: c3, ck: ck1) }
    }
}

@Suite struct MembershipVectorTests {
    var s2: JSONValue { Vectors.suite2 }

    func directory(_ d: JSONValue) -> MemberList.Directory {
        var certs: [ID16: JSONValue] = [:]
        for (k, v) in d["certs"].object! { certs[ID16(hex: k)!] = v }
        let grants = Set(d["grants"].items.map { MemberList.Directory.GrantKey(device: $0[0].id, epoch: $0[1].u32) })
        return .init(ownerKey: d["owner_pk_pub"].sigPub, certs: certs, revoked: Set(d["revoked"].items.map(\.id)), grants: grants)
    }

    @Test func memberListCases() throws {
        let cases = s2["member_lists"].items
        #expect(cases.count == 14)
        var ok = 0
        for c in cases {
            let name = c["name"].str
            do {
                let list = try MemberList.verify(c["signed"], wsk: c["wsk_pub"].sigPub)
                let prev = c["prev"].isNull ? nil : try MemberList.parse(object: c["prev"].object!)
                try list.checkRelayUpdate(cardWorkspace: c["card_workspace_id"].id, previous: prev, directory: directory(c["directory"]), nowMs: c["now_ms"].i64)
                ok += 1
                let want = c["expect"]["ok"]
                #expect(!want.isNull, "\(name) accepted")
                #expect(list.epoch == want["epoch"].u32 && list.listSeq == want["list_seq"].i64, "\(name)")
                #expect(list.members.map { $0.deviceID.hex } == want["members"].items.map { $0["device_id"].str }, "\(name)")
                #expect(list.members.map { $0.scopeStrings } == want["members"].items.map { $0["scopes"].items.map(\.str) }, "\(name)")
            } catch let r as Refusal {
                #expect(r.rawValue == c["expect"]["refuse"].str, "\(name)")
            }
        }
        #expect(ok == 3)
    }

    @Test func memberListShapeRefusals() throws {
        let wsk = SoftwareSigner(), ws = ID16.random()
        func list(_ edit: (inout [String: JSONValue]) -> Void) throws -> JSONValue {
            var o: [String: JSONValue] = ["v": 2, "suite": 2, "kind": "member_list", "workspace_id": .string(ws.hex), "epoch": 1, "list_seq": 1,
                                          "issued_ms": 1, "members": [["device_id": .string(String(repeating: "0", count: 32)), "scopes": ["look"]]]]
            edit(&o)
            return try SignedObject.sign(o, kind: .memberList, signer: wsk).json
        }
        _ = try MemberList.verify(list { _ in }, wsk: wsk.publicKey)
        let a = String(repeating: "0", count: 32), b = String(repeating: "1", count: 32)
        func m(_ id: String) -> JSONValue { ["device_id": .string(id), "scopes": ["look"]] }
        #expect(throws: Refusal.malformed) { try MemberList.verify(list { $0["extra"] = 1 }, wsk: wsk.publicKey) }
        #expect(throws: Refusal.malformed) { try MemberList.verify(list { $0["epoch"] = 0 }, wsk: wsk.publicKey) }
        #expect(throws: Refusal.malformed) { try MemberList.verify(list { $0["epoch"] = 4_294_967_296 }, wsk: wsk.publicKey) }
        #expect(throws: Refusal.malformed) { try MemberList.verify(list { $0["members"] = [m(b), m(a)] }, wsk: wsk.publicKey) }      // unsorted
        #expect(throws: Refusal.malformed) { try MemberList.verify(list { $0["members"] = [m(a), m(a)] }, wsk: wsk.publicKey) }      // duplicate
        #expect(throws: Refusal.malformed) { try MemberList.verify(list { $0["members"] = [["device_id": .string(a), "scopes": ["look"], "x": 1]] }, wsk: wsk.publicKey) }
        #expect(throws: Refusal.malformed) { try MemberList.verify(list { $0["members"] = [m(String(repeating: "A", count: 32))] }, wsk: wsk.publicKey) }
        #expect(throws: Refusal.malformed) { try MemberList.verify(list { $0["members"] = .array(Array(repeating: m(a), count: MemberList.maxMembers + 1)) }, wsk: wsk.publicKey) }
        #expect(throws: Refusal.badSignature) { try MemberList.verify(list { _ in }, wsk: SoftwareSigner().publicKey) }
        // a list whose scopes are not an array of strings is refused at the scope check, not at the shape
        let listJSON = try list { $0["members"] = [["device_id": .string(a), "scopes": "look"]] }
        let parsed = try MemberList.verify(listJSON, wsk: wsk.publicKey)
        #expect(parsed.members[0].scopeStrings == nil)
    }

    @Test func wkGrantCases() throws {
        let g = s2["wk_grants"]
        let cases = g["cases"].items
        #expect(cases.count == 3)
        for c in cases {
            let name = c["name"].str
            let phone = try testAgreer("\(c["device"].str).kx")
            do {
                let r = try WKGrant.open(c["signed"], wsk: c["wsk_pub"].sigPub, workspace: s2["ids"]["workspace_a"].id, device: s2["ids"]["device_\(c["device"].str)"].id, deviceKey: phone)
                #expect(r.epoch == c["expect"]["ok"]["epoch"].u32 && r.wk.rawBytes == c["expect"]["ok"]["wk"].hexData, "\(name)")
            } catch let r as Refusal {
                #expect(r.rawValue == c["expect"]["refuse"].str, "\(name)")
            }
        }
        // sealed with our own code, opened, and every binding enforced
        let wsk = SoftwareSigner(), dev = SoftwareKeyAgreer(), ws = ID16.random(), id = ID16.random(), wk = SymmetricKey(size: .bits256)
        let signed = try WKGrant.make(wsk: wsk, workspace: ws, device: id, deviceKey: dev.publicKey, epoch: 7, wk: wk)
        let opened = try WKGrant.open(signed.json, wsk: wsk.publicKey, workspace: ws, device: id, deviceKey: dev)
        #expect(opened.epoch == 7 && opened.wk.rawBytes == wk.rawBytes)
        #expect(throws: Refusal.notForThisDevice) { try WKGrant.open(signed.json, wsk: wsk.publicKey, workspace: ws, device: ID16.random(), deviceKey: dev) }
        #expect(throws: Refusal.notForThisDevice) { try WKGrant.open(signed.json, wsk: wsk.publicKey, workspace: ID16.random(), device: id, deviceKey: dev) }
        #expect(throws: Refusal.badSignature) { try WKGrant.open(signed.json, wsk: SoftwareSigner().publicKey, workspace: ws, device: id, deviceKey: dev) }
        #expect(throws: CryptoFailure.authenticationFailed) { try WKGrant.open(signed.json, wsk: wsk.publicKey, workspace: ws, device: id, deviceKey: SoftwareKeyAgreer()) }
        // a grant whose epoch field was changed after sealing: the signature fails first; re-signed, the AAD (epoch) fails
        var o = signed.object; o["epoch"] = 8
        let resigned = try SignedObject.sign(o, kind: .wkGrant, signer: wsk)
        #expect(throws: CryptoFailure.authenticationFailed) { try WKGrant.open(resigned.json, wsk: wsk.publicKey, workspace: ws, device: id, deviceKey: dev) }
        // a signed WK that is not 32 bytes
        let short = try Sealing.seal(to: dev.publicKey, recipientID: id, purpose: .wk, object: ws, epoch: 1, plaintext: Data(count: 31))
        let sh = try SignedObject.sign(["v": 2, "suite": 2, "kind": "wk_grant", "workspace_id": .string(ws.hex), "device_id": .string(id.hex), "epoch": 1, "sealed": .string(B64U.encode(short))], kind: .wkGrant, signer: wsk)
        #expect(throws: Refusal.malformed) { try WKGrant.open(sh.json, wsk: wsk.publicKey, workspace: ws, device: id, deviceKey: dev) }
        // the stored grant vector opens too
        let phone = try testAgreer("phone.kx")
        #expect(try WKGrant.open(g["grant_phone_epoch_1"], wsk: s2["keys"]["wsk_a.sig"]["pub"].sigPub, workspace: s2["ids"]["workspace_a"].id, device: s2["ids"]["device_phone"].id, deviceKey: phone).epoch == 1)
    }
}
