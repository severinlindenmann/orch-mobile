import CryptoKit
import Foundation

/// Drop codecs (section 10.1 to 10.6): content blobs, metadata, wraps, version descriptors, claim-once and document
/// chains. Codecs and pure checks only; no routes, no storage.
public enum Drop {
    public static let magic = Data("ORD2".utf8)
    public static let headerLength = 40
    public static let defaultChunkSize = 1 << 20
    public static let maxChunkSize = 64 << 20
    /// Upper bound for one blob held in memory by `decrypt`.
    public static let maxBlobBytes = 256 << 20
    public static let maxMetaBytes = 64 * 1024
}

// MARK: content blob (section 10.2)

public enum DropBlob {
    static func gcmNonce(prefix: Data, index: UInt32) throws -> AES.GCM.Nonce { try AES.GCM.Nonce(data: prefix + Bytes.u32(index)) }

    static func header(object: ID16, version: UInt32, chunkSize: Int, prefix: Data) -> Data {
        Drop.magic + Data([2, Suite2.id, 0, 0]) + object.bytes + Bytes.u32(version) + Bytes.u32(UInt32(chunkSize)) + prefix
    }

    /// `header (40) || chunk_0 || ... `, each chunk AES-256-GCM under `K_content` with nonce `prefix || u32(i)` and AAD
    /// `header || u32(i) || u8(is_last)`. Empty content is one empty last chunk.
    public static func encrypt(dek: SymmetricKey, object: ID16, version: UInt32, plaintext: Data, chunkSize: Int = Drop.defaultChunkSize) throws -> Data {
        var g = SystemRandomNumberGenerator()
        return try encrypt(dek: dek, object: object, version: version, plaintext: plaintext, chunkSize: chunkSize,
                           noncePrefix: Data((0..<8).map { _ in UInt8.random(in: 0...255, using: &g) }))
    }

    /// TEST-ONLY seam for a fixed nonce prefix. A prefix must never repeat under one DEK (the DEK is per version).
    static func encrypt(dek: SymmetricKey, object: ID16, version: UInt32, plaintext: Data, chunkSize: Int, noncePrefix: Data) throws -> Data {
        guard noncePrefix.count == 8, chunkSize > 0, chunkSize <= Drop.maxChunkSize else { throw CryptoFailure.invalidLength }
        let hdr = header(object: object, version: version, chunkSize: chunkSize, prefix: noncePrefix)
        let key = KDF.kDropContent(dek: dek, object: object, version: version)
        let pt = Data(plaintext)
        let n = max(1, (pt.count + chunkSize - 1) / chunkSize)
        var out = hdr
        for i in 0..<n {
            let chunk = pt.subdata(in: min(i * chunkSize, pt.count)..<min((i + 1) * chunkSize, pt.count))
            let aad = hdr + Bytes.u32(UInt32(i)) + Bytes.u8(i == n - 1 ? 1 : 0)
            let box = try AES.GCM.seal(chunk, using: key, nonce: gcmNonce(prefix: noncePrefix, index: UInt32(i)), authenticating: aad)
            out += box.ciphertext + box.tag
        }
        return out
    }

    /// Verifies the header against `(object, version)` and every chunk including the last-chunk flag (truncation fails).
    public static func decrypt(dek: SymmetricKey, object: ID16, version: UInt32, blob: Data, maxBytes: Int = Drop.maxBlobBytes) throws -> Data {
        guard blob.count >= Drop.headerLength + 16, blob.count <= maxBytes else { throw CryptoFailure.invalidLength }
        let b = Data(blob)
        let hdr = b.subdata(in: 0..<Drop.headerLength)
        guard hdr.prefix(4).elementsEqual(Drop.magic), hdr[4] == 2, hdr[5] == Suite2.id, hdr[6] == 0, hdr[7] == 0,
              hdr.subdata(in: 8..<24) == object.bytes, Bytes.readU32(hdr, 24) == version else { throw Refusal.malformed }
        let chunk = Int(Bytes.readU32(hdr, 28))
        guard chunk > 0, chunk <= Drop.maxChunkSize else { throw Refusal.malformed }
        let prefix = hdr.subdata(in: 32..<40)
        let body = b.subdata(in: Drop.headerLength..<b.count)
        let step = chunk + 16
        let n = (body.count + step - 1) / step
        guard n >= 1, body.count - (n - 1) * step >= 16 else { throw CryptoFailure.invalidLength }
        let key = KDF.kDropContent(dek: dek, object: object, version: version)
        var out = Data()
        for i in 0..<n {
            let c = body.subdata(in: i * step..<min((i + 1) * step, body.count))
            let aad = hdr + Bytes.u32(UInt32(i)) + Bytes.u8(i == n - 1 ? 1 : 0)
            let box = try AES.GCM.SealedBox(nonce: gcmNonce(prefix: prefix, index: UInt32(i)), ciphertext: c.dropLast(16), tag: c.suffix(16))
            do { out += try AES.GCM.open(box, using: key, authenticating: aad) } catch { throw CryptoFailure.authenticationFailed }
        }
        return out
    }
}

// MARK: metadata (section 10.2)

public struct DropMetadata: Equatable, Sendable {
    public let name: String
    public let mime: String
    public let size: Int64
    public let transcript: String?
    public init(name: String, mime: String, size: Int64, transcript: String?) {
        self.name = name; self.mime = mime; self.size = size; self.transcript = transcript
    }
    var json: JSONValue {
        ["name": .string(name), "mime": .string(mime), "size": .int(size), "transcript": transcript.map { .string($0) } ?? .null]
    }

    static func aad(object: ID16, version: UInt32) -> Data { Data(Label.aadDropMeta.utf8) + Bytes.u8(Suite2.id) + object.bytes + Bytes.u32(version) }

    /// Zero nonce: the DEK is per version.
    public func seal(dek: SymmetricKey, object: ID16, version: UInt32) throws -> Data {
        try ZeroNonceGCM.seal(key: KDF.kDropMeta(dek: dek, object: object, version: version), plaintext: canonicalJSON(json),
                              aad: Self.aad(object: object, version: version))
    }

    public static func open(sealed: Data, dek: SymmetricKey, object: ID16, version: UInt32) throws -> DropMetadata {
        guard sealed.count <= Drop.maxMetaBytes + 16 else { throw CryptoFailure.invalidLength }
        let pt = try ZeroNonceGCM.open(key: KDF.kDropMeta(dek: dek, object: object, version: version), blob: sealed,
                                       aad: aad(object: object, version: version))
        guard let o = (try? StrictJSON.parse(pt, maxBytes: Drop.maxMetaBytes))?.object, o.hasExactly(["name", "mime", "size", "transcript"]),
              let name = o["name"]?.string, let mime = o["mime"]?.string, let size = o["size"]?.int, size >= 0,
              let t = o["transcript"], t.isNull || t.string != nil else { throw Refusal.malformed }
        return DropMetadata(name: name, mime: mime, size: size, transcript: t.string)
    }
}

public enum DropKeys {
    /// `b64u(H("orch/v2/dek-commit|" || object_id || u32(version) || DEK))`, as bytes.
    public static func dekCommit(object: ID16, version: UInt32, dek: SymmetricKey) -> Data {
        Data(SHA256.hash(data: Data(Label.hDEKCommit.utf8) + object.bytes + Bytes.u32(version) + dek.rawBytes))
    }
}

// MARK: wraps (section 10.3)

public enum DropTargetKind: String, Sendable, CaseIterable { case wk, sk, wxk, device }

public struct DropWrapRecord: Equatable, Sendable {
    public let object: ID16
    public let version: UInt32
    public let targetKind: DropTargetKind
    public let target: ID16
    public let keyVersion: UInt32
    public let wrap: Data

    static let fields: Set<String> = ["object_id", "version", "target_kind", "target_id", "key_version", "wrap"]
    public static let maxWrapBytes = 1024

    public init(object: ID16, version: UInt32, targetKind: DropTargetKind, target: ID16, keyVersion: UInt32, wrap: Data) {
        self.object = object; self.version = version; self.targetKind = targetKind; self.target = target
        self.keyVersion = keyVersion; self.wrap = wrap
    }

    /// Exact field set, hex ids, canonical b64u, integers in range. `key_version` may be 0 for `device` wraps.
    public init(json: JSONValue) throws {
        guard let o = json.object, o.hasExactly(Self.fields), let obj = o.id16("object_id"), let tid = o.id16("target_id"),
              let v = o.positiveU32("version"), let kind = o["target_kind"]?.string.flatMap({ s in DropTargetKind.allCases.first { $0.rawValue.bytesEqual(s) } }),
              let kvRaw = o["key_version"]?.int, kvRaw >= 0, kvRaw <= Int64(UInt32.max),
              let w = o.b64u("wrap"), w.count <= Self.maxWrapBytes else { throw Refusal.malformed }
        self.init(object: obj, version: v, targetKind: kind, target: tid, keyVersion: UInt32(kvRaw), wrap: w)
    }

    public var json: JSONValue {
        ["object_id": .string(object.hex), "version": .int(Int64(version)), "target_kind": .string(targetKind.rawValue),
         "target_id": .string(target.hex), "key_version": .int(Int64(keyVersion)), "wrap": .string(B64U.encode(wrap))]
    }

    /// `"orch/v2/wrap-aad|" || suite || u8(len(kind)) || kind || target_id || object_id || u32(version) || u32(key_version)`
    static func aad(object: ID16, version: UInt32, kind: DropTargetKind, target: ID16, keyVersion: UInt32) -> Data {
        let k = Data(kind.rawValue.utf8)
        return Data(Label.aadWrap.utf8) + Bytes.u8(Suite2.id) + Bytes.u8(UInt8(k.count)) + k + target.bytes + object.bytes
            + Bytes.u32(version) + Bytes.u32(keyVersion)
    }

    static func extra(kind: DropTargetKind, version: UInt32) -> Data { Bytes.u8(kind == .wxk ? 1 : 2) + Bytes.u32(version) }
}

/// The key that unwraps a record: `WK_e`, `SK_e`, or the private key of the addressed `WXK` / device.
public enum DropWrapKey {
    case wk(SymmetricKey)
    case sk(SymmetricKey)
}

public enum DropWrap {
    static func saltedKey(kind: DropTargetKind, secret: SymmetricKey, target: ID16, keyVersion: UInt32) -> SymmetricKey {
        kind == .wk ? KDF.kWrapWK(wk: secret, workspace: target, epoch: keyVersion) : KDF.kWrapSK(sk: secret, space: target, epoch: keyVersion)
    }

    /// `wk` and `sk` wraps are SALTED-AEAD; `wxk` and `device` wraps are seals to the target's key agreement key.
    package static func wrapWithSecret(kind: DropTargetKind, secret: SymmetricKey, target: ID16, keyVersion: UInt32, object: ID16,
                                       version: UInt32, dek: SymmetricKey, salt: Data? = nil) throws -> DropWrapRecord {
        guard kind == .wk || kind == .sk else { throw Refusal.malformed }
        let aad = DropWrapRecord.aad(object: object, version: version, kind: kind, target: target, keyVersion: keyVersion)
        let k = saltedKey(kind: kind, secret: secret, target: target, keyVersion: keyVersion)
        let w = try salt.map { try SaltedAEAD.seal(key: k, msgLabel: Label.kdfWrapMsg, aad: aad, plaintext: dek.rawBytes, salt: $0) }
            ?? SaltedAEAD.seal(key: k, msgLabel: Label.kdfWrapMsg, aad: aad, plaintext: dek.rawBytes)
        return DropWrapRecord(object: object, version: version, targetKind: kind, target: target, keyVersion: keyVersion, wrap: w)
    }

    package static func wrapToKey(kind: DropTargetKind, to pub: AgreementPublicKey, target: ID16, keyVersion: UInt32, object: ID16,
                                  version: UInt32, dek: SymmetricKey) throws -> DropWrapRecord {
        guard kind == .wxk || kind == .device else { throw Refusal.malformed }
        let w = try Sealing.seal(to: pub, recipientID: target, purpose: .dropDEK, object: object, epoch: keyVersion,
                                 extra: DropWrapRecord.extra(kind: kind, version: version), plaintext: dek.rawBytes)
        return DropWrapRecord(object: object, version: version, targetKind: kind, target: target, keyVersion: keyVersion, wrap: w)
    }

    /// Opens a symmetric (`wk`/`sk`) wrap. The record's own fields are the AAD, so a wrap moved to another object,
    /// version, target kind or key version fails.
    public static func unwrap(_ r: DropWrapRecord, with key: DropWrapKey) throws -> SymmetricKey {
        let secret: SymmetricKey
        switch (r.targetKind, key) {
        case (.wk, .wk(let k)), (.sk, .sk(let k)): secret = k
        default: throw Refusal.malformed
        }
        let aad = DropWrapRecord.aad(object: r.object, version: r.version, kind: r.targetKind, target: r.target, keyVersion: r.keyVersion)
        let dek = try SaltedAEAD.open(key: saltedKey(kind: r.targetKind, secret: secret, target: r.target, keyVersion: r.keyVersion),
                                      msgLabel: Label.kdfWrapMsg, aad: aad, blob: r.wrap)
        guard dek.count == 32 else { throw Refusal.malformed }
        return SymmetricKey(data: dek)
    }

    /// Opens a `wxk` or `device` wrap with the addressed key agreement key.
    package static func unwrap(_ r: DropWrapRecord, agreement key: some KeyAgreer) throws -> SymmetricKey {
        guard r.targetKind == .wxk || r.targetKind == .device else { throw Refusal.malformed }
        let dek = try Sealing.open(with: key, recipientID: r.target, purpose: .dropDEK, object: r.object, epoch: r.keyVersion,
                                   extra: DropWrapRecord.extra(kind: r.targetKind, version: r.version), sealed: r.wrap)
        guard dek.count == 32 else { throw Refusal.malformed }
        return SymmetricKey(data: dek)
    }
}

// MARK: version descriptor (section 10.4)

public struct DropDescriptor: Equatable, Sendable {
    public enum Recipients: Equatable, Sendable { case inbox, ids([ID16]) }

    public let object: ID16
    public let space: ID16
    public let spaceKind: String
    public let objectKind: String
    public let version: UInt32
    public let parent: UInt32
    public let parentHash: Data?
    public let authorKind: String
    public let authorID: ID16
    public let contentHash: Data
    public let contentLen: Int64
    public let dekCommit: Data
    public let meta: Data
    public let recipients: Recipients
    public let origin: String
    public let createdMs: Int64
    public let expiresMs: Int64?
    /// The signed `o`, for the parent hash of the next version.
    public let raw: [String: JSONValue]

    static let fields: Set<String> = ["v", "suite", "kind", "object_id", "space_id", "space_kind", "object_kind", "version", "parent",
                                      "parent_hash", "author_kind", "author_id", "content_hash", "content_len", "dek_commit", "meta",
                                      "recipients", "origin", "created_ms", "expires_ms"]
    static func oneOf(_ s: String?, _ allowed: [String]) -> String? { s.flatMap { v in allowed.first { $0.bytesEqual(v) } } }

    /// Shape checks of section 10.4 (field set, enumerations, `version == parent + 1`, files are version 1, `parent_hash`
    /// null exactly at version 1, recipients "inbox" or sorted unique ids). No signature.
    public init(object o: [String: JSONValue]) throws {
        guard o.hasExactly(Self.fields), o["v"] == .int(2), o["suite"] == .int(Int64(Suite2.id)), o["kind"] == .string("drop_object"),
              let obj = o.id16("object_id"), let space = o.id16("space_id"), let author = o.id16("author_id"),
              let sk = Self.oneOf(o["space_kind"]?.string, ["personal", "workspace", "shared"]),
              let ok = Self.oneOf(o["object_kind"]?.string, ["file", "document"]),
              let ak = Self.oneOf(o["author_kind"]?.string, ["device", "workspace"]),
              let origin = Self.oneOf(o["origin"]?.string, ["human", "agent"]),
              let version = o.positiveU32("version"), let parentRaw = o["parent"]?.int, parentRaw >= 0, parentRaw <= Int64(UInt32.max),
              let contentHash = o.b64u("content_hash", length: 32), let dek = o.b64u("dek_commit", length: 32),
              let contentLen = o["content_len"]?.int, contentLen >= 0, let meta = o.b64u("meta"), meta.count <= Drop.maxMetaBytes + 16,
              let created = o["created_ms"]?.int, let expiresValue = o["expires_ms"], let phv = o["parent_hash"], let rv = o["recipients"]
        else { throw Refusal.malformed }
        let parent = UInt32(parentRaw)
        guard Int64(version) == Int64(parent) + 1, !(ok == "file" && version != 1) else { throw Refusal.malformed }
        var parentHash: Data?
        if !phv.isNull {
            guard let s = phv.string, let h = B64U.decode(s, length: 32) else { throw Refusal.malformed }
            parentHash = h
        }
        guard (version == 1) == (parentHash == nil) else { throw Refusal.malformed }
        var recipients = Recipients.inbox
        if let s = rv.string {
            guard s.bytesEqual("inbox") else { throw Refusal.malformed }
        } else {
            guard let list = rv.array, list.count <= 1024 else { throw Refusal.malformed }
            let ids = list.compactMap { $0.string.flatMap { ID16(hex: $0) } }
            guard ids.count == list.count else { throw Refusal.malformed }
            for (a, b) in zip(ids, ids.dropFirst()) where !a.hex.utf8.lexicographicallyPrecedes(b.hex.utf8) { throw Refusal.malformed }
            recipients = .ids(ids)
        }
        var expires: Int64?
        if !expiresValue.isNull { guard let e = expiresValue.int else { throw Refusal.malformed }; expires = e }
        self.object = obj; self.space = space; self.spaceKind = sk; self.objectKind = ok; self.version = version; self.parent = parent
        self.parentHash = parentHash; self.authorKind = ak; self.authorID = author; self.contentHash = contentHash
        self.contentLen = contentLen; self.dekCommit = dek; self.meta = meta; self.recipients = recipients; self.origin = origin
        self.createdMs = created; self.expiresMs = expires; self.raw = o
    }

    /// Verifies the descriptor with the author's key (`bad_signature`), then its shape (`malformed`). The caller must also
    /// check that the author may write to the space, `H(blob)` against `content_hash`, and `dek_commit` after unwrapping.
    public static func verify(_ signed: JSONValue, authorKey: SigningPublicKey) throws -> DropDescriptor {
        let o: [String: JSONValue]
        do { o = try SignedObject.parse(signed).verify(kind: .dropObject, key: authorKey) }
        catch let r as Refusal where r == .badSignature { throw r }
        catch { throw Refusal.badSignature }
        return try DropDescriptor(object: o)
    }

    /// `b64u(H("orch/v2/drop-parent|" || cj(parent descriptor o)))`, as bytes.
    public static func parentHash(of descriptor: [String: JSONValue]) throws -> Data {
        Data(SHA256.hash(data: Data(Label.hDropParent.utf8) + (try canonicalJSON(.object(descriptor)))))
    }

    /// `H(blob)` check against the signed `content_hash` (constant time irrelevant: both public).
    public func matches(blob: Data) -> Bool { Data(SHA256.hash(data: blob)) == contentHash }
}

// MARK: documents and claims (section 10.5 and 10.6): pure checks the relay and the readers apply

public enum DropDocument {
    public struct Fork: Error, Equatable, Sendable { public let at: Int64 }

    /// Fields that name the document: they must not change along a chain (the reference does not say so; see gaps.md).
    static let identityFields = ["object_id", "space_id", "space_kind", "object_kind"]

    static func sameDocument(_ a: [String: JSONValue], _ b: [String: JSONValue]) -> Bool {
        identityFields.allSatisfy { k in a[k] != nil && a[k] == b[k] }
    }

    /// A reader MUST check that each version's `parent_hash` is the hash of the version before it, from version 1 up, and
    /// (stricter than the reference) that every version names the same object, space and kinds as version 1.
    /// `versions` are signature-checked descriptor objects.
    /// TODO(reader slice): a reader must also persist the highest version it has seen per document and treat a lower
    /// "latest" as an error (section 10.6); that state lives outside this pure function.
    public static func verifyChain(_ versions: [[String: JSONValue]]) throws {
        for (i, o) in versions.enumerated() {
            if i > 0, !sameDocument(o, versions[0]) { throw Fork(at: o["version"]?.int ?? -1) }
            let want: JSONValue = i == 0 ? .null : .string(B64U.encode(try DropDescriptor.parentHash(of: versions[i - 1])))
            guard o["version"] == .int(Int64(i + 1)), o["parent_hash"] == want else { throw Fork(at: o["version"]?.int ?? -1) }
        }
    }

    public struct State: Equatable, Sendable {
        public var current: UInt32
        public var head: [String: JSONValue]?
        public init(current: UInt32, head: [String: JSONValue]?) { self.current = current; self.head = head }
    }

    public struct Reply: Equatable, Sendable {
        public let status: Int
        public let error: String?
        public let version: UInt32?
        public let current: UInt32?
    }

    /// `If-Match`: a decimal without leading zeros, at most 16 digits.
    static func parseIfMatch(_ s: String?) -> UInt64? {
        guard let s, !s.isEmpty, s.utf8.count <= 16, s.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              s.utf8.count == 1 || s.utf8.first != 0x30 else { return nil }
        return UInt64(s)
    }

    /// Section 10.6, as the relay applies it (the descriptor's signature is checked before this): `428` for a missing or
    /// malformed `If-Match`; `409 version_conflict` (with `current`) unless `If-Match == current`, `parent == current`,
    /// `version == current + 1` and `parent_hash` is the hash of the current head. On success the state advances.
    public static func checkPut(state: inout State, ifMatch: String?, descriptor new: [String: JSONValue]) -> Reply {
        guard let m = parseIfMatch(ifMatch) else { return Reply(status: 428, error: "precondition_required", version: nil, current: nil) }
        let cur = Int64(state.current)
        let wantParent: JSONValue = state.head.flatMap { try? DropDescriptor.parentHash(of: $0) }.map { .string(B64U.encode($0)) } ?? .null
        let headOK = state.head != nil || state.current == 0
        let sameDoc = state.head.map { sameDocument(new, $0) } ?? true
        guard headOK, sameDoc, m == UInt64(state.current), new["parent"] == .int(cur), new["version"] == .int(cur + 1), new["parent_hash"] == wantParent,
              state.current < UInt32.max else { return Reply(status: 409, error: "version_conflict", version: nil, current: state.current) }
        state.current += 1
        state.head = new
        return Reply(status: 201, error: nil, version: state.current, current: nil)
    }
}

public enum DropClaim {
    public enum ObjectState: Equatable, Sendable { case inbox, claimed(by: ID16) }

    public struct Stored: Equatable, Sendable {
        public var object: ID16
        public var version: UInt32
        public var state: ObjectState
        public var wraps: [DropWrapRecord]
        public init(object: ID16, version: UInt32, state: ObjectState, wraps: [DropWrapRecord]) {
            self.object = object; self.version = version; self.state = state; self.wraps = wraps
        }
    }

    public struct Reply: Equatable, Sendable {
        public let status: Int
        public let error: String?
        public let claimedBy: ID16?
    }

    static let fields: Set<String> = ["v", "suite", "kind", "object_id", "workspace_id", "wrap"]

    /// The claim body signed by the claimer's `WSK`.
    package static func make(wsk: some Signer, object: ID16, workspace: ID16, wrap: DropWrapRecord) throws -> SignedObject {
        try SignedObject.sign(["v": 2, "suite": 2, "kind": "drop_claim", "object_id": .string(object.hex),
                               "workspace_id": .string(workspace.hex), "wrap": wrap.json], kind: .dropClaim, signer: wsk)
    }

    /// Section 10.5, one transaction. `cards` maps a workspace to its `wsk_pub`; `epochs` to its current epoch from the
    /// accepted member list. `stored` changes only on success.
    public static func check(stored: inout Stored, claim: JSONValue, cards: [ID16: SigningPublicKey], epochs: [ID16: UInt32]) -> Reply {
        func fail(_ s: Int, _ e: String) -> Reply { Reply(status: s, error: e, claimedBy: nil) }
        guard let o0 = claim.object?["o"]?.object, let ws = o0.id16("workspace_id"), let key = cards[ws] else { return fail(403, "not_eligible") }
        let o: [String: JSONValue]
        do { o = try SignedObject.parse(claim).verify(kind: .dropClaim, key: key) } catch { return fail(401, "bad_signature") }
        guard o.hasExactly(fields), o.id16("object_id") == stored.object, let record = try? DropWrapRecord(json: o["wrap"] ?? .null),
              record.targetKind == .wk, record.target == ws, record.object == stored.object, record.version == stored.version,
              epochs[ws] == record.keyVersion else { return fail(400, "malformed") }
        switch stored.state {
        case .claimed(let by):
            return by == ws ? Reply(status: 200, error: nil, claimedBy: ws) : Reply(status: 409, error: "already_claimed", claimedBy: by)
        case .inbox:
            guard stored.wraps.contains(where: { $0.targetKind == .wxk && $0.target == ws }) else { return fail(403, "not_eligible") }
            stored.state = .claimed(by: ws)
            stored.wraps = [record]
            return Reply(status: 200, error: nil, claimedBy: ws)
        }
    }
}
