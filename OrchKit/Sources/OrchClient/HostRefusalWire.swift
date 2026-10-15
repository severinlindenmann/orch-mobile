import Foundation
import OrchProtocol

/// Wire spelling of sealed host refusals (protocol section 14, bridge table). Never carries `host_api`, never echoes request
/// content: only the code and its documented fields.
public extension HostRefusal {
    var code: String {
        switch self {
        case .malformed: "malformed"
        case .notVisible: "not_visible"
        case .notMember: "not_member"
        case .revoked: "revoked"
        case .badSignature: "bad_signature"
        case .ridConflict: "rid_conflict"
        case .alreadyDone: "already_done"
        case .staleTimestamp: "stale_timestamp"
        case .staleSequence: "stale_sequence"
        case .staleEpoch: "stale_epoch"
        case .forbiddenScope: "forbidden_scope"
        case .busy: "busy"
        case .scopeChanged: "scope_changed"
        case .stopped: "stopped"
        case .alreadyAnswered: "already_answered"
        case .questionChanged: "question_changed"
        case .pairingClosed: "pairing_closed"
        case .otherPerson: "other_person"
        case .certInvalid: "cert_invalid"
        case .certExpired: "cert_expired"
        case .host(let code, _, _, _): code
        }
    }

    /// `{"refusal": code, ...fields}`
    var meta: JSONValue {
        var o: [String: JSONValue] = ["refusal": .string(code)]
        switch self {
        case .alreadyDone(let s): o["status"] = .string(s)
        case .staleTimestamp(let h): o["host_ms"] = .int(h)
        case .staleSequence(let h): o["high"] = .int(Int64(min(h, UInt64(maxSafeInt))))
        case .staleEpoch(let e): o["epoch"] = .int(Int64(e))
        case .alreadyAnswered(let l, let at): o["by_device_label"] = .string(l); o["at_ms"] = .int(at)
        case .questionChanged(let h): o["content_hash"] = .string(B64U.encode(h))
        case .host(_, let retryable, let seqs, let nextKey):
            o["retryable"] = .bool(retryable)
            if let seqs { o["seqs"] = .array(seqs.map { .int($0) }) }
            if let nextKey { o["next_key"] = .string(nextKey) }
        default: break
        }
        return .object(o)
    }

    /// Strict: exact field set for the code, correct types.
    init?(meta: JSONValue) {
        guard let m = meta.object, let code = m["refusal"]?.string else { return nil }
        let rest = Set(m.keys).subtracting(["refusal"])
        func none(_ r: HostRefusal) -> HostRefusal? { rest.isEmpty ? r : nil }
        switch code {
        case "malformed": guard let r = none(.malformed) else { return nil }; self = r
        case "not_visible": guard let r = none(.notVisible) else { return nil }; self = r
        case "not_member": guard let r = none(.notMember) else { return nil }; self = r
        case "revoked": guard let r = none(.revoked) else { return nil }; self = r
        case "bad_signature": guard let r = none(.badSignature) else { return nil }; self = r
        case "rid_conflict": guard let r = none(.ridConflict) else { return nil }; self = r
        case "forbidden_scope": guard let r = none(.forbiddenScope) else { return nil }; self = r
        case "busy": guard let r = none(.busy) else { return nil }; self = r
        case "scope_changed": guard let r = none(.scopeChanged) else { return nil }; self = r
        case "stopped": guard let r = none(.stopped) else { return nil }; self = r
        case "pairing_closed": guard let r = none(.pairingClosed) else { return nil }; self = r
        case "other_person": guard let r = none(.otherPerson) else { return nil }; self = r
        case "cert_invalid": guard let r = none(.certInvalid) else { return nil }; self = r
        case "cert_expired": guard let r = none(.certExpired) else { return nil }; self = r
        case "already_done":
            // Whitelisted outcome (orch-29 Q12): completed | failed | unknown. Advisory only; never a host status code.
            guard rest == ["status"], let s = m["status"]?.string, ["completed", "failed", "unknown"].contains(s) else { return nil }
            self = .alreadyDone(status: s)
        case "stale_timestamp":
            guard rest == ["host_ms"], let h = m["host_ms"]?.int else { return nil }; self = .staleTimestamp(hostMs: h)
        case "stale_sequence":
            guard rest == ["high"], let h = m["high"]?.int, h >= 0 else { return nil }; self = .staleSequence(high: UInt64(h))
        case "stale_epoch":
            guard rest == ["epoch"], let e = m["epoch"]?.int, e >= 1, e <= Int64(UInt32.max) else { return nil }; self = .staleEpoch(epoch: UInt32(e))
        case "already_answered":
            guard rest == ["by_device_label", "at_ms"], let l = m["by_device_label"]?.string, let a = m["at_ms"]?.int else { return nil }
            self = .alreadyAnswered(byDeviceLabel: l, atMs: a)
        case "question_changed":
            guard rest == ["content_hash"], let h = m["content_hash"]?.string.flatMap({ B64U.decode($0, length: 32) }) else { return nil }
            self = .questionChanged(contentHash: h)
        default: guard let r = Self.hostCode(code, m) else { return nil }; self = r
        }
    }

    /// The code spellings the R2 sheet's `retryable` field is checked against: a dotted section 0.6 code, or one of the undotted codes of
    /// `framing.RETRY`.
    private static func isHostCode(_ code: String) -> Bool {
        let u = Array(code.utf8)
        guard (1...64).contains(u.count) else { return false }
        func lower(_ c: UInt8) -> Bool { c >= 0x61 && c <= 0x7A }
        func word(_ c: UInt8) -> Bool { lower(c) || (c >= 0x30 && c <= 0x39) || c == 0x5F }
        let parts = u.split(separator: 0x2E, omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && lower($0.first!) && $0.allSatisfy(word) }) else { return false }
        return parts.count >= 2 || PhoneRetryTable.knownCodes.contains(where: { $0.utf8.elementsEqual(u) })
    }

    /// `{"refusal": code, "retryable": bool, "seqs"?: [int], "next_key"?: Key}` and nothing else (host section 0.6 code, 11A.5).
    /// `retryable` must equal what the code's class derives (A and B true, C and D false); `internal` and `outcome.unknown_idem` depend on
    /// a context the answer does not carry, so either value is accepted for those two. `seqs` is a non-empty list of positive integers
    /// (the events that LANDED), `next_key` only for `ticket.key_not_next`.
    private static func hostCode(_ code: String, _ m: [String: JSONValue]) -> HostRefusal? {
        guard isHostCode(code), let retryable = m["retryable"]?.bool,
              Set(m.keys).isSubset(of: ["refusal", "retryable", "seqs", "next_key"]) else { return nil }
        let contextual = code.bytesEqual("internal") || code.bytesEqual("outcome.unknown_idem")
        if !contextual {
            let derived = PhoneRetryTable.classify(code, PhoneRefusalContext(eventID: "", hostNowMs: 0)).retryable
            guard retryable == derived else { return nil }
        }
        var seqs: [Int64]?
        if let s = m["seqs"] {
            guard let a = s.array, (1...1024).contains(a.count) else { return nil }
            var out: [Int64] = []
            for v in a { guard let n = v.int, n >= 1, n <= maxSafeInt else { return nil }; out.append(n) }
            seqs = out
        }
        var nextKey: String?
        if let k = m["next_key"] {
            guard code.bytesEqual("ticket.key_not_next"), let s = k.string, (1...64).contains(s.utf8.count), validTicketKeyShape(s) else { return nil }
            nextKey = s
        }
        return .host(code: code, retryable: retryable, seqs: seqs, nextKey: nextKey)
    }

    /// A ticket key as a display hint: `[A-Z][A-Z0-9]*-[0-9]+`. The `Key` type of host 0.1 says four or more digits, but the R2 vector
    /// (`ticket_key_not_next`) carries `DEMO-42`, and `next_key` is advisory (never a reservation, never bound), so the shape is checked
    /// loosely and only the length is capped.
    private static func validTicketKeyShape(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard let dash = u.firstIndex(of: 0x2D), dash >= 1, u.count - dash - 1 >= 1 else { return false }
        guard let f = u.first, f >= 0x41, f <= 0x5A else { return false }
        return u[..<dash].allSatisfy { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) } && u[(dash + 1)...].allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }
}
