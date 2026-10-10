import Foundation

/// Test-only access to the protocol vectors copied from orch-relay (see PROVENANCE.md next to this file).
public enum Vectors {
    public static var url: URL { Bundle.module.url(forResource: "vectors_v2", withExtension: "json")! }
    public static var data: Data { try! Data(contentsOf: url) }
}
