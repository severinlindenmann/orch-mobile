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

    public init(decl: ReaderDeclaration?, highest: Int, build: String, acked: Bool) {
        self.decl = decl; self.highest = highest; self.build = build; self.acked = acked
    }

    /// The state after this build made `decl` (the marker only ever rises).
    public func recording(_ decl: ReaderDeclaration, build: String, acked: Bool) -> ReaderStateRecord {
        ReaderStateRecord(decl: decl, highest: max(highest, decl.level), build: build, acked: acked)
    }

    func encode() throws -> Data {
        var o: [String: JSONValue] = ["v": 1, "highest": .int(Int64(highest)), "build": .string(build), "acked": .bool(acked)]
        if let decl { o["decl"] = decl.json }
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
        return ReaderStateRecord(decl: decl, highest: Int(highest), build: build, acked: acked)
    }
}

public enum ReaderStoreError: Error, Equatable, Sendable {
    /// The record exists but cannot be read: the workspace is not opened (fail closed).
    case corrupt
}

public enum ReaderStore {
    static let purpose = "reader.state"

    /// nil: no state (a workspace paired by a build before H12d).
    public static func load(_ vault: RealmVault, ws: ID16) throws -> ReaderStateRecord? {
        let data: Data
        do { data = try vault.get(ws: ws.hex, purpose: purpose) } catch VaultError.notFound { return nil }
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
    public static func rd(_ record: ReaderStateRecord?) -> String? { record?.decl?.digest }
}

/// The single injection point of `rd` into a column-R request (protocol v2 8.6: a field of the sealed request meta, never read by the
/// relay). TODO(R2, orch-core #467): `WorkspaceSessionConfig.sendsReaderDigest` is switched on by the R2 framing wiring; until then
/// no request carries it. Idempotent: a meta that already has `rd` (a re-seal of a request) keeps its first value.
public enum ReaderRD {
    public static func inject(into plaintext: Data, rd: String?) throws -> Data {
        guard let rd else { return plaintext }
        let (meta, data) = try Bridge.unframe(plaintext)
        guard var m = meta.object else { throw Refusal.malformed }
        if m["rd"] != nil { return plaintext }
        m["rd"] = .string(rd)
        return try Bridge.frame(meta: .object(m), data: data)
    }
}

/// A `reader.declare` ready to send (host 9.11): the declaration and the meta that carries it.
/// TODO(R2, orch-core #467): the closed op table of 11A.4 pins the wire spelling of `reader.declare`; this is the proposed one
/// (`{"op":"reader.declare","reader_decl":{...}}`, exempt from `rd`) and lives only here.
public struct ReaderDeclareRequest: Equatable, Sendable {
    public let declaration: ReaderDeclaration
    public var meta: JSONValue { ["op": "reader.declare", "reader_decl": declaration.json] }
}
