import Foundation
import Observation
import OrchClient
import OrchProtocol

/// One joined `(realm, workspace, generation)`: the verified identity from the join, plus what the workspace API reads. The screens get
/// only this display model; the session behind `BridgeWorkspaceAPI` is never reachable from here (host-api section 1).
@MainActor @Observable
final class LiveWorkspace: WorkspaceModel {
    let workspaceID: ID16
    let generation: Int64
    @ObservationIgnored let api: BridgeWorkspaceAPI
    private(set) var info: WorkspaceInfo
    private(set) var questions: [Question] = []
    private(set) var allTickets: [Ticket] = []
    private(set) var loaded = false
    @ObservationIgnored weak var services: LiveServices?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var offlineSince: Date?

    init(workspaceID: ID16, generation: Int64, api: BridgeWorkspaceAPI, info: WorkspaceInfo) {
        self.workspaceID = workspaceID; self.generation = generation; self.api = api; self.info = info
    }

    // MARK: Lifecycle

    func start() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self] in
            guard let self else { return }
            await self.api.start()
            await self.refresh()
            let stream = await self.api.events()
            for await event in stream {
                if Task.isCancelled { break }
                self.handle(event)
            }
        }
    }

    /// Ends this generation's consumers; the models of a removed workspace are discarded by the caller.
    func stop() async {
        eventTask?.cancel(); eventTask = nil
        await api.setForeground(false)
    }

    func setNotifications(_ on: Bool) { info.notificationsOn = on }

    func refresh() async {
        do {
            let snapshot = try await api.snapshot()
            apply(snapshot)
        } catch {
            markOffline()
        }
    }

    private func handle(_ event: WorkspaceEvent) {
        switch event {
        case .snapshot(let s): apply(s)
        case .connection(let c):
            switch c {
            case .online: offlineSince = nil; info.connection = .online
            case .offline: markOffline()
            case .reconciling: info.connection = .reconciling
            }
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
        loaded = true
        offlineSince = nil
        info.connection = .online
        services?.snapshotApplied(self)
    }

    // MARK: New ticket

    private struct Draft: Codable, Equatable { var title: String, body: String, id: String }

    private var draftKey: String { "orch.ticket.draft." + workspaceID.hex }

    var canCreateTickets: Bool { info.scopes.contains(.operate) }

    /// The creation ID is persisted with the exact draft; the same fields reuse it, an edit gets a new one, success clears it.
    func createTicket(title: String, body: String) async -> TicketCreation {
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: draftKey).flatMap { try? JSONDecoder().decode(Draft.self, from: $0) }
        let draft = (saved?.title == title && saved?.body == body ? saved : nil)
            ?? Draft(title: title, body: body, id: SystemEntropy().id16().hex)
        if let data = try? JSONEncoder().encode(draft) { defaults.set(data, forKey: draftKey) }
        guard let id = ID16(hex: draft.id) else { return .failed("Could not prepare the ticket.") }
        do {
            let ticket = try await api.newTicket(NewTicketSubmission(creationID: id, title: title, body: body, epicKey: nil))
            defaults.removeObject(forKey: draftKey)
            await refresh()
            return .created(key: ticket.key)
        } catch ViewError.invalidDraft {
            return .failed("The title or text has characters that cannot be sent. Remove them and try again.")
        } catch {
            return .failed("The ticket was not confirmed. Try again; it will not be created twice.")
        }
    }

    // MARK: WorkspaceModel

    var waiting: [Question] { questions.filter(\.isOpen).sorted { $0.created < $1.created } }
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
                             connection: .online, primaryLabel: "", notificationsOn: false)
    }
    var waiting: [Question] { [] }
    var answered: [Question] { [] }
    var tickets: [Ticket] { [] }
    func ticket(key: String) -> Ticket? { nil }
    func epicProgress(for epicKey: String) -> EpicProgress { EpicProgress(done: 0, total: 0) }
    func children(of epicKey: String) -> [Ticket] { [] }
    func question(id: String) -> Question? { nil }
}
