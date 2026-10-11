import Foundation
import CryptoKit
import Observation
import OrchClient
import OrchProtocol
import OrchStore
import OrchCoordination

/// One pairing generation. Cached plaintext metadata never crosses this model's lifetime.
@MainActor @Observable
final class LiveDrop {
    let service: DropService
    weak var workspace: LiveWorkspace?
    private(set) var revision = 0
    private(set) var listRevision = 0
    var status: String?
    private(set) var alarm = false
    private(set) var unauthorized = false
    private(set) var loading = false
    private(set) var sending = false
    var canOperate: Bool { usable && workspace?.info.scopes.contains(.operate) == true }
    @ObservationIgnored var beforePublication: (() async -> Void)?
    private var pendingDraft: DropDraft?
    var stopped: Set<String> = []
    var readIDs: Set<String> = []
    var confirmed: [DropUploadIdentity] = []
    var aliases: [String: String] = [:]
    var verifying: Set<String> = []
    var objects: [String: DropObject] = [:]
    var downloads: [String: DropDownload] = [:]
    var rows: [DropItem] = []
    var failures: [DropUploadFailure] = []
    var previewURL: URL?
    @ObservationIgnored private(set) var alarmCleanup: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    var nowMs: Int64 { workspace?.services?.runtime?.clock.nowMs ?? Int64(Date().timeIntervalSince1970 * 1000) }
    var locked: Bool { workspace?.services?.deviceLocked ?? true }
    var usable: Bool { workspace?.usable == true && !alarm && !unauthorized && !locked }

    init(service: DropService, workspace: LiveWorkspace) {
        self.service = service; self.workspace = workspace
    }
    func cancelUI(clear: Bool) {
        revision += 1; previewURL = nil; expiryTask?.cancel()
        if pendingDraft != nil { status = "Not sent" }
        pendingDraft = nil
        if clear { downloads = [:]; objects = [:]; rows = []; failures = []; pendingDraft = nil; stopped = []; confirmed = []; readIDs = []; aliases = [:]; status = nil }
    }
    func report(_ error: any Error) {
        if error is CancellationError || (error as? DropError) == .suspended { return }
        switch error {
        case SQLiteError.busy, TombstoneError.lockFailed: status = "Busy lock: try again"
        case DropError.rollback, DropError.integrity, DropError.malformed, DropStoreError.rollback, Refusal.badSignature, Refusal.malformed, Refusal.conflictingSnapshot,
             Refusal.staleList, Refusal.staleCard, SessionError.pairAgain, SessionError.grantConflict, SessionError.badResponse, is DropDocument.Fork, is CryptoFailure, is CryptoKitError:
            alarm = true; status = "Verification alarm"; downloads = [:]; previewURL = nil
            for index in rows.indices { rows[index].name = "Blocked item"; rows[index].text = nil; rows[index].bytes = 0; rows[index].mime = nil; rows[index].verified = false }
            alarmCleanup = Task {
                await service.invalidate()
                do { try await service.downloadContainer.purgeExpiredDownloads(nowMs: .max) }
                catch { status = "Verification alarm: local cleanup needs retry" }
            }
        case DropError.unavailableKey, SessionError.noKeyForEpoch, SessionError.epochUnavailable: status = "Key unavailable: retry later"
        case DropError.unauthorized, ClientError.host(.forbiddenScope), ClientError.host(.scopeChanged), ClientError.host(.notMember), ClientError.host(.revoked): unauthorized = true; previewURL = nil; status = "Action unavailable"
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
            try await purge()
            let received = try await service.list(.received)
            let sending = try await service.list(.sending)
            let failed = try await service.failedUploads()
            let confirmations = try await service.confirmedUploads()
            await beforePublication?()
            guard usable, mine == revision, !Task.isCancelled else { return }
            confirmed = confirmations
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
            listRevision += 1
            downloads = downloads.filter { next[$0.key] != nil }
            status = nil
        } catch { if mine == revision && workspace?.usable == true { report(error) } }
    }

    func verifyVisible(_ id: String) async {
        while verifying.count >= 3 || verifying.contains(id) {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard usable else { return }
        }
        guard usable, downloads[id] == nil, let object = objects[id] else { return }
        verifying.insert(id)
        defer { verifying.remove(id) }
        let mine = revision
        do {
            let download = try await service.downloadVerified(object)
            await beforePublication?()
            guard usable, mine == revision, !Task.isCancelled,
                  objects[id]?.descriptor.version == object.descriptor.version else { return }
            downloads[id] = download
            if let index = rows.firstIndex(where: { $0.id == id }) {
                rows[index] = row(object, direction: rows[index].direction)
            }
        } catch { if mine == revision && workspace?.usable == true { report(error) } }
    }

    private func row(_ object: DropObject, direction: DropDirection) -> DropItem {
        let d = object.descriptor, download = downloads[d.object.hex]
        let metadata = download?.metadata
        let isText = metadata?.name == "note.txt" || (metadata?.mime == "text/plain" && aliases[d.object.hex]?.hasPrefix("share-") == true)
        let kind: DropKind = metadata?.mime == "text/uri-list" ? .url : (isText ? .note : .file)
        let content = (kind == .note || kind == .url) ? download.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) } : nil
        let text = content.map { body in metadata?.transcript.map { body + "\n\n" + $0 } ?? body } ?? metadata?.transcript
        let fixtureAlias = d.authorKind == "workspace" ? ["readme.txt": "d-readme", "empty.txt": "d-empty", "note.txt": "d-note",
            "link.txt": "d-url", "deployment.txt": "d-deploy", "Runbook": "d-runbook"][metadata?.name ?? ""] : nil
        return DropItem(id: d.object.hex, workspaceID: workspace?.info.id ?? "",
                        name: metadata?.name ?? "Encrypted item", bytes: Int(metadata?.size ?? 0), kind: kind,
                        direction: direction, expires: d.expiresMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? .distantFuture,
                        versions: Int(d.version), unread: direction == .received && !readIDs.contains(d.object.hex), text: text,
                        from: d.authorID.hex, simulatedDone: confirmed.contains { $0.object == d.object && $0.version == d.version },
                        verified: metadata != nil, alias: aliases[d.object.hex] ?? fixtureAlias, stopped: stopped.contains(d.object.hex), mime: metadata?.mime, hasSignedExpiry: d.expiresMs != nil)
    }
}

 extension LiveDrop {
    func purge() async throws {
        try await service.downloadContainer.purgeExpiredDownloads(nowMs: alarm ? .max : nowMs)
        let expired = downloads.filter { $0.value.deadlineMs <= nowMs }.map(\.key)
        for id in expired {
            downloads[id] = nil
            if let index = rows.firstIndex(where: { $0.id == id }) {
                rows[index].verified = false; rows[index].name = "Encrypted item"; rows[index].text = nil; rows[index].bytes = 0; rows[index].mime = nil; rows[index].alias = nil
            }
        }
        let signedExpired = Set(objects.filter { $0.value.descriptor.expiresMs.map { $0 <= nowMs } ?? false }.map(\.key))
        rows.removeAll { signedExpired.contains($0.id) }
        objects = objects.filter { !signedExpired.contains($0.key) }
        if !expired.isEmpty || !signedExpired.isEmpty { previewURL = nil }
    }
    func foreground() async {
        await alarmCleanup?.value
        do { try await purge() } catch { status = "Local cleanup needs retry" }
        guard usable else { return }
        let mine = revision
        var failure: (any Error)?
        do {
            try await purge()
            let results = try await service.resumeUploads()
            guard usable, mine == revision else { return }
            for result in results { if case .failure(let error) = result.result { report(error); failure = error } }
            let updatedFailures = try await service.failedUploads()
            guard usable, mine == revision else { return }
            failures = updatedFailures
        } catch { if mine == revision && workspace?.usable == true { report(error) } }
        await refresh()
        if let failure, usable, mine == revision { report(failure) }
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
                    guard let self, self.revision == mine, self.previewURL == file.url else { return }
                    if !self.usable || self.nowMs >= file.deadlineMs {
                        self.previewURL = nil
                        if self.usable { do { try await self.purge() } catch { self.report(error) } }
                        return
                    }
                }
            }
        } catch { if mine == revision && workspace?.usable == true { report(error) } }
    }
 }

extension LiveDrop {
    func send(_ draft: DropDraft) async {
        guard canOperate, !sending, draft.attachments.count <= DropLimits.maxAttachments,
              draft.attachments.reduce(0, { $0 + $1.data.count }) <= DropLimits.maxBytes else { return }
        sending = true; pendingDraft = draft; status = "Sending…"
        let mine = revision
        defer { sending = false }
        do {
            let attachments = draft.attachments.isEmpty
                ? [DropSendAttachment(id: UUID(), data: Data(draft.note.utf8), name: "note.txt", mime: "text/plain")]
                : draft.attachments.map { DropSendAttachment(id: $0.id, data: $0.data, name: $0.name, transcript: draft.note.isEmpty ? nil : draft.note) }
            _ = try await service.sealSend(UUID(), attachments: attachments)
            pendingDraft = nil
            guard canOperate, mine == revision else { return }
            for result in try await service.resumeUploads() { _ = try result.result.get() }
            guard canOperate, mine == revision else { return }
            await refresh()
            guard canOperate, mine == revision else { return }
            pendingDraft = nil
            status = "Sent (confirmed)"
        } catch {
            guard workspace?.usable == true, mine == revision else { return }
            let unsealed = pendingDraft != nil
            pendingDraft = nil
            report(error)
            if unsealed { status = "Not sent" }
            // A durable pending identity is recovered by resumeUploads, never a fresh send.
            do {
                let updated = try await service.failedUploads()
                guard usable, mine == revision else { return }
                failures = updated
            } catch { if usable, mine == revision { report(error) } }
        }
    }
    func claim(_ id: String) async {
        guard canOperate, let object = objects[id], object.descriptor.recipients == .inbox else { return }
        let mine = revision
        do {
            try await service.claim(object)
            guard canOperate, mine == revision else { return }
            await refresh(); await verifyVisible(id)
        } catch { if mine == revision && workspace?.usable == true { report(error) } }
    }
    func resolve(_ failure: DropUploadFailure, retry: Bool) async {
        guard canOperate else { return }
        let mine = revision
        do {
            if retry { _ = try await service.retryUpload(object: failure.object, version: failure.version) }
            else { try await service.discardUpload(object: failure.object, version: failure.version) }
            guard canOperate, mine == revision else { return }
            if !retry { stopped.insert(failure.object.hex) }
            guard canOperate, mine == revision else { return }
            await refresh()
            guard canOperate, mine == revision else { return }
            status = retry ? "Sent (confirmed)" : "Stopped sending. Already-committed relay content may remain."
        } catch { if mine == revision && workspace?.usable == true { report(error) } }
    }
}
