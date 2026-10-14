import Foundation
import OrchProtocol

/// The real HTTPS `RequestSender` (the other implementation is the in-process FakeRelay).
///
/// Contract (see `RequestSender`):
/// - The origin is fixed at init and is the only host this sender ever contacts. The request target must be a path (and optional
///   query) starting with a single `/`; anything that could change the authority is refused before I/O.
/// - Every redirect is refused: the delegate answers `nil` to `willPerformHTTPRedirection`, so the redirect target is never
///   requested, and the 3xx reply is returned to the caller as a value (callers treat any non-2xx as a failure, never as data).
/// - The response body is capped while it is read: a `Content-Length` over the cap aborts before the first byte is buffered, and
///   a body that grows past the cap (chunked, or a lying length) is cancelled at the first chunk that crosses it. The caller gets
///   `TransportError.responseTooLarge` and no bytes; nothing is parsed here at all.
/// - The URLSession is ephemeral with no cookie storage, no cache and no credential storage, and HTTP authentication
///   challenges are rejected. TLS server trust uses the system default (ATS stays on).
/// - Timeouts: `requestTimeout` is URLSession's idle timeout (no bytes for that long), `resourceTimeout` bounds the whole
///   exchange. The relay long-polls for at most 25 s, so the defaults (60 s idle, 120 s total) leave a wide margin.
/// - Connection loss, timeouts, TLS failures and every other URLSession error are `TransportError.disconnected` (the outcome of
///   the request is unknown); task cancellation is `CancellationError`.
/// - Compression: every request carries `accept-encoding: identity`, and a response with any `Content-Encoding` other than
///   `identity` is refused at the headers with `TransportError.responseTooLarge` (URLSession would decode it before the cap sees
///   a byte: a compression bomb), before any body byte is read.
/// - Headers: exactly the ones `WireRequest` carries plus `accept-encoding: identity`. URLSession itself adds the transport-level
///   fields it always adds (Host, Content-Length, User-Agent); this sender adds no application header, cookie or credential.
/// - The request URL is built from an allow-listed target (RFC 3986 pchar plus `/?&=`, `%` only before two hex digits), and the
///   response's final URL is checked against the origin.
public final class URLSessionRequestSender: RequestSender, @unchecked Sendable {
    public static let defaultMaxResponseBytes = 4 << 20

    public let origin: String
    public let maxResponseBytes: Int
    private let session: URLSession
    private let delegate: Delegate
    private let components: URLComponents

    /// Production: `origin` must be a valid `https` relay origin.
    public convenience init(origin: String, maxResponseBytes: Int = defaultMaxResponseBytes,
                            requestTimeout: TimeInterval = 60, resourceTimeout: TimeInterval = 120) throws {
        guard origin.hasPrefix("https://"), RelayURL.isValid(origin) else { throw RealmViolation.invalidOrigin }
        try self.init(validated: origin, maxResponseBytes: maxResponseBytes, requestTimeout: requestTimeout, resourceTimeout: resourceTimeout)
    }

    #if DEBUG
    /// TEST-ONLY: a loopback `http` origin, under the same `#if DEBUG` + `package` rules as `RealmContext.liveLoopbackForTesting`.
    package convenience init(loopbackOrigin origin: String, maxResponseBytes: Int = defaultMaxResponseBytes,
                             requestTimeout: TimeInterval = 60, resourceTimeout: TimeInterval = 120) throws {
        guard RealmContext.isLoopbackHTTP(origin) else { throw RealmViolation.invalidOrigin }
        try self.init(validated: origin, maxResponseBytes: maxResponseBytes, requestTimeout: requestTimeout, resourceTimeout: resourceTimeout)
    }
    #endif

    private init(validated origin: String, maxResponseBytes: Int, requestTimeout: TimeInterval, resourceTimeout: TimeInterval) throws {
        guard maxResponseBytes > 0, let c = URLComponents(string: origin) else { throw RealmViolation.invalidOrigin }
        self.origin = origin; self.maxResponseBytes = maxResponseBytes; self.components = c
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = [:]
        config.allowsExpensiveNetworkAccess = true
        let d = Delegate(cap: maxResponseBytes, origin: c)
        self.delegate = d
        self.session = URLSession(configuration: config, delegate: d, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// Tests: the largest single chunk of body the delegate was ever handed (0 when every response was refused at its headers).
    package var largestChunkSeen: Int { delegate.largestChunk }

    public func send(_ request: WireRequest) async throws -> WireReply {
        let url = try Self.url(origin: components, target: request.target)
        var r = URLRequest(url: url)
        r.httpMethod = request.method
        r.httpShouldHandleCookies = false
        r.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        // No compressed responses: URLSession decodes gzip/deflate/br before the delegate sees a byte, so a small body could expand
        // far past the cap in one chunk. `identity` asks the relay for the bytes as they are (the delegate also refuses any
        // Content-Encoding other than identity).
        r.setValue("identity", forHTTPHeaderField: "accept-encoding")
        if !request.body.isEmpty { r.httpBody = request.body }
        try Task.checkCancellation()
        let task = session.dataTask(with: r)
        let outcome: Delegate.Outcome = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Delegate.Outcome, Error>) in
                delegate.register(task, cont)
                task.resume()
            }
        } onCancel: { delegate.cancelByCaller(task) }
        return try WireReply(status: outcome.status, headerFields: outcome.headers, body: outcome.body)
    }

    /// `origin` + `target`, refusing a target that is not an origin-form path (`/...`), starts with `//`, or carries a fragment.
    static func url(origin: URLComponents, target: String) throws -> URL {
        guard target.hasPrefix("/"), !target.hasPrefix("//"), allowed(target) else { throw TransportError.invalidArgument }
        var c = origin
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        c.percentEncodedPath = String(parts[0])      // safe: only allow-listed bytes reach the setters (they trap on anything else)
        c.percentEncodedQuery = parts.count > 1 ? String(parts[1]) : nil
        guard let url = c.url, url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port, c.user == nil else {
            throw TransportError.invalidArgument
        }
        return url
    }

    /// RFC 3986 pchar (unreserved, sub-delims, `:` `@`) plus `/` and one `?` and `&` `=`; `%` only before two hex digits. This
    /// excludes `< > | { } " ^ \` [ ] #`, spaces, controls, non-ASCII, a lone `%` and `%zz`.
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

    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        struct Outcome: Sendable { var status = 0; var headers: [(name: String, value: String)] = []; var body = Data() }
        private struct State {
            var cont: CheckedContinuation<Outcome, Error>?
            var outcome = Outcome()
            var failure: Error?
            var callerCancelled = false
        }
        private let lock = NSLock()
        private var states: [Int: State] = [:]
        private var largest = 0
        var largestChunk: Int { lock.withLock { largest } }
        private let cap: Int
        private let origin: URLComponents
        init(cap: Int, origin: URLComponents) { self.cap = cap; self.origin = origin }

        func register(_ task: URLSessionTask, _ cont: CheckedContinuation<Outcome, Error>) {
            lock.withLock { states[task.taskIdentifier] = State(cont: cont) }
        }

        /// The calling task was cancelled: only this makes URLSession's `cancelled` a `CancellationError`.
        func cancelByCaller(_ task: URLSessionTask) {
            lock.withLock { states[task.taskIdentifier]?.callerCancelled = true }
            task.cancel()
        }

        /// Records the first failure for the task and cancels it; later calls keep the first.
        private func fail(_ task: URLSessionTask, _ error: Error) {
            lock.withLock { if states[task.taskIdentifier]?.failure == nil { states[task.taskIdentifier]?.failure = error } }
            task.cancel()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)      // refuse: the 3xx itself becomes the reply
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                completionHandler(.performDefaultHandling, nil)
            } else {
                completionHandler(.rejectProtectionSpace, nil)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else {
                fail(dataTask, TransportError.disconnected); completionHandler(.cancel); return
            }
            // A compressed body would be decoded by URLSession before `didReceive data` runs: refuse it at the headers.
            if let enc = http.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespaces).lowercased(), !enc.isEmpty, enc != "identity" {
                fail(dataTask, TransportError.responseTooLarge); completionHandler(.cancel); return
            }
            if let u = http.url, u.scheme != origin.scheme || u.host != origin.host || u.port != origin.port {
                fail(dataTask, TransportError.disconnected); completionHandler(.cancel); return
            }
            if response.expectedContentLength > Int64(cap) {
                fail(dataTask, TransportError.responseTooLarge); completionHandler(.cancel); return
            }
            var fields: [(name: String, value: String)] = []
            for (k, v) in http.allHeaderFields { if let k = k as? String, let v = v as? String { fields.append((k, v)) } }
            lock.withLock {
                states[dataTask.taskIdentifier]?.outcome.status = http.statusCode
                states[dataTask.taskIdentifier]?.outcome.headers = fields
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let over: Bool = lock.withLock {
                largest = max(largest, data.count)
                guard var s = states[dataTask.taskIdentifier], s.failure == nil else { return false }
                if s.outcome.body.count + data.count > cap { return true }
                s.outcome.body.append(data)
                states[dataTask.taskIdentifier] = s
                return false
            }
            if over { fail(dataTask, TransportError.responseTooLarge) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let s = lock.withLock({ states.removeValue(forKey: task.taskIdentifier) }), let cont = s.cont else { return }
            let cancelledByCaller = s.callerCancelled
            if let f = s.failure {
                cont.resume(throwing: f)
            } else if let e = error {
                // `cancelled` is task cancellation only if this task was cancelled; a system-initiated cancel is a lost connection.
                let cancelled = (e as? URLError)?.code == .cancelled && cancelledByCaller
                cont.resume(throwing: cancelled ? CancellationError() : TransportError.disconnected)
            } else if s.outcome.status == 0 {
                cont.resume(throwing: TransportError.disconnected)
            } else {
                cont.resume(returning: s.outcome)
            }
        }
    }
}
