import CryptoKit
import Foundation
import OrchCustody
import OrchProtocol
import OrchShareStaging
import OrchStore

public enum DropError: Error, Equatable, Sendable {
    case suspended, malformed, unauthorized, expired, integrity, rollback, conflict, tooLarge, unavailableKey, abandoned
    case uploadRejected(status: Int)
    case versionConflict(current: UInt32)

    fileprivate var terminalUpload: Bool {
        switch self {
        case .conflict, .versionConflict, .expired, .uploadRejected: true
        default: false
        }
    }
}

/// A descriptor is exposed only after author, workspace and document-chain verification.
public struct DropObject: Sendable, Equatable {
    public let descriptor: DropDescriptor
    public let signed: JSONValue
    public let wraps: [DropWrapRecord]
}

public struct DropDownload: Sendable, Equatable {
    public let url: URL
    public let metadata: DropMetadata
    /// Persisted local retention deadline, bounded by signed expiry.
    public let deadlineMs: Int64
}

public struct DropUploadIdentity: Sendable, Hashable {
    public let object: ID16
    public let version: UInt32
}

public struct DropUploadFailure: Sendable, Equatable {
    public let object: ID16
    public let version: UInt32
    public let reason: String
}

public struct DropUploadResult: Sendable {
    public let object: ID16
    public let version: UInt32
    public let result: Result<DropObject, any Error>
}

public struct DropSendAttachment: Sendable {
    public let id: UUID
    public let data: Data
    public let name: String
    public let mime: String
    public let transcript: String?
    public init(id: UUID, data: Data, name: String, mime: String = "application/octet-stream", transcript: String? = nil) {
        self.id = id; self.data = data; self.name = name; self.mime = mime; self.transcript = transcript
    }
}

/// Workspace-scoped Drop client. Other-device certificates must be verified by the caller against
/// the workspace owner before being supplied; membership is checked against a signed member list.
public actor DropService {
    public enum Direction: String, Sendable { case received, sending }
    public enum Kind: String, Sendable { case file, document }
    @TaskLocal private static var operationEpoch: UInt64?
    private var lifecycleEpoch: UInt64 = 0
    private var suspended = false
    private var invalidated = false
    public func suspend() {
        lifecycleEpoch &+= 1
        suspended = true
        uploads.values.forEach { $0.task.cancel() }
        imports.values.forEach { $0.task.cancel() }
    }
    public func invalidate() async {
        invalidated = true; suspend()
        // Cancellation-uncooperative transports/hooks must not hold Leave forever.
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !running.isEmpty && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    public func activate() throws {
        guard !invalidated else { throw DropError.suspended }
        suspended = false
    }
    private func requireAvailable() throws {
        try Task.checkCancellation()
        guard !suspended, !invalidated, Self.operationEpoch.map({ $0 == lifecycleEpoch }) ?? true else { throw DropError.suspended }
    }
    private struct Operation<Value: Sendable> {
        let id: UUID
        let epoch: UInt64
        let task: Task<Value, Error>
    }
    private var imports: [String: Operation<[DropObject]>] = [:]
    private var uploads: [String: Operation<DropObject>] = [:]
    private var running: Set<UUID> = []
    // All work for an upload/job, including discard, passes through this FIFO admission.
    private var admissions: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var hook: (@Sendable (String) async throws -> Void)?
    /// Test seam only; must never be wired in app code.
    package func setHook(_ hook: (@Sendable (String) async throws -> Void)?) { self.hook = hook }
    private func admit(_ key: String) async {
        if admissions[key] == nil { admissions[key] = []; return }
        await withCheckedContinuation { admissions[key, default: []].append($0) }
    }
    private func release(_ key: String) {
        if admissions[key]?.isEmpty == false { admissions[key]!.removeFirst().resume() }
        else { admissions[key] = nil }
    }
    private func requireActive(_ key: String) async throws {
        try await check()
        let db = try await session.cfg.container.database()
        guard try await db.query("SELECT key FROM drop_abandoned WHERE key=?", [.text(key)]).isEmpty else { throw DropError.abandoned }
    }
    private func requireActiveUpload(_ object: ID16, _ version: UInt32) async throws {
        try await requireActive(Self.importAbandonmentKey(object))
        let db = try await session.cfg.container.database()
        guard let body = try await db.query("SELECT body FROM drop_uploads WHERE object=? AND version=?", [.text(object.hex), .int(Int64(version))]).first?.blob("body") else { throw DropError.abandoned }
        try await requireActive(Self.abandonmentKey(object, version, body))
        guard try await db.query("SELECT job FROM drop_imports JOIN drop_abandoned ON key='job:' || job WHERE object=?", [.text(object.hex)]).isEmpty else { throw DropError.abandoned }
    }
    private nonisolated static func abandonmentKey(_ object: ID16, _ version: UInt32, _ body: Data) -> String {
        "upload:\(object.hex):\(version):\(B64U.encode(Data(SHA256.hash(data: body))))"
    }
    // Import retries retain their object identity even when no sealed upload remains.
    private nonisolated static func importAbandonmentKey(_ object: ID16) -> String {
        "import:\(object.hex)"
    }
    public nonisolated var downloadContainer: WorkspaceContainer { session.cfg.container }
    let session: WorkspaceSession
    let card: VerifiedCard
    let certificates: [ID16: DeviceCertificate]
    public static let maxPlaintextBytes = 25 << 20
    public static let maxVersions = 1024

    public init(session: WorkspaceSession, card: VerifiedCard, certificates: [DeviceCertificate] = []) throws {
        guard card.workspace == session.workspace, card.wsk == session.cfg.wsk else { throw DropError.unauthorized }
        self.session = session; self.card = card
        self.certificates = Dictionary(certificates.map { ($0.deviceID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    package func requireDemo() throws {
        guard session.cfg.context.realm == .demo else { throw RealmViolation.wrongStore }
        try session.cfg.context.generation?.check()
    }

    private func auth() async throws -> RelaySession {
        try await check()
        let result = try await session.dropRelaySession()
        try await hook?("auth.acquired")
        try await check()
        return result
    }
    private func check() async throws { try requireAvailable(); try await session.ensureCurrent(); try requireAvailable() }
    private func parse(_ reply: WireReply, fields: Set<String>, status: Int = 200) throws -> [String: JSONValue] {
        _ = try HostAPI.expect(reply, status: status)
        guard let o = try StrictJSON.parse(reply.body, maxBytes: 8 << 20).object,
              Set(o.keys) == fields.union(["host_api"]), o["host_api"] == 0 else { throw DropError.malformed }
        return o
    }
    private func membership(operate: Bool = false) async throws -> MemberList {
        let s = try await auth()
        try requireAvailable()
        let raw = try await RelayClient(transport: session.cfg.transport).memberList(workspace: card.workspace, session: s)
        let list = try MemberList.verify(raw, wsk: card.wsk)
        guard list.workspace == card.workspace, list.members.contains(where: { $0.deviceID == session.cfg.deviceID && ($0.scopeStrings?.contains(operate ? "operate" : "look") ?? false) }) else { throw DropError.unauthorized }
        guard list.epoch >= (try await session.currentEpoch()) else { throw DropError.rollback }
        if list.epoch > (try await session.currentEpoch()) {
            try await check()
            _ = try await session.refreshGrants(confirmedEpoch: list.epoch)
        }
        guard list.epoch == (try await session.currentEpoch()) else { throw DropError.unavailableKey }
        try await check()
        return list
    }
    private func verify(_ signed: JSONValue, members: MemberList) throws -> DropDescriptor {
        guard let o = signed.object?["o"]?.object else { throw DropError.malformed }
        let shape = try DropDescriptor(object: o)
        guard shape.space == card.workspace, shape.spaceKind == "workspace" else { throw DropError.unauthorized }
        let key: SigningPublicKey
        if shape.authorKind == "workspace" {
            guard shape.authorID == card.workspace else { throw DropError.unauthorized }
            key = card.wsk
        } else {
            guard members.members.contains(where: { $0.deviceID == shape.authorID && ($0.scopeStrings?.contains("operate") ?? false) }) else { throw DropError.unauthorized }
            if shape.authorID == session.cfg.deviceID { key = session.cfg.identity.publicKeys.sig }
            else {
                guard let cert = certificates[shape.authorID], cert.personID == card.ownerPersonID,
                      cert.expiresMs.map({ $0 > session.cfg.wall.nowMs }) ?? true else { throw DropError.unauthorized }
                key = cert.signingKey
            }
        }
        return try DropDescriptor.verify(signed, authorKey: key)
    }
    private func get(_ id: ID16, _ version: UInt32, _ part: DropPart) async throws -> WireReply {
        let s = try await auth()
        try requireAvailable()
        let reply = try await session.cfg.transport.dropGet(objectID: id, version: version, part: part, session: s)
        try await check()
        return reply
    }
    private func verified(_ signed: JSONValue, wraps: [JSONValue], members: MemberList) async throws -> DropObject {
        let d = try verify(signed, members: members)
        guard d.version <= Self.maxVersions, wraps.count <= 1024 else { throw DropError.tooLarge }
        guard d.expiresMs.map({ $0 > session.cfg.wall.nowMs }) ?? (d.objectKind == "document") else { throw DropError.expired }
        var chain: [[String: JSONValue]] = []
        if d.version > 1 {
            for version in 1..<d.version {
                let o = try parse(await get(d.object, version, .descriptor), fields: ["descriptor"])
                let previous = try verify(o["descriptor"]!, members: members)
                guard previous.object == d.object, previous.version == version else { throw DropError.integrity }
                chain.append(previous.raw)
            }
        }
        chain.append(d.raw)
        try DropDocument.verifyChain(chain)
        switch d.recipients {
        case .ids(let ids): guard ids.contains(card.workspace) || ids.contains(session.cfg.deviceID) else { throw DropError.unauthorized }
        case .inbox: break
        }
        let parsed = try wraps.map(DropWrapRecord.init(json:))
        guard parsed.allSatisfy({ $0.object == d.object && $0.version == d.version }) else { throw DropError.integrity }
        try await check()
        try await session.cfg.container.acceptDropChain(object: d.object.hex, chain: chain.map { try DropDescriptor.parentHash(of: $0) })
        return DropObject(descriptor: d, signed: signed, wraps: parsed)
    }

    public func list(_ direction: Direction = .received) async throws -> [DropObject] {
        // Nested operations and unstructured children retain the admitting lifecycle epoch.
        if Self.operationEpoch == nil {
            return try await Self.$operationEpoch.withValue(lifecycleEpoch) { try await self.list(direction) }
        }
        try requireAvailable()
        try await purgeExpiredDownloads()
        let members = try await membership(), s = try await auth()
        let query: JSONValue = ["host_api": 0, "workspace_id": .string(card.workspace.hex), "direction": .string(direction.rawValue)]
        try requireAvailable()
        let o = try parse(await session.cfg.transport.dropList(canonicalJSON(query), session: s), fields: ["objects"])
        guard let rows = o["objects"]?.array, rows.count <= 1024 else { throw DropError.tooLarge }
        var result: [DropObject] = []
        for row in rows {
            guard let r = row.object, Set(r.keys) == ["descriptor", "wraps"], let signed = r["descriptor"], let wraps = r["wraps"]?.array else { throw DropError.malformed }
            let v = try await verified(signed, wraps: wraps, members: members)
            guard (direction == .sending) == (v.descriptor.authorID == session.cfg.deviceID) else { throw DropError.unauthorized }
            result.append(v)
        }
        try await check()
        return result
    }

    /// Imports only this generation's claimed destination. The SQLite item mapping survives crashes;
    /// plaintext is deleted after every non-abandoned item is confirmed by read-back and job completion is durable.
    /// Completed jobs retry cleanup only and return no new objects; deletion failures are reported to the caller.
    public func importShareJob(_ job: StagedJob, inbox: ShareInbox) async throws -> [DropObject] {
        // Nested operations and unstructured children retain the admitting lifecycle epoch.
        if Self.operationEpoch == nil {
            return try await Self.$operationEpoch.withValue(lifecycleEpoch) { try await self.importShareJob(job, inbox: inbox) }
        }
        try requireAvailable()
        guard job.manifest.realm == session.cfg.context.realm.rawValue, job.manifest.ws == card.workspace.hex,
              job.manifest.generation == session.generation else { throw DropError.unauthorized }
        if let operation = imports[job.manifest.jobID], operation.epoch == lifecycleEpoch { return try await operation.task.value }
        let id = UUID()
        running.insert(id)
        let task = Task {
            defer { self.running.remove(id) }
            return try await self.performImport(job, inbox: inbox)
        }
        imports[job.manifest.jobID] = Operation(id: id, epoch: lifecycleEpoch, task: task)
        defer { if imports[job.manifest.jobID]?.id == id { imports[job.manifest.jobID] = nil } }
        return try await task.value
    }

    private func performImport(_ job: StagedJob, inbox: ShareInbox) async throws -> [DropObject] {
        let key = "job:\(job.manifest.jobID)"
        try await hook?("import.requested")
        await admit(key)
        defer { release(key) }
        try await requireActive(key)
        try await check()
        guard job.manifest.realm.utf8.elementsEqual(session.cfg.context.realm.rawValue.utf8),
              job.manifest.ws.utf8.elementsEqual(card.workspace.hex.utf8), job.manifest.generation == session.generation else { throw DropError.unauthorized }
        let db = try await session.cfg.container.database()
        if try await !db.query("SELECT job FROM drop_completed_jobs WHERE job=?", [.text(job.manifest.jobID)]).isEmpty {
            try await check()
            try await inbox.cleanupCompleted(job, beforeRemovingItem: { try await self.check() }, afterRemovingItem: hook)
            return []
        }
        var result: [DropObject] = []
        for (i, item) in job.manifest.items.enumerated() {
            let fresh = session.cfg.entropy.id16()
            try await check()
            try await db.execute("INSERT OR IGNORE INTO drop_imports(job,item,object) VALUES(?,?,?)", [.text(job.manifest.jobID), .int(Int64(i)), .text(fresh.hex)])
            guard let id = try await db.query("SELECT object FROM drop_imports WHERE job=? AND item=?", [.text(job.manifest.jobID), .int(Int64(i))]).first?.text("object").flatMap(ID16.init(hex:)) else { throw DropError.malformed }
            if try await !db.query("SELECT key FROM drop_abandoned WHERE key=?", [.text(Self.importAbandonmentKey(id))]).isEmpty { continue }
            do {
            try await check()
            let data = try inbox.contents(of: item, in: job)
            result.append(try await sendData(data, name: item.name, mime: item.kind == .url ? "text/uri-list" : (item.kind == .text ? "text/plain" : "application/octet-stream"),
                transcript: job.manifest.note, expiresMs: nil, document: nil, chosenObject: id))
            } catch DropError.abandoned {
                guard try await !db.query("SELECT key FROM drop_abandoned WHERE key=?", [.text(Self.importAbandonmentKey(id))]).isEmpty else { throw DropError.abandoned }
            }
        }
        try await check()
        try await check()
        try await db.transaction { tx in
            try tx.execute("INSERT OR IGNORE INTO drop_completed_jobs(job) VALUES(?)", [.text(job.manifest.jobID)])
        }
        try await check()
        try await inbox.cleanupCompleted(job, beforeRemovingItem: { try await self.check() }, afterRemovingItem: hook)
        return result
    }

    public func send(_ data: Data, name: String, mime: String = "application/octet-stream", transcript: String? = nil,
                     expiresMs: Int64? = nil, kind: Kind = .file, document: DropObject? = nil) async throws -> DropObject {
        // Nested operations and unstructured children retain the admitting lifecycle epoch.
        if Self.operationEpoch == nil {
            return try await Self.$operationEpoch.withValue(lifecycleEpoch) { try await self.send(data, name: name, mime: mime, transcript: transcript, expiresMs: expiresMs, kind: kind, document: document) }
        }
        try requireAvailable()
        return try await sendData(data, name: name, mime: mime, transcript: transcript, expiresMs: expiresMs, document: document, chosenObject: nil, kind: kind)
    }

    /// Atomically commits a whole compose send. No relay operation occurs during sealing.
    /// Object identities bind workspace, send UUID and attachment UUID; retries reuse stored ciphertext.
    public func sealSend(_ sendID: UUID, attachments: [DropSendAttachment]) async throws -> [DropUploadIdentity] {
        if Self.operationEpoch == nil {
            return try await Self.$operationEpoch.withValue(lifecycleEpoch) { try await self.sealSend(sendID, attachments: attachments) }
        }
        try await check()
        guard !attachments.isEmpty, attachments.count <= 5,
              Set(attachments.map(\.id)).count == attachments.count,
              attachments.reduce(0, { $0 + $1.data.count }) <= Self.maxPlaintextBytes else { throw DropError.tooLarge }
        let epoch = try await session.currentEpoch(), wk = try await session.dropKey(epoch)
        let now = session.cfg.wall.nowMs
        var sealed: [(String, Data)] = []
        for attachment in attachments {
            try await check()
            let digest = SHA256.hash(data: Data("drop-send:\(card.workspace.hex):\(sendID):\(attachment.id)".utf8))
            let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
            let object = ID16(hex: hex)!
            let body = try DropUpload.seal(attachment.data,
                metadata: DropMetadata(name: attachment.name, mime: attachment.mime, size: Int64(attachment.data.count), transcript: attachment.transcript),
                object: object, workspace: card.workspace, author: session.cfg.deviceID, authorKind: "device", signer: session.cfg.identity.sig,
                wxk: card.wxk, wxkVersion: card.wxkVersion, sender: session.cfg.identity.publicKeys.kx, wk: wk, epoch: epoch,
                now: now, expiry: DropUpload.addMs(now, 604800000))
            sealed.append((hex, body))
            try await hook?("send.sealed:\(sealed.count)")
        }
        let db = try await session.cfg.container.database()
        try await check()
        let batch = sealed
        try await db.transaction { tx in
            for (object, body) in batch {
                try tx.execute("INSERT OR IGNORE INTO drop_uploads(object,version,body,done) VALUES(?,1,?,0)", [.text(object), .blob(body)])
            }
        }
        return batch.map { DropUploadIdentity(object: ID16(hex: $0.0)!, version: 1) }
    }

    /// Fresh DEK per version. The exact sealed upload is durable before the first PUT.
    private func sendData(_ data: Data, name: String, mime: String, transcript: String?,
                     expiresMs: Int64?, document: DropObject?, chosenObject: ID16?, kind: Kind = .file) async throws -> DropObject {
        _ = try await membership(operate: true)
        guard data.count <= Self.maxPlaintextBytes else { throw DropError.tooLarge }
        let now = session.cfg.wall.nowMs
        let expiry = expiresMs ?? DropUpload.addMs(now, 604800000)
        guard expiry > now, expiry <= DropUpload.addMs(now, 604800000) else { throw DropError.expired }
        let object = chosenObject ?? document?.descriptor.object ?? session.cfg.entropy.id16()
        if chosenObject != nil { try await requireActive(Self.importAbandonmentKey(object)) }
        if chosenObject != nil, try await session.cfg.container.database().query("SELECT object FROM drop_uploads WHERE object=? AND version=1", [.text(object.hex)]).first != nil {
            return try await upload(object: object, version: 1)
        }
        let parent = document?.descriptor.version ?? 0
        guard parent < Self.maxVersions, document == nil || document?.descriptor.objectKind == "document" else { throw DropError.malformed }
        let epoch = try await session.currentEpoch()
        let wk = try await session.dropKey(epoch)
        try await check()
        let body = try DropUpload.seal(data, metadata: DropMetadata(name: name, mime: mime, size: Int64(data.count), transcript: transcript),
            object: object, workspace: card.workspace, author: session.cfg.deviceID, authorKind: "device", signer: session.cfg.identity.sig,
            wxk: card.wxk, wxkVersion: card.wxkVersion, sender: session.cfg.identity.publicKeys.kx, wk: wk, epoch: epoch,
            now: now, expiry: expiry, parent: document?.descriptor, kind: kind.rawValue)
        let db = try await session.cfg.container.database()
        try await check()
        try await db.transaction { tx in
            // Recheck atomically with persistence in case discard ran while sealing.
            guard try tx.query("SELECT key FROM drop_abandoned WHERE key=?", [.text(Self.importAbandonmentKey(object))]).isEmpty else { throw DropError.abandoned }
            guard try tx.query("SELECT key FROM drop_abandoned WHERE key=?", [.text(Self.abandonmentKey(object, parent + 1, body))]).isEmpty else { throw DropError.abandoned }
            try tx.execute("INSERT OR IGNORE INTO drop_uploads(object,version,body,done) VALUES(?,?,?,0)", [.text(object.hex), .int(Int64(parent + 1)), .blob(body)])
            guard let stored = try tx.query("SELECT body FROM drop_uploads WHERE object=? AND version=?", [.text(object.hex), .int(Int64(parent + 1))]).first?.blob("body") else { throw DropError.malformed }
            if chosenObject == nil && stored != body { throw DropError.conflict }
        }
        return try await upload(object: object, version: parent + 1)
    }

    /// Recover every pending row independently; stale uncommitted bodies get a fresh DEK.
    public func resumeUploads() async throws -> [DropUploadResult] {
        // Nested operations and unstructured children retain the admitting lifecycle epoch.
        if Self.operationEpoch == nil {
            return try await Self.$operationEpoch.withValue(lifecycleEpoch) { try await self.resumeUploads() }
        }
        try requireAvailable()
        try await check()
        let rows = try await session.cfg.container.database().query("SELECT object,version FROM drop_uploads WHERE done=0 ORDER BY object,version")
        var result: [DropUploadResult] = []
        for row in rows {
            guard let id = row.text("object").flatMap(ID16.init(hex:)), let n = row.int("version"), n > 0, n <= UInt32.max else { throw DropError.malformed }
            try await hook?("resume.row:\(id.hex)")
            do { result.append(DropUploadResult(object: id, version: UInt32(n), result: .success(try await upload(object: id, version: UInt32(n))))) }
            catch { result.append(DropUploadResult(object: id, version: UInt32(n), result: .failure(error))) }
        }
        return result
    }
    private func upload(object: ID16, version: UInt32, retry: Bool = false) async throws -> DropObject {
        let key = "upload:\(object.hex):\(version)"
        try requireAvailable()
        if let operation = uploads[key], operation.epoch == lifecycleEpoch {
            try await hook?("upload.coalesced:\(object.hex)")
            return try await operation.task.value
        }
        let id = UUID()
        running.insert(id)
        let task = Task {
            defer { self.running.remove(id) }
            try await self.hook?("upload.requested:\(object.hex)")
            await self.admit(key)
            defer { self.release(key) }
            try await self.requireActiveUpload(object, version)
            let db = try await self.session.cfg.container.database()
            if retry {
                try await self.check()
                try await db.execute("UPDATE drop_uploads SET done=0,failure=NULL WHERE object=? AND version=? AND done=2", [.text(object.hex), .int(Int64(version))])
            }
            return try await self.uploadCurrent(object: object, version: version)
        }
        uploads[key] = Operation(id: id, epoch: lifecycleEpoch, task: task)
        defer { if uploads[key]?.id == id { uploads[key] = nil } }
        return try await task.value
    }

    // Reload only after admission. Each recursive reseal gets its own revision-scoped outcome.
    private func uploadCurrent(object: ID16, version: UInt32) async throws -> DropObject {
        try await requireActiveUpload(object, version)
        let db = try await session.cfg.container.database()
        guard let row = try await db.query("SELECT body,revision,done FROM drop_uploads WHERE object=? AND version=?", [.text(object.hex), .int(Int64(version))]).first,
              let body = row.blob("body"), let revision = row.int("revision") else { throw DropError.abandoned }
        guard row.int("done") != 2 else { throw DropError.conflict }
        do { return try await performUpload(object: object, version: version, body: body, revision: revision) }
        catch {
            if let e = error as? DropError, e.terminalUpload {
                try await check()
                try await db.execute("UPDATE drop_uploads SET done=2,failure=? WHERE object=? AND version=? AND revision=? AND done=0", [.text(String(describing: e)), .text(object.hex), .int(Int64(version)), .int(revision)])
            }
            throw error
        }
    }

    /// Terminal outcomes survive restart and remain visible until explicitly resolved.
    public func failedUploads() async throws -> [DropUploadFailure] {
        // Nested operations and unstructured children retain the admitting lifecycle epoch.
        if Self.operationEpoch == nil {
            return try await Self.$operationEpoch.withValue(lifecycleEpoch) { try await self.failedUploads() }
        }
        try requireAvailable()
        try await check()
        let rows = try await session.cfg.container.database().query("SELECT object,version,failure FROM drop_uploads WHERE done=2")
        return try rows.map { row in
            guard let id = row.text("object").flatMap(ID16.init(hex:)), let n = row.int("version"), n > 0, n <= UInt32.max else { throw DropError.malformed }
            return DropUploadFailure(object: id, version: UInt32(n), reason: row.text("failure") ?? "failed")
        }
    }

    /// Only these uploads have passed exact descriptor and blob read-back.
    public func confirmedUploads() async throws -> [DropUploadIdentity] {
        // Nested operations and unstructured children retain the admitting lifecycle epoch.
        if Self.operationEpoch == nil {
            return try await Self.$operationEpoch.withValue(lifecycleEpoch) { try await self.confirmedUploads() }
        }
        try requireAvailable()
        try await check()
        let rows = try await session.cfg.container.database().query("SELECT object,version FROM drop_uploads WHERE done=1")
        try await check()
        return try rows.map { row in
            guard let object = row.text("object").flatMap(ID16.init(hex:)), let version = row.int("version"),
                  version > 0, version <= UInt32.max else { throw DropError.malformed }
            return DropUploadIdentity(object: object, version: UInt32(version))
        }
    }

    /// Explicitly retry a terminal row; conflict bytes are never overwritten automatically.
    public func retryUpload(object: ID16, version: UInt32) async throws -> DropObject {
        // Nested operations and unstructured children retain the admitting lifecycle epoch.
        if Self.operationEpoch == nil {
            return try await Self.$operationEpoch.withValue(lifecycleEpoch) { try await self.retryUpload(object: object, version: version) }
        }
        try requireAvailable()
        return try await upload(object: object, version: version, retry: true)
    }

    /// Stops local sending of this sealed upload; present this as "stopped sending", not "deleted".
    /// A PUT whose response was lost may already have committed; its content remains on the relay.
    public func discardUpload(object: ID16, version: UInt32) async throws {
        // Nested operations and unstructured children retain the admitting lifecycle epoch.
        if Self.operationEpoch == nil {
            return try await Self.$operationEpoch.withValue(lifecycleEpoch) { try await self.discardUpload(object: object, version: version) }
        }
        try requireAvailable()
        let key = "upload:\(object.hex):\(version)"
        await admit(key)
        defer { release(key) }
        try await hook?("discard.upload.admitted")
        let db = try await session.cfg.container.database()
        try await check()
        try await db.transaction { tx in
            if try !tx.query("SELECT object FROM drop_imports WHERE object=?", [.text(object.hex)]).isEmpty {
                try tx.execute("INSERT OR IGNORE INTO drop_abandoned(key) VALUES(?)", [.text(Self.importAbandonmentKey(object))])
            } else if let body = try tx.query("SELECT body FROM drop_uploads WHERE object=? AND version=?", [.text(object.hex), .int(Int64(version))]).first?.blob("body") {
                try tx.execute("INSERT OR IGNORE INTO drop_abandoned(key) VALUES(?)", [.text(Self.abandonmentKey(object, version, body))])
            }
            try tx.execute("DELETE FROM drop_uploads WHERE object=? AND version=?", [.text(object.hex), .int(Int64(version))])
        }
    }

    /// Stops local sending and removes staged plaintext; present this as "stopped sending", not "deleted".
    /// Content already committed by a PUT (including a lost response) remains on the relay.
    /// Tombstone precedes cleanup and survives failed deletion and stale in-memory job handles.
    public func discardShareJob(_ job: StagedJob, inbox: ShareInbox) async throws {
        // Nested operations and unstructured children retain the admitting lifecycle epoch.
        if Self.operationEpoch == nil {
            return try await Self.$operationEpoch.withValue(lifecycleEpoch) { try await self.discardShareJob(job, inbox: inbox) }
        }
        try requireAvailable()
        guard job.manifest.ws == card.workspace.hex, job.manifest.generation == session.generation,
              job.manifest.realm == session.cfg.context.realm.rawValue else { throw DropError.unauthorized }
        let key = "job:\(job.manifest.jobID)"
        await admit(key)
        defer { release(key) }
        try await hook?("discard.job.admitted")
        let db = try await session.cfg.container.database()
        try await check()
        try await db.execute("INSERT OR IGNORE INTO drop_abandoned(key) VALUES(?)", [.text(key)])
        try await hook?("discard.job.tombstoned")
        let rows = try await db.query("SELECT object FROM drop_imports WHERE job=?", [.text(job.manifest.jobID)])
        for row in rows { if let id = row.text("object").flatMap(ID16.init(hex:)) { try await discardUpload(object: id, version: 1) } }
        try await hook?("discard.job.cleanup")
        try await check()
        guard inbox.complete(job) else { throw ShareError.io("remove staged plaintext") }
        try await check()
        try await db.execute("DELETE FROM drop_imports WHERE job=?", [.text(job.manifest.jobID)])
    }

    private func performUpload(object: ID16, version: UInt32, body: Data, revision: Int64) async throws -> DropObject {
        let members = try await membership(operate: true)
        let s = try await auth()
        guard let o = try StrictJSON.parse(body, maxBytes: 36 << 20).object,
              Set(o.keys) == ["host_api", "descriptor", "wraps", "blob"], o["host_api"] == 0,
              let signed = o["descriptor"], let wraps = o["wraps"]?.array, wraps.count <= 1024,
              let blobText = o["blob"]?.string, let expectedBlob = B64U.decode(blobText), expectedBlob.count <= 26 << 20 else { throw DropError.malformed }
        let descriptor = try verify(signed, members: members)
        let existing = try await get(object, version, .descriptor)
        if existing.status == 404 {
            let records = try wraps.map(DropWrapRecord.init(json:))
            if records.contains(where: { $0.targetKind == .wk && $0.target == card.workspace && $0.keyVersion < members.epoch }) {
                guard let dek = try await openKey(records, descriptor: descriptor) else { throw DropError.unavailableKey }
                let metadata = try DropMetadata.open(sealed: descriptor.meta, dek: dek, object: object, version: version)
                let plaintext = try DropBlob.decrypt(dek: dek, object: object, version: version, blob: expectedBlob, maxBytes: 26 << 20)
                var parent: DropDescriptor?
                if version > 1 {
                    let previous = try parse(await get(object, version - 1, .descriptor), fields: ["descriptor"])
                    parent = try verify(previous["descriptor"]!, members: members)
                    guard try DropDescriptor.parentHash(of: parent!.raw) == descriptor.parentHash else { throw DropError.conflict }
                }
                guard let expiry = descriptor.expiresMs, expiry > session.cfg.wall.nowMs else { throw DropError.expired }
                let currentKey = try await session.dropKey(members.epoch)
                try await check()
                let fresh = try DropUpload.seal(plaintext, metadata: metadata, object: object, workspace: card.workspace,
                    author: session.cfg.deviceID, authorKind: "device", signer: session.cfg.identity.sig, wxk: card.wxk,
                    wxkVersion: card.wxkVersion, sender: session.cfg.identity.publicKeys.kx, wk: currentKey,
                    epoch: members.epoch, now: session.cfg.wall.nowMs, expiry: expiry, parent: parent, kind: descriptor.objectKind)
                let db = try await session.cfg.container.database()
                try await check()
                try await db.execute("UPDATE drop_uploads SET body=?,revision=revision+1 WHERE object=? AND version=? AND revision=? AND done=0", [.blob(fresh), .text(object.hex), .int(Int64(version)), .int(revision)])
                return try await uploadCurrent(object: object, version: version)
            }
            guard descriptor.expiresMs.map({ $0 > session.cfg.wall.nowMs }) ?? true else { throw DropError.expired }
        } else if existing.status != 200 { _ = try HostAPI.expect(existing) }
        var conflictCurrent: UInt32?
        let stale = try wraps.map(DropWrapRecord.init(json:)).contains { $0.targetKind == .wk && $0.keyVersion < members.epoch }
        do {
            if existing.status == 404 || !stale {
                try await requireActiveUpload(object, version)
                try await check()
                let reply = try await session.cfg.transport.dropPut(objectID: object, ifMatch: version - 1, body: body, session: s)
                if reply.status == 409, let n = try StrictJSON.parse(reply.body).object?["current"]?.int, n >= 0, n <= UInt32.max { conflictCurrent = UInt32(n) }
                if (400..<500).contains(reply.status), reply.status != 409, reply.status != 429 { throw DropError.uploadRejected(status: reply.status) }
                if reply.status != 409 { _ = try parse(reply, fields: ["version"], status: 201) }
            }
        } catch let error as TransportError {
            if error != .disconnected { throw error }
        }
        // Always read back: a lost 201 or a stale retry is successful only for these exact committed bytes.
        let readBack = try await get(object, version, .descriptor)
        if readBack.status == 404, let conflictCurrent { throw DropError.versionConflict(current: conflictCurrent) }
        let committed = try parse(readBack, fields: ["descriptor"])
        let blob = try await get(object, version, .blob)
        _ = try HostAPI.expect(blob)
        guard try canonicalJSON(committed["descriptor"]!) == canonicalJSON(signed),
              expectedBlob == blob.body else {
            if let conflictCurrent { throw DropError.versionConflict(current: conflictCurrent) }
            throw DropError.conflict
        }
        let result = try await verified(signed, wraps: wraps, members: membership())
        try await check()
        try await session.cfg.container.database().execute("UPDATE drop_uploads SET done=1,failure=NULL WHERE object=? AND version=? AND revision=? AND done=0", [.text(object.hex), .int(Int64(version)), .int(revision)])
        return result
    }

    /// The phone asks the host to claim; only the host signs the §10.5 claim.
    public func claim(_ object: DropObject) async throws {
        // Nested operations and unstructured children retain the admitting lifecycle epoch.
        if Self.operationEpoch == nil {
            return try await Self.$operationEpoch.withValue(lifecycleEpoch) { try await self.claim(object) }
        }
        try requireAvailable()
        guard object.descriptor.recipients == .inbox else { throw DropError.malformed }
        _ = try await verified(object.signed, wraps: object.wraps.map(\.json), members: membership(operate: true))
        try await check()
        let response = try await session.exchange(meta: ["op": "drop_claim", "object_id": .string(object.descriptor.object.hex),
                                                        "version": .int(Int64(object.descriptor.version))])
        guard response.status == 200 else { throw DropError.conflict }
        try await check()
    }

    public func download(_ object: DropObject) async throws -> URL {
        try await downloadVerified(object).url
    }

    /// Call on app foreground; no network access is needed to remove expired local plaintext.
    public func purgeExpiredDownloads() async throws {
        // Nested operations and unstructured children retain the admitting lifecycle epoch.
        if Self.operationEpoch == nil {
            return try await Self.$operationEpoch.withValue(lifecycleEpoch) { try await self.purgeExpiredDownloads() }
        }
        try requireAvailable()
        try await check()
        try await session.cfg.container.purgeExpiredDownloads(nowMs: session.cfg.wall.nowMs)
    }

    public func downloadVerified(_ object: DropObject) async throws -> DropDownload {
        // Nested operations and unstructured children retain the admitting lifecycle epoch.
        if Self.operationEpoch == nil {
            return try await Self.$operationEpoch.withValue(lifecycleEpoch) { try await self.downloadVerified(object) }
        }
        try requireAvailable()
        try await purgeExpiredDownloads()
        let (d, dek) = try await verifiedMetadataKey(object)
        let blob = try await get(d.object, d.version, .blob)
        _ = try HostAPI.expect(blob)
        guard blob.body.count <= 26 << 20, d.contentLen == Int64(blob.body.count), d.matches(blob: blob.body) else { throw DropError.integrity }
        let metadata = try DropMetadata.open(sealed: d.meta, dek: dek, object: d.object, version: d.version)
        let plaintext = try DropBlob.decrypt(dek: dek, object: d.object, version: d.version, blob: blob.body, maxBytes: 26 << 20)
        guard metadata.size == plaintext.count, plaintext.count <= Self.maxPlaintextBytes else { throw DropError.integrity }
        try await check()
        try await hook?("download.publish")
        let wall = session.cfg.wall
        try await check()
        let file = try await session.cfg.container.writeDropVerified(plaintext, object: d.object.hex, version: d.version,
            expiresMs: d.expiresMs, now: { wall.nowMs })
        try await check()
        return DropDownload(url: file.url, metadata: metadata, deadlineMs: file.deadlineMs)
    }
    /// Verifies metadata without fetching the blob or publishing a plaintext file.
    public func metadataVerified(_ object: DropObject) async throws -> DropMetadata {
        if Self.operationEpoch == nil {
            return try await Self.$operationEpoch.withValue(lifecycleEpoch) { try await self.metadataVerified(object) }
        }
        try await check()
        let (d, dek) = try await verifiedMetadataKey(object)
        let metadata = try DropMetadata.open(sealed: d.meta, dek: dek, object: d.object, version: d.version)
        guard metadata.size >= 0, metadata.size <= Self.maxPlaintextBytes else { throw DropError.integrity }
        try await check()
        return metadata
    }

    private func verifiedMetadataKey(_ object: DropObject) async throws -> (DropDescriptor, SymmetricKey) {
        let members = try await membership()
        let current = try await verified(object.signed, wraps: object.wraps.map(\.json), members: members)
        let d = current.descriptor
        var wraps = current.wraps
        if d.recipients == .inbox {
            let state = try parse(await get(d.object, d.version, .wraps), fields: ["wraps", "claimed_by"])
            guard state["claimed_by"] == .string(card.workspace.hex) else { throw DropError.unavailableKey }
            guard let raw = state["wraps"]?.array, raw.count <= 1024 else { throw DropError.malformed }
            wraps = try raw.map(DropWrapRecord.init(json:))
        }
        var dek = try await openKey(wraps, descriptor: d)
        if dek == nil {
            try await check()
            let response = try await session.exchange(meta: ["op": "drop_rewrap", "object_id": .string(d.object.hex), "version": .int(Int64(d.version))])
            guard response.status == 200 else { throw DropError.unavailableKey }
            try await check()
            _ = try await session.refreshGrants()
            let o = try parse(await get(d.object, d.version, .wraps), fields: ["wraps", "claimed_by"])
            guard let raw = o["wraps"]?.array, raw.count <= 1024 else { throw DropError.malformed }
            wraps = try raw.map(DropWrapRecord.init(json:))
            dek = try await openKey(wraps, descriptor: d)
        }
        guard let dek else { throw DropError.unavailableKey }
        try await check()
        return (d, dek)
    }

    private func openKey(_ wraps: [DropWrapRecord], descriptor d: DropDescriptor) async throws -> SymmetricKey? {
        for w in wraps {
            guard w.object == d.object, w.version == d.version else { throw DropError.integrity }
            let key: SymmetricKey?
            if w.targetKind == .device, w.target == session.cfg.deviceID, w.keyVersion == 0 {
                key = try? DropWrap.unwrap(w, agreement: session.cfg.identity.kx)
            } else if w.targetKind == .wk, w.target == card.workspace, let wk = try? await session.dropKey(w.keyVersion) {
                key = try? DropWrap.unwrap(w, with: .wk(wk))
            } else { continue }
            guard let key, DropKeys.dekCommit(object: d.object, version: d.version, dek: key) == d.dekCommit else { continue }
            return key
        }
        return nil
    }
}

package enum DropUpload {
    package static func addMs(_ a: Int64, _ b: Int64) -> Int64 {
        let (v, overflow) = a.addingReportingOverflow(b); return overflow ? .max : v
    }
    package static func seal(_ data: Data, metadata: DropMetadata, object: ID16, workspace: ID16, author: ID16, authorKind: String,
                             signer: some Signer, wxk: AgreementPublicKey, wxkVersion: UInt32, sender: AgreementPublicKey?,
                             wk: SymmetricKey, epoch: UInt32, now: Int64, expiry: Int64, parent: DropDescriptor? = nil, kind: String = "file") throws -> Data {
        let version = (parent?.version ?? 0) + 1
        let dek = SymmetricKey(size: .bits256)
        let blob = try DropBlob.encrypt(dek: dek, object: object, version: version, plaintext: data)
        let meta = try metadata.seal(dek: dek, object: object, version: version)
        guard meta.count <= Drop.maxMetaBytes + 16 else { throw DropError.tooLarge }
        let raw: [String: JSONValue] = ["v": 2, "suite": 2, "kind": "drop_object", "object_id": .string(object.hex),
            "space_id": .string(workspace.hex), "space_kind": "workspace", "object_kind": .string(parent == nil ? kind : "document"),
            "version": .int(Int64(version)), "parent": .int(Int64(version - 1)),
            "parent_hash": try parent.map { .string(B64U.encode(try DropDescriptor.parentHash(of: $0.raw))) } ?? .null,
            "author_kind": .string(authorKind), "author_id": .string(author.hex), "content_hash": .string(B64U.encode(Data(SHA256.hash(data: blob)))),
            "content_len": .int(Int64(blob.count)), "dek_commit": .string(B64U.encode(DropKeys.dekCommit(object: object, version: version, dek: dek))),
            "meta": .string(B64U.encode(meta)), "recipients": .array([.string(workspace.hex)]), "origin": .string(authorKind == "workspace" ? "agent" : "human"),
            "created_ms": .int(now), "expires_ms": .int(expiry)]
        var wraps = [try DropWrap.wrapToKey(kind: .wxk, to: wxk, target: workspace, keyVersion: wxkVersion, object: object, version: version, dek: dek),
                     try DropWrap.wrapWithSecret(kind: .wk, secret: wk, target: workspace, keyVersion: epoch, object: object, version: version, dek: dek)]
        if let sender { wraps.append(try DropWrap.wrapToKey(kind: .device, to: sender, target: author, keyVersion: 0, object: object, version: version, dek: dek)) }
        return try canonicalJSON(["host_api": 0, "descriptor": SignedObject.sign(raw, kind: .dropObject, signer: signer).json,
                                  "wraps": .array(wraps.map(\.json)), "blob": .string(B64U.encode(blob))])
    }
}
