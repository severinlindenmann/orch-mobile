import CryptoKit
import Foundation
import Testing
@testable import OrchProtocol

@Suite struct PhoneEventsTests {
    let v = F1Vectors.load("phone_events")
    var wsid: ID16 { ID16(hex: v["workspace_id"].str)! }
    var phoneKey: SigningPublicKey { SigningPublicKey.fromB64u(v["keys"]["dk_sevp1"]["pub_b64u"].str) }

    func actor(_ submitted: JSONValue) throws -> PhoneActor {
        let a = submitted["actor"]
        let person = ID16(hex: String(a["id"].str.dropFirst(2)))!, device = ID16(hex: String(a["device"].str.dropFirst(2)))!
        return try PhoneActor(person: person, device: device, auth: F1Auth(wire: submitted["auth"].str)!)
    }

    func withoutSig(_ s: JSONValue) -> [String: JSONValue] {
        var o = s.object!; o["sig"] = nil; return o
    }

    /// The question as `ticket.get` would send it, rebuilt from the vector's hashed values.
    func questionView(_ c: JSONValue) -> JSONValue {
        let h = c["question"]["hashed"]
        var q: [String: JSONValue] = ["id": c["submitted"]["question"], "state": "open", "to": [], "blocking": false,
                                      "answered_by": .null, "answered_seq": .null, "text": h["text"],
                                      "qid": c["question"]["qid"], "hash": c["question"]["hash"]]
        if !h["options"].items.isEmpty { q["options"] = h["options"] }
        return .object(q)
    }

    func build(_ c: JSONValue, signer: SoftwareSigner) throws -> SignedPhoneEvent {
        let s = c["submitted"]
        let a = try actor(s)
        if s["type"].str == "ticket.created" {
            return try PhoneEvents.create(ticketUID: c["log"].str, key: s["key"].str, ticketType: s["ticket_type"].str,
                                          title: PhoneEvents.prepareText(s["title"].str, oneLine: true),
                                          id: s["id"].str, rosterV: s["roster_v"].i64, actor: a, workspace: wsid, signer: signer)
        }
        let q = try F1Question(questionView(c))
        let r = try q.reviewed(ticketUID: c["log"].str, workspace: wsid, basedOn: s["based_on"].str, rosterV: s["roster_v"].i64)
        let text = try s["text"].string.map { try PhoneEvents.prepareText($0, oneLine: false) }
        return try PhoneEvents.answer(r, option: s["option"].string, text: text, id: s["id"].str, actor: a, workspace: wsid, signer: signer)
    }

    @Test func acceptedCasesReproduceCoreBytes() throws {
        let signer = F1Vectors.signer(v["keys"], "dk_sevp1")
        #expect(signer.publicKey == phoneKey)
        let cases = v["accepted"].items
        #expect(cases.count == 7)
        for c in cases {
            let name = c["name"].str
            let e = try build(c, signer: signer)
            #expect(e.event["sig"] != nil, "\(name)")
            var unsigned = e.event; unsigned["sig"] = nil
            #expect(unsigned == withoutSig(c["submitted"]), "\(name) fields")
            #expect(Hex.encode(e.signingBytes) == c["person_signing_hex"].str, "\(name) signing bytes")
            #expect(e.digest == c["digest"].str, "\(name) digest")
            // the submitted form is cj of the vector's submitted event, up to the (randomised) signature value
            var theirs = c["submitted"].object!; theirs["sig"] = .string(B64U.encode(e.signature))
            #expect(e.bytes == (try canonicalJSON(.object(theirs))), "\(name) cj")
            #expect(e.signature.count == 64)
            #expect(B64U.encode(e.signature).count == 86)
            // our signature and core's stored one both verify over the same bytes
            let label = Data(Label.sigTicketEvent.utf8)
            let msg = Data(e.signingBytes.dropFirst(label.count))
            #expect(Signature.verify(phoneKey, signature: e.signature, label: Label.sigTicketEvent, message: msg), "\(name) own sig")
            #expect(Signature.verify(phoneKey, signature: c["sig"].b64Data, label: Label.sigTicketEvent, message: msg), "\(name) core sig")
            #expect(e.id == c["submitted"]["id"].str)
            #expect(e.log == c["log"].str)
        }
    }

    @Test func submittedCjMatchesTheVectorForTheStoredSignature() throws {
        for c in v["accepted"].items {
            #expect(String(decoding: try canonicalJSON(c["submitted"]), as: UTF8.self) == c["submitted_cj"].str)
        }
    }

    /// Which refused cases of core carry a signature that verifies over the phone's signing bytes. Every case is listed: a new case in the
    /// vector fails this test until it is classified. (The refusals themselves are host/model rules; only the signature is checkable here.)
    @Test func everyRefusedCaseSignatureIsClassified() throws {
        let expectedValid: [String: Bool] = [
            "question_stale": true, "members_stale": true, "bad_base": true, "sig_invalid": false, "device_scope": false,   // device_scope: not signed by dk_sevp1
           
            "duplicate_id": true, "taken_key": true, "abandoned_replayed": true,
        ]
        let cases = v["refused"].items
        #expect(cases.count == expectedValid.count)
        for c in cases {
            let s = c["submitted"]
            let bytes = try PhoneEvents.signingBytes(event: withoutSig(s), log: c["log"].str, workspace: wsid)
            let label = Data(Label.sigTicketEvent.utf8)
            let ok = Signature.verify(phoneKey, signature: s["sig"].b64Data, label: Label.sigTicketEvent, message: Data(bytes.dropFirst(label.count)))
            #expect(expectedValid[c["name"].str] == ok, "\(c["name"].str)")
        }
    }

    // MARK: builder rules

    let base = "sha256:" + String(repeating: "a", count: 64)
    func reviewedQuestion(base: String? = nil, roster: Int64 = 3) throws -> F1Question.Reviewed {
        let c = v["accepted"][0]
        return try F1Question(questionView(c)).reviewed(ticketUID: c["log"].str, workspace: wsid, basedOn: base ?? self.base, rosterV: roster)
    }
    func pt(_ s: String, oneLine: Bool = false) throws -> PhoneEvents.PreparedText { try PhoneEvents.prepareText(s, oneLine: oneLine) }
    let id = "01M4JM4RKG79RG3QTWCP60NNNG"

    func me(_ auth: F1Auth = .secureEnclaveUnlocked) throws -> PhoneActor {
        try PhoneActor(person: ID16(hex: String(repeating: "1", count: 32))!, device: ID16(hex: String(repeating: "2", count: 32))!, auth: auth)
    }

    @Test func columnROnlyAcceptsTwoAuthValues() {
        let p = ID16(hex: String(repeating: "1", count: 32))!
        for a in [F1Auth.convenience, .secureEnclave, .webauthn, .tpm, .windowsHello] { #expect((try? PhoneActor(person: p, device: p, auth: a)) == nil) }
        #expect((try? PhoneActor(person: p, device: p, auth: .passphrase)) != nil)
    }

    @Test func answerValidation() throws {
        let r = try reviewedQuestion()
        let s = SoftwareSigner()
        let a = try me()
        func go(option: String? = "csv", text: PhoneEvents.PreparedText? = nil, id: String = id) throws -> SignedPhoneEvent {
            try PhoneEvents.answer(r, option: option, text: text, id: id, actor: a, workspace: wsid, signer: s)
        }
        #expect((try? go()) != nil)
        #expect((try? go(option: "nope")) == nil)
        #expect((try? go(option: nil, text: nil)) == nil)
        #expect((try? go(option: nil, text: pt("free"))) != nil)
        #expect((try? go(option: "csv", text: pt("both"))) != nil)
        #expect((try? go(option: nil, text: pt(""))) == nil)
        #expect((try? go(option: nil, text: pt(String(repeating: "x", count: 4096)))) != nil)
        #expect((try? go(option: nil, text: pt(String(repeating: "x", count: 4097)))) == nil)
        #expect((try? go(option: nil, text: pt(String(repeating: "\u{E9}", count: 2049)))) == nil)   // 4098 bytes
        #expect((try? go(id: "01m4jm4rkg79rg3qtwcp60nnng")) == nil)
        #expect((try? go(id: "81M4JM4RKG79RG3QTWCP60NNNG")) == nil)
        let ev = try go(option: "csv", text: pt("ok\tfine"))
        #expect(Set(ev.event.keys) == ["actor", "auth", "based_on", "hash", "hash_v", "id", "option", "question", "roster_v", "sig", "text", "type", "v"])
        #expect(ev.event["based_on"] == .string(base))
        #expect(ev.event["roster_v"] == .int(3))
    }

    @Test func snapshotValuesTravelInsideReviewed() {
        #expect((try? reviewedQuestion(base: "sha256:abc")) == nil)
        #expect((try? reviewedQuestion(roster: -1)) == nil)
    }

    @Test func phoneAuthoredTextMustGoThroughPrepareText() {
        #expect((try? pt("a\rb")) != nil)               // CR becomes LF
        #expect((try? pt("x\u{202E}")) == nil)          // bidi control: refused, not repaired
        #expect((try? pt("two\nlines", oneLine: true)) == nil)
        #expect((try? pt("x\u{323B0}")) == nil)         // assigned only after Unicode 16.0
    }

    @Test func creationValidation() throws {
        let s = SoftwareSigner()
        let a = try me()
        let uid = "01J9ZK4Q7M3R8T2V6X0B5N1C9F"
        func go(key: String = "DEMO-0002", type: String = "feature", title: PhoneEvents.PreparedText? = nil) throws -> SignedPhoneEvent {
            try PhoneEvents.create(ticketUID: uid, key: key, ticketType: type, title: title ?? pt("Check the tariff seeds", oneLine: true), id: id,
                                   rosterV: 3, actor: a, workspace: wsid, signer: s)
        }
        let ev = try go()
        #expect(Set(ev.event.keys) == ["actor", "auth", "based_on", "hash_v", "id", "key", "owner", "roster_v", "sig", "ticket_type", "title", "type", "v"])
        #expect(ev.event["based_on"] == .null)
        #expect(ev.event["owner"] == .string(a.personID))
        #expect(ev.log == uid)
        for t in PhoneEvents.ticketTypes { #expect((try? go(type: t)) != nil) }
        #expect((try? go(type: "story")) == nil)
        #expect((try? go(key: "demo-0002")) == nil)
        #expect((try? go(key: "DEMO-02")) == nil)
        #expect((try? go(title: pt("", oneLine: true))) == nil)
        #expect((try? go(title: pt("multi\nline"))) == nil)   // prepared as multi-line text: not a title
        #expect((try? go(title: pt(String(repeating: "t", count: 200), oneLine: true))) != nil)
        #expect((try? go(title: pt(String(repeating: "t", count: 201), oneLine: true))) == nil)
        #expect((try? go(title: pt(String(repeating: "\u{1F600}", count: 200), oneLine: true))) != nil)   // scalars, not bytes
        #expect((try? PhoneEvents.create(ticketUID: "bad", key: "DEMO-0002", ticketType: "bug", title: pt("t", oneLine: true), id: id, rosterV: 3,
                                         actor: a, workspace: wsid, signer: s)) == nil)
    }

    @Test func prepareTextNormalisesBeforeTheSignSheet() throws {
        #expect(try PhoneEvents.prepareText("cafe\u{301}\r\n", oneLine: false).value == "caf\u{E9}\n")
    }

    @Test func signingBytesAndDigestAreDeterministicUnlikeTheSignature() throws {
        let c = v["accepted"][4]
        let s = F1Vectors.signer(v["keys"], "dk_sevp1")
        let a = try build(c, signer: s), b = try build(c, signer: s)
        #expect(a.signingBytes == b.signingBytes)
        #expect(a.digest == b.digest)   // signature is randomised, the content digest is not
        #expect(a.digest == digestOf(a.signingBytes))
    }

    func digestOf(_ d: Data) -> String { "sha256:" + Hex.encode(SHA256.hash(data: d)) }
}

extension SigningPublicKey {
    static func fromB64u(_ s: String) -> SigningPublicKey { try! SigningPublicKey(x963: B64U.decode(s)!) }
}

@Suite struct ULIDTests {
    @Test func formatAndTime() throws {
        let id = try ULID.make(timeMs: 1_790_000_000_000, random: Data(repeating: 0xFF, count: 10))
        let expected: Int64 = 1_790_000_000_000   // typed constant: an untyped literal in #expect against Int64? mis-compared once (see PhoneEventIDsTests)
        #expect(id.count == 26)
        #expect(ULID.isValid(id))
        #expect(ULID.timeMs(of: id) == expected)
        #expect(id.hasSuffix("ZZZZZZZZZZZZZZZZ"))
    }

    @Test func knownAnswers() throws {
        #expect(try ULID.make(timeMs: 0, random: Data(repeating: 0, count: 10)) == "00000000000000000000000000")
        // 2^48 - 1 ms is the largest time: first char 7
        #expect(try ULID.make(timeMs: (1 << 48) - 1, random: Data(repeating: 0xFF, count: 10)) == "7ZZZZZZZZZZZZZZZZZZZZZZZZZ")
        // the vectors' ids decode to their times
        let v = F1Vectors.load("phone_events")
        for c in v["accepted"].items {
            let id = c["submitted"]["id"].str
            #expect(ULID.isValid(id))
            #expect(try ULID.make(timeMs: ULID.timeMs(of: id)!, random: randomPart(id)) == id)
        }
    }

    func randomPart(_ id: String) -> Data {
        // re-derive the 80 random bits from characters 10...25 (16 chars x 5 bits)
        let alpha = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var bits = "", out = [UInt8]()
        for ch in id.dropFirst(10) { bits += String(String(alpha.firstIndex(of: ch)!, radix: 2).leftPad(5)) }
        var i = bits.startIndex
        while i < bits.endIndex { let j = bits.index(i, offsetBy: 8); out.append(UInt8(bits[i..<j], radix: 2)!); i = j }
        return Data(out)
    }

    @Test func rejectsBadInputs() {
        #expect(throws: ULID.Failure.timeOutOfRange) { try ULID.make(timeMs: -1, random: Data(count: 10)) }
        #expect(throws: ULID.Failure.timeOutOfRange) { try ULID.make(timeMs: 1 << 48, random: Data(count: 10)) }
        #expect(throws: ULID.Failure.badRandomLength) { try ULID.make(timeMs: 1, random: Data(count: 9)) }
        for bad in ["", "8ZZZZZZZZZZZZZZZZZZZZZZZZZ", "0000000000000000000000000I", "0000000000000000000000000L", "0000000000000000000000000O",
                    "0000000000000000000000000U", "0000000000000000000000000a", "000000000000000000000000000"] {
            #expect(!ULID.isValid(bad), "\(bad)")
        }
    }

    @Test func hostWindowEdges() throws {
        let now: Int64 = 1_790_000_000_000
        func id(_ t: Int64) throws -> String { try ULID.make(timeMs: t, random: Data(count: 10)) }
        #expect(ULID.isInsideHostWindow(try id(now - 900_000), hostNowMs: now))
        #expect(!ULID.isInsideHostWindow(try id(now - 900_001), hostNowMs: now))
        #expect(ULID.isInsideHostWindow(try id(now + 300_000), hostNowMs: now))
        #expect(!ULID.isInsideHostWindow(try id(now + 300_001), hostNowMs: now))
        #expect(!ULID.isInsideHostWindow(try id(now), hostNowMs: Int64.max))   // saturates, does not trap
        #expect(!ULID.isInsideHostWindow(try id(0), hostNowMs: Int64.min))
        #expect(ULID.outboxMaxAgeMs == 840_000)
    }
}

extension String {
    func leftPad(_ n: Int) -> String { String(repeating: "0", count: max(0, n - count)) + self }
}

@Suite struct FieldRules {
    /// Foundation's NFC follows the OS Unicode version and is wrong for some sequences; signing and hashing paths use `F1Text.nfc`.
    @Test func noFoundationNFCInOrchProtocol() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OrchProtocol")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count > 10)
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            let uses = text.components(separatedBy: "\n").filter { $0.contains("precomposedStringWithCanonicalMapping") && !$0.contains("///") }
            #expect(uses.isEmpty, "\(f.lastPathComponent)")
        }
    }

    @Test func unicodeTablesMatchTheirPinnedDigest() {
        let blocks = [("assigned", Unicode16Data.assigned), ("ccc", Unicode16Data.ccc), ("decomp", Unicode16Data.decomp), ("composable", Unicode16Data.composable)]
        var h = SHA256()
        for (n, b) in blocks { h.update(data: Data((n + "\n" + b + "\n").utf8)) }
        #expect(Hex.encode(h.finalize()) == Unicode16Data.digest)
    }
}
