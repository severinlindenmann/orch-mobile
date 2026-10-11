import CryptoKit
import Foundation
import Testing
import OrchClient
import OrchProtocol
import OrchStore
import OrchTestVectors
@testable import OrchFakeHost

/// Forwards to the real in-process transport; grant and member-list replies can be replaced by what a hostile relay would serve.
final class ReplayingTransport: RelayTransport, @unchecked Sendable {
    let inner: any RelayTransport
    private let lock = NSLock()
    private var grantsOverride: [JSONValue]?
    private var listOverride: JSONValue?
    init(_ inner: any RelayTransport) { self.inner = inner }
    func serveGrants(_ g: [JSONValue]?) { lock.withLock { grantsOverride = g } }
    func serveList(_ l: JSONValue?) { lock.withLock { listOverride = l } }
    private func reply(_ fields: [String: JSONValue]) throws -> WireReply {
        try WireReply(status: 200, headers: ["content-type": "application/json"], body: canonicalJSON(.object(fields)))
    }
    var context: RealmContext { inner.context }
    func challenge() async throws -> WireReply { try await inner.challenge() }
    func login(_ body: Data) async throws -> WireReply { try await inner.login(body) }
    func pairingPost(_ envelope: Data, route: PairRoute) async throws -> WireReply { try await inner.pairingPost(envelope, route: route) }
    func pairingPoll(route: PairRoute, after: UInt64?) async throws -> WireReply { try await inner.pairingPoll(route: route, after: after) }
    func bridgePost(_ envelope: Data, route: BridgeRoute, session: RelaySession) async throws -> WireReply { try await inner.bridgePost(envelope, route: route, session: session) }
    func bridgePoll(route: BridgeRoute, after: UInt64?, session: RelaySession) async throws -> WireReply { try await inner.bridgePoll(route: route, after: after, session: session) }
    func grants(workspaceID: ID16, epoch: UInt32?, session: RelaySession) async throws -> WireReply {
        if let g = lock.withLock({ grantsOverride }) { return try reply(["grants": .array(g)]) }
        return try await inner.grants(workspaceID: workspaceID, epoch: epoch, session: session)
    }
    func memberList(workspaceID: ID16, session: RelaySession) async throws -> WireReply {
        if let l = lock.withLock({ listOverride }) { return try reply(["member_list": l]) }
        return try await inner.memberList(workspaceID: workspaceID, session: session)
    }
    func card(workspaceID: ID16, session: RelaySession) async throws -> WireReply { try await inner.card(workspaceID: workspaceID, session: session) }
    func cardKey(workspaceID: ID16, cardSequence: UInt32, session: RelaySession) async throws -> WireReply {
        try await inner.cardKey(workspaceID: workspaceID, cardSequence: cardSequence, session: session)
    }
    func registerPush(_ body: Data, session: RelaySession) async throws -> WireReply { try await inner.registerPush(body, session: session) }
    func unregisterPush(_ body: Data, session: RelaySession) async throws -> WireReply { try await inner.unregisterPush(body, session: session) }
    func revocation(deviceID: ID16) async throws -> WireReply { try await inner.revocation(deviceID: deviceID) }
    func dropPut(objectID: ID16, ifMatch: UInt32, body: Data, session: RelaySession) async throws -> WireReply {
        try await inner.dropPut(objectID: objectID, ifMatch: ifMatch, body: body, session: session)
    }
    func dropList(_ query: Data, session: RelaySession) async throws -> WireReply { try await inner.dropList(query, session: session) }
    func dropGet(objectID: ID16, version: UInt32, part: DropPart, session: RelaySession) async throws -> WireReply {
        try await inner.dropGet(objectID: objectID, version: version, part: part, session: session)
    }
}

extension FakeHost {
    /// Tests: the host loses an uncommitted epoch's key (as after a refused publication).
    func forgetUncommittedKey(_ e: UInt32) { wks[e] = nil; core.keys[e] = nil; sealedGrants = sealedGrants.filter { $0.key.epoch != e } }
}

@Suite struct HostileRelayMembershipTests {
    /// S1: a hostile relay hands the phone the WSK-signed grant of a publication it refused (epoch 2, key K'). The phone keeps it
    /// unconfirmed; when the committed epoch-2 grant (key K) arrives with its list, the list's wk_commit picks K over K' (Q10).
    @Test func refusedBodysGrantDoesNotPinTheEpoch() async throws {
        let w = try await World.make()
        let hostile = ReplayingTransport(w.transport)
        let phone = try await w.makePhone(transport: hostile)
        let refused = try await w.host.grant(for: w.phone, epoch: 2)
        await w.host.forgetUncommittedKey(2)
        let g1 = try await RelayClient(transport: w.transport).grants(workspace: w.ws, session: w.phoneSession)
        hostile.serveGrants(g1 + [refused])
        #expect(try await phone.session.refreshGrants() == 1)               // stored, not confirmed by the epoch-1 list
        hostile.serveGrants(nil)
        try await w.host.rotate(remaining: w.baseRoster, relay: w.relay, session: w.hostSession)
        #expect(try await phone.session.refreshGrants() == 2)
        let stored = try #require(try w.vault.scoped(to: .demo).get(ws: w.ws.hex, purpose: "wk.2"))
        #expect(stored == (await w.host.wkFor(2)).withUnsafeBytes { Data($0) })
        // once a list commits epoch 2, no other key is ever kept for it
        await #expect(throws: SessionError.wkCommitMismatch(2)) { try await phone.session.install(epoch: 2, key: SymmetricKey(size: .bits256)) }
    }

    /// Q10 (formerly the S1 lockout gap): the hostile relay serves the refused key K' in the very refresh that brings the epoch-2
    /// list. The list's wk_commit names K, so K' is not kept and nothing is sealed (no_key, never a fallback to epoch 1); the next
    /// honest refresh brings K and the phone seals at epoch 2.
    @Test func refusedKeyServedWithTheConfirmingListIsNotPinned() async throws {
        let w = try await World.make()
        await w.host.setHandler { _ in .response(status: 200, headers: ["content-type": "application/json"], data: Data("ok".utf8)) }
        let hostile = ReplayingTransport(w.transport)
        let phone = try await w.makePhone(transport: hostile)
        let refused = try await w.host.grant(for: w.phone, epoch: 2)
        await w.host.forgetUncommittedKey(2)
        try await w.host.rotate(remaining: w.baseRoster, relay: w.relay, session: w.hostSession)
        let g1 = try await RelayClient(transport: w.transport).grants(workspace: w.ws, session: w.phoneSession).filter {
            $0.object?["o"]?.object?["epoch"] == .int(1)
        }
        hostile.serveGrants(g1 + [refused])
        // the epoch-2 list is held, its key is not: surfaced as a mismatch (an alarm in the App), never silently skipped
        await #expect(throws: SessionError.wkCommitMismatch(2)) { _ = try await phone.session.refreshGrants() }
        #expect(try await phone.session.currentEpoch() == 1)
        #expect(try await phone.container.memberListHead()?.epoch == 2)
        // sending tries ONE refetch, meets the same mismatch and seals nothing
        await #expect(throws: SessionError.wkCommitMismatch(2)) { _ = try await phone.session.exchange(meta: httpGet) }
        #expect(try await phone.session.pendingRequests().isEmpty)
        hostile.serveGrants(nil)
        #expect(try await phone.session.refreshGrants() == 2)
        let r = try await w.serve(phone) { try await phone.session.exchange(meta: httpGet) }
        #expect(r.status == 200)
    }

    /// Q10: two WSK-signed lists at one epoch with different wk_commit raise the durable local alarm; sending stops.
    @Test func twoCommitmentsAtOneEpochRaiseTheAlarm() async throws {
        let w = try await World.make()
        let phone = try await w.makePhone()
        let forked = try await w.host.memberList([(w.primaryID, World.all), (w.phoneID, ["look", "decide"])], epoch: 1, listSeq: 2,
                                                 wkCommit: WKCommit.compute(workspace: w.ws, epoch: 1, wk: SymmetricKey(size: .bits256)))
        await #expect(throws: Refusal.wkCommitConflict) { _ = try await phone.session.acceptMemberList(forked) }
        #expect(try await phone.session.wkCommitConflictEpoch() == 1)
        #expect(await phone.session.keyAlarm() == .conflict(epoch: 1))     // what the App reads at launch
        #expect(try await phone.container.memberListHead()?.listSeq == 1)   // nothing else was written
        // every later send names the alarm (not "no key, retry later")
        await #expect(throws: Refusal.wkCommitConflict) { _ = try await phone.session.exchange(meta: httpGet) }
        await #expect(throws: Refusal.wkCommitConflict) { _ = try await phone.session.exchange(meta: httpGet) }
        #expect(WorkspaceKeyAlarm(error: Refusal.wkCommitConflict) != nil && WorkspaceKeyAlarm(error: SessionError.wkCommitMismatch(2)) == .mismatch(epoch: 2))
        // an older list_seq with the other commitment is the same alarm (not merely stale_list)
        let older = try await w.host.memberList([(w.primaryID, World.all)], epoch: 1, listSeq: 1,
                                                wkCommit: WKCommit.compute(workspace: w.ws, epoch: 1, wk: SymmetricKey(size: .bits256)))
        await #expect(throws: Refusal.wkCommitConflict) { _ = try await phone.session.acceptMemberList(older) }
    }

    /// Phone-side enforcement (security review of #46): a later list at the head's epoch that drops a device is refused
    /// (rotation_required), and a listed person without a member device is other_person, before anything is recorded.
    @Test func phoneRefusesARemovalWithoutRotationAndAnUnboundPerson() async throws {
        let w = try await World.make()
        let phone = try await w.makePhone()
        let dropped = try await w.host.memberList([(w.phoneID, ["look", "decide"])], epoch: 1, listSeq: 2)
        await #expect(throws: Refusal.rotationRequired) { _ = try await phone.session.acceptMemberList(dropped) }
        let unbound = try await w.host.memberList([(w.primaryID, World.all), (w.phoneID, ["look", "decide"])], epoch: 1, listSeq: 2,
                                                  persons: [ID16.random()])
        await #expect(throws: Refusal.otherPerson) { _ = try await phone.session.acceptMemberList(unbound) }
        #expect(try await phone.container.memberListHead()?.listSeq == 1)
        // with the bump it is a rotation, accepted
        let rotated = try await w.host.memberList([(w.phoneID, ["look", "decide"])], epoch: 2, listSeq: 2)
        #expect(try await phone.session.acceptMemberList(rotated).epoch == 2)
    }

    /// S2: the phone persists the head of the last list it accepted and refuses a rollback, even at the same epoch.
    @Test func phoneRefusesAnOlderOrConflictingList() async throws {
        let w = try await World.make()
        let hostile = ReplayingTransport(w.transport)
        let phone = try await w.makePhone(transport: hostile)
        let list1 = try await RelayClient(transport: w.transport).memberList(workspace: w.ws, session: w.phoneSession)
        _ = try await phone.session.acceptMemberList(list1)
        let k = DemoKeys(sig: SoftwareSigner().publicKey, kx: SoftwareKeyAgreer().publicKey)
        try await w.relay.publishCertificate(try await w.primary.certify(k, label: "X", scopesMax: ["look"]))
        try await w.publish(w.baseRoster + [(k, ["look"])], epoch: 1, listSeq: 2)
        let list2 = try await RelayClient(transport: w.transport).memberList(workspace: w.ws, session: w.phoneSession)
        _ = try await phone.session.acceptMemberList(list2)
        _ = try await phone.session.acceptMemberList(list2)                    // the same list again: fine
        await #expect(throws: Refusal.staleList) { _ = try await phone.session.acceptMemberList(list1) }
        let other = try await w.host.memberList([(w.primaryID, World.all), (w.phoneID, ["look", "decide"])], epoch: 1, listSeq: 2)
        await #expect(throws: Refusal.conflictingSnapshot) { _ = try await phone.session.acceptMemberList(other) }
        // and the grant refresh path uses the same check
        hostile.serveList(list1)
        let refused = try await w.host.grant(for: w.phone, epoch: 2)
        let g1 = try await RelayClient(transport: w.transport).grants(workspace: w.ws, session: w.phoneSession)
        hostile.serveGrants(g1 + [refused])
        await #expect(throws: Refusal.staleList) { _ = try await phone.session.refreshGrants() }
        #expect(try await phone.session.currentEpoch() == 1)
    }

    /// Upgrade path (migration 12): a v11 store has a head list without `wk_commit` and no commitments. The migration drops that head
    /// (the host's re-issued list under the same list_seq would otherwise be a permanent conflicting_snapshot) and the first send
    /// recovers with one bounded list + grants fetch instead of failing with no_key until a stale_epoch or a Drop fetch.
    @Test func aV11StoreRecoversOnTheFirstSend() async throws {
        let w = try await World.make()
        await w.host.setHandler { _ in .response(status: 200, headers: ["content-type": "application/json"], data: Data("ok".utf8)) }
        let phone = try await w.makePhone()
        let db = try await phone.container.database()
        // back to schema 11: no wk_commits, no member set, and a pre-Q10 head (digest of a list without wk_commit) at list_seq 1
        try await db.execute("DROP TABLE wk_commits")
        try await db.execute("ALTER TABLE member_list_head DROP COLUMN members")
        try await db.execute("UPDATE member_list_head SET digest=?", [.blob(Data(repeating: 7, count: 32))])
        try await db.execute("DELETE FROM schema_migrations WHERE version=12")
        await phone.container.suspend()
        try await phone.container.resume()                                   // migration 12 runs
        #expect(try await phone.container.memberListHead() == nil)
        #expect(try await phone.container.epochHighWater() == 1)             // the confirmed epoch is kept
        let cfg = WorkspaceSessionConfig(context: w.env.context, workspace: w.ws, generation: 1, identity: w.env.device, wsk: w.host.wskPublic,
                                         container: phone.container, vault: w.vault.scoped(to: .demo), transport: w.env.transport,
                                         clock: phone.clock, wall: phone.clock)
        let upgraded = Phone(session: try await WorkspaceSession(cfg), container: phone.container, clock: phone.clock)
        let r = try await w.serve(upgraded) { try await upgraded.session.exchange(meta: httpGet) }
        #expect(r.status == 200)
        #expect(try await phone.container.memberListHead()?.listSeq == 1)    // the re-issued list, accepted as the new head
        #expect(try await phone.container.wkCommit(epoch: 1) != nil)
    }

    /// The local Q10 snapshot vectors, through the code the device runs (`acceptMemberList` and the persisted head), not only the pure
    /// `MemberList.checkSnapshot`. TODO(G2b): use orch-relay's `member_list_snapshots`.
    @Test func localSnapshotVectorsThroughTheSession() async throws {
        let local = try StrictJSON.parse(LocalG2bVectors.data, maxBytes: .max)
        let cases = local.object!["member_list_snapshots"]!.array!
        #expect(cases.count == 10)
        for c in cases {
            let co = c.object!, name = co["name"]!.string!
            let w = try await World.make()
            let phone = try await w.makePhone(install: false)
            func signed(_ l: JSONValue) async throws -> JSONValue {
                let o = l.object!
                return try await w.host.memberList(o["members"]!.array!.map { (ID16(hex: $0.string!)!, ["look"]) }, epoch: UInt32(o["epoch"]!.int!),
                                                   listSeq: o["list_seq"]!.int!, wkCommit: B64U.decode(o["wk_commit"]!.string!)!)
            }
            if let k = co["known"], k != .null { _ = try await phone.session.acceptMemberList(try await signed(k)) }
            let next = co["next"]! == co["known"] ? try await signed(co["known"]!) : try await signed(co["next"]!)
            let want = co["expect"]!.string!
            do { _ = try await phone.session.acceptMemberList(next); #expect(want == "ok", "\(name)") }
            catch let r as Refusal { #expect(r.rawValue == want, "\(name)") }
        }
    }
}
