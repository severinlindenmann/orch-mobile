// Creates sealed push fixtures (`.apns` files for `xcrun simctl push`) from the TEST-ONLY keys in
// OrchKit/Tests/OrchPushFixtures/PushFixtures.swift. Build and run through scripts/make-push-fixture.sh:
//   scripts/make-push-fixture.sh [--out DIR] [--now-ms N]
// Writes: NN_<case>.apns (question, closure, replay, stale, unknown workspace, forged WSK, tampered, malicious outer
// fields), material.arg (the `--push-material` launch argument for the app's DEBUG push harness) and expectations.json
// (what the notification extension must record and show per case). Send them in file order: later cases depend on the
// replay state earlier ones leave. The keys are public and protect nothing.
import CryptoKit
import Foundation

@main
enum MakePushFixture {
    static func main() throws {
        var out = FileManager.default.currentDirectoryPath + "/push-fixtures"
        var now = Int64(Date().timeIntervalSince1970 * 1000)
        var hub = false
        var args = CommandLine.arguments.dropFirst()
        while let a = args.popFirst() {
            switch a {
            case "--out": out = args.popFirst() ?? out
            case "--hub": hub = true
            case "--now-ms": now = Int64(args.popFirst() ?? "") ?? now
            default: FileHandle.standardError.write(Data("unknown argument \(a)\n".utf8)); exit(2)
            }
        }
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if hub { try writeHub(to: dir, now: now); return }
        var expectations: [[String: Any]] = []
        for f in PushFixtures.sequence(nowMs: now) {
            try f.apns.write(to: dir.appendingPathComponent("\(f.name).apns"))
            expectations.append(["name": f.name, "outcome": f.expectedOutcome, "body": f.expectedBody ?? "generic", "maxTs": String(f.expectedMaxTs)])
        }
        let w = PushFixtures.workspaceA
        try Data("\(w.id.hex):\(B64U.encode(PushFixtures.materialJSON(w)))".utf8).write(to: dir.appendingPathComponent("material.arg"))
        try JSONSerialization.data(withJSONObject: expectations, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("expectations.json"))
        print("wrote \(expectations.count) fixtures to \(dir.path) (now_ms=\(now))")
    }

    /// `--hub`: hub pushes (design B4). A fresh push key, hub id and channel id; the material item (`hub-material.arg` = `hub:` + b64u of the
    /// item's JSON, for `--push-material`) and three pushes: a `prepare` hint, a `needs_you` hint, and the first one again (a replay).
    static func writeHub(to dir: URL, now: Int64) throws {
        let key = P256.KeyAgreement.PrivateKey()
        let pub = try AgreementPublicKey(x963: key.publicKey.x963Representation)
        let hubID = ID16(bytes: Data((0..<16).map { _ in UInt8.random(in: 0...255) }))!
        let channelID = ID16(bytes: Data((0..<16).map { _ in UInt8.random(in: 0...255) }))!
        let label = "Work hub"
        let material = try canonicalJSON(["v": 1, "hub_id": .string(hubID.hex), "channel_id": .string(channelID.hex), "label": .string(label),
                                          "push_key": .string(B64U.encode(key.rawRepresentation))])
        func outer(type: String, id: ID16, ts: Int64) throws -> String {
            let pt = try canonicalJSON(["v": 2, "hv": 0, "kind": "hub.push", "type": .string(type), "ts_ms": .int(ts), "ref": .null])
            let sealed = B64U.encode(try Sealing.sealHubPush(to: pub, channel: channelID, message: id, hub: hubID, plaintext: pt))
            return String(decoding: try canonicalJSON(["v": 2, "hub": .string(hubID.hex), "ch": .string(channelID.hex), "id": .string(id.hex), "c": .string(sealed)]), as: UTF8.self)
        }
        let id1 = ID16(bytes: Data((0..<16).map { _ in UInt8.random(in: 0...255) }))!, id2 = ID16(bytes: Data((0..<16).map { _ in UInt8.random(in: 0...255) }))!
        let o1 = try outer(type: "prepare", id: id1, ts: now), o2 = try outer(type: "needs_you", id: id2, ts: now + 1000)
        let cases: [(String, String, String, String, String?)] = [
            ("01_hub_prepare", o1, "shown", "A signature request is waiting", label),
            ("02_hub_needs_you", o2, "shown", "Something needs you", label),
            ("03_hub_replay", o1, "droppedReplay", "generic", nil),
        ]
        var expectations: [[String: Any]] = []
        for (name, o, outcome, body, title) in cases {
            try PushFixtures.apns(outer: o).write(to: dir.appendingPathComponent("\(name).apns"))
            expectations.append(["name": name, "outcome": outcome, "body": body, "title": title ?? "orch"])
        }
        try Data("hub:\(B64U.encode(material))".utf8).write(to: dir.appendingPathComponent("material.arg"))
        try JSONSerialization.data(withJSONObject: expectations, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("expectations.json"))
        print("wrote \(cases.count) hub fixtures to \(dir.path) (now_ms=\(now))")
    }
}
