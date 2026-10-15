import Foundation
import OrchCustody
import OrchProtocol

// H12d, the phone's persisted reader state (host section 9.5, orch-f1 O3 and O5): the highest level declared per workspace and the
// current declaration, kept in the `.keys` vault of the device's own realm (the same keychain group and realm tag as `dk_sig`/`dk_kx`).
// A reinstall drops the keys and this state together; an install-over downgrade is caught by the marker.

/// What the running build can do: the result of its runtime KAT and its build identity. `production` is the real one; tests inject others.
public struct ReaderRuntime: Sendable, Equatable {
    /// nil: the runtime KAT failed, the build declares nothing (level 0).
    public var capability: ReaderKAT.Capability?
    /// The running build, e.g. `1.4 (212)`. A change triggers a fresh `reader.declare` per workspace on first launch (O5).
    public var build: String
    public init(capability: ReaderKAT.Capability?, build: String) { self.capability = capability; self.build = build }
    public var level: Int { capability?.level ?? 0 }
    public static var production: ReaderRuntime { ReaderRuntime(capability: ReaderKAT.current, build: BuildIdentity.current) }
}

public enum BuildIdentity {
    /// `CFBundleShortVersionString (CFBundleVersion)` of the main bundle (the app, or its extension); `unknown` outside a bundle.
    public static var current: String {
        let info = Bundle.main.infoDictionary
        let v = (info?["CFBundleShortVersionString"] as? String) ?? "0"
        let b = (info?["CFBundleVersion"] as? String) ?? "0"
        return "\(v) (\(b))"
    }
}

/// The persisted state of one workspace.
public struct ReaderStateRecord: Equatable, Sendable {
    /// The declaration the host holds (or, if `acked` is false, the one built for the host and not yet confirmed). `rd` is its digest.
    public var decl: ReaderDeclaration?
    /// The highest level this device ever declared for the workspace. Never lowered.
    public var highest: Int
    /// The build that made `decl`.
    public var build: String
    /// The host accepted `decl` (the pairing gate, or an answered `reader.declare`).
    public var acked: Bool
    /// The `digest` of the host's answer to `reader.declare` (`{device, reader, level, digest}`). The host matches `rd` against its STORED
    /// record only, and keeps the stored bytes when it already held the same body under another signature, so once an answer exists this is
    /// the digest `rd` carries; sha256 of a re-signed declaration never is. nil until the first answer (the pair declaration's own digest
    /// is right until then: it is persisted byte for byte).
    public var hostDigest: String?

    public init(decl: ReaderDeclaration?, highest: Int, build: String, acked: Bool, hostDigest: String? = nil) {
        self.decl = decl; self.highest = highest; self.build = build; self.acked = acked; self.hostDigest = hostDigest
    }

    /// The state after this build made `decl` (the marker only ever rises).
    public func recording(_ decl: ReaderDeclaration, build: String, acked: Bool) -> ReaderStateRecord {
        ReaderStateRecord(decl: decl, highest: max(highest, decl.level), build: build, acked: acked)     // a new declaration: no host digest yet
    }

    func encode() throws -> Data {
        var o: [String: JSONValue] = ["v": 1, "highest": .int(Int64(highest)), "build": .string(build), "acked": .bool(acked)]
        if let decl { o["decl"] = decl.json }
        if let hostDigest { o["host_digest"] = .string(hostDigest) }
        return try canonicalJSON(.object(o))
    }

    static func decode(_ data: Data) -> ReaderStateRecord? {
        guard let v = try? StrictJSON.parse(data, maxBytes: 8 * 1024), let o = v.object, o["v"] == .int(1),
              let highest = o["highest"]?.int, highest >= 0, highest <= Int64(ReaderDecl.levelMax),
              let build = o["build"]?.string, let acked = o["acked"]?.bool else { return nil }
        var decl: ReaderDeclaration?
        if let d = o["decl"] {
            guard let parsed = try? ReaderDeclaration(signed: d), parsed.level <= Int(highest) else { return nil }
            decl = parsed
        }
        var hostDigest: String?
        if let h = o["host_digest"] {
            guard let s = h.string, R2.isDigest(s), decl != nil else { return nil }
            hostDigest = s
        }
        return ReaderStateRecord(decl: decl, highest: Int(highest), build: build, acked: acked, hostDigest: hostDigest)
    }
}

public enum ReaderStoreError: Error, Equatable, Sendable {
    /// The record exists but cannot be decoded: the workspace is not opened (fail closed, skip reason `reader_state`).
    case corrupt
    /// The vault is temporarily unreachable (device locked). Not a downgrade and not a skip: retry later.
    case locked
    /// The vault cannot say (any other keychain error). Also retried, never read as "no marker".
    case unavailable
}

public enum ReaderStore {
    static let purpose = "reader.state"

    /// nil: no state (a workspace paired by a build before H12d).
    public static func load(_ vault: RealmVault, ws: ID16) throws -> ReaderStateRecord? {
        let data: Data
        do { data = try vault.get(ws: ws.hex, purpose: purpose) }
        catch VaultError.notFound { return nil }
        catch VaultError.locked { throw ReaderStoreError.locked }
        catch { throw ReaderStoreError.unavailable }
        guard let r = ReaderStateRecord.decode(data) else { throw ReaderStoreError.corrupt }
        return r
    }

    /// Writes inside the realm fence (the vault view is fenced by the caller's context).
    public static func save(_ vault: RealmVault, ws: ID16, _ record: ReaderStateRecord) throws {
        try vault.put(try record.encode(), ws: ws.hex, purpose: purpose)
    }
}

/// The rules over a stored state.
public enum ReaderGate {
    /// The text a screen shows when a workspace is refused for its marker.
    public static let updateMessage = "Update orch to open this workspace"
    /// The stable tag of a refused restore (`RestoreOutcome.skipped`).
    public static let skipReason = "reader_downgrade"

    /// A workspace is opened only by a build whose level is at least the highest this device declared for it (O3).
    public static func opens(_ record: ReaderStateRecord?, runningLevel: Int) -> Bool { runningLevel >= (record?.highest ?? 0) }

    /// O5: the first launch of a new build (or a declaration the host never confirmed) declares again before any other op. A build
    /// whose KAT failed declares nothing.
    public static func needsDeclare(_ record: ReaderStateRecord?, runtime: ReaderRuntime) -> Bool {
        guard runtime.capability != nil else { return false }
        guard let record, record.decl != nil else { return true }
        return record.build != runtime.build || !record.acked
    }

    /// `rd` (protocol 8.6): the digest of the device's current declaration; nil before any (a pre-H12d state, or a level-0 build).
    public static func rd(_ record: ReaderStateRecord?) -> String? { record?.hostDigest ?? record?.decl?.digest }
}

/// The single injection point of `rd` into a column-R request (protocol v2 8.6: a field of the sealed request meta, never read by the
/// relay). R2 (orch-core #467, merged): the field is `rd` in the request meta `{"op","args","idem"?,"rd"?}` (`R2.requestMeta`), and
/// `WorkspaceSessionConfig.sendsReaderDigest` is on for paired (Live and Demo) sessions.
///
/// Semantics: with `overwrite: false` (a same-rid re-seal, a byte-identical resend) a meta that already has `rd` keeps its FIRST value
/// (protocol 8.6: a resend carries the `rd` of its first send); with `overwrite: true` (a NEW rid replacing a refused attempt) the
/// current declaration's `rd` replaces the old one.
///
/// Placement (`Placement`): `metaField` is protocol 8.6, a sibling of `op` in the sealed meta. NOTE for R2: that field sits OUTSIDE what a
/// detached decision signature covers (`Decisions.body`), but the fake host's `Decisions.verifyOp` demands the exact field set
/// `op, decision_id, question_id, content_hash, answer, sig`, so a detached `decision` with `rd` is refused there. 11A.12 retires the
/// detached decision (phones answer with `relay.submit`), so this is moot once R2 lands; if R2 wants `rd` elsewhere, `argsField` puts it
/// inside the `args` object of a `{"t":"req",...,"args":{...}}` frame, and a different placement is a change of this one function.
public enum ReaderRD {
    public enum Placement: Sendable, Equatable { case metaField, argsField }

    public static func inject(into plaintext: Data, rd: String?, overwrite: Bool = false, placement: Placement = .metaField) throws -> Data {
        guard let rd else { return plaintext }
        let (meta, data) = try Bridge.unframe(plaintext)
        guard var m = meta.object else { throw Refusal.malformed }
        switch placement {
        case .metaField:
            if m["rd"] != nil, !overwrite { return plaintext }
            m["rd"] = .string(rd)
        case .argsField:
            guard var args = m["args"]?.object else { return plaintext }
            if args["rd"] != nil, !overwrite { return plaintext }
            args["rd"] = .string(rd)
            m["args"] = .object(args)
        }
        return try Bridge.frame(meta: .object(m), data: data)
    }
}

/// A `reader.declare` ready to send (host 9.11), in the op frame orch-52 fixed:
/// `{"t":"req","id":…,"op":"reader.declare","args":{"reader_decl":{"o":…,"sig":…}},"opts":{"idem":"a_…"}}`, exempt from `rd`.
/// `idem` is derived from the declaration digest (the host is idempotent on `digest`), so a resend of the same declaration is the same
/// request. The answer is `{device, reader, level, digest}` (`ReaderDeclareResult`).
public struct ReaderDeclareRequest: Equatable, Sendable {
    public let declaration: ReaderDeclaration
    /// The op frame's request id (the caller's, e.g. its logical id hex).
    public let id: String
    public init(declaration: ReaderDeclaration, id: String) { self.declaration = declaration; self.id = id }
    public var idem: String { "a_" + String(declaration.digest.dropFirst("sha256:".count).prefix(32)) }
    public var meta: JSONValue {
        ["t": "req", "id": .string(id), "op": "reader.declare", "args": ["reader_decl": declaration.json], "opts": ["idem": .string(idem)]]
    }
}

/// The host's answer to a `reader.declare` (host 9.10/9.11): `{device, reader, level, digest}`.
public struct ReaderDeclareResult: Equatable, Sendable {
    public let device: String, reader: Int, level: Int, digest: String
    public init?(_ v: JSONValue) {
        guard let o = v.object, Set(o.keys) == ["device", "reader", "level", "digest"], let d = o["device"]?.string, let r = o["reader"]?.int,
              let l = o["level"]?.int, let g = o["digest"]?.string, r >= 0, l >= 0 else { return nil }
        device = d; reader = Int(r); level = Int(l); digest = g
    }
}
