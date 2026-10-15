import CryptoKit
import Foundation
import Testing
import OrchProtocol
@testable import OrchPush

@Suite struct AdversarialPush {
    let ws = ID16.random()
    let wsk = SoftwareSigner()
    let wk = SymmetricKey(size: .bits256)
    func make(_ p: JSONValue, epoch: UInt32 = 1, signer: (any Signer)? = nil, wsOverride: ID16? = nil, extraOuter: String = "") throws -> String {
        let s = signer ?? wsk
        let cj = try canonicalJSON(p)
        let signed = Data(Label.sigPush.utf8) + Data([2]) + ws.bytes + Bytes.u32(epoch) + cj
        let sig = try s.rawSignature(over: signed)
        let inner = try canonicalJSON(["p": p, "sig": .string(B64U.encode(sig))])
        let kp = KDF.kPush(wk: wk, workspace: ws, epoch: epoch)
        let aad = Data(Label.aadPush.utf8) + Data([2]) + ws.bytes + Bytes.u32(epoch)
        let c = try SaltedAEAD.seal(key: kp, msgLabel: Label.kdfPushMsg, aad: aad, plaintext: inner)
        return "{\"v\":2,\"ws\":\"\((wsOverride ?? ws).hex)\",\"epoch\":\(epoch),\"c\":\"\(B64U.encode(c))\"\(extraOuter)}"
    }
    var keys: PushProcessor.Keyring { [ws: .init(wsk: wsk.publicKey, workspace: ws, wk: [1: wk])] }
    let now: Int64 = 1_800_000_000_000
    func pay(_ id: String, _ ts: Int64, label: String = "hi", kind: String = "question") -> JSONValue {
        ["kind": .string(kind), "id": .string(id), "label": .string(label), "ts_ms": .int(ts)]
    }
    @Test func cases() throws {
        var r = PushProcessor.ReplayState()
        var out = PushProcessor.process(o: try make(pay("a", now)), keys: keys, replay: r, nowMs: now)
        #expect(out.result == .show(.init(workspace: ws, epoch: 1, kind: "question", id: "a", label: "hi", tsMs: now))); r = out.replay
        // forged by member (has K_push, not WSK)
        out = PushProcessor.process(o: try make(pay("b", now), signer: SoftwareSigner()), keys: keys, replay: r, nowMs: now)
        #expect(out.result == .drop(.signature))
        // NFC/NFD ids are distinct (code points)
        out = PushProcessor.process(o: try make(pay("\u{e9}", now)), keys: keys, replay: r, nowMs: now); r = out.replay
        out = PushProcessor.process(o: try make(pay("e\u{301}", now)), keys: keys, replay: r, nowMs: now)
        if case .show = out.result {} else { Issue.record("nfd distinct id dropped: \(out.result)") }
        // replay same ts
        out = PushProcessor.process(o: try make(pay("a", now)), keys: keys, replay: r, nowMs: now)
        #expect(out.result == .drop(.replay))
        // epoch out of range / negative / unknown
        #expect(PushProcessor.process(o: try make(pay("z", now), epoch: 2), keys: keys, replay: r, nowMs: now).result == .drop(.noKey))
        // unknown ws but valid crypto for another ws
        // extra outer key
        #expect(PushProcessor.process(o: try make(pay("z", now), extraOuter: ",\"x\":1"), keys: keys, replay: r, nowMs: now).result == .drop(.shape))
        // 81 code points label
        #expect(PushProcessor.process(o: try make(pay("z", now, label: String(repeating: "a", count: 81))), keys: keys, replay: r, nowMs: now).result == .drop(.payload))
        // 80 scalars but many graphemes ok
        if case .show = PushProcessor.process(o: try make(pay("z", now, label: String(repeating: "\u{1F600}", count: 80))), keys: keys, replay: r, nowMs: now).result {} else { Issue.record("80 emoji") }
        // kind Kelvin-sign spoof not applicable; unknown kind
        #expect(PushProcessor.process(o: try make(pay("z", now, kind: "Question")), keys: keys, replay: r, nowMs: now).result == .drop(.payload))
        // stale boundaries
        #expect(PushProcessor.process(o: try make(pay("s", now + 300_001)), keys: keys, replay: r, nowMs: now).result == .drop(.stale))
        if case .show = PushProcessor.process(o: try make(pay("s", now + 300_000)), keys: keys, replay: r, nowMs: now).result {} else { Issue.record("skew edge") }
        // size cap
        let big = try make(pay("z", now, label: String(repeating: "a", count: 80)))
        #expect(PushProcessor.process(o: big + String(repeating: " ", count: 3073 - big.utf8.count), keys: keys, replay: r, nowMs: now).result == .drop(.size))
        // epoch as 1.0 / "1" / true
        let good = try make(pay("q", now))
        #expect(PushProcessor.process(o: good.replacingOccurrences(of: "\"epoch\":1", with: "\"epoch\":\"1\""), keys: keys, replay: r, nowMs: now).result == .drop(.shape))
        #expect(PushProcessor.process(o: good.replacingOccurrences(of: "\"epoch\":1", with: "\"epoch\":1.0"), keys: keys, replay: r, nowMs: now).result == .drop(.shape))
        // uppercase ws hex
        #expect(PushProcessor.process(o: good.replacingOccurrences(of: ws.hex, with: ws.hex.uppercased()), keys: keys, replay: r, nowMs: now).result == .drop(.shape))
        // prune + clock rollback replay
        var r2 = PushProcessor.ReplayState()
        let old = now - 1000
        r2 = PushProcessor.process(o: try make(pay("x", old)), keys: keys, replay: r2, nowMs: now).replay
        r2 = PushProcessor.process(o: try make(pay("x", old)), keys: keys, replay: r2, nowMs: now + PushProcessor.maxAgeMs + 10_000).replay   // clock jumped ahead
        let back = PushProcessor.process(o: try make(pay("x", old)), keys: keys, replay: r2, nowMs: now)
        #expect(back.result == .drop(.replay), "rollback replay")
    }
}
