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

    /// Rotation invariants (protocol §8.5):
    /// I1: No data is sealed while the gate is up, except the revocation reply (empty refusals are allowed).
    /// I2: Clear the gate only after grants, list and installEpoch succeed for one consistent roster.
    /// I3: Retire failed uncommitted attempts, deleting grants after authenticated acknowledgement; retries use fresh keys and increasing epochs.
    /// I4: The final roster excludes every queued removal and every relay/host revocation.
    /// I5: One task serializes requests; same-roster requests on the same relay join using current credentials.
    /// I6: Failures retain the gate and pending work; pump retries it.
    /// I7: Recovery leaves no final-epoch grant for a removed/revoked device.
    ///
    /// Rotation (section 7.2 host rules): `WK_{e+1}`, a grant for every remaining device, then the list.
    public func rotate(remaining: [(DemoKeys, [String])], relay: FakeRelay, session: RelaySession) async throws {
        try await beginRotation(remaining: remaining, relay: relay, session: session).value
    }

    /// Keep the gate raised for the whole queue, including retries. A later request cannot restore a device
    /// removed since the gate was raised. Compare full rosters (including keys/scopes), independent of order.
    private func beginRotation(remaining: [(DemoKeys, [String])], relay: FakeRelay, session: RelaySession) -> Task<Void, Error> {
        refreshRotationSession(relay: relay, session: session)
        rotationRequired = true
        let sameRoster = lastRotationRoster.map { previous in
            rostersEqual(previous, remaining)
        } ?? false
        if !sameRoster || pendingRotations.last.map({ $0.relay !== relay || $0.session != session }) == true {
            let previousIDs = lastRotationRoster.map { Set($0.map { $0.0.deviceID }) } ?? Set(roster.keys)
            let requestedIDs = Set(remaining.map { $0.0.deviceID })
            rotationRemoved.formUnion(previousIDs.subtracting(requestedIDs))
            rotationRemoved.formUnion(core.revoked)
            lastRotationRoster = remaining
            pendingRotations.append((remaining.filter { !rotationRemoved.contains($0.0.deviceID) }, relay, session))
        }
        return drainRotations()
    }

    /// Only this task owns cleanup. Failed and unstarted requests stay queued for the next pump.
    private func drainRotations() -> Task<Void, Error> {
        if let rotation { return rotation }
        let task = Task {
            defer { rotation = nil }
            while !pendingRotations.isEmpty {
                // A5: retry scheduling uses the relay's injected monotonic clock.
                if rotationFailures > 0 {
                    try await pendingRotations[0].relay.clock.sleep(for: .milliseconds(100 * (1 << min(rotationFailures - 1, 4))))
                }
                await refreshPendingRotations()
                let pending = pendingRotations[0]
                do {
                    try await publishRotation(remaining: pending.remaining, relay: pending.relay, session: pending.session)
                } catch RotationChanged.roster {
                    continue
                } catch {
                    rotationFailures = min(rotationFailures + 1, 5)
                    throw error
                }
                rotationFailures = 0
                pendingRotations.removeFirst()
            }
            lastRotationRoster = nil
            rotationRemoved = []
            rotationRequired = false
        }
        rotation = task
        return task
    }

    private func rostersEqual(_ lhs: [(DemoKeys, [String])], _ rhs: [(DemoKeys, [String])]) -> Bool {
        lhs.count == rhs.count && lhs.allSatisfy { keys, scopes in
            rhs.contains { $0.0 == keys && Set($0.1) == Set(scopes) }
        }
    }

    /// Refresh every outstanding request before publication, including the failed head on retry.
    private func refreshPendingRotations() async {
        var revoked: Set<ID16> = []
        var index = 0
        // Enqueueing can happen while reading a relay; include those entries before filtering.
        while index < pendingRotations.count {
            revoked.formUnion(await pendingRotations[index].relay.revokedDevices())
            index += 1
        }
        revoked.formUnion(core.revoked)
        rotationRemoved.formUnion(revoked)
        for index in pendingRotations.indices {
            pendingRotations[index].remaining.removeAll { rotationRemoved.contains($0.0.deviceID) }
        }
        // Adjacent equal rosters need one publication. Preserve distinct transitions and relay/session contexts.
        var next = 1
        while next < pendingRotations.count {
            let previous = pendingRotations[next - 1], current = pendingRotations[next]
            if previous.relay === current.relay && previous.session == current.session
                && rostersEqual(previous.remaining, current.remaining) {
                pendingRotations.remove(at: next)
            } else { next += 1 }
        }
    }

    private enum RotationChanged: Error { case roster }

    private func checkRotationRoster(_ remaining: [(DemoKeys, [String])], relay: FakeRelay) async throws {
        rotationRemoved.formUnion(await relay.revokedDevices())
        rotationRemoved.formUnion(core.revoked)
        if remaining.contains(where: { rotationRemoved.contains($0.0.deviceID) }) {
            throw RotationChanged.roster
        }
    }

    private func refreshRotationSession(relay: FakeRelay, session: RelaySession) {
        rotationSessions[ObjectIdentifier(relay)] = session
        if bridgeRelay?.relay === relay { bridgeRelay = (relay, session) }
        for i in pendingRotations.indices where pendingRotations[i].relay === relay {
            pendingRotations[i].session = session
        }
    }

    private func currentRotationSession(_ relay: FakeRelay, fallback: RelaySession) -> RelaySession {
        rotationSessions[ObjectIdentifier(relay)] ?? fallback
    }

    private func retirePending(fallback: RelaySession) async throws {
        guard let pending = pendingRetirement else { return }
        let body = try RotationAbandon.signed(workspace: workspace, epoch: pending.epoch, signer: wsk)
        let session = currentRotationSession(pending.relay, fallback: fallback)
        let request = try WireRequest(method: "POST",
            target: "/mobile/host-api/0/workspaces/\(workspace.hex)/rotation-abandon",
            headers: [HostAPI.versionHeader: "0", "authorization": "Bearer \(session.token)"],
            body: canonicalJSON(body), clientAddress: "198.51.100.7")
        _ = try HostAPI.expect(await pending.relay.send(request), status: 200)
        pendingRetirement = nil
    }

    private func publishRotation(remaining: [(DemoKeys, [String])], relay: FakeRelay, session: RelaySession) async throws {
        try await retirePending(fallback: session)
        guard max(epoch, rotationEpoch) < UInt32.max else { throw Refusal.badEpoch }
        rotationEpoch = max(epoch, rotationEpoch) + 1
        let next = rotationEpoch
        // Allocate before any suspension, including a failure before the first upload.
        wks[next] = SymmetricKey(data: entropy.bytes(32))
        do {
            try await publishHook?()
            try await checkRotationRoster(remaining, relay: relay)
            endOpenStreams(newEpoch: next)
            listSeq += 1
            for (k, _) in remaining {
                try await relay.putGrant(try grant(for: k, epoch: next), token: currentRotationSession(relay, fallback: session).token)
                try await checkRotationRoster(remaining, relay: relay)
            }
            try await checkRotationRoster(remaining, relay: relay)
            try await relay.publishMemberList(try memberList(remaining.map { ($0.0.deviceID, $0.1) }, epoch: next, listSeq: max(listSeq, 2)), token: currentRotationSession(relay, fallback: session).token)
            installEpoch(next)
            setRoster(remaining)
        } catch {
            wks[next] = nil
            core.keys[next] = nil
            pendingRetirement = (relay, next)
            try? await retirePending(fallback: session)
            throw error
        }
        // A removal during the list actor hop needs a follow-up rotation. Keep this committed
        // epoch's grants available; the gate stays raised until the filtered roster is published.
        try await checkRotationRoster(remaining, relay: relay)
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
        case .pair(let reply, let h): return (try? respondPairing(to: h, reply: reply)) ?? []
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
        case "http", "drop_rewrap": return .some("look")
        case "decision": return .some("decide")
        case "new_ticket", "member_remove", "drop_claim": return .some("operate")
        case "revocation": return .some(nil)           // authority is PK's signature, not a scope
        default: return nil                            // unknown op
        }
    }

    private func run(_ a: HostAccepted) async -> HostReply {
        guard let op = a.meta.object?["op"]?.string, let need = requiredScope(op, meta: a.meta) else { return .refuse(.malformed) }
        if let need, !a.scopes.contains(need) { return .refuse(.forbiddenScope) }
        if op == "revocation" { return await applyRevocation(a) }
        let request = HostRequest(device: a.header.device, scopes: a.scopes, meta: a.meta, data: a.data, epoch: a.header.epoch)
        if op == "drop_rewrap" || op == "drop_claim" { return await handleDropRewrap(request) }
        if let handler { return await handler(request) }
        return handleView(request)
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

    /// Revocations use the same queue as public rotations; retries preserve every outstanding request.
    /// `rotationRequired` is cleared only after the queue succeeds.
    @discardableResult
    private func runRotation() async -> Bool {
        let task: Task<Void, Error>
        if !pendingRotations.isEmpty {
            task = drainRotations()
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
        if demoDropFixtures, !dropSeedComplete, epoch > 0, !rotationRequired {
            if dropSeedTask == nil { dropSeedTask = Task { try await self.seedDrop(relay: relay, transport: transport, session: session) } }
            do { try await dropSeedTask?.value; dropSeedComplete = true; dropSeedTask = nil }
            catch { dropSeedTask = nil; throw error }
        }
        refreshRotationSession(relay: relay, session: session)
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

extension FakeHost {
    /// The roster as published (device keys and scopes).
    public func rosterEntries() -> [(DemoKeys, [String])] { roster.values.map { ($0.keys, $0.scopes) } }
}
