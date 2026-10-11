import Foundation
import Testing
@testable import OrchClient
@testable import OrchFakeHost
import OrchProtocol
import OrchShareStaging
import OrchStore

extension DropServiceTests {
    @Test func suspendedContainerDoesNotBecomeAuthoritativeRemoval() async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        await phone.container.suspend()
        await #expect(throws: StoreError.suspended) { try await service.list() }
    }

    @Test(arguments: [false, true])
    func suspendOrInvalidateBlocksPausedDownloadPublication(invalidate: Bool) async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let object = try await service.send(Data("private".utf8), name: "private")
        let gate = HookGate()
        await gate.hold("download.publish")
        await service.setHook { await gate.hit($0) }
        let task = Task { try await service.downloadVerified(object) }
        await gate.waitArrived("download.publish")
        if invalidate { await service.invalidate() } else { await service.suspend() }
        if !invalidate { try await service.activate() } // Old work must stay suspended across reactivation.
        await gate.release("download.publish")
        await #expect(throws: DropError.suspended) { try await task.value }
        #expect(try await phone.container.database().query("SELECT downloaded_at FROM drop_heads WHERE object=?", [.text(object.descriptor.object.hex)]).first?.int("downloaded_at") == nil)
        if invalidate {
            await #expect(throws: DropError.suspended) { try await service.activate() }
        } else {
            try await service.activate()
            let download = try await service.downloadVerified(object)
            #expect(download.deadlineMs == object.descriptor.expiresMs)
        }
    }

    @Test func invalidationStopsUnstructuredUploadBeforeAdmissionSideEffects() async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let gate = HookGate()
        await gate.hold("upload.requested")
        await service.setHook { name in
            if name.hasPrefix("upload.requested:") { await gate.hit("upload.requested") }
        }
        let task = Task { try await service.send(Data("pending".utf8), name: "pending") }
        await gate.waitArrived("upload.requested")
        await service.invalidate()
        await gate.release("upload.requested")
        await #expect(throws: (any Error).self) { try await task.value }
        let restarted = try await w.dropService(phone)
        #expect(try await restarted.list(.sending).isEmpty)
        #expect(try await restarted.confirmedUploads().isEmpty)
        let results = try await restarted.resumeUploads()
        #expect(results.count == 1)
        #expect(try results[0].result.get().descriptor.version == 1)
        #expect(try await restarted.confirmedUploads().count == 1)
    }

    @Test func suspensionInterruptsCleanupAndRecoveryKeepsConfirmedIdentity() async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let area = ShareArea(shareGroupRoot: w.env.layout.shareGroupRoot)
        let staging = try StagingSession(area: area, target: .init(realm: "demo", ws: w.ws.hex, name: "Laptop", hue: 0, generation: 1))
        try staging.add(.text("one")); try staging.add(.text("two")); try staging.commit(note: nil)
        let inbox = ShareInbox(area: area)
        let job = try #require(inbox.claim(live: [.init(realm: "demo", ws: w.ws.hex, generation: 1)]).claimed.first)
        let point = "import.cleanup.removed:\(job.manifest.items[0].file)", gate = HookGate()
        await gate.hold(point)
        await service.setHook { await gate.hit($0) }
        let task = Task { try await service.importShareJob(job, inbox: inbox) }
        await gate.waitArrived(point)
        await service.suspend()
        await gate.release(point)
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(FileManager.default.fileExists(atPath: job.dir.appendingPathComponent(job.manifest.items[1].file).path))
        try await service.activate()
        #expect(try await service.importShareJob(job, inbox: inbox).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: job.dir.path))
        #expect(try await service.list(.sending).count == 2)
    }
}
