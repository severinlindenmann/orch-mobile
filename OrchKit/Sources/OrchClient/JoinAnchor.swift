import Foundation
import OrchProtocol

/// The join floor of an approved pairing (protocol-v2 section 8.3, G3b P3-D28; F1 Q6): the `approved` answer's `epoch`,
/// `list_seq`, `card_seq`, `scopes` and `baseline`, persisted before anything is fetched and kept across join retries and restarts.
/// The first member list and card the phone accepts must be at or above it, so a relay cannot roll the join back below approval.
public struct JoinAnchor: Equatable, Sendable {
    public struct Baseline: Equatable, Sendable {
        public let n: Int64
        /// `"sha256:" + 64 lower-case hex`.
        public let hash: String
        public init(n: Int64, hash: String) { self.n = n; self.hash = hash }

        /// `null` or exactly `{"n": safe integer >= 0, "hash": "sha256:" + 64 lower-case hex}`; `nil` for anything else.
        static func parse(_ v: JSONValue) -> Baseline?? {
            if v.isNull { return .some(nil) }
            guard let o = v.object, Set(o.keys) == ["n", "hash"], o.keys.count == 2, let n = o["n"]?.int, n >= 0, n <= maxSafeInt,
                  let h = o["hash"]?.string, h.utf8.count == 71, h.hasPrefix("sha256:"),
                  h.utf8.dropFirst(7).allSatisfy(isLowerHex) else { return nil }
            return .some(Baseline(n: n, hash: h))
        }
        var json: JSONValue { ["n": .int(n), "hash": .string(hash)] }

        private static func isLowerHex(_ b: UInt8) -> Bool { (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66) }
    }

    public var epoch: UInt32
    public var listSeq: Int64
    public var cardSeq: Int64
    public var scopes: [String]
    public var baseline: Baseline?

    public init(epoch: UInt32, listSeq: Int64, cardSeq: Int64, scopes: [String], baseline: Baseline?) {
        self.epoch = epoch; self.listSeq = listSeq; self.cardSeq = cardSeq; self.scopes = scopes; self.baseline = baseline
    }

    /// A later `approved` only raises the floor: each number is the maximum; the baseline is replaced only by one with a strictly
    /// higher `n` (an equal `n` with another hash keeps the stored one); the scopes only by an answer with a strictly higher
    /// `list_seq`.
    public func raised(by next: JoinAnchor) -> JoinAnchor {
        var a = self
        if next.listSeq > listSeq { a.scopes = next.scopes }
        a.epoch = max(epoch, next.epoch); a.listSeq = max(listSeq, next.listSeq); a.cardSeq = max(cardSeq, next.cardSeq)
        if let nb = next.baseline, nb.n > (baseline?.n ?? -1) { a.baseline = nb }
        return a
    }

    /// Why the phone refuses an object at join (section 8.3): `below_anchor` and `scopes_mismatch` retry, `not_a_member` stops.
    public enum Refusal: String, Error, Equatable, Sendable {
        case belowAnchor = "below_anchor"
        case scopesMismatch = "scopes_mismatch"
        case notAMember = "not_a_member"
    }

    /// The first member list: `epoch` and `list_seq` at or above the floor (`below_anchor`), this device listed (`not_a_member`),
    /// and at exactly the floor's `list_seq` the floor's scopes (`scopes_mismatch`). Above it the list's scopes are authoritative.
    /// Returns the scopes the device joins with.
    public func checkList(_ list: MemberList, device: ID16) throws -> [String] {
        guard list.epoch >= epoch, list.listSeq >= listSeq else { throw Refusal.belowAnchor }
        guard let me = list.members.first(where: { $0.deviceID == device }), let mine = me.scopeStrings else { throw Refusal.notAMember }
        if list.listSeq == listSeq {
            guard mine.count == scopes.count, zip(mine, scopes).allSatisfy({ $0.utf8Equal($1) }) else { throw Refusal.scopesMismatch }
        }
        return mine
    }

    /// The first card: `card_seq` at or above the floor (`below_anchor`).
    public func checkCard(cardSeq seq: Int64) throws {
        guard seq >= cardSeq else { throw Refusal.belowAnchor }
    }

    var json: JSONValue {
        ["epoch": .int(Int64(epoch)), "list_seq": .int(listSeq), "card_seq": .int(cardSeq), "scopes": .array(scopes.map { .string($0) }),
         "baseline": baseline?.json ?? .null]
    }

    static func parse(_ v: JSONValue?) -> JoinAnchor? {
        guard let o = v?.object, let e = o.u32Field("epoch"), let l = o["list_seq"]?.int, l >= 1, l <= maxSafeInt,
              let c = o["card_seq"]?.int, c >= 1, c <= maxSafeInt, let sv = o["scopes"]?.array, case let scopes = sv.compactMap(\.string),
              scopes.count == sv.count, let b = o["baseline"], let baseline = Baseline.parse(b) else { return nil }
        return JoinAnchor(epoch: e, listSeq: l, cardSeq: c, scopes: scopes, baseline: baseline)
    }
}
