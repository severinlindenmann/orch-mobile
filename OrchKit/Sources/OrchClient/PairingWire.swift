import CryptoKit
import Foundation
import OrchProtocol

/// Why a pairing is stopped with a full-screen alarm (host-api section 6). Alarms are terminal and survive a restart.
public enum PairingAlarmKind: String, Sendable, Equatable, CaseIterable {
    /// The host's `pending` answer echoed keys that are not the phone's own: someone is pairing another key with this link.
    case echoWrongKey = "echo_wrong_key"
    /// The primary's challenge names keys that are not the phone's own (R1): the host asked for a certificate for another key.
    case r1Challenge = "r1_challenge"
    /// A pinned value (`sas_nonce`, `pk_pub`, the first valid challenge) changed.
    case pinSubstitution = "pin_substitution"
    /// An answer moved the state backwards (pending after cert_pending, a missing challenge after a shown one, ...).
    case regression = "regression"
}

/// The phone's side of the epoch-0 pairing wire (protocol section 8.3): the two requests it signs and the check of every answer.
/// Pure: no transport, no clock, no storage.
package enum PairingWire {
    package static let maxAnswer = 64 * 1024
    package static let knownRefusals: Set<String> = ["pairing_closed", "cert_invalid", "cert_expired", "other_person", "revoked",
                                                     "bad_signature", "malformed", "stale_timestamp"]

    package struct Context: Sendable {
        package var workspace: ID16, device: ID16, offer: ID16
        package var secret: SymmetricKey
        package var wskPin: Data, pkPin: Data
        package var dkSig: SigningPublicKey
        package var dkKx: AgreementPublicKey
        package var offsetMs: Int64
        package init(workspace: ID16, device: ID16, offer: ID16, secret: SymmetricKey, wskPin: Data, pkPin: Data, dkSig: SigningPublicKey,
                     dkKx: AgreementPublicKey, offsetMs: Int64 = 0) {
            self.workspace = workspace; self.device = device; self.offer = offer; self.secret = secret; self.wskPin = wskPin
            self.pkPin = pkPin; self.dkSig = dkSig; self.dkKx = dkKx; self.offsetMs = offsetMs
        }
    }

    // MARK: requests

    package enum Op: Sendable {
        case pair(label: String, cert: JSONValue?)
        case status
    }

    /// An epoch-0 request: sealed under `K_pair`, `stream` = the offer, signed by the new `dk_sig` (proof of possession).
    package static func request(_ op: Op, context c: Context, signer: some Signer, rid: ID16, seq: UInt64, tsMs: Int64, salt: Data) throws -> Data {
        let meta: JSONValue
        switch op {
        case .pair(let label, let cert):
            meta = ["op": "pair", "dk_sig_pub": .string(B64U.encode(c.dkSig.x963)), "dk_kx_pub": .string(B64U.encode(c.dkKx.x963)),
                    "label": .string(label), "cert": cert ?? .null]
        case .status: meta = ["op": "pair_status"]
        }
        let h = Bridge.Header(direction: .toHost, workspace: c.workspace, device: c.device, rid: rid, stream: c.offer, seq: seq,
                              tsMs: UInt64(max(tsMs, 0)), epoch: 0, salt: salt)
        guard let key = Bridge.channelKey(header: h, pairSecret: c.secret) else { throw CryptoFailure.invalidKey }
        return try Bridge.seal(header: h, channelKey: key, signer: signer, plaintext: Bridge.frame(meta: meta))
    }

    // MARK: answers

    package struct Challenge: Equatable, Sendable {
        package let signed: JSONValue
        package let object: [String: JSONValue]
        package let requestID: ID16
        package let primaryNonce: Data
        package let expiresMs: Int64
        package let certCode: String
    }

    package enum Body: Equatable, Sendable {
        case pending(sasNonce: Data, sas: String)
        case certPending(primaryLabel: String, pkPub: SigningPublicKey, challenge: Challenge?)
        case approved(scopes: [String], cert: JSONValue, certificate: DeviceCertificate, pkPub: SigningPublicKey, epoch: UInt32)
        case rejected
        case expired
        case refusal(code: String, hostMs: Int64?)
    }

    package struct Accepted: Equatable, Sendable {
        package let wskPub: SigningPublicKey
        package let body: Body
        /// Adopted from a verified `stale_timestamp` refusal, once per pending rid, within +-24 h.
        package let offsetMs: Int64?
        package let clockWrong: Bool
    }

    package enum Outcome: Equatable, Sendable {
        case accept(Accepted)
        /// Silence. `why` is the vectors' spelling; `alarm` is set where the protocol raises the alarm.
        case drop(why: String, alarm: PairingAlarmKind?, primaryLabel: String?)
    }

    /// Section 8.3 step 4, in order: shape, a pending rid, the tag under `K_pair`, `wsk_pin(wsk_pub)` against the link, the host
    /// signature, the chunk order, the window (refusals included; a verified `stale_timestamp` is exempt once per rid). Then the
    /// answer's own checks. `pending[rid]` is the request this answer is for. The table is updated only on accept.
    package static func check(_ envelope: Data, context c: Context, pending: [ID16: Bridge.PendingRequest], mailbox: Bridge.MailboxPosition,
                              nowMs: Int64) -> (outcome: Outcome, pending: [ID16: Bridge.PendingRequest]) {
        func drop(_ why: String, alarm: PairingAlarmKind? = nil, label: String? = nil) -> (Outcome, [ID16: Bridge.PendingRequest]) {
            (.drop(why: why, alarm: alarm, primaryLabel: label), pending)
        }
        // 1. shape
        guard envelope.count >= Bridge.overhead, envelope.count <= maxAnswer, let parts = try? Bridge.Parts(envelope: envelope) else { return drop("size") }
        let h = parts.header
        let known = Bridge.Flags.last.rawValue | Bridge.Flags.refusal.rawValue
        guard h.magic == Bridge.magic, h.version == Bridge.version, h.direction == Bridge.Direction.toDevice.rawValue, h.flags & ~known == 0
        else { return drop("version_direction_or_flags") }
        guard h.flagSet.contains(.last), !h.flagSet.contains(.refusal) || h.flagSet.contains(.last) else { return drop("flags") }
        guard h.suite == Suite2.id, h.workspace == c.workspace, h.device == c.device else { return drop("not_for_this_device") }
        guard h.epoch == 0, h.stream == c.offer else { return drop("shape") }
        // 2. a pending rid
        guard var pend = pending[h.rid] else { return drop("unknown_request") }
        guard pend.epoch == 0, mailbox.id == h.rid, mailbox.index == h.seq, mailbox.last == h.flagSet.contains(.last), !mailbox.stream
        else { return drop("mailbox_mismatch") }
        // 3. the tag
        guard let key = Bridge.channelKey(header: h, pairSecret: c.secret), let plain = try? Bridge.openBody(parts, channelKey: key),
              let (metaValue, data) = try? Bridge.unframe(plain), let meta = metaValue.object, data.isEmpty else { return drop("tag_or_meta") }
        // 4. the pin, 5. the signature
        guard let wsk = meta.sigKeyField("wsk_pub") else { return drop("tag_or_meta") }
        guard Identifiers.wskPin(wsk) == c.wskPin else { return drop("wsk_pin") }
        guard Bridge.verifySignature(parts, key: wsk) else { return drop("host_signature") }
        // 6. the chunk order
        guard h.seq == pend.next else { return drop("out_of_order") }
        // 7. the window
        let local = saturatingAdd(nowMs, c.offsetMs)
        let isRefusal = h.flagSet.contains(.refusal)
        var offset: Int64?, clockWrong = false
        if isRefusal, !pend.offsetAdopted, meta["refusal"]?.string?.utf8Equal("stale_timestamp") == true, let hostMs = meta["host_ms"]?.int {
            pend.offsetAdopted = true
            let off = hostMs.subtractingReportingOverflow(nowMs)
            if !off.overflow, abs(off.partialValue) <= Bridge.maxOffsetMs { offset = off.partialValue } else { clockWrong = true }
        } else {
            let ts = h.tsMs > UInt64(Int64.max) ? Int64.max : Int64(h.tsMs)
            let diff = local.subtractingReportingOverflow(ts)
            if diff.overflow || abs(diff.partialValue) > Bridge.windowMs { return drop("stale_timestamp") }
        }
        // the answer itself
        let body: Body
        switch interpret(meta, refusal: isRefusal, context: c, localMs: local) {
        case .success(let b): body = b
        case .failure(let d): return drop(d.why, alarm: d.alarm, label: d.label)
        }
        pend.next += 1
        var table = pending
        table[h.rid] = pend
        return (.accept(Accepted(wskPub: wsk, body: body, offsetMs: offset, clockWrong: clockWrong)), table)
    }

    private struct Dropped: Error { let why: String; var alarm: PairingAlarmKind? = nil; var label: String? = nil }

    private static func interpret(_ m: [String: JSONValue], refusal: Bool, context c: Context, localMs: Int64) -> Result<Body, Dropped> {
        if refusal {
            guard let code = m["refusal"]?.string, knownRefusals.contains(where: { $0.utf8Equal(code) }) else { return .failure(Dropped(why: "refusal_code")) }
            if code.utf8Equal("stale_timestamp") {
                guard let ms = m["host_ms"]?.int else { return .failure(Dropped(why: "shape")) }
                return .success(.refusal(code: code, hostMs: ms))
            }
            return .success(.refusal(code: code, hostMs: nil))
        }
        guard let state = m["state"]?.string else { return .failure(Dropped(why: "shape")) }
        switch state {
        case "pending":
            guard let nonce = m.b64uField("sas_nonce", length: 32), let sig = m.sigKeyField("dk_sig_pub"), let kx = m.kxKeyField("dk_kx_pub")
            else { return .failure(Dropped(why: "shape")) }
            guard sig == c.dkSig, kx == c.dkKx else { return .failure(Dropped(why: "not_my_key", alarm: .echoWrongKey)) }
            guard let wsk = m.sigKeyField("wsk_pub"),
                  let sas = try? Identifiers.pairingCode(workspace: c.workspace, offer: c.offer, dkSig: c.dkSig, dkKx: c.dkKx, wsk: wsk, sasNonce: nonce)
            else { return .failure(Dropped(why: "shape")) }
            return .success(.pending(sasNonce: nonce, sas: sas))
        case "cert_pending":
            guard let label = m["primary_label"]?.string, label.unicodeScalars.count <= PersonText.maxCodePoints, let pk = m.sigKeyField("pk_pub"), let ch = m["challenge"]
            else { return .failure(Dropped(why: "shape")) }
            guard Identifiers.pkPin(pk) == c.pkPin else { return .failure(Dropped(why: "pk_pin")) }
            if ch.isNull { return .success(.certPending(primaryLabel: label, pkPub: pk, challenge: nil)) }
            do {
                let (o, code) = try CertChallenge.check(ch, pk: pk, workspace: c.workspace, device: c.device, dkSig: c.dkSig, dkKx: c.dkKx, nowMs: localMs)
                guard let req = o.idField("request_id"), let nonce = o.b64uField("primary_nonce", length: 32), let exp = o["expires_ms"]?.int
                else { return .failure(Dropped(why: "challenge_signature")) }
                return .success(.certPending(primaryLabel: label, pkPub: pk,
                                             challenge: Challenge(signed: ch, object: o, requestID: req, primaryNonce: nonce, expiresMs: exp, certCode: code)))
            } catch let d as CertChallengeDrop {
                return .failure(Dropped(why: d.rawValue, alarm: d.raisesAlarm ? .r1Challenge : nil, label: label))
            } catch { return .failure(Dropped(why: "challenge_signature")) }
        case "approved":
            guard let sv = m["scopes"]?.array, case let scopes = sv.compactMap(\.string), scopes.count == sv.count, Scopes.isValid(scopes),
                  !scopes[0].utf8.starts(with: "drop:".utf8), let cert = m["cert"], let pk = m.sigKeyField("pk_pub"), let epoch = m.u32Field("epoch")
            else { return .failure(Dropped(why: "shape")) }
            guard Identifiers.pkPin(pk) == c.pkPin else { return .failure(Dropped(why: "pk_pin")) }
            guard let dc = try? DeviceCertificate.verify(cert, personKey: pk, nowMs: localMs), dc.signingKey == c.dkSig, dc.agreementKey == c.dkKx,
                  dc.deviceID == c.device, !dc.isScopedAgent else { return .failure(Dropped(why: "cert")) }
            guard scopes.count <= dc.scopesMax.count else { return .failure(Dropped(why: "scopes")) }
            return .success(.approved(scopes: scopes, cert: cert, certificate: dc, pkPub: pk, epoch: epoch))
        case "rejected": return .success(.rejected)
        case "expired": return .success(.expired)
        default: return .failure(Dropped(why: "shape"))
        }
    }
}
