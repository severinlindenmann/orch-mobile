import Foundation
import Network
import Testing
@testable import OrchClient

/// TLS refusal tests for the real sender. There is deliberately no TLS-skip option anywhere, so these can only check refusals:
/// an untrusted certificate (and an old protocol version) must end in `.disconnected` before any request bytes reach the server.
/// They need `/usr/bin/openssl` (or any `openssl` on PATH) and skip cleanly without it.
@Suite(.serialized) struct TLSRefusalTests {
    static var openssl: String? {
        ["/usr/bin/openssl", "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    final class OpenSSLServer: @unchecked Sendable {
        let port: UInt16
        private let process: Process
        private let dir: URL
        private let log: URL

        /// nil when the server could not be started (e.g. the build lacks the requested protocol).
        static func start(extra: [String]) async throws -> OpenSSLServer? {
            guard let openssl = TLSRefusalTests.openssl else { return nil }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("orch-tls-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let key = dir.appendingPathComponent("k.pem"), cert = dir.appendingPathComponent("c.pem")
            let gen = Process()
            gen.executableURL = URL(fileURLWithPath: openssl)
            gen.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", cert.path, "-days", "1", "-subj", "/CN=localhost",
                             "-addext", "subjectAltName=DNS:localhost"]
            gen.standardOutput = FileHandle.nullDevice; gen.standardError = FileHandle.nullDevice
            try gen.run(); gen.waitUntilExit()
            guard gen.terminationStatus == 0 else { try? FileManager.default.removeItem(at: dir); return nil }
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
                if !p.isRunning { server.stop(); return nil }
                if server.accepts() { return server }
                try await Task.sleep(for: .milliseconds(100))
            }
            server.stop(); return nil
        }

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

    func expectRefused(_ extra: [String], _ name: String) async throws {
        guard let server = try await OpenSSLServer.start(extra: extra) else { return }   // not available here: skip this case
        defer { server.stop() }
        let sender = try NWRequestSender(origin: "https://localhost:\(server.port)", requestTimeout: 10, resourceTimeout: 20)
        let request = try WireRequest(method: "GET", target: "/healthz", clientAddress: "x")
        await #expect(throws: TransportError.disconnected, "\(name)") { _ = try await sender.send(request) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!server.output.contains("GET /"), "\(name): the server saw a request")
    }

    @Test(.enabled(if: TLSRefusalTests.openssl != nil, "openssl not found")) func aSelfSignedCertificateIsRefusedBeforeAnyRequest() async throws {
        try await expectRefused([], "self-signed")
    }

    @Test(.enabled(if: TLSRefusalTests.openssl != nil, "openssl not found")) func tls11IsRefused() async throws {
        // OpenSSL 3 needs security level 0 to offer TLS 1.1 at all; builds without it fail to start and the case is skipped.
        try await expectRefused(["-tls1_1", "-cipher", "DEFAULT:@SECLEVEL=0"], "tls1.1")
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
        for host in ["wrong.host.badssl.com", "expired.badssl.com", "self-signed.badssl.com"] {
            let sender = try NWRequestSender(origin: "https://\(host)", requestTimeout: 15, resourceTimeout: 30)
            await #expect(throws: TransportError.disconnected, "\(host)") { _ = try await sender.send(WireRequest(method: "GET", target: "/", clientAddress: "x")) }
        }
    }
}
