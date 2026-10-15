import Foundation
import OrchProtocol
import OrchTestVectors

extension Fixtures.JSON {
    /// The protocol's JSON value; nil for a float (which the v2 JSON subset forbids).
    var jsonValue: JSONValue? {
        switch self {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .int(i)
        case .double: return nil
        case .string(let s): return .string(s)
        case .array(let a):
            let m = a.compactMap(\.jsonValue)
            return m.count == a.count ? .array(m) : nil
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, v) in o { guard let x = v.jsonValue else { return nil }; out[k] = x }
            return .object(out)
        }
    }
}

/// Every fixture case has a stable id `file.json#case_name`.
func caseID(_ f: Fixtures.File, _ c: Fixtures.Case) -> String { "\(f.fileName)#\(c.name)" }

/// The suite-2 signing public keys of the shared vectors (person, wsk, device and primary keys): the fixtures are signed with them.
func vectorSigningKeys() throws -> [String: SigningPublicKey] {
    let root = try StrictJSON.parse(Vectors.data, maxBytes: .max, maxDepth: 64)
    var out: [String: SigningPublicKey] = [:]
    for (name, k) in root.object?["suites"]?.object?["2"]?.object?["keys"]?.object ?? [:] where name.hasSuffix(".sig") {
        guard let hex = k.object?["pub"]?.string, let d = Hex.decode(hex) else { continue }
        out[name] = try SigningPublicKey(x963: d)
    }
    return out
}
