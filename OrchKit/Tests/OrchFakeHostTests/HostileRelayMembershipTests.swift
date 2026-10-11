import CryptoKit
import Foundation
import Testing
import OrchClient
import OrchProtocol
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
    /// unconfirmed; when the committed epoch-2 grant (key K) arrives with its list, K replaces K' instead of locking the phone out.
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
        // once confirmed, another key for epoch 2 is a conflict again
        await #expect(throws: SessionError.grantConflict) { try await phone.session.install(epoch: 2, key: SymmetricKey(size: .bits256)) }
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
}
