import XCTest
import OrchClient
import OrchProtocol
import OrchStore
import OrchCoordination
@testable import Orch

@MainActor
final class LiveDropTests: XCTestCase {
    private struct Deadline: Error {}
    private final class PublicationGate {
        var entered = false
        var released = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        func hit() async {
            entered = true
            guard !released else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() { released = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
    }
    private func bounded(_ complete: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !complete() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard complete() else { throw Deadline() }
    }

    private func fixture() async throws -> (LiveServices, LiveDrop) {
        let services = LiveServices(options: .parse(arguments: ["--ui-testing", "--demo", "--demo-seed"], debug: true))
        await services.boot()
        let drop = try XCTUnwrap(services.live.first { $0.info.scopes.contains(.operate) }?.drop)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while drop.loading && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard !drop.loading else { throw Deadline() }
        await drop.refresh()
        XCTAssertFalse(drop.rows.isEmpty)
        return (services, drop)
    }

    func testBusyAndUnknownRemovalPreserveRowsAndAlarmBlocksContent() async throws {
        let (services, drop) = try await fixture()
        let rows = drop.rows
        drop.report(SQLiteError.busy(message: "held"))
        XCTAssertEqual(drop.status, "Busy lock: try again")
        XCTAssertEqual(drop.rows, rows)
        drop.report(TombstoneError.lockFailed(35))
        XCTAssertEqual(drop.status, "Busy lock: try again")
        drop.report(StoreError.removalStateUnknown(ws: drop.workspace!.info.id, generation: 1))
        XCTAssertEqual(services.state(for: drop.workspace!.info.id), .live)
        XCTAssertEqual(drop.rows, rows)
        let errors: [any Error] = [DropError.rollback, DropStoreError.rollback, Refusal.badSignature, CryptoFailure.authenticationFailed]
        for error in errors {
            let isolated = LiveDrop(service: drop.service, workspace: drop.workspace!)
            isolated.report(error)
            XCTAssertTrue(isolated.alarm)
            XCTAssertFalse(isolated.usable)
        }
        drop.report(DropStoreError.rollback)
        XCTAssertTrue(drop.alarm)
        XCTAssertFalse(drop.usable)
        XCTAssertTrue(drop.rows.allSatisfy { !$0.verified && $0.text == nil })
        await drop.refresh()
        XCTAssertTrue(drop.alarm)
        services.resetThisiPhone(); await services.waitForReset()
    }

    func testRetentionRunsAfterAuthorizationFailureAndAlarmPurgesAllFiles() async throws {
        for alarm in [false, true] {
            let (services, drop) = try await fixture()
            let object = try await drop.service.send(Data("private".utf8), name: "private")
            await drop.refresh()
            await drop.open(object.descriptor.object.hex)
            let file = try XCTUnwrap(drop.downloads[object.descriptor.object.hex])
            drop.report(alarm ? DropError.integrity : DropError.unauthorized)
            if alarm {
                await drop.alarmCleanup?.value
            } else {
                let runtime = try XCTUnwrap(services.runtime)
                runtime.clock.advance(milliseconds: file.deadlineMs - runtime.clock.nowMs)
                services.setActive(false); await services.waitForLifecycle()
                services.setActive(true); await services.waitForShareActivation()
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
            XCTAssertNil(drop.previewURL)
            services.resetThisiPhone(); await services.waitForReset()
        }
    }

    func testLatePublicationCannotSurviveLeaveOrReset() async throws {
        for reset in [false, true] {
            let (services, drop) = try await fixture()
            let gate = PublicationGate()
            drop.beforePublication = { await gate.hit() }
            var finished = false
            let read = Task { await drop.refresh(); finished = true }
            do {
                try await bounded { gate.entered }
                if reset { services.resetThisiPhone(); await services.waitForReset() }
                else { _ = await services.leave(workspaceID: drop.workspace!.info.id, simulateOffline: false) }
                gate.release()
                try await bounded { finished }
            } catch {
                gate.release(); read.cancel(); drop.beforePublication = nil
                throw error
            }
            drop.beforePublication = nil
            XCTAssertTrue(drop.rows.isEmpty)
            XCTAssertTrue(drop.downloads.isEmpty)
            XCTAssertNil(drop.previewURL)
            XCTAssertFalse(drop.usable)
            do { try await drop.service.activate(); XCTFail("Invalidated service reactivated") } catch {}
            services.resetThisiPhone(); await services.waitForReset()
        }
    }

    func testForegroundPurgesAndResumesSamePendingIdentity() async throws {
        let (services, drop) = try await fixture()
        let runtime = try XCTUnwrap(services.runtime)
        runtime.faults.enqueue(.disconnect, at: .afterCommitBeforeResponse, routePrefix: "GET " + HostAPI.base + "/drop/")
        await drop.send(.init(workspaceID: drop.workspace!.info.id, attachments: [], note: "recover me"))
        services.setActive(false); await services.waitForLifecycle()
        services.setActive(true); await services.waitForShareActivation()
        let sending = try await drop.service.list(.sending)
        XCTAssertEqual(sending.count, 2) // fixture plus the recovered identity
        let item = try XCTUnwrap(drop.rows.first { $0.direction == .received })
        await drop.open(item.id)
        let file = try XCTUnwrap(drop.downloads[item.id])
        runtime.clock.advance(milliseconds: file.deadlineMs - runtime.clock.nowMs)
        services.setActive(false); await services.waitForLifecycle()
        services.setActive(true); await services.waitForShareActivation()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertNil(drop.previewURL)
        services.resetThisiPhone(); await services.waitForReset()
    }
}
