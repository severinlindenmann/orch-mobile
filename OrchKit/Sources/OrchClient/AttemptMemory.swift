import Foundation
import OrchCustody
import OrchProtocol

/// The phone's memory of its own pairing attempts (protocol-v2 section 8.3 step 2, G3b P3-D28): the current attempt's
/// `(device_id, dk_hash)` and the earlier ones, each kept at least 10 minutes after it was replaced (the challenge lifetime), so a
/// challenge or rejection of an own earlier attempt is dropped without the alarm (`stale_attempt`). A realm-level `.keys` item that
/// outlives the pairing records. A phone that lost it treats such objects as foreign (the alarm): fail closed.
enum AttemptMemory {
    static let purpose = "pairing.attempts"
    static let retentionMs: Int64 = 10 * 60_000

    struct Entry: Equatable {
        let attempt: PairingAttemptContext.EarlierAttempt
        let untilMs: Int64
    }

    /// Starts a new attempt in one write, before its pair request is sent: the previous `last` moves to `earlier` (kept until
    /// `now + 10 min`), expired entries go, and this attempt becomes `last`. Returns the earlier attempts. An unreadable memory is
    /// replaced (its entries are lost: their objects then raise the alarm); a write failure throws.
    static func begin(vault: RealmVault, device: ID16, dkHash: Data, nowMs now: Int64) throws -> [Entry] {
        var (last, earlier) = read(vault)
        if let l = last { earlier.append(Entry(attempt: l, untilMs: saturatingAdd(now, retentionMs))) }
        earlier = earlier.filter { $0.untilMs > now }
        last = .init(deviceID: device, dkHash: dkHash)
        let doc: JSONValue = [
            "last": ["device_id": .string(device.hex), "dk_hash": .string(B64U.encode(dkHash))],
            "earlier": .array(earlier.map { ["device_id": .string($0.attempt.deviceID.hex), "dk_hash": .string(B64U.encode($0.attempt.dkHash)),
                                              "until_ms": .int($0.untilMs)] })]
        try vault.put(try canonicalJSON(doc), purpose: purpose)
        return earlier
    }

    /// The earlier attempts as stored (for a resumed pairing); empty when the memory is missing or unreadable.
    static func earlier(_ vault: RealmVault) -> [Entry] { read(vault).earlier }

    private static func read(_ vault: RealmVault) -> (last: PairingAttemptContext.EarlierAttempt?, earlier: [Entry]) {
        guard let data = try? vault.get(purpose: purpose), let v = try? StrictJSON.parse(data, maxBytes: 1 << 20), let o = v.object else { return (nil, []) }
        func pair(_ x: [String: JSONValue]?) -> PairingAttemptContext.EarlierAttempt? {
            guard let x, let d = x.idField("device_id"), let h = x.b64uField("dk_hash", length: 32) else { return nil }
            return .init(deviceID: d, dkHash: h)
        }
        let last = pair(o["last"]?.object)
        let earlier = (o["earlier"]?.array ?? []).compactMap { e -> Entry? in
            guard let p = pair(e.object), let u = e.object?["until_ms"]?.int else { return nil }
            return Entry(attempt: p, untilMs: u)
        }
        return (last, earlier)
    }
}
