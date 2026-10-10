import Foundation

/// Lower-case hex (section 2.2): used for 16-byte ids and nothing else in JSON.
public enum Hex {
    public static func encode(_ d: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        for b in d { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 15)]) }
        return String(decoding: out, as: UTF8.self)
    }

    /// Lower-case hex of an exact byte length; nil on anything else (upper case, odd length, other characters).
    public static func decode(_ s: String, length: Int? = nil) -> Data? {
        let u = Array(s.utf8)
        guard u.count % 2 == 0 else { return nil }
        if let n = length, u.count != 2 * n { return nil }
        func nib(_ c: UInt8) -> UInt8? { c >= 0x30 && c <= 0x39 ? c - 0x30 : (c >= 0x61 && c <= 0x66 ? c - 0x61 + 10 : nil) }
        var out = Data(capacity: u.count / 2)
        for k in stride(from: 0, to: u.count, by: 2) {
            guard let h = nib(u[k]), let l = nib(u[k + 1]) else { return nil }
            out.append(h << 4 | l)
        }
        return out
    }
}

/// Canonical unpadded base64url (section 2.2).
public enum B64U {
    public static func encode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Refuses padding, the standard alphabet, a length of 4k+1 and non-zero trailing bits; checks `length`
    /// when given. Returns nil on any deviation.
    public static func decode(_ s: String, length: Int? = nil) -> Data? {
        let u = Array(s.utf8)
        guard u.allSatisfy({ ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39)
                              || $0 == 0x2D || $0 == 0x5F }), u.count % 4 != 1 else { return nil }
        var std = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        std += String(repeating: "=", count: (4 - std.count % 4) % 4)
        guard let d = Data(base64Encoded: std), encode(d) == s else { return nil }   // re-encoding rejects trailing bits
        if let n = length, d.count != n { return nil }
        return d
    }
}

/// RFC 4648 base32 (alphabet A-Z2-7, no padding), used for the 6-character pairing codes (section 4).
public enum Base32 {
    public static func encode(_ d: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        var out = [UInt8](), buffer = 0, bits = 0
        for b in d {
            buffer = (buffer << 8) | Int(b); bits += 8
            while bits >= 5 { out.append(alphabet[(buffer >> (bits - 5)) & 31]); bits -= 5 }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return String(decoding: out, as: UTF8.self)
    }
}

extension String {
    /// Byte-exact comparison (UTF-8), for protocol fields. Swift `==` is canonical equivalence.
    package func bytesEqual(_ other: String) -> Bool { utf8.elementsEqual(other.utf8) }
    package func bytesHasPrefix(_ prefix: String) -> Bool { utf8.starts(with: prefix.utf8) }
}

/// Saturating `a + b` for clock arithmetic (a hostile or broken clock must not trap).
package func saturatingAdd(_ a: Int64, _ b: Int64) -> Int64 {
    let (r, o) = a.addingReportingOverflow(b)
    return o ? (b > 0 ? Int64.max : Int64.min) : r
}

/// Binary layout helpers (section "Conventions"): big-endian integers and `lp16`.
public enum Bytes {
    public static func u8(_ v: UInt8) -> Data { Data([v]) }
    public static func u32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)]) }
    public static func u64(_ v: UInt64) -> Data { Data((0..<8).map { UInt8((v >> UInt64(56 - 8 * $0)) & 255) }) }
    /// 2-byte length followed by `x`. Precondition: `x.count < 65536`.
    public static func lp16(_ x: Data) -> Data {
        precondition(x.count < 1 << 16, "lp16 input too long")
        return Data([UInt8(x.count >> 8), UInt8(x.count & 255)]) + x
    }
}

/// A 16-byte identifier: 16 raw bytes in binary, 32 lower-case hex characters in text (section 2.1).
public struct ID16: Hashable, Sendable {
    public let bytes: Data
    public init?(bytes: Data) { guard bytes.count == 16 else { return nil }; self.bytes = Data(bytes) }
    public init?(hex: String) { guard let d = Hex.decode(hex, length: 16) else { return nil }; self.bytes = d }
    public var hex: String { Hex.encode(bytes) }
    /// 16 CSPRNG bytes (workspace_id, offer_id, request ids, ...).
    public static func random() -> ID16 {
        var g = SystemRandomNumberGenerator()
        return ID16(bytes: Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &g) }))!
    }
}

extension Bytes {
    /// Big-endian reads at `offset` (Data may be a slice; indices are relative to its start).
    static func readU32(_ d: Data, _ offset: Int) -> UInt32 {
        let b = d.startIndex + offset
        return (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(d[b + $1]) }
    }
    static func readU64(_ d: Data, _ offset: Int) -> UInt64 {
        let b = d.startIndex + offset
        return (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(d[b + $1]) }
    }
}
