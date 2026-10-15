import CryptoKit
import Foundation
import Testing
@testable import OrchProtocol

@Suite struct DropVectorTests {
    var s2: JSONValue { Vectors.suite2 }
    var d: JSONValue { s2["drop"] }
    var dek: SymmetricKey { d["dek"].key }
    var obj: ID16 { d["object_id"].id }

    @Test func testDropVectorsAndDocumentChains() throws {
        try blob(); try metadataAndCommit(); try wraps(); try wrapNegatives(); try descriptorCases(); try documentsAndChains(); try claims()
    }

    @Test func blob() throws {
        #expect(KDF.kDropContent(dek: dek, object: obj, version: 1).rawBytes == d["k_content"].hexData)
        let content = d["content"].hexData, prefix = d["nonce_prefix"].hexData
        let blob = try DropBlob.encrypt(dek: dek, object: obj, version: 1, plaintext: content, chunkSize: Int(d["chunk_size"].i64), noncePrefix: prefix)
        #expect(blob == d["blob"].hexData)
        #expect(blob.count == 40 + 1280 + 3 * 16 - 0 + 0 || blob.count == 1368)
        #expect(try DropBlob.decrypt(dek: dek, object: obj, version: 1, blob: blob) == content)
        let empty = try DropBlob.encrypt(dek: dek, object: obj, version: 1, plaintext: Data(), chunkSize: Int(d["chunk_size"].i64), noncePrefix: prefix)
        #expect(empty == d["empty_blob"].hexData)
        #expect(try DropBlob.decrypt(dek: dek, object: obj, version: 1, blob: empty).isEmpty)
        // 3 chunks of 512 over 1280 bytes: 512 + 512 + 256
        #expect(blob.count == 40 + 1280 + 3 * 16)
        // truncation at a chunk boundary, a dropped tail, reordering, another object or version, another key: all refused
        let step = 512 + 16
        for cut in [40 + step, 40 + 2 * step, blob.count - 1, blob.count - 16, 40 + 15, 40, 0] {
            #expect(throws: (any Error).self) { try DropBlob.decrypt(dek: dek, object: obj, version: 1, blob: blob.prefix(cut)) }
        }
        var swapped = blob.prefix(40) + blob.subdata(in: 40 + step..<40 + 2 * step) + blob.subdata(in: 40..<40 + step) + blob.suffix(from: 40 + 2 * step)
        swapped = Data(swapped)
        #expect(throws: CryptoFailure.authenticationFailed) { try DropBlob.decrypt(dek: dek, object: obj, version: 1, blob: swapped) }
        #expect(throws: Refusal.malformed) { try DropBlob.decrypt(dek: dek, object: ID16.random(), version: 1, blob: blob) }
        #expect(throws: Refusal.malformed) { try DropBlob.decrypt(dek: dek, object: obj, version: 2, blob: blob) }
        #expect(throws: CryptoFailure.authenticationFailed) { try DropBlob.decrypt(dek: SymmetricKey(size: .bits256), object: obj, version: 1, blob: blob) }
        for i in 0..<blob.count {                                                                 // every byte is covered
            var t = blob; t[i] ^= 1
            #expect((try? DropBlob.decrypt(dek: dek, object: obj, version: 1, blob: t)) == nil, "byte \(i)")
        }
        // an appended chunk (extension) fails too, and so do bad chunk sizes and the blob cap
        let extra = blob + Data(count: 16 + 1)
        #expect(throws: (any Error).self) { try DropBlob.decrypt(dek: dek, object: obj, version: 1, blob: extra) }
        var zeroChunk = blob; zeroChunk.replaceSubrange(28..<32, with: Bytes.u32(0))
        #expect(throws: Refusal.malformed) { try DropBlob.decrypt(dek: dek, object: obj, version: 1, blob: zeroChunk) }
        var hugeChunk = blob; hugeChunk.replaceSubrange(28..<32, with: Bytes.u32(UInt32(Drop.maxChunkSize) + 1))
        #expect(throws: Refusal.malformed) { try DropBlob.decrypt(dek: dek, object: obj, version: 1, blob: hugeChunk) }
        #expect(throws: CryptoFailure.invalidLength) { try DropBlob.decrypt(dek: dek, object: obj, version: 1, blob: blob, maxBytes: blob.count - 1) }
    }

    @Test func blobRoundTripsAtChunkBoundaries() throws {
        for (len, chunk) in [(0, 16), (1, 16), (15, 16), (16, 16), (17, 16), (32, 16), (33, 16), (1000, 1)] {
            let pt = Data((0..<len).map { UInt8(truncatingIfNeeded: $0 &* 7) })
            let b = try DropBlob.encrypt(dek: dek, object: obj, version: 3, plaintext: pt, chunkSize: chunk)
            #expect(try DropBlob.decrypt(dek: dek, object: obj, version: 3, blob: b) == pt, "\(len)/\(chunk)")
            #expect(b.count == 40 + pt.count + 16 * max(1, (len + chunk - 1) / chunk))
        }
        #expect(throws: CryptoFailure.invalidLength) { try DropBlob.encrypt(dek: dek, object: obj, version: 1, plaintext: Data(), chunkSize: 0) }
        #expect(throws: CryptoFailure.invalidLength) { try DropBlob.encrypt(dek: dek, object: obj, version: 1, plaintext: Data(), chunkSize: Drop.maxChunkSize + 1) }
        let a = try DropBlob.encrypt(dek: dek, object: obj, version: 1, plaintext: Data("x".utf8))
        let b = try DropBlob.encrypt(dek: dek, object: obj, version: 1, plaintext: Data("x".utf8))
        #expect(a != b)                                                                           // fresh nonce prefix
    }

    @Test func metadataAndCommit() throws {
        let m = d["meta"]
        let meta = DropMetadata(name: m["name"].str, mime: m["mime"].str, size: m["size"].i64, transcript: nil)
        let sealed = try meta.seal(dek: dek, object: obj, version: 1)
        #expect(sealed == d["meta_sealed"].hexData)
        #expect(try DropMetadata.open(sealed: sealed, dek: dek, object: obj, version: 1) == meta)
        #expect(throws: CryptoFailure.authenticationFailed) { try DropMetadata.open(sealed: sealed, dek: dek, object: obj, version: 2) }
        #expect(throws: CryptoFailure.authenticationFailed) { try DropMetadata.open(sealed: sealed, dek: dek, object: .random(), version: 1) }
        #expect(throws: CryptoFailure.authenticationFailed) { try DropMetadata.open(sealed: sealed, dek: SymmetricKey(size: .bits256), object: obj, version: 1) }
        #expect(throws: CryptoFailure.invalidLength) { try DropMetadata.open(sealed: Data(count: Drop.maxMetaBytes + 17), dek: dek, object: obj, version: 1) }
        let odd = DropMetadata(name: "n", mime: "m", size: 0, transcript: "t")
        #expect(try DropMetadata.open(sealed: odd.seal(dek: dek, object: obj, version: 1), dek: dek, object: obj, version: 1) == odd)
        // wrong shape under a valid key is malformed
        let wrong = try ZeroNonceGCM.seal(key: KDF.kDropMeta(dek: dek, object: obj, version: 1), plaintext: canonicalJSON(["name": "n"]), aad: DropMetadata.aad(object: obj, version: 1))
        #expect(throws: Refusal.malformed) { try DropMetadata.open(sealed: wrong, dek: dek, object: obj, version: 1) }
        #expect(B64U.encode(DropKeys.dekCommit(object: obj, version: 1, dek: dek)) == d["dek_commit"].str)
        #expect(DropKeys.dekCommit(object: obj, version: 2, dek: dek) != DropKeys.dekCommit(object: obj, version: 1, dek: dek))
    }

    @Test func wraps() throws {
        let w = d["wraps"]
        #expect(w.object!.count == 5)
        let wkSecret = s2["hkdf"].items.first { $0["name"].str == "k_wrap_wk_epoch_1" }!["ikm"].key
        let skSecret = s2["hkdf"].items.first { $0["name"].str == "k_wrap_sk_epoch_1" }!["ikm"].key
        // wk and sk: reproduce byte for byte with the vector's salt (the first 16 bytes), then unwrap
        for (name, kind, secret) in [("wk", DropTargetKind.wk, wkSecret), ("sk", .sk, skSecret)] {
            let rec = try DropWrapRecord(json: w[name])
            #expect(rec.json == w[name])
            let again = try DropWrap.wrapWithSecret(kind: kind, secret: secret, target: rec.target, keyVersion: rec.keyVersion, object: rec.object,
                                                    version: rec.version, dek: dek, salt: rec.wrap.prefix(16))
            #expect(again == rec, "\(name)")
            #expect(try DropWrap.unwrap(rec, with: kind == .wk ? .wk(secret) : .sk(secret)).rawBytes == dek.rawBytes, "\(name)")
        }
        // wxk and device wraps are seals: unwrap with the addressed key
        let wxkA = try DropWrapRecord(json: w["wxk_a"]), wxkB = try DropWrapRecord(json: w["wxk_b"]), dev = try DropWrapRecord(json: w["device"])
        #expect(try DropWrap.unwrap(wxkA, agreement: testAgreer("wxk_a_1.kx")).rawBytes == dek.rawBytes)
        #expect(try DropWrap.unwrap(wxkB, agreement: testAgreer("wxk_b_1.kx")).rawBytes == dek.rawBytes)
        #expect(try DropWrap.unwrap(dev, agreement: testAgreer("phone.kx")).rawBytes == dek.rawBytes)
        #expect(dev.keyVersion == 0 && dev.targetKind == .device)
        #expect(throws: CryptoFailure.self) { try DropWrap.unwrap(wxkA, agreement: testAgreer("wxk_b_1.kx")) }
        #expect(throws: Refusal.malformed) { try DropWrap.unwrap(wxkA, with: .wk(wkSecret)) }
        #expect(throws: Refusal.malformed) { try DropWrap.unwrap(try DropWrapRecord(json: w["wk"]), with: .sk(wkSecret)) }
        // fresh wraps round-trip
        let kx = SoftwareKeyAgreer(), target = ID16.random()
        for kind in [DropTargetKind.wxk, .device] {
            let rec = try DropWrap.wrapToKey(kind: kind, to: kx.publicKey, target: target, keyVersion: kind == .device ? 0 : 3, object: obj, version: 2, dek: dek)
            #expect(try DropWrap.unwrap(rec, agreement: kx).rawBytes == dek.rawBytes)
            #expect(throws: CryptoFailure.self) { try DropWrap.unwrap(DropWrapRecord(object: rec.object, version: 3, targetKind: kind, target: target, keyVersion: rec.keyVersion, wrap: rec.wrap), agreement: kx) }
        }
        #expect(throws: Refusal.malformed) { try DropWrap.wrapWithSecret(kind: .wxk, secret: wkSecret, target: target, keyVersion: 1, object: obj, version: 1, dek: dek) }
    }

    @Test func wrapNegatives() throws {
        let cases = d["wrap_negative"].items
        #expect(cases.count == 3)
        let wkSecret = s2["hkdf"].items.first { $0["name"].str == "k_wrap_wk_epoch_1" }!["ikm"].key
        for c in cases {
            let rec = try DropWrapRecord(json: c["record"])
            #expect(c["opens"].bool == false)
            switch rec.targetKind {
            case .wk: #expect(throws: CryptoFailure.authenticationFailed, "\(c["name"].str)") { try DropWrap.unwrap(rec, with: .wk(wkSecret)) }
            default: #expect(throws: CryptoFailure.self, "\(c["name"].str)") { try DropWrap.unwrap(rec, agreement: testAgreer("wxk_b_1.kx")) }
            }
        }
    }

    @Test func wrapRecordShape() throws {
        let good = d["wraps"]["wk"]
        func mutate(_ edit: (inout [String: JSONValue]) -> Void) -> JSONValue { var o = good.object!; edit(&o); return .object(o) }
        #expect(throws: Refusal.malformed) { try DropWrapRecord(json: mutate { $0["x"] = 1 }) }
        #expect(throws: Refusal.malformed) { try DropWrapRecord(json: mutate { $0["target_kind"] = "WK" }) }
        #expect(throws: Refusal.malformed) { try DropWrapRecord(json: mutate { $0["target_kind"] = "wxk\u{0}" }) }
        #expect(throws: Refusal.malformed) { try DropWrapRecord(json: mutate { $0["version"] = 0 }) }
        #expect(throws: Refusal.malformed) { try DropWrapRecord(json: mutate { $0["key_version"] = -1 }) }
        #expect(throws: Refusal.malformed) { try DropWrapRecord(json: mutate { $0["wrap"] = "AA==" }) }
        #expect(throws: Refusal.malformed) { try DropWrapRecord(json: mutate { $0["wrap"] = .string(B64U.encode(Data(count: DropWrapRecord.maxWrapBytes + 1))) }) }
        #expect(throws: Refusal.malformed) { try DropWrapRecord(json: mutate { $0["object_id"] = "00" }) }
    }

    @Test func descriptorCases() throws {
        let cases = d["descriptor_cases"].items
        #expect(cases.count == 5)
        var ok = 0
        for c in cases {
            do {
                let desc = try DropDescriptor.verify(c["signed"], authorKey: c["author_pub"].sigPub)
                ok += 1
                #expect(JSONValue.object(desc.raw) == c["expect"]["ok"], "\(c["name"].str)")
            } catch let r as Refusal {
                #expect(r.rawValue == c["expect"]["refuse"].str, "\(c["name"].str)")
            }
        }
        #expect(ok == 1)
        let desc = try DropDescriptor.verify(d["descriptor"], authorKey: s2["keys"]["phone.sig"]["pub"].sigPub)
        #expect(desc.matches(blob: d["blob"].hexData) && !desc.matches(blob: d["empty_blob"].hexData))
        #expect(desc.contentLen == Int64(d["blob"].hexData.count) && desc.dekCommit == DropKeys.dekCommit(object: obj, version: 1, dek: dek))
        #expect(desc.meta == d["meta_sealed"].hexData && desc.recipients == .inbox && desc.parentHash == nil && desc.version == 1)
        #expect(desc.authorID == s2["ids"]["device_phone"].id && desc.origin == "human" && desc.expiresMs == 1_790_604_800_000)
    }

    @Test func descriptorShapeRefusals() throws {
        let base = d["descriptor"]["o"].object!
        let key = try testSigner("phone.sig")
        func signed(_ edit: (inout [String: JSONValue]) -> Void) throws -> JSONValue { var o = base; edit(&o); return try SignedObject.sign(o, kind: .dropObject, signer: key).json }
        _ = try DropDescriptor.verify(signed { _ in }, authorKey: key.publicKey)
        let a = String(repeating: "a", count: 32), b = String(repeating: "b", count: 32)
        for (name, edit) in [
            ("extra field", { (o: inout [String: JSONValue]) in o["x"] = 1 }),
            ("space kind", { $0["space_kind"] = "Workspace" }), ("object kind", { $0["object_kind"] = "folder" }),
            ("origin", { $0["origin"] = "bot" }), ("author kind", { $0["author_kind"] = "agent" }),
            ("document v1 with parent hash", { $0["object_kind"] = "document"; $0["parent_hash"] = .string(B64U.encode(Data(count: 32))) }),
            ("document v2 without parent hash", { $0["object_kind"] = "document"; $0["version"] = 2; $0["parent"] = 1 }),
            ("parent hash wrong length", { $0["object_kind"] = "document"; $0["version"] = 2; $0["parent"] = 1; $0["parent_hash"] = .string(B64U.encode(Data(count: 31))) }),
            ("version != parent + 1", { $0["object_kind"] = "document"; $0["version"] = 3; $0["parent"] = 1; $0["parent_hash"] = .string(B64U.encode(Data(count: 32))) }),
            ("recipients unsorted", { $0["recipients"] = [.string(b), .string(a)] }), ("recipients duplicate", { $0["recipients"] = [.string(a), .string(a)] }),
            ("recipients not hex", { $0["recipients"] = ["zz"] }), ("recipients other string", { $0["recipients"] = "outbox" }),
            ("content hash length", { $0["content_hash"] = .string(B64U.encode(Data(count: 31))) }), ("negative length", { $0["content_len"] = -1 }),
            ("expires not int", { $0["expires_ms"] = "1" }),
        ] as [(String, (inout [String: JSONValue]) -> Void)] {
            let j = try signed(edit)
            #expect(throws: Refusal.self, "\(name)") { try DropDescriptor.verify(j, authorKey: key.publicKey) }
        }
        let list = try signed { $0["recipients"] = [.string(a), .string(b)] }
        #expect(try DropDescriptor.verify(list, authorKey: key.publicKey).recipients == .ids([ID16(hex: a)!, ID16(hex: b)!]))
        let noExpiry = try signed { $0["expires_ms"] = .null }
        #expect(try DropDescriptor.verify(noExpiry, authorKey: key.publicKey).expiresMs == nil)
    }

    @Test func documentsAndChains() throws {
        let docs = d["documents"].items
        #expect(docs.count == 7)
        for c in docs {
            var state = DropDocument.State(current: c["doc"]["current"].u32, head: c["doc"]["head"].object)
            let r = DropDocument.checkPut(state: &state, ifMatch: c["if_match"].string, descriptor: c["descriptor"].object!)
            let e = c["expect"]
            #expect(r.status == Int(e["status"].i64) && r.error == e["error"].string && r.current == e["current"].int.map(UInt32.init) && r.version == e["version"].int.map(UInt32.init), "\(c["name"].str)")
            if r.status == 201 { #expect(state.current == e["version"].u32 && state.head == c["descriptor"].object, "\(c["name"].str)") }
            else { #expect(state.current == c["doc"]["current"].u32, "\(c["name"].str)") }
        }
        let chains = d["document_chains"].items
        #expect(chains.count == 3)
        for c in chains {
            let versions = c["versions"].items.map { $0.object! }
            do { try DropDocument.verifyChain(versions); #expect(!c["expect"]["ok"].isNull, "\(c["name"].str)") }
            catch let f as DropDocument.Fork { #expect(c["expect"]["refuse"].str == "fork" && f.at == c["expect"]["at"].i64, "\(c["name"].str)") }
        }
        // If-Match forms
        #expect(DropDocument.parseIfMatch("0") == 0 && DropDocument.parseIfMatch("12") == 12)
        for bad in [nil, "", "03", "-1", "1 ", "+1", "1.0", "12345678901234567", "\u{660}"] as [String?] { #expect(DropDocument.parseIfMatch(bad) == nil, "\(bad ?? "nil")") }
    }

    func claimRig(_ c: JSONValue) throws -> (DropClaim.Stored, [ID16: SigningPublicKey], [ID16: UInt32]) {
        let o = c["object"]
        let stored = DropClaim.Stored(object: o["object_id"].id, version: o["version"].u32, state: .inbox, wraps: try o["wraps"].items.map { try DropWrapRecord(json: $0) })
        var cards: [ID16: SigningPublicKey] = [:]
        for (k, v) in c["cards"].object! { cards[ID16(hex: k)!] = v["wsk_pub"].sigPub }
        var epochs: [ID16: UInt32] = [:]
        for (k, v) in c["epochs"].object! { epochs[ID16(hex: k)!] = UInt32(v.int!) }
        return (stored, cards, epochs)
    }

    @Test func claims() throws {
        let cases = d["claims"].items
        #expect(cases.count == 6)
        for c in cases {
            let name = c["name"].str
            var (stored, cards, epochs) = try claimRig(c)
            for st in c["steps"].items {
                let r = DropClaim.check(stored: &stored, claim: st["claim"], cards: cards, epochs: epochs)
                let e = st["expect"]
                #expect(r.status == Int(e["status"].i64) && r.error == e["error"].string && r.claimedBy?.hex == e["claimed_by"].string, "\(name)")
            }
            let after = c["after"]
            switch stored.state {
            case .inbox: #expect(after["state"].str == "inbox" && after["claimed_by"].isNull, "\(name)")
            case .claimed(let by): #expect(after["state"].str == "claimed" && after["claimed_by"].str == by.hex, "\(name)")
            }
            #expect(stored.wraps.map(\.json) == after["wraps"].items, "\(name)")
        }
    }

    @Test func claimsBuiltAndDefended() throws {
        let wskA = SoftwareSigner(), wskB = SoftwareSigner(), a = ID16.random(), b = ID16.random(), o = ID16.random()
        let cards = [a: wskA.publicKey, b: wskB.publicKey], epochs: [ID16: UInt32] = [a: 2, b: 5]
        let inbox = [try DropWrap.wrapToKey(kind: .wxk, to: SoftwareKeyAgreer().publicKey, target: a, keyVersion: 1, object: o, version: 1, dek: dek)]
        let wk = SymmetricKey(size: .bits256)
        func claim(_ ws: ID16, _ signer: SoftwareSigner, epoch: UInt32, version: UInt32 = 1, object: ID16? = nil, kind: DropTargetKind = .wk, target: ID16? = nil) throws -> JSONValue {
            let w = try DropWrap.wrapWithSecret(kind: .wk, secret: wk, target: target ?? ws, keyVersion: epoch, object: object ?? o, version: version, dek: dek)
            let rec = DropWrapRecord(object: w.object, version: w.version, targetKind: kind, target: w.target, keyVersion: w.keyVersion, wrap: w.wrap)
            return try DropClaim.make(wsk: signer, object: object ?? o, workspace: ws, wrap: rec).json
        }
        func fresh() -> DropClaim.Stored { .init(object: o, version: 1, state: .inbox, wraps: inbox) }
        var s = fresh()
        #expect(DropClaim.check(stored: &s, claim: try claim(a, wskA, epoch: 2), cards: cards, epochs: epochs).status == 200)
        #expect(s.state == .claimed(by: a) && s.wraps.count == 1 && s.wraps[0].targetKind == .wk)
        for (label, j, status) in [("wrong signer", try claim(a, wskB, epoch: 2), 401), ("epoch", try claim(a, wskA, epoch: 3), 400), ("version", try claim(a, wskA, epoch: 2, version: 2), 400),
                                   ("object", try claim(a, wskA, epoch: 2, object: .random()), 400), ("kind", try claim(a, wskA, epoch: 2, kind: .sk), 400),
                                   ("target", try claim(a, wskA, epoch: 2, target: b), 400), ("no wxk wrap for b", try claim(b, wskB, epoch: 5), 403)] {
            var t = fresh()
            #expect(DropClaim.check(stored: &t, claim: j, cards: cards, epochs: epochs).status == status, "\(label)")
            #expect(t == fresh(), "\(label): a refused claim changes nothing")
        }
        var unknown = fresh()
        #expect(DropClaim.check(stored: &unknown, claim: try claim(ID16.random(), wskA, epoch: 2), cards: cards, epochs: epochs).status == 403)
        #expect(DropClaim.check(stored: &unknown, claim: "junk", cards: cards, epochs: epochs).status == 403)
        // the loser learns the winner
        let lost = DropClaim.check(stored: &s, claim: try claim(b, wskB, epoch: 5), cards: cards, epochs: epochs)
        #expect(lost.status == 409 && lost.error == "already_claimed" && lost.claimedBy == a)
    }
}
