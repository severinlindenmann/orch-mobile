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
        try await beginRotation(remaining: remaining, relay: relay, session: session).value
    }

    /// Every entry point installs the gate synchronously, before publication can suspend. Concurrent callers join it.
    /// Only the publication task owns cleanup, so a waiter cannot clear the gate of a later rotation.
    private func beginRotation(remaining: [(DemoKeys, [String])], relay: FakeRelay, session: RelaySession) -> Task<Void, Error> {
        if let rotation { return rotation }
        rotationRequired = true
        pendingRotation = (remaining, relay, session)
        let task = Task {
            defer { rotation = nil }
            try await publishRotation(remaining: remaining, relay: relay, session: session)
            pendingRotation = nil
            rotationRequired = false
        }
        rotation = task
        return task
    }

    private func publishRotation(remaining: [(DemoKeys, [String])], relay: FakeRelay, session: RelaySession) async throws {
        let next = epoch + 1
        try await publishHook?()
        endOpenStreams(newEpoch: next)
        listSeq += 1
        _ = wk(next)
        for (k, _) in remaining { try await relay.putGrant(try grant(for: k, epoch: next), token: session.token) }
        try await relay.publishMemberList(try memberList(remaining.map { ($0.0.deviceID, $0.1) }, epoch: next, listSeq: max(listSeq, 2)), token: session.token)
        installEpoch(next)
        setRoster(remaining)
    }

    /// Section 8.5: rotation ends every open stream with `LAST | REFUSAL` `stale_epoch`, sealed under the stream's own (old) epoch.
    /// The chunks wait in the outbox for `pump`; a late answer from the stream's handler is discarded.
    private func endOpenStreams(newEpoch: UInt32) {
        for (rid, st) in streamOpen {
            let h = Bridge.Header(direction: .toDevice, flags: [.last, .refusal, .stream], workspace: workspace, device: st.device, rid: rid, stream: rid,
                                  seq: st.next, tsMs: UInt64(max(wall.nowMs, 0)), epoch: st.epoch, salt: entropy.bytes(16))
            if let wk = core.keys[st.epoch], let key = Bridge.channelKey(header: h, wk: wk),
               let chunk = try? Bridge.seal(header: h, channelKey: key, signer: responseSigner ?? wsk,
                                            plaintext: Bridge.frame(meta: HostRefusal.staleEpoch(epoch: newEpoch).meta, data: Data())) {
                outbox.append((rid, chunk))
            }
            streamEnded.insert(rid)
        }
        streamOpen = [:]
        core.streams = [:]
    }

    /// Chunks queued by rotation, for tests that do not pump.
    package func takeOutbox() -> [(rid: ID16, chunk: Data)] { let o = outbox; outbox = []; return o }

    /// Simulates a host that ran a request and lost the record of its answer: a re-send gets `already_done(unknown)`.
    package func forgetOutcome(rid: ID16) { core.rids[rid]?.outcome = nil }

    package func setResponseSigner(_ s: SoftwareSigner?) { responseSigner = s }

    /// Adversarial/state tests: the host's own view of revocation (normally set by the PK-signed op).
    package func markRevoked(_ d: ID16) { core.revoked.insert(d) }

    package func coreState() -> HostBridgeCore { core }

    /// Section 8.6 for one request envelope. Returns the sealed response chunks to post, in order (empty for silence).
    /// A rotation in progress is awaited first, and membership, revocation and epoch are checked AGAIN after the handler
    /// ran: if any changed, the answer is `already_done(unknown)` and no data leaves under the old epoch (section 8.5).
    public func process(envelope: Data, mailbox: ID16?) async -> [Data] {
        while let t = rotation { _ = try? await t.value }
        let now = wall.nowMs
        switch core.check(envelope, mailbox: mailbox, nowMs: now) {
        case .drop: return []
        case .refuse(let r, let h): return (try? respond(to: h, meta: r.meta, data: Data(), refusal: true)) ?? []
        case .replay(let chunks, let h):
            if rotationRequired {
                return (try? respond(to: h, meta: HostRefusal.alreadyDone(status: "unknown").meta, data: Data(), refusal: true)) ?? []
            }
            return chunks
        case .accept(let a):
            let h = a.header
            if h.flagSet.contains(.stream) { streamOpen[h.rid] = (h.device, h.epoch, 0) }
            let isRevocation = a.meta.object?["op"]?.string == "revocation"
            if rotationRequired && !isRevocation {           // a retired key may still be active: nothing runs, nothing is sealed
                streamOpen[h.rid] = nil
                return (try? respond(to: h, meta: HostRefusal.alreadyDone(status: "unknown").meta, data: Data(), refusal: true)) ?? []
            }
            let reply = await run(a)
            // A non-stream handler may finish while grants are suspended, with epoch and membership still unchanged.
            // Refuse immediately; streams wait for their terminal stale_epoch chunk and revocation waits for its own rotation.
            if rotationRequired && !isRevocation && !h.flagSet.contains(.stream) {
                return (try? respond(to: h, meta: HostRefusal.alreadyDone(status: "unknown").meta, data: Data(), refusal: true)) ?? []
            }
            while let t = rotation { _ = try? await t.value }     // seal only after a rotation completed
            if streamEnded.remove(h.rid) != nil { return [] }          // a rotation already ended this stream
            streamOpen[h.rid] = nil
            // The revocation's own `{"revoked":true}` reply is the one exemption: it is sealed under the request's epoch (8.5), carries no data.
            let changed = core.revoked.contains(h.device) || core.members[h.device] == nil || (!isRevocation && core.epoch != h.epoch)
                || (rotationRequired && !isRevocation)
            if changed { return (try? respond(to: h, meta: HostRefusal.alreadyDone(status: "unknown").meta, data: Data(), refusal: true)) ?? [] }
            switch reply {
            case .refuse(let r):
                let chunks = (try? respond(to: h, meta: r.meta, data: Data(), refusal: true)) ?? []
                core.complete(rid: h.rid, with: .refusal(r))
                return chunks
            case .response(let status, let headers, let data):
                let meta: JSONValue = ["status": .int(Int64(status)), "headers": .object(headers.mapValues { .string($0) })]
                guard let chunks = try? respond(to: h, meta: meta, data: data, refusal: false) else { return [] }
                core.complete(rid: h.rid, with: .stored(chunks))
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
        if op == "revocation" { return await applyRevocation(a) }
        return await handler(HostRequest(device: a.header.device, scopes: a.scopes, meta: a.meta, data: a.data, epoch: a.header.epoch))
    }

    /// Protocol 6.2/8.7: the revocation takes effect at once; a removed member means a rotation (grants, then the list, then the
    /// new epoch) BEFORE anything new is sealed and before this reply. Without a relay to publish to (`process` outside `pump`)
    /// nothing is applied and the answer is `already_done(unknown)`.
    private func applyRevocation(_ a: HostAccepted) async -> HostReply {
        var probe = core
        switch probe.applyRevocation(a.meta, ownerKey: primary.publicKey) {
        case .refuse(let c): return .refuse(c == "other_person" ? .otherPerson : (c == "bad_signature" ? .badSignature : .malformed))
        case .ok(let device, let rotate):
            if rotate || rotationRequired {
                guard bridgeRelay != nil else { return .refuse(.alreadyDone(status: "unknown")) }
                if rotate { rotationRequired = true }          // before the member leaves the roster
                core = probe
                for (rid, st) in streamOpen where st.device == device { streamEnded.insert(rid); streamOpen[rid] = nil }
                guard await runRotation() else { return .refuse(.alreadyDone(status: "unknown")) }
            } else { core = probe }
            return .response(status: 200, headers: [:], data: (try? canonicalJSON(["host_api": 0, "revoked": true])) ?? Data())
        }
    }

    /// Publishes the pending rotation (grants, list, new epoch) for the roster minus every revoked device. Joins one in progress.
    /// `rotationRequired` is cleared only on success.
    @discardableResult
    private func runRotation() async -> Bool {
        let task: Task<Void, Error>
        if let rotation { task = rotation }
        else if let pending = pendingRotation {
            let remaining = pending.remaining.filter { !core.revoked.contains($0.0.deviceID) }
            task = beginRotation(remaining: remaining, relay: pending.relay, session: pending.session)
        } else {
            guard let ctx = bridgeRelay else { return false }
            let remaining = roster.filter { !core.revoked.contains($0.key) }.map { ($0.value.keys, $0.value.scopes) }
            task = beginRotation(remaining: remaining, relay: ctx.relay, session: ctx.session)
        }
        do { try await task.value; return !rotationRequired } catch { return false }
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
        bridgeRelay = (relay, session)
        if rotationRequired { await runRotation() }
        try await flushOutbox(transport: transport, session: session)
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
            try await flushOutbox(transport: transport, session: session)
            handled += 1
        }
        return handled
    }

    private func flushOutbox(transport: any RelayTransport, session: RelaySession) async throws {
        while !outbox.isEmpty {
            let item = outbox.removeFirst()
            let r = try await transport.bridgePost(item.chunk, route: BridgeRoute(workspaceID: workspace, requestID: item.rid), session: session)
            _ = try HostAPI.expect(r, status: 202)
        }
    }
}
