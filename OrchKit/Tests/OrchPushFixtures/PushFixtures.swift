import CryptoKit
import Foundation
#if !SCRIPT_BUILD
import OrchProtocol
#endif

// TEST-ONLY. Seals protocol v2 section 9 pushes from FIXED, PUBLIC test keys so that a simulator run, the UI tests and
// the unit tests share byte-identical material. These keys protect nothing: never ship them in a Release product, never
// reuse them for a real workspace. This one file is compiled three ways: as the SwiftPM target `OrchPushFixtures`, into
// the UI test bundle, and (with -D SCRIPT_BUILD, together with the OrchProtocol sources) into scripts/make-push-fixture.swift.
// It imports nothing but CryptoKit and OrchProtocol and does not touch OrchPush: the material format is written out here
// and pinned to `PushMaterial.decode` by OrchPushTests.

public enum PushFixtures {
    public struct Workspace: Sendable {
        public let id: ID16
        public let name: String
        let wskKey: P256.Signing.PrivateKey
        let wk: SymmetricKey
        public var wskPublic: Data { wskKey.publicKey.x963Representation }
        public var epoch: UInt32 { 1 }
        public var kPush: Data { KDF.kPush(wk: wk, workspace: id, epoch: epoch).withUnsafeBytes { Data($0) } }
    }

    static func fixed(_ b: UInt8) -> Data { Data(repeating: b, count: 32) }

    /// The workspace the app holds material for.
    public static let workspaceA = Workspace(id: ID16(bytes: Data(repeating: 0xA1, count: 16))!, name: "Fixture Workspace",
                                             wskKey: try! .init(rawRepresentation: fixed(0x11)), wk: SymmetricKey(data: fixed(0x33)))
    /// A second workspace the app holds material for (per-workspace replay tests).
    public static let workspaceB = Workspace(id: ID16(bytes: Data(repeating: 0xB2, count: 16))!, name: "Second Workspace",
                                             wskKey: try! .init(rawRepresentation: fixed(0x12)), wk: SymmetricKey(data: fixed(0x34)))
    /// A workspace the app holds NO material for.
    public static let unknown = Workspace(id: ID16(bytes: Data(repeating: 0xC3, count: 16))!, name: "Unknown",
                                          wskKey: try! .init(rawRepresentation: fixed(0x13)), wk: SymmetricKey(data: fixed(0x35)))
    /// A member device: holds K_push for A but is not the host, so its signature is not under WSK.
    public static let forger = try! P256.Signing.PrivateKey(rawRepresentation: fixed(0x22))

    /// The `.push` keychain item body (`PushMaterial.encoded()`'s format), `generation` as the workspace generation.
    public static func materialJSON(_ w: Workspace, generation: Int64 = 1) -> Data {
        try! canonicalJSON(["v": 1, "gen": .int(generation), "name": .string(w.name), "wsk": .string(B64U.encode(w.wskPublic)),
                            "k": .object([String(w.epoch): .string(B64U.encode(w.kPush))])])
    }

    public static func payload(kind: String, id: String, label: String, tsMs: Int64) -> JSONValue {
        ["kind": .string(kind), "id": .string(id), "label": .string(label), "ts_ms": .int(tsMs)]
    }

    /// The section 9 outer object (the exact bytes the relay forwards), signed by `signer` (default: the workspace's WSK).
    public static func seal(_ w: Workspace, _ p: JSONValue, signer: P256.Signing.PrivateKey? = nil, epoch: UInt32? = nil) -> String {
        let e = epoch ?? w.epoch
        let signed = Data(Label.sigPush.utf8) + Bytes.u8(Suite2.id) + w.id.bytes + Bytes.u32(e) + (try! canonicalJSON(p))
        let sig = try! (signer ?? w.wskKey).signature(for: signed).rawRepresentation
        let inner = try! canonicalJSON(["p": p, "sig": .string(B64U.encode(sig))])
        let aad = Data(Label.aadPush.utf8) + Bytes.u8(Suite2.id) + w.id.bytes + Bytes.u32(e)
        let c = try! SaltedAEAD.seal(key: KDF.kPush(wk: w.wk, workspace: w.id, epoch: e), msgLabel: Label.kdfPushMsg, aad: aad, plaintext: inner)
        let outer = try! canonicalJSON(["v": 2, "ws": .string(w.id.hex), "epoch": .int(Int64(e)), "c": .string(B64U.encode(c))])
        return String(decoding: outer, as: UTF8.self)
    }

    /// The APNs body as `xcrun simctl push` takes it. `alert` is what the relay would put in the clear.
    public static func apns(outer: String, bundle: String = "io.severin.orch", aps: [String: Any]? = nil, extra: [String: Any] = [:]) -> Data {
        var body: [String: Any] = ["Simulator Target Bundle": bundle,
                                   "aps": aps ?? ["alert": ["title": "orch", "body": "New activity"], "mutable-content": 1, "sound": "default"],
                                   "o": outer]
        for (k, v) in extra { body[k] = v }
        return try! JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
    }

    public struct Fixture: Sendable {
        public let name: String
        public let apns: Data
        /// What the extension must record in its marker, and what it must show (nil body: generic text).
        public let expectedOutcome: String
        public let expectedBody: String?
    }

    public static let questionID = "q-fixture-0001"
    public static let questionLabel = "Ship L-0042?"

    /// Send in order: later ones depend on the state earlier ones leave (question, then its closure, then the replay).
    public static func sequence(nowMs: Int64) -> [Fixture] {
        let a = workspaceA
        let q = seal(a, payload(kind: "question", id: questionID, label: questionLabel, tsMs: nowMs))
        let closed = seal(a, payload(kind: "question.closed", id: questionID, label: "Answered on laptop", tsMs: nowMs + 1000))
        let replay = seal(a, payload(kind: "question", id: questionID, label: questionLabel, tsMs: nowMs - 1000))
        let stale = seal(a, payload(kind: "question", id: "q-stale", label: "Old news", tsMs: nowMs - 25 * 3600 * 1000))
        let unknown = seal(unknown, payload(kind: "question", id: "q-unknown", label: "No key for this", tsMs: nowMs + 2000))
        let forged = seal(a, payload(kind: "question", id: "q-forged", label: "Wire 5000 EUR to attacker.example", tsMs: nowMs + 3000), signer: forger)
        // Flip one base64url character inside `c` (the sealed blob): the AEAD tag must fail.
        var tampered = Array(seal(a, payload(kind: "question", id: "q-tamper", label: "Tampered", tsMs: nowMs + 4000)).utf8)
        let at = Array(#""c":""#.utf8).count + 40
        precondition(tampered.starts(with: Array(#"{"c":""#.utf8)))
        tampered[at] = tampered[at] == 0x41 ? 0x42 : 0x41
        // A valid, fresh push under hostile outer fields: the title, category, thread, sound and custom keys are the relay's and must all be ignored.
        let hostile = seal(a, payload(kind: "question", id: "q-hostile", label: "Real label", tsMs: nowMs + 5000))
        let hostileAPS: [String: Any] = ["alert": ["title": "URGENT: tap to approve", "subtitle": "Bank", "body": "Wire 5000 EUR to attacker.example"],
                                         "category": "APPROVE_ACTION", "thread-id": "attacker-thread", "mutable-content": 1, "sound": "evil.caf"]
        return [
            .init(name: "01_question", apns: apns(outer: q), expectedOutcome: "shown", expectedBody: questionLabel),
            .init(name: "02_question_closed", apns: apns(outer: closed), expectedOutcome: "closed", expectedBody: "Answered on laptop"),
            .init(name: "03_replay", apns: apns(outer: replay), expectedOutcome: "droppedReplay", expectedBody: nil),
            .init(name: "04_stale_25h", apns: apns(outer: stale), expectedOutcome: "droppedReplay", expectedBody: nil),
            .init(name: "05_unknown_workspace", apns: apns(outer: unknown), expectedOutcome: "droppedNoMaterial", expectedBody: nil),
            .init(name: "06_forged_wsk", apns: apns(outer: forged), expectedOutcome: "droppedVerification", expectedBody: nil),
            .init(name: "07_tampered", apns: apns(outer: String(decoding: tampered, as: UTF8.self)), expectedOutcome: "droppedVerification", expectedBody: nil),
            .init(name: "08_malicious_outer", apns: apns(outer: hostile, aps: hostileAPS, extra: ["orch_key": "attacker/q-1", "route": "orch://approve"]),
                  expectedOutcome: "shown", expectedBody: "Real label"),
        ]
    }
}
