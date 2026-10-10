import Foundation

/// The JSON subset of protocol v2 section 2.3: objects, arrays, strings, booleans, null and integers in
/// +-(2^53-1). No floats, ASCII non-empty keys, no lone surrogates (impossible in a Swift `String`), nesting at
/// most 16 levels.
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Byte-exact equality: strings compare by UTF-8 bytes, never by Swift's canonical equivalence (U+212A is not "K",
    /// U+037E is not ";"). Signatures and protocol fields are defined over bytes.
    public static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.int(let x), .int(let y)): return x == y
        case (.string(let x), .string(let y)): return x.utf8.elementsEqual(y.utf8)
        case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy { $0 == $1 }
        case (.object(let x), .object(let y)):
            // keys are ASCII (section 2.3), for which String equality is byte equality
            return x.count == y.count && x.allSatisfy { k, v in y[k].map { $0 == v } ?? false }
        default: return false
        }
    }

    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var int: Int64? { if case .int(let i) = self { return i }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
                     ExpressibleByNilLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
    public init(integerLiteral v: Int64) { self = .int(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
}

public let maxSafeInt: Int64 = (1 << 53) - 1
public let maxJSONDepth = 16

/// Strict parser over UTF-8 bytes (section 2.3 "Strict parsing"): refuses duplicate keys, NaN/Infinity, floats
/// (including `1.0` and `1e3`), integers outside the safe range, non-ASCII or empty keys, invalid UTF-8, lone
/// surrogates, trailing bytes and nesting deeper than 16 container levels.
public struct StrictJSON {
    private let b: [UInt8]
    private var i = 0

    public static func parse(_ data: Data) throws -> JSONValue {
        var p = StrictJSON(b: Array(data))
        p.skipWS()
        let v = try p.value(0)
        p.skipWS()
        guard p.i == p.b.count else { throw JSONError(why: "trailing bytes") }
        return v
    }

    public static func parse(_ text: String) throws -> JSONValue { try parse(Data(text.utf8)) }

    private init(b: [UInt8]) { self.b = b }

    private mutating func skipWS() {
        while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
    }

    private func peek() throws -> UInt8 {
        guard i < b.count else { throw JSONError(why: "eof") }
        return b[i]
    }

    private mutating func lit(_ s: String, _ v: JSONValue) throws -> JSONValue {
        let u = Array(s.utf8)
        guard i + u.count <= b.count, Array(b[i..<i + u.count]) == u else { throw JSONError(why: "bad literal") }
        i += u.count
        return v
    }

    /// `depth` is the number of containers that enclose this value.
    private mutating func value(_ depth: Int) throws -> JSONValue {
        switch try peek() {
        case UInt8(ascii: "{"):
            guard depth < maxJSONDepth else { throw JSONError(why: "too deep") }
            i += 1
            var o: [String: JSONValue] = [:]
            skipWS()
            if try peek() == UInt8(ascii: "}") { i += 1; return .object(o) }
            while true {
                skipWS()
                guard try peek() == UInt8(ascii: "\"") else { throw JSONError(why: "key") }
                let k = try str()
                guard !k.isEmpty, k.utf8.allSatisfy({ $0 < 0x80 }) else { throw JSONError(why: "key not ASCII") }
                guard o[k] == nil else { throw JSONError(why: "duplicate key") }
                skipWS()
                guard try peek() == UInt8(ascii: ":") else { throw JSONError(why: "colon") }
                i += 1
                skipWS()
                o[k] = try value(depth + 1)
                skipWS()
                let c = try peek(); i += 1
                if c == UInt8(ascii: "}") { return .object(o) }
                guard c == UInt8(ascii: ",") else { throw JSONError(why: "comma") }
            }
        case UInt8(ascii: "["):
            guard depth < maxJSONDepth else { throw JSONError(why: "too deep") }
            i += 1
            var a: [JSONValue] = []
            skipWS()
            if try peek() == UInt8(ascii: "]") { i += 1; return .array(a) }
            while true {
                skipWS()
                a.append(try value(depth + 1))
                skipWS()
                let c = try peek(); i += 1
                if c == UInt8(ascii: "]") { return .array(a) }
                guard c == UInt8(ascii: ",") else { throw JSONError(why: "comma") }
            }
        case UInt8(ascii: "\""): return .string(try str())
        case UInt8(ascii: "t"): return try lit("true", .bool(true))
        case UInt8(ascii: "f"): return try lit("false", .bool(false))
        case UInt8(ascii: "n"): return try lit("null", .null)
        default: return try number()
        }
    }

    private mutating func number() throws -> JSONValue {
        let start = i
        if try peek() == UInt8(ascii: "-") { i += 1 }
        let ds = i
        while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
        let digits = i - ds
        guard digits > 0, !(digits > 1 && b[ds] == 0x30) else { throw JSONError(why: "number") }
        if i < b.count, b[i] == UInt8(ascii: ".") || b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
            throw JSONError(why: "float")
        }
        guard digits <= 16, let n = Int64(String(decoding: b[start..<i], as: UTF8.self)),
              n >= -maxSafeInt, n <= maxSafeInt else { throw JSONError(why: "integer range") }
        return .int(n)
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= b.count else { throw JSONError(why: "escape") }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = b[i]; i += 1
            switch c {
            case 0x30...0x39: v = v * 16 + UInt32(c - 0x30)
            case 0x41...0x46: v = v * 16 + UInt32(c - 0x41 + 10)
            case 0x61...0x66: v = v * 16 + UInt32(c - 0x61 + 10)
            default: throw JSONError(why: "escape")
            }
        }
        return v
    }

    private mutating func str() throws -> String {
        i += 1 // opening quote
        var out = [UInt8]()
        while true {
            let c = try peek(); i += 1
            switch c {
            case UInt8(ascii: "\""):
                // Validate without transforming: Foundation's String(bytes:encoding:) drops a leading U+FEFF, which
                // would change the bytes a signature covers. Invalid input decodes to U+FFFD and fails the round trip.
                let s = String(decoding: out, as: UTF8.self)
                guard Array(s.utf8) == out else { throw JSONError(why: "utf8") }
                return s
            case 0..<0x20: throw JSONError(why: "control char")
            case UInt8(ascii: "\\"):
                let e = try peek(); i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var cp = try hex4()
                    if (0xD800..<0xDC00).contains(cp) {
                        guard i + 2 <= b.count, b[i] == 0x5C, b[i + 1] == UInt8(ascii: "u") else { throw JSONError(why: "lone surrogate") }
                        i += 2
                        let lo = try hex4()
                        guard (0xDC00..<0xE000).contains(lo) else { throw JSONError(why: "lone surrogate") }
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                    } else if (0xDC00..<0xE000).contains(cp) { throw JSONError(why: "lone surrogate") }
                    guard let sc = Unicode.Scalar(cp) else { throw JSONError(why: "scalar") }
                    out.append(contentsOf: Array(String(Character(sc)).utf8))
                default: throw JSONError(why: "escape")
                }
            default: out.append(c)
            }
        }
    }
}

/// Canonical JSON `cj` (section 2.3): sorted keys, no whitespace, non-ASCII raw, like Python's
/// `json.dumps(sort_keys=True, separators=(",", ":"), ensure_ascii=False)` encoded as UTF-8.
/// Throws if the value leaves the subset (key not non-empty ASCII, integer out of the safe range, too deep), so that
/// a signer cannot produce bytes a strict verifier would refuse.
public func canonicalJSON(_ v: JSONValue) throws -> Data {
    var out = Data()
    func esc(_ s: String) {
        out.append(0x22)
        for u in s.unicodeScalars {
            switch u.value {
            case 0x22: out.append(contentsOf: Array("\\\"".utf8))
            case 0x5C: out.append(contentsOf: Array("\\\\".utf8))
            case 0x0A: out.append(contentsOf: Array("\\n".utf8))
            case 0x0D: out.append(contentsOf: Array("\\r".utf8))
            case 0x09: out.append(contentsOf: Array("\\t".utf8))
            case 0x08: out.append(contentsOf: Array("\\b".utf8))
            case 0x0C: out.append(contentsOf: Array("\\f".utf8))
            case 0..<0x20:
                let h = String(u.value, radix: 16)
                out.append(contentsOf: Array(("\\u" + String(repeating: "0", count: 4 - h.count) + h).utf8))
            default: out.append(contentsOf: Array(String(Character(u)).utf8))
            }
        }
        out.append(0x22)
    }
    func go(_ v: JSONValue, _ depth: Int) throws {
        switch v {
        case .null: out.append(contentsOf: Array("null".utf8))
        case .bool(let b): out.append(contentsOf: Array((b ? "true" : "false").utf8))
        case .int(let n):
            guard n >= -maxSafeInt, n <= maxSafeInt else { throw JSONError(why: "integer range") }
            out.append(contentsOf: Array(String(n).utf8))
        case .string(let s): esc(s)
        case .array(let a):
            guard depth < maxJSONDepth else { throw JSONError(why: "too deep") }
            out.append(0x5B)
            for (k, x) in a.enumerated() { if k > 0 { out.append(0x2C) }; try go(x, depth + 1) }
            out.append(0x5D)
        case .object(let o):
            guard depth < maxJSONDepth else { throw JSONError(why: "too deep") }
            out.append(0x7B)
            // keys are ASCII, so byte order == code point order
            for (k, key) in o.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }).enumerated() {
                guard !key.isEmpty, key.utf8.allSatisfy({ $0 < 0x80 }) else { throw JSONError(why: "key not ASCII") }
                if k > 0 { out.append(0x2C) }
                esc(key); out.append(0x3A); try go(o[key]!, depth + 1)
            }
            out.append(0x7D)
        }
    }
    try go(v, 0)
    return out
}
