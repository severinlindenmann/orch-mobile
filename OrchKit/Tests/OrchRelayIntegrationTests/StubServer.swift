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
        /// Send each piece with its own write, `gapMs` apart, then close (fragmentation).
        case pieces([Data], gapMs: Int)
        /// Send `prefix`, then one byte every `everyMs` until the peer goes away (slow loris).
        case trickle(prefix: Data, everyMs: Int)
        /// Send the bytes and keep the connection open.
        case bytesThenHang(Data)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "stub-server")
    private let lock = NSLock()
    private var hits: [String: Int] = [:]
    private var seen: [Request] = []
    private var handler: @Sendable (Request) -> Behaviour = { _ in .raw(StubServer.http(200, body: "{}")) }
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0
    /// false: answer as soon as the request head is complete, without waiting for its body (an early final response).
    var readsRequestBody = true

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
                if readsRequestBody, b.count - r.upperBound < length, err == nil, !done { self.read(c, b); return }
                let req = Request(method: String(first[0]), target: String(first[1]), headers: headers)
                let h: @Sendable (Request) -> Behaviour = self.lock.withLock { self.hits[req.target, default: 0] += 1; self.seen.append(req); return self.handler }
                self.respond(c, h(req))
            } else if err != nil || done { c.cancel() } else { self.read(c, b) }
        }
    }

    private func drain(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, done, err in
            if done || err != nil { c.cancel() } else { self?.drain(c) }
        }
    }

    private func respond(_ c: NWConnection, _ b: Behaviour) {
        switch b {
        case .raw(let d):
            // An early reply (request body unread) must not be followed by a close while the client is still writing: closing a socket
            // with unread input sends a RST that can discard the reply. So keep draining and discarding the request until the client
            // closes its side (the sender cancels as soon as it has the final reply); the connection is cancelled then, or by stop().
            c.send(content: d, completion: .contentProcessed { [weak self] _ in
                if self?.readsRequestBody == false { self?.drain(c) } else { c.cancel() }
            })
        case .truncated(let d): c.send(content: d, completion: .contentProcessed { _ in c.cancel() })
        case .hang: break
        case .bytesThenHang(let d): c.send(content: d, completion: .contentProcessed { _ in })
        case .pieces(let ps, let gap): sendPieces(c, ps[...], gap)
        case .trickle(let prefix, let every):
            c.send(content: prefix, completion: .contentProcessed { [weak self] e in if let self, e == nil { self.trickle(c, every) } else { c.cancel() } })
        case .endless(let n):
            let head = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\n\r\n".utf8)
            let chunk = Data(String(n, radix: 16).utf8) + Data("\r\n".utf8) + Data(repeating: 0x78, count: n) + Data("\r\n".utf8)
            c.send(content: head, completion: .contentProcessed { [weak self] e in guard let self else { return };  if e == nil { self.stream(c, chunk, sent: 0) } else { c.cancel() } })
        }
    }

    private func sendPieces(_ c: NWConnection, _ ps: ArraySlice<Data>, _ gap: Int) {
        guard let first = ps.first else { c.cancel(); return }
        c.send(content: first, completion: .contentProcessed { [weak self] e in
            guard let self, e == nil else { c.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + .milliseconds(gap)) { self.sendPieces(c, ps.dropFirst(), gap) }
        })
    }

    private func trickle(_ c: NWConnection, _ every: Int) {
        queue.asyncAfter(deadline: .now() + .milliseconds(every)) { [weak self] in
            c.send(content: Data([0x20]), completion: .contentProcessed { e in if let self, e == nil { self.trickle(c, every) } else { c.cancel() } })
        }
    }

    private func stream(_ c: NWConnection, _ chunk: Data, sent: Int) {
        guard sent < 256 << 20 else { c.cancel(); return }
        c.send(content: chunk, completion: .contentProcessed { [weak self] e in if let self, e == nil { self.stream(c, chunk, sent: sent + chunk.count) } else { c.cancel() } })
    }
}
