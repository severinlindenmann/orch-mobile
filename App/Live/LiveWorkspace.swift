import Foundation
import Observation
import OrchClient
import OrchProtocol
import OrchStore

/// One joined `(realm, workspace, generation)`: the verified identity from the join, plus what the workspace API reads. The screens get
/// only this display model; the session behind `BridgeWorkspaceAPI` is never reachable from here (host-api section 1).
@MainActor @Observable
final class LiveWorkspace: WorkspaceModel {
    var drop: LiveDrop?
    /// Relay push registration and key material for this workspace (Live with the push capability only; nil in Demo).
    @ObservationIgnored var push: (any PushRegistering)?
    var downloadContainer: WorkspaceContainer?
    let workspaceID: ID16
    let generation: Int64
    @ObservationIgnored let api: any WorkspaceAPI
    private var storedInfo: WorkspaceInfo
    var info: WorkspaceInfo {
        get { var value = storedInfo; value.lifecycle = services?.state(for: value.id) ?? .removed; return value }
        set { storedInfo = newValue }
    }
    var usable: Bool { services?.canUse(storedInfo.id) == true }
    private(set) var questions: [Question] = []
    private(set) var allTickets: [Ticket] = []
    private(set) var loaded = false
    private(set) var macOnlyCount = 0
    private(set) var ticketsIncomplete = false
    @ObservationIgnored weak var services: LiveServices?
    @ObservationIgnored private(set) var eventTask: Task<Void, Never>?
    @ObservationIgnored private var eventRevision = 0
    @ObservationIgnored private var offlineSince: Date?

    init(workspaceID: ID16, generation: Int64, api: any WorkspaceAPI, info: WorkspaceInfo) {
        self.workspaceID = workspaceID; self.generation = generation; self.api = api; self.storedInfo = info
    }

    // MARK: Lifecycle

    func start() {
        guard usable, eventTask == nil else { return }
        eventRevision += 1
        let revision = eventRevision
        eventTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.eventRevision == revision { self.eventTask = nil } }
            // Subscribe first so the replayed cached snapshot and later events are not missed.
            let stream = await self.api.events()
            guard self.usable, !Task.isCancelled else { return }
            await self.api.start()
            await self.checkKeyAlarm()
            await self.refresh()
            for await event in stream {
                if Task.isCancelled { break }
                self.handle(event)
            }
        }
    }

    /// Ends this generation's consumers; the models of a removed workspace are discarded by the caller. Non-throwing and write-free, so it
    /// is unaffected by a realm fence that already refuses the container's writes (as is `DropService.invalidate`).
    func stop() async {
        eventRevision += 1
        eventTask?.cancel(); eventTask = nil
        await api.setForeground(false)
    }

    func setNotifications(_ on: Bool) { info.notificationsOn = on }

    func refresh() async {
        guard usable else { return }
        do {
            let snapshot = try await api.snapshot()
            guard usable else { return }
            apply(snapshot)
            await checkKeyAlarm()
        } catch {
            noteKeyAlarm(error)
            markOffline()
        }
    }

    // MARK: Key alarm (Q10)

    static let keyAlarmMessage = "Key alarm: this workspace published two different keys for the same version, so orch has stopped sending to it. It clears when your Mac issues a new key. If it stays, remove the workspace and pair again."

    /// Reads the alarm (at launch and after every snapshot). It is per epoch (G2b D2): a verified list at a higher epoch lifts it,
    /// and then it is cleared here.
    func checkKeyAlarm() async {
        info.keyAlarm = await api.keyAlarm() != nil ? Self.keyAlarmMessage : nil
    }

    /// Any workspace call that failed on a key alarm (`wk_commit_conflict`, `wkCommitMismatch`) shows it instead of "try again".
    @discardableResult
    func noteKeyAlarm(_ error: any Error) -> Bool {
        // H12d-3: a sealed reader refusal (no declaration, reader too old, an invalid or unknown declaration) is not "try again": the person
        // updates orch or pairs again, and the cached view is not shown as current
        if case ClientError.host(.reader) = error { info.keyAlarm = ReaderGate.updateMessage; return true }
        guard WorkspaceKeyAlarm(error: error) != nil else { return false }
        info.keyAlarm = Self.keyAlarmMessage
        return true
    }

    private func handle(_ event: WorkspaceEvent) {
        guard usable else { return }
        switch event {
        case .snapshot(let s): apply(s)
        case .connection(let c):
            switch c {
            case .online: offlineSince = nil; info.connection = .online
            case .offline: markOffline()
            case .reconciling: info.connection = .reconciling
            }
        case .readerRefused:
            // a sealed reader refusal: nothing cached is shown as current; the person updates orch or pairs again
            questions = []; allTickets = []; macOnlyCount = 0; ticketsIncomplete = false; loaded = false
            info.keyAlarm = ReaderGate.updateMessage
            markOffline()
        case .invalidated: break          // the session re-reads on its own (foreground, with a subscriber)
        case .removed: services?.workspaceRemoved(self)
        }
    }

    private func markOffline() {
        let since = offlineSince ?? Date()
        offlineSince = since
        info.connection = .offline(since: since)
    }

    private func apply(_ s: WorkspaceSnapshot) {
        questions = s.questions.map { Mapping.question($0, workspaceID: info.id) }
        allTickets = s.tickets.map { Mapping.ticket($0, workspaceID: info.id) }
        macOnlyCount = s.macOnlyCount; ticketsIncomplete = s.ticketsIncomplete
        loaded = true
        offlineSince = nil
        info.connection = .online
        services?.snapshotApplied(self)
    }

    // MARK: New ticket

    private struct Draft: Codable, Equatable { var title: String, body: String, id: String }

    /// The draft lives in the workspace's own directory, so the local wipe removes it with everything else (U9).
    @ObservationIgnored var draftURL: URL?
    /// The realm's write fence: the draft is written inside `performFenced`, so a finished realm cannot write into its successor (L6).
    /// A Live workspace without one cannot save a draft at all.
    @ObservationIgnored var draftFence: (any WriteFence)?
    @ObservationIgnored var requiresDraftFence = false

    private func loadDraft() -> Draft? {
        guard let url = draftURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Draft.self, from: data)
    }
    private func saveDraft(_ d: Draft) throws {
        guard canCreateTickets, let url = draftURL,
              FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { throw ViewError.invalidDraft }
        let data = try JSONEncoder().encode(d)
        if let fence = draftFence { try fence.performFenced { try data.write(to: url, options: [.atomic, .completeFileProtection]) } }
        else if requiresDraftFence { throw ViewError.invalidDraft }
        else { try data.write(to: url, options: [.atomic, .completeFileProtection]) }
    }

    var canCreateTickets: Bool { usable && services?.capabilities.writes == true && info.scopes.contains(.operate) }

    /// The creation ID is persisted with the exact draft; the same fields reuse it, an edit gets a new one, success clears it.
    func createTicket(title: String, body: String) async -> TicketCreation {
        guard canCreateTickets else { return .failed("This workspace is unavailable.") }
        let saved = loadDraft()
        let draft = (saved?.title == title && saved?.body == body ? saved : nil)
            ?? Draft(title: title, body: body, id: SystemEntropy().id16().hex)
        do { try saveDraft(draft) } catch { return .failed("Could not save the ticket draft. Nothing was sent. Try again.") }
        guard let id = ID16(hex: draft.id) else { return .failed("Could not prepare the ticket.") }
        do {
            let ticket = try await api.newTicket(NewTicketSubmission(creationID: id, title: title, body: body, epicKey: nil))
            if let url = draftURL { try? FileManager.default.removeItem(at: url) }
            await refresh()
            return .created(key: ticket.key)
        } catch ViewError.invalidDraft {
            return .failed("The title or text has characters that cannot be sent. Remove them and try again.")
        } catch where noteKeyAlarm(error) {
            return .failed(Self.keyAlarmMessage)
        } catch {
            return .failed("The ticket was not confirmed. Try again; it will not be created twice.")
        }
    }

    // MARK: WorkspaceModel

    var waiting: [Question] { guard usable else { return [] }; return questions.filter(\.isOpen).sorted { $0.created < $1.created } }
    var answered: [Question] {
        questions.filter { !$0.isOpen }.sorted { ($0.resolution?.at ?? .distantPast) > ($1.resolution?.at ?? .distantPast) }
    }
    var tickets: [Ticket] { allTickets.sorted { $0.updated > $1.updated } }
    func ticket(key: String) -> Ticket? { allTickets.first { $0.key == key } }
    func children(of epicKey: String) -> [Ticket] { allTickets.filter { $0.epicKey == epicKey } }
    func epicProgress(for epicKey: String) -> EpicProgress {
        let kids = children(of: epicKey)
        return EpicProgress(done: kids.filter { $0.state == .done }.count, total: kids.count)
    }
    func question(id: String) -> Question? { questions.first { $0.id == id } }
}

/// What a screen gets for a workspace that is no longer on this iPhone.
@MainActor @Observable
final class RemovedWorkspaceModel: WorkspaceModel {
    let info: WorkspaceInfo
    init(id: String) {
        info = WorkspaceInfo(id: id, name: "Removed", host: "", hue: 5, hostedBy: nil, clientHosted: false, scopes: [],
                             connection: .online, primaryLabel: "", lifecycle: .removed, notificationsOn: false)
    }
    var waiting: [Question] { [] }
    var answered: [Question] { [] }
    var tickets: [Ticket] { [] }
    func ticket(key: String) -> Ticket? { nil }
    func epicProgress(for epicKey: String) -> EpicProgress { EpicProgress(done: 0, total: 0) }
    func children(of epicKey: String) -> [Ticket] { [] }
    func question(id: String) -> Question? { nil }
}
