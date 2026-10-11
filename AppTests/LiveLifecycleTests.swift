import XCTest
import OrchClient
import OrchProtocol
import OrchPush
import OrchStore
@testable import Orch

private actor Suspension {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = false
    private var released = false
    func wait() async { entered = true; if !released { await withCheckedContinuation { continuations.append($0) } } }
    func signal() { entered = true }
    func resume() { released = true; continuations.forEach { $0.resume() }; continuations = [] }
}

private actor WorkspaceStub: WorkspaceAPI {
    let suspension = Suspension()
    let subscription = Suspension()
    private var suspendSubscription = false
    private(set) var subscriptions = 0
    func holdSubscription() { suspendSubscription = true }
    var foreground: [Bool] = []
    var submissions: [ID16] = []
    var reviews = 0
    var verifiedReceiptMs: Int64? { nil }
    func start() {}
    func setForeground(_ value: Bool) { foreground.append(value) }
    func refreshViews() async { await suspension.wait() }
    func invalidateReviews() {}
    func reconcile(decisionID: ID16) throws -> DecisionOutcome { throw ViewError.offline }
    func retry(decisionID: ID16) throws -> DecisionOutcome { throw ViewError.offline }
    func snapshot() throws -> WorkspaceSnapshot { throw ViewError.offline }
    func review(questionID: ID16) throws -> QuestionReview { reviews += 1; throw ViewError.offline }
    func decide(_ review: QuestionReview, optionID: String) throws -> DecisionOutcome { throw ViewError.offline }
    func pendingDecisions() -> [OrchClient.DecisionStatus] { [] }
    func newTicket(_ draft: NewTicketSubmission) throws -> OrchClient.Ticket {
        // Host accepted this ID; the reply was lost.
        submissions.append(draft.creationID)
        throw ViewError.offline
    }
    func events() async -> AsyncStream<WorkspaceEvent> {
        subscriptions += 1
        if suspendSubscription { await subscription.wait() }
        return AsyncStream { $0.finish() }
    }
}

private actor NotificationRecorder: DemoNotificationBackend {
    let suspension = Suspension()
    var ordering: [String] = []
    var delivered: [String] = ["demo/other/keep"]
    var pending: [String] = ["demo/other/keep"]
    func schedule(_ presentation: PushPresentation, identifier: String) async {
        await suspension.wait()
        delivered.append(identifier); pending.append(identifier)
        ordering.append("scheduled")
    }
    func removeDelivered(identifiers: [String]) {
        delivered.removeAll { identifiers.contains($0) }; pending.removeAll { identifiers.contains($0) }
    }
    func purge(workspace: String?) {
        ordering.append("purged")
        let prefix = workspace.map { "demo/\($0)/" } ?? "demo/"
        delivered.removeAll { $0.hasPrefix(prefix) }; pending.removeAll { $0.hasPrefix(prefix) }
    }
}

@MainActor
final class LiveLifecycleTests: XCTestCase {
    private let options = LaunchOptions.parse(arguments: ["--ui-testing"], debug: true)
    private func workspace(_ services: LiveServices, api: WorkspaceStub = WorkspaceStub()) -> LiveWorkspace {
        let id = SystemEntropy().id16()
        let info = WorkspaceInfo(id: id.hex, name: "Test", host: "Mac", hue: 0, hostedBy: nil, clientHosted: false,
                                 scopes: [.look, .operate, .decide], connection: .online, primaryLabel: "Mac", notificationsOn: true)
        let ws = LiveWorkspace(workspaceID: id, generation: 1, api: api, info: info)
        services.register(ws)
        return ws
    }
    private func waitUntil(_ predicate: () async -> Bool) async {
        for _ in 0..<5000 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for suspension")
    }

    private func bounded(_ operation: @escaping @MainActor () async -> Void) async {
        var done = false
        let task = Task { await operation(); done = true }
        await waitUntil { done }
        task.cancel()
    }

    func testBackgroundForegroundAcrossSuspendedSubscription() async {
        let services = LiveServices(options: options)
        let api = WorkspaceStub()
        await api.holdSubscription()
        let ws = workspace(services, api: api)
        services.setActive(true)
        await waitUntil { await api.subscription.entered }
        services.setActive(false)
        await bounded { await services.waitForLifecycle() }
        await api.subscription.resume()
        await waitUntil { ws.eventTask == nil }
        services.setActive(true)
        await waitUntil { await api.subscriptions == 2 }
        await api.suspension.resume()
        services.setActive(false)
        await bounded { await services.waitForLifecycle() }
    }

    func testNewInvitationDoesNotAbandonSuspendedPairingStart() async throws {
        let runtime = try await DemoRuntime.boot(temporaryStorage: true)
        let services = LiveServices(options: options, runtime: runtime)
        let model = LivePairingModel(services: services, start: nil)
        let gate = Suspension()
        model.afterCoordinatorStart = { await gate.wait() }
        model.useDemoInvitation()
        await waitUntil { await gate.entered }
        model.demoNewLink()
        await bounded { await model.waitForInvitation() }
        XCTAssertFalse(model.demoOfferLink.isEmpty)
        await gate.resume()
        await waitUntil { model.runStarts == 1 }
        await waitUntil {
            if case .comparingHost(let sas) = model.state { return !sas.isEmpty && model.demoHostCode == sas }
            return false
        }
        let hostCode = model.demoHostCode
        let previousOffer = model.demoOfferLink
        model.demoNewLink()
        await bounded { await model.waitForInvitation() }
        XCTAssertNotEqual(model.demoOfferLink, previousOffer)
        // Let the restarted panel sample the host after the new invitation was created.
        await bounded { try? await Task.sleep(for: .milliseconds(650)) }
        XCTAssertEqual(model.demoHostCode, hostCode)
        model.hostApprove()
        await waitUntil {
            if case .waitingPrimary = model.state { return true }
            return false
        }
        model.screenClosed()
        services.exitDemo()
        await bounded { await services.waitForReset() }
    }

    /// Rejecting on the Demo primary while the phone still waits (request opened, challenge not yet pinned) is worded as the
    /// primary's "no", never as the Mac's (PR #45 review).
    func testPrimaryRejectWhileWaitingIsAttributedToThePrimary() async throws {
        let runtime = try await DemoRuntime.boot(temporaryStorage: true)
        let services = LiveServices(options: options, runtime: runtime)
        let model = LivePairingModel(services: services, start: nil)
        /// Real Demo clock (the phone polls every 10 s in cert_pending): up to 60 s, without failing on its own.
        func await60(_ step: String, _ p: () async -> Bool) async {
            for _ in 0..<600 { if await p() { return }; try? await Task.sleep(for: .milliseconds(100)) }
            XCTFail("\(step): \(model.state)")
        }
        model.useDemoInvitation()
        await await60("host code") { if case .comparingHost = model.state { return true }; return false }
        model.hostApprove()
        await await60("waiting") { if case .waitingPrimary = model.state { return true }; return false }
        await runtime.primary.processInbox(relay: runtime.env.relay)          // the request is open on the primary
        let device = runtime.env.deviceID
        await await60("prompt") { await !runtime.primary.openPrompts().filter { $0.deviceID == device }.isEmpty }
        model.primaryReject()
        await await60("end") { if case .refused = model.state { return true }; return model.state == .denied }
        XCTAssertTrue(model.state == .denied || model.state == .refused(.rejectedOnPrimary), "\(model.state)")
        model.screenClosed()
        services.exitDemo()
        await bounded { await services.waitForReset() }
    }

    func testFailedRemovalThenForegroundStaysQuarantined() async throws {
        let runtime = try await DemoRuntime.boot(temporaryStorage: true)
        let services = LiveServices(options: options, runtime: runtime)
        let api = WorkspaceStub()
        let ws = workspace(services, api: api)
        let staleReview = LiveReviewModel(services: services, workspace: ws, questionID: SystemEntropy().id16().hex, optionID: "a")
        services.wipeWorkspace = { _, _ in throw ViewError.offline }
        let report = await services.leave(workspaceID: ws.info.id, simulateOffline: false)
        XCTAssertTrue(report.incomplete)
        services.setActive(true)
        await bounded { await services.waitForLifecycle() }
        let foreground = await api.foreground
        XCTAssertFalse(foreground.contains(true))
        XCTAssertEqual(ws.info.lifecycle, .removalIncomplete)
        XCTAssertEqual(services.workspaces.first?.lifecycle, .removalIncomplete)
        XCTAssertFalse(ws.canCreateTickets)
        let review = services.review(workspaceID: ws.info.id, questionID: "q", optionID: "a")
        await review.loadReview()
        await staleReview.loadReview()
        let reads = await api.reviews
        XCTAssertEqual(reads, 0)
        _ = await ws.createTicket(title: "Refused", body: "")
        let submissions = await api.submissions
        XCTAssertTrue(submissions.isEmpty)
        services.exitDemo(); await bounded { await services.waitForReset() }
    }

    func testOfflineLeaveWipesLocallyAndKeepsServerCleanupPending() async throws {
        let runtime = try await DemoRuntime.boot(temporaryStorage: true)
        let services = LiveServices(options: options, runtime: runtime)
        let ws = workspace(services)
        let id = ws.info.id
        var cleaned: [String] = []
        services.serverCleanup = { cleaned.append($0.ws) }
        let scoped = runtime.keysVault.scoped(to: .demo)
        try scoped.put(Data([1, 2, 3]), ws: ws.workspaceID.hex, purpose: "test")
        let report = await services.leave(workspaceID: id, simulateOffline: true)
        XCTAssertFalse(report.incomplete)
        XCTAssertNil(report.failure)
        XCTAssertEqual(report.server, .pendingOffline)
        XCTAssertEqual(services.state(for: id), .removed)
        XCTAssertTrue(services.workspaces.isEmpty)
        let tombstones = try await runtime.env.index.tombstones()
        XCTAssertTrue(tombstones.contains { $0.record.ws == ws.workspaceID.hex && $0.phase >= LocalWipe.donePhase })
        // The server half is a persisted pending item, not a failure.
        XCTAssertThrowsError(try scoped.get(ws: ws.workspaceID.hex, purpose: "test"))   // no key material left
        XCTAssertEqual(services.pendingServerCleanups.map(\.ws), [ws.workspaceID.hex])
        XCTAssertEqual(services.pendingServerCleanups.first?.generation, ws.generation)
        XCTAssertEqual(ServerCleanupStore(defaults: services.cleanupDefaults).load().count, 1)
        XCTAssertTrue(cleaned.isEmpty)
        await services.retryServerCleanup()
        XCTAssertEqual(cleaned, [ws.workspaceID.hex])
        XCTAssertTrue(services.pendingServerCleanups.isEmpty)
        services.exitDemo(); await bounded { await services.waitForReset() }
    }

    func testServerCleanupStaysPendingWhileStillFailing() async throws {
        let runtime = try await DemoRuntime.boot(temporaryStorage: true)
        let services = LiveServices(options: options, runtime: runtime)
        _ = workspace(services)
        services.serverCleanup = { _ in throw ViewError.offline }
        let id = services.workspaces[0].id
        _ = await services.leave(workspaceID: id, simulateOffline: true)
        await services.retryServerCleanup()
        XCTAssertEqual(services.pendingServerCleanups.count, 1)
        services.exitDemo(); await bounded { await services.waitForReset() }
    }

    func testFailedShareJournalDoesNotBlockLocalWipe() async throws {
        let runtime = try await DemoRuntime.boot(temporaryStorage: true)
        let services = LiveServices(options: options, runtime: runtime)
        let ws = workspace(services)
        services.beforeWorkspaceRemoval = { _ in false }
        let report = await services.leave(workspaceID: ws.info.id, simulateOffline: true)
        XCTAssertFalse(report.incomplete)
        XCTAssertEqual(services.state(for: ws.info.id), .removed)
        // The wipe's own tombstone is durable in the coordination directories, so extensions refuse this workspace.
        let records = try runtime.env.layout.tombstones.records()
        XCTAssertTrue(records.contains { $0.ws == ws.workspaceID.hex && $0.generation >= ws.generation })
        XCTAssertNotNil(services.shareStatus)   // the unfinished journal is surfaced
        services.exitDemo(); await bounded { await services.waitForReset() }
    }

    func testRepairingDropsStalePendingServerCleanup() async throws {
        let runtime = try await DemoRuntime.boot(temporaryStorage: true)
        let services = LiveServices(options: options, runtime: runtime)
        let ws = workspace(services)
        _ = await services.leave(workspaceID: ws.info.id, simulateOffline: true)
        XCTAssertEqual(services.pendingServerCleanups.count, 1)
        let again = LiveWorkspace(workspaceID: ws.workspaceID, generation: ws.generation + 1, api: WorkspaceStub(), info: ws.info)
        services.register(again)
        XCTAssertTrue(services.pendingServerCleanups.isEmpty)
        services.exitDemo(); await bounded { await services.waitForReset() }
    }

    func testGenuineLocalWipeFailureStaysIncompleteEvenOffline() async throws {
        let runtime = try await DemoRuntime.boot(temporaryStorage: true)
        let services = LiveServices(options: options, runtime: runtime)
        let ws = workspace(services)
        services.wipeWorkspace = { _, _ in throw ViewError.offline }
        let report = await services.leave(workspaceID: ws.info.id, simulateOffline: true)
        XCTAssertTrue(report.incomplete)
        XCTAssertNotNil(report.failure)
        XCTAssertEqual(services.state(for: ws.info.id), .removalIncomplete)
        XCTAssertTrue(services.pendingServerCleanups.isEmpty)   // nothing is "removed", so no server cleanup is queued
        services.exitDemo(); await bounded { await services.waitForReset() }
    }

    func testBackgroundDoesNotWaitForSuspendedRefresh() async {
        let services = LiveServices(options: options)
        let api = WorkspaceStub()
        let ws = workspace(services, api: api)
        services.setActive(true)
        await waitUntil { await api.suspension.entered }
        services.setActive(false)
        await bounded { await services.waitForLifecycle() }
        let states = await api.foreground
        XCTAssertEqual(states, [true, false])
        XCTAssertFalse(ws.canCreateTickets)
        await api.suspension.resume()
    }

    func testSecondResetRetriesFirstFailedRuntime() async throws {
        let runtime = try await DemoRuntime.boot(temporaryStorage: true)
        let suite = "orch.reset-test.\(UUID().uuidString)"
        let flags = UserDefaults(suiteName: suite)!
        defer { flags.removePersistentDomain(forName: suite) }
        let services = LiveServices(options: options, runtime: runtime, resetFlags: flags)
        let ws = workspace(services)
        var attempts = 0
        services.resetRuntime = { retained in
            XCTAssertTrue(retained === runtime)
            XCTAssertTrue(flags.bool(forKey: "orch.demo.resetPending"))
            attempts += 1
            if attempts == 1 { throw ViewError.offline }
            try await retained.reset()
        }
        services.exitDemo(); await bounded { await services.waitForReset() }
        XCTAssertNil(services.runtime)
        XCTAssertEqual(services.state(for: ws.info.id), .removalIncomplete)
        XCTAssertTrue(flags.bool(forKey: "orch.demo.resetPending"))
        XCTAssertTrue(services.resetIncomplete)
        services.exitDemo(); await bounded { await services.waitForReset() }
        XCTAssertFalse(flags.bool(forKey: "orch.demo.resetPending"))
        XCTAssertFalse(services.resetIncomplete)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(services.state(for: ws.info.id), .removed)
    }

    func testFailedLaunchResetRecoveryShowsFailureAndCanRetry() async {
        let suite = "orch.reset-test.\(UUID().uuidString)"
        let flags = UserDefaults(suiteName: suite)!
        let defaults = UserDefaults.standard
        let previousDemo = defaults.object(forKey: "orch.demo.entered")
        defaults.set(false, forKey: "orch.demo.entered")
        defer {
            flags.removePersistentDomain(forName: suite)
            if let previousDemo { defaults.set(previousDemo, forKey: "orch.demo.entered") }
            else { defaults.removeObject(forKey: "orch.demo.entered") }
        }
        flags.set(true, forKey: "orch.demo.resetPending")
        let services = LiveServices(options: .parse(arguments: [], debug: true), resetFlags: flags)
        var attempts = 0
        services.finishInterruptedReset = {
            attempts += 1
            if attempts == 1 { throw ViewError.offline }
        }
        await bounded { await services.boot() }
        XCTAssertTrue(services.ready)
        XCTAssertTrue(services.resetIncomplete)
        XCTAssertTrue(flags.bool(forKey: "orch.demo.resetPending"))
        XCTAssertEqual(attempts, 1)
        services.exitDemo()
        await bounded { await services.waitForReset() }
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(services.resetIncomplete)
        XCTAssertFalse(flags.bool(forKey: "orch.demo.resetPending"))
    }

    func testOverlappingResetsRetryFailedContext() async throws {
        let runtime = try await DemoRuntime.boot(temporaryStorage: true)
        let suite = "orch.reset-test.\(UUID().uuidString)"
        let flags = UserDefaults(suiteName: suite)!
        defer { flags.removePersistentDomain(forName: suite) }
        let services = LiveServices(options: options, runtime: runtime, resetFlags: flags)
        let gate = Suspension()
        var attempts = 0
        services.resetRuntime = { retained in
            XCTAssertTrue(retained === runtime)
            XCTAssertTrue(flags.bool(forKey: "orch.demo.resetPending"))
            attempts += 1
            if attempts == 1 {
                await gate.wait()
                throw ViewError.offline
            }
            try await retained.reset()
        }
        services.exitDemo()
        await waitUntil { await gate.entered }
        services.exitDemo()
        await gate.resume()
        await bounded { await services.waitForReset() }
        XCTAssertFalse(flags.bool(forKey: "orch.demo.resetPending"))
        XCTAssertFalse(services.resetIncomplete)
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(services.runtime)
    }

    func testDraftWriteFailureAndLostResponseRetry() async throws {
        let services = LiveServices(options: options)
        let api = WorkspaceStub()
        let ws = workspace(services, api: api)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        ws.draftURL = dir.appendingPathComponent("draft.json")
        _ = await ws.createTicket(title: "Ticket", body: "Body")
        let absent = await api.submissions
        XCTAssertTrue(absent.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "stale drafts must not recreate wiped directories")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        // A present directory is insufficient if the draft write fails.
        try FileManager.default.createDirectory(at: ws.draftURL!, withIntermediateDirectories: false)
        _ = await ws.createTicket(title: "Ticket", body: "Body")
        let failed = await api.submissions
        XCTAssertTrue(failed.isEmpty)
        try FileManager.default.removeItem(at: ws.draftURL!)
        _ = await ws.createTicket(title: "Ticket", body: "Body")
        // Recreate the model, proving the retry ID comes from disk rather than memory.
        let reopened = LiveWorkspace(workspaceID: ws.workspaceID, generation: 1, api: api, info: ws.info)
        reopened.services = services; reopened.draftURL = ws.draftURL
        _ = await reopened.createTicket(title: "Ticket", body: "Body")
        let ids = await api.submissions
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 1)
    }

    func testCloseDuringDemoNewLinkDoesNotStartPanel() async throws {
        let runtime = try await DemoRuntime.boot(temporaryStorage: true)
        let services = LiveServices(options: options, runtime: runtime)
        let model = LivePairingModel(services: services, start: nil)
        let gate = Suspension()
        model.beforeInvitation = { await gate.wait() }
        model.demoNewLink()
        await waitUntil { await gate.entered }
        model.screenClosed()
        await gate.resume()
        await bounded { await model.waitForInvitation() }
        XCTAssertEqual(model.panelStarts, 0)
        XCTAssertEqual(model.demoOfferLink, "")
        services.exitDemo(); await bounded { await services.waitForReset() }
    }

    func testLeaveDrainsSchedulingAndPurgesBothNotificationQueues() async throws {
        let backend = NotificationRecorder()
        let drain = Suspension()
        let notifications = DemoNotifications(backend: backend, onDrain: { await drain.signal() })
        let runtime = try await DemoRuntime.boot(temporaryStorage: true, notifications: notifications)
        let services = LiveServices(options: options, runtime: runtime)
        let ws = workspace(services)
        try await runtime.env.index.addWorkspace(ws: ws.info.id, generation: ws.generation)
        let schedule = Task { await notifications.schedule(.generic, identifier: "test", workspace: ws.info.id) }
        await waitUntil { await backend.suspension.entered }
        var completed = false
        let leave = Task {
            let report = await services.leave(workspaceID: ws.info.id, simulateOffline: false)
            XCTAssertFalse(report.incomplete)
            completed = true
            return report
        }
        await waitUntil { await drain.entered }
        XCTAssertFalse(completed)
        await backend.suspension.resume()
        await bounded { await schedule.value }
        await waitUntil { completed }
        leave.cancel()
        let ordering = await backend.ordering
        XCTAssertEqual(ordering.first, "scheduled")
        XCTAssertFalse(ordering.dropFirst().isEmpty)
        XCTAssertTrue(ordering.dropFirst().allSatisfy { $0 == "purged" })
        ws.draftURL = runtime.draftURL(workspace: ws.workspaceID)
        _ = await ws.createTicket(title: "Stale model", body: "Must not be written")
        XCTAssertFalse(ws.canCreateTickets)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.draftURL!.deletingLastPathComponent().path))
        let delivered = await backend.delivered
        let pending = await backend.pending
        XCTAssertEqual(delivered, ["demo/other/keep"])
        XCTAssertEqual(pending, ["demo/other/keep"])
        await notifications.schedule(.generic, identifier: "late", workspace: ws.info.id)
        let after = await backend.pending
        XCTAssertEqual(after, pending)
        services.exitDemo(); await bounded { await services.waitForReset() }
    }

    func testDeliveredAPNsMatchWorkspaceThreadRegardlessOfIdentifier() {
        XCTAssertTrue(SystemDemoNotifications.matchesDelivered(identifier: "apns-assigned", thread: "workspace", workspace: "workspace"))
        XCTAssertFalse(SystemDemoNotifications.matchesDelivered(identifier: "apns-assigned", thread: "other", workspace: "workspace"))
        XCTAssertTrue(SystemDemoNotifications.matchesDelivered(identifier: "demo/workspace/request", thread: "", workspace: "workspace"))
    }

    func testResetDrainsInflightSchedule() async throws {
        let backend = NotificationRecorder()
        let drain = Suspension()
        let notifications = DemoNotifications(backend: backend, onDrain: { await drain.signal() })
        let runtime = try await DemoRuntime.boot(temporaryStorage: true, notifications: notifications)
        let services = LiveServices(options: options, runtime: runtime)
        let schedule = Task { await notifications.schedule(.generic, identifier: "test", workspace: "reset") }
        await waitUntil { await backend.suspension.entered }
        services.exitDemo()
        await waitUntil { await drain.entered }
        await backend.suspension.resume()
        await bounded { await schedule.value }
        await bounded { await services.waitForReset() }
        let ordering = await backend.ordering
        XCTAssertEqual(ordering.first, "scheduled")
        XCTAssertFalse(ordering.dropFirst().isEmpty)
        XCTAssertTrue(ordering.dropFirst().allSatisfy { $0 == "purged" })
        let pending = await backend.pending
        let delivered = await backend.delivered
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(delivered.isEmpty)
    }

    func testUnavailableRuntimeAndUnknownWorkspaceLeaveAreIncomplete() async {
        let services = LiveServices(options: options)
        let ws = workspace(services)
        let missingRuntime = await services.leave(workspaceID: ws.info.id, simulateOffline: false)
        let unknown = await services.leave(workspaceID: "unknown", simulateOffline: false)
        XCTAssertTrue(missingRuntime.incomplete)
        XCTAssertTrue(unknown.incomplete)
    }
}
