import CryptoKit
import Foundation
import OrchClient
import OrchProtocol

/// A pairing offer as the host's Remote tab shows it. The link carries `S`, so it is redacted from every textual rendering.
public struct PairingOffer: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let offerID: ID16
    /// `https://<relay>/app/pair#v2.<ws>.<offer>.<S>.<wsk_pin>.<pk_pin>` (the QR payload).
    public let link: String
    public let expiresMs: Int64
    public let scopes: [String]
    public var description: String { "PairingOffer(offer: \(offerID.hex), expiresMs: \(expiresMs), <link redacted>)" }
    public var debugDescription: String { description }
}

/// The host's pairing panel row (host-api section 5: the labelled Demo host panel; default action Reject).
public struct PendingPairing: Sendable, Equatable {
    public let device: ID16
    public let offerID: ID16
    public let label: String
    /// The pairing code the human compares with the phone's screen.
    public let sas: String
    public let certState: String
    public let state: String
    public let scopes: [String]
}

public enum PairingApprovalError: Error, Equatable, Sendable {
    /// Approve is available only after "I compared the codes".
    case comparisonNotConfirmed
    case unknownPairing
    case notPending
    /// Scopes outside the four-level prefix list, or a drop scope.
    case invalidScopes
    /// `hostIsPrimary` on a client-hosted workspace: such a host never receives `PK`.
    case hostCannotBePrimary
}

extension FakeHost {
    public static let offerLifetimeMs: Int64 = 600_000
    static let usedOfferRetentionMs: Int64 = 24 * 3600 * 1000

    // MARK: scenario knobs (the fakes' behaviours; never a human decision)

    public func setHostIsPrimary(_ v: Bool) throws {
        guard !v || !isClientHosted else { throw PairingApprovalError.hostCannotBePrimary }
        hostIsPrimary = v
    }
    public func setR1Attack(_ v: Bool) { r1Attack = v }
    public func setAsksPrimaryAlways(_ v: Bool) { asksPrimaryAlways = v }
    public func setEchoWrongKey(_ k: EchoedKey?) { echoWrongKey = k }
    /// Adversarial knob (tests only): a compromised host ends a pairing claiming the primary said no, relaying `rejection` as it is,
    /// without the verification `progressCertPending` does. The phone must believe it only if it verifies under the pinned `PK`.
    package func forceRelayedRejection(device: ID16, rejection: JSONValue) {
        core.pendingPairs[device]?.rejection = rejection
        transition(device, to: "rejected")
    }
    package func pairingRequestID(of device: ID16) -> ID16? { core.pendingPairs[device]?.requestID }
    /// Tests: the attempt binding of a device's pairing (offer, attempt nonce, dk_hash of its keys).
    package func pairingBinding(of device: ID16) -> (offer: ID16, attempt: String, dkHash: Data)? {
        core.pendingPairs[device].map { ($0.offer, $0.attempt, Identifiers.dkHash(sig: $0.dkSig, kx: $0.dkKx)) }
    }

    // MARK: offers

    /// A single-use, 10-minute offer: `S` and the host's `sas_nonce` are drawn now; the nonce is revealed only to the device that
    /// consumes the offer.
    public func createOffer(scopes: [String] = ["look", "decide"]) throws -> PairingOffer {
        try capability.generation.check()
        guard Scopes.isValid(scopes), !scopes[0].utf8.starts(with: "drop:".utf8) else { throw PairingApprovalError.invalidScopes }
        let now = wall.nowMs
        core.offers = core.offers.filter { $0.value.expiresMs + Self.usedOfferRetentionMs > now }
        let id = entropy.id16()
        let secret = entropy.bytes(32), nonce = entropy.bytes(32)
        core.offers[id] = HostOffer(secret: secret, expiresMs: now + Self.offerLifetimeMs, sasNonce: nonce, scopes: scopes)
        let owner = primary.publicKey
        let frag = ["v2", workspace.hex, id.hex, B64U.encode(secret), B64U.encode(Identifiers.wskPin(wskPublic)), B64U.encode(Identifiers.pkPin(owner))]
            .joined(separator: ".")
        return PairingOffer(offerID: id, link: origin + "/app/pair#" + frag, expiresMs: now + Self.offerLifetimeMs, scopes: scopes)
    }

    // MARK: panel

    public func pendingPairings() -> [PendingPairing] {
        guard let wsk = core.wskPub else { return [] }
        return core.pendingPairs.map { dev, p in
            PendingPairing(device: dev, offerID: p.offer, label: p.label,
                           sas: (try? Identifiers.pairingCode(workspace: workspace, offer: p.offer, dkSig: p.dkSig, dkKx: p.dkKx, wsk: wsk, sasNonce: p.sasNonce)) ?? "",
                           certState: p.certState, state: p.state, scopes: p.scopes ?? [])
        }.sorted { $0.device.hex < $1.device.hex }
    }

    public func pairingState(of device: ID16) -> String? { core.pendingPairs[device]?.state }
    public func lastPairingFailure() -> String? { lastPairingError }

    /// The explicit host approval. Never automatic: the caller states that the codes were compared. With a certificate already
    /// presented (or when the host is the primary) the host goes straight to approval (step 6); otherwise it asks the primary
    /// (`cert_pending`, section 8.4). No grant and no card key is created here for a device without a certificate.
    ///
    /// The transition is reserved (the pairing's version is bumped) before the first suspension; every later step revalidates that
    /// version before it writes or publishes, so a rejection that lands meanwhile wins and nothing is overwritten.
    public func approvePairing(device: ID16, scopes: [String]? = nil, confirmedComparison: Bool, relay: FakeRelay,
                               transport: any RelayTransport) async throws {
        try capability.generation.check()
        guard confirmedComparison else { throw PairingApprovalError.comparisonNotConfirmed }
        guard var p = core.pendingPairs[device] else { throw PairingApprovalError.unknownPairing }
        guard p.state == "pending" else { throw PairingApprovalError.notPending }
        let want = scopes ?? p.scopes ?? ["look", "decide"]
        guard Scopes.isValid(want), !want[0].utf8.starts(with: "drop:".utf8) else { throw PairingApprovalError.invalidScopes }
        p.scopes = want
        p.version += 1
        let v = p.version
        core.pendingPairs[device] = p
        let keys = DemoKeys(sig: p.dkSig, kx: p.dkKx)
        // R1 (adversarial scenario): the compromised host ignores a certificate the phone presented and asks the primary for one of its
        // own instead, so the attack also reaches an iPhone that is already one of the owner's devices (D-1). The Demo's
        // `asksPrimaryAlways` does the same honestly (for the phone's own keys) to show the primary's phase.
        if p.cert != nil, !bypassesPresentedCertificate {
            try await completeJoin(device: device, relay: relay, transport: transport, reserved: v)
        } else if hostIsPrimary {
            guard !isClientHosted else { throw PairingApprovalError.hostCannotBePrimary }
            let cert = try await primary.certifyAsHost(keys, label: p.label, scopesMax: p.scopesMax ?? want)
            try still(device, v)
            core.pendingPairs[device]?.cert = cert
            try await completeJoin(device: device, relay: relay, transport: transport, reserved: v)
        } else {
            try await requestCertificate(device: device, pair: p, relay: relay, transport: transport, reserved: v)
        }
    }

    public func rejectPairing(device: ID16) throws {
        try capability.generation.check()
        guard core.pendingPairs[device] != nil else { throw PairingApprovalError.unknownPairing }
        guard let st = core.pendingPairs[device]?.state, st == "pending" || st == "cert_pending" else { throw PairingApprovalError.notPending }
        transition(device, to: "rejected")
    }

    /// Every state change of a pairing bumps its version, which invalidates any approval step that reserved an earlier one.
    private func transition(_ device: ID16, to state: String) {
        guard var p = core.pendingPairs[device] else { return }
        p.state = state; p.version += 1
        core.pendingPairs[device] = p
    }

    private func still(_ device: ID16, _ version: Int) throws {
        guard core.pendingPairs[device]?.version == version else { throw PairingApprovalError.notPending }
    }

    private func stage(_ name: String) async { if let h = approvalHook { await h(name) } }

    // MARK: cert_pending (section 8.4 step 1)

    private func requestCertificate(device: ID16, pair p: HostPendingPair, relay: FakeRelay, transport: any RelayTransport, reserved v: Int) async throws {
        let now = wall.nowMs
        let requestID = entropy.id16()
        // R1 (adversarial scenario): the compromised host asks for a certificate for a key of its own.
        let attacker = DemoKeys(sig: SoftwareSigner().publicKey, kx: SoftwareKeyAgreer().publicKey)
        let k = r1Attack ? attacker : DemoKeys(sig: p.dkSig, kx: p.dkKx)
        let inner = CertRequestInner(deviceID: k.deviceID, dkSig: k.sig, dkKx: k.kx, label: p.label, scopesMax: p.scopesMax ?? p.scopes ?? ["look", "decide"], offerID: p.offer,
                                     attempt: p.attempt)
        let req = try CertRequest.make(wsk: wsk, requestID: requestID, workspace: workspace, person: primary.personID, primary: primary.deviceID,
                                       primaryKey: primary.deviceKeys.kx, inner: inner, createdMs: now)
        let session = try await currentSession(transport: transport)
        await stage("cert_request.post")
        try still(device, v)
        let gen = try await holderGeneration(relay: relay, session: session)
        try still(device, v)
        // `POST /v2/persons/{person}/cert-requests` with the workspace session under this host's holder generation (W(g)); 200 also
        // for an identical resend
        let post = try WireRequest(method: "POST", target: "\(HostAPI.base)/persons/\(primary.personID.hex)/cert-requests",
                                   headers: ["authorization": "Bearer " + session.token, "orch-holder": String(gen), "content-type": "application/json"],
                                   body: canonicalJSON(.object(["request": req.json])), clientAddress: "host")
        _ = try HostAPI.expect(try await relay.send(post))
        // a rejection that landed during the post wins; the posted request is not retracted (the primary may still challenge it, but the
        // host never completes a join for a pairing that is not pending)
        try still(device, v)
        core.pendingPairs[device]?.state = "cert_pending"
        core.pendingPairs[device]?.certPendingSince = now
        core.pendingPairs[device]?.primaryLabel = primary.label
        core.pendingPairs[device]?.requestID = requestID
    }

    // MARK: approval (section 8.3 step 6)

    /// Uploads the certificate (if new), then publishes the new member list with every member's grant for the current epoch and the
    /// device's card-key wrap in one atomic membership publication (P3-D7). Runs only for a device whose certificate is valid for
    /// exactly its two keys; the relay checks the same again. Reserves a transition first (unless the caller did) and revalidates it
    /// before every publication and before the final write.
    func completeJoin(device: ID16, relay: FakeRelay, transport: any RelayTransport, reserved: Int? = nil) async throws {
        guard var p = core.pendingPairs[device], let cert = p.cert, let want = p.scopes else { throw PairingApprovalError.unknownPairing }
        let v: Int
        if let reserved { v = reserved; try still(device, v) } else {
            guard p.state == "pending" || p.state == "cert_pending" else { throw PairingApprovalError.notPending }
            p.version += 1; v = p.version
            core.pendingPairs[device] = p
        }
        let now = wall.nowMs
        let dc: DeviceCertificate
        do { dc = try DeviceCertificate.verify(cert, personKey: primary.publicKey, nowMs: now, revoked: core.revoked) }
        catch { lastPairingError = "cert"; throw error }
        guard dc.signingKey == p.dkSig, dc.agreementKey == p.dkKx else { lastPairingError = "cert_keys"; throw Refusal.certInvalid }
        let scopes = Array(want.prefix(dc.scopesMax.count))
        let keys = DemoKeys(sig: p.dkSig, kx: p.dkKx)
        let session = try await currentSession(transport: transport)
        await stage("complete.cert"); try still(device, v)
        try await relay.publishCertificate(cert)
        let adding: (DemoKeys, [String])? = hostile.omitFromList ? nil : (keys, hostile.listScopes ?? scopes)
        let wraps = hostile.omitFromList ? [] : [keys]           // a wrap may name only a listed member
        await stage("complete.list"); try still(device, v)
        if let hold = listHoldUntilMs, wall.nowMs < hold {
            heldList = (adding, wraps)                 // published by the first pump at or after the hold time
        } else {
            try await publishJoin(adding: adding, wraps: wraps, relay: relay, session: session)
        }
        await stage("complete.final")
        guard core.pendingPairs[device]?.version == v else {
            // rejected after the publication began: the device was listed, so taking it out is a removal and rotates (section 7.2)
            if heldList != nil { heldList = nil } else {
                try? await rotate(remaining: roster.values.filter { $0.keys.deviceID != device }.map { ($0.keys, $0.scopes) }, relay: relay, session: session)
            }
            throw PairingApprovalError.notPending
        }
        core.approvedEpochOverride = hostile.approvedEpoch
        core.pendingPairs[device]?.state = "approved"
        // the join anchor: the list that adds this device. A held list (a Demo scenario) is not accepted yet, so the phone stays
        // below the anchor and retries until it is published.
        core.pendingPairs[device]?.listSeq = heldList != nil ? listSeq + 1 : listSeq
        core.pendingPairs[device]?.cardSeq = Int64(max(cardSeq, 1))
        core.pendingPairs[device]?.scopes = scopes
        lastPairingError = nil
    }

    /// Publishes a list that a scenario held back, once its time has come.
    private func publishHeldList(relay: FakeRelay, session: RelaySession) async throws {
        guard let h = heldList, let hold = listHoldUntilMs, wall.nowMs >= hold else { return }
        heldList = nil
        try await publishJoin(adding: h.adding, wraps: h.wraps, relay: relay, session: session)
    }

    // MARK: serving

    /// One pass over the epoch-0 inboxes: answers every pairing request that arrived since the last pass, in global arrival order across
    /// all offers (section 8.3), then moves every `cert_pending` pairing on (the primary's challenge, its certificate, its rejection, the
    /// 10-minute expiry).
    @discardableResult
    public func pumpPairing(relay: FakeRelay, transport: any RelayTransport) async throws -> Int {
        let session = try await currentSession(transport: transport)
        var handled = 0
        var inbox: [(offer: ID16, rid: ID16, envelope: Data, arrival: UInt64)] = []
        for offer in core.offers.keys {
            for item in try await relay.pendingPairRequests(workspace: workspace, offer: offer, token: session.token) where item.arrival > lastPairArrival {
                inbox.append((offer, item.rid, item.envelope, item.arrival))
            }
        }
        for item in inbox.sorted(by: { $0.arrival < $1.arrival }) {
            lastPairArrival = max(lastPairArrival, item.arrival)
            for chunk in await process(envelope: item.envelope, mailbox: item.rid) {
                // the response is posted with the workspace session under this host's holder generation (W(g)); a lost post (or a
                // lost hold) is a lost answer (the phone re-sends)
                let target = "\(HostAPI.base)/workspaces/\(workspace.hex)/pair/\(item.offer.hex)/\(item.rid.hex)"
                guard let gen = try? await holderGeneration(relay: relay, session: session) else { continue }
                if let req = try? WireRequest(method: "POST", target: target, headers: ["authorization": "Bearer " + session.token,
                                                                                         "orch-holder": String(gen)],
                                              body: chunk, clientAddress: "host") {
                    _ = try? await relay.send(req)
                }
            }
            handled += 1
        }
        try await publishHeldList(relay: relay, session: session)
        try await progressCertPending(relay: relay, transport: transport, token: session.token)
        return handled
    }

    private func progressCertPending(relay: FakeRelay, transport: any RelayTransport, token: String) async throws {
        let now = wall.nowMs
        for device in core.pendingPairs.keys.sorted(by: { $0.hex < $1.hex }) {
            // every step re-reads the pairing: a rejection or an approval that interleaved at an await is never overwritten
            guard let p = core.pendingPairs[device], p.state == "cert_pending", let since = p.certPendingSince, let rid = p.requestID else { continue }
            let v = p.version
            if now >= since + HostBridgeCore.certPendingLifeMs { transition(device, to: "expired"); continue }
            // `GET /v2/cert-requests/{id}`: the queue's state, the primary's challenge, its certificate or its rejection
            let view = try await certRequestView(relay: relay, requestID: rid, token: token)
            guard core.pendingPairs[device]?.version == v else { continue }
            if let rej = view?.rejection {
                // only a rejection that verifies under the owner's PK for exactly this request ends the pairing as the primary's
                // "no"; anything else is ignored (the pairing keeps waiting and expires on its own)
                // A rejection that does not verify is ignored and the request is checked as if it had none (challenge, certificate):
                // an unauthenticated relay field must never stall a pairing.
                if let r = try? CertRejection.verify(rej, pk: primary.publicKey), r.requestID == rid, r.workspace == workspace,
                   r.offer == p.offer, r.attempt.utf8.elementsEqual(p.attempt.utf8), r.device == device,
                   r.dkHash == Identifiers.dkHash(sig: p.dkSig, kx: p.dkKx),
                   r.person == primary.personID {
                    core.pendingPairs[device]?.rejection = rej
                    transition(device, to: "rejected")
                    continue
                }
            }
            if p.challenge == nil, let ch = view?.challenge {
                core.pendingPairs[device]?.challenge = ch          // relayed unchanged in the next cert_pending answer
            }
            // the request's certificate, or the directory's: has the primary certified exactly this device?
            // Both sources are tried: one that does not verify (or names other keys) never hides a good one in the other.
            // An R1 host wants its own key certified, not the phone admitted, and `asksPrimaryAlways` waits for the primary's answer:
            // neither falls back to the phone's directory certificate.
            let directory = bypassesPresentedCertificate ? nil : await relay.certificate(device: device)
            guard core.pendingPairs[device]?.version == v else { continue }
            let good = [view?.cert, directory].compactMap { $0 }.first { cert in
                (try? DeviceCertificate.verify(cert, personKey: primary.publicKey, nowMs: now, revoked: core.revoked))
                    .map({ $0.signingKey == p.dkSig && $0.agreementKey == p.dkKx }) == true
            }
            if let cert = good {
                core.pendingPairs[device]?.cert = cert
                do { try await completeJoin(device: device, relay: relay, transport: transport) } catch { lastPairingError = "\(error)" }
            }
        }
    }

    /// `GET /v2/cert-requests/{id}` with the workspace session; nil when the relay no longer holds the request.
    private func certRequestView(relay: FakeRelay, requestID: ID16, token: String) async throws -> (challenge: JSONValue?, cert: JSONValue?, rejection: JSONValue?)? {
        let get = try WireRequest(method: "GET", target: "\(HostAPI.base)/cert-requests/\(requestID.hex)", headers: ["authorization": "Bearer " + token],
                                  body: Data(), clientAddress: "host")
        let reply = try await relay.send(get)
        if reply.status == 404 { return nil }
        let o = try HostAPI.object(try HostAPI.expect(reply))
        func field(_ k: String) -> JSONValue? { o[k].flatMap { $0.isNull ? nil : $0 } }
        return (field("challenge"), field("cert"), field("rejection"))
    }

    /// Seals an epoch-0 answer: under the offer's `K_pair`, header `stream` = the offer, `LAST` (+ `REFUSAL`), signed by `WSK`.
    func respondPairing(to req: Bridge.Header, reply: HostPairReply) throws -> [Data] {
        guard let offer = core.offers[req.stream] else { throw CryptoFailure.invalidKey }
        var meta: JSONValue
        var refusal = false
        switch reply {
        case .pending(_, _, _, let a): meta = a
        case .status(let a): meta = a
        case .refuse(_, let m): meta = m; refusal = true
        }
        if let wrong = echoWrongKey, var o = meta.object, o["state"]?.string == "pending" {
            switch wrong {
            case .signing: o["dk_sig_pub"] = .string(B64U.encode(SoftwareSigner().publicKey.x963))
            case .exchange: o["dk_kx_pub"] = .string(B64U.encode(SoftwareKeyAgreer().publicKey.x963))
            }
            meta = .object(o)
        }
        var flags: Bridge.Flags = [.last]
        if refusal { flags.insert(.refusal) }
        let h = Bridge.Header(direction: .toDevice, flags: flags, workspace: workspace, device: req.device, rid: req.rid, stream: req.stream, seq: 0,
                              tsMs: UInt64(max(wall.nowMs, 0)), epoch: 0, salt: entropy.bytes(16))
        guard let key = Bridge.channelKey(header: h, pairSecret: SymmetricKey(data: offer.secret)) else { throw CryptoFailure.invalidKey }
        return [try Bridge.seal(header: h, channelKey: key, signer: responseSigner ?? wsk, plaintext: Bridge.frame(meta: meta))]
    }
}
