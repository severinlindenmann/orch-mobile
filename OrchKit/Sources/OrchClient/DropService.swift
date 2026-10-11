import CryptoKit
import Foundation
import OrchCustody
import OrchProtocol
import OrchShareStaging
import OrchStore

public enum DropError: Error, Equatable, Sendable {
    case malformed, unauthorized, expired, integrity, rollback, conflict, tooLarge, unavailableKey
}

/// A descriptor is exposed only after author, workspace and document-chain verification.
public struct DropObject: Sendable, Equatable {
    public let descriptor: DropDescriptor
    public let signed: JSONValue
    public let wraps: [DropWrapRecord]
}

/// Workspace-scoped Drop client. Other-device certificates must be verified by the caller against
/// the workspace owner before being supplied; membership is checked against a signed member list.
public actor DropService {
    public enum Direction: String, Sendable { case received, sending }
    public enum Kind: String, Sendable { case file, document }
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

    private func auth() async throws -> RelaySession { try await session.dropRelaySession() }
    private func check() async throws { try await session.ensureCurrent() }
    private func parse(_ reply: WireReply, fields: Set<String>, status: Int = 200) throws -> [String: JSONValue] {
        _ = try HostAPI.expect(reply, status: status)
        guard let o = try StrictJSON.parse(reply.body, maxBytes: 8 << 20).object,
              Set(o.keys) == fields.union(["host_api"]), o["host_api"] == 0 else { throw DropError.malformed }
        return o
    }
    private func membership() async throws -> MemberList {
        let s = try await auth()
        let raw = try await RelayClient(transport: session.cfg.transport).memberList(workspace: card.workspace, session: s)
        let list = try MemberList.verify(raw, wsk: card.wsk)
        guard list.workspace == card.workspace, list.members.contains(where: { $0.deviceID == session.cfg.deviceID && ($0.scopeStrings?.contains("look") ?? false) }) else { throw DropError.unauthorized }
        guard list.epoch >= (try await session.currentEpoch()) else { throw DropError.rollback }
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
        let members = try await membership(), s = try await auth()
        let query: JSONValue = ["host_api": 0, "workspace_id": .string(card.workspace.hex), "direction": .string(direction.rawValue)]
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
    /// plaintext is deleted only after every item's durable upload has been confirmed by read-back.
    public func importShareJob(_ job: StagedJob, inbox: ShareInbox) async throws -> [DropObject] {
        try await check()
        guard job.manifest.realm.utf8.elementsEqual(session.cfg.context.realm.rawValue.utf8),
              job.manifest.ws.utf8.elementsEqual(card.workspace.hex.utf8), job.manifest.generation == session.generation else { throw DropError.unauthorized }
        let db = try await session.cfg.container.database()
        var result: [DropObject] = []
        for (i, item) in job.manifest.items.enumerated() {
            let fresh = session.cfg.entropy.id16()
            try await db.execute("INSERT OR IGNORE INTO drop_imports(job,item,object) VALUES(?,?,?)", [.text(job.manifest.jobID), .int(Int64(i)), .text(fresh.hex)])
            guard let id = try await db.query("SELECT object FROM drop_imports WHERE job=? AND item=?", [.text(job.manifest.jobID), .int(Int64(i))]).first?.text("object").flatMap(ID16.init(hex:)) else { throw DropError.malformed }
            let data = try inbox.contents(of: item, in: job)
            result.append(try await sendData(data, name: item.name, mime: item.kind == .url ? "text/uri-list" : (item.kind == .text ? "text/plain" : "application/octet-stream"),
                transcript: job.manifest.note, expiresMs: nil, document: nil, chosenObject: id))
        }
        try await check()
        inbox.complete(job)
        return result
    }

    public func send(_ data: Data, name: String, mime: String = "application/octet-stream", transcript: String? = nil,
                     expiresMs: Int64? = nil, kind: Kind = .file, document: DropObject? = nil) async throws -> DropObject {
        try await sendData(data, name: name, mime: mime, transcript: transcript, expiresMs: expiresMs, document: document, chosenObject: nil, kind: kind)
    }

    /// Fresh DEK per version. The exact sealed upload is durable before the first PUT.
    private func sendData(_ data: Data, name: String, mime: String, transcript: String?,
                     expiresMs: Int64?, document: DropObject?, chosenObject: ID16?, kind: Kind = .file) async throws -> DropObject {
        try await check()
        guard data.count <= Self.maxPlaintextBytes else { throw DropError.tooLarge }
        let now = session.cfg.wall.nowMs
        let expiry = expiresMs ?? DropUpload.addMs(now, 604800000)
        guard expiry > now, expiry <= DropUpload.addMs(now, 604800000) else { throw DropError.expired }
        let object = chosenObject ?? document?.descriptor.object ?? session.cfg.entropy.id16()
        if chosenObject != nil, let row = try await session.cfg.container.database().query("SELECT body FROM drop_uploads WHERE object=? AND version=1", [.text(object.hex)]).first, let body = row.blob("body") {
            return try await upload(object: object, version: 1, body: body)
        }
        let parent = document?.descriptor.version ?? 0
        guard parent < Self.maxVersions, document == nil || document?.descriptor.objectKind == "document" else { throw DropError.malformed }
        let epoch = try await session.currentEpoch()
        let wk = try await session.dropKey(epoch)
        let body = try DropUpload.seal(data, metadata: DropMetadata(name: name, mime: mime, size: Int64(data.count), transcript: transcript),
            object: object, workspace: card.workspace, author: session.cfg.deviceID, authorKind: "device", signer: session.cfg.identity.sig,
            wxk: card.wxk, wxkVersion: card.wxkVersion, sender: session.cfg.identity.publicKeys.kx, wk: wk, epoch: epoch,
            now: now, expiry: expiry, parent: document?.descriptor, kind: kind.rawValue)
        let db = try await session.cfg.container.database()
        try await db.execute("INSERT INTO drop_uploads(object,version,body,done) VALUES(?,?,?,0)", [.text(object.hex), .int(Int64(parent + 1)), .blob(body)])
        return try await upload(object: object, version: parent + 1, body: body)
    }

    /// Retry durable uploads without resealing or allocating a different object.
    public func resumeUploads() async throws -> [DropObject] {
        try await check()
        let rows = try await session.cfg.container.database().query("SELECT object,version,body FROM drop_uploads WHERE done=0")
        var result: [DropObject] = []
        for row in rows {
            guard let id = row.text("object").flatMap(ID16.init(hex:)), let n = row.int("version"), n > 0, n <= UInt32.max, let body = row.blob("body") else { throw DropError.malformed }
            result.append(try await upload(object: id, version: UInt32(n), body: body))
        }
        return result
    }
    private func upload(object: ID16, version: UInt32, body: Data) async throws -> DropObject {
        let s = try await auth()
        guard let o = try StrictJSON.parse(body, maxBytes: 36 << 20).object,
              Set(o.keys) == ["host_api", "descriptor", "wraps", "blob"], o["host_api"] == 0,
              let signed = o["descriptor"], let wraps = o["wraps"]?.array, wraps.count <= 1024,
              let blobText = o["blob"]?.string, let expectedBlob = B64U.decode(blobText), expectedBlob.count <= 26 << 20 else { throw DropError.malformed }
        do {
            let reply = try await session.cfg.transport.dropPut(objectID: object, ifMatch: version - 1, body: body, session: s)
            if reply.status != 409 { _ = try parse(reply, fields: ["version"], status: 201) }
        } catch let error as TransportError {
            if error != .disconnected { throw error }
        }
        // Always read back: a lost 201 or a stale retry is successful only for these exact committed bytes.
        let committed = try parse(await get(object, version, .descriptor), fields: ["descriptor"])
        let blob = try await get(object, version, .blob)
        _ = try HostAPI.expect(blob)
        guard try canonicalJSON(committed["descriptor"]!) == canonicalJSON(signed),
              expectedBlob == blob.body else { throw DropError.conflict }
        let result = try await verified(signed, wraps: wraps, members: membership())
        try await session.cfg.container.database().execute("UPDATE drop_uploads SET done=1 WHERE object=? AND version=?", [.text(object.hex), .int(Int64(version))])
        return result
    }

    /// The phone asks the host to claim; only the host signs the §10.5 claim.
    public func claim(_ object: DropObject) async throws {
        guard object.descriptor.recipients == .inbox else { throw DropError.malformed }
        _ = try await verified(object.signed, wraps: object.wraps.map(\.json), members: membership())
        let response = try await session.exchange(meta: ["op": "drop_rewrap", "object_id": .string(object.descriptor.object.hex),
                                                        "version": .int(Int64(object.descriptor.version))])
        guard response.status == 200 else { throw DropError.conflict }
        try await check()
    }

    public func download(_ object: DropObject) async throws -> URL {
        let members = try await membership()
        let current = try await verified(object.signed, wraps: object.wraps.map(\.json), members: members)
        let d = current.descriptor
        var wraps = current.wraps
        var dek = try await openKey(wraps, descriptor: d)
        if dek == nil {
            let response = try await session.exchange(meta: ["op": "drop_rewrap", "object_id": .string(d.object.hex), "version": .int(Int64(d.version))])
            guard response.status == 200 else { throw DropError.unavailableKey }
            _ = try await session.refreshGrants()
            let o = try parse(await get(d.object, d.version, .wraps), fields: ["wraps"])
            guard let raw = o["wraps"]?.array, raw.count <= 1024 else { throw DropError.malformed }
            wraps = try raw.map(DropWrapRecord.init(json:))
            dek = try await openKey(wraps, descriptor: d)
        }
        guard let dek else { throw DropError.unavailableKey }
        let blob = try await get(d.object, d.version, .blob)
        _ = try HostAPI.expect(blob)
        guard blob.body.count <= 26 << 20, d.contentLen == Int64(blob.body.count), d.matches(blob: blob.body) else { throw DropError.integrity }
        let metadata = try DropMetadata.open(sealed: d.meta, dek: dek, object: d.object, version: d.version)
        let plaintext = try DropBlob.decrypt(dek: dek, object: d.object, version: d.version, blob: blob.body, maxBytes: 26 << 20)
        guard metadata.size == plaintext.count, plaintext.count <= Self.maxPlaintextBytes else { throw DropError.integrity }
        try await check()
        return try await session.cfg.container.writeDrop(plaintext, object: d.object.hex, version: d.version)
    }
    private func openKey(_ wraps: [DropWrapRecord], descriptor d: DropDescriptor) async throws -> SymmetricKey? {
        for w in wraps {
            guard w.object == d.object, w.version == d.version else { throw DropError.integrity }
            let key: SymmetricKey?
            if w.targetKind == .device, w.target == session.cfg.deviceID, w.keyVersion == 0 {
                key = try DropWrap.unwrap(w, agreement: session.cfg.identity.kx)
            } else if w.targetKind == .wk, w.target == card.workspace, let wk = try? await session.dropKey(w.keyVersion) {
                key = try DropWrap.unwrap(w, with: .wk(wk))
            } else { continue }
            guard let key, DropKeys.dekCommit(object: d.object, version: d.version, dek: key) == d.dekCommit else { throw DropError.integrity }
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
