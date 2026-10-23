import CryptoKit
import Foundation
import Testing
@testable import OrchProtocol

/// `PhoneEvents.validateSigned` (C2b): P1 to P5, P4 actor equality, and the signature recomputed from the event itself.
@Suite struct PhoneEventsValidateTests {
    let v = F1Vectors.load("phone_events")
    var wsid: ID16 { ID16(hex: v["workspace_id"].str)! }
    var phoneKey: SigningPublicKey { SigningPublicKey.fromB64u(v["keys"]["dk_sevp1"]["pub_b64u"].str) }
    var signer: SoftwareSigner { F1Vectors.signer(v["keys"], "dk_sevp1") }

    func actor(_ s: JSONValue) throws -> PhoneActor {
        let a = s["actor"]
        return try PhoneActor(person: ID16(hex: String(a["id"].str.dropFirst(2)))!, device: ID16(hex: String(a["device"].str.dropFirst(2)))!,
                              auth: F1Auth(wire: s["auth"].str)!)
    }

    /// The vector's submitted form exactly as core stored it (core's signature, core's signing bytes).
    func vectorEvent(_ c: JSONValue) throws -> SignedPhoneEvent {
        let s = c["submitted"]
        let kind: SignedPhoneEvent.Kind = s["type"].str == "ticket.created" ? .ticketCreated : .questionAnswered
        return SignedPhoneEvent(kind: kind, log: c["log"].str, id: s["id"].str, event: s.object!, bytes: try canonicalJSON(s),
                                signingBytes: Hex.decode(c["person_signing_hex"].str)!, digest: c["digest"].str, signature: c["sig"].b64Data)
    }

    /// Re-signs an arbitrary (possibly invalid) event under the vector key, so that only the field under test is wrong.
    func resigned(_ ev: [String: JSONValue], kind: SignedPhoneEvent.Kind, log: String) throws -> SignedPhoneEvent {
        var e = ev; e["sig"] = nil
        let bytes = try PhoneEvents.signingBytes(event: e, log: log, workspace: wsid)
        let sig = try Signature.sign(signer, label: Label.sigTicketEvent, message: Data(bytes.dropFirst(Label.sigTicketEvent.utf8.count)))
        e["sig"] = .string(B64U.encode(sig))
        return SignedPhoneEvent(kind: kind, log: log, id: e["id"]?.string ?? "", event: e, bytes: try canonicalJSON(.object(e)), signingBytes: bytes,
                                digest: PhoneEvents.digest(signingBytes: bytes), signature: sig)
    }

    func accepted(_ name: String) -> JSONValue { v["accepted"].items.first { $0["name"].str == name }! }

    func validate(_ e: SignedPhoneEvent, _ c: JSONValue, actor a: PhoneActor? = nil, pub: SigningPublicKey? = nil) throws {
        try PhoneEvents.validateSigned(e, kind: e.kind, actor: try a ?? actor(c["submitted"]), workspace: wsid, pub: pub ?? phoneKey)
    }

    @Test func everySubmittedFormOfTheVectorValidates() throws {
        #expect(v["accepted"].items.count == 7)
        for c in v["accepted"].items {
            // core's own signature over core's bytes, then ours
            try validate(try vectorEvent(c), c)
        }
    }

    @Test func aFreshlySignedEventValidates() throws {
        let c = accepted("creation")
        let s = c["submitted"], a = try actor(s)
        let u = try PhoneEvents.unsignedCreate(ticketUID: c["log"].str, key: s["key"].str, ticketType: s["ticket_type"].str,
                                               title: PhoneEvents.prepareText(s["title"].str, oneLine: true), id: s["id"].str,
                                               rosterV: s["roster_v"].i64, actor: a, workspace: wsid)
        #expect(u.event["sig"] == nil)
        let e = try PhoneEvents.sign(u, signer: signer)
        try validate(e, c)
    }

    @Test func unsignedAnswerEqualsTheSignedEventWithoutSig() throws {
        let c = accepted("answer_passphrase"), s = c["submitted"]
        let h = c["question"]["hashed"]
        var q: [String: JSONValue] = ["id": s["question"], "state": "open", "to": [], "blocking": false, "answered_by": .null, "answered_seq": .null,
                                      "text": h["text"], "spec": h["spec"], "qid": c["question"]["qid"], "hash": c["question"]["hash"]]
        if !h["options"].items.isEmpty { q["options"] = h["options"] }
        let r = try F1Question(.object(q)).reviewed(ticketUID: c["log"].str, workspace: wsid, basedOn: s["based_on"].str, rosterV: s["roster_v"].i64)
        let text = try s["text"].string.map { try PhoneEvents.prepareText($0, oneLine: false) }
        let u = try PhoneEvents.unsignedAnswer(r, option: s["option"].string, text: text, id: s["id"].str, actor: try actor(s), workspace: wsid)
        let signed = try PhoneEvents.sign(u, signer: signer)
        var withoutSig = signed.event; withoutSig["sig"] = nil
        #expect(u.event == withoutSig && u.id == signed.id && u.log == signed.log)
        try validate(signed, c)
    }

    @Test func refusesHostFields() throws {
        let c = accepted("creation")
        for f in ["seq", "at", "prev", "ws_seq", "host_sig"] {
            var ev = c["submitted"].object!; ev[f] = f == "at" ? .string("2026-10-10T10:01:10Z") : .int(7)
            let e = try resigned(ev, kind: .ticketCreated, log: c["log"].str)
            #expect(throws: PhoneEvents.Failure.hostField(f)) { try validate(e, c) }
        }
    }

    @Test func refusesSchemaViolations() throws {
        let c = accepted("creation"), log = c["log"].str
        func mutate(_ f: (inout [String: JSONValue]) -> Void) throws -> SignedPhoneEvent {
            var ev = c["submitted"].object!; f(&ev); return try resigned(ev, kind: .ticketCreated, log: log)
        }
        let cases: [(String, (inout [String: JSONValue]) -> Void)] = [
            ("extra field", { $0["note"] = "x" }), ("missing owner", { $0["owner"] = nil }), ("v", { $0["v"] = 1 }), ("hash_v", { $0["hash_v"] = 2 }),
            ("type", { $0["type"] = "question.answered" }), ("based_on", { $0["based_on"] = .string("sha256:" + String(repeating: "a", count: 64)) }),
            ("key", { $0["key"] = "demo-1" }), ("ticket_type", { $0["ticket_type"] = "Bug" }), ("empty title", { $0["title"] = "" }),
            ("two lines", { $0["title"] = "a\nb" }), ("control", { $0["title"] = "a\u{7}b" }), ("bidi", { $0["title"] = "a\u{202E}b" }),
            ("id", { $0["id"] = "nope" }), ("roster", { $0["roster_v"] = -1 }),
        ]
        for (name, f) in cases {
            let e = try mutate(f)
            #expect(throws: PhoneEvents.Failure.self, "\(name)") { try validate(e, c) }
        }
        // an answer with neither option nor text, and a long text
        let a = accepted("answer_passphrase")
        var ev = a["submitted"].object!; ev["option"] = nil; ev["text"] = nil
        let none = try resigned(ev, kind: .questionAnswered, log: a["log"].str)
        #expect(throws: PhoneEvents.Failure.schema("answer")) { try validate(none, a) }
        ev["text"] = .string(String(repeating: "a", count: 4097))
        let long = try resigned(ev, kind: .questionAnswered, log: a["log"].str)
        #expect(throws: PhoneEvents.Failure.textTooLong) { try validate(long, a) }
    }

    @Test func refusesAnotherActorDeviceOrAuth() throws {
        // P4: the event must be signed as exactly the (person, device, auth) this device is
        let c = accepted("creation"), a = try actor(c["submitted"])
        let e = try vectorEvent(c)
        let other = ID16(hex: String(repeating: "9", count: 32))!
        let person = ID16(hex: String(c["submitted"]["actor"]["id"].str.dropFirst(2)))!, device = ID16(hex: String(c["submitted"]["actor"]["device"].str.dropFirst(2)))!
        #expect(throws: PhoneEvents.Failure.actorMismatch) { try validate(e, c, actor: try PhoneActor(person: other, device: device, auth: a.auth)) }
        #expect(throws: PhoneEvents.Failure.actorMismatch) { try validate(e, c, actor: try PhoneActor(person: person, device: other, auth: a.auth)) }
        let flipped: F1Auth = a.auth == .passphrase ? .secureEnclaveUnlocked : .passphrase
        #expect(throws: PhoneEvents.Failure.actorMismatch) { try validate(e, c, actor: try PhoneActor(person: person, device: device, auth: flipped)) }
        // the event itself naming another person/device/auth, validly signed
        for (field, value) in [("id", "p_" + String(repeating: "9", count: 32)), ("device", "d_" + String(repeating: "9", count: 32))] {
            var ev = c["submitted"].object!
            var act = ev["actor"]!.object!; act[field] = .string(value); ev["actor"] = .object(act)
            #expect(throws: PhoneEvents.Failure.actorMismatch) { try validate(try resigned(ev, kind: .ticketCreated, log: c["log"].str), c) }
        }
        var ev = c["submitted"].object!; ev["auth"] = .string(flipped.rawValue)
        #expect(throws: PhoneEvents.Failure.actorMismatch) { try validate(try resigned(ev, kind: .ticketCreated, log: c["log"].str), c) }
        // a creation owned by someone else
        ev = c["submitted"].object!; ev["owner"] = .string("p_" + String(repeating: "9", count: 32))
        #expect(throws: PhoneEvents.Failure.actorMismatch) { try validate(try resigned(ev, kind: .ticketCreated, log: c["log"].str), c) }
    }

    @Test func refusesASignatureOverOtherBytes() throws {
        let c = accepted("creation")
        let good = try vectorEvent(c)
        // another key
        let stranger = try SoftwareSigner(testScalar: Data(repeating: 7, count: 32))
        #expect(throws: PhoneEvents.Failure.badSignature) { try validate(good, c, pub: stranger.publicKey) }
        // the event changed after signing, with the cached bytes recomputed to match: the signature no longer fits
        var ev = good.event; ev["title"] = "Another title"
        let tampered = SignedPhoneEvent(kind: .ticketCreated, log: good.log, id: good.id, event: ev, bytes: try canonicalJSON(.object(ev)),
                                        signingBytes: good.signingBytes, digest: good.digest, signature: good.signature)
        #expect(throws: PhoneEvents.Failure.badSignature) { try validate(tampered, c) }
        // the log is part of the signed bytes
        let otherLog = SignedPhoneEvent(kind: .ticketCreated, log: String(good.log.dropLast()) + (good.log.hasSuffix("0") ? "1" : "0"), id: good.id, event: good.event, bytes: good.bytes,
                                        signingBytes: good.signingBytes, digest: good.digest, signature: good.signature)
        #expect(throws: PhoneEvents.Failure.badSignature) { try validate(otherLog, c) }
        // another workspace
        #expect(throws: PhoneEvents.Failure.badSignature) {
            try PhoneEvents.validateSigned(good, kind: .ticketCreated, actor: try actor(c["submitted"]), workspace: ID16(hex: String(repeating: "1", count: 32))!, pub: phoneKey)
        }
        // an `sig` field that is not 64 bytes of base64url
        var short = good.event; short["sig"] = "AAAA"
        #expect(throws: PhoneEvents.Failure.schema("sig")) {
            try validate(SignedPhoneEvent(kind: .ticketCreated, log: good.log, id: good.id, event: short, bytes: good.bytes, signingBytes: good.signingBytes,
                                          digest: good.digest, signature: good.signature), c)
        }
    }

    @Test func refusesInconsistentCachedFields() throws {
        let c = accepted("creation")
        let g = try vectorEvent(c)
        func with(id: String? = nil, log: String? = nil, bytes: Data? = nil, signingBytes: Data? = nil, digest: String? = nil, signature: Data? = nil,
                  kind: SignedPhoneEvent.Kind? = nil) -> SignedPhoneEvent {
            SignedPhoneEvent(kind: kind ?? g.kind, log: log ?? g.log, id: id ?? g.id, event: g.event, bytes: bytes ?? g.bytes,
                             signingBytes: signingBytes ?? g.signingBytes, digest: digest ?? g.digest, signature: signature ?? g.signature)
        }
        #expect(throws: PhoneEvents.Failure.inconsistent("id")) { try validate(with(id: "01J9ZK4Q7M3R8T2V6X0B5N1C9E"), c) }
        #expect(throws: PhoneEvents.Failure.inconsistent("signingBytes")) { try validate(with(signingBytes: Data("x".utf8)), c) }
        #expect(throws: PhoneEvents.Failure.inconsistent("digest")) { try validate(with(digest: "sha256:" + String(repeating: "0", count: 64)), c) }
        #expect(throws: PhoneEvents.Failure.inconsistent("bytes")) { try validate(with(bytes: g.bytes + Data(" ".utf8)), c) }
        #expect(throws: PhoneEvents.Failure.inconsistent("signature")) { try validate(with(signature: Data(repeating: 1, count: 64)), c) }
        // the declared kind must be the one asked for
        #expect(throws: PhoneEvents.Failure.schema("kind")) {
            try PhoneEvents.validateSigned(with(kind: .questionAnswered), kind: .ticketCreated, actor: try actor(c["submitted"]), workspace: wsid, pub: phoneKey)
        }
    }

    @Test func autoResignDecidesOnUnsignedEvents() throws {
        // the whole point of the split: both sides of the comparison exist before any signature
        let c = accepted("creation"), s = c["submitted"], a = try actor(s)
        func unsigned(_ id: String, roster: Int64) throws -> PhoneEvents.UnsignedPhoneEvent {
            try PhoneEvents.unsignedCreate(ticketUID: c["log"].str, key: s["key"].str, ticketType: s["ticket_type"].str,
                                           title: PhoneEvents.prepareText(s["title"].str, oneLine: true), id: id, rosterV: roster, actor: a, workspace: wsid)
        }
        let prev = try unsigned(s["id"].str, roster: s["roster_v"].i64), next = try unsigned("01M4JM4RKG79RG3QTWCP60NNNH", roster: s["roster_v"].i64 + 1)
        let d = CreationDisplay(ticketType: s["ticket_type"].str, title: s["title"].str, owner: s["owner"].str)
        let input = AutoResignInput(lastClass: .cAuto, lastAnswerWasRefusedForExactIdem: true, earlierIdemUnresolved: false, reviewed: .creation(d),
                                    fresh: .creation(d), previous: prev.event, proposed: next.event, previousLog: prev.log, proposedLog: next.log,
                                    keyAssignedDisclosed: true, foregroundAndUnlockedSinceTap: true, autoResignsSoFar: 0)
        #expect(AutoResign.decide(input) == .allow)
    }
}
