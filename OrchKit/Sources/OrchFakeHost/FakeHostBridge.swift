import CryptoKit
import Foundation
import OrchClient
import OrchProtocol

/// What the host hands an op handler after section 8.6 accepted a request.
public struct HostRequest: Sendable {
    public let device: ID16
    public let scopes: [String]
    public let meta: JSONValue
    public let data: Data
    public let epoch: UInt32
}

public enum HostReply: Sendable {
    case response(status: Int, headers: [String: String], data: Data)
    case refuse(HostRefusal)
}

public typealias HostHandler = @Sendable (HostRequest) async -> HostReply

/// Without a view layer (slice 3) every `http` path is unknown and every other op is not implemented yet.
public let defaultHostHandler: HostHandler = { req in
    guard let op = req.meta.object?["op"]?.string else { return .refuse(.malformed) }
    if op == "http" {
        return .response(status: 404, headers: ["content-type": "application/json"],
                         data: (try? canonicalJSON(["host_api": 0, "error": "not_found"])) ?? Data())
    }
    return .refuse(.malformed)
}

extension FakeHost {
    public func setHandler(_ h: @escaping HostHandler) { handler = h }

    /// Makes `epoch` the current epoch, creating `WK_epoch` if needed. Older keys are kept to read older content and to
    /// answer an old-epoch request with `stale_epoch` under its own key.
    public func installEpoch(_ e: UInt32) {
        core.keys[e] = wk(e)
        core.epoch = e
        epoch = e
    }

    /// The host's membership roster: device keys and scopes, as published in the member list.
    public func setRoster(_ members: [(DemoKeys, [String])]) {
        roster = Dictionary(uniqueKeysWithValues: members.map { ($0.0.deviceID, (keys: $0.0, scopes: $0.1)) })
        core.members = roster.mapValues(\.scopes)
        core.devicePubs = roster.mapValues(\.keys.sig)
    }

    /// Deletes an old epoch's key (vector `epoch_whose_key_the_host_deleted_dropped`).
    public func deleteKey(epoch e: UInt32) { core.keys[e] = nil }

    /// Rotation (section 7.2 host rules): `WK_{e+1}`, a grant for every remaining device, then the list.
    public func rotate(remaining: [(DemoKeys, [String])], relay: FakeRelay, session: RelaySession) async throws {
        let next = epoch + 1
        listSeq += 1
        _ = wk(next)
        for (k, _) in remaining { try await relay.putGrant(try grant(for: k, epoch: next), token: session.token) }
        try await relay.publishMemberList(try memberList(remaining.map { ($0.0.deviceID, $0.1) }, epoch: next, listSeq: max(listSeq, 2)), token: session.token)
        installEpoch(next)
        setRoster(remaining)
    }

    /// Simulates a host that ran a request and lost the record of its answer: a re-send gets `already_done(unknown)`.
    package func forgetOutcome(rid: ID16) { core.rids[rid]?.outcome = nil }

    package func setResponseSigner(_ s: SoftwareSigner?) { responseSigner = s }

    /// Adversarial/state tests: the host's own view of revocation (normally set by the PK-signed op).
    package func markRevoked(_ d: ID16) { core.revoked.insert(d) }

    package func coreState() -> HostBridgeCore { core }

    /// Section 8.6 for one request envelope. Returns the sealed response chunks to post, in order (empty for silence).
    public func process(envelope: Data, mailbox: ID16?) async -> [Data] {
        let now = wall.nowMs
        switch core.check(envelope, mailbox: mailbox, nowMs: now) {
        case .drop: return []
        case .refuse(let r, let h): return (try? respond(to: h, meta: r.meta, data: Data(), refusal: true)) ?? []
        case .replay(let chunks, _): return chunks
        case .accept(let a):
            let reply = await run(a)
            switch reply {
            case .refuse(let r):
                let chunks = (try? respond(to: a.header, meta: r.meta, data: Data(), refusal: true)) ?? []
                core.complete(rid: a.header.rid, with: .refusal(r))
                return chunks
            case .response(let status, let headers, let data):
                let meta: JSONValue = ["status": .int(Int64(status)), "headers": .object(headers.mapValues { .string($0) })]
                guard let chunks = try? respond(to: a.header, meta: meta, data: data, refusal: false) else { return [] }
                core.complete(rid: a.header.rid, with: .stored(chunks))
                return chunks
            }
        }
    }

    private func requiredScope(_ op: String, meta: JSONValue) -> String?? {
        switch op {
        case "http": return .some("look")
        case "decision": return .some("decide")
        case "new_ticket", "member_remove": return .some("operate")
        case "revocation": return .some(nil)           // authority is PK's signature, not a scope
        default: return nil                            // unknown op
        }
    }

    private func run(_ a: HostAccepted) async -> HostReply {
        guard let op = a.meta.object?["op"]?.string, let need = requiredScope(op, meta: a.meta) else { return .refuse(.malformed) }
        if let need, !a.scopes.contains(need) { return .refuse(.forbiddenScope) }
        if op == "revocation" {
            switch core.applyRevocation(a.meta, ownerKey: primary.publicKey) {
            case .ok: return .response(status: 200, headers: [:], data: (try? canonicalJSON(["host_api": 0, "revoked": true])) ?? Data())
            case .refuse(let c): return .refuse(c == "other_person" ? .otherPerson : (c == "bad_signature" ? .badSignature : .malformed))
            }
        }
        return await handler(HostRequest(device: a.header.device, scopes: a.scopes, meta: a.meta, data: a.data, epoch: a.header.epoch))
    }

    /// Seals response chunks under the request's own epoch key (so a `stale_epoch` refusal at an old epoch is readable by
    /// its sender), signed by `WSK`. Chunk index is the header `seq`; `LAST` on the final one; a refusal is one `LAST|REFUSAL` chunk.
    func respond(to req: Bridge.Header, meta: JSONValue, data: Data, refusal: Bool) throws -> [Data] {
        guard let wk = core.keys[req.epoch] else { throw CryptoFailure.invalidKey }
        let zero = ID16(bytes: Data(count: 16))!
        let stream = req.flagSet.contains(.stream) ? req.rid : zero
        let room = Bridge.maxChunk - Bridge.overhead - 4
        var pieces: [(JSONValue, Data)] = []
        let firstMeta = try canonicalJSON(meta).count
        guard firstMeta <= Bridge.maxMeta, firstMeta < room else { throw Refusal.malformed }
        var rest = data[...]
        let take = min(rest.count, room - firstMeta)
        pieces.append((meta, Data(rest.prefix(take)))); rest = rest.dropFirst(take)
        while !rest.isEmpty {
            let n = min(rest.count, room - 2)
            pieces.append((.object([:]), Data(rest.prefix(n)))); rest = rest.dropFirst(n)
        }
        var out: [Data] = []
        for (i, p) in pieces.enumerated() {
            var flags: Bridge.Flags = []
            if i == pieces.count - 1 { flags.insert(.last) }
            if refusal { flags.insert(.refusal) }
            if req.flagSet.contains(.stream) { flags.insert(.stream) }
            let h = Bridge.Header(direction: .toDevice, flags: flags, workspace: workspace, device: req.device, rid: req.rid, stream: stream,
                                  seq: UInt64(i), tsMs: UInt64(max(wall.nowMs, 0)), epoch: req.epoch, salt: entropy.bytes(16))
            guard let key = Bridge.channelKey(header: h, wk: wk) else { throw CryptoFailure.invalidKey }
            out.append(try Bridge.seal(header: h, channelKey: key, signer: responseSigner ?? wsk, plaintext: Bridge.frame(meta: p.0, data: p.1)))
        }
        return out
    }

    /// One pass over the relay's inbox: runs every request that arrived since the last pass and posts the answers under the
    /// host's workspace session. A byte-identical re-send is a new arrival and gets the recorded answer (section 8.6 step 5).
    @discardableResult
    public func pump(relay: FakeRelay, transport: any RelayTransport, session: RelaySession) async throws -> Int {
        let inbox = try await relay.pendingRequests(workspace: workspace, token: session.token).filter { $0.arrival > lastArrival }
            .sorted { $0.arrival < $1.arrival }
        var handled = 0
        for item in inbox {
            lastArrival = max(lastArrival, item.arrival)
            let chunks = await process(envelope: item.envelope, mailbox: item.rid)
            for c in chunks {
                let r = try await transport.bridgePost(c, route: BridgeRoute(workspaceID: workspace, requestID: item.rid), session: session)
                _ = try HostAPI.expect(r, status: 202)
            }
            handled += 1
        }
        return handled
    }
}
