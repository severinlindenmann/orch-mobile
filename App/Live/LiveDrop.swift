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
    private(set) var warning = false
    private(set) var unauthorized = false
    private(set) var loading = false
    /// The last list walk did not complete (offline, too large, a page error): cached copies are not shown as current and `open` is
    /// refused until a complete walk succeeds. Nothing is purged on an incomplete walk.
    private(set) var outdated = false
    private(set) var sending = false
    var canOperate: Bool { usable && workspace?.info.scopes.contains(.operate) == true }
    #if DEBUG
    /// Runs before each list walk; a throw stands for an incomplete walk (offline, a page error).
    /// Runs inside `open` right after the download returned (a walk finishing or failing at that point).
    @ObservationIgnored var afterDownload: (() async -> Void)?
    @ObservationIgnored var walkOmits: Set<String> = []
    @ObservationIgnored var listHook: (() async throws -> Void)?
    #endif
    @ObservationIgnored var beforePublication: (() async -> Void)?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    private var notSent = false
    @ObservationIgnored var beforeSealOutcome: (() async -> Void)?
    var stopped: Set<String> = []
    var readIDs: Set<String> = []
    var confirmed: [DropUploadIdentity] = []
    var aliases: [String: String] = [:]
    var verifying: Set<String> = []
    var objects: [String: DropObject] = [:]
    var metadata: [String: DropMetadata] = [:]
    var downloads: [String: DropDownload] = [:]
    var rows: [DropItem] = []
    var failures: [DropUploadFailure] = []
    var previewURL: URL?
    @ObservationIgnored private(set) var alarmCleanup: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    var nowMs: Int64 { workspace?.services?.runtime?.nowMs ?? Int64(Date().timeIntervalSince1970 * 1000) }
    var locked: Bool { workspace?.services?.deviceLocked ?? true }
    var usable: Bool { workspace?.usable == true && !alarm && !unauthorized && !locked }

    init(service: DropService, workspace: LiveWorkspace) {
        self.service = service; self.workspace = workspace
    }
    func cancelUI(clear: Bool) {
        revision += 1; previewURL = nil; expiryTask?.cancel(); sendTask?.cancel()
        if clear { metadata = [:]; downloads = [:]; objects = [:]; rows = []; failures = []; stopped = []; confirmed = []; readIDs = []; aliases = [:]; status = nil }
    }
    func report(_ error: any Error) {
        if error is CancellationError || (error as? DropError) == .suspended { return }
        switch error {
        case SQLiteError.busy, TombstoneError.lockFailed: status = "Busy lock: try again"
        case _ where WorkspaceKeyAlarm(error: error) != nil:
            alarm = true; status = LiveWorkspace.keyAlarmMessage; workspace?.noteKeyAlarm(error)
        case DropError.rollback, DropError.integrity, DropError.malformed, DropStoreError.rollback, Refusal.badSignature, Refusal.malformed, Refusal.conflictingSnapshot,
             Refusal.rotationRequired, Refusal.staleList, Refusal.staleCard, SessionError.pairAgain, SessionError.grantConflict, SessionError.badResponse, is DropDocument.Fork, is CryptoFailure, is CryptoKitError:
            alarm = true; status = "Verification alarm"; metadata = [:]; downloads = [:]; previewURL = nil
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
            #if DEBUG
            try await listHook?()
            #endif
            let received = try await service.listVerifiedRows(.received)
            let sending = try await service.listVerifiedRows(.sending)
            let failed = try await service.failedUploads()
            let confirmations = try await service.confirmedUploads()
            await beforePublication?()
            guard usable, mine == revision, !Task.isCancelled else { return }
            confirmed = confirmations
            outdated = false                       // before the rows are built: they must not carry a stale flag or hide a transcript
            var next: [String: DropObject] = [:]
            var display: [DropItem] = []
            for (direction, values) in [(DropDirection.received, received), (.sending, sending)] {
                for id in values.blocked {
                    display.append(DropItem(id: "\(workspace?.info.id ?? "")-\(id)", workspaceID: workspace?.info.id ?? "", name: "Blocked item", bytes: 0,
                        kind: .file, direction: direction, expires: .distantFuture, versions: 0, unread: false, text: nil,
                        from: "", verified: false, hasSignedExpiry: false, blocked: true))
                }
                for object in values.objects {
                    let id = object.descriptor.object.hex
                    #if DEBUG
                    if walkOmits.contains(id) { continue }          // a complete walk that does not list it (tombstoned, retired, absent)
                    #endif
                    if objects[id]?.descriptor.version != object.descriptor.version {
                        metadata[id] = nil; downloads[id] = nil; previewURL = nil
                    }
                    next[id] = object
                    display.append(row(object, direction: direction))
                }
            }
            objects = next; rows = display; failures = failed
            listRevision += 1
            if let preview = previewURL, downloads.contains(where: { next[$0.key] == nil && $0.value.url == preview }) { previewURL = nil }
            downloads = downloads.filter { next[$0.key] != nil }
            if !received.blocked.isEmpty || !sending.blocked.isEmpty { warning = true }
            // A complete verified walk is the authority on what may stay cached: the cache of every object it did not show live (blocked,
            // tombstoned expired/retired, or absent) goes, per object; the cache of every live object is untouched.
            // A failed purge after a complete walk is a cleanup problem, not an incomplete walk: the list is current, so nothing is marked
            // outdated. Every refresh runs this purge again, which is the retry; until then the status says so.
            var cleanupFailed = false
            do { try await purgeLocal(except: Set(next.keys)) } catch { cleanupFailed = true }
            status = cleanupFailed ? "Local cleanup needs retry" : warning ? "Verification warning: blocked items" : (notSent ? "Not sent" : nil)
        } catch {
            if mine == revision && workspace?.usable == true { markOutdated(error); report(error) }
        }
    }

    /// An incomplete walk purges nothing, but a cached copy is no longer shown as current and cannot be opened.
    private func markOutdated(_ error: any Error) {
        if error is CancellationError || (error as? DropError) == .suspended { return }
        outdated = true; previewURL = nil
        for index in rows.indices where rows[index].verified || rows[index].text != nil {
            rows[index].outdated = true; rows[index].text = nil
        }
    }

    func verifyVisible(_ id: String) async {
        while verifying.count >= 3 || verifying.contains(id) {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard usable else { return }
        }
        guard usable, metadata[id] == nil, let object = objects[id] else { return }
        verifying.insert(id)
        defer { verifying.remove(id) }
        let mine = revision
        do {
            let verifiedMetadata = try await service.metadataVerified(object)
            await beforePublication?()
            guard usable, mine == revision, !Task.isCancelled,
                  objects[id]?.descriptor.version == object.descriptor.version else { return }
            metadata[id] = verifiedMetadata
            if let index = rows.firstIndex(where: { $0.id == id }) {
                rows[index] = row(object, direction: rows[index].direction)
            }
        } catch {
            guard mine == revision, workspace?.usable == true else { return }
            switch error {
            case DropError.integrity, DropError.malformed, DropError.rollback, DropError.unauthorized,
                 is Refusal, is CryptoFailure, is CryptoKitError, is DropDocument.Fork, DropStoreError.rollback:
                warning = true; status = "Verification warning: blocked items"
                objects[id] = nil
                if let index = rows.firstIndex(where: { $0.id == id }) {
                    rows[index].blocked = true; rows[index].verified = false; rows[index].name = "Blocked item"
                    rows[index].text = nil; rows[index].bytes = 0; rows[index].mime = nil
                }
                do { try await purgeLocal(objects: [id]) }
                catch { status = "Verification warning: local cleanup needs retry" }
            default: report(error)
            }
        }
    }

    private func row(_ object: DropObject, direction: DropDirection) -> DropItem {
        let d = object.descriptor, download = outdated ? nil : downloads[d.object.hex]
        let metadata = metadata[d.object.hex] ?? download?.metadata
        let isText = metadata?.name == "note.txt" || (metadata?.mime == "text/plain" && aliases[d.object.hex]?.hasPrefix("share-") == true)
        let kind: DropKind = metadata?.mime == "text/uri-list" ? .url : (isText ? .note : .file)
        let content = (kind == .note || kind == .url) ? download.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) } : nil
        let text = outdated ? nil : content.map { body in metadata?.transcript.map { body + "\n\n" + $0 } ?? body } ?? metadata?.transcript
        let fixtureAlias = d.authorKind == "workspace" ? ["readme.txt": "d-readme", "empty.txt": "d-empty", "note.txt": "d-note",
            "link.txt": "d-url", "deployment.txt": "d-deploy", "Runbook": "d-runbook"][metadata?.name ?? ""] : nil
        return DropItem(id: d.object.hex, workspaceID: workspace?.info.id ?? "",
                        name: metadata?.name ?? "Encrypted item", bytes: Int(metadata?.size ?? 0), kind: kind,
                        direction: direction, expires: d.expiresMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? .distantFuture,
                        versions: Int(d.version), unread: direction == .received && !readIDs.contains(d.object.hex), text: text,
                        from: d.authorID.hex, simulatedDone: confirmed.contains { $0.object == d.object && $0.version == d.version },
                        verified: metadata != nil, alias: aliases[d.object.hex] ?? fixtureAlias, stopped: stopped.contains(d.object.hex), mime: metadata?.mime, hasSignedExpiry: d.expiresMs != nil, outdated: outdated && metadata != nil)
    }
}

extension LiveDrop {
    /// Forgets and deletes the local plaintext of exactly these objects (or of every object but `keep`). The download is a cache, not
    /// evidence: stale plaintext of a retired, expired, blocked or vanished object is the riskier failure, so a complete walk purges it
    /// even on a relay hint. Pending uploads, chain heads and signed descriptors are never touched here.
    func purgeLocal(except keep: Set<String>) async throws {
        let dropped = Set(downloads.keys).union(metadata.keys).subtracting(keep)
        if let preview = previewURL, dropped.contains(where: { downloads[$0]?.url == preview }) { previewURL = nil }
        for id in dropped { downloads[id] = nil; metadata[id] = nil }
        try await service.downloadContainer.purgeDownloads(keeping: keep)
    }

    func purgeLocal(objects ids: Set<String>) async throws {
        guard !ids.isEmpty else { return }
        if let preview = previewURL, ids.contains(where: { downloads[$0]?.url == preview }) { previewURL = nil }
        for id in ids { downloads[id] = nil; metadata[id] = nil }
        try await service.downloadContainer.purgeDownloads(objects: ids)
    }
    func purge() async throws {
        try await service.downloadContainer.purgeExpiredDownloads(nowMs: alarm ? .max : nowMs)
        let expired = downloads.filter { $0.value.deadlineMs <= nowMs }.map(\.key)
        for id in expired {
            metadata[id] = nil; downloads[id] = nil
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
        guard !outdated else { status = "List may be outdated: refresh first"; return }
        let mine = revision
        do {
            try await purge()
            guard usable, mine == revision else { return }
            guard let object = objects[id] else { return }
            let version = object.descriptor.version
            let file = try await service.downloadVerified(object)
            #if DEBUG
            await afterDownload?()
            #endif
            guard usable, mine == revision, file.deadlineMs > nowMs else {
                try? await service.downloadContainer.purgeDownloads(objects: [id])      // the file just written is not shown: it goes
                return
            }
            // A walk may have finished (or failed) while the download was in flight: the file is kept and shown only if the list still
            // shows this object live at the version opened and is not outdated. Otherwise the file just written goes too (this object only).
            guard !outdated, objects[id]?.descriptor.version == version else {
                downloads[id] = nil; metadata[id] = nil; previewURL = nil
                status = outdated ? "List may be outdated: refresh first" : "No longer available"
                do { try await purgeLocal(objects: [id]) } catch { status = "Local cleanup needs retry" }
                return
            }
            downloads[id] = file; metadata[id] = file.metadata
            if let index = rows.firstIndex(where: { $0.id == id }) { rows[index] = row(object, direction: rows[index].direction) }
            let kind = rows.first(where: { $0.id == id })?.kind
            if file.metadata.size > 0, kind != .note, kind != .url { previewURL = file.url }
            expiryTask?.cancel()
            expiryTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    guard let self, self.revision == mine else { return }
                    if self.downloads.values.contains(where: { $0.deadlineMs <= self.nowMs }) {
                        do { try await self.purge() } catch { self.report(error) }
                    }
                    if self.downloads.isEmpty { return }
                }
            }
        } catch { if mine == revision && workspace?.usable == true { report(error) } }
    }
 }

extension LiveDrop {
    func startSend(_ draft: DropDraft) {
        guard sendTask == nil, !sending else { return }
        sendTask = Task { [weak self] in
            guard let self else { return }
            await self.send(draft)
            self.sendTask = nil
        }
    }
    func send(_ draft: DropDraft) async {
        guard canOperate, !sending, draft.attachments.count <= DropLimits.maxAttachments,
              draft.attachments.reduce(0, { $0 + $1.data.count }) <= DropLimits.maxBytes else { return }
        sending = true; notSent = false; status = "Sending…"
        var sealed = false
        let mine = revision
        defer { sending = false }
        do {
            let attachments = draft.attachments.isEmpty
                ? [DropSendAttachment(id: UUID(), data: Data(draft.note.utf8), name: "note.txt", mime: "text/plain")]
                : draft.attachments.map { DropSendAttachment(id: $0.id, data: $0.data, name: $0.name, transcript: draft.note.isEmpty ? nil : draft.note) }
            let outcome: Result<[DropUploadIdentity], any Error>
            do { outcome = .success(try await service.sealSend(UUID(), attachments: attachments)) }
            catch { outcome = .failure(error) }
            await beforeSealOutcome?()
            _ = try outcome.get()
            sealed = true
            if workspace?.info.lifecycle != .removed {
                notSent = false
                if status == "Not sent" { status = "Sending…" }
            }
            guard canOperate, mine == revision else { return }
            for result in try await service.resumeUploads() { _ = try result.result.get() }
            guard canOperate, mine == revision else { return }
            await refresh()
            guard canOperate, mine == revision else { return }
            status = "Sent (confirmed)"
        } catch {
            // Cancellation alone cannot tell whether the atomic seal transaction committed.
            if !sealed, workspace?.info.lifecycle != .removed {
                notSent = true; status = "Not sent"
            }
            guard workspace?.usable == true, mine == revision else { return }
            report(error)
            if !sealed { status = "Not sent" }
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
