import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
import OrchStore

@Suite struct DropPublicAPITests {
    @Test func verifiedMetadataIsAvailableWithoutInternalKeys() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let layout = try StoreLayout(appRoot: root.appendingPathComponent("app"), pushGroupRoot: root.appendingPathComponent("push"), shareGroupRoot: root.appendingPathComponent("share"), realm: "demo")
        let vault = SecretVault(group: .keys, backend: InMemoryVaultBackend())
        let custody = DefaultCustody.make(vault: vault), clock = TestClock()
        let env = try await DemoSetup.setup(layout: layout, custody: custody, clock: clock, wall: clock)
        let primary = DemoSetup.makeAuthority(env)
        let host = try DemoSetup.makeHost(env, primary: primary)
        let keys = DemoKeys(env.device.publicKeys)
        let certificate = try await primary.certify(keys, label: "Phone")
        await env.relay.registerOwner(primary.publicKey)
        try await env.relay.publishCertificate(certificate)
        _ = try await host.publishInitial(relay: env.relay, transport: env.transport, devices: [(keys, certificate, ["look", "decide", "operate", "type"])])
        let ws = host.workspace
        try await env.index.addWorkspace(ws: ws.hex, generation: 1)
        let container = try await WorkspaceContainer(index: env.index, ws: ws.hex, generation: 1)
        let session = try await WorkspaceSession(WorkspaceSessionConfig(context: env.context, workspace: ws, generation: 1,
            identity: env.device, wsk: host.wskPublic, container: container, vault: vault.scoped(to: .demo), transport: env.transport, clock: clock, wall: clock))
        let token = try await RelayClient(transport: env.transport).openDeviceSession(identity: env.device, deviceID: env.deviceID).session
        let card = try Card.verify(await RelayClient(transport: env.transport).card(workspace: ws, session: token), ownerKey: primary.publicKey)
        let service = try DropService(session: session, card: card)
        let sent = try await service.send(Data("hello".utf8), name: "hello.txt", mime: "text/plain", transcript: "a note")
        let result: DropDownload = try await service.downloadVerified(sent)
        #expect(result.metadata.name == "hello.txt")
        #expect(result.metadata.mime == "text/plain")
        #expect(result.metadata.size == 5)
        #expect(result.metadata.transcript == "a note")
        #expect(try Data(contentsOf: result.url) == Data("hello".utf8))
    }
}
