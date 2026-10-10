import CryptoKit
import Foundation
import OrchClient
import OrchFakeHost
import OrchProtocol
@testable import OrchClient
@testable import OrchFakeHost
@testable import OrchProtocol

/// A stand-in for a host that is not honest: it reads the phone's epoch-0 requests off the relay (it holds the link secret, as a
/// host does) and answers each with whatever the script says, sealed under `K_pair` and signed with the real `WSK`. Test-only.
final class PairForge: @unchecked Sendable {
    let h: PairHarness
    let link: PairingLink
    let nonceA = Data(repeating: 0xA1, count: 32)
    let nonceB = Data(repeating: 0xB2, count: 32)
    private let lock = NSLock()
    private var last: UInt64 = 0
    var phone: DemoKeys { DemoKeys(h.env.device.publicKeys) }

    init(h: PairHarness, link: PairingLink) { self.h = h; self.link = link }

    private var wskB64: JSONValue { .string(B64U.encode(h.host.wskPublic.x963)) }
    private var pkB64: JSONValue { .string(B64U.encode(h.primary.publicKey.x963)) }

    func pending(nonce: Data) -> JSONValue {
        ["state": "pending", "wsk_pub": wskB64, "sas_nonce": .string(B64U.encode(nonce)),
         "dk_sig_pub": .string(B64U.encode(phone.sig.x963)), "dk_kx_pub": .string(B64U.encode(phone.kx.x963))]
    }

    func certPending(challenge: JSONValue?, label: String = "Demo Mac") -> JSONValue {
        ["state": "cert_pending", "primary_label": .string(label), "pk_pub": pkB64, "challenge": challenge ?? .null, "wsk_pub": wskB64]
    }

    /// A PK-signed challenge for the phone's own keys.
    func challenge(nonce: Data, request: ID16 = ID16(bytes: Data(repeating: 0x33, count: 16))!, expiresDelta: Int64 = 0) async throws -> JSONValue {
        let exp = h.clock.nowMs + 600_000 + expiresDelta
        let o: [String: JSONValue] = [
            "v": 2, "suite": 2, "kind": "cert_challenge", "request_id": .string(request.hex), "workspace_id": .string(h.host.workspace.hex),
            "person_id": .string(h.primary.personID.hex), "device_id": .string(phone.deviceID.hex), "dk_sig_pub": .string(B64U.encode(phone.sig.x963)),
            "dk_kx_pub": .string(B64U.encode(phone.kx.x963)), "primary_nonce": .string(B64U.encode(nonce)), "expires_ms": .int(exp)]
        return try CertChallenge.sign(o, primary: h.primary.pkSigner).json
    }

    func approved(for keys: DemoKeys, signedBy signer: SoftwareSigner? = nil, pk: SigningPublicKey? = nil, scopes: [String] = ["look", "decide"],
                  epoch: Int64 = 1) async throws -> JSONValue {
        let cert: JSONValue
        if let signer {
            cert = try SignedObject.sign([
                "v": 2, "suite": 2, "kind": "device_cert", "device_id": .string(keys.deviceID.hex), "person_id": .string(Identifiers.personID(signer.publicKey).hex),
                "dk_sig_pub": .string(B64U.encode(keys.sig.x963)), "dk_kx_pub": .string(B64U.encode(keys.kx.x963)),
                "label_sealed": .string(B64U.encode(Data(count: 40))), "created_ms": .int(h.clock.nowMs), "expires_ms": .null,
                "scopes_max": ["look", "decide", "operate"]], kind: .deviceCert, signer: signer).json
        } else {
            cert = try await h.primary.certify(keys, label: "Demo iPhone", scopesMax: ["look", "decide", "operate"])
        }
        let pkValue: JSONValue = pk.map { .string(B64U.encode($0.x963)) } ?? pkB64
        return ["state": "approved", "scopes": .array(scopes.map { .string($0) }), "cert": cert, "pk_pub": pkValue, "epoch": .int(epoch), "wsk_pub": wskB64]
    }

    /// Seals `meta` as the answer to one phone request (`rid`).
    func answer(_ meta: JSONValue, to request: Bridge.Header, refusal: Bool = false) throws -> Data {
        var flags: Bridge.Flags = [.last]
        if refusal { flags.insert(.refusal) }
        let hd = Bridge.Header(direction: .toDevice, flags: flags, workspace: request.workspace, device: request.device, rid: request.rid, stream: request.stream,
                               seq: 0, tsMs: UInt64(h.clock.nowMs), epoch: 0)
        let key = Bridge.channelKey(header: hd, pairSecret: SymmetricKey(data: link.secret))!
        return try Bridge.seal(header: hd, channelKey: key, signer: h.host.wsk, plaintext: Bridge.frame(meta: meta))
    }

    /// Answers every request that arrived since the last call; `script` gets the op (`pair` or `pair_status`) and returns the meta, or nil
    /// for silence. Returns how many requests were seen.
    @discardableResult
    func pump(_ script: (String) async throws -> JSONValue?) async throws -> Int {
        let session = try await h.host.openSession(transport: h.env.transport)
        let inbox = try await h.relay.pendingPairRequests(workspace: h.host.workspace, offer: link.offer, token: session.token)
        var seen = 0
        for item in inbox.sorted(by: { $0.arrival < $1.arrival }) {
            let isNew: Bool = lock.withLock { if item.arrival > last { last = item.arrival; return true }; return false }
            guard isNew else { continue }
            seen += 1
            let parts = try Bridge.Parts(envelope: item.envelope)
            let key = Bridge.channelKey(header: parts.header, pairSecret: SymmetricKey(data: link.secret))!
            let (meta, _) = try Bridge.unframe(try Bridge.openBody(parts, channelKey: key))
            guard let op = meta.object?["op"]?.string, let reply = try await script(op) else { continue }
            let env = try answer(reply, to: parts.header, refusal: reply.object?["refusal"] != nil)
            let target = "\(HostAPI.base)/workspaces/\(h.host.workspace.hex)/pair/\(link.offer.hex)/\(item.rid.hex)"
            let req = try WireRequest(method: "POST", target: target, headers: [HostAPI.versionHeader: "0", "authorization": "Bearer " + session.token], body: env, clientAddress: "forge")
            _ = try await h.relay.send(req)
        }
        return seen
    }

    /// An epoch-0 `pair` request from some other device that holds the link (someone who got the QR).
    func sendPair(signer: SoftwareSigner, keys: DemoKeys, label: String) async throws {
        let ctx = PairingWire.Context(workspace: link.workspace, device: keys.deviceID, offer: link.offer, secret: SymmetricKey(data: link.secret),
                                      wskPin: link.wskPin, pkPin: link.pkPin, dkSig: keys.sig, dkKx: keys.kx)
        let rid = ID16.random()
        let env = try PairingWire.request(.pair(label: label, cert: nil), context: ctx, signer: signer, rid: rid, seq: 1, tsMs: h.clock.nowMs, salt: Bridge.Header.freshSalt())
        let reply = try await h.env.transport.pairingPost(env, route: PairRoute(workspaceID: link.workspace, offerID: link.offer, requestID: rid))
        precondition(reply.status == 202)
    }
}
