import CryptoKit
import Foundation
import OrchClient
import OrchProtocol

/// What the primary shows its human for one open request (host-api section 5: the separate, labelled Demo primary panel).
public struct PrimaryPrompt: Sendable, Equatable {
    public let requestID: ID16
    public let workspace: ID16
    public let deviceID: ID16
    /// The label the host cleaned and put into the request. Untrusted text.
    public let deviceLabel: String
    /// The code the human compares with the phone's screen: over the primary's own challenge, never over anything the host chose.
    public let certCode: String
    /// "This workspace runs on a machine that someone else administers."
    public let clientHostedWarning: Bool
    public let expiresMs: Int64
    public let scopesAsked: [String]
}

public enum PrimaryError: Error, Equatable, Sendable {
    /// Approve is available only after "I compared the codes".
    case comparisonNotConfirmed
    case unknownRequest
}

extension FakePrimary {
    /// Reads the queue for this primary device: each new request goes through the section 8.4 checks in order
    /// (`CertRequest.openAsPrimary`); only then does it draw its nonce, sign the challenge with `PK` and post it. A request that fails a
    /// check gets no challenge. Returns the requests that now wait for the human.
    @discardableResult
    public func processInbox(relay: FakeRelay) async -> [PrimaryPrompt] {
        try? capability.generation.check()
        var fresh: [PrimaryPrompt] = []
        for r in await relay.pendingCertRequests(primary: deviceID) {
            guard let o = r.object?["o"]?.object, let rid = o["request_id"]?.string.flatMap({ ID16(hex: $0) }), !ledger.seen.contains(rid),
                  refusals[rid] == nil, let ws = o["workspace_id"]?.string.flatMap({ ID16(hex: $0) }),
                  let card = await relay.verifiedCard(workspace: ws) else { continue }
            if case .success(let p) = await open(request: r, card: card, relay: relay) { fresh.append(p) }
        }
        return fresh
    }

    /// One request through section 8.4 step 2 (in order), then step 3: the nonce is drawn only after the keys reached the primary,
    /// the challenge is signed with `PK` and posted. A refused request gets no challenge and is remembered with its code.
    public func open(request r: JSONValue, card: VerifiedCard, relay: FakeRelay) async -> Result<PrimaryPrompt, Refusal> {
        let rid = r.object?["o"]?.object?["request_id"]?.string.flatMap { ID16(hex: $0) }
        do {
            try capability.generation.check()
            let accepted = try CertRequest.openAsPrimary(r, card: card, myPerson: personID, me: deviceID, myKey: kxAgreer, ledger: &ledger, nowMs: wall.nowMs)
            let challenge = try ledger.issueChallenge(requestID: accepted.requestID, primaryNonce: entropy.bytes(32), primary: pkSigner, nowMs: wall.nowMs)
            try await relay.postCertChallenge(challenge.json)
            let code = try Identifiers.certCode(challengeObject: .object(challenge.object))
            let p = PrimaryPrompt(requestID: accepted.requestID, workspace: card.workspace, deviceID: accepted.inner.deviceID, deviceLabel: accepted.inner.label,
                                  certCode: code, clientHostedWarning: accepted.clientHostedWarning, expiresMs: challenge.object["expires_ms"]?.int ?? 0,
                                  scopesAsked: accepted.inner.scopesMax)
            prompts[accepted.requestID] = p
            return .success(p)
        } catch let refusal as Refusal {
            if let rid { refusals[rid] = refusal }
            return .failure(refusal)
        } catch {
            if let rid { refusals[rid] = .malformed }
            return .failure(.malformed)
        }
    }

    /// Requests waiting for the human (unexpired, not signed, not rejected).
    public func openPrompts() -> [PrimaryPrompt] {
        let now = wall.nowMs
        return prompts.values.filter { now < $0.expiresMs }.sorted { $0.requestID.hex < $1.requestID.hex }
    }

    /// What the primary refused and why (section 8.4 codes), by request id.
    public func refusal(of request: ID16) -> Refusal? { refusals[request] }

    /// Second explicit approval: the human compared the code. Signs exactly the keys of the stored challenge, once. `scopesMax` may
    /// narrow what the host asked for, never widen it. The certificate goes to the directory.
    @discardableResult
    public func approve(request: ID16, scopesMax: [String]? = nil, confirmedComparison: Bool, relay: FakeRelay) async throws -> JSONValue {
        try capability.generation.check()
        guard confirmedComparison else { throw PrimaryError.comparisonNotConfirmed }
        guard let p = prompts[request] else { throw PrimaryError.unknownRequest }
        let sealed = try SealedLabel.seal(label: p.deviceLabel, pvk: pvkKey, person: personID, device: p.deviceID)
        let cert = try ledger.signCertificate(requestID: request, labelSealed: sealed, createdMs: wall.nowMs, expiresMs: nil,
                                              scopesMax: scopesMax ?? p.scopesAsked, primary: pkSigner)
        prompts[request] = nil
        try await relay.publishCertificate(cert.json)
        return cert.json
    }

    /// The human rejected the code: the request is closed and nothing is ever signed for it. The host is told (v0 propagation).
    public func reject(request: ID16, relay: FakeRelay) async throws {
        try capability.generation.check()
        guard prompts[request] != nil else { throw PrimaryError.unknownRequest }
        ledger.reject(requestID: request)
        prompts[request] = nil
        await relay.postCertRequestRejected(requestID: request)
    }

    /// The host is the owner's primary device (host-api section 5): after the host's own human approval it certifies locally. The same
    /// authority code signs; there is no cert-code screen. Never for a client-hosted workspace (such a host never receives `PK`).
    public func certifyAsHost(_ keys: DemoKeys, label: String, scopesMax: [String]) throws -> JSONValue {
        try capability.generation.check()
        return try signDeviceCert(keys, label: label, scopesMax: scopesMax, lifetimeMs: nil)
    }
}
