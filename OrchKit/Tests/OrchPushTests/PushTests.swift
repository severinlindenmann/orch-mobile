import CryptoKit
import Foundation
import OrchProtocol
import Testing
@testable import OrchPush

// TODO(M3+): the push vectors are the whole of `suites."2".push`; nothing from it is deferred. Other vector groups live in
// OrchProtocolTests (see the TODO(M3+) list there).

enum PushVectors {
    static let root: JSONValue = {
        let url = Bundle.module.url(forResource: "vectors_v2", withExtension: "json")!
        return try! StrictJSON.parse(try! Data(contentsOf: url))
    }()
    static var push: JSONValue { root["suites"]["2"]["push"] }
}

extension JSONValue {
    subscript(_ k: String) -> JSONValue { object?[k] ?? .null }
    subscript(_ i: Int) -> JSONValue { array.flatMap { i < $0.count ? $0[i] : nil } ?? .null }
    var items: [JSONValue] { array ?? [] }
    var str: String { string ?? "" }
}

func keyring(_ j: JSONValue) -> PushProcessor.Keyring {
    var out: PushProcessor.Keyring = [:]
    for (wsHex, entry) in j.object ?? [:] {
        let ws = ID16(hex: wsHex)!
        var wk: [UInt32: SymmetricKey] = [:]
        for (ep, h) in entry["wk"].object! { wk[UInt32(ep)!] = SymmetricKey(data: Hex.decode(h.str, length: 32)!) }
        out[ws] = .init(wsk: try! SigningPublicKey(x963: B64U.decode(entry["wsk_pub"].str)!), workspace: ws, wk: wk)
    }
    return out
}

@Suite struct PushVectorTests {
    @Test func allSuite2PushCases() throws {
        let cases = PushVectors.push["cases"].items
        #expect(cases.count == 11)
        var steps = 0
        for c in cases {
            let name = c["name"].str
            let keys = keyring(c["keys"])
            var replay = PushProcessor.ReplayState()
            for st in c["steps"].items {
                steps += 1
                let exp = st["expect"]
                let out = PushProcessor.process(o: st["raw"].str, keys: keys, replay: replay, nowMs: st["now_ms"].int!)
                replay = out.replay
                switch out.result {
                case .drop(let why):
                    #expect(exp["result"].str == "drop", "\(name)")
                    #expect(exp["why"].str == why.rawValue, "\(name)")
                case .show(let p):
                    #expect(exp["result"].str == "show", "\(name)")
                    #expect(exp["id"].str == p.id && exp["tag"].str == p.id, "\(name)")
                    #expect(exp["kind"].str == p.kind, "\(name)")
                    #expect(exp["label"].str == p.label, "\(name)")
                    #expect(exp["ts_ms"].int == p.tsMs, "\(name)")
                }
            }
        }
        #expect(steps == 13)
    }

    @Test func vectorConstantsMatch() {
        let c = PushVectors.root["constants"]["push"]
        #expect(c["max_bytes"].int == Int64(PushProcessor.maxOuterBytes))
        #expect(c["max_age_ms"].int == PushProcessor.maxAgeMs)
        #expect(Set(c["kinds"].items.map(\.str)) == PushProcessor.kinds)
        #expect(PushVectors.root["constants"]["skew_ms"].int == PushProcessor.skewMs)
    }

    @Test func rawAndStringEntryPointsAgree() {
        let c = PushVectors.push["cases"][0]
        let keys = keyring(c["keys"]), raw = c["steps"][0]["raw"].str, now = c["steps"][0]["now_ms"].int!
        let a = PushProcessor.process(o: raw, keys: keys, replay: .init(), nowMs: now)
        let b = PushProcessor.process(outer: Data(raw.utf8), keys: keys, replay: .init(), nowMs: now)
        #expect(a.result == b.result)
        #expect(a.replay == b.replay)
    }
}

/// Seals real pushes with software keys, the way a host would, to test what the vectors do not cover.
struct Host {
    let ws = ID16.random()
    let wsk = SoftwareSigner()
    let wk = SymmetricKey(size: .bits256)
    var keys: PushProcessor.Keyring { [ws: .init(wsk: wsk.publicKey, workspace: ws, wk: [1: wk])] }

    func outer(epoch: UInt32 = 1, signer: (any Signer)? = nil, payload: JSONValue? = nil, wkOverride: SymmetricKey? = nil,
               extraInner: Bool = false, ws wsOverride: ID16? = nil) throws -> Data {
        let p = payload ?? ["kind": "question", "id": "q-1", "label": "Ship?", "ts_ms": 1_000_000]
        let signed = Data(Label.sigPush.utf8) + Data([2]) + ws.bytes + Bytes.u32(epoch) + (try canonicalJSON(p))
        let sig = try (signer ?? wsk).rawSignature(over: signed)
        var inner: [String: JSONValue] = ["p": p, "sig": .string(B64U.encode(sig))]
        if extraInner { inner["x"] = 1 }
        let aad = Data(Label.aadPush.utf8) + Data([2]) + ws.bytes + Bytes.u32(epoch)
        let k = KDF.kPush(wk: wkOverride ?? wk, workspace: ws, epoch: epoch)
        let c = try SaltedAEAD.seal(key: k, msgLabel: Label.kdfPushMsg, aad: aad, plaintext: try canonicalJSON(.object(inner)))
        return try canonicalJSON(["v": 2, "ws": .string((wsOverride ?? ws).hex), "epoch": .int(Int64(epoch)), "c": .string(B64U.encode(c))])
    }
}

@Suite struct PushProcessorTests {
    let now: Int64 = 1_000_000

    @Test func showsAValidPush() throws {
        let h = Host()
        let out = PushProcessor.process(outer: try h.outer(), keys: h.keys, replay: .init(), nowMs: now)
        #expect(out.result == .show(.init(workspace: h.ws, epoch: 1, kind: "question", id: "q-1", label: "Ship?", tsMs: 1_000_000)))
        #expect(out.replay.last(workspace: h.ws, id: "q-1") == 1_000_000)
    }

    @Test func replayStateChangesOnShowOnly() throws {
        let h = Host(), raw = try h.outer()
        var r = PushProcessor.ReplayState()
        let first = PushProcessor.process(outer: raw, keys: h.keys, replay: r, nowMs: now)
        r = first.replay
        let again = PushProcessor.process(outer: raw, keys: h.keys, replay: r, nowMs: now)
        #expect(again.result == .drop(.replay) && again.replay == r)
        let dropped = PushProcessor.process(outer: Data("{}".utf8), keys: h.keys, replay: r, nowMs: now)
        #expect(dropped.result == .drop(.shape) && dropped.replay == r)
        // the input state is a value: the first call did not mutate it
        #expect(PushProcessor.process(outer: raw, keys: h.keys, replay: .init(), nowMs: now).result != .drop(.replay))
    }

    @Test func replayIsPerWorkspaceAndId() throws {
        let h = Host()
        let a = PushProcessor.process(outer: try h.outer(), keys: h.keys, replay: .init(), nowMs: now)
        let other = try h.outer(payload: ["kind": "question", "id": "q-2", "label": "x", "ts_ms": 1_000_000])
        #expect(PushProcessor.process(outer: other, keys: h.keys, replay: a.replay, nowMs: now).result != .drop(.replay))
        let newer = try h.outer(payload: ["kind": "question", "id": "q-1", "label": "x", "ts_ms": 1_000_001])
        #expect(PushProcessor.process(outer: newer, keys: h.keys, replay: a.replay, nowMs: now).result != .drop(.replay))
    }

    @Test func idsAreComparedByCodePoints() throws {
        let h = Host()
        let composed = "\u{e9}", decomposed = "e\u{301}"
        #expect(composed == decomposed)                                   // Swift String equality: canonical equivalence
        let first = PushProcessor.process(outer: try h.outer(payload: ["kind": "join", "id": .string(composed), "label": "x", "ts_ms": 1_000_000]),
                                          keys: h.keys, replay: .init(), nowMs: now)
        let second = PushProcessor.process(outer: try h.outer(payload: ["kind": "join", "id": .string(decomposed), "label": "x", "ts_ms": 1_000_000]),
                                           keys: h.keys, replay: first.replay, nowMs: now)
        guard case .show = second.result else { Issue.record("distinct code points must be distinct ids"); return }
    }

    @Test func timestampRule() {
        let n: Int64 = 10_000_000_000
        #expect(PushProcessor.checkTimestamp(tsMs: n - PushProcessor.maxAgeMs, nowMs: n, lastShown: nil) == nil)
        #expect(PushProcessor.checkTimestamp(tsMs: n - PushProcessor.maxAgeMs - 1, nowMs: n, lastShown: nil) == .stale)
        #expect(PushProcessor.checkTimestamp(tsMs: n + 300_000, nowMs: n, lastShown: nil) == nil)
        #expect(PushProcessor.checkTimestamp(tsMs: n + 300_001, nowMs: n, lastShown: nil) == .stale)
        #expect(PushProcessor.checkTimestamp(tsMs: n, nowMs: n, lastShown: n) == .replay)
        #expect(PushProcessor.checkTimestamp(tsMs: n, nowMs: n, lastShown: n + 1) == .replay)
        #expect(PushProcessor.checkTimestamp(tsMs: n, nowMs: n, lastShown: n - 1) == nil)
        #expect(PushProcessor.checkTimestamp(tsMs: n - 1, nowMs: n, lastShown: n) == .replay)
    }

    @Test func staleBeatsReplay() throws {
        let h = Host()
        let first = PushProcessor.process(outer: try h.outer(), keys: h.keys, replay: .init(), nowMs: now)
        let late = PushProcessor.process(outer: try h.outer(), keys: h.keys, replay: first.replay, nowMs: now + PushProcessor.maxAgeMs + 1)
        #expect(late.result == .drop(.stale))
    }

    @Test func prunedStateKeepsWhatStillMatters() throws {
        let h = Host()
        let r = PushProcessor.process(outer: try h.outer(), keys: h.keys, replay: .init(), nowMs: now).replay
        #expect(r.pruned(nowMs: now + 1000).last(workspace: h.ws, id: "q-1") == 1_000_000)
        #expect(r.pruned(nowMs: now + PushProcessor.maxAgeMs + 1).last(workspace: h.ws, id: "q-1") == nil)
    }

    @Test func forgedByAMemberWithKPush() throws {
        let h = Host()
        // a member holds WK, hence K_push, but not WSK
        let raw = try h.outer(signer: SoftwareSigner())
        #expect(PushProcessor.process(outer: raw, keys: h.keys, replay: .init(), nowMs: now).result == .drop(.signature))
    }

    @Test func wrongKeyOrEpochOrWorkspace() throws {
        let h = Host()
        #expect(PushProcessor.process(outer: try h.outer(wkOverride: SymmetricKey(size: .bits256)), keys: h.keys, replay: .init(), nowMs: now).result == .drop(.tag))
        #expect(PushProcessor.process(outer: try h.outer(epoch: 2), keys: h.keys, replay: .init(), nowMs: now).result == .drop(.noKey))
        #expect(PushProcessor.process(outer: try h.outer(), keys: [:], replay: .init(), nowMs: now).result == .drop(.noKey))
        // ws field swapped to another held workspace: AAD binds ws
        var two = h.keys
        let other = ID16.random()
        two[other] = h.keys[h.ws]
        #expect(PushProcessor.process(outer: try h.outer(ws: other), keys: two, replay: .init(), nowMs: now).result == .drop(.tag))
    }

    @Test func shapeAndPayloadRules() throws {
        let h = Host()
        func run(_ raw: Data) -> PushProcessor.Result { PushProcessor.process(outer: raw, keys: h.keys, replay: .init(), nowMs: now).result }
        #expect(run(Data(repeating: 0x20, count: PushProcessor.maxOuterBytes + 1)) == .drop(.size))
        for bad in ["", "[]", "{}", "{\"v\":2,\"ws\":\"00\",\"epoch\":1,\"c\":\"AA\"}", "{\"v\":3,\"ws\":\"\(h.ws.hex)\",\"epoch\":1,\"c\":\"AA\"}",
                    "{\"v\":2,\"ws\":\"\(h.ws.hex.uppercased())\",\"epoch\":1,\"c\":\"AA\"}",
                    "{\"v\":2,\"ws\":\"\(h.ws.hex)\",\"epoch\":1,\"c\":\"AA==\"}",
                    "{\"v\":2,\"ws\":\"\(h.ws.hex)\",\"epoch\":1,\"c\":\"AA\",\"x\":1}",
                    "{\"v\":2,\"ws\":\"\(h.ws.hex)\",\"epoch\":1,\"epoch\":1,\"c\":\"AA\"}"] {
            #expect(run(Data(bad.utf8)) == .drop(.shape), "\(bad)")
        }
        #expect(run(Data("{\"v\":2,\"ws\":\"\(h.ws.hex)\",\"epoch\":1.0,\"c\":\"AA\"}".utf8)) == .drop(.shape))
        #expect(run(Data("{\"v\":2,\"ws\":\"\(h.ws.hex)\",\"epoch\":\"1\",\"c\":\"AA\"}".utf8)) == .drop(.noKey))
        #expect(run(Data("{\"v\":2,\"ws\":\"\(h.ws.hex)\",\"epoch\":-1,\"c\":\"AA\"}".utf8)) == .drop(.noKey))
        #expect(run(Data("{\"v\":2,\"ws\":\"\(h.ws.hex)\",\"epoch\":4294967297,\"c\":\"AA\"}".utf8)) == .drop(.noKey))
        #expect(run(Data("{\"v\":2,\"ws\":\"\(h.ws.hex)\",\"epoch\":1,\"c\":\"AA\"}".utf8)) == .drop(.tag))

        #expect(run(try h.outer(extraInner: true)) == .drop(.payload))
        #expect(run(try h.outer(payload: ["kind": "nope", "id": "i", "label": "x", "ts_ms": 1_000_000])) == .drop(.payload))
        #expect(run(try h.outer(payload: ["kind": "join", "id": "i", "label": "x", "ts_ms": 1_000_000, "extra": 1])) == .drop(.payload))
        #expect(run(try h.outer(payload: ["kind": "join", "id": "i", "label": "x"])) == .drop(.payload))
        #expect(run(try h.outer(payload: ["kind": "join", "id": 5, "label": "x", "ts_ms": 1_000_000])) == .drop(.payload))
        #expect(run(try h.outer(payload: ["kind": "join", "id": "i", "label": "x", "ts_ms": "1"])) == .drop(.payload))
        #expect(run(try h.outer(payload: "not an object")) == .drop(.payload))
        let label80 = String(repeating: "\u{1F600}", count: 80)
        guard case .show = run(try h.outer(payload: ["kind": "join", "id": "i", "label": .string(label80), "ts_ms": 1_000_000])) else {
            Issue.record("80 code points are allowed"); return
        }
        #expect(run(try h.outer(payload: ["kind": "join", "id": "i", "label": .string(label80 + "x"), "ts_ms": 1_000_000])) == .drop(.payload))
    }

    @Test func everyKindIsAccepted() throws {
        let h = Host()
        for kind in PushProcessor.kinds {
            let out = PushProcessor.process(outer: try h.outer(payload: ["kind": .string(kind), "id": "i", "label": "x", "ts_ms": 1_000_000]),
                                            keys: h.keys, replay: .init(), nowMs: now)
            guard case .show(let p) = out.result else { Issue.record("\(kind)"); continue }
            #expect(p.kind == kind)
        }
    }

    @Test func tamperedBytesNeverShow() throws {
        let h = Host(), raw = try h.outer()
        var shown = 0
        for i in stride(from: 0, to: raw.count, by: 7) {
            var t = raw; t[i] ^= 0x01
            if case .show = PushProcessor.process(outer: t, keys: h.keys, replay: .init(), nowMs: now).result { shown += 1 }
        }
        #expect(shown == 0)
    }
}
