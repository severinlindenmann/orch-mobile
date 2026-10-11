import Foundation
import Observation
import OrchClient
import OrchProtocol
import OrchStore
import OrchCoordination

/// One pairing generation. Cached plaintext metadata never crosses this model's lifetime.
@MainActor @Observable
final class LiveDrop {
    let service: DropService
    unowned let workspace: LiveWorkspace
    private(set) var revision = 0
    var status: String?
    private(set) var alarm = false
    private(set) var loading = false
    private(set) var sending = false
    var canOperate: Bool { usable && workspace.info.scopes.contains(.operate) }
    var verifying: Set<String> = []
    var objects: [String: DropObject] = [:]
    var downloads: [String: DropDownload] = [:]
    var rows: [DropItem] = []
    var failures: [DropUploadFailure] = []
    var previewURL: URL?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    var nowMs: Int64 { workspace.services?.runtime?.clock.nowMs ?? Int64(Date().timeIntervalSince1970 * 1000) }
    var locked: Bool { workspace.services?.deviceLocked ?? true }
    var usable: Bool { workspace.usable && !alarm && !locked }

    init(service: DropService, workspace: LiveWorkspace) {
        self.service = service; self.workspace = workspace
    }
    func cancelUI(clear: Bool) {
        revision += 1; previewURL = nil; expiryTask?.cancel()
        if clear { downloads = [:]; objects = [:]; rows = [] }
    }
    func report(_ error: any Error) {
        if error is CancellationError || (error as? DropError) == .suspended { return }
        switch error {
        case SQLiteError.busy, TombstoneError.lockFailed: status = "Busy lock: try again"
        case DropError.rollback, DropError.integrity, DropStoreError.rollback, is CryptoFailure:
            alarm = true; status = "Verification alarm"; downloads = [:]; previewURL = nil
        case DropError.unavailableKey: status = "Key unavailable: retry later"
        case DropError.unauthorized: status = "Action unavailable"
        default: status = "Unavailable: retry later"
        }
    }
}

extension LiveDrop {
    func refresh() async {
        guard usable, !loading else { return }
        loading = true
        let mine = revision
        defer { loading = false }
        do {
            let received = try await service.list(.received)
            let sending = try await service.list(.sending)
            let failed = try await service.failedUploads()
            guard usable, mine == revision, !Task.isCancelled else { return }
            var next: [String: DropObject] = [:]
            var display: [DropItem] = []
            for (direction, values) in [(DropDirection.received, received), (.sending, sending)] {
                for object in values {
                    let id = object.descriptor.object.hex
                    if objects[id]?.descriptor.version != object.descriptor.version {
                        downloads[id] = nil; previewURL = nil
                    }
                    next[id] = object
                    display.append(row(object, direction: direction))
                }
            }
            objects = next; rows = display; failures = failed
            downloads = downloads.filter { next[$0.key] != nil }
            status = nil
        } catch { if mine == revision && workspace.usable { report(error) } }
    }

    func verifyVisible(_ id: String) async {
        while verifying.count >= 3 {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard usable else { return }
        }
        guard usable, downloads[id] == nil, let object = objects[id],
              !verifying.contains(id) else { return }
        verifying.insert(id)
        defer { verifying.remove(id) }
        let mine = revision
        do {
            let download = try await service.downloadVerified(object)
            guard usable, mine == revision, !Task.isCancelled,
                  objects[id]?.descriptor.version == object.descriptor.version else { return }
            downloads[id] = download
            if let index = rows.firstIndex(where: { $0.id == id }) {
                rows[index] = row(object, direction: rows[index].direction)
            }
        } catch { if mine == revision && workspace.usable { report(error) } }
    }

    private func row(_ object: DropObject, direction: DropDirection) -> DropItem {
        let d = object.descriptor, download = downloads[d.object.hex]
        let metadata = download?.metadata
        let kind: DropKind = metadata?.mime == "text/uri-list" ? .url : (metadata?.name == "note.txt" ? .note : .file)
        let text = metadata?.transcript ?? ((kind == .note || kind == .url) ? download.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) } : nil)
        return DropItem(id: d.object.hex, workspaceID: workspace.info.id,
                        name: metadata?.name ?? "Encrypted item", bytes: Int(metadata?.size ?? 0), kind: kind,
                        direction: direction, expires: Date(timeIntervalSince1970: Double(d.expiresMs ?? Int64.max) / 1000),
                        versions: Int(d.version), unread: direction == .received, text: text,
                        from: d.authorID.hex, simulatedDone: direction == .sending,
                        verified: metadata != nil)
    }
}

 extension LiveDrop {
    func purge() async throws {
        try await service.purgeExpiredDownloads()
        let expired = downloads.filter { $0.value.deadlineMs <= nowMs }.map(\.key)
        for id in expired { downloads[id] = nil }
        if !expired.isEmpty { previewURL = nil }
    }
    func foreground() async {
        guard usable else { return }
        let mine = revision
        do {
            try await purge()
            let results = try await service.resumeUploads()
            guard usable, mine == revision else { return }
            for result in results { if case .failure(let error) = result.result { report(error) } }
            failures = try await service.failedUploads()
        } catch { if mine == revision && workspace.usable { report(error) } }
        await refresh()
    }
    func open(_ id: String) async {
        guard usable else { return }
        let mine = revision
        do {
            try await purge()
            guard usable, mine == revision else { return }
            await verifyVisible(id)
            guard usable, mine == revision, let file = downloads[id], file.deadlineMs > nowMs else { return }
            guard file.metadata.size > 0 else { return }
            previewURL = file.url
            expiryTask?.cancel()
            expiryTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    guard let self, self.revision == mine else { return }
                    if !self.usable || self.nowMs >= file.deadlineMs {
                        self.previewURL = nil
                        if self.usable { do { try await self.purge() } catch { self.report(error) } }
                        return
                    }
                }
            }
        } catch { if mine == revision && workspace.usable { report(error) } }
    }
 }

extension LiveDrop {
    func send(_ draft: DropDraft) async {
        guard canOperate, !sending, draft.attachments.count <= DropLimits.maxAttachments,
              draft.attachments.reduce(0, { $0 + $1.data.count }) <= DropLimits.maxBytes else { return }
        sending = true; status = "Sending…"
        let mine = revision
        defer { sending = false }
        do {
            if draft.attachments.isEmpty {
                _ = try await service.send(Data(draft.note.utf8), name: "note.txt", mime: "text/plain")
            } else {
                for attachment in draft.attachments {
                    guard canOperate, mine == revision else { return }
                    _ = try await service.send(attachment.data, name: attachment.name,
                                               transcript: draft.note.isEmpty ? nil : draft.note)
                }
            }
            guard canOperate, mine == revision else { return }
            await refresh()
            status = "Sent (confirmed)"
        } catch {
            guard workspace.usable, mine == revision else { return }
            report(error)
            // A durable pending identity is recovered by resumeUploads, never a fresh send.
            do { failures = try await service.failedUploads() } catch { report(error) }
        }
    }
    func claim(_ id: String) async {
        guard canOperate, let object = objects[id], object.descriptor.recipients == .inbox else { return }
        let mine = revision
        do {
            try await service.claim(object)
            guard canOperate, mine == revision else { return }
            await refresh(); await verifyVisible(id)
        } catch { if mine == revision && workspace.usable { report(error) } }
    }
    func resolve(_ failure: DropUploadFailure, retry: Bool) async {
        guard canOperate else { return }
        let mine = revision
        do {
            if retry { _ = try await service.retryUpload(object: failure.object, version: failure.version) }
            else { try await service.discardUpload(object: failure.object, version: failure.version) }
            guard canOperate, mine == revision else { return }
            await refresh()
            status = retry ? "Sent (confirmed)" : "Stopped sending. Already-committed relay content may remain."
        } catch { if mine == revision && workspace.usable { report(error) } }
    }
}
