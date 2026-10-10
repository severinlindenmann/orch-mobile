import CryptoKit
import Foundation
import Testing
@testable import OrchProtocol

@Suite struct AdversarialJSON {
    func ok(_ b: [UInt8]) -> Bool { (try? StrictJSON.parse(Data(b))) != nil }
    func ok(_ s: String) -> Bool { (try? StrictJSON.parse(s)) != nil }
    @Test func parse() {
        #expect(!ok(#"{"a":1,"a":2}"#), "escaped dup")
        #expect(!ok(#"{"é":1}"#), "escaped non-ascii key")
        #expect(!ok(#"{"":1}"#))
        #expect(!ok([0x22, 0xC0, 0xAF, 0x22]), "overlong")
        #expect(!ok([0x22, 0xED, 0xA0, 0x80, 0x22]), "CESU surrogate")
        #expect(!ok([0x22, 0xF4, 0x90, 0x80, 0x80, 0x22]), ">10FFFF")
        #expect(!ok([0x22, 0xFF, 0x22]))
        #expect(!ok([0xEF, 0xBB, 0xBF] + Array("1".utf8)), "BOM")
        #expect(!ok("1e3")); #expect(!ok("1.0")); #expect(!ok("1E3")); #expect(!ok("-")); #expect(!ok("-01"))
        #expect(!ok("+1")); #expect(!ok("NaN")); #expect(!ok("Infinity")); #expect(!ok("-Infinity"))
        #expect(!ok("9007199254740992")); #expect(ok("-9007199254740991")); #expect(!ok("00"))
        #expect(!ok("[1,]")); #expect(!ok(#"{"a":1,}"#)); #expect(!ok("[1 2]")); #expect(!ok("1 2"))
        #expect(!ok(#""\ud800A""#)); #expect(!ok(#""\udc00""#)); #expect(!ok(#""\ud800""#))
        #expect(ok(#""😀""#))
        #expect(!ok([0x22, 0x00, 0x22]), "raw NUL")
        #expect(!ok(#""\x""#)); #expect(!ok(#""\u12""#)); #expect(!ok("\"abc"))
        #expect(!ok("tru")); #expect(!ok("nul"))
        #expect(!ok([0xA0] + Array("1".utf8)), "nbsp ws")
        #expect(ok(String(repeating: "[", count: 16) + String(repeating: "]", count: 16)))
        #expect(!ok(String(repeating: "[", count: 17) + String(repeating: "]", count: 17)))
        #expect(!ok(String(repeating: "[", count: 100000)), "deep no crash")
        // BOM inside string preserved
        let v = try! StrictJSON.parse(Data([0x22, 0xEF, 0xBB, 0xBF, 0x41, 0x22]))
        #expect(try! canonicalJSON(v) == Data([0x22, 0xEF, 0xBB, 0xBF, 0x41, 0x22]))
        // NFD stays NFD through cj
        let nfd = try! StrictJSON.parse("\"e\u{301}\"")
        #expect(try! canonicalJSON(nfd) == Data("\"e\u{301}\"".utf8))
        #expect(try! canonicalJSON(try! StrictJSON.parse("-0")) == Data("0".utf8))
        #expect(try! canonicalJSON(.string("\u{7f}\u{2028}\u{1f}")) == Data("\"\u{7f}\u{2028}\\u001f\"".utf8))
    }
    @Test func equalityIsByteExact() throws {
        // Swift String == is canonical equivalence; JSONValue and the protocol field checks must compare bytes
        #expect("\u{212A}" == "K" as String)                                   // the trap
        #expect(JSONValue.string("\u{212A}") != JSONValue.string("K"))
        #expect(JSONValue.string(";") != JSONValue.string("\u{37E}"))
        #expect(JSONValue.object(["k": "\u{212A}"]) != JSONValue.object(["k": "K"]))
        #expect(JSONValue.array(["\u{37E}"]) != JSONValue.array([";"]))
        #expect(JSONValue.string("a") == JSONValue.string("a"))
        #expect(try canonicalJSON(.string("\u{212A}")) != canonicalJSON(.string("K")))
        #expect(!"\u{212A}".bytesEqual("K") && "K".bytesEqual("K"))
        // protocol checks that compare strings
        #expect(!Scopes.isValid(["look", "decide", "operate", "typ\u{65}\u{301}"]))
        #expect(!Scopes.isValid(["\u{212A}"]))
        let pk = SoftwareSigner()
        let o: [String: JSONValue] = ["v": 2, "suite": 2, "kind": "revocation"]
        let s = try SignedObject.sign(o, kind: .revocation, signer: pk)
        var spoof = s.object; spoof["kind"] = "revocation"
        _ = try s.verify(kind: .revocation, key: pk.publicKey)

        #expect(throws: Refusal.self) { try SignedObject(object: spoof, signature: s.signature).verify(kind: .deviceCert, key: pk.publicKey) }
    }
}

@Suite struct AdversarialSig {
    let n = Array(Hex.decode("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")!)
    func subN(_ s: [UInt8]) -> [UInt8] { // n - s
        var out = n, borrow = 0
        for i in stride(from: 31, through: 0, by: -1) {
            var d = Int(n[i]) - Int(s[i]) - borrow; borrow = d < 0 ? 1 : 0; if d < 0 { d += 256 }; out[i] = UInt8(d)
        }
        return out
    }
    @Test func ranges() throws {
        let s = SoftwareSigner()
        let msg = Data("m".utf8)
        let sig = try Signature.sign(s, label: "L|", message: msg)
        #expect(Signature.verify(s.publicKey, signature: sig, label: "L|", message: msg))
        #expect(!Signature.verify(s.publicKey, signature: sig, label: "M|", message: msg))
        #expect(!Signature.verify(s.publicKey, signature: sig, message: Data("L|m".utf8) + Data([0])))
        let r = Array(sig.prefix(32)), ss = Array(sig.suffix(32))
        #expect(Signature.verify(s.publicKey, signature: Data(r + subN(ss)), label: "L|", message: msg), "high-S twin")
        #expect(!Signature.verify(s.publicKey, signature: Data([UInt8](repeating: 0, count: 32) + ss), label: "L|", message: msg))
        #expect(!Signature.verify(s.publicKey, signature: Data(r + n), label: "L|", message: msg))
        #expect(!Signature.verify(s.publicKey, signature: Data(n + ss), label: "L|", message: msg))
        #expect(!Signature.verify(s.publicKey, signature: Data(r + [UInt8](repeating: 0xff, count: 32)), label: "L|", message: msg))
        #expect(!Signature.verify(s.publicKey, signature: sig + Data([0]), label: "L|", message: msg))
        // off-curve key
        var bad = Array(s.publicKey.x963); bad[64] ^= 1
        #expect((try? SigningPublicKey(x963: Data(bad))) == nil)
        #expect((try? AgreementPublicKey(x963: Data(bad))) == nil)
        #expect((try? SigningPublicKey(x963: Data([4] + [UInt8](repeating: 0, count: 64)))) == nil)
        let p = Array(Hex.decode("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff")!)
        #expect((try? SigningPublicKey(x963: Data([4] + p + p))) == nil)
    }
    @Test func secretLeakViaReflection() throws {
        let k = SoftwareSigner()
        var out = ""; dump(k, to: &out)
        let raw = Hex.encode(k.key.rawRepresentation)
        #expect(!out.lowercased().contains(raw))
        let sk = SymmetricKey(size: .bits256)
        var o2 = ""; dump(sk, to: &o2)
        #expect(!o2.lowercased().contains(Hex.encode(sk.rawBytes)))
        let desc = String(describing: k) + String(reflecting: k)
        #expect(!desc.lowercased().contains(raw))
    }
    @Test func sealBinding() throws {
        let a = SoftwareKeyAgreer(), w = ID16.random(), d = ID16.random()
        let blob = try Sealing.seal(to: a.publicKey, recipientID: d, purpose: .wk, object: w, epoch: 3, plaintext: Data(count: 32))
        #expect((try? Sealing.open(with: a, recipientID: d, purpose: .wk, object: w, epoch: 3, sealed: blob)) != nil)
        #expect((try? Sealing.open(with: a, recipientID: d, purpose: .sk, object: w, epoch: 3, sealed: blob)) == nil)
        #expect((try? Sealing.open(with: a, recipientID: w, purpose: .wk, object: w, epoch: 3, sealed: blob)) == nil)
        #expect((try? Sealing.open(with: a, recipientID: d, purpose: .wk, object: w, epoch: 4, sealed: blob)) == nil)
        #expect((try? Sealing.open(with: a, recipientID: d, purpose: .wk, object: w, epoch: 3, extra: Data([0]), sealed: blob)) == nil)
        // ephemeral substitution with the recipient's own key / invalid point
        var t = Array(blob); t[1] ^= 1
        #expect((try? Sealing.open(with: a, recipientID: d, purpose: .wk, object: w, epoch: 3, sealed: Data(t))) == nil)
        let b2 = try Sealing.seal(to: a.publicKey, recipientID: d, purpose: .wk, object: w, epoch: 3, plaintext: Data(count: 32))
        #expect(blob.prefix(65) != b2.prefix(65), "fresh ephemeral")
        let s1 = try SaltedAEAD.seal(key: SymmetricKey(size: .bits256), msgLabel: "x", aad: Data(), plaintext: Data())
        #expect(s1.count == 32)
        // sliced Data input
        let k = SymmetricKey(size: .bits256)
        let sb = Data([9, 9, 9]) + (try SaltedAEAD.seal(key: k, msgLabel: "x", aad: Data([1]), plaintext: Data("hi".utf8)))
        #expect((try? SaltedAEAD.open(key: k, msgLabel: "x", aad: Data([1]), blob: sb.dropFirst(3))) == Data("hi".utf8))
        #expect((try? SaltedAEAD.open(key: k, msgLabel: "y", aad: Data([1]), blob: sb.dropFirst(3))) == nil)
    }
}
