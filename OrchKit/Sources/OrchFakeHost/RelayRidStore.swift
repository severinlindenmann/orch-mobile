import CryptoKit
import Foundation
import OrchProtocol

/// The relay's replay record of one `(workspace, device, rid)` (protocol-v2 section 19.3, P3-D8, P3-D9 and P3-D22), a port of the
/// reference `relay_bridge_request` / `relay_bridge_chunk`. It knows the request's full-envelope digest and epoch, its queued copies
/// (each with its delivery position `n` and its own 60 s lifetime) and the digests of the response chunks stored for it. The record
/// lives 900 s from the FIRST receipt; a resend never extends that, only a dependent copy or chunk does (`keepUntilMs`).
///
/// Bodies are kept beside the metadata only while they live (`envelope` becomes nil when a copy or chunk expires). An expired chunk
/// comes back only when the host posts the EXACT stored bytes again (P3-D27, bounded); its digest answers `chunk_conflict` for any
/// other bytes until the record goes.
package struct RelayRidRecord: Equatable, Sendable {
    package struct Copy: Equatable, Sendable {
        package var n: UInt64
        package var expiresMs: Int64
        package var envelope: Data?
        package init(n: UInt64, expiresMs: Int64, envelope: Data? = nil) { self.n = n; self.expiresMs = expiresMs; self.envelope = envelope }
    }
    package struct Chunk: Equatable, Sendable {
        package var digest: Data
        package var flags: UInt8
        package var expiresMs: Int64
        package var envelope: Data?
        /// How often the exact bytes were stored again after expiring (P3-D27, orch-relay d3816ea): at most `maxRestores`.
        package var restores: Int
        package init(digest: Data, flags: UInt8, expiresMs: Int64, envelope: Data? = nil, restores: Int = 0) {
            self.digest = digest; self.flags = flags; self.expiresMs = expiresMs; self.envelope = envelope; self.restores = restores
        }
    }
    package var digest: Data
    package var reqEpoch: UInt32
    package var firstMs: Int64
    package var requeues: Int
    package var lastRequeueMs: Int64
    package var keepUntilMs: Int64
    package var copies: [Copy]
    package var chunks: [UInt64: Chunk]

    package init(digest: Data, reqEpoch: UInt32, firstMs: Int64, requeues: Int, lastRequeueMs: Int64, keepUntilMs: Int64,
                 copies: [Copy], chunks: [UInt64: Chunk]) {
        self.digest = digest; self.reqEpoch = reqEpoch; self.firstMs = firstMs; self.requeues = requeues
        self.lastRequeueMs = lastRequeueMs; self.keepUntilMs = keepUntilMs; self.copies = copies; self.chunks = chunks
    }

    /// A copy the host has not acknowledged (`n` above the holder's cursor) that is still alive.
    package func hasUndeliveredCopy(cursor: UInt64, nowMs: Int64) -> Bool { copies.contains { $0.n > cursor && nowMs < $0.expiresMs } }
}

package enum RidStore {
    package static let retentionMs: Int64 = 900_000
    package static let requeueIntervalMs: Int64 = 10_000
    package static let maxRequeues = 8
    package static let maxChunks = 64
    /// P3-D27: an expired chunk's exact bytes may be stored again only until this long after the rid's FIRST receipt, and at most
    /// `maxRestores` times per chunk (orch-relay d3816ea, Q11).
    package static let restoreWindowMs: Int64 = 900_000
    package static let maxRestores = 8

    package enum RequestResult: Equatable, Sendable {
        case queued(n: UInt64), coalesced
        case staleEpoch(epoch: UInt32), ridConflict, retryExhausted
        /// The ten-second requeue interval (section 19.6): `Retry-After` is the remaining interval rounded up.
        case rateLimited(retryAfter: Int)
    }

    package enum ChunkResult: Equatable, Sendable {
        case stored, replay, restored
        case expired, chunkConflict, staleEpoch(epoch: UInt32), quotaExceeded, retryExhausted
    }

    package static func digest(_ raw: Data) -> Data { Data(SHA256.hash(data: raw)) }

    /// A device request for a rid (P3-D8/D9). The caller has already checked session, membership and shape. `epoch` is the current
    /// list epoch, `cursor` the holder's acknowledged position. `nextN` is the position a new copy gets; nil uses the reference's
    /// per-record numbering (`max(cursor, copies) + 1`), which the shared vectors pin; the FakeRelay passes its workspace counter.
    package static func request(_ record: inout RelayRidRecord?, raw: Data, header: Bridge.Header, epoch: UInt32, nowMs: Int64, cursor: UInt64,
                                copyLifetimeMs: Int64 = 60_000, nextN: UInt64? = nil) -> RequestResult {
        let d = digest(raw)
        if let r = record, nowMs >= r.keepUntilMs { record = nil }
        if var r = record {
            guard r.digest == d else { return .ridConflict }
            // An identical resend of a known rid skips the epoch check: the host answers it from its rid store.
            if r.hasUndeliveredCopy(cursor: cursor, nowMs: nowMs) { return .coalesced }
            if r.requeues >= maxRequeues { return .retryExhausted }
            if nowMs < r.lastRequeueMs + requeueIntervalMs {
                return .rateLimited(retryAfter: Int((r.lastRequeueMs + requeueIntervalMs - nowMs + 999) / 1000))
            }
            r.requeues += 1
            r.lastRequeueMs = nowMs
            let n = nextN ?? (max(cursor, r.copies.map(\.n).max() ?? 0) + 1)
            r.copies.append(.init(n: n, expiresMs: nowMs + copyLifetimeMs, envelope: raw))
            r.keepUntilMs = max(r.keepUntilMs, nowMs + copyLifetimeMs)
            record = r
            return .queued(n: n)
        }
        // A NEW rid whose header epoch is not the current list epoch: the unsigned hint (P3-D8). Nothing is recorded.
        guard header.epoch == epoch else { return .staleEpoch(epoch: epoch) }
        let n = nextN ?? (cursor + 1)
        record = RelayRidRecord(digest: d, reqEpoch: epoch, firstMs: nowMs, requeues: 0, lastRequeueMs: nowMs,
                           keepUntilMs: max(nowMs + retentionMs, nowMs + copyLifetimeMs),
                           copies: [.init(n: n, expiresMs: nowMs + copyLifetimeMs, envelope: raw)], chunks: [:])
        return .queued(n: n)
    }

    /// A host response chunk (P3-D22, P3-D27). The caller has checked shape, holder and the target device's membership (in that order,
    /// before this). `room` is the target's remaining response budget in bytes (nil: not constraining); it is the last check.
    package static func chunk(_ record: inout RelayRidRecord?, raw: Data, header: Bridge.Header, epoch: UInt32, nowMs: Int64,
                              chunkLifetimeMs: Int64 = 60_000, room: Int? = nil) -> ChunkResult {
        guard var r = record, nowMs < r.keepUntilMs else { return .expired }
        let d = digest(raw)
        let lastRefusal = Bridge.Flags.last.rawValue | Bridge.Flags.refusal.rawValue
        if var old = r.chunks[header.seq] {
            // Only the EXACT stored bytes are ever stored again; other bytes for a stored index stay a conflict.
            guard old.digest == d else { return .chunkConflict }
            if nowMs < old.expiresMs { return .replay }                      // a live duplicate: TTL unchanged, nothing charged
            if header.epoch != epoch && header.flags & lastRefusal != lastRefusal { return .replay }   // old-epoch data: never
            if nowMs >= r.firstMs + restoreWindowMs { return .expired }       // the immutable deadline, never keep_until_ms
            if old.restores >= maxRestores { return .retryExhausted }
            if let room, raw.count > room { return .quotaExceeded }
            old.restores += 1
            old.expiresMs = min(nowMs + chunkLifetimeMs, r.keepUntilMs)       // keep_until_ms unchanged
            old.envelope = raw
            r.chunks[header.seq] = old
            record = r
            return .restored
        }
        if header.epoch != r.reqEpoch || (header.epoch != epoch && header.flags & lastRefusal != lastRefusal) {
            return .staleEpoch(epoch: epoch)
        }
        if r.chunks.count >= maxChunks { return .quotaExceeded }
        if let room, raw.count > room { return .quotaExceeded }
        r.chunks[header.seq] = .init(digest: d, flags: header.flags, expiresMs: nowMs + chunkLifetimeMs, envelope: raw)
        r.keepUntilMs = max(r.keepUntilMs, nowMs + chunkLifetimeMs)
        record = r
        return .stored
    }
}
