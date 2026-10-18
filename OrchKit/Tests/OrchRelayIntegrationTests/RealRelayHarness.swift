#if os(macOS)   // Process: the iOS Simulator run of the package tests (dev-sandbox lane) skips the real-relay suites
import Foundation

/// Starts a local orch-relay (`uv run orch-relay serve`) for the integration suites.
///
/// HOW TO RUN (everything else skips cleanly, so CI stays green):
///   ORCH_RELAY_INTEGRATION=1 swift test --package-path OrchKit --no-parallel --filter RealRelayTests
/// Optional: `ORCH_RELAY_DIR` (relay checkout; default `~/orch-dev/orch-relay`), `ORCH_RELAY_UV` (path to `uv`).
/// The suites skip when `ORCH_RELAY_INTEGRATION` is not `1`, the checkout has no `pyproject.toml`, or `uv` cannot be found.
/// Each test starts its own relay on a free loopback port with a fresh temporary data directory, and terminates only the
/// process it started. `ORCH_RELAY_ORIGIN` is set to exactly the origin the test's RealmContext uses (login signatures bind it).
enum RealRelayEnvironment {
    static let relayDir: String = ProcessInfo.processInfo.environment["ORCH_RELAY_DIR"] ?? NSString(string: "~/orch-dev/orch-relay").expandingTildeInPath

    static var uv: String? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let u = env["ORCH_RELAY_UV"] { candidates.append(u) }
        candidates += (env["PATH"] ?? "").split(separator: ":").map { "\($0)/uv" }
        candidates += [NSString(string: "~/.cargo/bin/uv").expandingTildeInPath, "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var available: Bool {
        ProcessInfo.processInfo.environment["ORCH_RELAY_INTEGRATION"] == "1"
            && FileManager.default.fileExists(atPath: relayDir + "/pyproject.toml") && uv != nil
    }
}

struct RelayStartError: Error, CustomStringConvertible { let description: String }

final class RunningRelay: @unchecked Sendable {
    let origin: String
    let port: UInt16
    private let process: Process
    private let dataDir: URL
    private let logURL: URL

    static func start() async throws -> RunningRelay {
        guard let uv = RealRelayEnvironment.uv else { throw RelayStartError(description: "uv not found") }
        let port = try freePort()
        let origin = "http://127.0.0.1:\(port)"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("orch-relay-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var env = ProcessInfo.processInfo.environment
        env["ORCH_RELAY_DATA"] = dir.path
        env["ORCH_RELAY_ORIGIN"] = origin
        env["ORCH_RELAY_PORT"] = String(port)
        let log = dir.appendingPathComponent("relay.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: uv)
        p.arguments = ["run", "orch-relay", "serve", "--host", "127.0.0.1", "--port", String(port)]
        p.currentDirectoryURL = URL(fileURLWithPath: RealRelayEnvironment.relayDir)
        p.environment = env
        let h = try FileHandle(forWritingTo: log)
        p.standardOutput = h; p.standardError = h
        try p.run()
        let relay = RunningRelay(origin: origin, port: port, process: p, dataDir: dir, logURL: log)
        do { try await relay.waitHealthy() } catch { relay.stop(); throw error }
        return relay
    }

    private init(origin: String, port: UInt16, process: Process, dataDir: URL, logURL: URL) {
        self.origin = origin; self.port = port; self.process = process; self.dataDir = dataDir; self.logURL = logURL
    }

    /// A single-use invite from the relay's own admin CLI (same data dir).
    func createInvite() async throws -> String {
        guard let uv = RealRelayEnvironment.uv else { throw RelayStartError(description: "uv not found") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: uv)
        p.arguments = ["run", "orch-relay", "invite", "create", "--ttl", "1h"]
        p.currentDirectoryURL = URL(fileURLWithPath: RealRelayEnvironment.relayDir)
        var env = ProcessInfo.processInfo.environment
        env["ORCH_RELAY_DATA"] = dataDir.path
        p.environment = env
        let out = Pipe()
        p.standardOutput = out; p.standardError = out
        let data: Data = try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { _ in
                cont.resume(returning: (try? out.fileHandleForReading.readToEnd()) ?? Data())
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
        let code = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0, !code.isEmpty, !code.contains(" ") else { throw RelayStartError(description: "invite create failed: \(code)") }
        return code
    }

    private func waitHealthy() async throws {
        let url = URL(string: origin + "/healthz")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for _ in 0..<150 {
            if !process.isRunning { throw RelayStartError(description: "relay exited early: " + log()) }
            if let (_, r) = try? await session.data(from: url), (r as? HTTPURLResponse)?.statusCode == 200 { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw RelayStartError(description: "relay did not become healthy: " + log())
    }

    func log() -> String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }

    /// Terminates the process this harness started (and nothing else), then removes the data directory.
    func stop() {
        if process.isRunning {
            process.terminate()            // uv forwards SIGTERM to the relay it spawned
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: dataDir)
    }

    static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RelayStartError(description: "socket") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0; addr.sin_addr = in_addr(s_addr: UInt32(0x7F000001).bigEndian)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw RelayStartError(description: "bind") }
        var out = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &out) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        guard got == 0 else { throw RelayStartError(description: "getsockname") }
        return UInt16(bigEndian: out.sin_port)
    }
}

#endif
