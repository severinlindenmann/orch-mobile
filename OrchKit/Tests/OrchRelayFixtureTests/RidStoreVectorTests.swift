import Foundation
import Testing
@testable import OrchFakeHost
@testable import OrchProtocol
import OrchTestVectors

/// The FakeRelay's bridge replay store against the shared `p3.cases` (protocol-v2 P3-D8/D9/D22): every `request_replay` and
/// `chunk` case of both suites, from its complete input state to the exact expected result and post-state. The vectors number
/// copies per record (`max(cursor, copies) + 1`); the FakeRelay passes its workspace position counter instead.
@Suite struct RidStoreVectorTests {
    static let cases: [(suite: String, JSONValue)] = {
        guard let root = try? StrictJSON.parse(Vectors.data, maxBytes: .max, maxDepth: 64) else { return [] }
        return ["1", "2"].flatMap { suite in
            (root.object?["suites"]?.object?[suite]?.object?["p3"]?.object?["cases"]?.array ?? [])
                .filter { ["request_replay", "chunk"].contains($0.object?["op"]?.string ?? "") }.map { (suite, $0) }
        }
    }()

    /// A hex digest, or an opaque placeholder (the cap cases fill other chunk slots with "other").
    static func digest(_ s: String) -> Data { Hex.decode(s) ?? Data(s.utf8) }

    static func record(_ v: JSONValue?) throws -> RelayRidRecord? {
        guard let o = v?.object, !o.isEmpty else { return nil }
        let copies = try (o["copies"]?.array ?? []).map { c in
            RelayRidRecord.Copy(n: UInt64(try #require(c.object?["n"]?.int)), expiresMs: try #require(c.object?["expires_ms"]?.int))
        }
        var chunks: [UInt64: RelayRidRecord.Chunk] = [:]
        for (k, c) in o["chunks"]?.object ?? [:] {
            chunks[try #require(UInt64(k))] = .init(digest: Self.digest(try #require(c.object?["digest"]?.string)),
                                                     flags: UInt8(try #require(c.object?["flags"]?.int)),
                                                     expiresMs: try #require(c.object?["expires_ms"]?.int))
        }
        return RelayRidRecord(digest: Self.digest(try #require(o["digest"]?.string)), reqEpoch: UInt32(try #require(o["req_epoch"]?.int)),
                              firstMs: try #require(o["first_ms"]?.int), requeues: Int(try #require(o["requeues"]?.int)),
                              lastRequeueMs: try #require(o["last_requeue_ms"]?.int), keepUntilMs: try #require(o["keep_until_ms"]?.int),
                              copies: copies, chunks: chunks)
    }

    /// The post-state without bodies (the vectors carry metadata only).
    static func metadata(_ r: RelayRidRecord?) -> RelayRidRecord? {
        guard var r else { return nil }
        for i in r.copies.indices { r.copies[i].envelope = nil }
        for k in r.chunks.keys { r.chunks[k]?.envelope = nil }
        return r
    }

    static func expected(request v: JSONValue) -> RidStore.RequestResult? {
        let o = v.object ?? [:]
        switch (o["ok"]?.string, o["refuse"]?.string) {
        case ("queued", nil): return o["n"]?.int.map { .queued(n: UInt64($0)) }
        case ("coalesced", nil): return .coalesced
        case (nil, "stale_epoch"): return o["epoch"]?.int.map { .staleEpoch(epoch: UInt32($0)) }
        case (nil, "rid_conflict"): return .ridConflict
        case (nil, "retry_exhausted"): return .retryExhausted
        case (nil, "rate_limited"): return o["retry_after"]?.int.map { .rateLimited(retryAfter: Int($0)) }
        default: return nil
        }
    }

    static func expected(chunk v: JSONValue) -> RidStore.ChunkResult? {
        let o = v.object ?? [:]
        switch (o["ok"]?.string, o["refuse"]?.string) {
        case ("stored", nil): return .stored
        case ("replay", nil): return .replay
        case (nil, "expired"): return .expired
        case (nil, "chunk_conflict"): return .chunkConflict
        case (nil, "stale_epoch"): return o["epoch"]?.int.map { .staleEpoch(epoch: UInt32($0)) }
        case (nil, "quota_exceeded"): return .quotaExceeded
        default: return nil
        }
    }

    @Test func requestReplayAndChunkCasesOfBothSuites() throws {
        #expect(Self.cases.count == 60)          // 30 request_replay + chunk cases per suite
        for (suite, c) in Self.cases {
            let o = try #require(c.object)
            let name = "\(suite)/\(o["name"]?.string ?? "?")"
            let args = try #require(o["args"]?.object)
            let raw = try #require(args["raw"]?.string.flatMap { Hex.decode($0) })
            let header = try Bridge.Parts(envelope: raw).header
            let epoch = UInt32(try #require(args["epoch"]?.int)), now = try #require(args["now_ms"]?.int)
            var state = try Self.record(o["state"])
            let expect = try #require(o["expect"]?.object)
            switch o["op"]?.string {
            case "request_replay":
                let result = try #require(expect["result"])
                let want = try #require(Self.expected(request: result), "\(name) result")
                let cursor = try #require(args["cursor"]?.int)
                let got = RidStore.request(&state, raw: raw, header: header, epoch: epoch, nowMs: now, cursor: UInt64(cursor))
                #expect(got == want, "\(name)")
            default:
                let result = try #require(expect["result"])
                let want = try #require(Self.expected(chunk: result), "\(name) result")
                let got = RidStore.chunk(&state, raw: raw, header: header, epoch: epoch, nowMs: now)
                #expect(got == want, "\(name)")
            }
            #expect(Self.metadata(state) == (try Self.record(expect["state"])), "\(name) post-state")
        }
    }
}
