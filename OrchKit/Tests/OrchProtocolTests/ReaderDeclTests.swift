import CryptoKit
import Foundation
import OrchTestVectors
import Testing
@testable import OrchProtocol

/// H12d: the runtime view KAT and the reader_decl object, against orch-core's `reader_kat_1.json` and orch-relay's `reader_decl` vectors.
enum ReaderVectors {
    static let kat = F1Vectors.load("reader_kat_1")
    static let relay: JSONValue = try! StrictJSON.parse(OrchTestVectors.Vectors.readerDecl, maxBytes: .max, maxDepth: 64)
    static var group: JSONValue { relay["reader_decl"] }
    static func signer(_ name: String) -> SoftwareSigner { try! SoftwareSigner(testScalar: scalar(fromSeed: relay["keys"][name]["seed"].hexData)) }
    static func kx(_ name: String) -> AgreementPublicKey { relay["keys"][name]["pub"].kxPub }
    static func sig(_ name: String) -> SigningPublicKey { relay["keys"][name]["pub"].sigPub }
    static var workspace: ID16 { relay["ids"]["workspace_a"].id }

    static func context(_ c: JSONValue) -> ReaderDecl.Context {
        var ctx = ReaderDecl.Context(workspace: c["workspace_id"].id, dkSig: c["dk_sig_pub"].sigPub, dkKx: c["dk_kx_pub"].kxPub, who: c["who"], bind: c["bind"])
        ctx.hostMax = Int(c["host_max"].i64)
        ctx.surfaces = c["surfaces"].items.map(\.str)
        for (level, surfaces) in c["kat"].object ?? [:] { ctx.expectedKAT[Int(level)!] = (surfaces.object ?? [:]).mapValues(\.str) }
        return ctx
    }
}

@Suite struct ReaderKATTests {
    @Test func viewDigestEqualsCoresVector() throws {
        let expected = ReaderVectors.kat["expected"]["1"]["view"].str
        #expect(expected == ReaderKAT.expectedView1)
        let results = ReaderKAT.results1(parse: ReaderKAT.productionParser)
        #expect(ReaderKAT.digest(results) == expected)
        #expect(ReaderKAT.digest(results) == ReaderVectors.kat["view"]["digest"].str)
        #expect(results.map(\.accepted) == [true, true, false])
        #expect(results.map(\.auth) == ["convenience", "passphrase", nil])
        #expect(ReaderKAT.current == ReaderKAT.Capability(level: 1, kat: [1: ["view": expected]]))
        #expect(ReaderKAT.runningLevel == 1)
    }

    @Test func viewIDsAndCaseOrderMatchTheVector() {
        #expect(ReaderKAT.views1 == ["ticket.get.questions.answer"])
        let cases = ReaderVectors.kat["view"]["cases"].items
        #expect(cases.map { $0["view"].str } == Array(repeating: ReaderKAT.views1[0], count: 3))
        #expect(cases.map { $0["expect"]["auth"].string } == ["convenience", "passphrase", nil])
        #expect(cases.map { $0["expect"]["accepted"].bool } == [true, true, false])
    }

    /// The vector's own objects have no `answer.id` (v1.7), which the phone's parser requires; with an id added they must classify exactly
    /// as the vector says, and our corpus differs from them only in that field.
    @Test func vectorObjectsClassifyLikeCore() throws {
        for c in ReaderVectors.kat["view"]["cases"].items {
            var o = c["object"].object!
            var answer = o["answer"]!.object!
            answer["id"] = "01J9ZK00000000000000000003"
            o["answer"] = .object(answer)
            let got = ReaderKAT.productionParser(.object(o))
            #expect(got == c["expect"]["auth"].string)
            let auth = c["object"]["answer"]["signer"]["auth"].str
            #expect(try canonicalJSON(ReaderKAT.corpusEntry(auth: auth)) == canonicalJSON(.object(o)))
        }
    }

    @Test func aLenientParserFailsTheKATAndDeclaresNothing() {
        // maps an unknown auth to a known one (the dashboard bug class)
        let lenient: (JSONValue) -> String? = { v in ReaderKAT.productionParser(v) ?? "passphrase" }
        #expect(ReaderKAT.capability(parse: lenient) == nil)
        // refuses convenience (a pre-H12d parser)
        let old: (JSONValue) -> String? = { v in ReaderKAT.productionParser(v).flatMap { $0 == "convenience" ? nil : $0 } }
        #expect(ReaderKAT.capability(parse: old) == nil)
        // accepts everything but reports the wrong value
        let wrong: (JSONValue) -> String? = { v in ReaderKAT.productionParser(v) == nil ? nil : "passphrase" }
        #expect(ReaderKAT.capability(parse: wrong) == nil)
        #expect(ReaderKAT.capability(parse: ReaderKAT.productionParser) != nil)
    }

    @Test func labelMatchesCore() {
        #expect(F1Vectors.load("labels")["labels"]["sig_reader_decl"].str == Label.sigReaderDecl)
        #expect(ReaderVectors.group["label"].str == Label.sigReaderDecl)
    }
}

@Suite struct ReaderDeclObjectTests {
    /// Every relay `reader_decl.decls` case through the phone's check: same verdict, level and digest.
    @Test func relayDeclCasesAgree() {
        let cases = ReaderVectors.group["decls"].items
        #expect(cases.count >= 30)
        for c in cases {
            let got = ReaderDecl.check(c["decl"], ReaderVectors.context(c["ctx"]))
            let expect = c["expect"]
            if let ok = expect["ok"].object {
                guard case .success(let level) = got else { Issue.record("\(c["name"].str): \(got)"); continue }
                #expect(Int64(level) == ok["level"]?.int, Comment(rawValue: c["name"].str))
                #expect((try? ReaderDeclaration(signed: c["decl"]).digest) == ok["digest"]?.string, Comment(rawValue: c["name"].str))
            } else {
                #expect(got == .failure(ReaderDecl.Reason(rawValue: expect["reason"].str)!), Comment(rawValue: c["name"].str))
            }
        }
    }

    @Test func buildsTheVectorDeclarationByteExactAndSignsIt() throws {
        let want = ReaderVectors.group["digest"]["decl"]
        let o = want["o"]
        let signer = ReaderVectors.signer("phone.sig")
        let pin = B64U.decode(o["who"]["pk_pin"].str)!
        let bind = ReaderDeclaration.Bind.pair(offer: o["bind"]["offer_id"].id, attempt: o["bind"]["attempt"].str)
        let d = try ReaderDeclaration.make(workspace: ReaderVectors.workspace, dkSig: ReaderVectors.sig("phone.sig"), dkKx: ReaderVectors.kx("phone.kx"),
                                           who: .pkPin(pin), level: 1, kat: [1: ["view": ReaderKAT.expectedView1]], bind: bind,
                                           createdMs: o["created_ms"].i64, signer: signer)
        // the signed object `o` is byte-identical to the vector's (ECDSA signatures are randomised, so `sig` itself is verified, not compared)
        #expect(try canonicalJSON(d.json["o"]) == canonicalJSON(o))
        #expect(Int64(d.bytes.count) == ReaderVectors.group["digest"]["cj_bytes"].int)
        let ctx = ReaderDecl.Context(workspace: ReaderVectors.workspace, dkSig: ReaderVectors.sig("phone.sig"), dkKx: ReaderVectors.kx("phone.kx"),
                                     who: .pkPin(pin), bind: bind)
        #expect(ReaderDecl.check(d.json, ctx) == .success(1))
        // the vector's own signature verifies under the same label, computed here without ReaderDecl
        let sig = want["sig"].b64Data
        #expect(Signature.verify(ReaderVectors.sig("phone.sig"), signature: sig, label: "orch/v2/sig/reader-decl|", message: try canonicalJSON(o)))
        #expect(d.level == 1 && d.via == "pair" && d.createdMs == 1_790_000_000_000)
    }

    @Test func declareBindingAndLevelZero() throws {
        let signer = ReaderVectors.signer("phone.sig")
        let d = try ReaderDeclaration.make(workspace: ReaderVectors.workspace, dkSig: signer.publicKey, dkKx: ReaderVectors.kx("phone.kx"),
                                           who: .person(ReaderVectors.relay["ids"]["person_alice"].id), level: 1, kat: [1: ["view": ReaderKAT.expectedView1]],
                                           bind: .declare, createdMs: 1_790_000_001_000, signer: signer)
        #expect(d.json["o"]["bind"] == ["via": "declare"])
        var ctx = ReaderDecl.Context(workspace: ReaderVectors.workspace, dkSig: signer.publicKey, dkKx: ReaderVectors.kx("phone.kx"),
                                     who: .person(ReaderVectors.relay["ids"]["person_alice"].id), bind: .declare)
        ctx.expectedKAT = [1: ["view": ReaderKAT.expectedView1]]
        #expect(ReaderDecl.check(d.json, ctx) == .success(1))
        // a wrong digest, binding or person is refused
        ctx.expectedKAT = [1: ["view": "sha256:" + String(repeating: "0", count: 64)]]
        #expect(ReaderDecl.check(d.json, ctx) == .failure(.katMismatch))
        // level 0 carries no kat and is valid
        let z = try ReaderDeclaration.make(workspace: ReaderVectors.workspace, dkSig: signer.publicKey, dkKx: ReaderVectors.kx("phone.kx"),
                                           who: .person(ReaderVectors.relay["ids"]["person_alice"].id), level: 0, kat: [:], bind: .declare,
                                           createdMs: 1, signer: signer)
        ctx.expectedKAT = [:]
        #expect(ReaderDecl.check(z.json, ctx) == .success(0))
        // a level above the supplied kat cannot be built
        #expect(throws: Refusal.self) {
            try ReaderDeclaration.make(workspace: ReaderVectors.workspace, dkSig: signer.publicKey, dkKx: ReaderVectors.kx("phone.kx"),
                                       who: .person(ReaderVectors.relay["ids"]["person_alice"].id), level: 1, kat: [:], bind: .declare, createdMs: 1, signer: signer)
        }
    }

    @Test func rdIsTheDigestOfTheWholeSignedObjectAndStable() throws {
        let g = ReaderVectors.group
        let d = try ReaderDeclaration(signed: g["digest"]["decl"])
        #expect(d.digest == g["digest"]["rd"].str)
        #expect(d.digest == "sha256:" + Hex.encode(SHA256.hash(data: try canonicalJSON(g["digest"]["decl"]))))
        // parsing the stored bytes again gives the same digest (a resend and a restart see one rd)
        #expect(try ReaderDeclaration.parse(d.bytes).digest == d.digest)
        let later = try ReaderDeclaration(signed: g["later_declaration"]["decl"])
        #expect(later.digest == g["later_declaration"]["rd"].str)
        #expect(later.digest != d.digest)
    }

    @Test func parseChecksTheByteCapBeforeParsing() {
        #expect(throws: Refusal.self) { try ReaderDeclaration.parse(Data(repeating: 0x20, count: 4096)) }
        #expect(throws: (any Error).self) { try ReaderDeclaration.parse(Data("{\"o\":{},\"sig\":1}".utf8)) }
    }
}
