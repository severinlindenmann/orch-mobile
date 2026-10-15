import Foundation
import OrchClient
import OrchProtocol

/// The only transport a Demo context can have: the client's real byte path (`RoutedRelayTransport`) into `FakeRelay`, in the
/// same process. Construction fails, before any request, for a live context, a live relay or an origin the context does not admit.
public struct InProcessRelayTransport: RelayTransport {
    let inner: RoutedRelayTransport<FakeRelay>

    public init(context: RealmContext, relay: FakeRelay, clientAddress: String = "198.51.100.7") throws {
        guard context.realm == .demo, relay.context.realm == .demo, relay.origin == context.origin else {
            throw TransportError.realm(.wrongTransport)
        }
        inner = try RoutedRelayTransport(context: context, origin: relay.origin, sender: relay, clientAddress: clientAddress)
    }

    public var context: RealmContext { inner.context }

    public func challenge() async throws -> WireReply { try await inner.challenge() }
    public func login(_ body: Data) async throws -> WireReply { try await inner.login(body) }
    public func pairingPost(_ envelope: Data, route: PairRoute) async throws -> WireReply { try await inner.pairingPost(envelope, route: route) }
    public func pairingPoll(route: PairRoute, after: UInt64?, wait: Int?) async throws -> WireReply { try await inner.pairingPoll(route: route, after: after, wait: wait) }
    public func bridgePost(_ envelope: Data, route: BridgeRoute, session: RelaySession) async throws -> WireReply {
        try await inner.bridgePost(envelope, route: route, session: session)
    }
    public func bridgePoll(route: BridgeRoute, after: UInt64?, wait: Int?, session: RelaySession) async throws -> WireReply {
        try await inner.bridgePoll(route: route, after: after, wait: wait, session: session)
    }
    public func grants(workspaceID: ID16, epoch: UInt32?, session: RelaySession) async throws -> WireReply {
        try await inner.grants(workspaceID: workspaceID, epoch: epoch, session: session)
    }
    public func memberList(workspaceID: ID16, session: RelaySession) async throws -> WireReply { try await inner.memberList(workspaceID: workspaceID, session: session) }
    public func card(workspaceID: ID16, session: RelaySession) async throws -> WireReply { try await inner.card(workspaceID: workspaceID, session: session) }
    public func cardKey(workspaceID: ID16, cardSequence: UInt32, session: RelaySession) async throws -> WireReply {
        try await inner.cardKey(workspaceID: workspaceID, cardSequence: cardSequence, session: session)
    }
    public func logout(session: RelaySession) async throws -> WireReply { try await inner.logout(session: session) }
    public func registerPush(_ body: Data, session: RelaySession) async throws -> WireReply { try await inner.registerPush(body, session: session) }
    public func unregisterPush(_ body: Data, session: RelaySession) async throws -> WireReply { try await inner.unregisterPush(body, session: session) }
    public func revocation(deviceID: ID16, after: String?, limit: Int?) async throws -> WireReply { try await inner.revocation(deviceID: deviceID, after: after, limit: limit) }
    public func dropPut(objectID: ID16, ifMatch: UInt32, body: Data, session: RelaySession) async throws -> WireReply {
        try await inner.dropPut(objectID: objectID, ifMatch: ifMatch, body: body, session: session)
    }
    public func dropList(_ query: Data, session: RelaySession) async throws -> WireReply { try await inner.dropList(query, session: session) }
    public func certRequests(person: ID16, wait: Int?, session: RelaySession) async throws -> WireReply {
        try await inner.certRequests(person: person, wait: wait, session: session)
    }
    public func postCertChallenge(requestID: ID16, _ body: Data, session: RelaySession) async throws -> WireReply {
        try await inner.postCertChallenge(requestID: requestID, body, session: session)
    }
    public func postCertRejection(requestID: ID16, _ body: Data, session: RelaySession) async throws -> WireReply {
        try await inner.postCertRejection(requestID: requestID, body, session: session)
    }
    public func createAccount(_ body: Data) async throws -> WireReply { try await inner.createAccount(body) }
    public func dropGet(objectID: ID16, version: UInt32, part: DropPart, session: RelaySession) async throws -> WireReply {
        try await inner.dropGet(objectID: objectID, version: version, part: part, session: session)
    }
}
