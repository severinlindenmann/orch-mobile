import Foundation
import Network

/// A tiny loopback HTTP/1.1 server for sender tests: one canned behaviour per request, a hit counter, the request headers it saw.
final class StubServer: @unchecked Sendable {
    struct Request: Sendable { let method: String; let target: String; let headers: [String: String] }
    enum Behaviour: Sendable {
        /// Send these bytes verbatim, then close.
        case raw(Data)
        /// 200 chunked, `chunk` bytes of 'x' per chunk, until the peer goes away (or 256 MiB).
        case endless(chunk: Int)
        /// Never answer.
        case hang
        /// Send the bytes, then close without finishing the body.
        case truncated(Data)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "stub-server")
    private let lock = NSLock()
    private var hits: [String: Int] = [:]
    private var seen: [Request] = []
    private var handler: @Sendable (Request) -> Behaviour = { _ in .raw(StubServer.http(200, body: "{}")) }
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    var origin: String { "http://127.0.0.1:\(port)" }

    private init(listener: NWListener) { self.listener = listener }

    /// Binds a loopback listener on a free port and returns once it is ready (no thread blocks waiting for it).
    static func start() async throws -> StubServer {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let server = StubServer(listener: try NWListener(using: params))
        server.listener.newConnectionHandler = { [weak server] c in
            if let server { server.accept(c) } else { c.cancel() }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { cont.resume() }
                case .failed(let e): if once.take() { cont.resume(throwing: e) }
                case .cancelled: if once.take() { cont.resume(throwing: URLError(.cancelled)) }
                default: break
                }
            }
            server.listener.start(queue: server.queue)
        }
        guard let p = server.listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }
        server.port = p
        return server
    }

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock(); private var taken = false
        func take() -> Bool { lock.withLock { if taken { return false }; taken = true; return true } }
    }

    func handle(_ h: @escaping @Sendable (Request) -> Behaviour) { lock.withLock { handler = h } }
    func count(_ target: String) -> Int { lock.withLock { hits[target] ?? 0 } }
    var requests: [Request] { lock.withLock { seen } }

    func stop() {
        listener.cancel()
        let cs = lock.withLock { connections }
        for c in cs { c.cancel() }
    }

    static func http(_ status: Int, headers: [String: String] = [:], body: String = "") -> Data {
        var s = "HTTP/1.1 \(status) X\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        return Data((s + "\r\n" + body).utf8)
    }

    private func accept(_ c: NWConnection) {
        lock.withLock { connections.append(c) }
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { c.cancel(); return }
            var b = buf
            if let d = data { b.append(d) }
            if let r = b.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: b[..<r.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let first = head[0].split(separator: " ")
                var headers: [String: String] = [:]
                for l in head.dropFirst() { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
                // Read the whole request body before answering, so the client's write never meets a closed socket (a RST can
                // discard an unread reply).
                let length = Int(headers["content-length"] ?? "") ?? 0
                if b.count - r.upperBound < length, err == nil, !done { self.read(c, b); return }
                let req = Request(method: String(first[0]), target: String(first[1]), headers: headers)
                let h: @Sendable (Request) -> Behaviour = self.lock.withLock { self.hits[req.target, default: 0] += 1; self.seen.append(req); return self.handler }
                self.respond(c, h(req))
            } else if err != nil || done { c.cancel() } else { self.read(c, b) }
        }
    }

    private func respond(_ c: NWConnection, _ b: Behaviour) {
        switch b {
        case .raw(let d): c.send(content: d, completion: .contentProcessed { _ in c.cancel() })
        case .truncated(let d): c.send(content: d, completion: .contentProcessed { _ in c.cancel() })
        case .hang: break
        case .endless(let n):
            let head = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\n\r\n".utf8)
            let chunk = Data(String(n, radix: 16).utf8) + Data("\r\n".utf8) + Data(repeating: 0x78, count: n) + Data("\r\n".utf8)
            c.send(content: head, completion: .contentProcessed { [weak self] e in guard let self else { return };  if e == nil { self.stream(c, chunk, sent: 0) } else { c.cancel() } })
        }
    }

    private func stream(_ c: NWConnection, _ chunk: Data, sent: Int) {
        guard sent < 256 << 20 else { c.cancel(); return }
        c.send(content: chunk, completion: .contentProcessed { [weak self] e in if let self, e == nil { self.stream(c, chunk, sent: sent + chunk.count) } else { c.cancel() } })
    }
}
