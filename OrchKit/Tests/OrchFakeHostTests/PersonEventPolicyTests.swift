import CryptoKit
import Foundation
import Testing
import OrchCustody
import OrchProtocol
@testable import OrchClient
@testable import OrchFakeHost

/// C2b increment 1: where a person event may be signed (custody provenance, `PersonEventPolicy.derive`, `ProcessLocalWriteGrant`) and what
/// a transport lets through (`RoutedRelayTransport` construction and `bridgePost`'s `WritePermit`). No write is sent yet.

/// A sender that stands for the network: it does NOT conform to `InProcessDemoSender`.
private final class NetworkLikeSender: RequestSender, @unchecked Sendable {
    private let lock = NSLock()
    private var seen = 0
    let origin: String
    init(origin: String) { self.origin = origin }
    var count: Int { lock.withLock { seen } }
    func send(_ request: WireRequest) async throws -> WireReply {
        lock.withLock { seen += 1 }
        return try WireReply(status: 202, headers: [:], body: Data())
    }
}

/// A signer that counts: the policy and the transport must refuse before any key is used.
private final class CountingSigner: Signer, @unchecked Sendable {
    let inner: SoftwareSigner
    private let lock = NSLock()
    private var n = 0
    var uses: Int { lock.withLock { n } }
    init() { inner = SoftwareSigner() }
    var publicKey: SigningPublicKey { inner.publicKey }
    func rawSignature(over message: Data) throws -> Data { lock.withLock { n += 1 }; return try inner.rawSignature(over: message) }
}

/// A forwarding wrapper like the ones a test (or a hostile build) could define: it reports the inner transport's context and forwards
/// everything, the permit included.
private struct ForwardingTransport: RelayTransport {
    let inner: RoutedRelayTransport<NetworkLikeSender>
    var context: RealmContext { inner.context }
    func challenge() async throws -> WireReply { try await inner.challenge() }
    func login(_ body: Data) async throws -> WireReply { try await inner.login(body) }
    func pairingPost(_ envelope: Data, route: PairRoute) async throws -> WireReply { try await inner.pairingPost(envelope, route: route) }
    func pairingPoll(route: PairRoute, after: UInt64?, wait: Int?) async throws -> WireReply { try await inner.pairingPoll(route: route, after: after, wait: wait) }
    func bridgePost(_ envelope: Data, route: BridgeRoute, session: RelaySession, permit: WritePermit?) async throws -> WireReply {
        try await inner.bridgePost(envelope, route: route, session: session, permit: permit)
    }
    func bridgePoll(route: BridgeRoute, after: UInt64?, wait: Int?, session: RelaySession) async throws -> WireReply { try await inner.bridgePoll(route: route, after: after, wait: wait, session: session) }
    func grants(workspaceID: ID16, epoch: UInt32?, session: RelaySession) async throws -> WireReply { try await inner.grants(workspaceID: workspaceID, epoch: epoch, session: session) }
    func memberList(workspaceID: ID16, session: RelaySession) async throws -> WireReply { try await inner.memberList(workspaceID: workspaceID, session: session) }
    func card(workspaceID: ID16, session: RelaySession) async throws -> WireReply { try await inner.card(workspaceID: workspaceID, session: session) }
    func cardKey(workspaceID: ID16, cardSequence: UInt32, session: RelaySession) async throws -> WireReply { try await inner.cardKey(workspaceID: workspaceID, cardSequence: cardSequence, session: session) }
    func registerPush(_ body: Data, session: RelaySession) async throws -> WireReply { try await inner.registerPush(body, session: session) }
    func unregisterPush(_ body: Data, session: RelaySession) async throws -> WireReply { try await inner.unregisterPush(body, session: session) }
    func revocation(deviceID: ID16, after: String?, limit: Int?) async throws -> WireReply { try await inner.revocation(deviceID: deviceID, after: after, limit: limit) }
    func dropPut(objectID: ID16, ifMatch: UInt32, body: Data, session: RelaySession) async throws -> WireReply { try await inner.dropPut(objectID: objectID, ifMatch: ifMatch, body: body, session: session) }
    func dropList(_ query: Data, session: RelaySession) async throws -> WireReply { try await inner.dropList(query, session: session) }
    func dropGet(objectID: ID16, version: UInt32, part: DropPart, session: RelaySession) async throws -> WireReply { try await inner.dropGet(objectID: objectID, version: version, part: part, session: session) }
}

private let ws = ID16(hex: "00112233445566778899aabbccddeeff")!
private let rid = ID16(hex: "ffeeddccbbaa99887766554433221100")!
private let session = RelaySession(token: "tok123")

@Suite struct PersonEventPolicyTests {
    static let liveOrigin = "https://relay.example.org"
    func live() throws -> RealmContext { try RealmContext.live(origin: Self.liveOrigin) }
    func identity(realm: Realm, custody: CustodyKind, signer: (any Signer)? = nil) throws -> DeviceIdentity {
        DeviceIdentity(sig: try signer ?? SoftwareSigner(), kx: try SoftwareKeyAgreer(), realm: realm, custody: custody)
    }
    func grant(for ctx: RealmContext) -> ProcessLocalWriteGrant { ProcessLocalWriteGrant(generation: ctx.generation) }

    // MARK: provenance

    @Test func onlyTheInPackageCustodiesTagAnIdentity() throws {
        // a real software custody says `.software`, in either realm, and the realm lease keeps the tag
        let vault = SecretVault(group: .keys, backend: InMemoryVaultBackend())
        let custody = SoftwareCustody(vault: vault)
        for realm in Realm.allCases {
            let id = try custody.create(realm: realm)
            #expect(id.custody == .software && id.realm == realm)
            #expect(try custody.load(realm: realm).custody == .software)
        }
        let ctx = try live()
        #expect(ctx.leased(try identity(realm: .live, custody: .secureEnclave)).custody == .secureEnclave)
        #expect(ctx.leased(try identity(realm: .live, custody: .software)).custody == .software)
        #expect(try ctx.deviceIdentity(custody: custody, createIfMissing: true).custody == .software)
    }

    @Test func theGrantIsMintedOnlyByDemoSetup() throws {
        // a source scan: `ProcessLocalWriteGrant(` appears in no file of Sources but DemoSetup.swift (and its own declaration)
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var minted: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 50)
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            if text.contains("ProcessLocalWriteGrant(") && f.lastPathComponent != "PersonEventPolicy.swift" { minted.append(f.lastPathComponent) }
            // the policy has no initializer other than `derive`
            if f.lastPathComponent != "PersonEventPolicy.swift" { #expect(!text.contains("PersonEventPolicy("), "\(f.lastPathComponent)") }
        }
        #expect(minted == ["DemoSetup.swift"])
    }

    // MARK: derive

    @Test func liveNeedsASecureEnclaveIdentityUnderALiveContext() throws {
        let ctx = try live()
        let se = DevicePolicy.derive(try identity(realm: .live, custody: .secureEnclave), ctx, nil)
        #expect(se?.auth == .secureEnclaveUnlocked && se?.realm == .live)
        // software custody (Simulator, macOS, any relabelled-by-nobody identity) gets no policy, whatever grant comes with it
        #expect(DevicePolicy.derive(try identity(realm: .live, custody: .software), ctx, nil) == nil)
        #expect(DevicePolicy.derive(try identity(realm: .live, custody: .software), ctx, grant(for: ctx)) == nil)
        // a Demo identity or another realm's grant never helps a Live context
        #expect(DevicePolicy.derive(try identity(realm: .demo, custody: .software), ctx, grant(for: ctx)) == nil)
        #expect(DevicePolicy.derive(try identity(realm: .demo, custody: .secureEnclave), ctx, nil) == nil)
        // the signer is not touched by any of it
        let counting = CountingSigner()
        _ = DevicePolicy.derive(try identity(realm: .live, custody: .software, signer: counting), ctx, grant(for: ctx))
        #expect(counting.uses == 0)
    }

    @Test func demoNeedsADemoIdentityAndAGrantOfThisLifetime() async throws {
        let w = try await World.make(publish: false)
        let ctx = w.env.context
        let p = DevicePolicy.derive(w.env.device, ctx, w.env.processLocalWriteGrant)
        #expect(p?.auth == .passphrase && p?.realm == .demo)
        #expect(DevicePolicy.derive(w.env.device, ctx, nil) == nil)
        // a forged grant of another generation is refused
        #expect(DevicePolicy.derive(w.env.device, ctx, grant(for: try live())) == nil)
        let other = try await World.make(publish: false)
        #expect(DevicePolicy.derive(w.env.device, ctx, other.env.processLocalWriteGrant) == nil)
        // a Live identity under a Demo context
        #expect(DevicePolicy.derive(try identity(realm: .live, custody: .secureEnclave), ctx, w.env.processLocalWriteGrant) == nil)
        // the permit follows the policy
        let permit = p!.permit()
        #expect(permit.auth == .passphrase && permit.realm == .demo && permit.generation === ctx.generation)
    }

    // MARK: transport

    @Test func aDemoContextCannotBeBuiltOverASenderThatIsNotInProcess() throws {
        let sender = NetworkLikeSender(origin: DemoRelay.origin)
        #expect(throws: TransportError.realm(.wrongTransport)) {
            try RoutedRelayTransport(context: RealmContext.demo(DemoCapability(id: ID16.random())), origin: DemoRelay.origin, sender: sender, clientAddress: "a")
        }
        #expect(sender.count == 0)
    }

    @Test func aNetworkTransportTakesOnlyALiveSecureEnclavePermit() async throws {
        let ctx = try live()
        let sender = NetworkLikeSender(origin: ctx.origin)
        let t = try RoutedRelayTransport(context: ctx, origin: ctx.origin, sender: sender, clientAddress: "a")
        let route = BridgeRoute(workspaceID: ws, requestID: rid)
        let env = Data(repeating: 1, count: 40)
        let se = WritePermit(auth: .secureEnclaveUnlocked, realm: .live, generation: ctx.generation)
        // reads (nil) and a Live SE permit go out
        #expect(try await t.bridgePost(env, route: route, session: session, permit: nil).status == 202)
        #expect(try await t.bridgePost(env, route: route, session: session, permit: se).status == 202)
        #expect(sender.count == 2)
        // a passphrase permit does not, nor does a Demo one, nor one of another lifetime, nor a non-unlocked SE auth
        let refused: [(WritePermit, TransportError)] = [
            (WritePermit(auth: .passphrase, realm: .live, generation: ctx.generation), .realm(.wrongTransport)),
            (WritePermit(auth: .secureEnclave, realm: .live, generation: ctx.generation), .realm(.wrongTransport)),
            (WritePermit(auth: .convenience, realm: .live, generation: ctx.generation), .realm(.wrongTransport)),
            (WritePermit(auth: .passphrase, realm: .demo, generation: ctx.generation), .realm(.wrongStore)),
            (WritePermit(auth: .secureEnclaveUnlocked, realm: .demo, generation: ctx.generation), .realm(.wrongStore)),
            (WritePermit(auth: .secureEnclaveUnlocked, realm: .live, generation: RealmGeneration()), .realm(.wrongStore)),
        ]
        for (permit, error) in refused {
            await #expect(throws: error) { _ = try await t.bridgePost(env, route: route, session: session, permit: permit) }
        }
        #expect(sender.count == 2, "a refused permit never reaches the sender")
    }

    @Test func aForwardingWrapperChangesNothing() async throws {
        let ctx = try live()
        let sender = NetworkLikeSender(origin: ctx.origin)
        let wrapper = ForwardingTransport(inner: try RoutedRelayTransport(context: ctx, origin: ctx.origin, sender: sender, clientAddress: "a"))
        let route = BridgeRoute(workspaceID: ws, requestID: rid)
        await #expect(throws: TransportError.realm(.wrongTransport)) {
            _ = try await wrapper.bridgePost(Data(repeating: 1, count: 40), route: route, session: session,
                                             permit: WritePermit(auth: .passphrase, realm: .live, generation: ctx.generation))
        }
        // the 3-argument convenience is a read: nil permit
        #expect(try await wrapper.bridgePost(Data(repeating: 1, count: 40), route: route, session: session).status == 202)
        #expect(sender.count == 1)
    }

    @Test func theInProcessDemoTransportTakesOnlyADemoPassphrasePermit() async throws {
        let w = try await World.make()
        let ctx = w.env.context
        func post(_ permit: WritePermit?, _ n: UInt8) async throws -> Int {
            let r = ID16.fresh(n)
            return try await w.transport.bridgePost(try w.envelope(rid: r), route: BridgeRoute(workspaceID: w.ws, requestID: r), session: w.phoneSession, permit: permit).status
        }
        let demo = DevicePolicy.derive(w.env.device, ctx, w.env.processLocalWriteGrant)!.permit()
        #expect(try await post(nil, 0x41) == 202)
        #expect(try await post(demo, 0x42) == 202)
        // a Live Secure Enclave permit or a permit of another lifetime is refused before the relay sees anything
        await #expect(throws: TransportError.realm(.wrongStore)) { _ = try await post(WritePermit(auth: .secureEnclaveUnlocked, realm: .live, generation: ctx.generation), 0x43) }
        await #expect(throws: TransportError.realm(.wrongStore)) { _ = try await post(WritePermit(auth: .passphrase, realm: .demo, generation: RealmGeneration()), 0x44) }
        await #expect(throws: TransportError.realm(.wrongTransport)) { _ = try await post(WritePermit(auth: .secureEnclaveUnlocked, realm: .demo, generation: ctx.generation), 0x45) }
        // after a reset the permit is dead too
        ctx.invalidate()
        await #expect(throws: (any Error).self) { _ = try await post(demo, 0x46) }
    }
}

/// `PersonEventPolicy` is package-scoped; this spells the one constructor the tests use.
private enum DevicePolicy {
    static func derive(_ identity: DeviceIdentity, _ context: RealmContext, _ grant: ProcessLocalWriteGrant?) -> PersonEventPolicy? {
        PersonEventPolicy.derive(identity: identity, context: context, grant: grant)
    }
}
