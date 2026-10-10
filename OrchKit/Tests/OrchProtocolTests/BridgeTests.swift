import CryptoKit
import Foundation
import Testing
@testable import OrchProtocol

@Suite struct BridgeVectorTests {
    var s2: JSONValue { Vectors.suite2 }

    @Test func sealVector() throws {
        let cases = s2["bridge"]["seal"].items
        #expect(cases.count == 1)
        for c in cases {
            let f = c["header_fields"]
            let h = Bridge.Header(direction: .toHost, flags: [], workspace: f["workspace"].id, device: f["device"].id, rid: f["rid"].id,
                                  stream: f["stream"].id, seq: UInt64(f["seq"].i64), tsMs: UInt64(f["ts_ms"].i64),
                                  epoch: f["epoch"].u32, salt: f["salt"].hexData)
            #expect(h.encode() == c["header"].hexData)
            #expect(try Bridge.Header.decode(c["header"].hexData) == h)
            let wk = s2["hkdf"].items.first { $0["name"].str == "k_bridge_epoch_2" }!["ikm"].key
            let kChan = Bridge.channelKey(header: h, wk: wk)!
            #expect(kChan.rawBytes == c["k_bridge"].hexData)
            #expect(Bridge.messageKey(channelKey: kChan, salt: h.salt).rawBytes == c["message_key"].hexData)
            // framing
            let (meta, data) = try Bridge.unframe(c["plaintext"].hexData)
            #expect(data.isEmpty && meta["method"].str == "GET")
            #expect(try Bridge.frame(meta: meta) == c["plaintext"].hexData)
            // seal: header and body are deterministic; the ECDSA signature is randomised, so verify it
            let phone = try testSigner("phone.sig")
            let env = try Bridge.seal(header: h, channelKey: kChan, signer: phone, plaintext: c["plaintext"].hexData)
            let parts = try Bridge.Parts(envelope: env)
            let want = try Bridge.Parts(envelope: c["envelope"].hexData)
            #expect(parts.headerBytes == want.headerBytes && parts.headerBytes == c["header"].hexData)
            #expect(parts.body == want.body && parts.body == c["sealed"].hexData)
            #expect(env.count == Bridge.overhead + c["plaintext"].hexData.count)
            #expect(Bridge.verifySignature(parts, key: phone.publicKey))
            #expect(Bridge.verifySignature(want, key: phone.publicKey))          // the vector's own signature
            #expect(try Bridge.openBody(want, channelKey: kChan) == c["plaintext"].hexData)
            #expect(parts.digest == want.digest)
        }
    }

    func context(_ c: JSONValue) -> (Bridge.DeviceContext, [ID16: Bridge.PendingRequest]) {
        var wk: [UInt32: SymmetricKey] = [:]
        for (k, v) in c["wk"].object! { wk[UInt32(k)!] = v.key }
        var pending: [ID16: Bridge.PendingRequest] = [:]
        for (k, p) in c["pending"].object! {
            pending[ID16(hex: k)!] = .init(next: UInt64(p["next"].i64), stream: p["stream"].bool!, epoch: p["epoch"].u32)
        }
        return (.init(workspace: c["workspace"].id, device: c["device"].id, wsk: c["wsk_pub"].sigPub, wk: wk, offsetMs: c["offset_ms"].i64), pending)
    }

    @Test func deviceCases() throws {
        let cases = s2["bridge"]["device_cases"].items
        #expect(cases.count == 11)
        var accepted = 0
        for c in cases {
            let name = c["name"].str, e = c["expect"]
            let (ctx, pending) = context(c["ctx"])
            let mb = c["mailbox"]
            let (out, table) = Bridge.checkResponse(c["envelope"].hexData, context: ctx, pending: pending,
                                                    mailbox: .init(id: mb["id"].id, index: UInt64(mb["idx"].i64), last: mb["last"].bool!, stream: mb["stream"].bool!),
                                                    nowMs: c["now_ms"].i64)
            switch out {
            case .accept(let a):
                accepted += 1
                #expect(e["result"].str == "accept", "\(name)")
                #expect(a.last == e["last"].bool && a.refusal == e["refusal"].bool, "\(name)")
                #expect(a.meta == e["meta"] && a.data == e["data"].hexData, "\(name)")
                #expect(a.offsetMs == e["offset_ms"].int, "\(name)")
                #expect(a.fetchGrants == (e["fetch_grants"].bool ?? false), "\(name)")
                #expect(!a.clockWrong, "\(name)")
                let rid = ID16(hex: c["mailbox"]["id"].str)!
                #expect(table[rid] == (a.last ? nil : Bridge.PendingRequest(next: pending[rid]!.next + 1, stream: pending[rid]!.stream, epoch: pending[rid]!.epoch)), "\(name)")
            case .drop(let why):
                #expect(e["result"].str == "drop" && e["why"].str == why.code, "\(name)")
                if case .hostSignature(let pin) = why { #expect(pin == e["pin_failure"].bool, "\(name)") }
                #expect(table == pending, "\(name)")
            }
        }
        #expect(accepted == 3)
    }

    // MARK: synthetic cases beyond the vectors

    struct Rig {
        let ws = ID16.random(), dev = ID16.random(), rid = ID16.random()
        let wsk = SoftwareSigner(), wk = SymmetricKey(size: .bits256)
        var ctx: Bridge.DeviceContext { .init(workspace: ws, device: dev, wsk: wsk.publicKey, wk: [3: wk]) }
        var pending: [ID16: Bridge.PendingRequest] { [rid: .init(epoch: 3)] }
        let now: Int64 = 1_790_000_000_000
        func chunk(flags: Bridge.Flags = .last, direction: Bridge.Direction = .toDevice, seq: UInt64 = 0, ts: Int64? = nil,
                   epoch: UInt32 = 3, meta: JSONValue = ["status": 200], data: Data = Data("ok".utf8), signer: SoftwareSigner? = nil,
                   key: SymmetricKey? = nil) throws -> Data {
            let h = Bridge.Header(direction: direction, flags: flags, workspace: ws, device: dev, rid: rid, seq: seq,
                                  tsMs: UInt64(ts ?? now), epoch: epoch)
            return try Bridge.seal(header: h, channelKey: key ?? KDF.kBridge(wk: wk, workspace: ws, epoch: epoch), signer: signer ?? wsk,
                                   plaintext: Bridge.frame(meta: meta, data: data))
        }
        func check(_ env: Data, mailbox: Bridge.MailboxPosition? = nil, pending p: [ID16: Bridge.PendingRequest]? = nil, now n: Int64? = nil) -> Bridge.ResponseOutcome {
            Bridge.checkResponse(env, context: ctx, pending: p ?? pending, mailbox: mailbox ?? .init(id: rid, index: 0, last: true, stream: false), nowMs: n ?? now).outcome
        }
    }

    @Test func syntheticAcceptAndDrops() throws {
        let r = Rig()
        guard case .accept(let a) = r.check(try r.chunk()) else { Issue.record("must accept"); return }
        #expect(a.data == Data("ok".utf8) && a.last && !a.refusal)
        #expect(r.check(try r.chunk(direction: .toHost)) == .drop(.versionDirectionOrFlags))
        #expect(r.check(try r.chunk(flags: [.refusal])) == .drop(.flags))                     // REFUSAL requires LAST
        #expect(r.check(try r.chunk(flags: Bridge.Flags(rawValue: 0x08))) == .drop(.versionDirectionOrFlags))
        #expect(r.check(try r.chunk(), mailbox: .init(id: r.rid, index: 1, last: true, stream: false)) == .drop(.mailboxMismatch))
        #expect(r.check(try r.chunk(), mailbox: .init(id: r.rid, index: 0, last: false, stream: false)) == .drop(.mailboxMismatch))
        #expect(r.check(try r.chunk(), mailbox: .init(id: r.rid, index: 0, last: true, stream: true)) == .drop(.mailboxMismatch))
        #expect(r.check(try r.chunk(seq: 1), mailbox: .init(id: r.rid, index: 1, last: true, stream: false)) == .drop(.outOfOrder))
        #expect(r.check(try r.chunk(ts: r.now + 300_001)) == .drop(.staleTimestamp))
        guard case .accept = r.check(try r.chunk(ts: r.now + 300_000)) else { Issue.record("skew edge"); return }
        #expect(r.check(try r.chunk(), now: Int64.max) == .drop(.staleTimestamp))            // no overflow trap
        #expect(r.check(try r.chunk(), now: Int64.min) == .drop(.staleTimestamp))
        // signed by a member device: the tag opens, the signature is not the host's -> pin failure
        #expect(r.check(try r.chunk(signer: SoftwareSigner())) == .drop(.hostSignature(pinFailure: true)))
        // host-signed but sealed under the wrong key: tag
        #expect(r.check(try r.chunk(key: SymmetricKey(size: .bits256))) == .drop(.tag))
        #expect(r.check(Data(count: 100)) == .drop(.size))
        #expect(r.check(Data(count: Bridge.maxChunk + 1)) == .drop(.size))
        #expect(r.check(try r.chunk(), pending: [:]) == .drop(.unknownRequest))
        #expect(r.check(try r.chunk(), pending: [r.rid: .init(epoch: 4)]) == .drop(.epochMismatch))
        var noKey = r.ctx; noKey.wk = [:]
        #expect(Bridge.checkResponse(try r.chunk(), context: noKey, pending: r.pending, mailbox: .init(id: r.rid, index: 0, last: true, stream: false), nowMs: r.now).outcome == .drop(.noKey))
        // a corrupted body
        var bad = try r.chunk(); bad[Bridge.headerLength + 1] ^= 1
        #expect(r.check(bad) == .drop(.hostSignature(pinFailure: false)))
    }

    @Test func staleTimestampOffsetAdoptedOnce() throws {
        let r = Rig()
        let env = try r.chunk(flags: [.last, .refusal], ts: r.now + 3_600_000, meta: ["refusal": "stale_timestamp", "host_ms": .int(r.now + 3_600_000)], data: Data())
        let first = Bridge.checkResponse(env, context: r.ctx, pending: r.pending, mailbox: .init(id: r.rid, index: 0, last: true, stream: false), nowMs: r.now)
        guard case .accept(let a) = first.outcome else { Issue.record("accept"); return }
        #expect(a.offsetMs == 3_600_000 && a.refusal)
        #expect(first.pending[r.rid] == nil)                                                    // `last` retires the rid
        // a repeat of the chunk after `last` is dropped, signed or not
        #expect(Bridge.checkResponse(env, context: r.ctx, pending: first.pending, mailbox: .init(id: r.rid, index: 0, last: true, stream: false), nowMs: r.now).outcome == .drop(.unknownRequest))
        // a second stale_timestamp refusal for a rid that already adopted an offset gets the normal window check, not a pass
        let adopted: [ID16: Bridge.PendingRequest] = [r.rid: .init(epoch: 3, offsetAdopted: true)]
        let skewed = try r.chunk(flags: [.last, .refusal], ts: 1, meta: ["refusal": "stale_timestamp", "host_ms": .int(r.now)], data: Data())
        #expect(r.check(skewed, pending: adopted) == .drop(.staleTimestamp))
        guard case .accept(let b) = r.check(env, pending: adopted, now: r.now + 3_600_000) else { Issue.record("accept 2"); return }
        #expect(b.offsetMs == nil && !b.clockWrong)
        // more than 24 h away: the device clock is wrong, no offset
        let far = try r.chunk(flags: [.last, .refusal], meta: ["refusal": "stale_timestamp", "host_ms": .int(r.now + 90_000_000)], data: Data())
        guard case .accept(let c) = r.check(far) else { Issue.record("accept 3"); return }
        #expect(c.offsetMs == nil && c.clockWrong)
    }

    @Test func extremeClockDifferencesNeverTrap() throws {
        let r = Rig()
        let mb = Bridge.MailboxPosition(id: r.rid, index: 0, last: true, stream: false)
        // nowMs - ts == Int64.min exactly (no overflow, but abs would trap)
        let env = try r.chunk(ts: Int64.max)
        #expect(Bridge.checkResponse(env, context: r.ctx, pending: r.pending, mailbox: mb, nowMs: -1).outcome == .drop(.staleTimestamp))
        // host_ms - nowMs == Int64.min exactly: clock wrong, no offset, no trap
        let refusal = try r.chunk(flags: [.last, .refusal], meta: ["refusal": "stale_timestamp", "host_ms": -1], data: Data())
        guard case .accept(let a) = Bridge.checkResponse(refusal, context: r.ctx, pending: r.pending, mailbox: mb, nowMs: Int64.max).outcome else { Issue.record("accept"); return }
        #expect(a.clockWrong && a.offsetMs == nil)
        // the limits are inclusive
        guard case .accept(let edge) = Bridge.checkResponse(try r.chunk(flags: [.last, .refusal], meta: ["refusal": "stale_timestamp", "host_ms": .int(r.now + Bridge.maxOffsetMs)], data: Data()),
                                                            context: r.ctx, pending: r.pending, mailbox: mb, nowMs: r.now).outcome else { Issue.record("edge"); return }
        #expect(edge.offsetMs == Bridge.maxOffsetMs)
    }

    @Test func staleEpochRefusalRules() throws {
        let r = Rig()
        let up = try r.chunk(flags: [.last, .refusal], meta: ["refusal": "stale_epoch", "epoch": 4], data: Data())
        guard case .accept(let a) = r.check(up) else { Issue.record("accept"); return }
        #expect(a.fetchGrants)
        for e in [3, 2, -1] as [Int64] {
            #expect(r.check(try r.chunk(flags: [.last, .refusal], meta: ["refusal": "stale_epoch", "epoch": .int(e)], data: Data())) == .drop(.staleEpochNotHigher))
        }
        #expect(r.check(try r.chunk(flags: [.last, .refusal], meta: ["refusal": "stale_epoch", "epoch": "9"], data: Data())) == .drop(.staleEpochNotHigher))
    }

    @Test func headerCodecAndFraming() throws {
        let h = Bridge.Header(direction: .toDevice, flags: [.last, .stream], workspace: .random(), device: .random(), rid: .random(),
                              stream: .random(), seq: UInt64.max, tsMs: UInt64.max, epoch: UInt32.max)
        #expect(try Bridge.Header.decode(h.encode()) == h)
        #expect(h.encode().count == 108)
        #expect(throws: Refusal.malformed) { try Bridge.Header.decode(Data(count: 107)) }
        #expect(throws: Refusal.malformed) { try Bridge.Parts(envelope: Data(count: 187)) }
        // epoch 0: K_pair keyed by the offer id carried in `stream`
        let secret = SymmetricKey(size: .bits256)
        let h0 = Bridge.Header(direction: .toHost, workspace: h.workspace, device: h.device, rid: h.rid, stream: h.stream, seq: 1, tsMs: 1, epoch: 0)
        #expect(Bridge.channelKey(header: h0, pairSecret: secret)!.rawBytes == KDF.kPair(secret: secret, workspace: h.workspace, offer: h.stream).rawBytes)
        #expect(Bridge.channelKey(header: h0, wk: secret) == nil)
        // framing limits
        #expect(throws: Refusal.malformed) { try Bridge.unframe(Data([0, 0, 0])) }
        #expect(throws: Refusal.malformed) { try Bridge.unframe(Bytes.u32(10) + Data("{}".utf8)) }
        #expect(throws: Refusal.malformed) { try Bridge.unframe(Bytes.u32(65_537) + Data(count: 65_537)) }
        #expect(throws: Refusal.malformed) { try Bridge.unframe(Bytes.u32(2) + Data("[]".utf8)) }              // meta must be an object
        #expect(throws: Refusal.malformed) { try Bridge.unframe(Bytes.u32(13) + Data("{\"a\":1,\"a\":2}".utf8)) }  // duplicate key
        #expect(throws: Refusal.malformed) { try Bridge.frame(meta: ["x": .string(String(repeating: "a", count: 70_000))]) }
        #expect(throws: Refusal.malformed) { try Bridge.frame(meta: .array([])) }
        let (m, d) = try Bridge.unframe(Bridge.frame(meta: ["a": 1], data: Data([1, 2, 3])))
        #expect(m == ["a": 1] && d == Data([1, 2, 3]))
    }

    @Test func sealOpenRoundTripAndTamper() throws {
        let r = Rig()
        let h = Bridge.Header(direction: .toHost, workspace: r.ws, device: r.dev, rid: r.rid, seq: 1, tsMs: 5, epoch: 3)
        let signer = SoftwareSigner()
        let key = KDF.kBridge(wk: r.wk, workspace: r.ws, epoch: 3)
        let a = try Bridge.seal(header: h, channelKey: key, signer: signer, plaintext: Data("x".utf8))
        let again = try Bridge.seal(header: Bridge.Header(direction: .toHost, workspace: r.ws, device: r.dev, rid: r.rid, seq: 1, tsMs: 5, epoch: 3),
                                    channelKey: key, signer: signer, plaintext: Data("x".utf8))
        #expect(a != again)                                                                        // fresh salt
        let parts = try Bridge.Parts(envelope: a)
        #expect(try Bridge.openBody(parts, channelKey: key) == Data("x".utf8))
        for i in 0..<a.count {                                                                     // every byte is covered
            var t = a; t[i] ^= 1
            guard let p = try? Bridge.Parts(envelope: t) else { continue }
            let ok = Bridge.verifySignature(p, key: signer.publicKey) && (try? Bridge.openBody(p, channelKey: key)) != nil
            #expect(!ok, "byte \(i)")
        }
    }
}
