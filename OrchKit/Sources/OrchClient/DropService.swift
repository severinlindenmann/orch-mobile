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
    /// 429 `quota_exceeded` with a stored-bytes or count cap (protocol 19.9): not transient. The row stays pending (nothing is lost) and
    /// is not retried before `retryAfterSeconds` (the relay's `Retry-After`, 600 s); show "Drop storage full".
    case storageFull(quota: String?, retryAfterSeconds: Int)
    /// 429 `rate_limited` or a slot cap, 503 `overloaded`, or a refetch the limiter defers: transient, back off for `afterSeconds`.
    case retryLater(afterSeconds: Int)
    /// 409 `rotation_required`: the host has a rotation due; retry after it rotated.
    case rotationPending
    /// The relay answers 410 for an object whose signed expiry has NOT passed here (a document, or a file inside its lifetime). The
    /// relay may be lying or the host retired it: the row stays pending, is not retried for an hour, and is listed by `stalledUploads`
    /// ("Removed by the host? Retry or discard").
    case possiblyRemoved

    fileprivate var terminalUpload: Bool {
        switch self {
        case .conflict, .versionConflict, .expired, .uploadRejected, .malformed, .tooLarge: true
        default: false
        }
    }
}

/// Why a listed object is gone (protocol 19.9, list `state`): a tombstone stays listed for 30 days and cannot be opened or downloaded.
public struct DropGone: Sendable, Equatable {
    public enum Reason: String, Sendable { case expired, retired, unavailable }
    public let object: ID16
    public let version: UInt32
    public let reason: Reason
    public let tombstoneUntilMs: Int64?
    /// What to show: a retire is "Removed by your Mac", an expiry "Expired".
    public var label: String {
        switch reason {
        case .retired: "Removed by your Mac"
        case .expired: "Expired"
        case .unavailable: "No longer available"
        }
    }
}

/// A descriptor is exposed only after author, workspace and document-chain verification.
public struct DropObject: Sendable, Equatable {
    public let descriptor: DropDescriptor
    public let signed: JSONValue
    public let wraps: [DropWrapRecord]
    /// The list entry's `claimed_by`: an unauthenticated HINT from the relay, never a decision input (a download re-reads the wraps and
    /// only a wrap that opens to the committed DEK counts). nil when unclaimed or not from a list.
    public let claimedBy: ID16?
    package init(descriptor: DropDescriptor, signed: JSONValue, wraps: [DropWrapRecord], claimedBy: ID16? = nil) {
        self.descriptor = descriptor; self.signed = signed; self.wraps = wraps; self.claimedBy = claimedBy
    }
}

public struct DropListing: Sendable {
    public let objects: [DropObject]
    /// Opaque local identifiers; no unverified descriptor fields are exposed.
    public let blocked: [String]
    /// Tombstones (`expired`, `retired`) and entries that are not live: shown as gone, never opened.
    public let gone: [DropGone]
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
        try await migrateLegacyUploads()
        try await requireActive(Self.importAbandonmentKey(object))
        let db = try await session.cfg.container.database()
        guard let stored = try await loadHead(db, object, version) else { throw DropError.abandoned }
        try await requireActive(Self.abandonmentKey(object, version, descriptor: stored.parts.descriptor))
        guard try await db.query("SELECT job FROM drop_imports JOIN drop_abandoned ON key='job:' || job WHERE object=?", [.text(object.hex)]).isEmpty else { throw DropError.abandoned }
    }
    /// An upload is abandoned by its signed descriptor: re-framing the sealed bytes or re-wrapping the DEK (same descriptor) keeps a
    /// discard in force, and a reseal (a new descriptor) is a different upload.
    private nonisolated static func abandonmentKey(_ object: ID16, _ version: UInt32, descriptor: JSONValue) -> String {
        let bytes = (try? canonicalJSON(descriptor)) ?? Data()
        return "upload:\(object.hex):\(version):\(B64U.encode(Data(SHA256.hash(data: bytes))))"
    }
    /// The key of the pre-ODU2 stored form (a hash of the whole JSON body); only the migration reads it.
    private nonisolated static func legacyAbandonmentKey(_ object: ID16, _ version: UInt32, _ body: Data) -> String {
        "upload:\(object.hex):\(version):\(B64U.encode(Data(SHA256.hash(data: body))))"
    }

    /// The head of a stored upload frame: read with SQL `substr`, so the 26 MiB blob is never loaded to look at the descriptor.
    private struct StoredHead {
        let parts: DropFrame.Parts
        let total: Int
        let revision: Int64
        let done: Int64
    }
    private func loadHead(_ db: SQLiteDatabase, _ object: ID16, _ version: UInt32) async throws -> StoredHead? {
        guard let row = try await db.query("SELECT substr(body,1,?) AS head, length(body) AS n, revision, done FROM drop_uploads WHERE object=? AND version=?",
                                           [.int(Int64(DropFrame.prefixLength + DropFrame.maxHeadBytes)), .text(object.hex), .int(Int64(version))]).first,
              let head = row.blob("head"), let n = row.int("n"), let revision = row.int("revision"), let done = row.int("done") else { return nil }
        guard let parts = try? DropFrame.parseHead(head, total: Int(n)) else { throw DropError.malformed }
        return StoredHead(parts: parts, total: Int(n), revision: revision, done: done)
    }

    /// One-time (per process) migration of pending rows that hold the old JSON form `cj({descriptor, wraps, blob: b64u})`: the same sealed
    /// bytes are re-framed as `ODU2` (never resealed, so the relay sees the same descriptor and an exact retry still holds), and an
    /// abandonment recorded under the old key moves to the new one in the same transaction.
    private var migration: Task<Void, Error>?
    private func migrateLegacyUploads() async throws {
        if let running = migration { return try await running.value }
        let id = UUID()
        running.insert(id)
        let task = Task {
            defer { self.running.remove(id) }
            try await self.sweepStagedFrames()
            try await self.performMigration()
        }
        migration = task
        do { try await task.value } catch { migration = nil; throw error }
    }
    private func performMigration() async throws {
        let db = try await session.cfg.container.database()
        let rows = try await db.query("SELECT object,version,revision FROM drop_uploads WHERE substr(body,1,1)=x'7b'")
        for row in rows {
            guard let object = row.text("object").flatMap(ID16.init(hex:)), let n = row.int("version"), n > 0, n <= Int64(UInt32.max),
                  let revision = row.int("revision") else { continue }
            let version = UInt32(n)
            try await check()
            guard let body = try await db.query("SELECT body FROM drop_uploads WHERE object=? AND version=? AND revision=?",
                                                [.text(object.hex), .int(n), .int(revision)]).first?.blob("body") else { continue }
            guard let legacy = DropFrame.legacyParts(body), let frame = try? DropFrame.encode(descriptor: legacy.descriptor, wraps: legacy.wraps, blob: legacy.blob) else {
                try await db.execute("UPDATE drop_uploads SET done=2,failure='malformed' WHERE object=? AND version=? AND revision=? AND done=0", [.text(object.hex), .int(n), .int(revision)])
                continue
            }
            let oldKey = Self.legacyAbandonmentKey(object, version, body), newKey = Self.abandonmentKey(object, version, descriptor: legacy.descriptor)
            try await db.transaction { tx in
                try tx.execute("UPDATE drop_uploads SET body=? WHERE object=? AND version=? AND revision=? AND substr(body,1,1)=x'7b'",
                               [.blob(frame), .text(object.hex), .int(n), .int(revision)])
                if try !tx.query("SELECT key FROM drop_abandoned WHERE key=?", [.text(oldKey)]).isEmpty {
                    try tx.execute("INSERT OR IGNORE INTO drop_abandoned(key) VALUES(?)", [.text(newKey)])
                }
            }
        }
    }
    // Import retries retain their object identity even when no sealed upload remains.
    private nonisolated static func importAbandonmentKey(_ object: ID16) -> String {
        "import:\(object.hex)"
    }
    public nonisolated var downloadContainer: WorkspaceContainer { session.cfg.container }
    let session: WorkspaceSession
    /// The card the DEK is wrapped to (`wxk`). A 409 `bad_wxk_version` refreshes it once from the relay under the pinned owner key.
    private(set) var card: VerifiedCard
    private let ownerKey: SigningPublicKey?
    let certificates: [ID16: DeviceCertificate]
    public static let maxPlaintextBytes = 25 << 20
    public static let maxVersions = 1024
    /// A file lives 7 days (the relay accepts `(now, now + 7 d + 300 s]`); the phone seals 10 minutes short of that, a margin for clock
    /// skew and for a slow first PUT. Documents carry no expiry.
    public static let fileLifetimeMs: Int64 = 604_800_000
    public static let expiryMarginMs: Int64 = 600_000

    /// `ownerKey` verifies a refreshed card; it defaults to the realm's pinned owner (Live). Without either, a stale `wxk` version
    /// cannot be repaired and the upload waits ("key unavailable") instead.
    public init(session: WorkspaceSession, card: VerifiedCard, certificates: [DeviceCertificate] = [], ownerKey: SigningPublicKey? = nil) throws {
        guard card.workspace == session.workspace, card.wsk == session.cfg.wsk else { throw DropError.unauthorized }
        self.session = session; self.card = card; self.ownerKey = ownerKey ?? session.cfg.context.pinnedOwner
        self.certificates = Dictionary(certificates.map { ($0.deviceID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    package func requireDemo() throws {
        guard session.cfg.context.realm == .demo else { throw RealmViolation.wrongStore }
        try session.cfg.context.generation.check()
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
        _ = try expect(reply, status: status)
        guard let o = try StrictJSON.parse(reply.body, maxBytes: 8 << 20).object,
              Set(o.keys) == fields else { throw DropError.malformed }
        return o
    }

    /// `HostAPI.expect` with the Drop refusals of protocol 19.9 mapped: 410 is final ("expired", never a fork or rollback), a stored-bytes
    /// 429 is "storage full", a rate or slot 429 and a 503 are "retry later", 409 `rotation_required` is "waiting for the host".
    private func expect(_ reply: WireReply, status: Int = 200) throws -> Data {
        guard reply.status == status else { throw Self.mapped(HostAPI.failure(of: reply)) }
        return reply.body
    }

    static let storedBytesQuotas: Set<String> = ["drop_ws", "drop_head_ws", "drop_account", "drop_versions", "drop_documents", "drop_device",
        "drop_device_head", "drop_device_versions", "drop_device_documents", "drop_doc_versions"]

    static func mapped(_ error: ClientError) -> Error {
        guard case .relay(let r) = error else { return error }
        switch (r.status, r.code) {
        case (410, _): return DropError.expired
        case (413, .tooLarge): return DropError.uploadRejected(status: 413)
        case (429, .quotaExceeded):
            // Only the stored-bytes caps of protocol 19.9 are "storage full"; `slot` and any name this client does not know are transient.
            guard let q = r.quota, Self.storedBytesQuotas.contains(q) else { return DropError.retryLater(afterSeconds: r.retryAfter ?? 5) }
            return DropError.storageFull(quota: q, retryAfterSeconds: r.retryAfter ?? 600)
        case (429, _), (503, _): return DropError.retryLater(afterSeconds: r.retryAfter ?? 5)
        case (409, .rotationRequired): return DropError.rotationPending
        default: return error
        }
    }
    private func membership(operate: Bool = false) async throws -> MemberList {
        let s = try await auth()
        try requireAvailable()
        let raw = try await RelayClient(transport: session.cfg.transport).memberList(workspace: card.workspace, session: s)
        let list: MemberList
        do { list = try await session.acceptMemberList(raw) }
        catch let r as Refusal where r == .staleList || r == .conflictingSnapshot || r == .badEpoch || r == .wkCommitConflict || r == .rotationRequired { throw DropError.rollback }
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
    /// The previous descriptors of `d`, read from the first version the persisted chain head does not already vouch for. Pages of
    /// `GET /v2/drop/{o}/descriptors` replace one GET per version per refresh (protocol 19.9); a head is persisted by `acceptDropChain`.
    private func chainPrefix(of d: DropDescriptor, members: MemberList) async throws -> (first: UInt32, previous: [[String: JSONValue]]) {
        guard d.version > 1 else { return (1, []) }
        var first: UInt32 = 1
        if let head = try await session.cfg.container.dropHeadVersion(object: d.object.hex), head <= d.version { first = head }
        guard first < d.version else { return (first, []) }
        var previous: [[String: JSONValue]] = []
        var after = first - 1
        var pages = 0
        while previous.count < Int(d.version - first) {
            pages += 1
            guard pages <= 128 else { throw DropError.tooLarge }
            try await check()
            let s = try await auth()
            try requireAvailable()
            let reply = try await session.cfg.transport.dropDescriptors(objectID: d.object, after: after, limit: nil, session: s)
            let page = try parse(reply, fields: ["descriptors", "next"])
            guard let list = page["descriptors"]?.array, !list.isEmpty, list.count <= 256 else { throw DropError.malformed }
            for signed in list {
                let next = first + UInt32(previous.count)
                if next >= d.version { break }
                let v = try verify(signed, members: members)
                guard v.object == d.object, v.version == next else { throw DropError.integrity }
                previous.append(v.raw)
            }
            after = first - 1 + UInt32(previous.count)
            switch page["next"] {
            case .some(.null): guard previous.count == Int(d.version - first) else { throw DropError.integrity }
            case .some(.int): break
            default: throw DropError.malformed
            }
        }
        return (first, previous)
    }

    private func verified(_ signed: JSONValue, wraps: [JSONValue], members: MemberList, claimedBy: ID16? = nil) async throws -> DropObject {
        let d = try verify(signed, members: members)
        guard d.version <= Self.maxVersions, wraps.count <= 1024 else { throw DropError.tooLarge }
        guard d.expiresMs.map({ $0 > session.cfg.wall.nowMs }) ?? (d.objectKind == "document") else { throw DropError.expired }
        let (first, previous) = try await chainPrefix(of: d, members: members)
        let chain = previous + [d.raw]
        try DropDocument.verifyChain(chain, firstVersion: first)
        switch d.recipients {
        case .ids(let ids): guard ids.contains(card.workspace) || ids.contains(session.cfg.deviceID) else { throw DropError.unauthorized }
        case .inbox: break
        }
        let parsed = try wraps.map(DropWrapRecord.init(json:))
        guard parsed.allSatisfy({ $0.object == d.object && $0.version == d.version }) else { throw DropError.integrity }
        try await check()
        try await session.cfg.container.acceptDropChain(object: d.object.hex, firstVersion: first, chain: chain.map { try DropDescriptor.parentHash(of: $0) })
        return DropObject(descriptor: d, signed: signed, wraps: parsed, claimedBy: claimedBy)
    }

    public func list(_ direction: Direction = .received) async throws -> [DropObject] {
        try await listVerifiedRows(direction).objects
    }

    /// One list entry (protocol 19.9, A1): `{object_id, version, state, descriptor|null, wraps}` plus the optional `n`, `claimed_by` and
    /// `tombstone_until_ms`. Strict on the known keys; a key it does not know makes the entry unusable (it is blocked, not guessed at).
    private struct ListEntry {
        let object: ID16
        let version: UInt32
        let state: String
        let descriptor: JSONValue?
        let wraps: [JSONValue]
        let claimedBy: ID16?
        let tombstoneUntilMs: Int64?

        static let required: Set<String> = ["object_id", "version", "state", "descriptor", "wraps"]
        static let optional: Set<String> = ["n", "claimed_by", "tombstone_until_ms"]

        init(_ value: JSONValue) throws {
            guard let r = value.object, r.allKeysASCII2, Set(r.keys).isSuperset(of: Self.required), Set(r.keys).isSubset(of: Self.required.union(Self.optional)),
                  let object = r["object_id"]?.string.flatMap(ID16.init(hex:)), let v = r["version"]?.int, v >= 1, v <= Int64(UInt32.max),
                  let state = r["state"]?.string, let wraps = r["wraps"]?.array, let descriptor = r["descriptor"] else { throw DropError.malformed }
            self.object = object; self.version = UInt32(v); self.state = state; self.wraps = wraps
            self.descriptor = descriptor.isNull ? nil : descriptor
            switch r["claimed_by"] {
            case nil, .some(.null): claimedBy = nil
            case .some(.string(let h)): guard let id = ID16(hex: h) else { throw DropError.malformed }; claimedBy = id
            default: throw DropError.malformed
            }
            switch r["tombstone_until_ms"] {
            case nil, .some(.null): tombstoneUntilMs = nil
            case .some(let t): guard let n = t.int, n >= 0 else { throw DropError.malformed }; tombstoneUntilMs = n
            }
            if let n = r["n"] { guard let k = n.int, k >= 0 else { throw DropError.malformed } }
        }
    }

    /// Bounds of one list walk. Live objects (at most 4 096 live versions per workspace) are capped apart from tombstones, which need no
    /// verification and stay listed 30 days: at the relay's 1 000 new objects per workspace per day that is up to 30 000 of them. The
    /// page cap holds both at the relay's 64 per page (640 pages × 64 = 40 960 entries; a page of more than 64 rows is refused); a relay that never ends the walk is `tooLarge`.
    static let maxListPages = 640
    static let maxListObjects = 4096
    static let maxListTombstones = 32768

    public func listVerifiedRows(_ direction: Direction = .received) async throws -> DropListing {
        // Nested operations and unstructured children retain the admitting lifecycle epoch.
        if Self.operationEpoch == nil {
            return try await Self.$operationEpoch.withValue(lifecycleEpoch) { try await self.listVerifiedRows(direction) }
        }
        try requireAvailable()
        try await purgeExpiredDownloads()
        let members = try await membership()
        // Walk `next` from the start (a full list, `after` omitted): positions only move forward, so an object can appear on two pages
        // of one walk (it changed meanwhile); the higher version wins.
        var entries: [ID16: ListEntry] = [:]
        var order: [ID16] = []
        var blockedCount = 0
        var after: Int64?
        var pages = 0
        repeat {
            pages += 1
            guard pages <= Self.maxListPages else { throw DropError.tooLarge }
            var query: [String: JSONValue] = ["workspace_id": .string(card.workspace.hex), "direction": .string(direction.rawValue)]
            if let a = after { query["after"] = .int(a) }
            let s = try await auth()
            try requireAvailable()
            let page = try parse(await session.cfg.transport.dropList(canonicalJSON(.object(query)), session: s), fields: ["objects", "next"])
            guard let rows = page["objects"]?.array, rows.count <= 64 else { throw DropError.tooLarge }
            for row in rows {
                guard let entry = try? ListEntry(row) else {
                    blockedCount += 1
                    guard blockedCount <= Self.maxListObjects else { throw DropError.tooLarge }
                    continue
                }
                if let known = entries[entry.object] { if entry.version >= known.version { entries[entry.object] = entry } }
                else { entries[entry.object] = entry; order.append(entry.object) }
            }
            let tombstones = entries.values.filter { $0.state == "expired" || $0.state == "retired" }.count
            guard entries.count - tombstones <= Self.maxListObjects, tombstones <= Self.maxListTombstones else { throw DropError.tooLarge }
            switch page["next"] {
            case .some(.null): after = nil
            case .some(.int(let n)):
                // a cursor that does not move would walk forever
                guard n >= 0, after.map({ n > $0 }) ?? true, !rows.isEmpty else { throw DropError.malformed }
                after = n
            default: throw DropError.malformed
            }
        } while after != nil
        var result: [DropObject] = []
        var blocked: [String] = (0..<blockedCount).map { "blocked-\(direction.rawValue)-entry-\($0)" }
        var gone: [DropGone] = []
        for (index, id) in order.enumerated() {
            let entry = entries[id]!
            do {
                switch entry.state {
                case "live":
                    guard let signed = entry.descriptor else { throw DropError.malformed }
                    let v = try await verified(signed, wraps: entry.wraps, members: members, claimedBy: entry.claimedBy)
                    guard v.descriptor.object == entry.object, v.descriptor.version == entry.version else { throw DropError.integrity }
                    guard (direction == .sending) == (v.descriptor.authorID == session.cfg.deviceID) else { throw DropError.unauthorized }
                    result.append(v)
                case "expired", "retired":
                    // A tombstone carries no descriptor and no wraps: anything else is not what the relay promised.
                    guard entry.descriptor == nil, entry.wraps.isEmpty else { throw DropError.malformed }
                    gone.append(DropGone(object: entry.object, version: entry.version, reason: entry.state == "retired" ? .retired : .expired,
                                         tombstoneUntilMs: entry.tombstoneUntilMs))
                default:
                    // `pruned` (the newest blob is gone) and any state this client does not know: not live, never opened.
                    gone.append(DropGone(object: entry.object, version: entry.version, reason: .unavailable, tombstoneUntilMs: entry.tombstoneUntilMs))
                }
            } catch {
                switch error {
                case DropError.malformed, DropError.integrity, DropError.rollback, DropError.unauthorized, DropError.expired, DropError.tooLarge,
                     is Refusal, is DropDocument.Fork, is CryptoFailure, is CryptoKitError, DropStoreError.rollback:
                    blocked.append("blocked-\(direction.rawValue)-\(index)")
                default: throw error
                }
            }
        }
        try await check()
        return DropListing(objects: result, blocked: blocked, gone: gone)
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

    /// Atomically commits a whole compose send after checking signed membership. No upload occurs during sealing.
    /// Object identities bind workspace, send UUID and attachment UUID; retries reuse stored ciphertext.
    public func sealSend(_ sendID: UUID, attachments: [DropSendAttachment]) async throws -> [DropUploadIdentity] {
        if Self.operationEpoch == nil {
            return try await Self.$operationEpoch.withValue(lifecycleEpoch) { try await self.sealSend(sendID, attachments: attachments) }
        }
        try await check()
        guard !attachments.isEmpty, attachments.count <= 5,
              Set(attachments.map(\.id)).count == attachments.count,
              attachments.reduce(0, { $0 + $1.data.count }) <= Self.maxPlaintextBytes else { throw DropError.tooLarge }
        let members = try await membership(operate: true)
        let epoch = members.epoch, wk = try await session.dropSealKey(epoch)
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
                now: now, expiry: DropUpload.addMs(now, Self.fileLifetimeMs - Self.expiryMarginMs))
            sealed.append((hex, body))
            try await hook?("send.sealed:\(sealed.count)")
        }
        let db = try await session.cfg.container.database()
        try await check()
        let batch = sealed
        try await hook?("send.persist")
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
        let isDocument = kind == .document || document != nil
        let expiry: Int64?
        if isDocument {
            guard expiresMs == nil else { throw DropError.malformed }      // a document never expires (the host retires it)
            expiry = nil
        } else {
            let e = expiresMs ?? DropUpload.addMs(now, Self.fileLifetimeMs - Self.expiryMarginMs)
            guard e > now, e <= DropUpload.addMs(now, Self.fileLifetimeMs) else { throw DropError.expired }
            expiry = e
        }
        let object = chosenObject ?? document?.descriptor.object ?? session.cfg.entropy.id16()
        if chosenObject != nil { try await requireActive(Self.importAbandonmentKey(object)) }
        if chosenObject != nil, try await session.cfg.container.database().query("SELECT object FROM drop_uploads WHERE object=? AND version=1", [.text(object.hex)]).first != nil {
            return try await upload(object: object, version: 1)
        }
        let parent = document?.descriptor.version ?? 0
        guard parent < Self.maxVersions, document == nil || document?.descriptor.objectKind == "document" else { throw DropError.malformed }
        let (epoch, wk) = try await session.dropSealKey()            // head-based, as the bridge (not the lagging high-water mark)
        try await check()
        let body = try DropUpload.seal(data, metadata: DropMetadata(name: name, mime: mime, size: Int64(data.count), transcript: transcript),
            object: object, workspace: card.workspace, author: session.cfg.deviceID, authorKind: "device", signer: session.cfg.identity.sig,
            wxk: card.wxk, wxkVersion: card.wxkVersion, sender: session.cfg.identity.publicKeys.kx, wk: wk, epoch: epoch,
            now: now, expiry: expiry, parent: document?.descriptor, kind: kind.rawValue)
        let sealedDescriptor = try DropFrame.parseHead(body.prefix(DropFrame.prefixLength + DropFrame.maxHeadBytes), total: body.count).descriptor
        let db = try await session.cfg.container.database()
        try await check()
        try await db.transaction { tx in
            // Recheck atomically with persistence in case discard ran while sealing.
            guard try tx.query("SELECT key FROM drop_abandoned WHERE key=?", [.text(Self.importAbandonmentKey(object))]).isEmpty else { throw DropError.abandoned }
            guard try tx.query("SELECT key FROM drop_abandoned WHERE key=?", [.text(Self.abandonmentKey(object, parent + 1, descriptor: sealedDescriptor))]).isEmpty else { throw DropError.abandoned }
            try tx.execute("INSERT OR IGNORE INTO drop_uploads(object,version,body,done) VALUES(?,?,?,0)", [.text(object.hex), .int(Int64(parent + 1)), .blob(body)])
            guard let stored = try tx.query("SELECT body FROM drop_uploads WHERE object=? AND version=?", [.text(object.hex), .int(Int64(parent + 1))]).first?.blob("body") else { throw DropError.malformed }
            if chosenObject == nil && stored != body { throw DropError.conflict }
        }
        return try await upload(object: object, version: parent + 1)
    }

    /// Recover every pending row independently; a stale uncommitted body has its `wk` wrap re-wrapped (same DEK, same blob), never resealed.
    public func resumeUploads() async throws -> [DropUploadResult] {
        // Nested operations and unstructured children retain the admitting lifecycle epoch.
        if Self.operationEpoch == nil {
            return try await Self.$operationEpoch.withValue(lifecycleEpoch) { try await self.resumeUploads() }
        }
        try requireAvailable()
        try await check()
        try await migrateLegacyUploads()
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
                await self.clearBackoff(key)
                try await db.execute("UPDATE drop_uploads SET done=0,failure=NULL WHERE object=? AND version=? AND (done=2 OR (done=0 AND failure IS NOT NULL))", [.text(object.hex), .int(Int64(version))])
            }
            try await self.honourBackoff(key)
            return try await self.uploadCurrent(object: object, version: version)
        }
        uploads[key] = Operation(id: id, epoch: lifecycleEpoch, task: task)
        defer { if uploads[key]?.id == id { uploads[key] = nil } }
        return try await task.value
    }

    private var backoffs: [String: (untilMs: Int64, error: DropError)] = [:]
    private func clearBackoff(_ key: String) { backoffs[key] = nil }
    /// A relay back-off (`Retry-After`, a full quota) is honoured without a request: the same error until it has passed.
    private func honourBackoff(_ key: String) throws {
        guard let b = backoffs[key] else { return }
        if session.cfg.wall.nowMs >= b.untilMs { backoffs[key] = nil } else { throw b.error }
    }
    private func recordBackoff(_ key: String, _ error: DropError) {
        let seconds: Int
        switch error {
        case .storageFull(_, let s): seconds = s
        case .retryLater(let s): seconds = s
        case .possiblyRemoved: seconds = 3600
        default: return
        }
        backoffs[key] = (DropUpload.addMs(session.cfg.wall.nowMs, Int64(max(1, seconds)) * 1000), error)
    }

    // Reload only after admission. Each recursive rewrap gets its own revision-scoped outcome.
    private func uploadCurrent(object: ID16, version: UInt32, attempt: Int = 0) async throws -> DropObject {
        try await requireActiveUpload(object, version)
        let db = try await session.cfg.container.database()
        guard let head = try await loadHead(db, object, version) else { throw DropError.abandoned }
        guard head.done != 2 else { throw DropError.conflict }
        do { return try await performUpload(object: object, version: version, head: head, attempt: attempt) }
        catch {
            guard var e = error as? DropError else { throw error }
            // A relay status is a hint: `expired` ends a pending upload for good only when the SIGNED expiry has passed here too.
            // Otherwise the row stays pending behind a long back-off and is flagged for the user (no endless re-GET).
            var terminal = e.terminalUpload
            if e == .expired {
                terminal = (head.parts.descriptor.object?["o"]?.object?["expires_ms"]?.int).map { $0 <= session.cfg.wall.nowMs } ?? false
                if !terminal {
                    e = .possiblyRemoved
                    try await check()
                    try? await db.execute("UPDATE drop_uploads SET failure='possibly_removed' WHERE object=? AND version=? AND revision=? AND done=0",
                                          [.text(object.hex), .int(Int64(version)), .int(head.revision)])
                }
            }
            recordBackoff("upload:\(object.hex):\(version)", e)
            if terminal {
                try await check()
                try await db.execute("UPDATE drop_uploads SET done=2,failure=? WHERE object=? AND version=? AND revision=? AND done=0", [.text(String(describing: e)), .text(object.hex), .int(Int64(version)), .int(head.revision)])
            }
            throw e
        }
    }

    /// Pending uploads the relay claims are gone while their signed expiry has not passed ("Removed by the host? Retry or discard").
    /// Data only: they stay `done=0`, so `retryUpload`/`discardUpload` and a later `resumeUploads` still work.
    public func stalledUploads() async throws -> [DropUploadFailure] {
        if Self.operationEpoch == nil {
            return try await Self.$operationEpoch.withValue(lifecycleEpoch) { try await self.stalledUploads() }
        }
        try requireAvailable()
        try await check()
        let rows = try await session.cfg.container.database().query("SELECT object,version,failure FROM drop_uploads WHERE done=0 AND failure IS NOT NULL")
        return try rows.map { row in
            guard let id = row.text("object").flatMap(ID16.init(hex:)), let n = row.int("version"), n > 0, n <= UInt32.max else { throw DropError.malformed }
            return DropUploadFailure(object: id, version: UInt32(n), reason: row.text("failure") ?? "stalled")
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

    /// Only these uploads have passed the signed-descriptor read-back (canonical bytes equal to what was sealed).
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
        try await migrateLegacyUploads()
        try await hook?("discard.upload.admitted")
        let db = try await session.cfg.container.database()
        try await check()
        try await db.transaction { tx in
            if try !tx.query("SELECT object FROM drop_imports WHERE object=?", [.text(object.hex)]).isEmpty {
                try tx.execute("INSERT OR IGNORE INTO drop_abandoned(key) VALUES(?)", [.text(Self.importAbandonmentKey(object))])
            } else if let head = try tx.query("SELECT substr(body,1,?) AS head, length(body) AS n FROM drop_uploads WHERE object=? AND version=?",
                                              [.int(Int64(DropFrame.prefixLength + DropFrame.maxHeadBytes)), .text(object.hex), .int(Int64(version))]).first,
                      let bytes = head.blob("head"), let n = head.int("n"), let parts = try? DropFrame.parseHead(bytes, total: Int(n)) {
                try tx.execute("INSERT OR IGNORE INTO drop_abandoned(key) VALUES(?)", [.text(Self.abandonmentKey(object, version, descriptor: parts.descriptor))])
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

    static let stagePrefix = "orch-drop-"
    /// Staged frames live in their own directory, so the sweep never walks the shared temp directory.
    static var stageDirectory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("orch-drop-staging", isDirectory: true) }
    /// Staging files older than this are leftovers of a crashed run (an upload lasts at most the Drop deadline cap, 660 s).
    static let stageMaxAge: TimeInterval = RoutedRelayTransport<NWRequestSender>.dropDeadline(bytes: DropFrame.maxBlobBytes) + 5 * 60

    /// Removes leftover staged frames at service start. Only files older than `stageMaxAge`, so a second service in the process keeps its
    /// in-flight upload.
    private func sweepStagedFrames() async throws {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default, dir = Self.stageDirectory
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where url.lastPathComponent.hasPrefix(Self.stagePrefix) {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if Date().timeIntervalSince(modified) > Self.stageMaxAge { try? fm.removeItem(at: url) }
            }
        }.value
    }

    private static let windowBytes = 1 << 20
    /// The blob/frame of a stored upload in 1 MiB `substr` windows (never whole), from byte `from` (0-based) of a body of `total` bytes.
    /// The revision is part of every query, so a row that changed mid-way ends the read instead of mixing two bodies.
    private func forEachWindow(_ object: ID16, _ version: UInt32, revision: Int64, from: Int = 0, total: Int, _ body: (Data) async throws -> Void) async throws {
        let db = try await session.cfg.container.database()
        var offset = from
        while offset < total {
            try await check()
            let n = min(Self.windowBytes, total - offset)
            guard let w = try await db.query("SELECT substr(body,?,?) AS w FROM drop_uploads WHERE object=? AND version=? AND revision=?",
                                             [.int(Int64(offset + 1)), .int(Int64(n)), .text(object.hex), .int(Int64(version)), .int(revision)]).first?.blob("w"),
                  w.count == n else { throw DropError.abandoned }
            try await body(w)
            offset += n
        }
    }

    /// The stored frame written to a private temp file, so the PUT streams it from disk: the phone never holds the 26 MiB. It is copied in
    /// 1 MiB `substr` windows, and the file IO runs off the actor. The bytes are sealed ciphertext; the file goes when the request ended.
    private func stageFrame(_ object: ID16, _ version: UInt32, revision: Int64, total: Int) async throws -> URL {
        try? FileManager.default.createDirectory(at: Self.stageDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = Self.stageDirectory.appendingPathComponent(Self.stagePrefix + UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
            throw CocoaError(.fileWriteUnknown)         // local disk trouble: not a key problem, not terminal
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try await forEachWindow(object, version, revision: revision, total: total) { window in
                try await Task.detached(priority: .utility) { try handle.write(contentsOf: window) }.value
            }
        } catch { try? FileManager.default.removeItem(at: url); throw error }
        return url
    }

    /// Re-wrap the same DEK, never reseal: the descriptor and blob stay (so the relay sees the same `cj(o)`), and the `wk` wrap moves to
    /// the current epoch and/or the `wxk` wrap to the current card version. The frame's head is rewritten in SQL, the blob untouched.
    private func rewrapStored(_ object: ID16, _ version: UInt32, head: StoredHead, descriptor: DropDescriptor, records: [DropWrapRecord],
                              epoch: UInt32, wk: Bool, wxk: Bool) async throws {
        guard let dek = try await openKey(records, descriptor: descriptor) else { throw DropError.unavailableKey }
        var wraps = records
        if wk {
            wraps.removeAll { $0.targetKind == .wk && $0.target == card.workspace && $0.keyVersion != epoch }
            if !wraps.contains(where: { $0.targetKind == .wk && $0.target == card.workspace && $0.keyVersion == epoch }) {
                let key = try await session.dropSealKey(epoch)
                wraps.append(try DropWrap.wrapWithSecret(kind: .wk, secret: key, target: card.workspace, keyVersion: epoch, object: object, version: version, dek: dek))
            }
        }
        if wxk {
            wraps.removeAll { $0.targetKind == .wxk && $0.target == card.workspace && $0.keyVersion != card.wxkVersion }
            if !wraps.contains(where: { $0.targetKind == .wxk && $0.target == card.workspace && $0.keyVersion == card.wxkVersion }) {
                wraps.append(try DropWrap.wrapToKey(kind: .wxk, to: card.wxk, target: card.workspace, keyVersion: card.wxkVersion, object: object, version: version, dek: dek))
            }
        }
        let prefix = try DropFrame.prefix(descriptor: head.parts.descriptor, wraps: wraps.map(\.json))
        let db = try await session.cfg.container.database()
        try await check()
        // The stored blob must still be what the signed descriptor commits to before this row is rewritten around it.
        var hash = SHA256()
        try await forEachWindow(object, version, revision: head.revision, from: head.parts.blobOffset, total: head.total) { hash.update(data: $0) }
        guard Data(hash.finalize()) == descriptor.contentHash else { throw DropError.integrity }
        // SQLite has no blob concatenation: `||` yields text with the same bytes, `CAST ... AS BLOB` makes it a blob again. The length is
        // checked inside the transaction, so a frame that did not come out byte-exact never replaces the sealed one.
        let expected = prefix.count + head.parts.blobLength, blobOffset = head.parts.blobOffset + 1, revision = head.revision
        try await db.transaction { tx in
            let changed = try tx.execute("UPDATE drop_uploads SET body=CAST(? || substr(body,?) AS BLOB),revision=revision+1 WHERE object=? AND version=? AND revision=? AND done=0",
                                         [.blob(prefix), .int(Int64(blobOffset)), .text(object.hex), .int(Int64(version)), .int(revision)])
            guard changed == 1 else { throw DropError.abandoned }
            guard try tx.query("SELECT length(body) AS n FROM drop_uploads WHERE object=? AND version=?", [.text(object.hex), .int(Int64(version))]).first?.int("n") == Int64(expected) else {
                throw DropError.integrity
            }
        }
    }

    /// 409 `bad_wxk_version`: the card this phone holds is stale. Fetch the current card once, verify it under the pinned owner and
    /// accept it only as a forward step of the held one (`checkSnapshot`); the caller then re-wraps the same DEK.
    private func refreshCard() async throws {
        guard let ownerKey else { throw DropError.unavailableKey }
        let s = try await auth()
        try requireAvailable()
        let json = try await RelayClient(transport: session.cfg.transport).card(workspace: card.workspace, session: s)
        let next: VerifiedCard
        do {
            next = try Card.verify(json, ownerKey: ownerKey)
            guard next.workspace == card.workspace, next.wsk == card.wsk, next.relayURL.utf8Equal(card.relayURL) else { throw DropError.unauthorized }
            try Card.checkSnapshot(known: card.head, next: next)
        } catch is Refusal { throw DropError.unavailableKey }
        try await check()
        // the same card again cannot explain the refusal: nothing to repair, wait
        guard next.wxkVersion != card.wxkVersion || next.wxk != card.wxk else { throw DropError.unavailableKey }
        card = next
    }

    private func performUpload(object: ID16, version: UInt32, head: StoredHead, attempt: Int) async throws -> DropObject {
        let members = try await membership(operate: true)
        let s = try await auth()
        let parts = head.parts
        let signed = parts.descriptor
        guard parts.blobLength <= DropFrame.maxBlobBytes else { throw DropError.malformed }
        let descriptor = try verify(signed, members: members)
        guard descriptor.object == object, descriptor.version == version, descriptor.contentLen == Int64(parts.blobLength) else { throw DropError.malformed }
        let records = try parts.wraps.map(DropWrapRecord.init(json:))
        // Everything below talks to the relay. Only what is derived from the LOCAL row may fail an upload for good (malformed, too large);
        // an answer the relay shaped badly is a reason to retry later, never to stamp the sealed row failed.
        do {
            return try await reconcileUpload(object: object, version: version, head: head, attempt: attempt, members: members, session: s,
                                             signed: signed, descriptor: descriptor, records: records)
        } catch DropError.malformed, DropError.tooLarge, is JSONError, ClientError.badReply {
            throw DropError.retryLater(afterSeconds: 60)
        }
    }

    private func reconcileUpload(object: ID16, version: UInt32, head: StoredHead, attempt: Int, members: MemberList, session s: RelaySession,
                                 signed: JSONValue, descriptor: DropDescriptor, records: [DropWrapRecord]) async throws -> DropObject {
        let parts = head.parts
        var stored = false
        let existing = try await get(object, version, .descriptor)
        switch existing.status {
        case 200:
            // Already there: with exactly this descriptor the upload is done; with another the version was taken.
            let committed = try parse(existing, fields: ["descriptor"])
            guard try canonicalJSON(committed["descriptor"]!) == canonicalJSON(signed) else { throw DropError.versionConflict(current: version) }
            stored = true
        case 404:
            // The slot is empty. A `wk` wrap below the signed list's epoch is re-wrapped under the current one (same DEK, same blob).
            if records.contains(where: { $0.targetKind == .wk && $0.target == card.workspace && $0.keyVersion < members.epoch }) {
                try await rewrapStored(object, version, head: head, descriptor: descriptor, records: records, epoch: members.epoch, wk: true, wxk: false)
                return try await uploadCurrent(object: object, version: version, attempt: attempt)
            }
            guard descriptor.expiresMs.map({ $0 > session.cfg.wall.nowMs }) ?? true else { throw DropError.expired }
        case 403: throw DropError.uploadRejected(status: 403)
        default: _ = try expect(existing)
        }
        var conflictCurrent: UInt32?
        var putSaidGone = false
        if !stored {
            do {
                try await requireActiveUpload(object, version)
                try await check()
                let file = try await stageFrame(object, version, revision: head.revision, total: head.total)
                defer { try? FileManager.default.removeItem(at: file) }
                let reply = try await session.cfg.transport.dropPut(objectID: object, ifMatch: version - 1, bodyFile: file, session: s)
                switch reply.status {
                case 200, 201:
                    // 201 first write, 200 an exact retry (the relay recognised the stored descriptor)
                    guard try parse(reply, fields: ["version"], status: reply.status)["version"] == .int(Int64(version)) else { throw DropError.malformed }
                case 409:
                    switch HostAPI.failure(of: reply) {
                    case .relay(let r) where r.code == .versionConflict: conflictCurrent = r.current
                    case .relay(let r) where r.code == .staleEpoch:
                        // The list moved between the signed fetch and this PUT. The hint is only a reason to refetch the SIGNED list (bounded);
                        // its epoch value is never used. The next round re-wraps under the epoch the signed list confirms.
                        guard attempt < 2 else { throw DropError.retryLater(afterSeconds: 30) }
                        do { _ = try await session.refetchForEpochHint() }
                        catch SessionError.epochRefetchDeferred(let ms) { throw DropError.retryLater(afterSeconds: max(1, Int((ms + 999) / 1000))) }
                        return try await uploadCurrent(object: object, version: version, attempt: attempt + 1)
                    case .relay(let r) where r.code == .badWxkVersion:
                        guard attempt < 2 else { throw DropError.retryLater(afterSeconds: 30) }
                        try await refreshCard()
                        try await rewrapStored(object, version, head: head, descriptor: descriptor, records: records, epoch: members.epoch, wk: false, wxk: true)
                        return try await uploadCurrent(object: object, version: version, attempt: attempt + 1)
                    case .relay(let r) where r.code == .rotationRequired || r.code == .wrapConflict: throw Self.mapped(.relay(r))
                    default: break         // anything else: reconcile by reading the descriptor back
                    }
                case 410: putSaidGone = true        // unauthenticated: reconcile by the descriptor read-back below; it decides, not the status
                case 429: _ = try expect(reply, status: 201)
                // A session that expired (401), a route the relay does not have (404) or a timeout (408) says nothing about the sealed bytes.
                case 401, 404, 408: throw DropError.retryLater(afterSeconds: 30)
                case 400..<500: throw DropError.uploadRejected(status: reply.status)
                default: _ = try expect(reply, status: 201)
                }
            } catch let error as TransportError {
                // A body cut off past the response cap is as unknown as a lost connection: the commit may have happened, so read back.
                if error != .disconnected && error != .responseTooLarge { throw error }
            }
        }
        // Confirm by the descriptor only: it binds `content_hash`, which the relay checked against the bytes it stored.
        let readBack = try await get(object, version, .descriptor)
        if readBack.status == 404, let conflictCurrent { throw DropError.versionConflict(current: conflictCurrent) }
        if readBack.status == 403 { throw DropError.uploadRejected(status: 403) }
        if readBack.status == 404, putSaidGone { throw DropError.expired }      // handled by the caller as a hint (never terminal alone)
        let committed = try parse(readBack, fields: ["descriptor"])
        guard try canonicalJSON(committed["descriptor"]!) == canonicalJSON(signed) else {
            if let conflictCurrent { throw DropError.versionConflict(current: conflictCurrent) }
            throw DropError.conflict
        }
        // The signed-descriptor read-back confirms the upload; record that first, so a later bad chain page cannot fail a stored upload.
        try await check()
        try await self.session.cfg.container.database().execute("UPDATE drop_uploads SET done=1,failure=NULL WHERE object=? AND version=? AND revision=? AND done=0", [.text(object.hex), .int(Int64(version)), .int(head.revision)])
        return try await verified(signed, wraps: parts.wraps, members: membership())
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
        _ = try expect(blob)
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
                             wk: SymmetricKey, epoch: UInt32, now: Int64, expiry: Int64?, parent: DropDescriptor? = nil, kind: String = "file") throws -> Data {
        let version = (parent?.version ?? 0) + 1
        let dek = SymmetricKey(size: .bits256)
        let blob = try DropBlob.encrypt(dek: dek, object: object, version: version, plaintext: data)
        let meta = try metadata.seal(dek: dek, object: object, version: version)
        guard meta.count <= Drop.maxMetaBytes + 16, blob.count <= DropFrame.maxBlobBytes else { throw DropError.tooLarge }
        let raw: [String: JSONValue] = ["v": 2, "suite": 2, "kind": "drop_object", "object_id": .string(object.hex),
            "space_id": .string(workspace.hex), "space_kind": "workspace", "object_kind": .string(parent == nil ? kind : "document"),
            "version": .int(Int64(version)), "parent": .int(Int64(version - 1)),
            "parent_hash": try parent.map { .string(B64U.encode(try DropDescriptor.parentHash(of: $0.raw))) } ?? .null,
            "author_kind": .string(authorKind), "author_id": .string(author.hex), "content_hash": .string(B64U.encode(Data(SHA256.hash(data: blob)))),
            "content_len": .int(Int64(blob.count)), "dek_commit": .string(B64U.encode(DropKeys.dekCommit(object: object, version: version, dek: dek))),
            "meta": .string(B64U.encode(meta)), "recipients": .array([.string(workspace.hex)]), "origin": .string(authorKind == "workspace" ? "agent" : "human"),
            "created_ms": .int(now), "expires_ms": expiry.map { .int($0) } ?? .null]
        var wraps = [try DropWrap.wrapToKey(kind: .wxk, to: wxk, target: workspace, keyVersion: wxkVersion, object: object, version: version, dek: dek),
                     try DropWrap.wrapWithSecret(kind: .wk, secret: wk, target: workspace, keyVersion: epoch, object: object, version: version, dek: dek)]
        if let sender { wraps.append(try DropWrap.wrapToKey(kind: .device, to: sender, target: author, keyVersion: 0, object: object, version: version, dek: dek)) }
        return try DropFrame.encode(descriptor: SignedObject.sign(raw, kind: .dropObject, signer: signer).json, wraps: wraps.map(\.json), blob: blob)
    }
}
