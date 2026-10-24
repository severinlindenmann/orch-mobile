import CryptoKit
import Foundation
import OrchTestVectors
import Testing
@testable import OrchProtocol

@Suite struct EncodingTests {
    @Test func canonicalJSONVectors() throws {
        let cases = Vectors.root["encodings"]["canonical_json"].items
        #expect(cases.count >= 2)
        for c in cases {
            #expect(try canonicalJSON(c["value"]) == c["bytes"].hexData, "\(c["name"].str)")
        }
    }

    @Test func strictParseVectors() throws {
        let cases = Vectors.root["encodings"]["strict_parse"].items
        #expect(cases.count == 15)
        var withCanonical = 0
        for c in cases {
            let parsed = try? StrictJSON.parse(c["text"].str)
            #expect((parsed != nil) == c["ok"].bool, "\(c["name"].str)")
            // Accepted cases that carry a `canonical` string: the parsed value must serialise to exactly those bytes
            // (depth_16, depth_16_objects, and minus_zero where `-0` is written `0`).
            if c["ok"].bool == true, !c["canonical"].isNull, let parsed {
                withCanonical += 1
                #expect(try canonicalJSON(parsed) == Data(c["canonical"].str.utf8), "\(c["name"].str) canonical")
            }
        }
        #expect(withCanonical == 3)
        let byName = Dictionary(uniqueKeysWithValues: cases.map { ($0["name"].str, $0) })
        for n in ["depth_16", "depth_17", "depth_16_objects", "depth_17_objects", "minus_zero"] { #expect(byName[n] != nil, "\(n)") }
        #expect(byName["minus_zero"]?["canonical"].str == "[0]")
    }

    @Test func b64uVectors() {
        let cases = Vectors.root["encodings"]["b64u"].items
        #expect(cases.count == 5)
        for c in cases {
            let got = B64U.decode(c["text"].str)
            if c["bytes"].isNull { #expect(got == nil, "\(c["name"].str)") } else { #expect(got == c["bytes"].hexData, "\(c["name"].str)") }
        }
    }

    @Test func b64uRoundTripAndLength() {
        for n in 0..<40 {
            let d = Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
            #expect(B64U.decode(B64U.encode(d)) == d)
            #expect(B64U.decode(B64U.encode(d), length: n) == d)
            #expect(B64U.decode(B64U.encode(d), length: n + 1) == nil)
        }
        #expect(B64U.decode("AA=") == nil)
        #expect(B64U.decode("AA ") == nil)
        #expect(B64U.decode("") == Data())
    }

    @Test func hexIsLowerCaseAndExactLength() {
        #expect(Hex.decode("00ff", length: 2) == Data([0, 255]))
        #expect(Hex.decode("00FF") == nil)
        #expect(Hex.decode("0", length: 1) == nil)
        #expect(Hex.decode("00ff", length: 3) == nil)
        #expect(Hex.decode("0g") == nil)
        #expect(ID16(hex: String(repeating: "a", count: 31)) == nil)
        #expect(ID16(hex: String(repeating: "A", count: 32)) == nil)
        #expect(ID16(hex: String(repeating: "a", count: 32))?.hex == String(repeating: "a", count: 32))
    }

    @Test func strictParseRefusals() {
        let bad = ["{\"a\":1,\"a\":2}", "{\"a\":1.0}", "{\"a\":1e3}", "{\"a\":1E3}", "{\"a\":-}", "{\"\":1}", "{\"\u{e4}\":1}", "[NaN]",
                   "[Infinity]", "{\"a\":9007199254740992}", "{\"a\":-9007199254740992}", "{\"a\":\"\\ud800\"}", "{\"a\":\"\\udc00\"}",
                   "{} x", "{\"a\":01}", "{\"a\":+1}", "{\"a\":\"\\x\"}", "{\"a\":\"\t\"}", "", "{", "[1,]", "{\"a\":1,}", "'a'"]
        for t in bad { #expect(throws: JSONError.self, "\(t)") { try StrictJSON.parse(t) } }
        #expect(throws: JSONError.self) { try StrictJSON.parse(Data([0x22, 0xFF, 0x22])) }       // invalid UTF-8
        #expect(throws: JSONError.self) { try StrictJSON.parse(Data([0xEF, 0xBB, 0xBF, 0x7B, 0x7D])) }  // BOM before the value
    }

    /// JSONValue must not be ExpressibleByNilLiteral: an optional `JSONValue?` assigned `nil` must stay `nil`, never become JSON null.
    @Test func nilIsNeverJSONNull() {
        let absent: JSONValue? = nil
        #expect(absent == nil)
        var o: JSONValue? = .string("x")
        o = nil
        #expect(o == nil)
        let dict: [String: JSONValue?] = ["a": nil]
        #expect(dict["a"] != nil && dict["a"]! == nil)
        func take(_ v: JSONValue?) -> Bool { v == nil }
        #expect(take(nil))
    }

    @Test func strictParseAccepts() throws {
        #expect(try StrictJSON.parse(" { \"a\" : [ 1 , -0 , true , null ] } ") == ["a": [1, 0, true, .null]])
        #expect(try StrictJSON.parse("{\"a\":-9007199254740991}") == ["a": .int(-maxSafeInt)])
        #expect(try StrictJSON.parse("\"\\ud83d\\ude00\"") == "\u{1F600}")
    }

    @Test func bomInsideAStringIsKept() throws {
        let bytes = Data([0x7B, 0x22, 0x61, 0x22, 0x3A, 0x22, 0xEF, 0xBB, 0xBF, 0x78, 0x22, 0x7D])   // {"a":"<BOM>x"}
        let v = try StrictJSON.parse(bytes)
        #expect(v["a"].string?.unicodeScalars.count == 2)
        #expect(try canonicalJSON(v) == bytes)
    }

    @Test func inputSizeCap() throws {
        let doc = Data("{\"a\":\"\(String(repeating: "x", count: 100))\"}".utf8)
        _ = try StrictJSON.parse(doc, maxBytes: doc.count)
        #expect(throws: JSONError.self) { try StrictJSON.parse(doc, maxBytes: doc.count - 1) }
        #expect(throws: JSONError.self) { try StrictJSON.parse(Data(count: StrictJSON.defaultMaxBytes + 1)) }
        #expect(throws: JSONError.self) { try StrictJSON.parse(String(repeating: " ", count: 65_537) + "{}", maxBytes: 65_536) }
        #expect(StrictJSON.defaultMaxBytes == 1 << 20)
    }

    @Test func nestingLimit() throws {
        func nested(_ levels: Int) -> String { String(repeating: "[", count: levels) + String(repeating: "]", count: levels) }
        _ = try StrictJSON.parse(nested(16))
        #expect(throws: JSONError.self) { try StrictJSON.parse(nested(17)) }
        var v = JSONValue.array([])
        for _ in 0..<15 { v = .array([v]) }
        _ = try canonicalJSON(v)                                  // 16 levels
        #expect(throws: JSONError.self) { try canonicalJSON(.array([v])) }
    }

    @Test func canonicalJSONRefusesWhatStrictParsingWould() {
        #expect(throws: JSONError.self) { try canonicalJSON(.int(maxSafeInt + 1)) }
        #expect(throws: JSONError.self) { try canonicalJSON(["\u{e4}": 1]) }
        #expect(throws: JSONError.self) { try canonicalJSON(["": 1]) }
    }

    @Test func canonicalFormEscapesLikePython() throws {
        let s = "\u{0}\u{1f}\u{7f}\"\\/\u{8}\u{c}\n\r\t\u{2028}\u{e9}"
        let bytes = try canonicalJSON(["k": .string(s)])
        #expect(String(decoding: bytes, as: UTF8.self) == "{\"k\":\"\\u0000\\u001f\u{7f}\\\"\\\\/\\b\\f\\n\\r\\t\u{2028}\u{e9}\"}")
        #expect(try StrictJSON.parse(bytes) == ["k": .string(s)])
    }

    @Test func parseCanonicalRoundTrip() throws {
        let text = "{\"b\":[1,2,{\"z\":null,\"a\":\"x\"}],\"a\":true}"
        let v = try StrictJSON.parse(text)
        #expect(String(decoding: try canonicalJSON(v), as: UTF8.self) == "{\"a\":true,\"b\":[1,2,{\"a\":\"x\",\"z\":null}]}")
    }

    @Test func base32PairingAlphabet() {
        #expect(Base32.encode(Data("foobar".utf8)) == "MZXW6YTBOI")       // RFC 4648 test vector, unpadded
        #expect(Base32.encode(Data("fooba".utf8)) == "MZXW6YTB")
        #expect(Base32.encode(Data()) == "")
    }

    @Test func bytesHelpers() {
        #expect(Bytes.u32(0x01020304) == Data([1, 2, 3, 4]))
        #expect(Bytes.u64(0x0102030405060708) == Data([1, 2, 3, 4, 5, 6, 7, 8]))
        #expect(Bytes.lp16(Data([9, 9, 9])) == Data([0, 3, 9, 9, 9]))
    }
}

@Suite struct ProvenanceTests {
    @Test func vectorsMatchProvenanceSHA256() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OrchTestVectors/PROVENANCE.md")
        let prov = try String(contentsOf: url, encoding: .utf8)
        let digest = Hex.encode(SHA256.hash(data: OrchTestVectors.Vectors.data))
        #expect(prov.contains("sha256: `\(digest)`"))
    }
}

/// The deeper `StrictJSON.parse(_:maxBytes:maxDepth:)` exists only for the vector corpus: no product source may call it.
@Suite struct StrictJSONDepthOverrideTests {
    @Test func noProductCodeUsesTheDepthOverride() throws {
        let kit = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        for dir in [kit.appendingPathComponent("Sources"), kit.deletingLastPathComponent().appendingPathComponent("App"),
                    kit.deletingLastPathComponent().appendingPathComponent("NotificationService")] {
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "swift" && url.lastPathComponent != "JSON.swift" {
                if (try String(contentsOf: url, encoding: .utf8)).contains("maxDepth:") { offenders.append(url.lastPathComponent) }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}

