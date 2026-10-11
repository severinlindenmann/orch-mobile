import CryptoKit
import Foundation
@testable import OrchProtocol

/// Q10 made `wk_commit` a required member-list field (relay G2b). The copied relay fixtures and p3 vectors (386a6cb) predate it, so
/// their member lists would all be `malformed` now. Until orch-relay publishes the G2b fixtures, the replays upgrade every list
/// signed by `wsk_a` (the only workspace key the fixtures sign lists with) by adding the `wk_commit` of a deterministic test key for
/// its (workspace, epoch) and re-signing it; lists that do not verify under `wsk_a` (the bad-signature and wrong-suite cases) and
/// list objects without a usable workspace or epoch are left as they are, so they fail exactly as before. Two upgraded lists at one
/// epoch carry the same commitment, as an honest host's do, so none of the copied cases changes its outcome (the one case Q10
/// changes is a `caseOverrides` entry in SkipList.swift). Status, headers and response bytes are still compared byte for byte.
///
/// TODO(G2b): delete this shim, re-copy the fixtures and vectors (PROVENANCE.md) and send their bodies unchanged again.
enum PreG2b {
    /// The deterministic stand-in for `WK_epoch` of a fixture workspace.
    static func testWK(_ ws: ID16, _ epoch: UInt32) -> SymmetricKey {
        SymmetricKey(data: Data(SHA256.hash(data: Data("orch-mobile/pre-g2b/wk|".utf8) + ws.bytes + Bytes.u32(epoch))))
    }

    /// `o` with `wk_commit` added, if it is a member-list object without one and with a usable workspace and epoch.
    static func upgrade(_ o: [String: JSONValue]) -> [String: JSONValue] {
        guard o["kind"] == .string("member_list"), o["wk_commit"] == nil, let ws = o["workspace_id"]?.string.flatMap({ ID16(hex: $0) }),
              let e = o["epoch"]?.int, e >= 1, e <= Int64(UInt32.max) else { return o }
        var out = o
        out["wk_commit"] = .string(B64U.encode(WKCommit.compute(workspace: ws, epoch: UInt32(e), wk: testWK(ws, UInt32(e)))))
        return out
    }

    /// A signed list that verifies under `wsk_a`, upgraded and re-signed by it; anything else unchanged.
    static func upgradeSigned(_ signed: JSONValue) throws -> JSONValue {
        let wsk = try PR3Replay.signer("wsk_a.sig")
        guard let o = try? SignedObject.parse(signed).verify(kind: .memberList, key: wsk.publicKey) else { return signed }
        let up = upgrade(o)
        guard up != o else { return signed }
        return try SignedObject.sign(up, kind: .memberList, signer: wsk).json
    }

    /// A membership publication body with its `member_list` upgraded (anything that is not such a body unchanged).
    static func upgradeBody(_ body: JSONValue) throws -> JSONValue {
        guard var b = body.object, let list = b["member_list"] else { return body }
        b["member_list"] = try upgradeSigned(list)
        return .object(b)
    }
}
