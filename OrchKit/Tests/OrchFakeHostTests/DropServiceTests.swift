import CryptoKit
import Foundation
import Testing
@testable import OrchClient
@testable import OrchFakeHost
import OrchCustody
import OrchProtocol
import OrchShareStaging
import OrchStore

extension World {
    static func drop(faults: any FaultPolicy = NoFaults(), limits: RelayLimits = RelayLimits(), lateMember: Bool = false) async throws -> World {
        let w = try await World.make(faults: faults, limits: limits, publish: false)
        let cert = try await w.primary.certify(w.phone, label: "Sender", scopesMax: World.all)
        await w.relay.registerOwner(w.primary.publicKey)
        try await w.relay.publishCertificate(cert)
        var devices = [(w.primary.deviceKeys, try await w.primary.certifyOwnDevice(), World.all)]
        if !lateMember { devices.append((w.phone, cert, World.all)) }
        let hs = try await w.host.publishInitial(relay: w.relay, transport: w.transport, devices: devices)
        let ps = try await RelayClient(transport: w.transport).openDeviceSession(identity: w.env.device, deviceID: w.phoneID).session
        return World(env: w.env, clock: w.clock, custody: w.custody, vault: w.vault, primary: w.primary, host: w.host, phone: w.phone,
                     phoneID: w.phoneID, primaryID: w.primaryID, phoneCert: cert, hostSession: hs, phoneSession: ps)
    }
    func dropService(_ phone: Phone) async throws -> DropService {
        let raw = try await RelayClient(transport: transport).card(workspace: ws, session: phoneSession)
        return try DropService(session: phone.session, card: Card.verify(raw, ownerKey: primary.publicKey), ownerKey: primary.publicKey)
    }
    func dropBody(id: ID16, parent: DropDescriptor? = nil, kind: String = "file") async throws -> Data {
        let card = try Card.verify(await RelayClient(transport: transport).card(workspace: ws, session: phoneSession), ownerKey: primary.publicKey)
        let data = Data("Hello Drop".utf8)
        let key = try #require(await host.wks[1])
        return try DropUpload.seal(data, metadata: DropMetadata(name: "hello.txt", mime: "text/plain", size: Int64(data.count), transcript: nil),
            object: id, workspace: ws, author: phoneID, authorKind: "device", signer: env.device.sig, wxk: card.wxk, wxkVersion: card.wxkVersion,
            sender: env.device.publicKeys.kx, wk: key, epoch: 1, now: clock.nowMs, expiry: kind == "document" || parent != nil ? nil : clock.nowMs + 60000,
            parent: parent, kind: kind)
    }
}

@Suite struct DropServiceTests {
    @Test func testDropPutProtocolRoute() async throws {
        let w = try await World.drop(), id = ID16.fresh(0x71)
        let body = try await w.dropBody(id: id)
        let r = try await w.transport.dropPut(objectID: id, ifMatch: 0, body: body, session: w.phoneSession)
        #expect(r.status == 201)
        let got = try await w.transport.dropGet(objectID: id, version: 1, part: .blob, session: w.phoneSession)
        #expect(got.status == 200 && got.body.prefix(4) == Drop.magic)
        let wrong = try await w.relay.send(WireRequest(method: "PUT", target: "/v2/drop/\(id.hex)/versions/1", headers: ["authorization": "Bearer \(w.phoneSession.token)"], body: body, clientAddress: "test"))
        #expect(wrong.status != 201)
    }
    @Test func testDropPutRequiresIfMatch428() async throws {
        let w = try await World.drop(), id = ID16.fresh(0x72)
        let body = try await w.dropBody(id: id)
        for value in [nil, "", "01", "-1", "1.0", "18446744073709551616"] as [String?] {
            var headers = ["authorization": "Bearer \(w.phoneSession.token)"]
            headers["if-match"] = value
            let r = try await w.relay.send(WireRequest(method: "PUT", target: "/v2/drop/\(id.hex)/versions", headers: headers, body: body, clientAddress: "test"))
            #expect(r.status == 428 && errorCode(r) == "precondition_required")
        }
    }
    @Test func testDropCreateIfMatchZeroProposal() async throws {
        let w = try await World.drop(), id = ID16.fresh(0x73)
        let body = try await w.dropBody(id: id)
        #expect(try await w.transport.dropPut(objectID: id, ifMatch: 1, body: body, session: w.phoneSession).status == 409)
        #expect(try await w.transport.dropPut(objectID: id, ifMatch: 0, body: body, session: w.phoneSession).status == 201)
        // the very same descriptor again is an exact retry: 200 before the CAS (protocol 19.9), and not stored twice
        let again = try await w.transport.dropPut(objectID: id, ifMatch: 0, body: body, session: w.phoneSession)
        #expect(again.status == 200 && again.header("etag") == "\"1\"")
        // another descriptor for the taken slot is the CAS conflict
        let other = try await w.dropBody(id: id)
        let conflict = try await w.transport.dropPut(objectID: id, ifMatch: 0, body: other, session: w.phoneSession)
        #expect(conflict.status == 409 && errorCode(conflict) == "version_conflict")
    }
    @Test func testDropCASConflict409AndLostResponse() async throws {
        let faults = ScriptedFaults(), w = try await World.drop(faults: faults)
        let phone = try await w.makePhone(), service = try await w.dropService(phone)
        faults.enqueue(.disconnect, at: .afterCommitBeforeResponse, routePrefix: "PUT /v2/drop/")
        let object = try await service.send(Data("durable".utf8), name: "note", kind: .document)
        #expect(object.descriptor.version == 1)
        let version2 = try await service.send(Data("second".utf8), name: "note", document: object)
        #expect(version2.descriptor.version == 2)
        let writer = try await w.independentDropWriter()
        await #expect(throws: DropError.versionConflict(current: 2)) { _ = try await writer.send(Data("fork".utf8), name: "note", document: object) }
        #expect(try await writer.resumeUploads().isEmpty)
        #expect(try await writer.failedUploads().first?.reason == "versionConflict(current: 2)")
        await #expect(throws: DropError.versionConflict(current: 2)) { _ = try await writer.retryUpload(object: object.descriptor.object, version: 2) }
        #expect(try await service.resumeUploads().isEmpty)
    }
    @Test func testTamperedBlobDescriptorAndRollbackRejected() async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let first = try await service.send(Data("first".utf8), name: "note", kind: .document)
        _ = try await service.send(Data("second".utf8), name: "note", document: first)
        await #expect(throws: (any Error).self) { _ = try await service.download(first) }
        let id = ID16.fresh(0x74)
        var body = try DropTestFrame.json(await w.dropBody(id: id))
        var blob = B64U.decode(body["blob"]!.string!)!; blob[blob.count - 1] ^= 1
        body["blob"] = .string(B64U.encode(blob))
        #expect(try await w.transport.dropPut(objectID: id, ifMatch: 0, body: DropTestFrame.frame(body), session: w.phoneSession).status == 400)
        body = try DropTestFrame.json(await w.dropBody(id: id))
        var signed = body["descriptor"]!.object!, raw = signed["o"]!.object!
        raw["created_ms"] = 0; signed["o"] = .object(raw); body["descriptor"] = .object(signed)
        #expect(try await w.transport.dropPut(objectID: id, ifMatch: 0, body: DropTestFrame.frame(body), session: w.phoneSession).status == 401)
    }
    @Test func testNewMemberRewrapWithoutHistoricalGrant() async throws {
        let w = try await World.drop(lateMember: true)
        try await w.host.seedDrop(relay: w.relay, transport: w.transport, session: w.hostSession)
        try await w.host.rotate(remaining: [(w.phone, World.all), (w.primary.deviceKeys, World.all)], relay: w.relay, session: w.hostSession)
        let phone = try await w.makePhone(install: false)
        // Model a newly admitted phone: it has only the new epoch key, never WK_1.
        try await phone.session.install(epoch: 2, key: #require(await w.host.wks[2]))
        let service = try await w.dropService(phone)
        let objects = try await service.list()
        #expect(objects.count == 4)
        let url = try await w.serve(phone) { try await service.download(objects[0]) }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect((try? w.vault.scoped(to: .demo).get(ws: w.ws.hex, purpose: "wk.1")) == nil)
    }
    @Test func testDownloadAndWipeRemovesPlaintext() async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let object = try await service.send(Data("plaintext".utf8), name: "../../escape")
        let url = try await service.download(object)
        #expect(try Data(contentsOf: url) == Data("plaintext".utf8))
        #expect(url.deletingLastPathComponent().lastPathComponent == "files")
        try await LocalWipe(index: w.env.index).wipe(ws: w.ws.hex, generation: 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await #expect(throws: (any Error).self) { _ = try await service.download(object) }
    }
}

extension DropServiceTests {
    @Test func testShareJobImportEndToEnd() async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let area = ShareArea(shareGroupRoot: w.env.layout.shareGroupRoot)
        let target = ShareTarget(realm: "demo", ws: w.ws.hex, name: "Laptop", hue: 0, generation: 1)
        let staging = try StagingSession(area: area, target: target, now: { Date(timeIntervalSince1970: 1790000000) })
        try staging.add(.text("shared plaintext")); try staging.add(.url("https://example.invalid/")); try staging.commit(note: "sealed note")
        let inbox = ShareInbox(area: area)
        let job = try #require(inbox.claim(live: [LiveDestination(realm: "demo", ws: w.ws.hex, generation: 1)]).claimed.first)
        async let firstImport = service.importShareJob(job, inbox: inbox)
        async let secondImport = service.importShareJob(job, inbox: inbox)
        async let recovery = service.resumeUploads()
        let (sent, duplicate, _) = try await (firstImport, secondImport, recovery)
        #expect(sent == duplicate)
        #expect(sent.count == 2 && !FileManager.default.fileExists(atPath: job.dir.path))

        let identity = DeviceIdentity(sig: SoftwareSigner(), kx: SoftwareKeyAgreer(), realm: .demo, custody: .software)
        let keys = DemoKeys(identity.publicKeys)
        try await w.relay.publishCertificate(w.primary.certify(keys, label: "Receiver", scopesMax: World.all))
        try await w.host.rotate(remaining: [(w.phone, World.all), (w.primary.deviceKeys, World.all), (keys, World.all)], relay: w.relay, session: w.hostSession)
        let layout = try tempLayout(), index = try await WorkspaceIndex(layout: layout)
        try await index.addWorkspace(ws: w.ws.hex, generation: 1)
        let container = try await WorkspaceContainer(index: index, ws: w.ws.hex, generation: 1)
        let vault = SecretVault(group: .keys, backend: InMemoryVaultBackend())
        let cfg = WorkspaceSessionConfig(context: w.env.context, workspace: w.ws, generation: 1, identity: identity, wsk: w.host.wskPublic,
            container: container, vault: vault.scoped(to: .demo), transport: w.transport, clock: w.clock, wall: w.clock)
        let receiver = try await WorkspaceSession(cfg)
        try await receiver.refreshGrants()
        let card = try Card.verify(await RelayClient(transport: w.transport).card(workspace: w.ws, session: w.phoneSession), ownerKey: w.primary.publicKey)
        let cert = try DeviceCertificate.verify(w.phoneCert, personKey: w.primary.publicKey, nowMs: w.clock.nowMs, revoked: [])
        let receiving = try DropService(session: receiver, card: card, certificates: [cert])
        let objects = try await receiving.list()
        #expect(objects.count == 2)
        // Rewrap via the real host, then the other device opens only the current-epoch WK wrap.
        for object in objects { try await w.host.rewrapDrop(object: object.descriptor.object, version: 1, relay: w.relay, session: w.hostSession) }
        let refreshed = try await receiving.list()
        var contents: Set<Data> = []
        for object in refreshed { contents.insert(try Data(contentsOf: await receiving.download(object))) }
        #expect(contents == [Data("shared plaintext".utf8), Data("https://example.invalid/".utf8)])
        #expect((try? vault.scoped(to: .demo).get(ws: w.ws.hex, purpose: "wk.1")) == nil)
    }

    @Test func testClaimRace() async throws {
        let w = try await World.drop()
        let other = try DemoSetup.makeHost(w.env, primary: w.primary, name: "Other")
        let otherSession = try await other.publishInitial(relay: w.relay, transport: w.transport, devices: [(w.phone, w.phoneCert, World.all)])
        let id = ID16.fresh(0x79)
        var body = try DropTestFrame.json(await w.dropBody(id: id))
        var raw = body["descriptor"]!.object!["o"]!.object!
        raw["recipients"] = "inbox"
        body["descriptor"] = try SignedObject.sign(raw, kind: .dropObject, signer: w.env.device.sig).json
        // an inbox object carries one `wxk` wrap to its own space and no `wk` wrap (protocol 19.9)
        body["wraps"] = .array(body["wraps"]!.array!.filter { $0.object?["target_kind"] == "wxk" })
        #expect(try await w.transport.dropPut(objectID: id, ifMatch: 0, body: DropTestFrame.frame(body), session: w.phoneSession).status == 201)
        func claim(_ host: FakeHost, _ session: RelaySession) async throws -> WireReply {
            let record = DropWrapRecord(object: id, version: 1, targetKind: .wk, target: host.workspace, keyVersion: 1, wrap: Data(repeating: 1, count: 64))
            let signed = try DropClaim.make(wsk: host.wsk, object: id, workspace: host.workspace, wrap: record)
            return try await w.relay.send(WireRequest(method: "POST", target: "/v2/drop/\(id.hex)/claim",
                headers: ["authorization": "Bearer \(session.token)"], body: canonicalJSON(signed.json), clientAddress: "test"))
        }
        // another workspace cannot claim it (cross-workspace addressing is P6); the addressed workspace's claims are idempotent
        #expect(try await claim(other, otherSession).status == 403)
        async let a = claim(w.host, w.hostSession)
        async let b = claim(w.host, w.hostSession)
        let replies = try await [a, b]
        #expect(replies.map(\.status) == [200, 200])
        let fetched = try await w.transport.dropGet(objectID: id, version: 1, part: .wraps, session: w.hostSession)
        #expect(fetched.status == 200)
        #expect(try json(fetched)["wraps"]?.array?.count == 1)
        #expect(try await w.transport.dropGet(objectID: id, version: 1, part: .blob, session: otherSession).status == 403)
    }

    @Test func testDropExpiryQuotaAndReadScope() async throws {
        var limits = RelayLimits(); limits.maxDropVersions = 1
        let w = try await World.drop(limits: limits), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let first = try await service.send(Data(), name: "empty", expiresMs: phone.clock.nowMs + 61_000)
        await #expect(throws: DropError.storageFull(quota: "drop_versions", retryAfterSeconds: 600)) { _ = try await service.send(Data(), name: "over quota") }
        phone.clock.advance(by: .seconds(62)); w.clock.advance(by: .seconds(62))
        #expect(try await service.list(.sending).isEmpty)
        await #expect(throws: (any Error).self) { _ = try await service.download(first) }
        let readonly = try await World.make(), id = ID16.fresh(0x7a)
        let body = try await readonly.dropBody(id: id)
        #expect(try await readonly.transport.dropPut(objectID: id, ifMatch: 0, body: body, session: readonly.phoneSession).status == 403)
    }
}

private actor DropAdversary: RequestSender, InProcessDemoSender {
    nonisolated let origin: String
    let relay: FakeRelay
    var corruptBlob = false
    var corruptDescriptor = false
    var replayList: Data?
    init(_ relay: FakeRelay) { self.relay = relay; origin = relay.origin }
    func set(blob: Bool = false, descriptor: Bool = false, list: Data? = nil) {
        corruptBlob = blob; corruptDescriptor = descriptor; replayList = list
    }
    func send(_ request: WireRequest) async throws -> WireReply {
        let reply = try await relay.send(request)
        if request.target.hasSuffix("/drop/list"), let replayList { return try WireReply(status: 200, body: replayList) }
        if corruptBlob, request.target.hasSuffix("/blob"), reply.status == 200 {
            var body = reply.body; body[body.count - 1] ^= 1
            return try WireReply(status: 200, headers: reply.headers, body: body)
        }
        if corruptDescriptor, request.target.hasSuffix("/drop/list"), reply.status == 200 {
            var o = try StrictJSON.parse(reply.body).object!, objects = o["objects"]!.array!
            var entry = objects[0].object!, signed = entry["descriptor"]!.object!, raw = signed["o"]!.object!
            raw["created_ms"] = 0; signed["o"] = .object(raw); entry["descriptor"] = .object(signed)
            objects[0] = .object(entry); o["objects"] = .array(objects)
            return try WireReply(status: 200, body: canonicalJSON(.object(o)))
        }
        return reply
    }
}
extension DropServiceTests {
    @Test func testReaderRejectsTamperingAndPersistedRollback() async throws {
        let w = try await World.drop(), adversary = DropAdversary(w.relay)
        let transport = try RoutedRelayTransport(context: w.env.context, origin: w.env.context.origin, sender: adversary, clientAddress: "test")
        let phone = try await w.makePhone(transport: transport), service = try await w.dropService(phone)
        let first = try await service.send(Data("secret".utf8), name: "doc", kind: .document)
        let query = try canonicalJSON(["workspace_id": .string(w.ws.hex), "direction": "sending"])
        let old = try await w.transport.dropList(query, session: w.phoneSession).body
        await adversary.set(blob: true)
        await #expect(throws: (any Error).self) { _ = try await service.download(first) }
        await adversary.set(descriptor: true)
        let tampered = try await service.listVerifiedRows(.sending)
        #expect(tampered.objects.isEmpty && tampered.blocked.count == 1)
        await adversary.set()
        _ = try await service.send(Data("updated".utf8), name: "doc", document: first)
        let restarted = try await w.dropService(phone)
        await adversary.set(list: old)
        let rolledBack = try await restarted.listVerifiedRows(.sending)
        #expect(rolledBack.objects.isEmpty && rolledBack.blocked.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: w.env.layout.filesDir(w.ws.hex).path).isEmpty)
    }

    @Test func testShareImportRetainsPlaintextUntilConfirmedAndRetriesSameObject() async throws {
        let faults = ScriptedFaults(), w = try await World.drop(faults: faults)
        let phone = try await w.makePhone(), service = try await w.dropService(phone)
        let area = ShareArea(shareGroupRoot: w.env.layout.shareGroupRoot)
        let staging = try StagingSession(area: area, target: ShareTarget(realm: "demo", ws: w.ws.hex, name: "Laptop", hue: 0, generation: 1))
        try staging.add(.text("keep until durable")); try staging.commit(note: nil)
        let inbox = ShareInbox(area: area)
        let job = try #require(inbox.claim(live: [LiveDestination(realm: "demo", ws: w.ws.hex, generation: 1)]).claimed.first)
        faults.enqueue(.disconnect, at: .afterCommitBeforeResponse, routePrefix: "GET /v2/drop/")
        await #expect(throws: (any Error).self) { _ = try await service.importShareJob(job, inbox: inbox) }
        #expect(FileManager.default.fileExists(atPath: job.dir.path))
        let restarted = try await w.dropService(phone)
        _ = try await restarted.importShareJob(job, inbox: inbox)
        #expect(!FileManager.default.fileExists(atPath: job.dir.path))
        #expect(try await restarted.list(.sending).count == 1)
    }
}

extension DropServiceTests {
    @Test func testClientVMDemoSeedsClaimedDeploymentAndRunbook() async throws {
        let w = try await World.drop()
        let host = try DemoSetup.makeHost(w.env, primary: w.primary, name: "Client VM", clientHosted: true, demoDropFixtures: true)
        let token = try await host.publishInitial(relay: w.relay, transport: w.transport, devices: [(w.phone, w.phoneCert, World.all)])
        _ = try await host.pump(relay: w.relay, transport: w.transport, session: token)
        _ = try await host.pump(relay: w.relay, transport: w.transport, session: token)
        let query = try canonicalJSON(["workspace_id": .string(host.workspace.hex), "direction": "received"])
        let entries = try json(await w.transport.dropList(query, session: w.phoneSession))["objects"]!.array!
        #expect(entries.count == 2)
        for entry in entries {
            let d = try DropDescriptor.verify(entry.object!["descriptor"]!, authorKey: host.wskPublic)
            if d.objectKind == "file" {
                #expect(d.recipients == .inbox)
                let wraps = try entry.object!["wraps"]!.array!.map(DropWrapRecord.init(json:))
                #expect(wraps.count == 1 && wraps[0].targetKind == .wk)
            } else {
                #expect(d.version == 2)
                let first = try json(await w.transport.dropGet(objectID: d.object, version: 1, part: .descriptor, session: w.phoneSession))["descriptor"]!
                let parent = try DropDescriptor.verify(first, authorKey: host.wskPublic)
                try DropDocument.verifyChain([parent.raw, d.raw])
            }
        }
    }
}

extension DropServiceTests {
    @Test func testDemoSendingFixture() async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let object = try await DemoSetup.seedDropSending(service)
        #expect(try await service.list(.sending).map(\.descriptor.object) == [object.descriptor.object])
    }
}

extension DropServiceTests {
    @Test func testDropPUTRejectsChangedSpaceIdentity() async throws {
        let w = try await World.drop(), id = ID16.fresh(0x7b)
        let other = try DemoSetup.makeHost(w.env, primary: w.primary, name: "Other")
        _ = try await other.publishInitial(relay: w.relay, transport: w.transport, devices: [(w.phone, w.phoneCert, World.all)])
        let first = try await w.dropBody(id: id, kind: "document")
        #expect(try await w.transport.dropPut(objectID: id, ifMatch: 0, body: first, session: w.phoneSession).status == 201)
        let parent = try DropDescriptor(object: DropTestFrame.json(first)["descriptor"]!.object!["o"]!.object!)
        var body = try DropTestFrame.json(await w.dropBody(id: id, parent: parent))
        var raw = body["descriptor"]!.object!["o"]!.object!
        raw["space_id"] = .string(other.workspace.hex)
        body["descriptor"] = try SignedObject.sign(raw, kind: .dropObject, signer: w.env.device.sig).json
        let reply = try await w.transport.dropPut(objectID: id, ifMatch: 1, body: DropTestFrame.frame(body), session: w.phoneSession)
        #expect(reply.status == 403 && errorCode(reply) == "not_eligible")
    }
}

extension World {
    func independentDropWriter(clock receiverClock: TestClock? = nil) async throws -> DropService {
        let identity = DeviceIdentity(sig: SoftwareSigner(), kx: SoftwareKeyAgreer(), realm: .demo, custody: .software)
        let keys = DemoKeys(identity.publicKeys)
        try await relay.publishCertificate(primary.certify(keys, label: "Writer", scopesMax: World.all))
        try await host.rotate(remaining: [(phone, World.all), (primary.deviceKeys, World.all), (keys, World.all)], relay: relay, session: hostSession)
        let index = try await WorkspaceIndex(layout: tempLayout())
        try await index.addWorkspace(ws: ws.hex, generation: 1)
        let container = try await WorkspaceContainer(index: index, ws: ws.hex, generation: 1)
        let vault = SecretVault(group: .keys, backend: InMemoryVaultBackend())
        let config = WorkspaceSessionConfig(context: env.context, workspace: ws, generation: 1, identity: identity, wsk: host.wskPublic,
            container: container, vault: vault.scoped(to: .demo), transport: transport, clock: receiverClock ?? clock, wall: receiverClock ?? clock)
        let session = try await WorkspaceSession(config)
        try await session.refreshGrants()
        let card = try Card.verify(await RelayClient(transport: transport).card(workspace: ws, session: phoneSession), ownerKey: primary.publicKey)
        let cert = try DeviceCertificate.verify(phoneCert, personKey: primary.publicKey, nowMs: clock.nowMs, revoked: [])
        return try DropService(session: session, card: card, certificates: [cert])
    }
}

extension DropServiceTests {
    @Test func badWrapDoesNotHideGoodWrap() async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let sent = try await service.send(Data("ok".utf8), name: "readable")
        let good = try #require(sent.wraps.first { $0.targetKind == .wk })
        var bytes = good.wrap; bytes[bytes.count - 1] ^= 1
        let bad = DropWrapRecord(object: good.object, version: good.version, targetKind: good.targetKind, target: good.target, keyVersion: good.keyVersion, wrap: bytes)
        let poisoned = DropObject(descriptor: sent.descriptor, signed: sent.signed, wraps: [bad, good])
        #expect(try Data(contentsOf: await service.download(poisoned)) == Data("ok".utf8))
    }

    @Test func claimThenRotationRewrapForNewMember() async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let id = ID16.fresh(0x63)
        var body = try DropTestFrame.json(await w.dropBody(id: id))
        var raw = body["descriptor"]!.object!["o"]!.object!
        raw["recipients"] = "inbox"
        body["descriptor"] = try SignedObject.sign(raw, kind: .dropObject, signer: w.env.device.sig).json
        body["wraps"] = .array(body["wraps"]!.array!.filter { $0.object?["target_kind"] == "wxk" })
        #expect(try await w.transport.dropPut(objectID: id, ifMatch: 0, body: DropTestFrame.frame(body), session: w.phoneSession).status == 201)
        let object = try #require(await service.list(.sending).first)
        try await w.serve(phone) { try await service.claim(object) }
        let receiver = try await w.independentDropWriter(clock: phone.clock) // epoch 2; no historical grant
        let claimed = try #require(await receiver.list().first)
        let downloaded = try await w.serve(phone) { try await receiver.downloadVerified(claimed) }
        #expect(try Data(contentsOf: downloaded.url) == Data("Hello Drop".utf8))
        #expect(downloaded.metadata.name == "hello.txt")
        let wraps = try json(await w.transport.dropGet(objectID: id, version: 1, part: .wraps, session: w.phoneSession))["wraps"]!.array!.map(DropWrapRecord.init(json:))
        #expect(wraps.contains { $0.targetKind == .wk && $0.keyVersion == 2 })
        #expect(!wraps.contains { $0.targetKind == .wxk })
    }

    @Test func pendingOldEpochBodyResealsAndRecoveryContinuesPastExpiry() async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let db = try await phone.container.database()
        let expired = ID16.fresh(0x64), pending = ID16.fresh(0x65)
        for id in [expired, pending] {
            let body = try await w.dropBody(id: id)
            try await db.execute("INSERT INTO drop_uploads(object,version,body,done) VALUES(?,1,?,0)", [.text(id.hex), .blob(body)])
            if id == expired { w.clock.advance(milliseconds: 61000); phone.clock.advance(milliseconds: 61000) }
        }
        let old = try #require(await db.query("SELECT body FROM drop_uploads WHERE object=?", [.text(pending.hex)]).first?.blob("body"))
        try await w.host.rotate(remaining: [(w.phone, World.all)], relay: w.relay, session: w.hostSession)
        let results = try await service.resumeUploads()
        #expect(results.count == 2)
        let success = try #require(results.first { $0.object == pending }).result.get()
        #expect(success.wraps.filter { $0.targetKind == .wk }.map(\.keyVersion) == [2])
        let new = try #require(await db.query("SELECT body FROM drop_uploads WHERE object=?", [.text(pending.hex)]).first?.blob("body"))
        // the same DEK is re-wrapped under epoch 2: descriptor and blob are the sealed ones, only the `wk` wrap changed
        let (before, after) = try (DropTestFrame.json(old), DropTestFrame.json(new))
        #expect(before["blob"] == after["blob"] && before["descriptor"] == after["descriptor"] && before["wraps"] != after["wraps"])
        #expect(try await db.query("SELECT done FROM drop_uploads WHERE object=?", [.text(expired.hex)]).first?.int("done") == 2)
        #expect(try await service.resumeUploads().isEmpty)
        let restarted = try await w.dropService(phone)
        #expect(try await restarted.failedUploads().map(\.object) == [expired])
        try await restarted.discardUpload(object: expired, version: 1)
        #expect(try await db.query("SELECT body FROM drop_uploads WHERE object=?", [.text(expired.hex)]).isEmpty)
    }
}

extension DropServiceTests {
    @Test func discardTerminalShareJobRemovesPlaintext() async throws {
        let faults = ScriptedFaults(), w = try await World.drop(faults: faults)
        let phone = try await w.makePhone(), service = try await w.dropService(phone)
        let area = ShareArea(shareGroupRoot: w.env.layout.shareGroupRoot)
        let staging = try StagingSession(area: area, target: ShareTarget(realm: "demo", ws: w.ws.hex, name: "Laptop", hue: 0, generation: 1))
        try staging.add(.text("abandoned")); try staging.commit(note: nil)
        let inbox = ShareInbox(area: area)
        let job = try #require(inbox.claim(live: [LiveDestination(realm: "demo", ws: w.ws.hex, generation: 1)]).claimed.first)
        faults.enqueue(.disconnect, at: .afterCommitBeforeResponse, routePrefix: "GET /v2/drop/")
        await #expect(throws: TransportError.disconnected) { _ = try await service.importShareJob(job, inbox: inbox) }
        phone.clock.advance(milliseconds: 604800001); w.clock.advance(milliseconds: 604800001)
        let outcomes = try await service.resumeUploads()
        #expect(outcomes.count == 1)
        #expect(try await service.failedUploads().count == 1)
        #expect(FileManager.default.fileExists(atPath: job.dir.path))
        try await service.discardShareJob(job, inbox: inbox)
        #expect(!FileManager.default.fileExists(atPath: job.dir.path))
        #expect(try await service.failedUploads().isEmpty)
        #expect(try await phone.container.database().query("SELECT object FROM drop_imports WHERE job=?", [.text(job.manifest.jobID)]).isEmpty)
    }
}

extension DropServiceTests {
    @Test func recoveryReloadsLaterResealedAndConfirmedRow() async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let db = try await phone.container.database()
        let first = ID16.fresh(0x61), later = ID16.fresh(0x62)
        for id in [first, later] {
            try await db.execute("INSERT INTO drop_uploads(object,version,body,done) VALUES(?,1,?,0)", [.text(id.hex), .blob(try await w.dropBody(id: id))])
        }
        try await w.host.rotate(remaining: [(w.phone, World.all)], relay: w.relay, session: w.hostSession)
        let gate = HookGate(), point = "resume.row:\(first.hex)"
        await gate.hold(point)
        await service.setHook { await gate.hit($0) }
        let recovery = Task { try await service.resumeUploads() }
        await gate.waitArrived(point)
        let confirmed = try await service.retryUpload(object: later, version: 1)
        #expect(confirmed.wraps.contains { $0.targetKind == .wk && $0.keyVersion == 2 })
        await gate.release(point)
        let results = try await recovery.value
        #expect(results.count == 2)
        for result in results { _ = try result.result.get() }
        let row = try #require(await db.query("SELECT revision,done,failure FROM drop_uploads WHERE object=?", [.text(later.hex)]).first)
        #expect(row.int("revision") == 1 && row.int("done") == 1 && row.text("failure") == nil)
        #expect(try await service.failedUploads().isEmpty)
    }

    @Test(arguments: [false, true])
    func discardedDocumentBodyStaysBlockedButFreshVersionCanSend(restoreDiscardedBody: Bool) async throws {
        let faults = ScriptedFaults(), w = try await World.drop(faults: faults)
        let phone = try await w.makePhone(), service = try await w.dropService(phone)
        let parent = try await service.send(Data("parent".utf8), name: "doc", kind: .document)
        let id = parent.descriptor.object, db = try await phone.container.database()
        // Fail the pre-PUT lookup, leaving a durable version 2 that never reached the relay.
        faults.enqueue(.disconnect, at: .afterCommitBeforeResponse, routePrefix: "GET /v2/drop/")
        await #expect(throws: TransportError.disconnected) {
            _ = try await service.send(Data("discarded".utf8), name: "doc", document: parent)
        }
        let body = try #require(await db.query("SELECT body FROM drop_uploads WHERE object=? AND version=2", [.text(id.hex)]).first?.blob("body"))
        try await service.discardUpload(object: id, version: 2)
        let restarted = try await w.dropService(phone)
        #expect(try await restarted.resumeUploads().isEmpty)
        await #expect(throws: DropError.abandoned) { try await restarted.retryUpload(object: id, version: 2) }
        if restoreDiscardedBody {
            // Even a stale durable body restored after restart must never be resealed or sent.
            try await db.execute("INSERT INTO drop_uploads(object,version,body,done) VALUES(?,2,?,0)", [.text(id.hex), .blob(body)])
            try await w.host.rotate(remaining: [(w.phone, World.all)], relay: w.relay, session: w.hostSession)
            let results = try await restarted.resumeUploads()
            #expect(results.count == 1)
            #expect(throws: DropError.abandoned) { try results[0].result.get() }
            await #expect(throws: DropError.abandoned) { try await restarted.retryUpload(object: id, version: 2) }
            #expect(try await w.transport.dropGet(objectID: id, version: 2, part: .descriptor, session: w.phoneSession).status == 404)
            #expect(try await db.query("SELECT body FROM drop_uploads WHERE object=? AND version=2", [.text(id.hex)]).first?.blob("body") == body)
        } else {
            let refreshed = try #require(await restarted.list(.sending).first)
            #expect(refreshed.descriptor.version == 1)
            let fresh = try await restarted.send(Data("fresh".utf8), name: "doc", document: refreshed)
            #expect(fresh.descriptor.object == id && fresh.descriptor.version == 2)
            #expect(try Data(contentsOf: await restarted.download(fresh)) == Data("fresh".utf8))
            #expect(try await db.query("SELECT body FROM drop_uploads WHERE object=? AND version=2", [.text(id.hex)]).first?.blob("body") != body)
        }
    }

    @Test func discardAdmissionBlocksSnapshotRecoveryAndRetry() async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let db = try await phone.container.database(), id = ID16.fresh(0x66)
        try await db.execute("INSERT INTO drop_uploads(object,version,body,done) VALUES(?,1,?,0)", [.text(id.hex), .blob(try await w.dropBody(id: id))])
        let gate = HookGate(), point = "resume.row:\(id.hex)"
        await gate.hold(point, "discard.upload.admitted")
        await service.setHook { await gate.hit($0) }
        let recovery = Task { try await service.resumeUploads() }
        await gate.waitArrived(point)
        let discard = Task { try await service.discardUpload(object: id, version: 1) }
        await gate.waitArrived("discard.upload.admitted")
        await gate.release(point)
        await gate.waitArrived("upload.requested:\(id.hex)")
        let retry = Task { try await service.retryUpload(object: id, version: 1) }
        await gate.waitArrived("upload.coalesced:\(id.hex)")
        await gate.release("discard.upload.admitted")
        try await discard.value
        let results = try await recovery.value
        #expect(results.count == 1)
        #expect(throws: DropError.abandoned) { try results[0].result.get() }
        await #expect(throws: DropError.abandoned) { try await retry.value }
        let restarted = try await w.dropService(phone)
        await #expect(throws: DropError.abandoned) { try await restarted.retryUpload(object: id, version: 1) }
        #expect(try await restarted.resumeUploads().isEmpty)
        #expect(try await service.list(.sending).isEmpty)
    }

    private func stagedDrop(_ w: World) throws -> (ShareInbox, StagedJob) {
        let area = ShareArea(shareGroupRoot: w.env.layout.shareGroupRoot)
        let staging = try StagingSession(area: area, target: ShareTarget(realm: "demo", ws: w.ws.hex, name: "Laptop", hue: 0, generation: 1))
        try staging.add(.text("abandoned content")); try staging.commit(note: nil)
        let inbox = ShareInbox(area: area)
        return (inbox, try #require(inbox.claim(live: [LiveDestination(realm: "demo", ws: w.ws.hex, generation: 1)]).claimed.first))
    }

    @Test func abandonedItemDoesNotStrandRemainingImport() async throws {
        let faults = ScriptedFaults(), w = try await World.drop(faults: faults)
        let phone = try await w.makePhone(), service = try await w.dropService(phone)
        let area = ShareArea(shareGroupRoot: w.env.layout.shareGroupRoot)
        let staging = try StagingSession(area: area, target: ShareTarget(realm: "demo", ws: w.ws.hex, name: "Laptop", hue: 0, generation: 1))
        try staging.add(.text("skip")); try staging.add(.text("send")); try staging.commit(note: nil)
        let inbox = ShareInbox(area: area)
        let job = try #require(inbox.claim(live: [LiveDestination(realm: "demo", ws: w.ws.hex, generation: 1)]).claimed.first)
        let db = try await phone.container.database()
        faults.enqueue(.disconnect, at: .afterCommitBeforeResponse, routePrefix: "GET /v2/drop/")
        await #expect(throws: TransportError.disconnected) { try await service.importShareJob(job, inbox: inbox) }
        let id = try #require(await db.query("SELECT object FROM drop_imports WHERE item=0").first?.text("object").flatMap(ID16.init(hex:)))
        try await service.discardUpload(object: id, version: 1)
        let result = try await service.importShareJob(job, inbox: inbox)
        #expect(result.count == 1)
        #expect(try await db.query("SELECT object FROM drop_uploads WHERE done=1").count == 1)
        #expect(try await db.query("SELECT object FROM drop_uploads WHERE object=?", [.text(id.hex)]).isEmpty)
        #expect(throws: (any Error).self) { try inbox.contents(of: job.manifest.items[1], in: job) }
        #expect(try await w.transport.dropGet(objectID: id, version: 1, part: .descriptor, session: w.phoneSession).status == 404)
    }

    @Test func g1DiscardedImportRefusesRetryAndSnapshotRecovery() async throws {
        let faults = ScriptedFaults(), w = try await World.drop(faults: faults)
        let phone = try await w.makePhone(), service = try await w.dropService(phone)
        let (inbox, job) = try stagedDrop(w), db = try await phone.container.database()
        faults.enqueue(.disconnect, at: .afterCommitBeforeResponse, routePrefix: "GET /v2/drop/")
        await #expect(throws: TransportError.disconnected) { try await service.importShareJob(job, inbox: inbox) }
        let id = try #require(await db.query("SELECT object FROM drop_imports WHERE job=?", [.text(job.manifest.jobID)]).first?.text("object").flatMap(ID16.init(hex:)))
        let gate = HookGate(), point = "resume.row:\(id.hex)"
        await gate.hold(point)
        await service.setHook { await gate.hit($0) }
        let recovery = Task { try await service.resumeUploads() }
        await gate.waitArrived(point)
        try await service.discardUpload(object: id, version: 1)
         #expect(try await service.importShareJob(job, inbox: inbox).isEmpty)
        await gate.release(point)
        let results = try await recovery.value
        #expect(results.count == 1)
        #expect(throws: DropError.abandoned) { try results[0].result.get() }
        #expect(try await db.query("SELECT object FROM drop_uploads").isEmpty)
        #expect(try await w.transport.dropGet(objectID: id, version: 1, part: .descriptor, session: w.phoneSession).status == 404)
    }

    @Test(arguments: [false, true])
    func g1DiscardedImportStaysAbandonedAfterRestart(withoutUploadRow: Bool) async throws {
        let faults = ScriptedFaults(), w = try await World.drop(faults: faults)
        let phone = try await w.makePhone(), service = try await w.dropService(phone)
        let (inbox, job) = try stagedDrop(w), db = try await phone.container.database()
        faults.enqueue(.disconnect, at: .afterCommitBeforeResponse, routePrefix: "GET /v2/drop/")
        await #expect(throws: TransportError.disconnected) { try await service.importShareJob(job, inbox: inbox) }
        let id = try #require(await db.query("SELECT object FROM drop_imports WHERE job=?", [.text(job.manifest.jobID)]).first?.text("object").flatMap(ID16.init(hex:)))
        if withoutUploadRow {
            // The item mapping can be durable even when sealing has not persisted an upload.
            try await db.execute("DELETE FROM drop_uploads WHERE object=?", [.text(id.hex)])
        }
        try await service.discardUpload(object: id, version: 1)
        let restartedPhone = try await w.makePhone(), restarted = try await w.dropService(restartedPhone)
        let restartedInbox = ShareInbox(area: ShareArea(shareGroupRoot: w.env.layout.shareGroupRoot))
        let reclaimed = try #require(restartedInbox.claim(live: [LiveDestination(realm: "demo", ws: w.ws.hex, generation: 1)], includeClaimed: true).claimed.first)
        #expect(reclaimed.manifest.jobID == job.manifest.jobID)
        #expect(try await restarted.importShareJob(reclaimed, inbox: restartedInbox).isEmpty)
        #expect(try await restarted.resumeUploads().isEmpty)
        // Recovery must also reject a newly sealed body for the same persisted item identity.
        try await db.execute("INSERT INTO drop_uploads(object,version,body,done) VALUES(?,1,?,0)", [.text(id.hex), .blob(try await w.dropBody(id: id))])
        let results = try await restarted.resumeUploads()
        #expect(results.count == 1)
        #expect(throws: DropError.abandoned) { try results[0].result.get() }
        #expect(try await w.transport.dropGet(objectID: id, version: 1, part: .descriptor, session: w.phoneSession).status == 404)
        #expect(!FileManager.default.fileExists(atPath: reclaimed.dir.path))
    }

    @Test func shareDiscardAdmissionBlocksImport() async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let (inbox, job) = try stagedDrop(w), gate = HookGate()
        await gate.hold("discard.job.admitted")
        await service.setHook { await gate.hit($0) }
        let discard = Task { try await service.discardShareJob(job, inbox: inbox) }
        await gate.waitArrived("discard.job.admitted")
        let importing = Task { try await service.importShareJob(job, inbox: inbox) }
        await gate.waitArrived("import.requested")
        await gate.release("discard.job.admitted")
        try await discard.value
        await #expect(throws: DropError.abandoned) { try await importing.value }
        #expect(try await service.list(.sending).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: job.dir.path))
    }

    @Test(arguments: ["discard.job.tombstoned", "discard.job.cleanup", "deletion.failure"])
    func shareAbandonmentSurvivesCrashAndFailedPlaintextRemoval(point: String) async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let (inbox, job) = try stagedDrop(w)
        let db = try await phone.container.database(), id = ID16.fresh(0x67)
        try await db.execute("INSERT INTO drop_imports(job,item,object) VALUES(?,0,?)", [.text(job.manifest.jobID), .text(id.hex)])
        try await db.execute("INSERT INTO drop_uploads(object,version,body,done) VALUES(?,1,?,0)", [.text(id.hex), .blob(try await w.dropBody(id: id))])
        if point == "deletion.failure" {
            // Exceed the fd-relative remover's depth bound: deterministic failure, no permissions assumption.
            let deep = (0..<65).reduce(job.dir.appendingPathComponent("deep")) { url, _ in url.appendingPathComponent("d") }
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        } else {
            await service.setHook(Crashing(point: point).hook)
        }
        await #expect(throws: (any Error).self) { try await service.discardShareJob(job, inbox: inbox) }
        #expect(FileManager.default.fileExists(atPath: job.dir.path))
        #expect(try await db.query("SELECT key FROM drop_abandoned WHERE key=?", [.text("job:\(job.manifest.jobID)")]).count == 1)
        #expect(try await db.query("SELECT object FROM drop_imports WHERE job=?", [.text(job.manifest.jobID)]).count == 1)
        let restarted = try await w.dropService(phone)
        if point != "deletion.failure" {
            let reclaimed = try #require(inbox.claim(live: [LiveDestination(realm: "demo", ws: w.ws.hex, generation: 1)]).claimed.first)
            await #expect(throws: DropError.abandoned) { try await restarted.importShareJob(reclaimed, inbox: inbox) }
        }
        await #expect(throws: DropError.abandoned) { try await restarted.importShareJob(job, inbox: inbox) }
        for result in try await restarted.resumeUploads() {
            #expect(throws: DropError.abandoned) { try result.result.get() }
        }
        #expect(try await restarted.list(.sending).isEmpty)
        if point == "deletion.failure" { try FileManager.default.removeItem(at: job.dir.appendingPathComponent("deep")) }
        try await restarted.discardShareJob(job, inbox: inbox)
        #expect(!FileManager.default.fileExists(atPath: job.dir.path))
        #expect(try await db.query("SELECT object FROM drop_imports WHERE job=?", [.text(job.manifest.jobID)]).isEmpty)
    }
}

extension DropServiceTests {
    @Test(arguments: [false, true])
    func completedShareJobRetriesOnlyCleanupAfterRestart(deletionFailure: Bool) async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let area = ShareArea(shareGroupRoot: w.env.layout.shareGroupRoot)
        let staging = try StagingSession(area: area, target: ShareTarget(realm: "demo", ws: w.ws.hex, name: "Laptop", hue: 0, generation: 1))
        try staging.add(.text("first")); try staging.add(.text("second")); try staging.commit(note: nil)
        let inbox = ShareInbox(area: area)
        let live: Set<LiveDestination> = [LiveDestination(realm: "demo", ws: w.ws.hex, generation: 1)]
        let job = try #require(inbox.claim(live: live).claimed.first)
        let gate = HookGate(), point = "import.cleanup.removed:\(job.manifest.items[0].file)"
        await gate.hold(point)
        await service.setHook { name in
            await gate.hit(name)
            if name == point && !deletionFailure { throw PairingCrash() }
        }
        // A real remover failure after both items: no dependence on permissions or timing.
        let obstruction = job.dir.appendingPathComponent("zz-deep")
        if deletionFailure {
            let deep = (0..<65).reduce(obstruction) { url, _ in url.appendingPathComponent("d") }
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        }
        let importing = Task { try await service.importShareJob(job, inbox: inbox) }
        await gate.waitArrived(point)
        let db = try await phone.container.database()
        #expect(try await db.query("SELECT job FROM drop_completed_jobs WHERE job=?", [.text(job.manifest.jobID)]).count == 1)
        #expect(try await db.query("SELECT object FROM drop_uploads WHERE done=1").count == 2)
        #expect(!FileManager.default.fileExists(atPath: job.dir.appendingPathComponent(job.manifest.items[0].file).path))
        #expect(FileManager.default.fileExists(atPath: job.dir.appendingPathComponent(job.manifest.items[1].file).path))
        let bodies = try await db.query("SELECT body FROM drop_uploads ORDER BY object").compactMap { $0.blob("body") }
        await gate.release(point)
        await #expect(throws: (any Error).self) { try await importing.value }
        await phone.container.suspend()
        let restartedPhone = try await w.makePhone(), restarted = try await w.dropService(restartedPhone)
        let restartedInbox = ShareInbox(area: area)
        let reclaimed = try #require(restartedInbox.claim(live: live, includeClaimed: true).claimed.first)
        if deletionFailure {
            await #expect(throws: (any Error).self) { try await restarted.importShareJob(reclaimed, inbox: restartedInbox) }
            try FileManager.default.removeItem(at: obstruction)
        }
        #expect(try await restarted.importShareJob(reclaimed, inbox: restartedInbox).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: job.dir.path))
        #expect(restartedInbox.claim(live: live).claimed.isEmpty)
        // A stale handle is also cleanup-only, even after its directory has disappeared.
        #expect(try await restarted.importShareJob(job, inbox: restartedInbox).isEmpty)
        let reopenedDB = try await restartedPhone.container.database()
        #expect(try await reopenedDB.query("SELECT body FROM drop_uploads ORDER BY object").compactMap { $0.blob("body") } == bodies)
        #expect(try await reopenedDB.query("SELECT object FROM drop_uploads WHERE done=1").count == 2)
        #expect(try await restarted.list(.sending).count == 2)
    }
}

extension DropServiceTests {
    @Test func malformedListRowDoesNotHideValidNeighbor() async throws {
        let w = try await World.drop(), adversary = DropAdversary(w.relay)
        let transport = try RoutedRelayTransport(context: w.env.context, origin: w.env.context.origin, sender: adversary, clientAddress: "test")
        let phone = try await w.makePhone(transport: transport), service = try await w.dropService(phone)
        _ = try await service.send(Data("first".utf8), name: "first")
        _ = try await service.send(Data("second".utf8), name: "second")
        await adversary.set(descriptor: true)
        let result = try await service.listVerifiedRows(.sending)
        #expect(result.blocked.count == 1)
        #expect(result.objects.count == 1)
        #expect(try await service.metadataVerified(result.objects[0]).size > 0)
    }
}
