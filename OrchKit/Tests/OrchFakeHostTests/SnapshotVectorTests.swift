import CryptoKit
import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchStore
import OrchTestVectors
@testable import OrchFakeHost
@testable import OrchProtocol

/// orch-relay 491b500 `member_list_snapshots` (G2b device rules D1-D4) through the code the phone runs: each case's state is seeded
/// into a real workspace container, and every step goes through `WorkspaceSession` (`acceptMemberListResult`, grant custody,
/// `sealingKey`, `readKey`) as the phone `phone` with the vectors' own keys. After every step the persisted head, the held
/// commitments and the sealing blocks must equal the vector's state.
@Suite struct SnapshotVectorTests {
    static let s2: JSONValue = (try? StrictJSON.parse(Vectors.data, maxBytes: .max, maxDepth: 64))?.object?["suites"]?.object?["2"] ?? .null

    /// The vectors' `seed` is not the raw scalar: the reference derives `d = int(seed) mod (n-1) + 1`.
    static func scalar(fromSeed seed: Data) -> Data {
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
    static func seed(_ name: String) -> Data { scalar(fromSeed: Hex.decode(s2.object!["keys"]!.object![name]!.object!["seed"]!.string!)!) }

    static func state(_ c: WorkspaceContainer) async throws -> JSONValue {
        var head: JSONValue = .null
        let commits = try await c.wkCommits()
        if let h = try await c.memberListHeadRecord() {
            head = ["list_seq": .int(h.listSeq), "epoch": .int(h.epoch), "list_hash": .string(B64U.encode(h.digest)),
                    "wk_commit": commits[h.epoch].map { .string(B64U.encode($0)) } ?? .null, "members": .array(h.members.map { .string($0) })]
        }
        var map: [String: JSONValue] = [:]
        for (e, v) in commits { map[String(e)] = .string(B64U.encode(v)) }
        return ["head": head, "wk_commits": .object(map), "sealing_blocked": .array(try await c.sealingBlocked().map { .int($0) })]
    }

    static func seed(_ c: WorkspaceContainer, _ st: JSONValue) async throws {
        let db = try await c.database()
        if let h = st.object?["head"]?.object {
            try await db.execute("INSERT INTO member_list_head(id, list_seq, epoch, digest, members) VALUES(1,?,?,?,?)",
                                 [.int(h["list_seq"]!.int!), .int(h["epoch"]!.int!), .blob(B64U.decode(h["list_hash"]!.string!)!),
                                  .text(h["members"]!.array!.map { $0.string! }.sorted().joined(separator: ","))])
        }
        for (e, v) in st.object?["wk_commits"]?.object ?? [:] {
            try await db.execute("INSERT INTO wk_commits(epoch, wk_commit) VALUES(?,?)", [.int(Int64(e)!), .blob(B64U.decode(v.string!)!)])
        }
        for e in st.object?["sealing_blocked"]?.array ?? [] { try await db.execute("INSERT INTO sealing_blocked(epoch) VALUES(?)", [.int(e.int!)]) }
    }

    static func code(_ error: Error, read epoch: UInt32? = nil, mismatched: Set<UInt32> = []) -> String {
        switch error {
        case let r as Refusal: return r.rawValue
        // D4: on a read, an offered grant the held list does not commit is `wk_commit_mismatch` (it was not kept)
        case SessionError.noKeyForEpoch: return epoch.map { mismatched.contains($0) } == true ? "wk_commit_mismatch" : "no_key"
        case SessionError.wkCommitMismatch: return "wk_commit_mismatch"
        default: return "\(error)"
        }
    }

    @Test func memberListSnapshots() async throws {
        let cases = Self.s2.object!["member_list_snapshots"]!.array!
        #expect(cases.count == 13)
        var steps = 0
        for c in cases {
            let co = c.object!, name = co["name"]!.string!
            let w = try await World.make(publish: false)
            let ws = ID16(hex: co["card_workspace_id"]!.string!)!
            try await w.env.index.addWorkspace(ws: ws.hex, generation: 1)
            let container = try await WorkspaceContainer(index: w.env.index, ws: ws.hex, generation: 1)
            let identity = DeviceIdentity(sig: try SoftwareSigner(testScalar: Self.seed("phone.sig")),
                                          kx: try SoftwareKeyAgreer(testScalar: Self.seed("phone.kx")), realm: .demo)
            let clock = TestClock()
            let cfg = WorkspaceSessionConfig(context: w.env.context, workspace: ws, generation: 1, identity: identity,
                                             wsk: try SigningPublicKey(x963: Hex.decode(co["wsk_pub"]!.string!)!), container: container,
                                             vault: w.vault.scoped(to: .demo), transport: w.transport, clock: clock, wall: clock)
            let session = try await WorkspaceSession(cfg)
            try await Self.seed(container, co["state"]!)
            #expect(try await Self.state(container) == co["state"]!, "\(name) seeded state")
            for (i, st) in co["steps"]!.array!.enumerated() {
                let so = st.object!, want = so["expect"]!, id = "\(name) step \(i) \(so["op"]!.string!)"
                var got: JSONValue
                switch so["op"]!.string! {
                case "list":
                    do {
                        let r = try await session.acceptMemberListResult(so["signed"]!)
                        got = ["ok": .string(r.advanced ? "advanced" : "noop")]
                    } catch let r as Refusal {
                        got = r == .conflictingSnapshot || r == .wkCommitConflict ? ["alarm": .string(r.rawValue)] : ["refuse": .string(r.rawValue)]
                    }
                case "seal":
                    _ = try await session.ingestGrants(so["grants"]!.array!)
                    do {
                        let k = try await session.sealingKey()
                        got = ["ok": ["epoch": .int(Int64(k.epoch)), "wk": .string(Hex.encode(k.key.withUnsafeBytes { Data($0) }))]]
                    } catch { got = ["refuse": .string(Self.code(error))] }
                default:   // read
                    let e = UInt32(so["epoch"]!.int!)
                    let mismatched = try await session.ingestGrants(so["grants"]!.array!)
                    do {
                        let k = try await session.readKey(e)
                        got = ["ok": ["epoch": .int(Int64(e)), "wk": .string(Hex.encode(k.withUnsafeBytes { Data($0) }))]]
                    } catch { got = ["refuse": .string(Self.code(error, read: e, mismatched: mismatched))] }
                }
                #expect(got == want, "\(id): \(got)")
                #expect(try await Self.state(container) == so["state"]!, "\(id) state")
                steps += 1
            }
        }
        #expect(steps > 13)
    }
}
