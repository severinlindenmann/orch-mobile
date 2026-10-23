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

/// Per-request overrides of a sender's defaults. The Drop routes need them: a 26 MiB blob reply is far above the 4 MiB default cap and a
/// 26 MiB upload cannot finish inside the 120 s default deadline. nil keeps the sender's own value.
public struct RequestOptions: Sendable, Equatable {
    /// The most response body bytes the sender reads before it gives up with `.responseTooLarge`.
    public var maxResponseBytes: Int?
    /// The absolute deadline for the whole exchange (trickled bytes do not extend it).
    public var resourceTimeout: TimeInterval?
    public init(maxResponseBytes: Int? = nil, resourceTimeout: TimeInterval? = nil) {
        self.maxResponseBytes = maxResponseBytes; self.resourceTimeout = resourceTimeout
    }
}

/// One request as HTTP carries it. The in-process relay parses the target itself, exactly as a server would.
public struct WireRequest: Sendable, Equatable, CustomStringConvertible {
    public let method: String
    /// Path and optional query, e.g. `/v2/workspaces/<ws>/grants?epoch=2`.
    public let target: String
    public let headers: [String: String]
    public let body: Data
    /// A request body streamed from this file (then `body` is empty). The sender sends it in small pieces, so it never holds the
    /// whole file in memory; `Content-Length` is the file's size.
    public let bodyFile: URL?
    public let options: RequestOptions
    /// The peer address as the relay sees it (rate limits are per address).
    public let clientAddress: String

    public init(method: String, target: String, headers: [String: String] = [:], body: Data = Data(), clientAddress: String,
                bodyFile: URL? = nil, options: RequestOptions = RequestOptions()) throws {
        self.method = method; self.target = target; self.body = body; self.clientAddress = clientAddress
        self.bodyFile = bodyFile; self.options = options
        self.headers = try HeaderMap.normalize(headers.map { (name: $0.key, value: $0.value) })
    }

    /// The same request with a file body read into `body` (the in-process relay has no socket to stream to).
    public func materialized() throws -> WireRequest {
        guard let f = bodyFile else { return self }
        return try WireRequest(method: method, target: target, headers: headers, body: Data(contentsOf: f), clientAddress: clientAddress, options: options)
    }

    public func header(_ name: String) -> String? {
        headers[String(decoding: name.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 }, as: UTF8.self)]
    }

    /// Method and target only: headers (the bearer) and the body are not printed.
    public var description: String { "WireRequest(\(method) \(target))" }
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

/// Why an origin was refused. Always raised before any request is made.
public enum OriginViolation: Error, Equatable, Sendable {
    /// Not a section 7.1 origin (https, no userinfo, path, query or fragment).
    case invalidOrigin
}

/// Thrown by a transport. HTTP failures are not here: they are `WireReply` values.
public enum TransportError: Error, Equatable, Sendable {
    /// A grants epoch of 0 (reserved for pairing envelopes) or a counter outside its range, refused before any I/O.
    case invalidEpoch
    /// A session token or id that cannot be put on the wire safely.
    case invalidArgument
    /// The connection was lost; whether the relay committed the request is unknown.
    case disconnected
    /// The response body went past the sender's cap. The read was aborted; nothing was parsed.
    case responseTooLarge
}
