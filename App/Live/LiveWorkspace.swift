import Foundation
import Observation
import OrchClient
import OrchCustody
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
        // C2b: whether this workspace takes answers from this iPhone now (a person-event policy and a host that serves them)
        info.writeSupport = await api.writesAvailable()
        info.createSupport = await api.writesAvailable(op: "new_ticket")
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
            questions = []; allTickets = []; macOnlyCount = 0; ticketsIncomplete = false; loaded = false; nextKey = nil
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
        nextKey = s.nextKey
        loaded = true
        offlineSince = nil
        info.connection = .online
        services?.snapshotApplied(self)
    }

    // MARK: New ticket (C2b creation)

    /// The draft: the type and title, and the review id of a signed creation still being settled (the uid lives in `pe_reviews`).
    struct CreationDraft: Codable, Equatable { var type: String, title: String; var review: String? }

    /// The draft lives in the workspace's own directory, so the local wipe removes it with everything else (U9).
    @ObservationIgnored var draftURL: URL?
    /// The realm's write fence: the draft is written inside `performFenced`, so a finished realm cannot write into its successor (L6).
    /// A Live workspace without one cannot save a draft at all.
    @ObservationIgnored var draftFence: (any WriteFence)?
    @ObservationIgnored var requiresDraftFence = false
    /// `workspace.show` -> `next_key` of the last snapshot (nil: this device may not create here).
    var nextKey: String?
    /// The issued creation review behind the sheet's `CreationValue` (the App never builds one).
    @ObservationIgnored private var heldCreation: CreationReview?
    @ObservationIgnored private var creationRevision = 0

    private func loadDraft() -> CreationDraft? {
        guard let url = draftURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CreationDraft.self, from: data)
    }
    private func saveDraft(_ d: CreationDraft) throws {
        guard usable, let url = draftURL,
              FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { throw ViewError.invalidDraft }
        let data = try JSONEncoder().encode(d)
        if let fence = draftFence { try fence.performFenced { try data.write(to: url, options: [.atomic, .completeFileProtection]) } }
        else if requiresDraftFence { throw ViewError.invalidDraft }
        else { try data.write(to: url, options: [.atomic, .completeFileProtection]) }
    }
    private func clearDraft() {
        guard let url = draftURL else { return }
        if let fence = draftFence { try? fence.performFenced { try? FileManager.default.removeItem(at: url) } }
        else { try? FileManager.default.removeItem(at: url) }
    }

    var canCreateTickets: Bool {
        usable && services?.capabilities.writes == true && info.createSupport && info.scopes.contains(.decide) && nextKey != nil
    }

    func loadCreationDraft() -> (type: String, title: String, pending: Bool)? {
        loadDraft().map { ($0.type, $0.title, $0.review != nil) }
    }

    /// The form's inline check of a title: nil when it can be reviewed.
    static func titleProblem(_ title: String) -> String? {
        do {
            let p = try PhoneEvents.prepareText(title, oneLine: true)
            let n = p.value.unicodeScalars.count
            if n == 0 { return "Enter a title." }
            if n > PhoneEvents.maxTitleScalars { return "At most \(PhoneEvents.maxTitleScalars) characters (now \(n))." }
            return nil
        } catch PhoneEvents.Failure.text(let v) {
            switch v.kind {
            case .lineFeedInOneLine: return "The title must be one line."
            case .bidiControl: return "The title has a text-direction control at character \(v.index + 1). Remove it."
            case .control: return "The title has a control character at character \(v.index + 1). Remove it."
            case .unassigned: return "The title has a character this iPhone can't check at character \(v.index + 1). Remove it."
            case .notNFC: return "The title can't be sent as typed."
            }
        } catch { return "The title can't be sent as typed." }
    }

    func reviewCreation(type: String, title: String) async -> CreationReviewResult {
        guard canCreateTickets else { return .failed("This workspace doesn't take new tickets from this iPhone now.") }
        if let problem = Self.titleProblem(title) { return .failed(problem) }
        do { try saveDraft(CreationDraft(type: type, title: title, review: nil)) }
        catch { return .failed("Could not save the ticket draft. Nothing was sent. Try again.") }
        do {
            let r = try await api.reviewCreation(type: type, title: title)
            guard usable else { return .failed("This workspace is unavailable.") }
            heldCreation = r
            creationRevision += 1
            return .reviewed(CreationValue(workspaceName: r.workspaceName, hue: info.hue, ticketType: r.ticketType, title: r.title, owner: r.owner,
                                           nextKey: r.nextKey, uid: r.uid, workspaceID: info.id, revision: creationRevision,
                                           isDemo: services?.isDemo == true))
        } catch where noteKeyAlarm(error) {
            return .failed(Self.keyAlarmMessage)
        } catch ViewError.writesUnavailable {
            return .failed("This workspace doesn't take new tickets from this iPhone now.")
        } catch let f as PhoneEvents.Failure {
            return .failed(f == .badType ? "Choose a ticket type." : (Self.titleProblem(title) ?? "The title can't be sent as typed."))
        } catch {
            return .failed("The workspace could not be read. Nothing was signed.")
        }
    }

    /// Signs exactly the held review behind `value`. The sheet only calls this once armed, after showing the disclosure: the disclosed
    /// key is the review's own.
    func create(_ value: CreationValue) async -> CreationPhase {
        guard canCreateTickets, let held = heldCreation, held.uid == value.uid, value.revision == creationRevision else { return .invalidated }
        heldCreation = nil
        #if DEBUG
        await services?.applyDemoCreationControl(workspace: self)
        #endif
        do {
            let outcome = try await api.create(held, disclosedKey: held.nextKey)
            return await apply(outcome, uid: held.uid)
        } catch CustodyError.locked {
            api.noteCustodyLocked()
            return .unlockToContinue
        } catch let committed as AnswerCommitted {
            // signed and stored: it exists, so it is settled, never "not sent"
            noteKeyAlarm(committed.underlying)
            try? saveDraft(CreationDraft(type: held.ticketType, title: held.title, review: committed.reviewID))
            if let outcome = try? await api.writeOutcome(reviewID: committed.reviewID) { return await apply(outcome, uid: held.uid) }
            return .checking
        } catch ViewError.invalidReview {
            return .invalidated
        } catch where noteKeyAlarm(error) {
            return .notSent(Self.keyAlarmMessage)
        } catch {
            return .notSent("Nothing was signed or stored. Check the connection, then review the ticket again.")
        }
    }

    func checkCreation() async -> CreationPhase {
        guard usable, let draft = loadDraft(), let id = draft.review else { return .notSent("Nothing is being checked.") }
        do { return await apply(try await api.settle(reviewID: id), uid: nil) }
        catch { return .checking }
    }

    private func apply(_ outcome: WriteOutcome, uid: String?) async -> CreationPhase {
        let phase: CreationPhase
        switch outcome {
        case .landed(_, let key): phase = .created(key: key)
        case .landedAfterResign(_, let key): phase = .resentAfterChange(key: key)
        case .landedUnconfirmed: phase = .landedUnconfirmed
        case .ticketExists(let key): phase = .ticketExists(key: key)
        case .refused, .alreadyAnswered: phase = .refused
        case .needsReview(.notSent): phase = .needsReview("It was not sent in time. Review it again to send it.")
        case .needsReview: phase = .needsReview("The workspace changed and the ticket could not be signed again safely. Review it again.")
        case .checking:
            // keep the review id with the draft, so the form shows it as being checked after a relaunch
            if let uid, let id = try? await api.pendingWrites().first(where: { $0.creation?.uid == uid })?.reviewID,
               var d = loadDraft() { d.review = id; try? saveDraft(d) }
            return .checking
        }
        switch phase {
        case .needsReview: if var d = loadDraft() { d.review = nil; try? saveDraft(d) }
        default: clearDraft()
        }
        await refresh()
        return phase
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
