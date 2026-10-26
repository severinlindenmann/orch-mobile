import Foundation

/// Test-only access to the protocol vectors copied from orch-relay (see PROVENANCE.md next to this file).
public enum Vectors {
    public static var url: URL { Bundle.module.url(forResource: "vectors_v2", withExtension: "json")! }
    public static var data: Data { try! Data(contentsOf: url) }

    /// orch-hub `vectors/vectors_hub.json` (hub contract H0, FAKE keys; see PROVENANCE.md).
    public static var hub: Data { try! Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("vectors_hub.json")) }

    /// `origin_http.json`: the shared plain-http origin rule (copied from orch-hub `vectors/origin_http.json`).
    public static var originHTTP: Data { try! Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("origin_http.json")) }

    /// The pin of `vectors_hub.json`: `hub_repo`, `hub_commit`, `vectors_hub_sha256` lines (written by scripts/sync-hub-vectors.sh).
    public static var hubSource: String { try! String(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("vectors_hub.SOURCE"), encoding: .utf8) }

    /// The H12d reader_decl group of orch-relay's vectors (suite 2, trimmed; see PROVENANCE.md).
    public static var readerDecl: Data { try! Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("reader_decl_vectors.json")) }

    /// F1 vectors from orch-core `plugins/orch-core/tests/vectors/f1/` (see PROVENANCE.md), by file name without extension.
    public static func f1(_ name: String) -> Data {
        try! Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("f1/\(name).json"))
    }

    /// A non-JSON file of the F1 directory (`core_unicode16.py`).
    public static func f1Raw(_ name: String, ext: String) -> Data {
        try! Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("f1/\(name).\(ext)"))
    }

    /// orch-core R2 framing vectors `plugins/orch-core/tests/relay/r2_vectors/r2_framing.json` (see PROVENANCE.md).
    public static var r2Framing: Data {
        try! Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("r2/r2_framing.json"))
    }
}
