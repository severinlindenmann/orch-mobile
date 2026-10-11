import Foundation
import Testing
@testable import OrchClient
@testable import OrchFakeHost
import OrchProtocol
import OrchStore

extension DropServiceTests {
    @Test(arguments: ["foreground", "list", "download"])
    func downloadedExpirySurvivesRestart(trigger: String) async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let expiry = phone.clock.nowMs + 1000
        let object = try await service.send(Data("expires".utf8), name: "note", expiresMs: expiry)
        let other = try await service.send(Data("keep".utf8), name: "keep")
        let url = try await service.download(object), kept = try await service.download(other)
        let row = try #require(await phone.container.database().query("SELECT file_version,file_expires_ms FROM drop_heads WHERE object=?", [.text(object.descriptor.object.hex)]).first)
        #expect(row.int("file_version") == 1 && row.int("file_expires_ms") == expiry)
        await phone.container.close()
        let restartedPhone = try await w.makePhone(), restarted = try await w.dropService(restartedPhone)
        restartedPhone.clock.advance(milliseconds: expiry - restartedPhone.clock.nowMs - 1)
        try await restarted.purgeExpiredDownloads()
        #expect(FileManager.default.fileExists(atPath: url.path))
        restartedPhone.clock.advance(milliseconds: 1)
        w.clock.advance(milliseconds: expiry - w.clock.nowMs)
        switch trigger {
        case "foreground": try await restarted.purgeExpiredDownloads()
        case "list": _ = try await restarted.list(.sending)
        default: _ = try await restarted.download(other)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: kept) == Data("keep".utf8))
        try await restarted.purgeExpiredDownloads() // idempotent
    }

    private func publishNext(_ w: World, parent: DropObject) async throws -> DropObject {
        let body = try await w.dropBody(id: parent.descriptor.object, parent: parent.descriptor)
        #expect(try await w.transport.dropPut(objectID: parent.descriptor.object, ifMatch: parent.descriptor.version, body: body, session: w.phoneSession).status == 201)
        let fields = try #require(StrictJSON.parse(body).object)
        let signed = try #require(fields["descriptor"])
        return try DropObject(descriptor: DropDescriptor(object: #require(signed.object?["o"]?.object)), signed: signed,
                              wraps: #require(fields["wraps"]?.array).map(DropWrapRecord.init(json:)))
    }

    @Test(arguments: [false, true])
    func newerVersionPurgesDownloadedPlaintext(list: Bool) async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let first = try await service.send(Data("old".utf8), name: "note", kind: .document)
        let url = try await service.download(first)
        let next = try await publishNext(w, parent: first)
        #expect(FileManager.default.fileExists(atPath: url.path))
        if list { _ = try await service.list(.sending) }
        else { _ = try await service.download(next) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let latest = try await service.download(next)
        #expect(try Data(contentsOf: latest) == Data("Hello Drop".utf8))
        await #expect(throws: (any Error).self) { try await service.download(first) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test(arguments: ["expiry", "newer", "wipe"])
    func purgeWinsAgainstPausedPreviewPublication(reason: String) async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let object = try await service.send(Data("old".utf8), name: "note", expiresMs: phone.clock.nowMs + 1000, kind: .document)
        let gate = HookGate()
        await gate.hold("download.publish")
        await service.setHook { await gate.hit($0) }
        let download = Task { try await service.download(object) }
        await gate.waitArrived("download.publish")
        if reason == "wipe" { try await LocalWipe(index: w.env.index).wipe(ws: w.ws.hex, generation: 1) }
        else {
            // A second container/service models a concurrent list or foreground cleanup.
            let secondPhone = try await w.makePhone(), second = try await w.dropService(secondPhone)
            if reason == "expiry" {
                phone.clock.advance(milliseconds: 1000); secondPhone.clock.advance(milliseconds: 1000)
                try await second.purgeExpiredDownloads()
            } else {
                _ = try await publishNext(w, parent: object)
                _ = try await second.list(.sending)
            }
        }
        await gate.release("download.publish")
        await #expect(throws: (any Error).self) { try await download.value }
        let directory = try w.env.layout.filesDir(w.ws.hex)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty ?? true)
    }
}
