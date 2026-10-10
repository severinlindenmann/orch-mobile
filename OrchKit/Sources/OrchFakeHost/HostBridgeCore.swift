import CryptoKit
import Foundation
import OrchClient
import OrchProtocol

/// Limits of the host's rid store and refusal budget (protocol 8.6, bridge v1 section 5.3). Defaults are the reference
/// implementation's.
package struct HostLimits: Equatable, Sendable {
    package var perDevice = 1024
    package var maxRecords = 16384
    package var busyAllowance = 64
    package var refusalBudget = 10
    package var budgetWindowMs: Int64 = 60_000
    package var ridRetentionMs: Int64 = 900_000
    package var windowMs: Int64 = Bridge.windowMs
    package init() {}
}

/// 64-entry sliding window of accepted sequence numbers per device (the v1 window).
package struct SeqWindow: Equatable, Sendable {
    package static let size: UInt64 = 64
    package var high: UInt64 = 0
    package var bitmap: UInt64 = 0
    package init(high: UInt64 = 0, bitmap: UInt64 = 0) { self.high = high; self.bitmap = bitmap }

    /// Consumes `seq` if it is new and inside the window.
    package mutating func accept(_ seq: UInt64) -> Bool {
        if seq > high {
            let shift = seq - high
            bitmap = shift < Self.size ? ((bitmap << shift) | 1) : 1
            high = seq
            return true
        }
        let i = high - seq
        if seq < 1 || i >= Self.size || (bitmap >> i) & 1 == 1 { return false }
        bitmap |= 1 << i
        return true
    }
}

package struct RidRecord: Equatable, Sendable {
    package enum Outcome: Equatable, Sendable {
        /// The refusal recorded for this rid; replayed with fresh `host_ms`, `high` and `epoch`.
        case refusal(HostRefusal)
        /// Sealed response chunks, replayed byte for byte.
        case stored([Data])
        /// The response was too big to keep.
        case bodyNotStored(status: String)
    }
    package var device: ID16
    package var digest: Data
    package var outcome: Outcome?
    package var until: Int64
}

package struct HostAccepted: Equatable, Sendable {
    package let header: Bridge.Header
    package let scopes: [String]
    package let meta: JSONValue
    package let data: Data
}

package enum HostCheck: Equatable, Sendable {
    /// Silence. `why` is the vectors' spelling.
    case drop(String)
    case refuse(HostRefusal, Bridge.Header)
    case replay([Data], Bridge.Header)
    case accept(HostAccepted)
    /// An epoch-0 answer (section 8.3): sealed under the offer's `K_pair`, signed by `WSK`, carrying `wsk_pub`.
    case pair(HostPairReply, Bridge.Header)
}

/// Section 8.6, in the normative order. Epoch >= 1 requests run the device pipeline; epoch 0 (pairing, section 8.3, `K_pair`,
/// offers) goes to `checkPairing`. Pure state machine: no clock, no I/O.
package struct HostBridgeCore: Sendable {
    package var workspace: ID16
    package var epoch: UInt32
    package var keys: [UInt32: SymmetricKey] = [:]
    package var members: [ID16: [String]] = [:]
    package var devicePubs: [ID16: SigningPublicKey] = [:]
    package var revoked: Set<ID16> = []
    package var seq: [ID16: SeqWindow] = [:]
    package var rids: [ID16: RidRecord] = [:]
    package var streams: [ID16: ID16] = [:]
    package var unverified: [Int64] = []
    package var limits = HostLimits()
    // Pairing (section 8.3): offers by id, the pending pairing of each device, and the two keys an answer needs.
    package var offers: [ID16: HostOffer] = [:]
    package var pendingPairs: [ID16: HostPendingPair] = [:]
    package var wskPub: SigningPublicKey?
    package var ownerPK: SigningPublicKey?
    package var approvedEpochOverride: UInt32?

    package init(workspace: ID16, epoch: UInt32) { self.workspace = workspace; self.epoch = epoch }

    private func live(_ now: Int64) -> [RidRecord] { rids.values.filter { now < $0.until } }

    /// Drops rid records whose retention ended: they no longer count against the quotas and cannot grow without bound.
    /// A real host persists this store and the sequence windows atomically together (gaps.md).
    private mutating func prune(_ now: Int64) { rids = rids.filter { now < $0.value.until } }

    private enum RecordFailure: Error { case storeFull, deviceFull }

    private mutating func record(_ h: Bridge.Header, _ digest: Data, _ now: Int64, _ outcome: RidRecord.Outcome?) throws {
        let all = live(now)
        if all.count >= limits.maxRecords { throw RecordFailure.storeFull }
        if all.filter({ $0.device == h.device }).count >= limits.perDevice + limits.busyAllowance { throw RecordFailure.deviceFull }
        rids[h.rid] = RidRecord(device: h.device, digest: digest, outcome: outcome, until: now + limits.ridRetentionMs)
    }

    /// A refusal from step 4: counted in the host-wide budget and dropped once it is spent.
    private mutating func budgeted(_ r: HostRefusal, _ h: Bridge.Header, _ now: Int64) -> HostCheck {
        let recent = unverified.filter { now - $0 < limits.budgetWindowMs }
        guard recent.count < limits.refusalBudget else { unverified = recent; return .drop("budget") }
        unverified = recent + [now]
        return .refuse(r, h)
    }

    private mutating func recorded(_ r: HostRefusal, _ h: Bridge.Header, _ digest: Data, _ now: Int64) -> HostCheck {
        do { try record(h, digest, now, .refusal(r)); return .refuse(r, h) }
        catch RecordFailure.storeFull { return .drop("store_full") }
        catch { return .drop("busy_unrecordable") }
    }

    package mutating func check(_ env: Data, mailbox: ID16?, nowMs now: Int64) -> HostCheck {
        prune(now)
        // 1. shape
        guard env.count >= Bridge.overhead, env.count <= Bridge.maxRequest, let parts = try? Bridge.Parts(envelope: env) else { return .drop("size") }
        let h = parts.header
        guard h.magic == Bridge.magic, h.version == Bridge.version else { return .drop("version") }
        guard h.direction == Bridge.Direction.toHost.rawValue, h.flags & ~Bridge.Flags.stream.rawValue == 0 else { return .drop("direction_or_flags") }
        guard h.suite == Suite2.id else { return .drop("suite") }
        guard h.workspace == workspace else { return .drop("workspace") }
        if let m = mailbox, m != h.rid { return .drop("mailbox_mismatch") }
        // 2. key
        if h.epoch > epoch { return .drop("future_epoch") }
        if h.epoch == 0 { return checkPairing(parts, now) }
        guard h.epoch >= 1, let wk = keys[h.epoch], let ck = Bridge.channelKey(header: h, wk: wk) else { return .drop("no_key") }
        // 3. tag
        guard let plain = try? Bridge.openBody(parts, channelKey: ck) else { return .drop("tag") }
        // 4. device
        let dev = h.device
        if revoked.contains(dev) { return budgeted(.revoked, h, now) }
        guard members[dev] != nil, let pub = devicePubs[dev] else { return budgeted(.notMember, h, now) }
        guard Bridge.verifySignature(parts, key: pub) else { return budgeted(.badSignature, h, now) }
        // 5. a known request id
        let digest = parts.digest
        if let known = rids[h.rid], now < known.until {
            guard known.device == dev, known.digest == digest else { return .refuse(.ridConflict, h) }
            switch known.outcome {
            case nil: return .refuse(.alreadyDone(status: "unknown"), h)
            case .refusal(let r)?:
                switch r {
                case .staleTimestamp: return .refuse(.staleTimestamp(hostMs: now), h)
                case .staleSequence: return .refuse(.staleSequence(high: seq[dev]?.high ?? 0), h)
                case .staleEpoch: return .refuse(.staleEpoch(epoch: epoch), h)
                default: return .refuse(r, h)
                }
            case .bodyNotStored(let s)?: return .refuse(.alreadyDone(status: s), h)
            case .stored(let chunks)?: return .replay(chunks, h)
            }
        }
        // 5b. quota
        if live(now).filter({ $0.device == dev }).count >= limits.perDevice { return recorded(.busy, h, digest, now) }
        // 6. framing
        guard let (meta, data) = try? Bridge.unframe(plain), meta.object?["op"]?.string != nil else { return recorded(.malformed, h, digest, now) }
        // 7. sequence (consumed from here on)
        var w = seq[dev] ?? SeqWindow()
        let ok = w.accept(h.seq)
        seq[dev] = w
        guard ok else { return recorded(.staleSequence(high: w.high), h, digest, now) }
        // 8. time
        let diff = now.subtractingReportingOverflow(h.tsMs > UInt64(Int64.max) ? Int64.max : Int64(h.tsMs))
        if diff.overflow || abs(diff.partialValue) > limits.windowMs { return recorded(.staleTimestamp(hostMs: now), h, digest, now) }
        // 9. epoch
        if h.epoch != epoch { return recorded(.staleEpoch(epoch: epoch), h, digest, now) }
        // 10. stream
        if h.stream != ID16(bytes: Data(count: 16))!, streams[h.stream] != dev { return recorded(.forbiddenScope, h, digest, now) }
        // 11. record and run
        do { try record(h, digest, now, nil) }
        catch RecordFailure.storeFull { return .drop("store_full") }
        catch { return .drop("busy_unrecordable") }
        if h.flagSet.contains(.stream) { streams[h.rid] = dev }
        return .accept(HostAccepted(header: h, scopes: members[dev] ?? [], meta: meta, data: data))
    }

    /// Sets the final outcome of an accepted request (what a later identical re-send replays).
    package mutating func complete(rid: ID16, with outcome: RidRecord.Outcome) { rids[rid]?.outcome = outcome }

    // MARK: revocation op (protocol 6.2, 8.7)

    package enum RevocationResult: Equatable, Sendable {
        case ok(device: ID16, rotate: Bool)
        case refuse(String)
    }

    /// `{"op":"revocation","record":<signed revocation>}`. Authority is `PK`'s signature, whoever relays it. Records the
    /// revocation and removes the device from the roster; the caller rotates when `rotate` is true.
    package mutating func applyRevocation(_ meta: JSONValue, ownerKey: SigningPublicKey) -> RevocationResult {
        guard let m = meta.object, Set(m.keys) == ["op", "record"], let record = m["record"] else { return .refuse("malformed") }
        guard let signed = try? SignedObject.parse(record), let o = try? signed.verify(kind: .revocation, key: ownerKey) else { return .refuse("bad_signature") }
        guard Set(o.keys) == ["v", "suite", "kind", "person_id", "device_id", "revoked_ms", "reason"],
              let reason = o["reason"]?.string, Revocation.reasons.contains(where: { $0.utf8.elementsEqual(reason.utf8) }),
              o["revoked_ms"]?.int != nil, let person = o["person_id"]?.string.flatMap({ ID16(hex: $0) }),
              let device = o["device_id"]?.string.flatMap({ ID16(hex: $0) }) else { return .refuse("malformed") }
        guard person == Identifiers.personID(ownerKey) else { return .refuse("other_person") }
        revoked.insert(device)
        let was = members.removeValue(forKey: device) != nil
        devicePubs[device] = nil
        streams = streams.filter { $0.value != device }          // a revoked device's streams end with it
        return .ok(device: device, rotate: was)
    }
}
