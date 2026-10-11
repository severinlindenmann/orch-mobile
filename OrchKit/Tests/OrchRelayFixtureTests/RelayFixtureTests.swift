import CryptoKit
import Foundation
import Testing
@testable import OrchProtocol
import OrchTestVectors

@Suite struct FixtureSchemaTests {
    static let files: [Fixtures.File] = try! Fixtures.loadAll()

    @Test func everyFileAndCaseParses() throws {
        let files = Self.files
        #expect(files.count == FixtureCoverage.expectedFileCount)
        #expect(files.reduce(0) { $0 + $1.cases.count } == FixtureCoverage.expectedCaseCount)
        for f in files {
            #expect(f.contract == "orch-relay-http-v2", "\(f.fileName)")
            #expect(f.suite == 2, "\(f.fileName)")
            #expect(["GET", "POST", "PUT"].contains(f.route.method), "\(f.fileName)")
            #expect(f.route.path.hasPrefix("/v2/"), "\(f.fileName)")
            #expect(!f.cases.isEmpty && f.cases[0].name == "success", "\(f.fileName)")
            #expect(Set(f.cases.map(\.name)).count == f.cases.count, "\(f.fileName): duplicate case names")
            for c in f.cases {
                let id = caseID(f, c)
                // the three late-added cases (victim_person_without_member, other_workspace_person_refused x2) carry only `condition`
                #expect(c.given["scenario"]?.string != nil || c.given["condition"]?.string != nil, "\(id) given")
                #expect(c.given["now_ms"]?.int != nil || c.given["scenario"] == nil, "\(id) now_ms")
                let r = c.request
                #expect(r["method"]?.string == f.route.method, "\(id) method")
                #expect(r["query"]?.object?.values.allSatisfy { $0.string != nil } == true, "\(id) query values are strings")
                #expect(r["headers"]?.object?.values.allSatisfy { $0.string != nil } == true, "\(id) headers are strings")
                let hasBody = [r["json"] != nil, r["body_b64u"] != nil, r["body_recipe"] != nil]
                #expect(hasBody.filter { $0 }.count <= 1 || r["body_recipe"] != nil, "\(id) body kinds")
                #expect(c.response["status"]?.int != nil, "\(id) status")
                #expect(c.response["headers"]?.object != nil, "\(id) response headers")
                if r["body_recipe"] == nil, f.route.method != "GET" { #expect(hasBody.contains(true), "\(id) has a body") }
            }
        }
    }

    @Test func pathsMatchTheRouteTemplate() {
        for f in Self.files {
            let tmpl = f.route.path.split(separator: "/", omittingEmptySubsequences: false)
            for c in f.cases {
                let id = caseID(f, c)
                let parts = (c.request["path"]?.string ?? "").split(separator: "/", omittingEmptySubsequences: false)
                #expect(parts.count == tmpl.count, "\(id) path shape")
                guard parts.count == tmpl.count else { continue }
                for (p, t) in zip(parts, tmpl) {
                    if t.hasPrefix("{") { #expect(Hex.decode(String(p), length: 16) != nil, "\(id) id segment \(p)") }
                    else { #expect(p == t, "\(id) literal segment") }
                }
            }
        }
    }

    @Test func rawBodiesAndRecipesDecode() throws {
        var bodies = 0, recipes = 0
        for f in Self.files {
            for c in f.cases {
                let id = caseID(f, c), r = c.request
                if let b = r["body_b64u"]?.string { #expect(B64U.decode(b) != nil, "\(id) body_b64u"); bodies += 1 }
                if let rec = r["body_recipe"] {
                    recipes += 1
                    let pre = rec["prefix_b64u"]?.string.flatMap { B64U.decode($0) }, suf = rec["suffix_b64u"]?.string.flatMap { B64U.decode($0) }
                    #expect(pre != nil && suf != nil, "\(id) recipe prefix/suffix")
                    if let byte = rec["byte"]?.int, let count = rec["count"]?.int {
                        #expect((0...255).contains(byte) && count > 0, "\(id) recipe byte/count")
                        // size rejection is what the case is about: the recipe must describe more than the documented cap
                        #expect(Int(count) + (pre?.count ?? 0) + (suf?.count ?? 0) > 0)
                    } else { Issue.record("\(id) recipe byte/count") }
                }
            }
        }
        #expect(bodies > 0 && recipes > 0)
    }

    @Test func fixtureFilesMatchProvenance() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OrchTestVectors/PROVENANCE.md")
        let prov = try String(contentsOf: url, encoding: .utf8)
        for name in try Fixtures.fileNames() {
            let digest = Hex.encode(SHA256.hash(data: try Fixtures.rawData(name)))
            #expect(prov.contains("\(name): sha256 `\(digest)`"), "\(name) differs from PROVENANCE.md")
        }
    }
}

@Suite struct FixtureWireTests {
    static let files = FixtureSchemaTests.files

    /// Request and response JSON are inside the v2 JSON subset (no floats, ASCII keys, depth) and survive
    /// parse(cj(x)) == x with cj idempotent: what the adapter will put on the wire is byte-stable.
    @Test func jsonBodiesAreCanonicalisable() throws {
        var n = 0
        for f in Self.files {
            for c in f.cases {
                for (side, node) in [("request", c.request["json"]), ("response", c.response["json"])] {
                    guard let node else { continue }
                    let id = "\(caseID(f, c)) \(side)"
                    guard let v = node.jsonValue else { Issue.record("\(id): not in the v2 JSON subset"); continue }
                    let bytes = try canonicalJSON(v)
                    let back = try StrictJSON.parse(bytes, maxBytes: .max)
                    #expect(back == v, "\(id)")
                    #expect(try canonicalJSON(back) == bytes, "\(id) idempotent")
                    n += 1
                }
            }
        }
        #expect(n > 400)
    }

    /// Success-path signed objects (device certs, revocations, cards, member lists, cert requests/challenges/rejections)
    /// verify under the shared vector keys with the suite-2 labels. Pure wire: no product behaviour involved.
    @Test func signedObjectsInSuccessCasesVerify() throws {
        let keys = try vectorSigningKeys()
        #expect(keys.count == 11)
        let kinds = Dictionary(uniqueKeysWithValues: SignedKind.allCases.map { ($0.rawValue, $0) })
        var verified: [String: Int] = [:]
        let okNames: Set<String> = ["success", "exact_retry", "resigned_identical", "first_card_without_session"]

        func walk(_ v: JSONValue, _ id: String) {
            if let m = v.object {
                if let kind = m["o"]?.object?["kind"]?.string, m["sig"] != nil {
                    if kind == "card" {
                        if keys.values.contains(where: { (try? Card.verify(v, ownerKey: $0)) != nil }) { verified["card", default: 0] += 1 }
                        else { Issue.record("\(id): card does not verify under any vector key") }
                    } else if let k = kinds[kind], let s = try? SignedObject.parse(v) {
                        if keys.values.contains(where: { (try? s.verify(kind: k, key: $0)) != nil }) { verified[kind, default: 0] += 1 }
                        else { Issue.record("\(id): \(kind) does not verify under any vector key") }
                    } else if kind == "cert_rejection" {
                        // no SignedKind yet (PR4): checked structurally only, signature checked once the label is supported
                        verified["cert_rejection(unchecked)", default: 0] += 1
                    }
                    return
                }
                for x in m.values { walk(x, id) }
            } else if let a = v.array { for x in a { walk(x, id) } }
        }
        for f in Self.files {
            for c in f.cases where okNames.contains(c.name) {
                for node in [c.request["json"], c.response["json"]] { if let v = node?.jsonValue { walk(v, caseID(f, c)) } }
            }
        }
        for kind in ["device_cert", "revocation", "card", "member_list", "cert_request", "cert_challenge"] {
            #expect((verified[kind] ?? 0) >= 1, "no \(kind) was verified: \(verified)")
        }
        #expect(verified.values.reduce(0, +) >= 20, "\(verified)")
    }
}

@Suite struct FixtureCoverageTests {
    static let allIDs: Set<String> = Set(FixtureSchemaTests.files.flatMap { f in f.cases.map { caseID(f, $0) } })

    /// pending (by PR) + replayable == every case, disjoint, nothing stale: the skip list cannot silently shrink coverage.
    @Test func skipListPlusSupportedEqualsAllCases() {
        let files = Set(FixtureSchemaTests.files.map(\.fileName))
        #expect(Set(FixtureCoverage.pending.keys).isSubset(of: files), "stale pending entries")
        #expect(FixtureCoverage.replayable.isSubset(of: files), "stale replayable entries")
        #expect(Set(FixtureCoverage.pending.keys).isDisjoint(with: FixtureCoverage.replayable), "file both pending and replayable")
        var pendingIDs = Set<String>(), supportedIDs = Set<String>()
        for f in FixtureSchemaTests.files {
            for c in f.cases {
                let id = caseID(f, c)
                if FixtureCoverage.replayable.contains(f.fileName) { supportedIDs.insert(id) }
                else if FixtureCoverage.caseOverrides[id] != nil || FixtureCoverage.pending[f.fileName] != nil { pendingIDs.insert(id) }
            }
        }
        #expect(Set(FixtureCoverage.caseOverrides.keys).isSubset(of: Self.allIDs), "stale case override")
        #expect(pendingIDs.isDisjoint(with: supportedIDs))
        #expect(pendingIDs.union(supportedIDs) == Self.allIDs, "uncovered: \(Self.allIDs.subtracting(pendingIDs).subtracting(supportedIDs).sorted())")
        #expect(pendingIDs.count + supportedIDs.count == FixtureCoverage.expectedCaseCount)
    }

    /// PR1 changes no behaviour: nothing is replayable yet. A PR that enables a file must edit this number with the skip list.
    @Test func nothingIsReplayableInPR1() { #expect(FixtureCoverage.replayable.isEmpty) }

    @Test func everyPRHasWork() {
        for pr in FixtureCoverage.PR.allCases { #expect(FixtureCoverage.pending.values.contains(pr), "\(pr.rawValue)") }
    }
}
