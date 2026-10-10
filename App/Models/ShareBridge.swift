import Foundation
import OrchCoordination
import OrchShareStaging

/// App side of the share outbox (A10). Publishes the destinations index, claims jobs the share extension staged,
/// imports them into Drop "Sending" and deletes the staged plaintext. Sealing and upload follow with the real Drop
/// slice; for now the import target is the `PreviewWorld` fake.
@MainActor
final class ShareBridge {
    static let groupIdentifier = "group.io.severin.orch.share"

    let inbox: ShareInbox
    private let world: PreviewWorld
    /// Demo workspaces are never offered to the extension unless a DEBUG UI test asks for it.
    private let publishDemo: Bool
    /// Published destinations by preview workspace id (also the live set used to claim).
    private var published: [String: ShareTarget] = [:]
    private var listed: Set<String> = []
    private var recovered = false
    private var refreshing = false
    private(set) var lastPurge: (removed: Int, failed: Int) = (0, 0)

    init(area: ShareArea, world: PreviewWorld, publishDemo: Bool = false) {
        inbox = ShareInbox(area: area)
        self.world = world
        self.publishDemo = publishDemo
        world.beforeWorkspaceRemoval = { [weak self] id in self?.prepareRemoval(id) ?? false }
        world.onRedirectQuarantined = { [weak self] job, ws in self?.redirect(job: job, to: ws) }
    }

    /// nil when the App Group container is unavailable (unit tests, unsigned builds): sharing is simply off.
    static func make(world: PreviewWorld, override root: URL? = nil, publishDemo: Bool = false) -> ShareBridge? {
        guard let root = root ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else { return nil }
        return ShareBridge(area: ShareArea(shareGroupRoot: root), world: world, publishDemo: publishDemo)
    }

    var realm: String { world.isDemo ? "demo" : "live" }

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
            let hex = Self.wsHex(id)
            let generation = try published[id]?.generation ?? ((inbox.area.coordination.records()
                .filter { $0.realm == realm && $0.ws == hex }.map(\.generation).max() ?? 0) + 1)
            let record = TombstoneRecord(realm: published[id]?.realm ?? realm, ws: hex, generation: generation)
            try inbox.recordRemoval(record)
            try inbox.area.coordination.write(record)
            return true
        } catch { return false }
    }

    /// Replay the durable journal before offering destinations or claiming plaintext.
    func publishTargets() {
        let area = inbox.area
        let coordination = area.coordination
        do { try inbox.replayRemovals() } catch { return }
        guard let tombstones = try? coordination.records() else { return }
        var next: [String: ShareTarget] = [:]
        if !world.isDemo || publishDemo {
            for ws in world.workspaces {
                let hex = Self.wsHex(ws.id)
                let top = tombstones.filter { $0.realm == realm && $0.ws == hex }.map(\.generation).max() ?? 0
                next[ws.id] = ShareTarget(realm: realm, ws: hex, name: ws.name, hue: ws.hue, generation: top + 1)
            }
        }
        // Include the persisted index so a process restart cannot lose an unpublished removal.
        let previous = Array(published.values) + ((try? ShareTargetIndex.load(from: area)) ?? [])
        do {
            for old in Set(previous) where !next.values.contains(where: { $0.realm == old.realm && $0.ws == old.ws }) {
                try inbox.recordRemoval(TombstoneRecord(realm: old.realm, ws: old.ws, generation: old.generation))
            }
            try inbox.replayRemovals()
        } catch { return }
        published = next
        listed = Set(next.keys)
        try? ShareTargetIndex.publish(world.workspaces.compactMap { next[$0.id] }, to: area)
        lastPurge = inbox.purgeTombstoned()
    }

    /// Activation and foreground: publish, janitor, claim, import.
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        publishTargets()
        guard let pending = try? inbox.pendingRemovals(), pending.isEmpty,
              (try? inbox.area.coordination.records()) != nil else { return }
        inbox.sweep()
        let live = Set(published.filter { listed.contains($0.key) }.values.map { LiveDestination(realm: $0.realm, ws: $0.ws, generation: $0.generation) })
        // Only the first pass after launch may re-issue a `.claimed` job (a crashed import); later passes never do.
        let result = inbox.claim(live: live, realm: realm, includeClaimed: !recovered)
        recovered = true
        for job in result.claimed {
            if inbox.wasImported(job.manifest.jobID) { inbox.complete(job); continue }
            guard importJob(job) else { continue }
            inbox.markImported(job.manifest.jobID)
            inbox.complete(job)
        }
        showQuarantined()
    }

    @discardableResult
    private func importJob(_ job: StagedJob) -> Bool {
        let m = job.manifest
        guard let wsID = previewID(forHex: m.ws), m.realm == realm else { return false }
        var items: [PreviewWorld.SharedItem] = []
        for (n, item) in m.items.enumerated() {
            let kind: DropKind = item.kind == .file ? .file : (item.kind == .url ? .url : .note)
            let text = item.kind == .file ? nil : inbox.text(of: item, in: job).map { String($0.prefix(2000)) }
            items.append(.init(id: "share-\(m.jobID)-\(n)", name: item.name, bytes: item.bytes, kind: kind, text: text))
        }
        if let note = m.note { items.append(.init(id: "share-\(m.jobID)-note", name: "Note", bytes: note.utf8.count, kind: .note, text: note)) }
        world.importShared(workspaceID: wsID, items: items, expires: Date(timeIntervalSince1970: m.createdAt).addingTimeInterval(ShareLimits.sevenDays))
        return true
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
        guard let target = published[workspaceID], listed.contains(workspaceID),
              let q = inbox.quarantined().first(where: { $0.manifest.jobID == job && $0.manifest.realm == realm }) else { return }
        if let moved = try? inbox.redirect(q, to: LiveDestination(realm: target.realm, ws: target.ws, generation: target.generation)) {
            if inbox.wasImported(moved.manifest.jobID) { inbox.complete(moved) }
            else if importJob(moved) { inbox.markImported(moved.manifest.jobID); inbox.complete(moved) }
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
