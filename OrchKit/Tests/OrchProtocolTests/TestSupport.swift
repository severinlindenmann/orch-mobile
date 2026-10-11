import CryptoKit
import Foundation
import OrchTestVectors
@testable import OrchProtocol

/// Vector access. The file is a test resource copied from orch-relay (Tests/OrchTestVectors/PROVENANCE.md); it is parsed with
/// the module's own strict parser, which doubles as a check that the parser accepts the contract's own data.
enum Vectors {
    static let root: JSONValue = {
        try! StrictJSON.parse(OrchTestVectors.Vectors.data, maxBytes: .max)
    }()
    static var suite2: JSONValue { root["suites"]["2"] }
}

extension JSONValue {
    subscript(_ k: String) -> JSONValue { object?[k] ?? .null }
    subscript(_ i: Int) -> JSONValue { array.flatMap { i < $0.count ? $0[i] : nil } ?? .null }
    var items: [JSONValue] { array ?? [] }
    var str: String { string ?? "" }
    var hexData: Data { Hex.decode(str)! }
    var b64Data: Data { B64U.decode(str)! }
    var i64: Int64 { int ?? -1 }
    var u32: UInt32 { UInt32(int ?? 0) }
    var id: ID16 { ID16(hex: str)! }
    var key: SymmetricKey { SymmetricKey(data: hexData) }
    var sigPub: SigningPublicKey { try! SigningPublicKey(x963: str.count == 130 ? hexData : b64Data) }
    var kxPub: AgreementPublicKey { try! AgreementPublicKey(x963: str.count == 130 ? hexData : b64Data) }
}

/// The vectors' `seed` is not the raw scalar: the reference derives `d = int(seed) mod (n-1) + 1`.
func scalar(fromSeed seed: Data) -> Data {
    let n = Array(Hex.decode("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")!)
    func cmp(_ a: [UInt8], _ b: [UInt8]) -> Int { for (x, y) in zip(a, b) where x != y { return x < y ? -1 : 1 }; return 0 }
    func sub(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var out = a, borrow = 0
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            var d = Int(a[i]) - Int(b[i]) - borrow
            borrow = d < 0 ? 1 : 0
            if d < 0 { d += 256 }
            out[i] = UInt8(d)
        }
        return out
    }
    let nMinus1 = sub(n, [UInt8](repeating: 0, count: 31) + [1])
    var s = Array(seed)
    while cmp(s, nMinus1) >= 0 { s = sub(s, nMinus1) }
    for i in stride(from: 31, through: 0, by: -1) { if s[i] == 255 { s[i] = 0 } else { s[i] += 1; break } }
    return Data(s)
}

func testSigner(_ name: String) throws -> SoftwareSigner {
    try SoftwareSigner(testScalar: scalar(fromSeed: Vectors.suite2["keys"][name]["seed"].hexData))
}

func testAgreer(_ name: String) throws -> SoftwareKeyAgreer {
    try SoftwareKeyAgreer(testScalar: scalar(fromSeed: Vectors.suite2["keys"][name]["seed"].hexData))
}

/// A deterministic test `WK_e` for (workspace, epoch) and the list `wk_commit` that commits it (Q10). Two lists built with it at
/// one epoch carry the same commitment, as an honest host's do.
func testWK(_ ws: ID16, _ epoch: Int64) -> SymmetricKey {
    SymmetricKey(data: Data(SHA256.hash(data: Data("orch-mobile/test/wk|".utf8) + ws.bytes + Bytes.u32(UInt32(epoch)))))
}
func testWKCommit(_ ws: ID16, _ epoch: Int64) -> JSONValue {
    .string(B64U.encode(WKCommit.compute(workspace: ws, epoch: UInt32(epoch), wk: testWK(ws, epoch))))
}
