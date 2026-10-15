import Foundation
import OrchCoordination
import OrchShareStaging

/// What the share bridge needs from the workspace world: the preview fake and the live Demo services both conform.
@MainActor
protocol ShareWorld: AnyObject {
    /// `capabilities.share` off: no destinations are published and nothing is imported or uploaded for this realm.
    var capabilities: RealmCapabilities { get }
    /// The realm of this graph ("demo" or "live"), taken from its attached runtime, not from `isDemo`.
    var shareRealm: String { get }
    var workspaces: [WorkspaceInfo] { get }
    var beforeWorkspaceRemoval: ((String) -> Bool)? { get set }
    var onRedirectQuarantined: ((_ jobID: String, _ workspaceID: String) -> Void)? { get set }
    var onRetryShared: (() -> Void)? { get set }
    var onStopShared: (() -> Void)? { get set }
    func stopShareJob(_ job: StagedJob, inbox: ShareInbox, workspaceID: String) async throws
    func waitForShareActivation() async
    func eligibleShareDestination(_ id: String) -> Bool
    func importShareJob(_ job: StagedJob, inbox: ShareInbox, workspaceID: String) async throws
    func shareProgress(_ value: String)
    func importShared(workspaceID: String, items: [PreviewWorld.SharedItem], expires: Date)
    func setQuarantined(_ entries: [(job: String, workspaceID: String, name: String, bytes: Int, kind: DropKind, expires: Date)])
    /// The real workspace id (32 hex) and generation in the realm index; nil for the preview fake, whose ids are mapped.
    func shareIdentity(of workspaceID: String) -> (ws: String, generation: Int64)?
}

/// App side of the share outbox (A10). Publishes the destinations index, claims jobs the share extension staged,
/// awaits the workspace Drop service for durable confirmation and staged plaintext cleanup.
@MainActor
final class ShareBridge {
    static let groupIdentifier = "group.io.severin.orch.share"

    let inbox: ShareInbox
    private let world: any ShareWorld
    /// Demo workspaces are offered (the extension labels the realm) only while Demo is the active realm; claims are realm-checked, so a
    /// Demo-realm job is never imported by a live app. Pass false to withhold them.
    private let publishDemo: Bool
    /// Published destinations by preview workspace id (also the live set used to claim).
    private var published: [String: ShareTarget] = [:]
    /// Retain identities even when scope/lifecycle prevents offering a workspace to the extension.
    private var tracked: [String: ShareTarget] = [:]
    private var listed: Set<String> = []
    private var attempted: Set<String> = []
    private func key(_ job: StagedJob) -> String { "\(job.manifest.realm)/\(job.manifest.ws)/\(job.manifest.generation)/\(job.manifest.jobID)" }
    private var refreshing = false
    private var task: Task<Void, Never>?
    private var failed: [String: StagedJob] = [:]
    func waitForRefresh() async { await task?.value }
    private(set) var lastPurge: (removed: Int, failed: Int) = (0, 0)

    init(area: ShareArea, world: any ShareWorld, publishDemo: Bool = true) {
        inbox = ShareInbox(area: area)
        self.world = world
        self.publishDemo = publishDemo
        world.onRetryShared = { [weak self] in self?.retryFailed() }
        world.onStopShared = { [weak self] in self?.stopFailed() }
        world.beforeWorkspaceRemoval = { [weak self] id in self?.prepareRemoval(id) ?? false }
        world.onRedirectQuarantined = { [weak self] job, ws in self?.redirect(job: job, to: ws) }
    }

    /// nil when the App Group container is unavailable (unit tests, unsigned builds): sharing is simply off.
    static func make(world: any ShareWorld, override root: URL? = nil, publishDemo: Bool = true) -> ShareBridge? {
        guard let root = root ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else { return nil }
        return ShareBridge(area: ShareArea(shareGroupRoot: root), world: world, publishDemo: publishDemo)
    }

    var realm: String { world.shareRealm }

    /// Removals whose tombstone is not yet durable (retried on every publish).
    var unfinishedRemovals: Int { (try? inbox.pendingRemovals().count) ?? 0 }

    /// The preview workspace ids ("laptop") are not 32-hex; the fake maps them to stable valid ids.
    static func wsHex(_ id: String) -> String {
        func fnv(_ seed: UInt64) -> UInt64 {
            var h: UInt64 = 0xcbf29ce484222325 ^ seed
            for b in id.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
            return h
        }
        return String(format: "%016llx%016llx", fnv(0), fnv(0x9e3779b97f4a7c15))
    }

    private func previewID(forHex ws: String) -> String? { published.first { $0.value.ws == ws && listed.contains($0.key) }?.key }

    /// Journal before changing local workspace state; a failed tombstone keeps the workspace in place.
    private func prepareRemoval(_ id: String) -> Bool {
        do {
            let identity = world.shareIdentity(of: id)
            let target = tracked[id] ?? published[id]
            let hex = identity?.ws ?? target?.ws ?? Self.wsHex(id)
            let generation = try identity?.generation ?? target?.generation ?? ((inbox.area.coordination.records()
                .filter { $0.realm == realm && $0.ws == hex }.map(\.generation).max() ?? 0) + 1)
            let record = TombstoneRecord(realm: target?.realm ?? realm, ws: hex, generation: generation)
            try inbox.recordRemoval(record)
            try inbox.area.coordination.write(record)
            return true
        } catch { return false }
    }

    /// Replay the durable journal before offering destinations or claiming plaintext.
    func publishTargets() {
        let area = inbox.area
        let coordination = area.coordination
        do { try inbox.replayRemovals() } catch { ShareTargetIndex.recordPublishSkipped("removal replay: \(ShareTargetIndex.PublishStatus.code(error))", in: area); return }
        let tombstones: [TombstoneRecord]
        do { tombstones = try coordination.records() } catch {
            ShareTargetIndex.recordPublishSkipped("tombstones: \(ShareTargetIndex.PublishStatus.code(error))", in: area); return
        }
        var next: [String: ShareTarget] = [:]
        var nextTracked: [String: ShareTarget] = [:]
        for ws in world.workspaces {
            let identity = world.shareIdentity(of: ws.id)
            let hex = identity?.ws ?? Self.wsHex(ws.id)
            let top = tombstones.filter { $0.realm == realm && $0.ws == hex }.map(\.generation).max() ?? 0
            let target = ShareTarget(realm: realm, ws: hex, name: ws.name, hue: ws.hue, generation: identity?.generation ?? top + 1)
            nextTracked[ws.id] = target
            if world.capabilities.share, realm != "demo" || publishDemo, world.eligibleShareDestination(ws.id) {
                next[ws.id] = target
            }
        }
        // Include the persisted index so a process restart cannot lose an unpublished removal.
        // Every persisted destination, stale or tombstoned too (retiring one twice is idempotent). An unreadable index reads
        // as empty so the publish below repairs it; that can drop an unpublished removal across a restart (docs/gaps.md).
        let persisted = (try? ShareTargetIndex.persisted(from: area)) ?? []
        let previous = Array(published.values) + persisted
        do {
            for old in Set(previous) {
                if old.realm == realm {
                    guard !world.workspaces.contains(where: { (world.shareIdentity(of: $0.id)?.ws ?? Self.wsHex($0.id)) == old.ws }) else { continue }
                } else {
                    // The OTHER realm's entries: a live app retires stale Demo targets (Demo storage is wiped each boot), but Demo
                    // must never tombstone live targets (that would burn their generation and kill the destination for good).
                    guard realm == "live", old.realm == "demo" else { continue }
                }
                try inbox.recordRemoval(TombstoneRecord(realm: old.realm, ws: old.ws, generation: old.generation))
            }
            try inbox.replayRemovals()
        } catch { ShareTargetIndex.recordPublishSkipped("retire: \(ShareTargetIndex.PublishStatus.code(error))", in: area); return }
        tracked = nextTracked
        published = next
        listed = Set(next.keys)
        // While Demo is active the persisted LIVE destinations stay visible (the extension labels Demo ones); imports are realm-checked.
        let kept = realm == "demo" ? persisted.filter { $0.realm == "live" } : []
        // publish records its own outcome (index-status.json) for the on-device diagnostics, so try? loses nothing.
        try? ShareTargetIndex.publish(world.workspaces.compactMap { next[$0.id] } + kept, to: area)
        lastPurge = inbox.purgeTombstoned()
    }

    /// Activation and foreground: publish, janitor, claim, import.
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        task = Task {
            await world.waitForShareActivation()
            await performRefresh()
            refreshing = false
        }
    }

    private func performRefresh() async {
        publishTargets()
        guard let pending = try? inbox.pendingRemovals(), pending.isEmpty,
              (try? inbox.area.coordination.records()) != nil else { return }
        inbox.sweep()
        let live = Set(published.filter { listed.contains($0.key) }.values.map { LiveDestination(realm: $0.realm, ws: $0.ws, generation: $0.generation) })
        // Each job is admitted once per bridge lifetime. Deferred destinations retain startup recovery.
        let deferred = Set(world.workspaces.filter { !world.eligibleShareDestination($0.id) }.map { ws in
            let identity = world.shareIdentity(of: ws.id)
            return LiveDestination(realm: realm, ws: identity?.ws ?? Self.wsHex(ws.id), generation: identity?.generation ?? 1)
        })
        let result = inbox.claim(live: live, realm: realm, includeClaimed: true, deferred: deferred)
        for job in result.claimed where !attempted.contains(key(job)) {
            attempted.insert(key(job))
            await importJob(job)
        }
        showQuarantined()
    }

    private func importJob(_ job: StagedJob) async {
        let m = job.manifest
        guard let wsID = previewID(forHex: m.ws), m.realm == realm,
              world.eligibleShareDestination(wsID) else { attempted.remove(key(job)); return }
        world.shareProgress("Importing / sending / cleanup…")
        do {
            try await world.importShareJob(job, inbox: inbox, workspaceID: wsID)
            guard m.realm == realm, world.eligibleShareDestination(wsID) else { attempted.remove(key(job)); return }
            failed[key(job)] = nil
            world.shareProgress("Share import confirmed; plaintext cleanup complete")
        } catch {
            guard m.realm == realm, world.eligibleShareDestination(wsID) else { attempted.remove(key(job)); return }
            failed[key(job)] = job
            world.shareProgress("Share import failed: retry or stop sending. Already-committed relay content may remain.")
        }
    }

    func retryFailed() {
        guard !refreshing else { return }
        refreshing = true
        task = Task {
            await world.waitForShareActivation()
            for job in Array(failed.values) { await importJob(job) }
            refreshing = false
        }
    }

    func stopFailed() {
        guard !refreshing else { return }
        refreshing = true
        task = Task {
            defer { refreshing = false }
            for job in Array(failed.values) {
                guard let id = previewID(forHex: job.manifest.ws), world.eligibleShareDestination(id) else { continue }
                do {
                    try await world.stopShareJob(job, inbox: inbox, workspaceID: id)
                    failed[key(job)] = nil
                    world.shareProgress("Stopped sending. Already-committed relay content may remain.")
                } catch { world.shareProgress("Share cleanup failed: retry later") }
            }
        }
    }

    private func showQuarantined() {
        let entries = inbox.quarantined().filter { $0.manifest.realm == realm }.map { job -> (job: String, workspaceID: String, name: String, bytes: Int, kind: DropKind, expires: Date) in
            let m = job.manifest
            let first = m.items.first
            let name = m.items.count > 1 ? "\(first?.name ?? "Item") and \(m.items.count - 1) more" : (first?.name ?? "Item")
            return (m.jobID, m.ws, name, m.totalBytes, first?.kind == .file ? .file : (first?.kind == .url ? .url : .note),
                    Date(timeIntervalSince1970: m.createdAt).addingTimeInterval(ShareLimits.sevenDays))
        }
        world.setQuarantined(entries)
    }

    /// The user chose another destination for a quarantined job. Copy-then-delete under the destination's tombstone
    /// lock; if anything fails the quarantined original stays and is shown again.
    func redirect(job: String, to workspaceID: String) {
        guard world.eligibleShareDestination(workspaceID), let target = published[workspaceID], listed.contains(workspaceID),
              let q = inbox.quarantined().first(where: { $0.manifest.jobID == job && $0.manifest.realm == realm }) else { return }
        if let moved = try? inbox.redirect(q, to: LiveDestination(realm: target.realm, ws: target.ws, generation: target.generation)) {
            task = Task { await world.waitForShareActivation(); await importJob(moved); showQuarantined() }
        }
        showQuarantined()
    }
}

extension Notification.Name {
    /// DEBUG fixture only: asks the app to import now.
    static let orchDebugShareRefresh = Notification.Name("io.severin.orch.debug.shareRefresh")
}

#if DEBUG
extension ShareBridge {
    /// UI tests: a ready job staged for a workspace that does not exist, so the next claim quarantines it.
    func seedQuarantinedJobForUITests() {
        let target = ShareTarget(realm: realm, ws: Self.wsHex("removed-workspace"), name: "Removed", hue: 0, generation: 1)
        guard let s = try? StagingSession(area: inbox.area, target: target) else { return }
        try? s.add(.text("kept until you choose a destination"))
        _ = try? s.commit(note: nil)
    }
}
#endif

@MainActor
extension ShareWorld {
    func waitForShareActivation() async {}
    func eligibleShareDestination(_ id: String) -> Bool {
        workspaces.contains { $0.id == id && $0.lifecycle == .live && $0.scopes.contains(.operate) }
    }
    func shareProgress(_ value: String) {}
}

@MainActor
extension PreviewWorld {
    func stopShareJob(_ job: StagedJob, inbox: ShareInbox, workspaceID: String) async throws {
        guard inbox.complete(job) else { throw ShareError.io("cleanup") }
    }
    func importShareJob(_ job: StagedJob, inbox: ShareInbox, workspaceID: String) async throws {
        var items: [PreviewWorld.SharedItem] = []
        for (n, item) in job.manifest.items.enumerated() {
            items.append(.init(id: "share-\(job.manifest.jobID)-\(n)", name: item.name, bytes: item.bytes,
                               kind: item.kind == .file ? .file : (item.kind == .url ? .url : .note),
                               text: inbox.text(of: item, in: job)))
        }
        if let note = job.manifest.note {
            items.append(.init(id: "share-\(job.manifest.jobID)-note", name: "Note", bytes: note.utf8.count, kind: .note, text: note))
        }
        importShared(workspaceID: workspaceID, items: items,
                     expires: Date(timeIntervalSince1970: job.manifest.createdAt + ShareLimits.sevenDays))
        guard inbox.complete(job) else { throw ShareError.io("cleanup") }
    }
}
