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
            guard rest == ["status"], let s = m["status"]?.string else { return nil }; self = .alreadyDone(status: s)
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
        default: return nil
        }
    }
}
