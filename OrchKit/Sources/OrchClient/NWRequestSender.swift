import Foundation
import Network
import OrchProtocol
import Security

/// The real HTTPS `RequestSender`: a minimal HTTP/1.1 client on Network.framework, with its own strict response parser
/// (`HTTP1ResponseParser`). It replaces URLSession on purpose.
///
/// INVARIANT (one place): the phone never decodes a relay-controlled content encoding and never buffers more than `maxResponseBytes`
/// of body. URLSession cannot promise either (CFNetwork decodes gzip/br before any delegate callback, including on MIME sniffing),
/// so there is no URLSession here. Nothing in this file or the parser knows how to decompress, and there is no redirect machinery:
/// a 3xx is just a reply.
///
/// What it does:
/// - One request per connection, `Connection: close`. It sends exactly the `WireRequest` headers plus `Host`, `Content-Length` (when
///   there is a body), `Accept-Encoding: identity`, `Connection: close` and a fixed `User-Agent`. A `WireRequest` carrying one of those
///   names (or any framing or hop-by-hop field) is refused with `invalidArgument`. It never sends `Expect`.
/// - Reply headers: the client reads only `retry-after` from the wire (and callers/tests may read `content-type` and `location`).
///   Repeats of framing and security-relevant headers (`content-length`, `transfer-encoding`, `content-encoding`, `content-type`,
///   `retry-after`, `location`) are kept, so a conflicting repeat is refused; repeats of any other header (`Set-Cookie`, `Server-Timing`
///   behind a CDN) keep their first value and drop the rest, so they can never fail a request.
/// - The request is never replayed: a lost connection is `TransportError.disconnected` and the caller decides (WorkspaceSession's
///   uncertain-request logic stays in charge).
/// - TLS: Network.framework does NOT apply App Transport Security, so this sender enforces https and TLS 1.2 or newer itself.
///   Default system trust evaluation (no custom verify block, no skip option), SNI and the `Host` header both come from the origin's
///   hostname, ALPN offers only `http/1.1` and any other negotiated protocol is refused. The endpoint is the origin's DNS name: this
///   code never resolves a name itself, so what Network.framework connects to is what the TLS name was checked against.
/// - Plain TCP exists only for the DEBUG + `package` loopback initializer used by the integration tests (see
///   `RealmContext.liveLoopbackForTesting`); a Release build has no such initializer.
/// - Per request (`WireRequest.options`): a larger response cap and a longer absolute deadline, both bounded (64 MiB, one hour); the
///   Drop routes use them, everything else keeps the defaults. A request body may be streamed from a file (`WireRequest.bodyFile`).
/// - Timeouts: `requestTimeout` is the idle limit (connect included; no byte moved for that long) and `resourceTimeout` the absolute
///   deadline, which trickled bytes do not extend. The relay long-polls for at most 25 s, so the 60 s and 120 s defaults leave margin.
/// - Errors: connection loss, refused connection, timeout, a malformed or unsupported reply and a body that ends early are
///   `.disconnected`; a body past the cap, or any content encoding other than identity, is `.responseTooLarge`; `CancellationError`
///   only when the calling task was cancelled (also when that happened before the connection was started).
/// - The target is allow-listed (RFC 3986 pchar plus `/`, one `?`, `&`, `=`; `%` only before two hex digits), so nothing can add a
///   header line or change the authority.
public final class NWRequestSender: RequestSender, @unchecked Sendable {
    public static let defaultMaxResponseBytes = 4 << 20
    static let readBufferBytes = 16 << 10

    public let origin: String
    public let maxResponseBytes: Int
    private let host: String
    private let port: UInt16
    private let tls: Bool
    private let requestTimeout: TimeInterval
    private let resourceTimeout: TimeInterval
    private let queue = DispatchQueue(label: "orch.nw-request-sender")
    private let counter = Counter()

    /// Production: `origin` must be a valid `https` relay origin.
    public convenience init(origin: String, maxResponseBytes: Int = defaultMaxResponseBytes,
                            requestTimeout: TimeInterval = 60, resourceTimeout: TimeInterval = 120) throws {
        guard origin.hasPrefix("https://"), RelayURL.isValid(origin) else { throw RealmViolation.invalidOrigin }
        try self.init(validated: origin, tls: true, maxResponseBytes: maxResponseBytes, requestTimeout: requestTimeout, resourceTimeout: resourceTimeout)
    }

    #if DEBUG
    /// TEST-ONLY: a loopback `http` origin, under the same `#if DEBUG` + `package` rules as `RealmContext.liveLoopbackForTesting`.
    package convenience init(loopbackOrigin origin: String, maxResponseBytes: Int = defaultMaxResponseBytes,
                             requestTimeout: TimeInterval = 60, resourceTimeout: TimeInterval = 120) throws {
        guard RealmContext.isLoopbackHTTP(origin) else { throw RealmViolation.invalidOrigin }
        try self.init(validated: origin, tls: false, maxResponseBytes: maxResponseBytes, requestTimeout: requestTimeout, resourceTimeout: resourceTimeout)
    }
    #endif

    private init(validated origin: String, tls: Bool, maxResponseBytes: Int, requestTimeout: TimeInterval, resourceTimeout: TimeInterval) throws {
        guard maxResponseBytes > 0, requestTimeout > 0, resourceTimeout > 0, let c = URLComponents(string: origin), var h = c.host, !h.isEmpty else {
            throw RealmViolation.invalidOrigin
        }
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        self.origin = origin; self.maxResponseBytes = maxResponseBytes; self.tls = tls
        self.host = h; self.port = UInt16(c.port ?? (tls ? 443 : 80))
        self.requestTimeout = requestTimeout; self.resourceTimeout = resourceTimeout
    }

    /// Tests: total bytes read from sockets by this sender.
    package var bytesRead: Int { counter.value }

    private var hostHeader: String {
        let h = host.contains(":") ? "[\(host)]" : host
        return port == (tls ? 443 : 80) ? h : "\(h):\(port)"
    }

    public func send(_ request: WireRequest) async throws -> WireReply {
        try Task.checkCancellation()
        let source: BodySource
        if let file = request.bodyFile {
            guard request.body.isEmpty else { throw TransportError.invalidArgument }
            source = try BodySource.file(file)
        } else { source = .data(request.body) }
        let maxResponse: Int, deadline: TimeInterval
        do {
            maxResponse = try Self.checked(request.options.maxResponseBytes, default: maxResponseBytes, ceiling: Self.ceilingResponseBytes)
            deadline = try Self.checked(request.options.resourceTimeout, default: resourceTimeout, ceiling: Self.ceilingResourceTimeout)
        } catch { source.close(); throw error }
        let head: Data
        do { head = try Self.requestHead(request, host: hostHeader, bodyLength: source.length) } catch { source.close(); throw error }
        let exchange = Exchange(sender: self, head: head, body: source, maxResponseBytes: maxResponse, resourceTimeout: deadline)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<WireReply, Error>) in exchange.start(cont) }
        } onCancel: { exchange.cancelByCaller() }
    }

    /// Per-request overrides are bounded: a caller cannot ask for an unbounded buffer or an unbounded wait.
    static let ceilingResponseBytes = 64 << 20
    static let ceilingResourceTimeout: TimeInterval = 3600
    private static func checked<T: Comparable & Numeric>(_ value: T?, default d: T, ceiling: T) throws -> T {
        guard let value else { return d }
        guard value > 0, value <= ceiling else { throw TransportError.invalidArgument }
        return value
    }

    /// The request body: bytes, or a file read in `readBufferBytes` pieces as the connection takes them.
    enum BodySource {
        case data(Data)
        case file(handle: FileHandle, length: Int)

        var length: Int { switch self { case .data(let d): d.count; case .file(_, let n): n } }

        static func file(_ url: URL) throws -> BodySource {
            guard url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) else { throw TransportError.invalidArgument }
            guard let size = try? handle.seekToEnd(), (try? handle.seek(toOffset: 0)) != nil, size <= UInt64(Int32.max) else {
                try? handle.close(); throw TransportError.invalidArgument
            }
            return .file(handle: handle, length: Int(size))
        }

        /// The next piece from `offset` (the connection takes them strictly in order); nil when the file ended early or failed.
        func piece(from offset: Int, upTo end: Int) -> Data? {
            switch self {
            case .data(let d): return d.subdata(in: offset..<end)
            case .file(let h, _):
                guard let d = try? h.read(upToCount: end - offset), d.count == end - offset else { return nil }
                return d
            }
        }

        func close() { if case .file(let h, _) = self { try? h.close() } }
    }

    // MARK: request

    private static let managed: Set<String> = ["host", "content-length", "transfer-encoding", "connection", "accept-encoding", "user-agent", "expect",
                                               "upgrade", "te", "trailer", "proxy-authorization", "proxy-connection", "keep-alive"]

    static func requestHead(_ r: WireRequest, host: String, bodyLength: Int) throws -> Data {
        // only the methods the relay protocol uses: no HEAD (a body-less reply would break the framing rules) and no CONNECT
        guard ["GET", "POST", "PUT", "DELETE"].contains(r.method) else { throw TransportError.invalidArgument }
        guard r.target.hasPrefix("/"), !r.target.hasPrefix("//"), allowed(r.target) else { throw TransportError.invalidArgument }
        var s = "\(r.method) \(r.target) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: orch-mobile\r\nAccept-Encoding: identity\r\nConnection: close\r\n"
        for (name, value) in r.headers.sorted(by: { $0.key < $1.key }) {
            guard !managed.contains(name), !name.hasPrefix("proxy-") else { throw TransportError.invalidArgument }
            s += "\(name): \(value)\r\n"
        }
        if bodyLength > 0 || r.method == "POST" || r.method == "PUT" { s += "Content-Length: \(bodyLength)\r\n" }
        return Data((s + "\r\n").utf8)
    }

    /// RFC 3986 pchar (unreserved, sub-delims, `:` `@`) plus `/` and one `?`; `%` only before two hex digits. This excludes
    /// `< > | { } " ^ \` [ ] #`, spaces, controls, non-ASCII, a lone `%` and `%zz`.
    static func allowed(_ target: String) -> Bool {
        let u = Array(target.utf8)
        var i = 0, queries = 0
        func hex(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66) }
        while i < u.count {
            let c = u[i]
            switch c {
            case 0x25:
                guard i + 2 < u.count, hex(u[i + 1]), hex(u[i + 2]) else { return false }
                i += 2
            case 0x3F: queries += 1; if queries > 1 { return false }
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39: break
            case UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"), UInt8(ascii: "!"), UInt8(ascii: "$"),
                 UInt8(ascii: "&"), UInt8(ascii: "'"), UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"),
                 UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: "="), UInt8(ascii: ":"), UInt8(ascii: "@"), UInt8(ascii: "/"): break
            default: return false
            }
            i += 1
        }
        return true
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        var value: Int { lock.withLock { n } }
        func add(_ k: Int) { lock.withLock { n += k } }
    }

    // MARK: one exchange

    /// All mutable state is confined to `sender.queue`; the continuation is resumed exactly once.
    private final class Exchange: @unchecked Sendable {
        let sender: NWRequestSender
        let head: Data
        let body: BodySource
        let resourceTimeout: TimeInterval
        var parser: HTTP1ResponseParser
        var connection: NWConnection?
        var cont: CheckedContinuation<WireReply, Error>?
        var result: Result<WireReply, Error>?
        var idle: DispatchWorkItem?
        var total: DispatchWorkItem?
        var started = false

        init(sender: NWRequestSender, head: Data, body: BodySource, maxResponseBytes: Int, resourceTimeout: TimeInterval) {
            self.sender = sender; self.head = head; self.body = body; self.resourceTimeout = resourceTimeout
            parser = HTTP1ResponseParser(maxBody: maxResponseBytes)
        }

        func start(_ c: CheckedContinuation<WireReply, Error>) {
            sender.queue.async {
                self.cont = c
                if let r = self.result { c.resume(with: r); self.cont = nil; return }   // cancelled before it began
                self.begin()
            }
        }

        func cancelByCaller() {
            sender.queue.async { self.finish(.failure(CancellationError())) }
        }

        private func begin() {
            let params: NWParameters
            if sender.tls {
                let tls = NWProtocolTLS.Options()
                sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
                sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, sender.host)
                sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
                params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            } else {
                params = NWParameters.tcp
            }
            guard let port = NWEndpoint.Port(rawValue: sender.port) else { return finish(.failure(TransportError.disconnected)) }
            let c = NWConnection(host: NWEndpoint.Host(sender.host), port: port, using: params)
            connection = c
            started = true
            c.stateUpdateHandler = { [weak self] state in guard let self else { return }; self.sender.queue.async { self.onState(state) } }
            armIdle()
            let t = DispatchWorkItem { [weak self] in self?.finish(.failure(TransportError.disconnected)) }
            total = t
            sender.queue.asyncAfter(deadline: .now() + resourceTimeout, execute: t)
            c.start(queue: sender.queue)
        }

        private func onState(_ state: NWConnection.State) {
            guard result == nil else { return }
            switch state {
            case .ready:
                if sender.tls, !alpnAcceptable() { return finish(.failure(TransportError.disconnected)) }
                armIdle()
                receive()
                sendHead()
            case .failed: finish(.failure(TransportError.disconnected))
            case .waiting:
                // `waiting` is Network.framework's "no usable path (yet)": offline, refused, unreachable. It is final for us (the old
                // `waitsForConnectivity = false`): no waiting for a better path, so a late connection can never send a request after
                // the caller was told it failed.
                finish(.failure(TransportError.disconnected))
            case .cancelled: finish(.failure(TransportError.disconnected))
            default: break
            }
        }

        private func alpnAcceptable() -> Bool {
            guard let meta = connection?.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return false }
            guard let p = sec_protocol_metadata_get_negotiated_protocol(meta.securityProtocolMetadata) else { return true }   // none: HTTP/1.1
            return String(cString: p) == "http/1.1"
        }

        // MARK: write (stops as soon as a final reply or a failure arrives)

        private func sendHead() {
            connection?.send(content: head, completion: .contentProcessed { [weak self] e in
                guard let self else { return }
                self.sender.queue.async { guard self.result == nil else { return }
                    // A failed write is not yet a failed exchange: a server may answer early and close while the upload is still going.
                    // Stop writing and let the read side say what arrived (an error there is `.disconnected`).
                    if e != nil { return }
                    self.armIdle(); self.sendBody(from: 0) }
            })
        }

        private func sendBody(from offset: Int) {
            guard result == nil, offset < body.length else { return }
            let end = min(offset + NWRequestSender.readBufferBytes, body.length)
            // a file that ended early cannot be completed: the declared length would never arrive, so the exchange fails now
            guard let piece = body.piece(from: offset, upTo: end) else { return finish(.failure(TransportError.disconnected)) }
            connection?.send(content: piece, completion: .contentProcessed { [weak self] e in
                guard let self else { return }
                self.sender.queue.async { guard self.result == nil else { return }
                    if e != nil { return }
                    self.armIdle(); self.sendBody(from: end) }
            })
        }

        // MARK: read

        private func receive() {
            connection?.receive(minimumIncompleteLength: 1, maximumLength: NWRequestSender.readBufferBytes) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                self.sender.queue.async { self.onData(data, isComplete: isComplete, error: error) }
            }
        }

        private func onData(_ data: Data?, isComplete: Bool, error: NWError?) {
            guard result == nil else { return }
            if let data, !data.isEmpty {
                sender.counter.add(data.count)
                armIdle()
                do { try parser.feed(data) } catch { return finish(.failure(Self.map(error))) }
            }
            if parser.isComplete { return completeReply() }
            if error != nil { return finish(.failure(TransportError.disconnected)) }
            if isComplete {
                do { try parser.end() } catch { return finish(.failure(Self.map(error))) }
                return parser.isComplete ? completeReply() : finish(.failure(TransportError.disconnected))
            }
            receive()
        }

        private func completeReply() {
            do { finish(.success(try WireReply(status: parser.status, headerFields: parser.replyFields, body: parser.body))) }
            catch { finish(.failure(TransportError.disconnected)) }
        }

        static func map(_ e: Error) -> Error {
            switch e as? HTTP1ResponseParser.Failure {
            case .tooLarge?: TransportError.responseTooLarge
            default: TransportError.disconnected
            }
        }

        // MARK: lifecycle

        private func armIdle() {
            idle?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.finish(.failure(TransportError.disconnected)) }
            idle = w
            sender.queue.asyncAfter(deadline: .now() + sender.requestTimeout, execute: w)
        }

        /// Completes exactly once, stops timers and closes the connection locally.
        private func finish(_ r: Result<WireReply, Error>) {
            guard result == nil else { return }
            result = r
            body.close()
            idle?.cancel(); total?.cancel()
            connection?.stateUpdateHandler = nil
            connection?.cancel()
            if let c = cont { cont = nil; c.resume(with: r) }
        }
    }
}
