import XCTest
import os
import OrchPush
@testable import Orch

final class BoundedOSCallTests: XCTestCase {
    /// A notification daemon that never calls back must not block app start (launch spinner hang): the result is nil (unknown).
    func testNeverAnsweringCallIsUnknown() async {
        let value: [String]? = await boundedOSCall(seconds: 0.2) { _ in }
        XCTAssertNil(value)
    }

    func testAnswerWinsAndLateTimerResumesNothingMore() async throws {
        let resumes = OSAllocatedUnfairLock(initialState: 0)
        let value: Int? = await boundedOSCall(seconds: 0.2, resumes: resumes) { done in done(7) }
        XCTAssertEqual(value, 7)
        try await Task.sleep(nanoseconds: 400_000_000)   // past the timer
        XCTAssertEqual(resumes.withLock { $0 }, 1)
    }

    func testLateAnswerAfterTimeoutIsIgnored() async throws {
        let resumes = OSAllocatedUnfairLock(initialState: 0)
        let value: Int? = await boundedOSCall(seconds: 0.1, resumes: resumes) { done in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { done(9) }
        }
        XCTAssertNil(value)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(resumes.withLock { $0 }, 1)
    }

    /// An unanswered purge is recorded as owed (so it is retried on the next boot); a whole-Demo purge subsumes workspaces.
    func testOwedPurgeBookkeeping() {
        let d = UserDefaults(suiteName: "owed-\(UUID().uuidString)")!
        SystemDemoNotifications.setOwed("ws1", true, defaults: d)
        SystemDemoNotifications.setOwed(nil, true, defaults: d)
        XCTAssertEqual(SystemDemoNotifications.owed(d), ["*", "ws1"])
        SystemDemoNotifications.setOwed("ws1", false, defaults: d)
        XCTAssertEqual(SystemDemoNotifications.owed(d), ["*"])
        SystemDemoNotifications.setOwed(nil, false, defaults: d)
        XCTAssertTrue(SystemDemoNotifications.owed(d).isEmpty)
    }
}

final class DemoNotificationGateTests: XCTestCase {
    actor Log { var events: [String] = []; func add(_ e: String) { events.append(e) } }
    struct Backend: DemoNotificationBackend {
        let log: Log
        func schedule(_ presentation: PushPresentation, identifier: String) async { await log.add("schedule") }
        func removeDelivered(identifiers: [String]) async {}
        func purge(workspace: String?) async { try? await Task.sleep(nanoseconds: 300_000_000); await log.add("purge") }
    }

    /// The boot purge removes demo/ and sim/ by prefix, so the new runtime must not schedule until it is done.
    func testSchedulingWaitsForBootPurgeSoItIsNeverPurged() async {
        let log = Log()
        let n = DemoNotifications(backend: Backend(log: log))
        let purge = Task.detached { await Backend(log: log).purge(workspace: nil) }
        await n.hold(until: purge)
        await n.schedule(PushPresentation.generic, identifier: "i", workspace: "w")
        let events = await log.events
        XCTAssertEqual(events, ["purge", "schedule"])
    }
}
