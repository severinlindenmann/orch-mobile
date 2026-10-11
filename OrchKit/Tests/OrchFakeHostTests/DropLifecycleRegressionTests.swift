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
    func value() async throws -> T {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while result == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard let result else { throw DropGate.Deadline() }
        return try result.get()
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
            await #expect(throws: (any Error).self) { try await completed.value() }
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
            await #expect(throws: DropError.suspended) { try await completed.value() }
        } catch { task.cancel(); await gate.release(); throw error }
    }
}
