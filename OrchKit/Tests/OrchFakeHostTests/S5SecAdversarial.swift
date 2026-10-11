import CryptoKit
import Foundation
import Testing
@testable import OrchClient
@testable import OrchFakeHost
import OrchCustody
import OrchProtocol
import OrchStore

private func secWorld(phoneScopes: [String]) async throws -> World {
    let w = try await World.make(publish: false)
    let cert = try await w.primary.certify(w.phone, label: "Sender", scopesMax: World.all)
    await w.relay.registerOwner(w.primary.publicKey)
    try await w.relay.publishCertificate(cert)
    let devices = [(w.primary.deviceKeys, try await w.primary.certifyOwnDevice(), World.all), (w.phone, cert, phoneScopes)]
    let hs = try await w.host.publishInitial(relay: w.relay, transport: w.transport, devices: devices)
    let ps = try await RelayClient(transport: w.transport).openDeviceSession(identity: w.env.device, deviceID: w.phoneID).session
    return World(env: w.env, clock: w.clock, custody: w.custody, vault: w.vault, primary: w.primary, host: w.host, phone: w.phone,
                 phoneID: w.phoneID, primaryID: w.primaryID, phoneCert: cert, hostSession: hs, phoneSession: ps)
}
private func svc(_ w: World, _ phone: Phone) async throws -> DropService {
    let raw = try await RelayClient(transport: w.transport).card(workspace: w.ws, session: w.phoneSession)
    return try DropService(session: phone.session, card: Card.verify(raw, ownerKey: w.primary.publicKey))
}

@Suite struct S5SecAdversarial {
    // F1 regression: refresh to the signed current epoch before sealing.
    @Test func staleEpochSealAfterRemoval() async throws {
        let w = try await secWorld(phoneScopes: World.all), phone = try await w.makePhone(), service = try await svc(w, phone)
        try await w.host.rotate(remaining: [(w.phone, World.all)], relay: w.relay, session: w.hostSession) // primary removed -> epoch 2
        let sent = try await service.send(Data("secret after removal".utf8), name: "x")
        let wk = sent.wraps.filter { $0.targetKind == .wk }.map(\.keyVersion)
        print("S5SEC F1 wk wrap key_versions:", wk)
        #expect(wk == [2])
    }
    // F2 regression: looking must never claim or remove the WXK wrap.
    @Test func lookOnlyDownloadClaimsInbox() async throws {
        let w = try await secWorld(phoneScopes: ["look"]), phone = try await w.makePhone(), service = try await svc(w, phone)
        let id = ID16.fresh(0x55), data = Data("inbox".utf8)
        let wk = try #require(await w.host.wks[1])
        let card = try Card.verify(await RelayClient(transport: w.transport).card(workspace: w.ws, session: w.phoneSession), ownerKey: w.primary.publicKey)
        var o = try StrictJSON.parse(DropUpload.seal(data, metadata: DropMetadata(name: "i", mime: "text/plain", size: 5, transcript: nil),
            object: id, workspace: w.ws, author: w.ws, authorKind: "workspace", signer: w.host.wsk, wxk: card.wxk, wxkVersion: card.wxkVersion,
            sender: nil, wk: wk, epoch: 1, now: w.clock.nowMs, expiry: w.clock.nowMs + 60000), maxBytes: 1 << 20).object!
        var raw = o["descriptor"]!.object!["o"]!.object!; raw["recipients"] = "inbox"
        o["descriptor"] = try SignedObject.sign(raw, kind: .dropObject, signer: w.host.wsk).json
        o["wraps"] = .array(o["wraps"]!.array!.filter { $0.object?["target_kind"] == "wxk" })
        #expect(try await w.transport.dropPut(objectID: id, ifMatch: 0, body: canonicalJSON(.object(o)), session: w.hostSession).status == 201)
        let objects = try await service.list()
        let obj = try #require(objects.first { $0.descriptor.object == id })
        await #expect(throws: DropError.unavailableKey) { _ = try await service.download(obj) }
        await #expect(throws: DropError.unauthorized) { try await service.claim(obj) }
        await #expect(throws: ClientError.host(.forbiddenScope)) {
            _ = try await w.serve(phone) { try await phone.session.exchange(meta: ["op": "drop_claim", "object_id": .string(id.hex), "version": 1]) }
        }
        await #expect(throws: ClientError.host(.forbiddenScope)) {
            _ = try await w.serve(phone) { try await phone.session.exchange(meta: ["op": "drop_rewrap", "object_id": .string(id.hex), "version": 1]) }
        }
        await #expect(throws: DropError.unauthorized) { _ = try await service.send(Data(), name: "denied") }
        await #expect(throws: DropError.unavailableKey) { try await w.host.rewrapDrop(object: id, version: 1, relay: w.relay, session: w.hostSession) }
        let wr = try await w.transport.dropGet(objectID: id, version: 1, part: .wraps, session: w.hostSession)
        let s = String(decoding: wr.body, as: UTF8.self)
        print("S5SEC F2 wraps after look-only download:", s)
        #expect(s.contains("\"wxk\""))
    }
    // F3 regression: terminal conflicts do not poison subsequent recovery.
    @Test func conflictedRowPoisonsResume() async throws {
        let w = try await secWorld(phoneScopes: World.all), phone = try await w.makePhone(), service = try await svc(w, phone)
        let v1 = try await service.send(Data("a".utf8), name: "d", kind: .document)
        let other = try await service.send(Data("b".utf8), name: "d", document: v1) // commits v2
        _ = other
        await #expect(throws: (any Error).self) { _ = try await service.send(Data("fork".utf8), name: "d", document: v1) }
        // Exercise a real relay conflict using a separately sealed winning version:
        let d1 = try await service.send(Data("x".utf8), name: "e", kind: .document)
        let body = try await w.dropBody(id: d1.descriptor.object, parent: d1.descriptor)
        #expect(try await w.transport.dropPut(objectID: d1.descriptor.object, ifMatch: 1, body: body, session: w.phoneSession).status == 201)
        await #expect(throws: (any Error).self) { _ = try await service.send(Data("mine".utf8), name: "e", document: d1) }
        let pending = ID16.fresh(0x77), db = try await phone.container.database()
        try await db.execute("INSERT INTO drop_uploads(object,version,body,done) VALUES(?,1,?,0)", [.text(pending.hex), .blob(try await w.dropBody(id: pending))])
        let results = try await service.resumeUploads()
        #expect(results.count == 1)
        #expect(try results.first?.result.get().descriptor.object == pending)
        #expect(try await db.query("SELECT done FROM drop_uploads WHERE object=? AND version=2", [.text(d1.descriptor.object.hex)]).first?.int("done") == 2)
        var threw = 0
        for _ in 0..<3 { do { _ = try await service.resumeUploads() } catch { threw += 1 } }
        print("S5SEC F3 resumeUploads threw", threw, "of 3")
        #expect(threw == 0)
    }
}
