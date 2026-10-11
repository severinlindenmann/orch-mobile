import XCTest
import OrchClient
import OrchProtocol
import OrchStore
import OrchCoordination
@testable import Orch

@MainActor
final class LiveDropTests: XCTestCase {
    private func fixture() async throws -> (LiveServices, LiveDrop) {
        let services = LiveServices(options: .parse(arguments: ["--ui-testing", "--demo", "--demo-seed"], debug: true))
        await services.boot()
        let drop = try XCTUnwrap(services.live.first { $0.info.scopes.contains(.operate) }?.drop)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while drop.loading && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
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

    func testLatePublicationCannotSurviveLeaveOrReset() async throws {
        for reset in [false, true] {
            let (services, drop) = try await fixture()
            var entered = false
            var resume: CheckedContinuation<Void, Never>?
            drop.beforePublication = {
                entered = true
                await withCheckedContinuation { resume = $0 }
            }
            let read = Task { await drop.refresh() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !entered && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(entered)
            if reset { services.resetThisiPhone(); await services.waitForReset() }
            else { _ = await services.leave(workspaceID: drop.workspace!.info.id, simulateOffline: false) }
            resume?.resume()
            await read.value
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
