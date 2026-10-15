import CryptoKit
import Foundation
import OrchClient
import OrchCustody
@testable import OrchFakeHost
import OrchProtocol
import OrchStore
import OrchTestVectors
import Testing
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
                .openDeviceSession(identity: env.device, deviceID: env.deviceID).session
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

/// A host that really seals: a WSK-like signer and a workspace key, so a device can run the section 8.8 check on what the relay returns.
struct HostRig {
    let signer = SoftwareSigner()
    let wk = SymmetricKey(data: Data(repeating: 9, count: 32))
}

extension World {
    /// A genuine ORB2 response chunk from `rig` to the phone's device: sealed under K_bridge(wk, ws, epoch) and signed by the rig.
    /// P3-D22: the relay stores a response chunk only for a rid it knows. Posts the phone's request for `rid` first.
    @discardableResult
    func postRequest(rid: ID16, epoch: UInt32 = 1) async throws -> WireReply {
        try await transport.bridgePost(try envelope(rid: rid, epoch: epoch), route: BridgeRoute(workspaceID: ws, requestID: rid), session: phoneSession)
    }

    func sealedResponse(rig: HostRig, rid: ID16, seq: UInt64, flags: Bridge.Flags = [], dataBytes: Int = 4, epoch: UInt32 = 1) throws -> Data {
        let h = Bridge.Header(direction: .toDevice, flags: flags, workspace: ws, device: phoneID, rid: rid, seq: seq, tsMs: UInt64(env.wall.nowMs), epoch: epoch)
        let key = Bridge.channelKey(header: h, wk: rig.wk)!
        let plain = try Bridge.frame(meta: ["status": 200], data: Data(repeating: 2, count: dataBytes))
        return try Bridge.seal(header: h, channelKey: key, signer: rig.signer, plaintext: plain)
    }

    func deviceContext(rig: HostRig, epoch: UInt32 = 1) -> Bridge.DeviceContext {
        Bridge.DeviceContext(workspace: ws, device: phoneID, wsk: rig.signer.publicKey, wk: [epoch: rig.wk])
    }

    func check(_ envelope: Data, rig: HostRig, rid: ID16, index: UInt64, last: Bool, epoch: UInt32 = 1) -> Bridge.ResponseOutcome {
        Bridge.checkResponse(envelope, context: deviceContext(rig: rig, epoch: epoch), pending: [rid: Bridge.PendingRequest(next: index, epoch: epoch)],
                             mailbox: .init(id: rid, index: index, last: last, stream: false), nowMs: env.wall.nowMs).outcome
    }

    /// The initial roster: the primary (all scopes) and the phone (look, decide).
    var baseRoster: [(DemoKeys, [String])] { [(primary.deviceKeys, World.all), (phone, ["look", "decide"])] }

    /// One atomic membership publication (P3-D7) straight to the relay: the signed list, every member's (persisted) grant at
    /// `epoch`, and the card-key wraps of `wraps`. The host's own state is not updated.
    @discardableResult
    func publish(_ roster: [(DemoKeys, [String])], epoch: UInt32, listSeq: Int64, wraps: [DemoKeys] = [],
                 session: RelaySession? = nil) async throws -> (listSeq: Int64, epoch: UInt32) {
        let body = try await host.membershipBody(roster: roster, epoch: epoch, listSeq: listSeq, wraps: wraps)
        return try await host.sendMembership(body, relay: relay, session: session ?? hostSession)
    }

    /// A second member device with its own certificate, grant, card-key wrap and a session, added through the honest path.
    func addMember(scopes: [String] = ["look"], listSeq: Int64 = 2) async throws -> (id: ID16, keys: DemoKeys, session: RelaySession) {
        let signer = SoftwareSigner(), kx = SoftwareKeyAgreer()
        let keys = DemoKeys(sig: signer.publicKey, kx: kx.publicKey)
        try await relay.publishCertificate(try await primary.certify(keys, label: "Second", scopesMax: ["look", "decide"]))
        try await publish(baseRoster + [(keys, scopes)], epoch: 1, listSeq: listSeq, wraps: [keys])
        let s = try await RelayClient(transport: transport).openSession(kind: .device, id: keys.deviceID, signer: signer).session
        return (keys.deviceID, keys, s)
    }
}

// MARK: phone-side session

final class Done: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    var value: Bool { lock.withLock { v } }
    func set() { lock.withLock { v = true } }
}

/// The barrier assumes a single consumer stream. Counts events a test's consumer has fully processed; `World.serve` uses it as a barrier against the session's emitted count.
final class Consumed: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    var count: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}

struct Phone {
    let session: WorkspaceSession
    let container: WorkspaceContainer
    let clock: TestClock          // the phone's own clock (may differ from the host's)
}

extension World {
    /// A phone-side session bound to (demo, ws, generation 1) with real storage. `skewMs` makes the phone's wall clock differ.
    func makePhone(skewMs: Int64 = 0, faultsFree: Bool = true, timeout: Duration = .seconds(30), install: Bool = true,
                   transport: (any RelayTransport)? = nil, longPollSeconds: Int? = nil,
                   reader: ReaderRuntime? = nil, sendsReaderDigest: Bool = false) async throws -> Phone {
        let index = env.index
        try await index.addWorkspace(ws: ws.hex, generation: 1)
        let container = try await WorkspaceContainer(index: index, ws: ws.hex, generation: 1)
        let pclock = TestClock(wallStartMs: clock.nowMs + skewMs)
        var cfg = WorkspaceSessionConfig(context: env.context, workspace: ws, generation: 1, identity: env.device, wsk: host.wskPublic,
                                         container: container, vault: vault.scoped(to: .demo), transport: transport ?? env.transport, clock: pclock,
                                         wall: pclock, entropy: SystemEntropy(), pollInterval: .milliseconds(500), responseTimeout: timeout, longPollSeconds: longPollSeconds)
        if let reader { cfg.reader = reader }
        cfg.sendsReaderDigest = sendsReaderDigest
        let session = try await WorkspaceSession(cfg)
        if install { try await session.refreshGrants() }
        return Phone(session: session, container: container, clock: pclock)
    }

    /// Runs `body` while the host serves and both clocks tick, until it finishes. With `consumed`, the clocks also wait for the
    /// body's event consumer to catch up with the session's emitted snapshots before each tick. If `body` has not finished when
    /// `steps` or `timeout` run out, it is cancelled and its result (usually a cancellation error) is returned.
    func serve<T: Sendable>(_ phone: Phone, steps: Int = 200, timeout: Duration = .seconds(120),
                          consumed: Consumed? = nil, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let done = Done()
        let task = Task { () -> Result<T, Error> in
            defer { done.set() }
            do { return .success(try await body()) } catch { return .failure(error) }
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        for _ in 0..<steps {
            if done.value { break }
            // Scheduler yields are not simulated elapsed time. Wait for the client to finish its storage/crypto
            // work and park in polling before ticking; otherwise a near-boundary replay can age out in flight.
            while !done.value && phone.clock.sleeperCount == 0 && ContinuousClock.now < deadline {
                await Task.yield()
            }
            // Consumer barrier: never tick while an emitted snapshot is still unconsumed, otherwise a slow consumer reads a
            // clock that has run ahead of the emission and measures intervals that include its own scheduling delay.
            if let consumed {
                while !done.value && ContinuousClock.now < deadline {
                    let emitted = await phone.session.snapshotsEmitted
                    if consumed.count >= emitted { break }
                    await Task.yield()
                }
            }
            if done.value || ContinuousClock.now >= deadline { break }
            _ = try await host.pump(relay: relay, transport: transport, session: try await host.currentSession(transport: transport))
            clock.advance(milliseconds: 500); phone.clock.advance(milliseconds: 500)
            await Task.yield()
        }
        if !done.value { task.cancel() }
        return try await task.value.get()
    }
}

/// Runs `body` but gives up after `seconds` of real time: cancels it and records an issue naming `what`, so a stream or task
/// that never finishes fails the test fast instead of running into the CI job timeout. Returns nil on timeout.
func boundedWait<T: Sendable>(_ what: String, seconds: Int = 120, _ body: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await body() }
        group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        if first == nil { Issue.record("timed out after \(seconds) s of real time waiting for: \(what)") }
        return first
    }
}
