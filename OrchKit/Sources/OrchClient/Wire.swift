import Foundation
import OrchProtocol

/// Header names are case-insensitive (host-api section 1): names are stored lower-case, two spellings of one name with
/// different values are a conflict, and a conflict is refused rather than resolved.
public enum WireError: Error, Equatable, Sendable {
    case conflictingHeader(String)
    case invalidHeaderName(String)
    case invalidHeaderValue(String)
}

enum HeaderMap {
    static func isToken(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || "!#$%&'*+-.^_`|~".utf8.contains(c)
        }
    }

    static func normalize(_ fields: some Sequence<(name: String, value: String)>) throws -> [String: String] {
        var out: [String: String] = [:]
        for (rawName, rawValue) in fields {
            guard isToken(rawName) else { throw WireError.invalidHeaderName(rawName) }
            let name = String(decoding: rawName.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 }, as: UTF8.self)
            // Optional whitespace around a field value is not part of it; control characters never are.
            let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard value.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7F }) else { throw WireError.invalidHeaderValue(name) }
            if let existing = out[name], existing != value { throw WireError.conflictingHeader(name) }
            out[name] = value
        }
        return out
    }
}

/// What a transport returns. HTTP failures are values, not throws.
public struct WireReply: Sendable, Equatable {
    public let status: Int
    /// Lower-case names.
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) throws {
        self.status = status
        self.headers = try HeaderMap.normalize(headers.map { (name: $0.key, value: $0.value) })
        self.body = body
    }

    /// From raw header fields in wire order (repeats allowed when equal).
    public init(status: Int, headerFields: [(name: String, value: String)], body: Data = Data()) throws {
        self.status = status
        self.headers = try HeaderMap.normalize(headerFields)
        self.body = body
    }

    /// A reply header by name. Repeats of headers a caller acts on are refused upstream (`HTTP1ResponseParser.strictRepeats`); any other
    /// repeated header holds its first value here, so add a header to `strictRepeats` before reading it.
    public func header(_ name: String) -> String? {
        headers[String(decoding: name.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 }, as: UTF8.self)]
    }
}

/// One request as HTTP carries it. The in-process relay parses the target itself, exactly as a server would.
public struct WireRequest: Sendable, Equatable, CustomStringConvertible {
    public let method: String
    /// Path and optional query, e.g. `/v2/workspaces/<ws>/grants?epoch=2`.
    public let target: String
    public let headers: [String: String]
    public let body: Data
    /// The peer address as the relay sees it (rate limits are per address).
    public let clientAddress: String

    public init(method: String, target: String, headers: [String: String] = [:], body: Data = Data(), clientAddress: String) throws {
        self.method = method; self.target = target; self.body = body; self.clientAddress = clientAddress
        self.headers = try HeaderMap.normalize(headers.map { (name: $0.key, value: $0.value) })
    }

    public func header(_ name: String) -> String? {
        headers[String(decoding: name.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 }, as: UTF8.self)]
    }

    /// Method and target only: headers (the bearer) and the body are not printed.
    public var description: String { "WireRequest(\(method) \(target))" }
}

/// A bearer token. It never appears in `description`, `debugDescription`, `dump` or a `Mirror`, so logging a session cannot leak it.
public struct RelaySession: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let token: String
    public init(token: String) { self.token = token }
    public var description: String { "RelaySession(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

public struct PairRoute: Sendable, Equatable {
    public let workspaceID: ID16, offerID: ID16, requestID: ID16
    public init(workspaceID: ID16, offerID: ID16, requestID: ID16) { self.workspaceID = workspaceID; self.offerID = offerID; self.requestID = requestID }
}

public struct BridgeRoute: Sendable, Equatable {
    public let workspaceID: ID16, requestID: ID16
    public init(workspaceID: ID16, requestID: ID16) { self.workspaceID = workspaceID; self.requestID = requestID }
}

public enum DropPart: String, Sendable { case descriptor, wraps, blob }

/// The seam between the client and any relay (host-api section 1). Bytes in, bytes out: no crypto here. Constructed with
/// a fixed `RealmContext` and allowed origin; callers cannot override either. `context` is the transport's own realm and
/// origin: the client binds a login to it (it signs `context.origin`, and only with an identity of `context.realm`), so a
/// wrapper that forwards to another transport must forward the context of the transport that really carries the bytes.
public protocol RelayTransport: Sendable {
    var context: RealmContext { get }
    func challenge() async throws -> WireReply
    func login(_ body: Data) async throws -> WireReply
    func pairingPost(_ envelope: Data, route: PairRoute) async throws -> WireReply
    /// `wait` is the long-poll seconds (0...25, section 19); nil sends no `wait` (an immediate answer).
    func pairingPoll(route: PairRoute, after: UInt64?, wait: Int?) async throws -> WireReply
    func bridgePost(_ envelope: Data, route: BridgeRoute, session: RelaySession) async throws -> WireReply
    func bridgePoll(route: BridgeRoute, after: UInt64?, wait: Int?, session: RelaySession) async throws -> WireReply
    func grants(workspaceID: ID16, epoch: UInt32?, session: RelaySession) async throws -> WireReply
    func memberList(workspaceID: ID16, session: RelaySession) async throws -> WireReply
    func card(workspaceID: ID16, session: RelaySession) async throws -> WireReply
    func cardKey(workspaceID: ID16, cardSequence: UInt32, session: RelaySession) async throws -> WireReply
    func registerPush(_ body: Data, session: RelaySession) async throws -> WireReply
    func unregisterPush(_ body: Data, session: RelaySession) async throws -> WireReply
    /// A revocation record is a public, PK-signed object: this route takes no session (a revoked device has none).
    /// `after` is the relay's opaque page cursor (`next` of the previous page) and `limit` the page size (1...32); nil sends neither.
    func revocation(deviceID: ID16, after: String?, limit: Int?) async throws -> WireReply
    /// Ends a session (`POST /v2/session/logout`). Best effort: callers ignore failure. Transports without the route keep the default.
    func logout(session: RelaySession) async throws -> WireReply
    func dropPut(objectID: ID16, ifMatch: UInt32, body: Data, session: RelaySession) async throws -> WireReply
    func dropList(_ query: Data, session: RelaySession) async throws -> WireReply
    func dropGet(objectID: ID16, version: UInt32, part: DropPart, session: RelaySession) async throws -> WireReply

    // The primary device's side of the cert_pending queues and the account route (section 19.1, 19.3).
    /// `GET /v2/persons/{person}/cert-requests[?wait=s]` with the primary's device session (D(p), addressee only).
    func certRequests(person: ID16, wait: Int?, session: RelaySession) async throws -> WireReply
    /// `POST /v2/cert-requests/{id}/challenge` with the primary's device session; the body is `cj({"challenge": signed})`.
    func postCertChallenge(requestID: ID16, _ body: Data, session: RelaySession) async throws -> WireReply
    /// `POST /v2/cert-requests/{id}/rejection` with the primary's device session; the body is `cj({"rejection": signed})`.
    func postCertRejection(requestID: ID16, _ body: Data, session: RelaySession) async throws -> WireReply
    /// `POST /v2/accounts`, session-less (P3-D3).
    func createAccount(_ body: Data) async throws -> WireReply
}

/// Transports that do not carry the primary's routes (test doubles that wrap only the pairing and workspace calls) refuse them
/// before any I/O.
extension RelayTransport {
    public func certRequests(person: ID16, wait: Int?, session: RelaySession) async throws -> WireReply { throw TransportError.invalidArgument }
    public func postCertChallenge(requestID: ID16, _ body: Data, session: RelaySession) async throws -> WireReply { throw TransportError.invalidArgument }
    public func postCertRejection(requestID: ID16, _ body: Data, session: RelaySession) async throws -> WireReply { throw TransportError.invalidArgument }
    public func createAccount(_ body: Data) async throws -> WireReply { throw TransportError.invalidArgument }
}

public extension RelayTransport {
    func pairingPoll(route: PairRoute, after: UInt64?) async throws -> WireReply { try await pairingPoll(route: route, after: after, wait: nil) }
    func bridgePoll(route: BridgeRoute, after: UInt64?, session: RelaySession) async throws -> WireReply {
        try await bridgePoll(route: route, after: after, wait: nil, session: session)
    }
    func revocation(deviceID: ID16) async throws -> WireReply { try await revocation(deviceID: deviceID, after: nil, limit: nil) }
    func logout(session: RelaySession) async throws -> WireReply { throw TransportError.invalidArgument }
}

/// Something that carries one request to a relay and brings back its reply (the HTTPS client later, the fake now).
///
/// `origin` is the one origin this sender talks to; the transport admits it against its realm context on every send.
/// A future HTTPS sender MUST refuse every redirect (a redirect is a different origin), and MUST cap the response body
/// size while reading, before any parsing, so a hostile relay cannot make the client buffer or parse unbounded data.
public protocol RequestSender: Sendable {
    var origin: String { get }
    func send(_ request: WireRequest) async throws -> WireReply
}

/// Thrown by a transport. HTTP failures are not here: they are `WireReply` values.
public enum TransportError: Error, Equatable, Sendable {
    case realm(RealmViolation)
    /// A grants epoch of 0 (reserved for pairing envelopes) or a counter outside its range, refused before any I/O.
    case invalidEpoch
    /// A session token or id that cannot be put on the wire safely.
    case invalidArgument
    /// The connection was lost; whether the relay committed the request is unknown.
    case disconnected
    /// The response body went past the sender's cap. The read was aborted; nothing was parsed.
    case responseTooLarge
}
