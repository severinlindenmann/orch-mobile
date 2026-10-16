import Foundation
import Observation

/// Preview/fake services seeded with the host-api-v0 §4 Demo data. Used for previews and UI tests only;
/// real OrchClient wiring replaces this object behind `AppServices`.
@MainActor @Observable
final class PreviewWorld: AppServices, HomeModel, DropModel, SettingsModel, ShareWorld {
    func shareIdentity(of workspaceID: String) -> (ws: String, generation: Int64)? { nil }
    var isDemo: Bool
    var capabilities: RealmCapabilities = .demo
    var shareRealm: String? { isDemo ? "demo" : "live" }
    var workspaces: [WorkspaceInfo] = []
    var questions: [Question] = []
    var tickets: [Ticket] = []
    var dropItems: [DropItem] = []
    var onRetryShared: (() -> Void)?
    var onStopShared: (() -> Void)?
    var deviceLabel = "Demo iPhone"
    var notificationStatus: NotificationStatus = .allowed
    var pairingScenario: PairingScenario = .firstTime
    var signOutcome: SignOutcome = .accepted
    var pendingWrites: [PendingWrite] = []
    @ObservationIgnored var reconcileTasks: [String: Task<Void, Never>] = [:]
    /// Seconds between background reconcile attempts.
    @ObservationIgnored var reconcileInterval = 5.0
    /// Set by `ShareBridge`: moves a quarantined share job to the chosen workspace.
    @ObservationIgnored var beforeWorkspaceRemoval: ((String) -> Bool)?
    @ObservationIgnored var onRedirectQuarantined: ((_ jobID: String, _ workspaceID: String) -> Void)?
    let custody = "Software key (Simulator)"
    var lastChecked: Date
    let now: Date

    init(demo: Bool, now: Date = Date()) {
        self.isDemo = demo
        self.now = now
        self.lastChecked = now.addingTimeInterval(-120)
        if demo { seed() }
    }

    var home: any HomeModel { self }
    var drop: any DropModel { self }
    var settings: any SettingsModel { self }

    // MARK: Seed (docs/host-api-v0.md §4)

    func enterDemo() {
        isDemo = true
        seed()
    }

    private func seed() {
        workspaces = [
            WorkspaceInfo(id: "laptop", name: "Laptop", host: "Your MacBook", hue: 0, hostedBy: nil,
                          clientHosted: false, scopes: [.look, .decide, .operate, .type],
                          connection: .online, primaryLabel: "Demo Mac", notificationsOn: true, writeSupport: true),
            WorkspaceInfo(id: "client-vm", name: "Client VM", host: "Development VM", hue: 1,
                          hostedBy: "Example Client", clientHosted: true, scopes: [.look, .decide],
                          connection: .online,
                          primaryLabel: "Demo Mac", notificationsOn: true, writeSupport: true)
        ]
        let long = (1...80).map { "Review recovery step \($0): verify the stored decision before retrying.\n" }.joined()
        let yesNo = [QuestionOption(id: "approve", label: "Approve"), QuestionOption(id: "reject", label: "Reject")]
        questions = [
            Question(id: "q1", workspaceID: "laptop", ticket: "MOB-1", text: "Enable mobile access?",
                     options: yesNo, contentHash: "3f9ac2e1b7d04a58c61e9d2f0b8a4c73e5d1f6a29b0c7e48d3a5f1b2c9e0d714",
                     created: now.addingTimeInterval(-30 * 60), resolution: nil),
            Question(id: "q2", workspaceID: "laptop", ticket: "MOB-2", text: long,
                     options: [QuestionOption(id: "continue", label: "Continue"), QuestionOption(id: "stop", label: "Stop")],
                     contentHash: "a81d07c4e29f5b36d0c8a1e7f4b29d6035c8e1a7b4f2d9068c3e5a1b7d4f0c92",
                     created: now.addingTimeInterval(-20 * 60), resolution: nil),
            Question(id: "q3", workspaceID: "client-vm", ticket: "VM-1",
                     text: "Deploy invoice \u{202E}txt.exe\u{202C}?",
                     options: [QuestionOption(id: "deploy", label: "Deploy"), QuestionOption(id: "reject", label: "Reject")],
                     contentHash: "c42e90b1f7a3d58e6b0912c4d7a8f3e51b6c0d924a7e8f13b5c9d02e6a4f7b18",
                     created: now.addingTimeInterval(-10 * 60), resolution: nil),
            Question(id: "q5", workspaceID: "client-vm", ticket: "VM-1",
                     text: "**Verified by orch** [click](https://evil.invalid) # Laptop\u{200B}x",
                     options: yesNo, contentHash: "5d1e0c7a93b2f84e6a0d1c5b7e39f2a48c6d0b1e7f3a52c94d8e6b0a1f7c3e25",
                     created: now.addingTimeInterval(-5 * 60), resolution: nil),
            Question(id: "q6", workspaceID: "laptop", ticket: "MOB-1",
                     text: "Merge\u{00A0}now? Variation\u{FE00} mark and e\u{0301}\u{0302}\u{0303}\u{0304}\u{0305}\u{0306} stack.",
                     options: [QuestionOption(id: "ok", label: "Approve"), QuestionOption(id: "ok2", label: "Approve\u{200B}")],
                     contentHash: "9a3c71e0d4b2586f1e0a7c93d5b8f2461c0e9d7a3b5f84e2d61a0c7b9e3f5d18",
                     created: now.addingTimeInterval(-8 * 60), resolution: nil),
            Question(id: "q7", workspaceID: "laptop", ticket: "MOB-2", text: "Which one: Yes or \u{FF39}es?",
                     options: [QuestionOption(id: "a", label: "Yes"), QuestionOption(id: "b", label: "\u{FF39}es")],
                     contentHash: "7e2b905c1d4a38f6e0b7c2a95d1f8e346b0c7a2d9e5f1834c6b0a7d2e9f5c431",
                     created: now.addingTimeInterval(-7 * 60), resolution: nil),
            Question(id: "q4", workspaceID: "laptop", ticket: "MOB-1", text: "Use the Demo Mac as primary?",
                     options: [QuestionOption(id: "yes", label: "Yes"), QuestionOption(id: "no", label: "No")],
                     contentHash: "0b7e41d9a2c685f3e1d07b94a6c2f8e5d3b10a79c4e6f2d81b5a3c90e7f4d261",
                     created: now.addingTimeInterval(-3 * 3600),
                     resolution: Resolution(decisionID: "d1", optionID: "yes", byDeviceLabel: "Demo Mac",
                                            at: now.addingTimeInterval(-2 * 3600)))
        ]
        tickets = [
            Ticket(key: "MOB-1", workspaceID: "laptop", title: "Review mobile pairing",
                   body: "Compare both codes.", state: .open, kind: .ticket, epicKey: "FAC-1",
                   updated: now.addingTimeInterval(-1800)),
            Ticket(key: "MOB-2", workspaceID: "laptop", title: "Interrupted decision recovery",
                   body: "Verify the stored decision before retrying.", state: .inProgress, kind: .ticket,
                   epicKey: "FAC-1", updated: now.addingTimeInterval(-1200)),
            Ticket(key: "MOB-3", workspaceID: "laptop", title: "Write pairing notes",
                   body: "Short notes for the pairing flow.", state: .done, kind: .ticket, epicKey: "FAC-1",
                   updated: now.addingTimeInterval(-7200)),
            Ticket(key: "FAC-1", workspaceID: "laptop", title: "Factory: mobile readiness",
                   body: "Everything the iPhone needs before the first TestFlight build.", state: .inProgress,
                   kind: .factoryEpic, epicKey: nil, updated: now.addingTimeInterval(-900)),
            Ticket(key: "VM-1", workspaceID: "client-vm", title: "Approve staging deployment",
                   body: "Waiting for your decision on the invoice build.", state: .open, kind: .ticket,
                   epicKey: nil, updated: now.addingTimeInterval(-600))
        ]
        let week = now.addingTimeInterval(7 * 86400)
        dropItems = [
            DropItem(id: "d-readme", workspaceID: "laptop", name: "readme.txt", bytes: 1_240, kind: .file,
                     direction: .received, expires: week, versions: 1, unread: true, text: nil, from: "Demo Mac"),
            DropItem(id: "d-empty", workspaceID: "laptop", name: "empty.txt", bytes: 0, kind: .file,
                     direction: .received, expires: week, versions: 1, unread: false, text: nil, from: "Demo Mac"),
            DropItem(id: "d-note", workspaceID: "laptop", name: "Short note", bytes: 38, kind: .note,
                     direction: .received, expires: week, versions: 1, unread: true,
                     text: "Remember to compare both codes.", from: "Demo Mac"),
            DropItem(id: "d-url", workspaceID: "laptop", name: "Link", bytes: 25, kind: .url,
                     direction: .received, expires: week, versions: 1, unread: false,
                     text: "https://example.invalid/", from: "Demo Mac"),
            DropItem(id: "d-deploy", workspaceID: "client-vm", name: "deployment.txt", bytes: 5_312, kind: .file,
                     direction: .received, expires: week, versions: 1, unread: false, text: nil, from: "Demo Mac"),
            DropItem(id: "d-runbook", workspaceID: "client-vm", name: "Runbook", bytes: 48_200, kind: .file,
                     direction: .received, expires: week, versions: 2, unread: true, text: nil, from: "Demo Mac"),
            DropItem(id: "d-sending", workspaceID: "laptop", name: "photo.jpg", bytes: 2_400_000, kind: .file,
                     direction: .sending, expires: week, versions: 1, unread: false, text: nil, from: "This iPhone")
        ]
    }

    // MARK: HomeModel

    var needsYou: [NeedsYouGroup] {
        workspaces.compactMap { ws in
            let waiting = questions.filter { $0.workspaceID == ws.id && $0.isOpen }.sorted { $0.created < $1.created }
            return waiting.isEmpty ? nil : NeedsYouGroup(workspace: ws, questions: waiting)
        }.sorted { ($0.questions.first?.created ?? .distantFuture) < ($1.questions.first?.created ?? .distantFuture) }
    }

    var needsYouCount: Int { questions.filter(\.isOpen).count }

    var oldestWaiting: (question: Question, workspace: WorkspaceInfo)? {
        guard let q = questions.filter(\.isOpen).min(by: { $0.created < $1.created }),
              let ws = workspaces.first(where: { $0.id == q.workspaceID }) else { return nil }
        return (q, ws)
    }

    func waitingCount(in workspaceID: String) -> Int {
        questions.filter { $0.workspaceID == workspaceID && $0.isOpen }.count
    }

    var dropSummary: DropSummary {
        let unread = dropItems.filter { $0.direction == .received && $0.unread }
        return DropSummary(newCount: unread.count, lastName: unread.last?.name)
    }

    // MARK: AppServices

    func workspace(_ id: String) -> any WorkspaceModel { PreviewWorkspaceModel(world: self, id: id) }

    func review(workspaceID: String, questionID: String, optionID: String) -> any QuestionReviewModel {
        PreviewReviewModel(world: self, questionID: questionID, optionID: optionID)
    }

    func makePairing(start: PairingState?) -> any PairingFlowModel {
        PreviewPairingModel(world: self, start: start)
    }

    func workspaceID(forQuestion id: String) -> String? { questions.first { $0.id == id }?.workspaceID }

    // MARK: DropModel

    func items(_ direction: DropDirection) -> [DropItem] {
        dropItems.filter { $0.direction == direction }
    }

    func item(id: String) -> DropItem? { dropItems.first { $0.id == id } }

    func items(workspace: String) -> [DropItem] { dropItems.filter { $0.workspaceID == workspace } }

    func send(_ draft: DropDraft) {
        let names = draft.attachments.map(\.name)
        let title = names.isEmpty ? "Note" : (names.count == 1 ? names[0] : "\(names.count) files")
        let newID = "d-\(UUID().uuidString.prefix(6))"
        dropItems.insert(DropItem(
            id: newID, workspaceID: draft.workspaceID, name: title,
            bytes: draft.attachments.reduce(0) { $0 + $1.bytes }, kind: names.isEmpty ? .note : .file,
            direction: .sending, expires: now.addingTimeInterval(Double(draft.expiryDays) * 86400),
            versions: 1, unread: false, text: draft.note.isEmpty ? nil : draft.note, from: "This iPhone"), at: 0)
        // Simulated transfer terminates: nothing is actually uploaded.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, let i = self.dropItems.firstIndex(where: { $0.id == newID }) else { return }
            self.dropItems[i].simulatedDone = true
        }
    }

    // MARK: Share import (A10): the phone-local part; real sealing and upload arrive with the Drop slice

    struct SharedItem: Sendable {
        let id: String
        let name: String
        let bytes: Int
        let kind: DropKind
        let text: String?
    }

    /// Adds claimed share items to Sending. Idempotent per item id (a crash between import and cleanup re-claims the job).
    func importShared(workspaceID: String, items: [SharedItem], expires: Date) {
        for item in items where !dropItems.contains(where: { $0.id == item.id }) {
            dropItems.insert(DropItem(id: item.id, workspaceID: workspaceID, name: item.name, bytes: item.bytes, kind: item.kind,
                                      direction: .sending, expires: expires, versions: 1, unread: false, text: item.text,
                                      from: "This iPhone"), at: 0)
            let newID = item.id
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, let i = self.dropItems.firstIndex(where: { $0.id == newID }) else { return }
                self.dropItems[i].simulatedDone = true
            }
        }
    }

    /// Replaces the quarantined entries (shown in Sending until the user chooses another destination).
    func setQuarantined(_ entries: [(job: String, workspaceID: String, name: String, bytes: Int, kind: DropKind, expires: Date)]) {
        dropItems.removeAll { $0.quarantineJob != nil }
        for e in entries {
            dropItems.insert(DropItem(id: "share-q-\(e.job)", workspaceID: e.workspaceID, name: e.name, bytes: e.bytes, kind: e.kind,
                                      direction: .sending, expires: e.expires, versions: 1, unread: false, text: nil,
                                      from: "This iPhone", quarantineJob: e.job), at: 0)
        }
    }

    func redirectQuarantined(id: String, to workspaceID: String) {
        guard let job = dropItems.first(where: { $0.id == id })?.quarantineJob else { return }
        onRedirectQuarantined?(job, workspaceID)
    }

    // MARK: Pending decisions (U8)

    func dropPending(_ id: String) { pendingWrites.removeAll { $0.reviewID == id } }

    /// Applies the stored decision exactly as signed (its own option), never anything re-derived.
    func applyAccepted(_ id: String) {
        guard let d = pendingWrites.first(where: { $0.reviewID == id }) else { return }
        if let i = questions.firstIndex(where: { $0.id == d.questionID }), questions[i].isOpen {
            questions[i].resolution = Resolution(decisionID: id, optionID: d.optionID, byDeviceLabel: deviceLabel, at: Date())
        }
        dropPending(id)
    }

    /// Background reconciliation: bounded retries while the app runs; state stays visible on Home.
    func markUncertain(_ id: String) {
        if let i = pendingWrites.firstIndex(where: { $0.reviewID == id }) { pendingWrites[i].state = .checking }
        reconcileTasks[id]?.cancel()
        reconcileTasks[id] = Task { [weak self] in
            for attempt in 1...3 {
                guard let interval = self?.reconcileInterval else { return }
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard let self, self.pendingWrites.contains(where: { $0.reviewID == id }) else { return }
                // The fake host confirms receipt on the second attempt.
                if attempt >= 2 { self.applyAccepted(id); return }
            }
        }
    }

    func markRead(id: String) {
        if let i = dropItems.firstIndex(where: { $0.id == id }) { dropItems[i].unread = false }
    }

    // MARK: SettingsModel

    var demoPushResult: String? { nil }
    func demoSendPush(workspaceID: String) {}
    func demoSendNotification() async {}
    func refreshNotificationStatus() async {}
    func openNotificationSettings() {}
    var pushDiagnostics: String { "" }
    var pendingServerCleanups: [PendingServerCleanup] { [] }
    func retryServerCleanup() async {}

    func setNotifications(_ on: Bool, workspaceID: String) {
        if let i = workspaces.firstIndex(where: { $0.id == workspaceID }) { workspaces[i].notificationsOn = on }
    }

    func leave(workspaceID: String, simulateOffline: Bool) async -> LeaveReport {
        let ws = workspaces.first { $0.id == workspaceID }
        guard beforeWorkspaceRemoval?(workspaceID) != false else {
            return LeaveReport(workspaceName: ws?.name ?? "Workspace", server: .pendingOffline)
        }
        // Local wipe first and network-independent.
        workspaces.removeAll { $0.id == workspaceID }
        questions.removeAll { $0.workspaceID == workspaceID }
        tickets.removeAll { $0.workspaceID == workspaceID }
        dropItems.removeAll { $0.workspaceID == workspaceID }
        pendingWrites.removeAll { $0.workspaceID == workspaceID }
        let canDeregister = ws?.scopes.contains(.operate) ?? false
        let server: LeaveServerStatus = !canDeregister ? .finishOnMac : (simulateOffline ? .pendingOffline : .done)
        return LeaveReport(workspaceName: ws?.name ?? "Workspace", server: server)
    }

    func resetThisiPhone() {
        workspaces = []; questions = []; tickets = []; dropItems = []; pendingWrites = []
        isDemo = false
        deviceLabel = "iPhone"
    }

    func exitDemo() { resetThisiPhone() }

    /// Test hook for the empty-Demo state.
    func removeAllWorkspaces() { workspaces = []; questions = []; tickets = []; dropItems = []; pendingWrites = [] }

    func resetDemoData() { seed() }
}

@MainActor @Observable
final class PreviewWorkspaceModel: WorkspaceModel {
    private let world: PreviewWorld
    private let id: String
    init(world: PreviewWorld, id: String) { self.world = world; self.id = id }

    var info: WorkspaceInfo {
        world.workspaces.first { $0.id == id } ?? WorkspaceInfo(
            id: id, name: "Removed", host: "", hue: 5, hostedBy: nil, clientHosted: false, scopes: [],
            connection: .online, primaryLabel: "", notificationsOn: false)
    }
    var waiting: [Question] {
        world.questions.filter { $0.workspaceID == id && $0.isOpen }.sorted { $0.created < $1.created }
    }
    var answered: [Question] {
        world.questions.filter { $0.workspaceID == id && !$0.isOpen }
            .sorted { ($0.resolution?.at ?? .distantPast) > ($1.resolution?.at ?? .distantPast) }
    }
    var tickets: [Ticket] {
        world.tickets.filter { $0.workspaceID == id }.sorted { $0.updated > $1.updated }
    }
    func ticket(key: String) -> Ticket? { tickets.first { $0.key == key } }
    func children(of epicKey: String) -> [Ticket] { tickets.filter { $0.epicKey == epicKey } }
    func epicProgress(for epicKey: String) -> EpicProgress {
        let kids = children(of: epicKey)
        return EpicProgress(done: kids.filter { $0.state == .done }.count, total: kids.count)
    }
    func question(id: String) -> Question? { world.questions.first { $0.id == id } }
}

@MainActor @Observable
final class PreviewReviewModel: QuestionReviewModel {
    private let world: PreviewWorld
    private let questionID: String
    private var optionID: String
    private var session: QuestionReviewSession?
    /// Bumped by every invalidation and every new review request; async completions from an older token are dropped.
    private var token = 0
    private(set) var load: ReviewLoad = .loading
    private(set) var review: ReviewValue?
    private(set) var phase: SignPhase = .ready

    init(world: PreviewWorld, questionID: String, optionID: String) {
        self.world = world
        self.questionID = questionID
        self.optionID = optionID
        // U8: reopening an unresolved submission shows exactly what was signed, never re-derived.
        if let pending = world.pendingWrites.first(where: { $0.questionID == questionID }) {
            self.optionID = pending.optionID
            review = pending.review
            load = .loaded
            phase = .checking
        }
    }

    private func issue(revision: Int) {
        guard let q = world.questions.first(where: { $0.id == questionID }) else {
            load = .failed("This question is no longer available."); return
        }
        let ws = world.workspaces.first { $0.id == q.workspaceID }
        session = QuestionReviewSession(identity: UUID(), realm: "demo", workspaceID: q.workspaceID, generation: 1,
                                        question: q, chosenOptionID: optionID, revision: revision)
        review = ReviewValue(
            workspaceID: q.workspaceID, workspaceName: ws?.name ?? "", hue: ws?.hue ?? 5,
            clientHosted: ws?.clientHosted ?? false, hostedBy: ws?.hostedBy,
            questionID: q.id, ticket: q.ticket, text: q.text, optionID: optionID,
            optionLabel: q.options.first { $0.id == optionID }?.label ?? optionID,
            options: q.options, contentHash: q.contentHash, revision: revision, isDemo: world.isDemo)
        load = .loaded
    }

    func loadReview() async {
        guard session == nil, phase == .ready else { return }
        token += 1
        let mine = token
        load = .loading
        try? await Task.sleep(for: .milliseconds(120))
        guard mine == token else { return }
        if world.signOutcome == .loadFails {
            world.signOutcome = .accepted
            load = .failed("The question could not be read from the workspace. Nothing was signed.")
            return
        }
        issue(revision: 0)
    }

    func sign() async {
        guard phase == .ready, let session, let review, review.optionsRefusal == nil else { return }
        phase = .sending
        let mine = token
        let decisionID = "d-\(session.question.id)"
        // Persist before send (U8), with the exact review and option.
        world.pendingWrites.append(PendingWrite(
            reviewID: decisionID, questionID: session.question.id, workspaceID: session.workspaceID,
            optionID: optionID, optionLabel: review.optionLabel, review: review, state: .sending))
        try? await Task.sleep(for: .milliseconds(500))
        // The send is already persisted and in flight; its result is always applied (never dropped as stale).
        _ = mine
        let outcome = world.signOutcome
        world.signOutcome = .accepted   // one-shot
        switch outcome {
        case .accepted, .loadFails:
            world.applyAccepted(decisionID)
            phase = .accepted
        case .alreadyAnswered:
            world.dropPending(decisionID)
            phase = .alreadyAnswered(by: "Demo Mac", at: Date().addingTimeInterval(-90))
        case .questionChanged:
            world.dropPending(decisionID)
            phase = .questionChanged
        case .uncertain, .held:
            world.markUncertain(decisionID)
            phase = .checking
        case .workspaceChanged:
            world.applyAccepted(decisionID)
            phase = .resentAfterChange
        case .locked:
            world.dropPending(decisionID)
            phase = .unlockToContinue
        case .custodyUnavailable:
            world.dropPending(decisionID)
            phase = .custodyUnavailable
        }
    }

    func reread() async {
        guard phase == .questionChanged else { return }
        token += 1
        let mine = token
        phase = .rereading
        try? await Task.sleep(for: .milliseconds(300))
        guard mine == token, phase == .rereading else { return }   // invalidated meanwhile: stay invalidated
        issue(revision: (review?.revision ?? 0) + 1)
        phase = .ready
    }

    func checkWhetherReceived() async {
        guard phase == .checking else { return }
        try? await Task.sleep(for: .milliseconds(600))
        let id = "d-\(questionID)"
        if world.pendingWrites.contains(where: { $0.reviewID == id }) { world.applyAccepted(id) }
        phase = .accepted
    }

    /// Lock/background/content change. Only unsent or unconfirmed-by-user states are dropped; sending and
    /// checking keep going (U8).
    func invalidate() {
        switch phase {
        case .ready, .rereading, .questionChanged, .unlockToContinue, .invalidated:
            token += 1
            session = nil
            phase = .invalidated
        default: break
        }
        if load == .loading { token += 1 }
    }

    func retryAfterUnlock() {
        guard phase == .unlockToContinue else { return }
        token += 1
        issue(revision: (review?.revision ?? 0) + 1)
        phase = .ready
    }
}
