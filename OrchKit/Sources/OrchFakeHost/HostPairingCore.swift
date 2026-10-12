import CryptoKit
import Foundation
import OrchClient
import OrchProtocol

/// One pairing offer (section 8.3 step 1): created by the host with `S`, a host-chosen `sas_nonce`, a 10-minute life and its scopes.
/// Single use; used records are kept 24 hours.
package struct HostOffer: Equatable, Sendable {
    package var secret: Data
    package var expiresMs: Int64
    package var sasNonce: Data
    package var used: Bool
    /// Times of refusals sent for this offer (budget: 5 per minute).
    package var unverified: [Int64]
    package var scopes: [String]
    package init(secret: Data, expiresMs: Int64, sasNonce: Data, used: Bool = false, unverified: [Int64] = [], scopes: [String] = ["look", "decide"]) {
        self.secret = secret; self.expiresMs = expiresMs; self.sasNonce = sasNonce; self.used = used; self.unverified = unverified; self.scopes = scopes
    }
}

/// The pairing the host holds for a device that consumed an offer.
package struct HostPendingPair: Equatable, Sendable {
    package var offer: ID16
    package var dkSig: SigningPublicKey
    package var dkKx: AgreementPublicKey
    package var label: String
    /// The device's pairing-attempt nonce (G3b): copied into the cert request; a resend must carry the same one.
    package var attempt: String
    package var sasNonce: Data
    /// The certificate the phone presented, then (once approved) the one the phone gets.
    package var cert: JSONValue?
    package var certState: String
    /// pending, cert_pending, approved, rejected, expired
    package var state: String
    package var certPendingSince: Int64?
    package var primaryLabel: String?
    package var challenge: JSONValue?
    package var scopes: [String]?
    package var requestID: ID16?
    /// The primary's PK-signed `cert_rejection`, verified by the host and relayed unchanged in the `rejected` answer.
    package var rejection: JSONValue?
    /// What the offer allowed (the most a certificate for this device may carry); `scopes` is what the host's human approved within it.
    package var scopesMax: [String]?
    /// The join anchor sent with `approved` (G3b): the relay-accepted head list's `list_seq`, the current card's `card_seq`, and
    /// the baseline (`null` while the workspace has no ticket-log checkpoint).
    package var listSeq: Int64?
    package var cardSeq: Int64?
    package var baseline: JSONValue = .null
    /// Bumped by every transition (and by every reservation of one): an await in the host's approval path may continue only if the
    /// version it reserved is still the pairing's, so a concurrent rejection or expiry is never overwritten.
    package var version = 0
    package init(offer: ID16, dkSig: SigningPublicKey, dkKx: AgreementPublicKey, label: String, attempt: String, sasNonce: Data, cert: JSONValue?, certState: String,
                 state: String = "pending", certPendingSince: Int64? = nil, primaryLabel: String? = nil, challenge: JSONValue? = nil,
                 scopes: [String]? = nil, requestID: ID16? = nil) {
        self.offer = offer; self.dkSig = dkSig; self.dkKx = dkKx; self.label = label; self.attempt = attempt; self.sasNonce = sasNonce; self.cert = cert
        self.certState = certState; self.state = state; self.certPendingSince = certPendingSince; self.primaryLabel = primaryLabel
        self.challenge = challenge; self.scopes = scopes; self.requestID = requestID
    }
}

package enum HostPairReply: Equatable, Sendable {
    /// A first (or re-sent) `pair`: the cleaned label, whether a certificate is needed, the pairing code the host shows, and the answer.
    case pending(label: String, certState: String, sas: String, answer: JSONValue)
    case status(answer: JSONValue)
    /// A sealed refusal; `meta` carries `wsk_pub` (and `host_ms` for a stale timestamp).
    case refuse(code: String, meta: JSONValue)
}

extension HostBridgeCore {
    static let certPendingLifeMs: Int64 = CertRequest.lifetimeMs
    static let pairRefusalBudget = 5

    /// Section 8.3 step 3, after §8.6 steps 1 to 3: the offer named by `stream`, otherwise silence; the tag under `K_pair`, otherwise
    /// silence; then, in order, the meta shape, an open and unused offer (or a resend by the holder), the device id and signature, the
    /// time window and the certificate. Every refusal counts against the offer's own budget and carries `wsk_pub`.
    package mutating func checkPairing(_ parts: Bridge.Parts, _ now: Int64) -> HostCheck {
        let h = parts.header
        guard let offer = offers[h.stream], let wsk = wskPub, let owner = ownerPK else { return .drop("no_key") }
        guard let ck = Bridge.channelKey(header: h, pairSecret: SymmetricKey(data: offer.secret)), let plain = try? Bridge.openBody(parts, channelKey: ck)
        else { return .drop("tag") }

        func refuse(_ code: String, hostMs: Int64? = nil) -> HostCheck {
            var o = offers[h.stream] ?? offer
            let recent = o.unverified.filter { now - $0 < limits.budgetWindowMs }
            guard recent.count < Self.pairRefusalBudget else { o.unverified = recent; offers[h.stream] = o; return .drop("budget") }
            o.unverified = recent + [now]
            offers[h.stream] = o
            var meta: [String: JSONValue] = ["refusal": .string(code), "wsk_pub": .string(B64U.encode(wsk.x963))]
            if let ms = hostMs { meta["host_ms"] = .int(ms) }
            return .pair(.refuse(code: code, meta: .object(meta)), h)
        }
        func inWindow() -> Bool {
            let diff = now.subtractingReportingOverflow(h.tsMs > UInt64(Int64.max) ? Int64.max : Int64(h.tsMs))
            return !diff.overflow && abs(diff.partialValue) <= limits.windowMs
        }
        // 1. the meta shape
        guard let (metaValue, _) = try? Bridge.unframe(plain), let m = metaValue.object, let op = m["op"]?.string else { return refuse("malformed") }
        if op.utf8Equal("pair_status") {
            guard m.exactly(["op"]) else { return refuse("malformed") }
            guard var p = pendingPairs[h.device], p.offer == h.stream else { return refuse("pairing_closed") }
            guard Bridge.verifySignature(parts, key: p.dkSig) else { return refuse("bad_signature") }
            guard inWindow() else { return refuse("stale_timestamp", hostMs: now) }
            if p.state == "cert_pending", let since = p.certPendingSince, now >= since + Self.certPendingLifeMs { p.state = "expired"; p.version += 1; pendingPairs[h.device] = p }
            return .pair(.status(answer: answer(p, wsk: wsk, owner: owner)), h)
        }
        guard op.utf8Equal("pair"), m.exactly(["op", "dk_sig_pub", "dk_kx_pub", "label", "cert", "attempt"]), let sig = m.sigKeyField("dk_sig_pub"),
              let kx = m.kxKeyField("dk_kx_pub"), let label = m["label"]?.string, let cert = m["cert"], cert.isNull || cert.object != nil,
              let attempt = m["attempt"]?.string, Identifiers.isAttempt(attempt)
        else { return refuse("malformed") }
        // 2. the offer is open and unused; a resend by the holder with the same two keys AND the same attempt is answered `pending`
        let existing = pendingPairs[h.device]
        let resend = existing.map { $0.offer == h.stream && $0.dkSig == sig && $0.dkKx == kx && $0.attempt.utf8.elementsEqual(attempt.utf8) } ?? false
        if !resend { guard !offer.used, now < offer.expiresMs else { return refuse("pairing_closed") } }
        // 3. the device id is the key's, and the proof of possession
        guard Identifiers.deviceID(sig) == h.device, Bridge.verifySignature(parts, key: sig) else { return refuse("bad_signature") }
        // 4. the time window
        guard inWindow() else { return refuse("stale_timestamp", hostMs: now) }
        if resend, let p = existing {
            let code = (try? Identifiers.pairingCode(workspace: workspace, offer: h.stream, dkSig: sig, dkKx: kx, wsk: wsk, sasNonce: p.sasNonce)) ?? ""
            return .pair(.pending(label: p.label, certState: p.certState, sas: code, answer: pendingAnswer(p, wsk: wsk)), h)
        }
        // 5. a presented certificate
        if !cert.isNull {
            guard let person = cert.object?["o"]?.object?["person_id"]?.string else { return refuse("cert_invalid") }
            guard person.utf8Equal(Identifiers.personID(owner).hex) else { return refuse("other_person") }
            do {
                let dc = try DeviceCertificate.verify(cert, personKey: owner, nowMs: now, revoked: revoked)
                guard dc.signingKey == sig, dc.agreementKey == kx, !dc.isScopedAgent else { return refuse("cert_invalid") }
            } catch let r as Refusal {
                switch r {
                case .certExpired: return refuse("cert_expired")
                case .revoked: return refuse("revoked")
                default: return refuse("cert_invalid")
                }
            } catch { return refuse("cert_invalid") }
        }
        // accepted: the offer is used, the label cleaned, the pairing recorded
        let presented: JSONValue? = cert.isNull ? Optional<JSONValue>.none : Optional<JSONValue>.some(cert)
        var used = offer; used.used = true; offers[h.stream] = used
        var p = HostPendingPair(offer: h.stream, dkSig: sig, dkKx: kx, label: PersonText.clean(label), attempt: attempt, sasNonce: offer.sasNonce,
                                cert: presented, certState: presented == nil ? "needed" : "present", scopes: offer.scopes)
        p.scopesMax = offer.scopes
        pendingPairs[h.device] = p
        let code = (try? Identifiers.pairingCode(workspace: workspace, offer: h.stream, dkSig: sig, dkKx: kx, wsk: wsk, sasNonce: p.sasNonce)) ?? ""
        return .pair(.pending(label: p.label, certState: p.certState, sas: code, answer: pendingAnswer(p, wsk: wsk)), h)
    }

    func pendingAnswer(_ p: HostPendingPair, wsk: SigningPublicKey) -> JSONValue {
        ["state": "pending", "wsk_pub": .string(B64U.encode(wsk.x963)), "sas_nonce": .string(B64U.encode(p.sasNonce)),
         "dk_sig_pub": .string(B64U.encode(p.dkSig.x963)), "dk_kx_pub": .string(B64U.encode(p.dkKx.x963))]
    }

    /// The five answers of section 8.3, exactly.
    func answer(_ p: HostPendingPair, wsk: SigningPublicKey, owner: SigningPublicKey) -> JSONValue {
        let w: JSONValue = .string(B64U.encode(wsk.x963))
        switch p.state {
        case "cert_pending":
            return ["state": "cert_pending", "primary_label": .string(p.primaryLabel ?? ""), "pk_pub": .string(B64U.encode(owner.x963)),
                    "challenge": p.challenge ?? .null, "wsk_pub": w]
        case "approved":
            return ["state": "approved", "scopes": .array((p.scopes ?? []).map { .string($0) }), "cert": p.cert ?? .null,
                    "pk_pub": .string(B64U.encode(owner.x963)), "epoch": .int(Int64(approvedEpochOverride ?? epoch)),
                    "list_seq": .int(p.listSeq ?? 1), "card_seq": .int(p.cardSeq ?? 1), "baseline": p.baseline, "wsk_pub": w]
        case "rejected":
            // a rejection by the primary carries its PK-signed proof (and pk_pub for the phone's pin check); the host's own has none
            guard let rej = p.rejection else { return ["state": "rejected", "wsk_pub": w] }
            return ["state": "rejected", "wsk_pub": w, "pk_pub": .string(B64U.encode(owner.x963)), "rejection": rej]
        case "expired": return ["state": "expired", "wsk_pub": w]
        default: return pendingAnswer(p, wsk: wsk)
        }
    }
}
