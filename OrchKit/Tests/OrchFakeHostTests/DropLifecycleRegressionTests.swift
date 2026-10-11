import Foundation
import Testing
@testable import OrchClient
import OrchProtocol

/// Release is sticky, including arrivals after a failed deadline.
actor DropGate {
    var arrived = false
    var released = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func hit() async {
        arrived = true
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { released = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
    func wait() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !arrived && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard arrived else { release(); throw Deadline() }
    }
    struct Deadline: Error {}
}

actor DropCompletion<T: Sendable> {
    var result: Result<T, any Error>?
    func set(_ result: Result<T, any Error>) { self.result = result }
    func value() async throws -> T { try await waitResult().get() }
    func waitResult() async throws -> Result<T, any Error> {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while result == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard let result else { throw DropGate.Deadline() }
        return result
    }
}

extension DropServiceTests {
    @Test func resumeDoesNotCoalesceWithCancelledEpoch() async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let gate = DropGate(), completed = DropCompletion<Void>()
        await service.setHook { if $0.hasPrefix("upload.requested:") { await gate.hit() } }
        let old = Task {
            do { _ = try await service.send(Data("sealed".utf8), name: "sealed"); await completed.set(.success(())) }
            catch { await completed.set(.failure(error)) }
        }
        do {
            try await gate.wait()
            await service.suspend()
            try await service.activate()
            await service.setHook(nil)
            let resumed = DropCompletion<Int>()
            let task = Task {
                do {
                    let rows = try await service.resumeUploads()
                    for row in rows { _ = try row.result.get() }
                    await resumed.set(.success(rows.count))
                } catch { await resumed.set(.failure(error)) }
            }
            do { #expect(try await resumed.value() == 1) }
            catch { task.cancel(); throw error }
            await gate.release()
            let outcome = try await completed.waitResult()
            #expect(throws: (any Error).self) { try outcome.get() }
        } catch { old.cancel(); await gate.release(); throw error }
    }

    @Test func suspensionAfterSessionAcquisitionStopsList() async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let gate = DropGate(), completed = DropCompletion<Int>()
        await service.setHook { if $0 == "auth.acquired" { await gate.hit() } }
        let task = Task {
            do { await completed.set(.success(try await service.list().count)) }
            catch { await completed.set(.failure(error)) }
        }
        do {
            try await gate.wait()
            await service.suspend(); try await service.activate()
            await gate.release()
            let outcome = try await completed.waitResult()
            #expect(throws: DropError.suspended) { try outcome.get() }
        } catch { task.cancel(); await gate.release(); throw error }
    }
}

extension DropServiceTests {
    @Test func composeSealsAllOrNothingAndResumesStableIdentities() async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let sendID = UUID()
        let attachments = ["one", "two"].map { DropSendAttachment(id: UUID(), data: Data($0.utf8), name: $0) }
        let gate = DropGate(), completed = DropCompletion<[DropUploadIdentity]>()
        await service.setHook { if $0 == "send.sealed:1" { await gate.hit() } }
        let task = Task {
            do { await completed.set(.success(try await service.sealSend(sendID, attachments: attachments))) }
            catch { await completed.set(.failure(error)) }
        }
        do {
            try await gate.wait()
            #expect(try await phone.container.database().query("SELECT object FROM drop_uploads").isEmpty)
            await service.suspend(); await gate.release()
            let outcome = try await completed.waitResult()
            #expect(throws: DropError.suspended) { try outcome.get() }
            #expect(try await phone.container.database().query("SELECT object FROM drop_uploads").isEmpty)
            try await service.activate(); await service.setHook(nil)
            let ids = try await service.sealSend(sendID, attachments: attachments)
            #expect(try await service.list(.sending).isEmpty)
            #expect(try await service.sealSend(sendID, attachments: attachments) == ids)
            let resumed = try await service.resumeUploads()
            #expect(resumed.count == 2)
            for row in resumed { _ = try row.result.get() }
            #expect(try await service.confirmedUploads().count == 2)
        } catch { task.cancel(); await gate.release(); throw error }
    }
}

extension DropServiceTests {
    @Test func metadataVerificationDoesNotPublishPlaintext() async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let object = try await service.send(Data("private".utf8), name: "private")
        #expect(try await service.metadataVerified(object).name == "private")
        #expect(try await phone.container.database().query("SELECT downloaded_at FROM drop_heads WHERE object=?", [.text(object.descriptor.object.hex)]).first?.int("downloaded_at") == nil)
        let file = try await service.downloadVerified(object)
        #expect(try Data(contentsOf: file.url) == Data("private".utf8))
    }
}


extension DropServiceTests {
    @Test(.timeLimit(.minutes(1))) func composeRequiresCurrentOperateMembershipBeforeSealing() async throws {
        for removed in [false, true] {
            let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
            var members = [(w.primary.deviceKeys, World.all)]
            if !removed { members.append((w.phone, ["look"])) }
            try await w.host.rotate(remaining: members, relay: w.relay, session: w.hostSession)
            let attachment = DropSendAttachment(id: UUID(), data: Data("private".utf8), name: "note.txt")
            await #expect(throws: (any Error).self) {
                _ = try await service.sealSend(UUID(), attachments: [attachment])
            }
            #expect(try await phone.container.database().query("SELECT object FROM drop_uploads").isEmpty)
        }
    }

    @Test func composeCancellationAfterFinalCheckReturnsCommittedOutcome() async throws {
        let w = try await World.drop(), phone = try await w.makePhone(), service = try await w.dropService(phone)
        let gate = DropGate(), completed = DropCompletion<[DropUploadIdentity]>()
        await service.setHook { if $0 == "send.persist" { await gate.hit() } }
        let task = Task {
            do {
                await completed.set(.success(try await service.sealSend(UUID(), attachments: [
                    DropSendAttachment(id: UUID(), data: Data("durable".utf8), name: "note.txt")
                ])))
            } catch { await completed.set(.failure(error)) }
        }
        do {
            try await gate.wait()
            task.cancel(); await service.suspend(); await gate.release()
            let ids = try await completed.value()
            #expect(ids.count == 1)
            #expect(try await phone.container.database().query("SELECT object FROM drop_uploads").count == 1)
            await service.setHook(nil); try await service.activate()
            let resumed = try await service.resumeUploads()
            #expect(resumed.count == 1)
            for row in resumed { _ = try row.result.get() }
            #expect(try await service.confirmedUploads() == ids)
        } catch { task.cancel(); await gate.release(); throw error }
    }
}
