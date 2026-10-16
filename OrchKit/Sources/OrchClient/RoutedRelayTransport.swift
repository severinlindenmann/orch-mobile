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
    ///
    /// A `.demo` context is refused (`RealmViolation.wrongTransport`) unless the sender is an `InProcessDemoSender` (the in-process FakeRelay
    /// and the test doubles that stand in for it): no sender that reaches a network can serve a Demo realm, so a Demo key or event can never
    /// travel over one. The same fact decides which `WritePermit` `bridgePost` takes (see there).
    package init(context: RealmContext, origin: String, sender: Sender, clientAddress: String) throws {
        if context.realm == .demo, !(sender is any InProcessDemoSender) { throw TransportError.realm(.wrongTransport) }
        try context.admit(origin: origin)
        guard sender.origin == origin else { throw TransportError.realm(.externalOrigin) }
        self.context = context; self.origin = origin; self.sender = sender; self.clientAddress = clientAddress
    }

    private var R: String { HostAPI.base }

    private func request(_ method: String, _ target: String, body: Data = Data(), contentType: String? = nil,
                         session: RelaySession? = nil, extra: [String: String] = [:], bodyFile: URL? = nil,
                         options: RequestOptions = RequestOptions()) throws -> WireRequest {
        var h = extra
        if let ct = contentType { h["content-type"] = ct }
        if let s = session { h["authorization"] = "Bearer " + (try Self.checked(s.token)) }
        return try WireRequest(method: method, target: target, headers: h, body: body, clientAddress: clientAddress, bodyFile: bodyFile, options: options)
    }

    /// A bearer token is visible ASCII with no space: it goes into a header and must not smuggle another.
    static func checked(_ token: String) throws -> String {
        guard !token.isEmpty, token.utf8.count <= 512, token.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { throw TransportError.invalidArgument }
        return token
    }

    private func send(_ r: WireRequest) async throws -> WireReply {
        do {
            try context.generation.check()
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

    private func get(_ target: String, session: RelaySession? = nil, options: RequestOptions = RequestOptions()) async throws -> WireReply {
        try await send(request("GET", target, session: session, options: options))
    }

    public func challenge() async throws -> WireReply { try await json("POST", "/session/challenge", HostAPI.json()) }
    public func login(_ body: Data) async throws -> WireReply { try await json("POST", "/session/login", body) }

    public func pairingPost(_ envelope: Data, route: PairRoute) async throws -> WireReply {
        try await octets("POST", "\(R)/workspaces/\(route.workspaceID.hex)/pair/\(route.offerID.hex)/\(route.requestID.hex)", envelope)
    }

    public func pairingPoll(route: PairRoute, after: UInt64?, wait: Int?) async throws -> WireReply {
        try await get("\(R)/workspaces/\(route.workspaceID.hex)/pair/\(route.offerID.hex)/\(route.requestID.hex)" + (try Self.pollQuery(after: after, wait: wait)))
    }

    /// A write permit is checked before anything is sealed into a request: it must belong to this context's lifetime and realm, and the
    /// credential it was minted for must be the one this kind of sender may carry. A sender that reaches a network takes only a live,
    /// `secure-enclave-unlocked` permit; the in-process Demo sender only a Demo `passphrase` one. Anything else is refused and the sender is
    /// never touched.
    public func bridgePost(_ envelope: Data, route: BridgeRoute, session: RelaySession, permit: WritePermit?) async throws -> WireReply {
        if let permit {
            guard permit.generation === context.generation, permit.realm == context.realm else { throw TransportError.realm(.wrongStore) }
            if sender is any InProcessDemoSender {
                guard context.realm == .demo, permit.auth == .passphrase else { throw TransportError.realm(.wrongTransport) }
            } else {
                guard context.realm == .live, permit.auth == .secureEnclaveUnlocked else { throw TransportError.realm(.wrongTransport) }
            }
        }
        return try await octets("POST", "\(R)/workspaces/\(route.workspaceID.hex)/bridge/\(route.requestID.hex)", envelope, session: session)
    }

    /// The sender object's identity when it is an in-process Demo sender of a class type (the FakeRelay actor); otherwise nil.
    public var processLocalSender: ObjectIdentifier? {
        guard sender is any InProcessDemoSender, Sender.self is AnyObject.Type else { return nil }
        return ObjectIdentifier(sender as AnyObject)
    }

    public func bridgePoll(route: BridgeRoute, after: UInt64?, wait: Int?, session: RelaySession) async throws -> WireReply {
        try await get("\(R)/workspaces/\(route.workspaceID.hex)/bridge/\(route.requestID.hex)" + (try Self.pollQuery(after: after, wait: wait)), session: session)
    }

    /// `?after=<decimal>&wait=<0...25>` (section 19.6); each part only when given. A `wait` outside 0...25 is refused before any I/O.
    static func pollQuery(after cursor: UInt64?, wait: Int?) throws -> String {
        var items: [String] = []
        if let c = cursor { items.append("after=" + HostAPI.decimal(c)) }
        if let w = wait {
            guard (0...25).contains(w) else { throw TransportError.invalidArgument }
            items.append("wait=\(w)")
        }
        return items.isEmpty ? "" : "?" + items.joined(separator: "&")
    }

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

    public func logout(session: RelaySession) async throws -> WireReply { try await json("POST", "/session/logout", HostAPI.json(), session: session) }

    public func registerPush(_ body: Data, session: RelaySession) async throws -> WireReply { try await json("POST", "/push/register", body, session: session) }
    public func unregisterPush(_ body: Data, session: RelaySession) async throws -> WireReply { try await json("POST", "/push/unregister", body, session: session) }

    public func revocation(deviceID: ID16, after: String?, limit: Int?) async throws -> WireReply {
        var items: [String] = []
        if let a = after {
            // the relay's cursor is unpadded base64url; nothing else may ride in the query
            guard !a.isEmpty, a.utf8.count <= 512, a.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }) else { throw TransportError.invalidArgument }
            items.append("after=" + a)
        }
        if let l = limit {
            guard (1...32).contains(l) else { throw TransportError.invalidArgument }
            items.append("limit=\(l)")
        }
        return try await get("\(R)/devices/\(deviceID.hex)/revocation" + (items.isEmpty ? "" : "?" + items.joined(separator: "&")))
    }

    /// Drop moves up to 26 MiB: the relay's slowest accepted transfer is 64 KiB/s (10 minutes at most), so the deadline of a Drop body is
    /// 60 s plus `bytes / 64 KiB/s`, capped at the relay's own 10 minutes plus the same 60 s. Everything else keeps the sender's default.
    static func dropDeadline(bytes: Int) -> TimeInterval { min(60 + Double(max(bytes, 0)) / 65536.0, 660) }
    static var dropBlobResponseCap: Int { DropFrame.maxBlobBytes }

    public func dropPut(objectID: ID16, ifMatch: UInt32, body: Data, session: RelaySession) async throws -> WireReply {
        try await send(request("PUT", "\(R)/drop/\(objectID.hex)/versions", body: body, contentType: "application/octet-stream", session: session,
                               extra: ["if-match": String(ifMatch)], options: RequestOptions(resourceTimeout: Self.dropDeadline(bytes: body.count))))
    }

    public func dropPut(objectID: ID16, ifMatch: UInt32, bodyFile: URL, session: RelaySession) async throws -> WireReply {
        let size = (try? FileManager.default.attributesOfItem(atPath: bodyFile.path)[.size] as? Int) ?? nil
        guard let size, size >= DropFrame.prefixLength else { throw TransportError.invalidArgument }
        return try await send(request("PUT", "\(R)/drop/\(objectID.hex)/versions", contentType: "application/octet-stream", session: session,
                               extra: ["if-match": String(ifMatch)], bodyFile: bodyFile, options: RequestOptions(resourceTimeout: Self.dropDeadline(bytes: size))))
    }

    public func dropList(_ query: Data, session: RelaySession) async throws -> WireReply { try await json("POST", "/drop/list", query, session: session) }

    public func certRequests(person: ID16, wait: Int?, session: RelaySession) async throws -> WireReply {
        // protocol-v2 section 19 ("Long polls take `wait` from 0 to 25 s"; 19.6: integer 0..25), as cert_requests_poll.json sends
        if let w = wait, !(0...25).contains(w) { throw TransportError.invalidArgument }
        return try await get("\(R)/persons/\(person.hex)/cert-requests" + (wait.map { "?wait=\($0)" } ?? ""), session: session)
    }

    public func postCertChallenge(requestID: ID16, _ body: Data, session: RelaySession) async throws -> WireReply {
        try await json("POST", "/cert-requests/\(requestID.hex)/challenge", body, session: session)
    }

    public func postCertRejection(requestID: ID16, _ body: Data, session: RelaySession) async throws -> WireReply {
        try await json("POST", "/cert-requests/\(requestID.hex)/rejection", body, session: session)
    }

    public func createAccount(_ body: Data) async throws -> WireReply { try await json("POST", "/accounts", body) }

    public func dropDescriptors(objectID: ID16, after: UInt32?, limit: Int?, session: RelaySession) async throws -> WireReply {
        var items: [String] = []
        if let a = after { items.append("after=\(a)") }
        if let l = limit {
            guard (1...256).contains(l) else { throw TransportError.invalidArgument }
            items.append("limit=\(l)")
        }
        return try await get("\(R)/drop/\(objectID.hex)/descriptors" + (items.isEmpty ? "" : "?" + items.joined(separator: "&")), session: session)
    }

    public func dropGet(objectID: ID16, version: UInt32, part: DropPart, session: RelaySession) async throws -> WireReply {
        // a blob reply may be a whole 26 MiB ORD2 object: a per-request cap and a body-scaled deadline, nothing else is raised
        try await get("\(R)/drop/\(objectID.hex)/versions/\(version)/\(part.rawValue)", session: session,
                      options: part == .blob ? RequestOptions(maxResponseBytes: Self.dropBlobResponseCap, resourceTimeout: Self.dropDeadline(bytes: Self.dropBlobResponseCap)) : RequestOptions())
    }
}
