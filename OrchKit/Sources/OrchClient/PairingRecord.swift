import Foundation
import OrchProtocol

/// The pending pairing the coordinator persists before it sends anything (host-api section 6): reviewed origin, workspace and
/// offer, the pairing secret, link pins, own key references (by device id: the keys live in custody), optional existing
/// certificate and owner, label, sequence and the serialized request, clock offset, start and progress times, the validated
/// `WSK` and `PK`, the pinned `sas_nonce`, the first valid challenge and the state. A rendered code is never stored: it is
/// recomputed from verified inputs. It lives in the encrypted keychain (`.keys`), not in the index, and is erased on every end.
struct PairingRecord: Equatable {
    enum Phase: String { case connecting, comparingHost = "comparing_host", waitingPrimary = "waiting_primary", comparingPrimary = "comparing_primary", joining }

    struct Inflight: Equatable {
        var rid: ID16
        var isPair: Bool
        var envelope: Data
        var posted: Bool
        var nextIdx: UInt64
        var offsetAdopted: Bool
        var createdMs: Int64
    }

    struct Approved: Equatable {
        var scopes: [String]
        var cert: JSONValue
        var epoch: UInt32
    }

    var generation: Int64
    var origin: String
    var ws: ID16
    var offer: ID16
    /// `S`. Erased (nil) the moment `approved` is pinned: the join does not need it.
    var secret: Data?
    var wskPin: Data
    var pkPin: Data
    var deviceID: ID16
    var label: String
    var createdKeys: Bool
    var existingCert: JSONValue?
    var phase: Phase = .connecting
    var startedMs: Int64
    var lastProgressMs: Int64
    var offsetMs: Int64 = 0
    var wskPub: Data?
    var sasNonce: Data?
    var pkPub: Data?
    var seq: UInt64 = 1
    var inflight: Inflight?
    var lastPostMs: Int64 = 0
    var primaryLabel: String?
    var certPendingSinceMs: Int64?
    var challenge: JSONValue?
    var approved: Approved?
    var joinStartedMs: Int64?
    /// When `approved` was first pinned: the start of the hard window for join retries.
    var approvedMs: Int64?

    var challengeExpiresMs: Int64? { challenge?.object?["o"]?.object?["expires_ms"]?.int }
    var challengeRequestID: ID16? { challenge?.object?["o"]?.object?.idField("request_id") }

    // MARK: encoding

    func encode() throws -> Data {
        var o: [String: JSONValue] = [
            "v": 1, "generation": .int(generation), "origin": .string(origin), "ws": .string(ws.hex), "offer": .string(offer.hex),
            "wsk_pin": .string(B64U.encode(wskPin)), "pk_pin": .string(B64U.encode(pkPin)),
            "device_id": .string(deviceID.hex), "label": .string(label), "created_keys": .bool(createdKeys),
            "phase": .string(phase.rawValue), "started_ms": .int(startedMs), "last_progress_ms": .int(lastProgressMs),
            "offset_ms": .int(offsetMs), "seq": .int(Int64(seq)), "last_post_ms": .int(lastPostMs)]
        func put(_ k: String, _ v: JSONValue?) { if let v { o[k] = v } }
        put("secret", secret.map { .string(B64U.encode($0)) })
        put("existing_cert", existingCert)
        put("wsk_pub", wskPub.map { .string(B64U.encode($0)) })
        put("sas_nonce", sasNonce.map { .string(B64U.encode($0)) })
        put("pk_pub", pkPub.map { .string(B64U.encode($0)) })
        put("primary_label", primaryLabel.map { .string($0) })
        put("cert_pending_since_ms", certPendingSinceMs.map { .int($0) })
        put("challenge", challenge)
        put("join_started_ms", joinStartedMs.map { .int($0) })
        put("approved_ms", approvedMs.map { .int($0) })
        if let f = inflight {
            o["inflight"] = .object(["rid": .string(f.rid.hex), "is_pair": .bool(f.isPair), "envelope": .string(B64U.encode(f.envelope)),
                                     "posted": .bool(f.posted), "next_idx": .int(Int64(f.nextIdx)), "offset_adopted": .bool(f.offsetAdopted),
                                     "created_ms": .int(f.createdMs)])
        }
        if let a = approved {
            o["approved"] = .object(["scopes": .array(a.scopes.map { .string($0) }), "cert": a.cert, "epoch": .int(Int64(a.epoch))])
        }
        return try canonicalJSON(.object(o))
    }

    static func decode(_ data: Data) -> PairingRecord? {
        guard let v = try? StrictJSON.parse(data, maxBytes: 1 << 20), let o = v.object, o["v"] == .int(1),
              let generation = o["generation"]?.int, let origin = o["origin"]?.string, let ws = o.idField("ws"), let offer = o.idField("offer"),
              let wskPin = o.b64uField("wsk_pin", length: 32), let pkPin = o.b64uField("pk_pin", length: 32),
              let device = o.idField("device_id"), let label = o["label"]?.string, let created = o["created_keys"]?.bool,
              let phaseText = o["phase"]?.string, let phase = Phase(rawValue: phaseText), let started = o["started_ms"]?.int,
              let progress = o["last_progress_ms"]?.int, let offset = o["offset_ms"]?.int, let seq = o["seq"]?.int, seq >= 1,
              let lastPost = o["last_post_ms"]?.int else { return nil }
        // `S` is present until the approval is pinned, and absent after (never both missing and unapproved)
        let secret = o.b64uField("secret", length: 32)
        guard secret != nil || o["approved"] != nil else { return nil }
        var r = PairingRecord(generation: generation, origin: origin, ws: ws, offer: offer, secret: secret, wskPin: wskPin, pkPin: pkPin,
                              deviceID: device, label: label, createdKeys: created, existingCert: o["existing_cert"], phase: phase,
                              startedMs: started, lastProgressMs: progress)
        r.offsetMs = offset; r.seq = UInt64(seq); r.lastPostMs = lastPost
        r.wskPub = o.b64uField("wsk_pub"); r.sasNonce = o.b64uField("sas_nonce"); r.pkPub = o.b64uField("pk_pub")
        r.primaryLabel = o["primary_label"]?.string; r.certPendingSinceMs = o["cert_pending_since_ms"]?.int
        r.challenge = o["challenge"]; r.joinStartedMs = o["join_started_ms"]?.int; r.approvedMs = o["approved_ms"]?.int
        if let f = o["inflight"]?.object {
            guard let rid = f.idField("rid"), let isPair = f["is_pair"]?.bool, let env = f.b64uField("envelope"), let posted = f["posted"]?.bool,
                  let next = f["next_idx"]?.int, next >= 0, let adopted = f["offset_adopted"]?.bool, let created = f["created_ms"]?.int else { return nil }
            r.inflight = Inflight(rid: rid, isPair: isPair, envelope: env, posted: posted, nextIdx: UInt64(next), offsetAdopted: adopted, createdMs: created)
        }
        if let a = o["approved"]?.object {
            guard let sv = a["scopes"]?.array, case let scopes = sv.compactMap(\.string), scopes.count == sv.count, let cert = a["cert"],
                  let epoch = a.u32Field("epoch") else { return nil }
            r.approved = Approved(scopes: scopes, cert: cert, epoch: epoch)
        }
        return r
    }
}
