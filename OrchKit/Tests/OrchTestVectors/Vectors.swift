import Foundation

/// Test-only access to the protocol vectors copied from orch-relay (see PROVENANCE.md next to this file).
public enum Vectors {
    public static var url: URL { Bundle.module.url(forResource: "vectors_v2", withExtension: "json")! }
    public static var data: Data { try! Data(contentsOf: url) }

    /// The H12d reader_decl group of orch-relay's vectors (suite 2, trimmed; see PROVENANCE.md).
    public static var readerDecl: Data { try! Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("reader_decl_vectors.json")) }

    /// F1 vectors from orch-core `plugins/orch-core/tests/vectors/f1/` (see PROVENANCE.md), by file name without extension.
    public static func f1(_ name: String) -> Data {
        try! Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("f1/\(name).json"))
    }

    /// orch-core R2 framing vectors `plugins/orch-core/tests/relay/r2_vectors/r2_framing.json` (see PROVENANCE.md).
    public static var r2Framing: Data {
        try! Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("r2/r2_framing.json"))
    }
}
