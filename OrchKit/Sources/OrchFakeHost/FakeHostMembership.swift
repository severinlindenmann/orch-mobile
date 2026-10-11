import CryptoKit
import Foundation
import OrchClient
import OrchProtocol

/// The host side of atomic membership publication (protocol-v2 P3-D7, section 19.7). A publication is the signed list, a grant
/// for every member at its epoch, and optionally card-key wraps, sent as one `PUT /v2/workspaces/{ws}/membership`. The host
/// persists the key and the exact sealed bytes before sending and only ever resends those bytes; a reply that is lost leaves the
/// outcome open, so the next attempt resends rather than reseals. Only a refusal of the checks proves nothing was committed.
public enum MembershipPublicationError: Error, Equatable, Sendable {
    /// The relay holds a list this host did not publish (or acceptance cannot be established): surfaced, never assumed (section 19.7).
    case conflict
}

extension FakeHost {
    struct PendingPublication: Sendable {
        /// `cj(body)`: the exact HTTP body, resent byte for byte (replaced only after a refusal proved it was not committed).
        var raw: Data
        let memberList: JSONValue
        let listSeq: Int64
        let epoch: UInt32
        let roster: [(DemoKeys, [String])]
        /// The devices the body wraps `CK` to, and the card sequence of those wraps (nil: no wraps).
        var wraps: [DemoKeys] = []
        var wrapSeq: UInt32?
        /// Set (durably, in a real host) immediately before the first send. Until then the bytes never left the host.
        var sent = false
    }

    /// Refusal codes that say nothing about the body (session, holder, budget): the publication stays pending for an identical resend.
    static let undecided: Set<RelayRefusal.Code> = [.unauthenticated, .fenced, .notEligible, .rateLimited, .quotaExceeded, .overloaded, .unknownWorkspace]

    /// `WK_e` sealed to a device once; every later publication at `e` carries these exact bytes (no `grant_conflict` on a resend).
    func persistedGrant(for keys: DemoKeys, epoch e: UInt32) throws -> JSONValue {
        let k = MemberList.Directory.GrantKey(device: keys.deviceID, epoch: e)
        if let g = sealedGrants[k] { return g }
        let g = try grant(for: keys, epoch: e)
        sealedGrants[k] = g
        return g
    }

    func persistedWrap(for keys: DemoKeys, cardSeq seq: UInt32) throws -> String {
        if let w = sealedWraps[keys.deviceID]?[seq] { return w }
        let w = B64U.encode(try cardKeyWrap(for: keys, cardSeq: seq))
        sealedWraps[keys.deviceID, default: [:]][seq] = w
        return w
    }

    /// The publication body for `roster` at `epoch` with the next `list_seq`: every member's grant and the wraps of `wraps`.
    package func membershipBody(roster: [(DemoKeys, [String])], epoch e: UInt32, listSeq seq: Int64, wraps: [DemoKeys] = [],
                                listScopes: [ID16: [String]] = [:]) throws -> JSONValue {
        let list = try memberList(roster.map { ($0.0.deviceID, listScopes[$0.0.deviceID] ?? $0.1) }, epoch: e, listSeq: seq)
        let grants = try roster.sorted { $0.0.deviceID.hex < $1.0.deviceID.hex }.map { try persistedGrant(for: $0.0, epoch: e) }
        var body: [String: JSONValue] = ["member_list": list, "grants": .array(grants)]
        if !wraps.isEmpty {
            let seq = max(cardSeq, 1)
            let items: [JSONValue] = try wraps.sorted { $0.deviceID.hex < $1.deviceID.hex }.map {
                ["device_id": .string($0.deviceID.hex), "sealed": .string(try persistedWrap(for: $0, cardSeq: seq))]
            }
            body["card_key_wraps"] = ["card_seq": .int(Int64(seq)), "wraps": .array(items)]
        }
        return .object(body)
    }

    /// Builds and persists the next publication (`list_seq + 1`). `WK_e` must already be persisted (`wk(e)` creates it).
    func preparePublication(roster: [(DemoKeys, [String])], epoch e: UInt32, wraps: [DemoKeys]) throws -> PendingPublication {
        let body = try membershipBody(roster: roster, epoch: e, listSeq: listSeq + 1, wraps: wraps)
        guard let list = body.object?["member_list"] else { throw Refusal.malformed }
        let p = PendingPublication(raw: try canonicalJSON(body), memberList: list, listSeq: listSeq + 1, epoch: e, roster: roster,
                                   wraps: wraps, wrapSeq: wraps.isEmpty ? nil : max(cardSeq, 1))
        pendingPublication = p
        return p
    }

    /// Renews this host's holder generation, or takes a new one (the Demo host is the only writer).
    func holderGeneration(relay: FakeRelay, session: RelaySession) async throws -> UInt64 {
        if let g = holderGen, let renewed = try? await relay.hold(workspace: workspace, token: session.token, gen: g) { return renewed }
        let g = try await relay.hold(workspace: workspace, token: session.token, gen: nil, takeOver: true)
        holderGen = g
        return g
    }

    /// One HTTP `PUT membership` of exactly `raw`, under the current holder generation.
    func putMembership(_ raw: Data, relay: FakeRelay, session: RelaySession) async throws -> WireReply {
        let gen = try await holderGeneration(relay: relay, session: session)
        return try await relay.send(WireRequest(method: "PUT", target: "\(HostAPI.base)/workspaces/\(workspace.hex)/membership",
                                                headers: ["authorization": "Bearer \(session.token)", "orch-holder": String(gen),
                                                          "content-type": "application/json"],
                                                body: raw, clientAddress: "198.51.100.7"))
    }

    /// Tests: sends any body (not the pending slot) and throws the relay's refusal. Host state is the caller's to keep in step.
    @discardableResult
    package func sendMembership(_ body: JSONValue, relay: FakeRelay, session: RelaySession) async throws -> (listSeq: Int64, epoch: UInt32) {
        let o = try HostAPI.object(try HostAPI.expect(try await putMembership(try canonicalJSON(body), relay: relay, session: session)))
        guard let seq = o["list_seq"]?.int, let e = o["epoch"]?.int, let epoch = UInt32(exactly: e) else { throw ClientError.badReply }
        return (seq, epoch)
    }

    /// The relay's current signed list, read over the workspace session (section 19.7 reconciliation).
    func relayMemberList(relay: FakeRelay, session: RelaySession) async throws -> JSONValue {
        let reply = try await relay.send(WireRequest(method: "GET", target: "\(HostAPI.base)/workspaces/\(workspace.hex)/members",
                                                     headers: ["authorization": "Bearer \(session.token)"], clientAddress: "198.51.100.7"))
        return try HostAPI.memberList(try HostAPI.expect(reply))
    }

    /// Sends the pending publication's exact bytes. Returns once they are committed, now or by an earlier send whose answer was
    /// lost, and installs what they commit. A refusal of the checks discards them (nothing was committed) together with an
    /// uncommitted epoch's key, so a later publication seals a fresh one; anything else keeps them for an identical resend.
    @discardableResult
    func sendPending(relay: FakeRelay, session: RelaySession) async throws -> PendingPublication? {
        guard var p = pendingPublication else { return nil }
        p.sent = true
        pendingPublication = p
        let reply = try await putMembership(p.raw, relay: relay, session: session)
        if reply.status == 200 {
            let o = try HostAPI.object(reply.body)
            if o["list_seq"] == .int(p.listSeq), o["epoch"] == .int(Int64(p.epoch)) { installCommitted(p); return p }
            // An answer for other values than these bytes carry: settle it from the relay's signed list, never sticky.
            return try await reconcile(p, relay: relay, session: session)
        }
        let failure = HostAPI.failure(of: reply)
        guard case .relay(let r) = failure else { throw failure }
        if Self.undecided.contains(r.code) { throw failure }
        if r.code == .staleList { return try await reconcile(p, relay: relay, session: session) }
        // Q10: only the wraps were wrong. The same signed list and grants go again with fixed wraps; no epoch is burned.
        if r.code == .staleCard || r.code == .wrapConflict, let fixed = try rewrapped(p, code: r.code) {
            pendingPublication = fixed
            return try await sendPending(relay: relay, session: session)
        }
        discardRefused(p, code: r.code)
        throw failure
    }

    /// The refused publication with the same `member_list` and grants and fixed card-key wraps: re-wrapped at this host's card
    /// sequence after `stale_card` when that moved on, otherwise without wraps (the relay keeps the wraps it holds; `wrap_conflict`
    /// says it holds other bytes for one of them). Nil when there is nothing to fix.
    private func rewrapped(_ p: PendingPublication, code: RelayRefusal.Code) throws -> PendingPublication? {
        guard let old = p.wrapSeq, var body = try StrictJSON.parse(p.raw, maxBytes: .max).object else { return nil }
        var q = p
        q.sent = false
        let seq = max(cardSeq, 1)
        if code == .staleCard, seq != old {
            let items: [JSONValue] = try p.wraps.sorted { $0.deviceID.hex < $1.deviceID.hex }.map {
                ["device_id": .string($0.deviceID.hex), "sealed": .string(try persistedWrap(for: $0, cardSeq: seq))]
            }
            body["card_key_wraps"] = ["card_seq": .int(Int64(seq)), "wraps": .array(items)]
            q.wrapSeq = seq
        } else {
            body["card_key_wraps"] = nil
            q.wraps = []; q.wrapSeq = nil
        }
        q.raw = try canonicalJSON(.object(body))
        return q
    }

    /// Section 19.7: after a lost response the relay may hold exactly this list (its receipt expired): compare the signed lists.
    /// If it holds another (newer) list, these bytes can never commit: they are discarded with their uncommitted key, the relay's
    /// `list_seq` and epoch become the floor of the next publication (a fresh sequence and epoch), and the conflict is surfaced once.
    private func reconcile(_ p: PendingPublication, relay: FakeRelay, session: RelaySession) async throws -> PendingPublication {
        let current = try await relayMemberList(relay: relay, session: session)
        if current == p.memberList { installCommitted(p); return p }
        discardRefused(p, code: nil)
        // Only a list above every list_seq this host used can be newer: a relay replaying one of this host's own earlier refused (still
        // WSK-signed) lists cannot push the floors up, because `discardRefused` already raised them past it (Q10).
        if let other = try? MemberList.verify(current, wsk: wskPublic), other.listSeq > listSeq {
            listSeq = other.listSeq
            relayEpochFloor = max(relayEpochFloor, other.epoch)
        }
        throw MembershipPublicationError.conflict
    }

    private func installCommitted(_ p: PendingPublication) {
        pendingPublication = nil
        listSeq = max(listSeq, p.listSeq)
        relayEpochFloor = 0                          // the relay now holds this host's list
        if p.epoch != epoch { installEpoch(p.epoch) }
        // A member revoked or removed while these bytes were in flight is not re-added locally; the gate stays up and the next
        // rotation publishes without it.
        setRoster(p.roster.filter { !rotationRemoved.contains($0.0.deviceID) && !core.revoked.contains($0.0.deviceID) })
    }

    /// The relay saw these bytes and refused them (or holds another list). Q10, one `WK` per epoch, ever: an epoch above the current
    /// one is burned, never resealed. Its key stays as a retained, never-activated key (it answers a section 8.5 `stale_epoch` to a
    /// phone that sealed under it), the next publication's `list_seq` and epoch go above this one's (`listSeq` floor `p.listSeq`, epoch
    /// floor `p.epoch`, so a rotation goes to `floor + 1`), and nothing sealed to the refused roster is ever activated. A refusal of
    /// an addition at the current epoch because a member's certificate is revoked or invalid means grants of the current `WK` went out
    /// to it: the gate goes up and the next pump rotates.
    private func discardRefused(_ p: PendingPublication, code: RelayRefusal.Code?) {
        pendingPublication = nil
        listSeq = max(listSeq, p.listSeq)
        if p.epoch > epoch {
            if let k = wks[p.epoch] { core.keys[p.epoch] = k }
            relayEpochFloor = max(relayEpochFloor, p.epoch)
        } else if p.epoch == epoch, let code, [.revoked, .certInvalid, .certExpired].contains(code) {
            rotationRequired = true
        }
    }

    /// An earlier publication that may have left the host is settled first: resent byte for byte (committed or refused). One that
    /// never left is simply dropped; its key never left the host either.
    /// Returns the publication it committed, if any.
    @discardableResult
    func resolvePending(relay: FakeRelay, session: RelaySession) async throws -> PendingPublication? {
        guard let p = pendingPublication else { return nil }
        guard p.sent else { pendingPublication = nil; return nil }
        return try await sendPending(relay: relay, session: session)
    }

    /// Publishes `roster` at `epoch` (creating and persisting `WK_epoch` if needed) after settling any earlier publication, and
    /// installs it. Serialized with every other publication of this host.
    func publishMembership(roster: [(DemoKeys, [String])], epoch e: UInt32, wraps: [DemoKeys], relay: FakeRelay, session: RelaySession) async throws {
        try await withPublicationLock {
            try await resolvePending(relay: relay, session: session)
            _ = wk(e)
            _ = try preparePublication(roster: roster, epoch: e, wraps: wraps)
            try await sendPending(relay: relay, session: session)
        }
    }

    /// A join: the roster as it stands once this publication's turn comes (after any rotation), plus `adding` (nil when a hostile
    /// host leaves the device out), at the then-current epoch. Returns the roster it published.
    @discardableResult
    func publishJoin(adding: (DemoKeys, [String])?, wraps: [DemoKeys], relay: FakeRelay, session: RelaySession) async throws -> [(DemoKeys, [String])] {
        try await withPublicationLock {
            try await resolvePending(relay: relay, session: session)
            var members = roster.values.filter { $0.keys.deviceID != adding?.0.deviceID }.map { ($0.keys, $0.scopes) }
            if let adding { members.append(adding) }
            // Behind a relay list this host did not publish: a fresh epoch above it (its key is unknown here).
            let e = relayEpochFloor > epoch ? relayEpochFloor + 1 : epoch
            _ = wk(e)
            _ = try preparePublication(roster: members, epoch: e, wraps: wraps)
            try await sendPending(relay: relay, session: session)
            return members
        }
    }

    /// FIFO: the lock is handed directly to the longest waiter, so no later caller can barge in between.
    func withPublicationLock<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        if publicationLocked { await withCheckedContinuation { publicationWaiters.append($0) } }   // resumed holding the lock
        else { publicationLocked = true }
        defer {
            if publicationWaiters.isEmpty { publicationLocked = false } else { publicationWaiters.removeFirst().resume() }
        }
        return try await body()
    }

    /// Tests: the publication persisted but not yet committed.
    package func pendingPublicationState() -> (listSeq: Int64, epoch: UInt32, sent: Bool, raw: Data)? {
        pendingPublication.map { ($0.listSeq, $0.epoch, $0.sent, $0.raw) }
    }
}
