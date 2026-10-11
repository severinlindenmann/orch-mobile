import Foundation
import OrchProtocol

/// The one implementation of `RelayTransport`: it spells every call as an HTTP request (protocol-v2 section 19) and
/// hands it to a `RequestSender`. A future HTTPS client is a sender; the in-process FakeRelay is another. The realm
/// context and origin are fixed at construction; every call re-checks them before the sender is touched.
public struct RoutedRelayTransport<Sender: RequestSender>: RelayTransport {
    public let context: RealmContext
    /// The origin `context` admitted at construction. Every send re-admits it and requires the sender to still be on it.
    let origin: String
    let sender: Sender
    let clientAddress: String

    /// `origin` is the origin this transport talks to; it must be admitted by `context` or construction throws, so a
    /// transport for an external origin cannot exist in a Demo context.
    package init(context: RealmContext, origin: String, sender: Sender, clientAddress: String) throws {
        try context.admit(origin: origin)
        guard sender.origin == origin else { throw TransportError.realm(.externalOrigin) }
        self.context = context; self.origin = origin; self.sender = sender; self.clientAddress = clientAddress
    }

    private var R: String { HostAPI.base }

    private func request(_ method: String, _ target: String, body: Data = Data(), contentType: String? = nil,
                         session: RelaySession? = nil, extra: [String: String] = [:]) throws -> WireRequest {
        var h = extra
        if let ct = contentType { h["content-type"] = ct }
        if let s = session { h["authorization"] = "Bearer " + (try Self.checked(s.token)) }
        return try WireRequest(method: method, target: target, headers: h, body: body, clientAddress: clientAddress)
    }

    /// A bearer token is visible ASCII with no space: it goes into a header and must not smuggle another.
    static func checked(_ token: String) throws -> String {
        guard !token.isEmpty, token.utf8.count <= 512, token.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { throw TransportError.invalidArgument }
        return token
    }

    private func send(_ r: WireRequest) async throws -> WireReply {
        do {
            try context.generation?.check()
            try context.admit(origin: origin)
            try context.admit(origin: sender.origin)
        } catch let v as RealmViolation { throw TransportError.realm(v) }
        try Task.checkCancellation()
        return try await sender.send(r)
    }

    private func json(_ method: String, _ path: String, _ body: Data, session: RelaySession? = nil) async throws -> WireReply {
        try await send(request(method, R + path, body: body, contentType: "application/json", session: session))
    }

    private func octets(_ method: String, _ target: String, _ body: Data, session: RelaySession? = nil, extra: [String: String] = [:]) async throws -> WireReply {
        try await send(request(method, target, body: body, contentType: "application/octet-stream", session: session, extra: extra))
    }

    private func get(_ target: String, session: RelaySession? = nil) async throws -> WireReply {
        try await send(request("GET", target, session: session))
    }

    public func challenge() async throws -> WireReply { try await json("POST", "/session/challenge", HostAPI.json()) }
    public func login(_ body: Data) async throws -> WireReply { try await json("POST", "/session/login", body) }

    public func pairingPost(_ envelope: Data, route: PairRoute) async throws -> WireReply {
        try await octets("POST", "\(R)/workspaces/\(route.workspaceID.hex)/pair/\(route.offerID.hex)/\(route.requestID.hex)", envelope)
    }

    public func pairingPoll(route: PairRoute, after: UInt64?) async throws -> WireReply {
        try await get("\(R)/workspaces/\(route.workspaceID.hex)/pair/\(route.offerID.hex)/\(route.requestID.hex)" + Self.after(after))
    }

    public func bridgePost(_ envelope: Data, route: BridgeRoute, session: RelaySession) async throws -> WireReply {
        try await octets("POST", "\(R)/workspaces/\(route.workspaceID.hex)/bridge/\(route.requestID.hex)", envelope, session: session)
    }

    public func bridgePoll(route: BridgeRoute, after: UInt64?, session: RelaySession) async throws -> WireReply {
        try await get("\(R)/workspaces/\(route.workspaceID.hex)/bridge/\(route.requestID.hex)" + Self.after(after), session: session)
    }

    static func after(_ cursor: UInt64?) -> String { cursor.map { "?after=" + HostAPI.decimal($0) } ?? "" }

    public func grants(workspaceID: ID16, epoch: UInt32?, session: RelaySession) async throws -> WireReply {
        // Epoch 0 is reserved for pairing envelopes: refuse before any I/O, before even looking at the session.
        if let e = epoch, e < 1 { throw TransportError.invalidEpoch }
        return try await get("\(R)/workspaces/\(workspaceID.hex)/grants" + (epoch.map { "?epoch=\($0)" } ?? ""), session: session)
    }

    public func memberList(workspaceID: ID16, session: RelaySession) async throws -> WireReply {
        try await get("\(R)/workspaces/\(workspaceID.hex)/members", session: session)
    }

    public func card(workspaceID: ID16, session: RelaySession) async throws -> WireReply {
        try await get("\(R)/workspaces/\(workspaceID.hex)/card", session: session)
    }

    public func cardKey(workspaceID: ID16, cardSequence: UInt32, session: RelaySession) async throws -> WireReply {
        guard cardSequence >= 1 else { throw TransportError.invalidEpoch }
        return try await get("\(R)/workspaces/\(workspaceID.hex)/card-key?card_seq=\(cardSequence)", session: session)
    }

    public func registerPush(_ body: Data, session: RelaySession) async throws -> WireReply { try await json("POST", "/push/register", body, session: session) }
    public func unregisterPush(_ body: Data, session: RelaySession) async throws -> WireReply { try await json("POST", "/push/unregister", body, session: session) }

    public func revocation(deviceID: ID16) async throws -> WireReply {
        try await get("\(R)/devices/\(deviceID.hex)/revocation")
    }

    public func dropPut(objectID: ID16, ifMatch: UInt32, body: Data, session: RelaySession) async throws -> WireReply {
        // TODO(orch-4e): Drop routes are not in protocol-v2 section 19 yet; the open question is whether they stay under /v2 or keep
        // their section 10.6 spelling. Until that is decided this one keeps its un-prefixed path and the others sit under /v2.
        try await send(request("PUT", "/drop/\(objectID.hex)/versions", body: body, contentType: "application/json", session: session,
                               extra: ["if-match": String(ifMatch)]))
    }

    public func dropList(_ query: Data, session: RelaySession) async throws -> WireReply { try await json("POST", "/drop/list", query, session: session) }

    public func dropGet(objectID: ID16, version: UInt32, part: DropPart, session: RelaySession) async throws -> WireReply {
        try await get("\(R)/drop/\(objectID.hex)/versions/\(version)/\(part.rawValue)", session: session)
    }
}
