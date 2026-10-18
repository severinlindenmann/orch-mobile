import Foundation

/// Test-only access to the relay HTTP v2 examples copied from orch-relay (`http_fixtures/`, see PROVENANCE.md).
/// Schema (README.md there): each file has `contract`, `suite`, `route` (method, path template, role, auth) and `cases`;
/// each case has `name`, `given` (preconditions, never sent), `request` and `response`.
public enum Fixtures {
    public struct Route: Codable, Sendable, Equatable {
        public let method: String
        public let path: String
        public let role: String
        public let auth: String
    }

    /// A parsed JSON tree (no OrchProtocol dependency: this target is a leaf). Integers stay integers.
    public indirect enum JSON: Codable, Sendable, Equatable {
        case null, bool(Bool), int(Int64), double(Double), string(String), array([JSON]), object([String: JSON])

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Int64.self) { self = .int(v) }
            else if let v = try? c.decode(Double.self) { self = .double(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([JSON].self) { self = .array(v) }
            else { self = .object(try c.decode([String: JSON].self)) }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let v): try c.encode(v)
            case .int(let v): try c.encode(v)
            case .double(let v): try c.encode(v)
            case .string(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .object(let v): try c.encode(v)
            }
        }
        public subscript(_ k: String) -> JSON? { if case .object(let o) = self { return o[k] }; return nil }
        public var string: String? { if case .string(let s) = self { return s }; return nil }
        public var int: Int64? { if case .int(let i) = self { return i }; return nil }
        public var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
        public var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    }

    public struct Case: Codable, Sendable {
        public let name: String
        public let given: JSON
        public let request: JSON
        public let response: JSON
    }

    public struct File: Codable, Sendable {
        /// File name without directory, e.g. `session_login.json`; filled by the loader.
        public var fileName: String = ""
        public let contract: String
        public let suite: Int
        public let route: Route
        public let cases: [Case]
        private enum CodingKeys: String, CodingKey { case contract, suite, route, cases }
    }

    public static var directory: URL {
        // Bundle.module's resource URL is only nil for a broken bundle; fall back to a path that fails loudly on first read.
        (Bundle.module.resourceURL ?? URL(fileURLWithPath: "/nonexistent")).appendingPathComponent("http_fixtures", isDirectory: true)
    }

    /// Names of the JSON fixture files (README.md excluded), sorted.
    public static func fileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") && $0 != "MANIFEST.json" }.sorted()
    }

    /// Every file of the copied directory (fixtures, README, the relay's manifest script and `MANIFEST.json`).
    public static func allFileNames() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() }

    public static func rawData(_ fileName: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(fileName)) }

    public static func load(_ fileName: String) throws -> File {
        var f = try JSONDecoder().decode(File.self, from: rawData(fileName))
        f.fileName = fileName
        return f
    }

    public static func loadAll() throws -> [File] { try fileNames().map(load) }

    /// The push registration fixtures (orch-relay 4a9f954, see PROVENANCE.md "push_fixtures"): kept apart from `http_fixtures`, which is
    /// pinned to an older manifest revision.
    public static func loadPush(_ fileName: String) throws -> File {
        let dir = (Bundle.module.resourceURL ?? URL(fileURLWithPath: "/nonexistent")).appendingPathComponent("push_fixtures", isDirectory: true)
        var f = try JSONDecoder().decode(File.self, from: Data(contentsOf: dir.appendingPathComponent(fileName)))
        f.fileName = fileName
        return f
    }
}
