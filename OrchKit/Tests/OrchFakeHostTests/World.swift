import CryptoKit
import Foundation
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
import OrchStore
import OrchTestVectors
@testable import OrchProtocol

/// Entropy for tests: queued values first (to pin a challenge), then a counter stream.
final class QueuedEntropy: Entropy, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Data] = []
    private var counter: UInt64 = 0
    init(_ queued: [Data] = []) { queue = queued }
    func enqueue(_ d: Data) { lock.withLock { queue.append(d) } }
    func bytes(_ count: Int) -> Data {
        lock.withLock {
            if let first = queue.first, first.count == count { queue.removeFirst(); return first }
            counter += 1
            return Data((0..<count).map { UInt8(truncatingIfNeeded: counter &* 31 &+ UInt64($0) &* 7 &+ 5) })
        }
    }
}

func tempLayout(realm: String = "demo") throws -> StoreLayout {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("orch-s1-" + UUID().uuidString)
    return try StoreLayout(appRoot: base.appendingPathComponent("app"), pushGroupRoot: base.appendingPathComponent("push"),
                           shareGroupRoot: base.appendingPathComponent("share"), realm: realm)
}

struct World {
    let env: DemoEnvironment
    let clock: TestClock
    let custody: any DeviceKeyCustody
    let vault: SecretVault
    let primary: FakePrimary
    let host: FakeHost
    let phone: DemoKeys
    let phoneID: ID16
    let primaryID: ID16
    let phoneCert: JSONValue
    let hostSession: RelaySession
    let phoneSession: RelaySession
    var relay: FakeRelay { env.relay }
    var transport: InProcessRelayTransport { env.transport }
    var ws: ID16 { host.workspace }

    static let all = ["look", "decide", "operate", "type"]

    static func make(faults: any FaultPolicy = NoFaults(), limits: RelayLimits = RelayLimits(), entropy: any Entropy = SystemEntropy(),
                     publish: Bool = true) async throws -> World {
        let clock = TestClock()
        let vault = SecretVault(group: .keys, backend: InMemoryVaultBackend())
        let custody = DefaultCustody.make(vault: vault)
        let env = try await DemoSetup.setup(layout: tempLayout(), custody: custody, clock: clock, wall: clock, entropy: entropy,
                                            faults: faults, limits: limits)
        let primary = DemoSetup.makeAuthority(env)
        let host = try DemoSetup.makeHost(env, primary: primary)
        let phone = DemoKeys(env.device.publicKeys)
        let phoneCert = try await primary.certify(phone, label: "Demo iPhone", scopesMax: ["look", "decide"])
        let primaryCert = try await primary.certifyOwnDevice()
        var hostSession = RelaySession(token: "")
        var phoneSession = RelaySession(token: "")
        if publish {
            hostSession = try await host.publishInitial(relay: env.relay, transport: env.transport, devices: [
                (primary.deviceKeys, primaryCert, all), (phone, phoneCert, ["look", "decide"])])
            phoneSession = try await RelayClient(transport: env.transport)
                .openDeviceSession(identity: env.device, deviceID: env.deviceID, origin: env.context.origin).session
        }
        return World(env: env, clock: clock, custody: custody, vault: vault, primary: primary, host: host, phone: phone, phoneID: env.deviceID,
                     primaryID: primary.deviceID, phoneCert: phoneCert, hostSession: hostSession, phoneSession: phoneSession)
    }

    /// A sealed-looking ORB2 request or response; the relay never opens it, so any channel key will do.
    func envelope(direction: Bridge.Direction = .toHost, device: ID16? = nil, workspace: ID16? = nil, rid: ID16, seq: UInt64 = 1,
                  epoch: UInt32 = 1, flags: Bridge.Flags = [], stream: ID16? = nil, signer: SoftwareSigner? = nil, payload: Int = 16) throws -> Data {
        let h = Bridge.Header(direction: direction, flags: flags, workspace: workspace ?? ws, device: device ?? phoneID, rid: rid, stream: stream,
                              seq: seq, tsMs: UInt64(env.wall.nowMs), epoch: epoch)
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        let plain = try Bridge.frame(meta: ["op": "http"], data: Data(repeating: 1, count: payload))
        if let signer { return try Bridge.seal(header: h, channelKey: key, signer: signer, plaintext: plain) }
        return try Bridge.seal(header: h, channelKey: key, signer: env.device.sig, plaintext: plain)
    }
}

func json(_ r: WireReply) throws -> [String: JSONValue] {
    try StrictJSON.parse(r.body).object ?? [:]
}

func errorCode(_ r: WireReply) -> String? { (try? json(r))?["error"]?.string }

func hostAPI(_ r: WireReply) -> JSONValue? { (try? json(r))?["host_api"] }

func chunkList(_ r: WireReply) throws -> [HostAPI.Chunk] { try HostAPI.chunks(r.body) }

extension ID16 {
    static func fresh(_ n: UInt8) -> ID16 { ID16(bytes: Data(repeating: n, count: 16))! }
}

/// Read-only navigation of vector JSON (the protocol tests' own helpers are file-private there).
struct J {
    let v: JSONValue
    init(_ v: JSONValue) { self.v = v }
    subscript(_ k: String) -> J { J(v.object?[k] ?? .null) }
    var items: [J] { (v.array ?? []).map(J.init) }
    var str: String { v.string ?? "" }
    var string: String? { v.string }
    var int: Int64? { v.int }
    var i64: Int64 { v.int ?? -1 }
    var hexData: Data { Hex.decode(str)! }
    var id: ID16 { ID16(hex: str)! }
    var sigPub: SigningPublicKey { try! SigningPublicKey(x963: hexData) }
}
