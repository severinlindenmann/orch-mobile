import Foundation
import OrchTestVectors
@testable import OrchProtocol

/// Access to the orch-core F1 vectors (Tests/OrchTestVectors/f1, PROVENANCE.md). A lone surrogate escape cannot be a Swift string:
/// it is replaced by U+FFFD before parsing and the cases that carry one are skipped by name.
enum F1Vectors {
    static func load(_ name: String) -> JSONValue {
        var text = String(decoding: OrchTestVectors.Vectors.f1(name), as: UTF8.self)
        text = text.replacingOccurrences(of: "\\ud800\"", with: "\\ufffd\"")
        return try! StrictJSON.parse(Data(text.utf8), maxBytes: .max, maxDepth: 64)
    }
    static func signer(_ keys: JSONValue, _ name: String) -> SoftwareSigner {
        try! SoftwareSigner(testScalar: keys[name]["scalar_hex"].hexData)
    }
}
