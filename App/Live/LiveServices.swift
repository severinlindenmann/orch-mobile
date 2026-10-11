import Foundation
import Observation
import OrchClient
import OrchFakeHost
import OrchProtocol
import OrchPush
import OrchCustody
import OrchShareStaging
import UserNotifications

/// The App's real service layer. In Demo it runs the real client stack against the in-process fakes (`DemoRuntime`); a build without a
/// reachable relay has no workspaces at all (pairing says so). Screens see only the view-model protocols (A4): never FakeHost, custody
/// or signing.
@MainActor @Observable
final class LiveServices: AppServices, HomeModel, DropModel, SettingsModel, ShareWorld {
    private enum Keys { static let demo = "orch.demo.entered"; static let resetPending = "orch.demo.resetPending" }

    let options: LaunchOptions
    private(set) var ready = false
    private(set) var isDemo = false
    private(set) var live: [LiveWorkspace] = []
    private(set) var pendingDecisions: [DecisionStatus] = []
    private(set) var lastChecked = Date()
    private var heldDropItems: [DropItem] = []
    var dropItems: [DropItem] { live.flatMap { $0.drop?.rows ?? [] } + heldDropItems }
    private(set) var demoPushResult: String?
    var onRetryShared: (() -> Void)?
    var onStopShared: (() -> Void)?
    var deviceLabel = "Demo iPhone"
    var notificationStatus: NotificationStatus = .notAsked
    var pairingScenario: PairingScenario = .firstTime
    var signOutcome: SignOutcome = .accepted
    @ObservationIgnored private(set) var runtime: DemoRuntime?
    @ObservationIgnored var beforeWorkspaceRemoval: ((String) -> Bool)?
    @ObservationIgnored var onRedirectQuarantined: ((_ jobID: String, _ workspaceID: String) -> Void)?
    @ObservationIgnored private var resetTask: Task<Void, Never>?
    @ObservationIgnored private var bootTask: Task<DemoRuntime?, Never>?
    @ObservationIgnored private var submitted: [String: ReviewValue] = [:]
    /// Keyed "<workspace hex>/<decision hex>"; an entry is removed when its task ends.
    @ObservationIgnored private var reconcileTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var reconcileSerials: [String: Int] = [:]
    @ObservationIgnored private var reconcileSerial = 0
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var demoLockRelease: Task<Void, Never>?
    private(set) var lifecycle: [String: WorkspaceLifecycle] = [:]
    private(set) var active = true
    @ObservationIgnored private var refreshTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var failedReset: DemoRuntime?
    private(set) var resetIncomplete = false
    @ObservationIgnored private let resetFlags: UserDefaults
    @ObservationIgnored private var resetRevision = 0
    // Injection points exercise failure boundaries without weakening the runtime availability check.
    @ObservationIgnored var wipeWorkspace: (DemoRuntime, LiveWorkspace) async throws -> Void = { runtime, ws in
        try await runtime.wipe(workspace: ws.workspaceID, generation: ws.generation)
    }
    @ObservationIgnored var resetRuntime: (DemoRuntime) async throws -> Void = { try await $0.reset() }

    @ObservationIgnored var finishInterruptedReset: () async throws -> Void = { try await DemoRuntime.finishInterruptedReset() }

    func state(for id: String) -> WorkspaceLifecycle { lifecycle[id] ?? .removed }
    func isLive(_ id: String) -> Bool { state(for: id) == .live }
    func canUse(_ id: String) -> Bool { active && isLive(id) }
    func register(_ ws: LiveWorkspace) {
        ws.services = self
        lifecycle[ws.info.id] = .live
        live.append(ws)
    }
    func waitForLifecycle() async { await lifecycleTask?.value }
    func waitForReset() async { await resetTask?.value }

    private func transition(_ id: String, to state: WorkspaceLifecycle) {
        if state != .live { live.first { $0.info.id == id }?.drop?.cancelUI(clear: true) }
        lifecycle[id] = state
        if state != .live { refreshTasks[id]?.cancel(); refreshTasks[id] = nil }
    }

    init(options: LaunchOptions, runtime: DemoRuntime? = nil, resetFlags: UserDefaults? = nil) {
        self.resetFlags = resetFlags ?? (options.uiTesting
            ? UserDefaults(suiteName: "orch.tests.\(UUID().uuidString)")! : .standard)
        self.options = options; self.runtime = runtime; self.isDemo = runtime != nil
    }

    // MARK: Boot

    func boot() async {
        guard !ready else { return }
        Task.detached { await SystemDemoNotifications().retryOwedPurges() }
        let defaults = UserDefaults.standard
        // Ticket drafts now live in the workspace directory; remove any older copy that outlived a Leave.
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("orch.ticket.draft.") { defaults.removeObject(forKey: key) }
        if !options.uiTesting, resetFlags.bool(forKey: Keys.resetPending) {
            // A Demo reset was interrupted: finish it first, whether or not Demo was entered.
            do {
                try await finishInterruptedReset()
                resetFlags.set(false, forKey: Keys.resetPending)
                resetIncomplete = false
            } catch {
                resetIncomplete = true
            }
        }
        let persisted = !options.uiTesting && defaults.bool(forKey: Keys.demo)
        if options.demo || persisted { _ = await startDemo() }
        if options.demoSeed, isDemo { await seedDemoWorkspaces() }
        ready = true
    }

    @discardableResult
    private func startDemo() async -> DemoRuntime? {
        if let bootTask {
            let revision = resetRevision
            let result = await bootTask.value
            return revision == resetRevision ? result : nil
        }
        await resetTask?.value
        // Another caller may have booted (or started booting) while the reset was awaited.
        if let bootTask {
            let revision = resetRevision
            let result = await bootTask.value
            return revision == resetRevision ? result : nil
        }
        if let runtime { return runtime }
        guard failedReset == nil else { return nil }
        let revision = resetRevision
        let task = Task { () -> DemoRuntime? in
            do { return try await DemoRuntime.boot(temporaryStorage: self.options.uiTesting) } catch { return nil }
        }
        bootTask = task
        let r = await task.value
        guard revision == resetRevision else { return nil }
        bootTask = nil
        runtime = r
        isDemo = r != nil
        if let r { r.deviceLabel = deviceLabel }
        if !options.uiTesting { UserDefaults.standard.set(r != nil, forKey: Keys.demo) }
        return r
    }

    /// The running Demo, booting it first when "Try Demo" is still starting it.
    func demoRuntime() async -> DemoRuntime? {
        if let runtime { return runtime }
        if isDemo || bootTask != nil { return await startDemo() }
        return nil
    }

    /// DEBUG UI tests only: pairs the two Demo workspaces through the same pairing model, with the Demo humans' explicit actions
    /// played by this loop, on a fast Demo clock.
    private func seedDemoWorkspaces() async {
        guard let runtime else { return }
        runtime.speed = 10
        defer { runtime.speed = 1 }
        for _ in 0..<2 {
            let model = LivePairingModel(services: self, start: nil)
            model.useDemoInvitation()
            let deadline = Date().addingTimeInterval(90)
            var done = false
            while !done, Date() < deadline {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { model.cancel(); return }
                switch model.state {
                case .comparingHost where !model.demoHostCode.isEmpty: model.hostApprove()
                case .waitingPrimary: model.primaryOpenRequest()
                case .comparingPrimary where model.demoPrimaryHasChallenge: model.primaryApprove()
                case .ready, .refused, .alarm, .expired, .denied: done = true
                default: break
                }
            }
            model.cancel()
        }
        for ws in live { await ws.refresh() }
        await refreshPending()
    }

    // MARK: AppServices

    var home: any HomeModel { self }
    var drop: any DropModel { self }
    var settings: any SettingsModel { self }

    func workspace(_ id: String) -> any WorkspaceModel {
        live.first { $0.info.id == id } ?? RemovedWorkspaceModel(id: id)
    }

    func review(workspaceID: String, questionID: String, optionID: String) -> any QuestionReviewModel {
        guard canUse(workspaceID), let ws = live.first(where: { $0.info.id == workspaceID }) else { return UnavailableReviewModel() }
        return LiveReviewModel(services: self, workspace: ws, questionID: questionID, optionID: optionID)
    }

    func makePairing(start: PairingState?) -> any PairingFlowModel { LivePairingModel(services: self, start: start) }

    func workspaceID(forQuestion id: String) -> String? { resolveQuestion(id)?.workspaceID }

    func resolveWorkspace(_ raw: String) -> String? {
        if let ws = live.first(where: { $0.info.id == raw }) { return ws.info.id }
        guard let runtime else { return nil }
        return live.first { ws in runtime.entry(for: ws.workspaceID)?.kind.alias == raw }?.info.id
    }

    func resolveQuestion(_ raw: String) -> (workspaceID: String, questionID: String)? {
        for ws in live {
            if ws.questions.contains(where: { $0.id == raw }) { return (ws.info.id, raw) }
            if let id = runtime?.entry(for: ws.workspaceID)?.aliases[raw] { return (ws.info.id, id.hex) }
        }
        return nil
    }

    // MARK: Workspaces

    func workspaceJoined(_ handle: JoinedHandle) {
        let j = handle.joined
        guard !live.contains(where: { $0.workspaceID == j.workspace }) else { return }
        guard let entry = runtime?.entry(for: j.workspace) else { return }
        entry.joined = true
        let kind: DemoRuntime.Kind? = entry.kind
        let info = WorkspaceInfo(
            id: j.workspace.hex, name: j.name, host: kind?.hostLabel ?? "Demo Mac", hue: kind.map { $0.rawValue } ?? live.count,
            hostedBy: j.hosted.marker ? (j.hosted.hostedBy ?? "(unknown)") : nil, clientHosted: j.hosted.marker,
            scopes: Mapping.scopes(j.scopes), connection: .online, primaryLabel: "Demo Mac", notificationsOn: true)
        let ws = LiveWorkspace(workspaceID: j.workspace, generation: j.generation, api: BridgeWorkspaceAPI(session: j.session), info: info)
        ws.services = self
        ws.downloadContainer = j.downloadContainer
        ws.draftURL = runtime?.draftURL(workspace: j.workspace)
        if let service = try? j.makeDropService() { ws.drop = LiveDrop(service: service, workspace: ws) }
        register(ws)
        Task {
            if kind == .laptop, let drop = ws.drop {
                do {
                    let object = try await DemoSetup.seedDropSending(drop.service)
                    guard drop.usable else { return }
                    drop.aliases[object.descriptor.object.hex] = "d-sending"
                } catch { if drop.usable { drop.report(error) } }
            }
            await ws.drop?.refresh()
        }
        ws.start()
        Task { await refreshPending() }
    }

    func workspaceRemoved(_ ws: LiveWorkspace) {
        Task { _ = await leave(workspaceID: ws.info.id, simulateOffline: false) }
    }

    func snapshotApplied(_ ws: LiveWorkspace) {
        Task {
            if let ms = await ws.api.verifiedReceiptMs, let runtime { lastChecked = runtime.date(forMs: ms) } else { lastChecked = Date() }
        }
    }

    /// Lock/background: reviews and arming are dropped; return to foreground reads afresh and re-drives stored submissions.
    func setActive(_ active: Bool) {
        self.active = active
        if !active { for ws in live { ws.drop?.cancelUI(clear: false) } }
        refreshTasks.values.forEach { $0.cancel() }
        refreshTasks = [:]
        if !active { reconcileTasks.values.forEach { $0.cancel() } }
        let previous = lifecycleTask
        let workspaces = live
        lifecycleTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            for ws in workspaces {
                if let drop = ws.drop {
                    if active && self.canUse(ws.info.id) { try? await drop.service.activate() }
                    else { await drop.service.suspend() }
                }
                await ws.api.setForeground(active && self.canUse(ws.info.id))
            }
            guard active, self.active else { return }
            // Local retention is independent of relay authorization and Drop alarms.
            for ws in workspaces where ws.info.lifecycle != .removed {
                do { try await ws.downloadContainer?.purgeExpiredDownloads(nowMs: ws.drop?.alarm == true ? .max : (self.runtime?.clock.nowMs ?? Int64(Date().timeIntervalSince1970 * 1000))) }
                catch { ws.drop?.status = "Local cleanup needs retry" }
            }
            for ws in workspaces where self.canUse(ws.info.id) {
                ws.start()
                self.refreshTasks[ws.info.id] = Task { [weak self] in
                    await ws.drop?.foreground()
                    await ws.api.refreshViews()
                    guard !Task.isCancelled, let self, self.canUse(ws.info.id) else { return }
                    await self.refreshPending(reconcile: true)
                }
            }
        }
    }

    // MARK: HomeModel

    var workspaces: [WorkspaceInfo] { live.map(\.info) }

    var needsYou: [NeedsYouGroup] {
        live.compactMap { ws in
            let waiting = ws.waiting
            return waiting.isEmpty ? nil : NeedsYouGroup(workspace: ws.info, questions: waiting)
        }.sorted { ($0.questions.first?.created ?? .distantFuture) < ($1.questions.first?.created ?? .distantFuture) }
    }

    var needsYouCount: Int { live.reduce(0) { $0 + $1.waiting.count } }

    var oldestWaiting: (question: Question, workspace: WorkspaceInfo)? {
        live.flatMap { ws in ws.waiting.map { ($0, ws.info) } }.min { $0.0.created < $1.0.created }
    }

    func waitingCount(in workspaceID: String) -> Int { live.first { $0.info.id == workspaceID }?.waiting.count ?? 0 }

    var dropSummary: DropSummary {
        let unread = dropItems.filter { $0.direction == .received && $0.unread }
        return DropSummary(newCount: unread.count, lastName: unread.last?.name)
    }

    func enterDemo() { Task { await startDemo() } }

    // MARK: Pending decisions (U8)

    func recordSubmission(_ review: ReviewValue) { submitted[review.questionID + "/" + review.optionID] = review }

    func storedDecision(workspace: LiveWorkspace, questionID: String) async -> ID16? {
        guard canUse(workspace.info.id), let qid = ID16(hex: questionID) else { return nil }
        return (try? await workspace.api.pendingDecisions())?.first { $0.questionID == qid }?.decisionID
    }

    func refreshPending(reconcile: Bool = false) async {
        var out: [DecisionStatus] = []
        for ws in live where canUse(ws.info.id) {
            // A store error is not an empty list: keep what is shown until the next read succeeds.
            guard let statuses = try? await ws.api.pendingDecisions(), canUse(ws.info.id), !Task.isCancelled else { return }
            for d in statuses {
                let q = ws.question(id: d.questionID.hex)
                let key = d.questionID.hex + "/" + d.optionID
                let review = submitted[key] ?? ReviewValue(
                    workspaceID: ws.info.id, workspaceName: ws.info.name, hue: ws.info.hue, clientHosted: ws.info.clientHosted,
                    hostedBy: ws.info.hostedBy, questionID: d.questionID.hex, ticket: q?.ticket ?? "", text: q?.text ?? "",
                    optionID: d.optionID, optionLabel: q?.options.first { $0.id == d.optionID }?.label ?? d.optionID,
                    options: q?.options ?? [], contentHash: q?.contentHash ?? "", revision: 0, isDemo: isDemo)
                let outcome: DecisionOutcomeState = d.state == .uncertain ? .uncertain : .pending
                out.append(DecisionStatus(decisionID: d.decisionID.hex, questionID: d.questionID.hex, workspaceID: ws.info.id,
                                          optionID: d.optionID, optionLabel: review.optionLabel, review: review, outcome: outcome))
                if reconcile { startReconcile(workspace: ws, decisionID: d.decisionID) }
            }
        }
        pendingDecisions = out.filter { $0.outcome != .resolved }
    }

    /// Bounded background reconciliation while the app runs; the state stays visible on Home. It reconciles the stored decision only.
    func startReconcile(workspace: LiveWorkspace, decisionID: ID16) {
        guard canUse(workspace.info.id) else { return }
        let key = workspace.workspaceID.hex + "/" + decisionID.hex
        reconcileTasks[key]?.cancel()
        reconcileSerial += 1
        let serial = reconcileSerial
        reconcileSerials[key] = serial
        reconcileTasks[key] = Task { [weak self] in
            // Remove this task's own entry when it ends (finished, settled or cancelled), never a newer one under the same key.
            defer { self?.reconcileEnded(key: key, serial: serial) }
            for _ in 0..<6 {
                do { try await Task.sleep(for: .seconds(self?.options.uiTesting == true ? 20 : 4)) } catch { return }
                guard let self, self.canUse(workspace.info.id) else { return }
                if let outcome = try? await workspace.api.reconcile(decisionID: decisionID), outcome != .uncertain {
                    await self.decisionSettled(workspace: workspace)
                    return
                }
            }
        }
        Task { await refreshPending() }
    }

    private func reconcileEnded(key: String, serial: Int) {
        guard reconcileSerials[key] == serial else { return }
        reconcileTasks[key] = nil
        reconcileSerials[key] = nil
    }

    func decisionSettled(workspace: LiveWorkspace) async {
        await workspace.refresh()
        await refreshPending()
    }

    // MARK: Demo controls (real host behaviour, one shot)

    /// True once when "Review fails to load" is armed: the next review read is treated as failed (nothing is signed or stored).
    func takeDemoReadFailure() -> Bool {
        guard isDemo, signOutcome == .loadFails else { return false }
        signOutcome = .accepted
        return true
    }

    func applyDemoSignControl(workspace: LiveWorkspace, questionID: String, optionID: String) async {
        let outcome = signOutcome
        guard workspace.usable, outcome != .accepted, outcome != .loadFails, let runtime,
              let host = runtime.entry(for: workspace.workspaceID)?.host, let qid = ID16(hex: questionID) else { return }
        signOutcome = .accepted              // one-shot
        switch outcome {
        case .alreadyAnswered:
            let first = workspace.question(id: questionID)?.options.first?.id ?? optionID
            try? await host.demoAnswerOnHost(question: qid, optionID: first)
        case .questionChanged:
            let text = workspace.question(id: questionID)?.text ?? ""
            try? await host.demoEditQuestion(qid, text: text + "\nEdited at the Mac.")
        case .uncertain:
            await host.demoLoseNextDecisionResponse(faults: runtime.faults)
        case .locked:
            // The simulated phone is locked for this attempt; it unlocks by itself a few seconds later (the person unlocking it).
            runtime.lock.isLocked = true
            demoLockRelease?.cancel()
            demoLockRelease = Task { [weak runtime] in
                try? await Task.sleep(for: .seconds(2))
                runtime?.lock.isLocked = false
            }
        default: break
        }
    }

    var deviceLocked: Bool { runtime?.lock.isLocked ?? false }

    // MARK: DropModel (simulated: no Drop service yet)

    func items(_ direction: DropDirection) -> [DropItem] { dropItems.filter { $0.direction == direction } }
    func item(id: String) -> DropItem? { dropItems.first { $0.id == id || $0.presentationID == id } }
    func items(workspace: String) -> [DropItem] { dropItems.filter { $0.workspaceID == workspace } }

    func canSend(to workspaceID: String) -> Bool { eligibleShareDestination(workspaceID) }

    func send(_ draft: DropDraft) {
        guard canUse(draft.workspaceID), let drop = live.first(where: { $0.info.id == draft.workspaceID })?.drop else { return }
        drop.startSend(draft)
    }

    func refreshDrop() async {
        for ws in live where canUse(ws.info.id) { await ws.drop?.refresh() }
    }
    func verifyDropRow(_ id: String) async {
        if let item = item(id: id), let drop = dropState(item.id) { await drop.verifyVisible(item.id); return }
        // A fixture deep route resolves only after metadata verification; no fake object is inserted.
        if id.hasPrefix("d-") {
            await refreshDrop()
            for drop in live.compactMap(\.drop) {
                for row in drop.rows.prefix(12) {
                    await drop.verifyVisible(row.id)
                    if item(id: id) != nil { return }
                }
            }
        }
    }
    func dropState(_ id: String) -> LiveDrop? {
        live.compactMap(\.drop).first { $0.objects[id] != nil || $0.rows.contains { $0.presentationID == id } }
    }
    private(set) var shareStatus: String?
    var dropRefreshRevision: Int { live.reduce(0) { $0 + ($1.drop?.listRevision ?? 0) } }
    var dropStatus: String? { live.compactMap { $0.drop?.status }.first ?? shareStatus ?? (live.contains { $0.drop?.loading == true } ? "Loading…" : nil) }
    func shareProgress(_ value: String) { shareStatus = value }
    func waitForShareActivation() async {
        await waitForLifecycle()
        for task in Array(refreshTasks.values) { await task.value }
    }
    func eligibleShareDestination(_ id: String) -> Bool {
        canUse(id) && live.first(where: { $0.info.id == id })?.drop?.canOperate == true
    }
    func stopShareJob(_ job: StagedJob, inbox: ShareInbox, workspaceID: String) async throws {
        guard eligibleShareDestination(workspaceID), let drop = live.first(where: { $0.info.id == workspaceID })?.drop else { throw DropError.suspended }
        try await drop.service.discardShareJob(job, inbox: inbox)
        await drop.refresh()
    }
    func importShareJob(_ job: StagedJob, inbox: ShareInbox, workspaceID: String) async throws {
        guard eligibleShareDestination(workspaceID), let drop = live.first(where: { $0.info.id == workspaceID })?.drop else { throw DropError.suspended }
        let mine = drop.revision
        let objects: [DropObject]
        do { objects = try await drop.service.importShareJob(job, inbox: inbox) }
        catch {
            if mine == drop.revision && drop.workspace?.usable == true { drop.report(error) }
            throw error
        }
        guard drop.canOperate, mine == drop.revision else { throw DropError.suspended }
        for (index, object) in objects.enumerated() {
            drop.aliases[object.descriptor.object.hex] = "share-\(job.manifest.jobID)-\(index)"
        }
        await drop.refresh()
    }

    func shareIdentity(of workspaceID: String) -> (ws: String, generation: Int64)? {
        return live.first { $0.info.id == workspaceID }.map { ($0.workspaceID.hex, $0.generation) }
    }

    func importShared(workspaceID: String, items: [PreviewWorld.SharedItem], expires: Date) {}

    func setQuarantined(_ entries: [(job: String, workspaceID: String, name: String, bytes: Int, kind: DropKind, expires: Date)]) {
        heldDropItems.removeAll { $0.quarantineJob != nil }
        for e in entries {
            heldDropItems.insert(DropItem(id: "share-q-\(e.job)", workspaceID: e.workspaceID, name: e.name, bytes: e.bytes, kind: e.kind,
                                      direction: .sending, expires: e.expires, versions: 1, unread: false, text: nil,
                                      from: "This iPhone", quarantineJob: e.job), at: 0)
        }
    }

    func redirectQuarantined(id: String, to workspaceID: String) {
        guard isLive(workspaceID), let job = dropItems.first(where: { $0.id == id })?.quarantineJob else { return }
        onRedirectQuarantined?(job, workspaceID)
    }

    func markRead(id: String) {
        if let drop = dropState(id), let index = drop.rows.firstIndex(where: { $0.id == id || $0.presentationID == id }) {
            drop.readIDs.insert(drop.rows[index].id); drop.rows[index].unread = false
        }
    }

    // MARK: SettingsModel

    var custody: String { DefaultCustody.isSecureEnclave ? "Secure Enclave" : "Software key (Simulator)" }

    func setNotifications(_ on: Bool, workspaceID: String) {
        guard isLive(workspaceID) else { return }
        live.first { $0.info.id == workspaceID }?.setNotifications(on)
        if on, notificationStatus == .notAsked { requestNotificationPermission() }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.notificationStatus = granted ? .allowed : .denied }
        }
    }

    func demoSendPush(workspaceID: String) {
        guard isLive(workspaceID) else { return }
        guard let ws = live.first(where: { $0.info.id == workspaceID }), let runtime else { return }
        if notificationStatus == .notAsked { requestNotificationPermission() }
        demoPushResult = "Sending…"
        Task {
            let result = await runtime.simulatePush(workspace: ws.workspaceID, name: ws.info.name, generation: ws.generation,
                                                    label: "Demo: a question is waiting")
            switch result?.outcome {
            case .some(let outcome): demoPushResult = "Local notification scheduled (\(outcome))"
            case .none: demoPushResult = "The Demo push could not be sealed."
            }
        }
    }

    /// Leave = "Remove from this iPhone": the real local wipe first and network-independent; server cleanup is reported separately (U9).
    func leave(workspaceID: String, simulateOffline: Bool) async -> LeaveReport {
        guard let ws = live.first(where: { $0.info.id == workspaceID }) else {
            return LeaveReport(workspaceName: "Workspace", server: .finishOnMac, incomplete: true)
        }
        guard let runtime, state(for: workspaceID) != .removing else {
            return LeaveReport(workspaceName: ws.info.name, server: .pendingOffline, incomplete: true)
        }
        transition(workspaceID, to: .removing)
        await ws.drop?.service.invalidate()
        let name = ws.info.name
        // The share outbox journals the removal first; a failed journal keeps the workspace in place.
        guard beforeWorkspaceRemoval?(workspaceID) != false else {
            transition(workspaceID, to: .removalIncomplete)
            await waitForLifecycle()
            await ws.stop()
            return LeaveReport(workspaceName: name, server: .pendingOffline, incomplete: true)
        }
        let canDeregister = ws.info.scopes.contains(.operate)
        await waitForLifecycle()
        await ws.stop()
        let prefix = ws.workspaceID.hex + "/"
        for (key, task) in reconcileTasks where key.hasPrefix(prefix) { task.cancel(); reconcileTasks[key] = nil; reconcileSerials[key] = nil }
        do { try await wipeWorkspace(runtime, ws) }
        catch {
            // Never report success on a failed wipe: the workspace stays listed, stopped and marked "removal incomplete"; Leave again
            // resumes the persisted wipe (LocalWipe.resumePendingWipes). A half-wiped workspace is not restarted.
            transition(workspaceID, to: .removalIncomplete)
            return LeaveReport(workspaceName: name, server: .pendingOffline, incomplete: true)
        }
        transition(workspaceID, to: .removed)
        live.removeAll { $0.info.id == workspaceID }
        heldDropItems.removeAll { $0.workspaceID == workspaceID }
        pendingDecisions.removeAll { $0.workspaceID == workspaceID }
        let server: LeaveServerStatus = !canDeregister ? .finishOnMac : (simulateOffline ? .pendingOffline : .done)
        return LeaveReport(workspaceName: name, server: server)
    }

    /// Wipes the Demo realm through the real reset path and leaves Demo.
    func resetThisiPhone() { teardown(thenDemo: false) }
    func exitDemo() { teardown(thenDemo: false) }
    func resetDemoData() { teardown(thenDemo: true) }

    private func teardown(thenDemo: Bool) {
        resetRevision += 1
        let revision = resetRevision
        let pendingBoot = bootTask
        bootTask = nil
        let old = runtime
        if let old { failedReset = old }
        for ws in live { transition(ws.info.id, to: .removing) }
        let workspaces = live
        runtime = nil; live = []; heldDropItems = []; pendingDecisions = []; submitted = [:]
        reconcileTasks.values.forEach { $0.cancel() }
        reconcileTasks = [:]; reconcileSerials = [:]
        refreshTasks.values.forEach { $0.cancel() }; refreshTasks = [:]
        demoLockRelease?.cancel()
        resetFlags.set(true, forKey: Keys.resetPending)
        isDemo = false
        deviceLabel = thenDemo ? deviceLabel : "iPhone"
        if !options.uiTesting { UserDefaults.standard.set(false, forKey: Keys.demo) }
        let previous = resetTask
        resetTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if let booted = await pendingBoot?.value { self.failedReset = booted }
            await self.waitForLifecycle()
            for ws in workspaces { await ws.drop?.service.invalidate(); await ws.stop() }
            do {
                if let pending = self.failedReset { try await self.resetRuntime(pending) }
                else if !self.options.uiTesting { try await self.finishInterruptedReset() }
                self.failedReset = nil
                for id in self.lifecycle.keys { self.transition(id, to: .removed) }
                self.resetFlags.set(false, forKey: Keys.resetPending)
                self.resetIncomplete = false
                if thenDemo, revision == self.resetRevision { await self.startDemoAfterReset() }
            } catch {
                self.resetIncomplete = true
                for id in self.lifecycle.keys { self.transition(id, to: .removalIncomplete) }
            }
        }
    }

    private func startDemoAfterReset() async {
        resetTask = nil
        _ = await startDemo()
    }
}

/// A review for a workspace that is no longer on this iPhone: it can load nothing.
@MainActor @Observable
final class UnavailableReviewModel: QuestionReviewModel {
    private(set) var load: ReviewLoad = .failed("This workspace is no longer on this iPhone.")
    private(set) var review: ReviewValue?
    private(set) var phase: SignPhase = .invalidated
    func loadReview() async {}
    func sign() async {}
    func reread() async {}
    func checkWhetherReceived() async {}
    func invalidate() {}
    func retryAfterUnlock() {}
}

#if DEBUG
extension LiveServices {
    func demoDropPending() async {
        guard options.uiTesting, let runtime, let drop = live.first(where: { $0.info.scopes.contains(.operate) })?.drop,
              let id = drop.workspace?.info.id else { return }
        for _ in 0..<100 where live.contains(where: { !($0.drop?.verifying.isEmpty ?? true) || $0.drop?.loading == true }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard drop.canOperate else { return }
        runtime.faults.enqueue(.disconnect, at: .afterCommitBeforeResponse, routePrefix: "GET " + HostAPI.base + "/drop/")
        await drop.send(.init(workspaceID: id, attachments: [], note: "Foreground recovery bytes"))
    }
    func demoDropReject() async {
        guard options.uiTesting, let runtime else { return }
        do { try await runtime.env.relay.demoRejectNextDrop() } catch { shareStatus = "Could not arm Demo fault" }
    }
    func demoDropInbox() async {
        guard options.uiTesting, let runtime, let ws = live.first(where: { $0.info.scopes.contains(.operate) }),
              let entry = runtime.entry(for: ws.workspaceID) else { return }
        do {
            try await entry.host.demoInboxDrop(relay: runtime.env.relay, transport: runtime.env.transport, session: entry.session)
            await ws.drop?.refresh()
        } catch { ws.drop?.report(error) }
    }
    func demoDropExpire() {
        guard options.uiTesting else { return }
        setActive(false)
        runtime?.fastForward(seconds: 604801)
        setActive(true)
    }
}
#endif
