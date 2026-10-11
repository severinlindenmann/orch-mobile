import Foundation
import Observation
import OrchClient
import OrchFakeHost
import OrchProtocol
import OrchPush
import OrchCustody
import UserNotifications

/// The App's real service layer. In Demo it runs the real client stack against the in-process fakes (`DemoRuntime`); a build without a
/// reachable relay has no workspaces at all (pairing says so). Screens see only the view-model protocols (A4): never FakeHost, custody
/// or signing.
@MainActor @Observable
final class LiveServices: AppServices, HomeModel, DropModel, SettingsModel {
    private enum Keys { static let demo = "orch.demo.entered" }

    let options: LaunchOptions
    private(set) var ready = false
    private(set) var isDemo = false
    private(set) var live: [LiveWorkspace] = []
    private(set) var pendingDecisions: [DecisionStatus] = []
    private(set) var lastChecked = Date()
    private(set) var dropItems: [DropItem] = []
    private(set) var demoPushResult: String?
    var deviceLabel = "Demo iPhone"
    var notificationStatus: NotificationStatus = .notAsked
    var pairingScenario: PairingScenario = .firstTime
    var signOutcome: SignOutcome = .accepted
    @ObservationIgnored private(set) var runtime: DemoRuntime?
    @ObservationIgnored private var resetTask: Task<Void, Never>?
    @ObservationIgnored private var bootTask: Task<DemoRuntime?, Never>?
    @ObservationIgnored private var submitted: [String: ReviewValue] = [:]
    @ObservationIgnored private var reconcileTasks: [String: Task<Void, Never>] = [:]

    init(options: LaunchOptions) { self.options = options }

    // MARK: Boot

    func boot() async {
        guard !ready else { return }
        let persisted = !options.uiTesting && UserDefaults.standard.bool(forKey: Keys.demo)
        if options.demo || persisted { _ = await startDemo() }
        if options.demoSeed, isDemo { await seedDemoWorkspaces() }
        ready = true
    }

    @discardableResult
    private func startDemo() async -> DemoRuntime? {
        if let bootTask { return await bootTask.value }
        await resetTask?.value
        if let runtime { return runtime }
        let task = Task { () -> DemoRuntime? in
            do { return try await DemoRuntime.boot(temporaryStorage: self.options.uiTesting) } catch { return nil }
        }
        bootTask = task
        let r = await task.value
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
                try? await Task.sleep(for: .milliseconds(100))
                switch model.state {
                case .comparingHost where !model.demoHostCode.isEmpty: model.hostApprove()
                case .waitingPrimary: model.primaryOpenRequest()
                case .comparingPrimary where model.demoPrimaryHasChallenge: model.primaryApprove()
                case .ready, .refused, .alarm, .expired: done = true
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
        guard let ws = live.first(where: { $0.info.id == workspaceID }) else { return UnavailableReviewModel() }
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
        let entry = runtime?.entry(for: j.workspace)
        entry?.joined = true
        let kind = entry?.kind
        let info = WorkspaceInfo(
            id: j.workspace.hex, name: j.name, host: kind?.hostLabel ?? "Demo Mac", hue: kind.map { $0.rawValue } ?? live.count,
            hostedBy: j.hosted.marker ? (j.hosted.hostedBy ?? "(unknown)") : nil, clientHosted: j.hosted.marker,
            scopes: Mapping.scopes(j.scopes), connection: .online, primaryLabel: "Demo Mac", notificationsOn: true)
        let ws = LiveWorkspace(workspaceID: j.workspace, generation: j.generation, api: BridgeWorkspaceAPI(session: j.session), info: info)
        ws.services = self
        live.append(ws)
        if let kind { dropItems += DemoContent.drop(kind, workspaceID: info.id, now: Date()) }
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
        for ws in live {
            let api = ws.api
            Task {
                await api.setForeground(active)
                if active { await api.refreshViews() }
            }
        }
        if active { Task { await refreshPending(reconcile: true) } }
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
        guard let qid = ID16(hex: questionID) else { return nil }
        return (try? await workspace.api.pendingDecisions())?.first { $0.questionID == qid }?.decisionID
    }

    func refreshPending(reconcile: Bool = false) async {
        var out: [DecisionStatus] = []
        for ws in live {
            // A store error is not an empty list: keep what is shown until the next read succeeds.
            guard let statuses = try? await ws.api.pendingDecisions() else { return }
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
        let key = decisionID.hex
        reconcileTasks[key]?.cancel()
        reconcileTasks[key] = Task { [weak self] in
            for _ in 0..<6 {
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                guard let self else { return }
                if let outcome = try? await workspace.api.reconcile(decisionID: decisionID), outcome != .uncertain {
                    await self.decisionSettled(workspace: workspace)
                    return
                }
            }
        }
        Task { await refreshPending() }
    }

    func decisionSettled(workspace: LiveWorkspace) async {
        await workspace.refresh()
        await refreshPending()
    }

    // MARK: Demo controls (real host behaviour, one shot)

    func applyDemoReadControl(workspace: LiveWorkspace) async {
        guard signOutcome == .loadFails, let host = runtime?.entry(for: workspace.workspaceID)?.host else { return }
        signOutcome = .accepted
        await host.demoFailNextRead()
    }

    func applyDemoSignControl(workspace: LiveWorkspace, questionID: String, optionID: String) async {
        let outcome = signOutcome
        guard outcome != .accepted, outcome != .loadFails, let runtime,
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
            runtime.lock.isLocked = true
        default: break
        }
    }

    func unlockDevice() { runtime?.lock.isLocked = false }

    // MARK: DropModel (simulated: no Drop service yet)

    func items(_ direction: DropDirection) -> [DropItem] { dropItems.filter { $0.direction == direction } }
    func item(id: String) -> DropItem? { dropItems.first { $0.id == id } }
    func items(workspace: String) -> [DropItem] { dropItems.filter { $0.workspaceID == workspace } }

    func send(_ draft: DropDraft) {
        let names = draft.attachments.map(\.name)
        let title = names.isEmpty ? "Note" : (names.count == 1 ? names[0] : "\(names.count) files")
        let newID = "d-\(UUID().uuidString.prefix(6))"
        dropItems.insert(DropItem(
            id: newID, workspaceID: draft.workspaceID, name: title, bytes: draft.attachments.reduce(0) { $0 + $1.bytes },
            kind: names.isEmpty ? .note : .file, direction: .sending, expires: Date().addingTimeInterval(Double(draft.expiryDays) * 86400),
            versions: 1, unread: false, text: draft.note.isEmpty ? nil : draft.note, from: "This iPhone"), at: 0)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, let i = self.dropItems.firstIndex(where: { $0.id == newID }) else { return }
            self.dropItems[i].simulatedDone = true
        }
    }

    func markRead(id: String) {
        if let i = dropItems.firstIndex(where: { $0.id == id }) { dropItems[i].unread = false }
    }

    // MARK: SettingsModel

    var custody: String { DefaultCustody.isSecureEnclave ? "Secure Enclave" : "Software key (Simulator)" }

    func setNotifications(_ on: Bool, workspaceID: String) {
        live.first { $0.info.id == workspaceID }?.setNotifications(on)
        if on, notificationStatus == .notAsked { requestNotificationPermission() }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.notificationStatus = granted ? .allowed : .denied }
        }
    }

    func demoSendPush(workspaceID: String) {
        guard let ws = live.first(where: { $0.info.id == workspaceID }), let runtime else { return }
        if notificationStatus == .notAsked { requestNotificationPermission() }
        demoPushResult = "Sending…"
        Task {
            let result = await runtime.simulatePush(workspace: ws.workspaceID, name: ws.info.name, generation: ws.generation,
                                                    label: "Demo: a question is waiting", scheduler: UNUserNotificationScheduler())
            switch result?.outcome {
            case .some(let outcome): demoPushResult = "Local notification scheduled (\(outcome))"
            case .none: demoPushResult = "The Demo push could not be sealed."
            }
        }
    }

    /// Leave = "Remove from this iPhone": the real local wipe first and network-independent; server cleanup is reported separately (U9).
    func leave(workspaceID: String, simulateOffline: Bool) async -> LeaveReport {
        guard let ws = live.first(where: { $0.info.id == workspaceID }) else {
            return LeaveReport(workspaceName: "Workspace", server: .finishOnMac)
        }
        let name = ws.info.name
        let canDeregister = ws.info.scopes.contains(.operate)
        await ws.stop()
        reconcileTasks.values.forEach { $0.cancel() }
        do { try await runtime?.wipe(workspace: ws.workspaceID, generation: ws.generation) } catch {}
        live.removeAll { $0.info.id == workspaceID }
        dropItems.removeAll { $0.workspaceID == workspaceID }
        pendingDecisions.removeAll { $0.workspaceID == workspaceID }
        let server: LeaveServerStatus = !canDeregister ? .finishOnMac : (simulateOffline ? .pendingOffline : .done)
        return LeaveReport(workspaceName: name, server: server)
    }

    /// Wipes the Demo realm through the real reset path and leaves Demo.
    func resetThisiPhone() { teardown(thenDemo: false) }
    func exitDemo() { teardown(thenDemo: false) }
    func resetDemoData() { teardown(thenDemo: true) }

    private func teardown(thenDemo: Bool) {
        let old = runtime
        let workspaces = live
        runtime = nil; live = []; dropItems = []; pendingDecisions = []; submitted = [:]
        isDemo = false
        deviceLabel = thenDemo ? deviceLabel : "iPhone"
        if !options.uiTesting { UserDefaults.standard.set(false, forKey: Keys.demo) }
        let previous = resetTask
        resetTask = Task { [weak self] in
            await previous?.value
            for ws in workspaces { await ws.stop() }
            try? await old?.reset()
            if thenDemo { await self?.startDemoAfterReset() }
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
