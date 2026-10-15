import Foundation
import Network
import Testing
@testable import OrchClient

/// TLS refusal test for the real sender. There is deliberately no TLS-skip option anywhere, so this can only check that an untrusted
/// (self-signed) certificate ends in `.disconnected`. The TLS 1.2 floor is checked in the opt-in `TLSLiveTests` (tls-v1-1.badssl.com):
/// the macOS system openssl is LibreSSL and cannot serve TLS 1.1 at security level 0, and a self-signed cert would mask the version anyway.
/// It needs `/usr/bin/openssl` (or any `openssl` on PATH) and skip cleanly without it.
@Suite(.serialized) struct TLSRefusalTests {
    static var openssl: String? {
        ["/usr/bin/openssl", "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    final class OpenSSLServer: @unchecked Sendable {
        let port: UInt16
        private let process: Process
        private let dir: URL
        private let log: URL

        /// Throws if openssl exists but the server cannot be started (a test failure, never a silent pass).
        static func start(extra: [String]) async throws -> OpenSSLServer {
            guard let openssl = TLSRefusalTests.openssl else { throw ServerError.notFound }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("orch-tls-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let key = dir.appendingPathComponent("k.pem"), cert = dir.appendingPathComponent("c.pem")
            let gen = Process()
            gen.executableURL = URL(fileURLWithPath: openssl)
            gen.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", cert.path, "-days", "1", "-subj", "/CN=localhost",
                             "-addext", "subjectAltName=DNS:localhost"]
            gen.standardOutput = FileHandle.nullDevice; gen.standardError = FileHandle.nullDevice
            try gen.run(); gen.waitUntilExit()
            guard gen.terminationStatus == 0 else { try? FileManager.default.removeItem(at: dir); throw ServerError.failed("certificate generation") }
            let port = try RunningRelay.freePort()
            let log = dir.appendingPathComponent("server.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: openssl)
            p.arguments = ["s_server", "-accept", String(port), "-cert", cert.path, "-key", key.path, "-www"] + extra
            let h = try FileHandle(forWritingTo: log)
            p.standardOutput = h; p.standardError = h
            try p.run()
            let server = OpenSSLServer(port: port, process: p, dir: dir, log: log)
            // wait for the listener (a plain TCP connect)
            for _ in 0..<50 {
                if !p.isRunning { let out = server.output; server.stop(); throw ServerError.failed("s_server exited: \(out)") }
                if server.accepts() { return server }
                try await Task.sleep(for: .milliseconds(100))
            }
            server.stop(); throw ServerError.failed("s_server never listened")
        }

        enum ServerError: Error { case notFound, failed(String) }

        private init(port: UInt16, process: Process, dir: URL, log: URL) { self.port = port; self.process = process; self.dir = dir; self.log = log }

        private func accepts() -> Bool {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian; a.sin_addr = in_addr(s_addr: UInt32(0x7F000001).bigEndian)
            return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
        }

        var output: String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

        /// Terminates only the process this harness started.
        func stop() {
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(3)
                while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test(.enabled(if: TLSRefusalTests.openssl != nil, "openssl not found")) func aSelfSignedCertificateIsRefused() async throws {
        let server = try await OpenSSLServer.start(extra: [])      // throws (fails the test) if openssl exists but cannot serve
        defer { server.stop() }
        let sender = try NWRequestSender(origin: "https://localhost:\(server.port)", requestTimeout: 10, resourceTimeout: 20)
        let request = try WireRequest(method: "GET", target: "/healthz", clientAddress: "x")
        await #expect(throws: TransportError.disconnected) { _ = try await sender.send(request) }
    }
}

/// Opt-in (not CI): the real internet. `ORCH_TLS_LIVE=1 swift test --package-path OrchKit --no-parallel --filter TLSLiveTests`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ORCH_TLS_LIVE"] == "1", "set ORCH_TLS_LIVE=1 (needs the network)"))
struct TLSLiveTests {
    @Test func theDevRelayAnswersHealthz() async throws {
        let sender = try NWRequestSender(origin: "https://relay.dev.severin.io")
        let r = try await sender.send(WireRequest(method: "GET", target: "/healthz", clientAddress: "x"))
        #expect(r.status == 200)
    }

    @Test func badCertificatesAreRefused() async throws {
        for host in ["wrong.host.badssl.com", "expired.badssl.com", "self-signed.badssl.com", "tls-v1-1.badssl.com:1011"] {
            let sender = try NWRequestSender(origin: "https://\(host)", requestTimeout: 15, resourceTimeout: 30)
            await #expect(throws: TransportError.disconnected, "\(host)") { _ = try await sender.send(WireRequest(method: "GET", target: "/", clientAddress: "x")) }
        }
    }
}
