import CryptoKit
import Foundation
import Testing
@testable import OrchProtocol
import OrchTestVectors

@Suite struct FixtureSchemaTests {
    static let files: [Fixtures.File] = (try? Fixtures.loadAll()) ?? []

    @Test func everyFileAndCaseParses() throws {
        let files = try Fixtures.loadAll()   // a load failure fails this test; other suites then see no files and fail their counts
        #expect(files.count == FixtureCoverage.expectedFileCount)
        #expect(files.reduce(0) { $0 + $1.cases.count } == FixtureCoverage.expectedCaseCount)
        for f in files {
            #expect(f.contract == "orch-relay-http-v2", "\(f.fileName)")
            #expect(f.suite == 2, "\(f.fileName)")
            #expect(["GET", "POST", "PUT", "DELETE"].contains(f.route.method), "\(f.fileName)")
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
                if r["body_recipe"] == nil, f.route.method != "GET", f.route.method != "DELETE" { #expect(hasBody.contains(true), "\(id) has a body") }
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
                    // 16-byte ids; the F1 hash and page placeholders ({hash}, {source_hash}, {target_hash}, {i}) are not ids
                    if t.hasPrefix("{"), !t.contains("hash"), t != "{i}" { #expect(Hex.decode(String(p), length: 16) != nil, "\(id) id segment \(p)") }
                    else if t.hasPrefix("{") { #expect(!p.isEmpty, "\(id) segment \(t)") }
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

    /// The relay's own manifest (MANIFEST.json, written by its manifest.py): every copied file's SHA-256 and the aggregate
    /// (`sha256` of the sorted `name\tsha\n` lines) must match, and the directory holds exactly the manifest's files. The
    /// vectors file is pinned in PROVENANCE.md, together with the manifest's revision and aggregate.
    @Test func fixtureFilesMatchTheRelaysManifest() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OrchTestVectors/PROVENANCE.md")
        let prov = try String(contentsOf: url, encoding: .utf8)
        let vdigest = Hex.encode(SHA256.hash(data: Vectors.data))
        #expect(prov.contains("sha256: `\(vdigest)`"), "vectors_v2.json differs from PROVENANCE.md")
        let manifest = try #require(try StrictJSON.parse(try Fixtures.rawData("MANIFEST.json"), maxBytes: .max).object)
        let files = try #require(manifest["files"]?.object)
        let names = try Fixtures.allFileNames().filter { $0 != "MANIFEST.json" }
        #expect(Set(files.keys) == Set(names), "the fixture directory differs from MANIFEST.json")
        var lines = ""
        for name in files.keys.sorted() {
            let digest = Hex.encode(SHA256.hash(data: try Fixtures.rawData(name)))
            #expect(files[name]?.string == digest, "\(name) differs from MANIFEST.json")
            lines += "\(name)\t\(files[name]?.string ?? "")\n"
        }
        let aggregate = Hex.encode(SHA256.hash(data: Data(lines.utf8)))
        #expect(manifest["aggregate"]?.string == aggregate, "MANIFEST.json aggregate")
        let revision = try #require(manifest["revision"]?.int)
        #expect(prov.contains("MANIFEST.json revision \(revision), aggregate `\(aggregate)`"), "PROVENANCE.md names another manifest")
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

    /// Success-path signed objects verify under their EXPECTED signer only (not any vector key): person-signed kinds
    /// (device_cert, revocation, cert_challenge, cert_rejection, card) under the key whose person id equals the object's person/owner id;
    /// workspace-key kinds (member_list, cert_request, wk_grant) under `wsk_a` for the vectors' workspace 705d40ab….
    /// Pure wire: no product behaviour involved.
    @Test func signedObjectsInSuccessCasesVerify() throws {
        let keys = try vectorSigningKeys()
        #expect(keys.count == 11)
        let byPerson = Dictionary(uniqueKeysWithValues: ["person_alice.sig", "person_bob.sig"].map { (Identifiers.personID(keys[$0]!).hex, keys[$0]!) })
        let wskA = keys["wsk_a.sig"]!
        let kinds = Dictionary(uniqueKeysWithValues: SignedKind.allCases.map { ($0.rawValue, $0) })
        let personField = ["device_cert": "person_id", "revocation": "person_id", "cert_challenge": "person_id", "cert_rejection": "person_id",
                           "card": "owner_person_id"]
        let wskKinds: Set<String> = ["member_list", "cert_request", "wk_grant"]
        let f1Kinds: Set<String> = ["genesis_pin", "workspace_checkpoint"]
        var verified: [String: Int] = [:]
        let okNames: Set<String> = ["success", "exact_retry", "resigned_identical", "first_card_without_session"]

        func walk(_ v: JSONValue, _ id: String) {
            guard let m = v.object else { if let a = v.array { for x in a { walk(x, id) } }; return }
            guard let o = m["o"]?.object, let kind = o["kind"]?.string, m["sig"] != nil else { for x in m.values { walk(x, id) }; return }
            let key: SigningPublicKey?
            if let f = personField[kind] { key = o[f]?.string.flatMap { byPerson[$0] } }
            else if wskKinds.contains(kind) {
                if o["workspace_id"]?.string != "705d40abbb8c1c90354a1acaa94c935c" { Issue.record("\(id): unexpected workspace for \(kind)") }
                key = wskA
            } else if f1Kinds.contains(kind) { return                // F1 ticket-log objects: host/relay only, the phone has no verifier
            } else { Issue.record("\(id): no expected signer for \(kind)"); return }
            guard let key else { Issue.record("\(id): \(kind) person/owner is not a vector person"); return }
            let ok: Bool
            if kind == "card" { ok = (try? Card.verify(v, ownerKey: key)) != nil }
            else if let k = kinds[kind], let s = try? SignedObject.parse(v) { ok = (try? s.verify(kind: k, key: key)) != nil }
            else { ok = false }
            if ok { verified[kind, default: 0] += 1 } else { Issue.record("\(id): \(kind) does not verify under its expected signer") }
        }
        for f in Self.files {
            for c in f.cases where okNames.contains(c.name) {
                for node in [c.request["json"], c.response["json"]] { if let v = node?.jsonValue { walk(v, caseID(f, c)) } }
            }
        }
        // pinned: a fixture re-copy that changes these counts must be reviewed
        let expected: [String: Int] = ["card": 3, "cert_challenge": 4, "cert_rejection": 3, "cert_request": 2, "device_cert": 8, "member_list": 3, "revocation": 4, "wk_grant": 5]
        #expect(verified == expected, "\(verified)")
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
                if FixtureCoverage.caseOverrides[id] != nil || FixtureCoverage.pending[f.fileName] != nil { pendingIDs.insert(id) }
                else if FixtureCoverage.replayable.contains(f.fileName) { supportedIDs.insert(id) }
            }
        }
        #expect(Set(FixtureCoverage.caseOverrides.keys).isSubset(of: Self.allIDs), "stale case override")
        #expect(pendingIDs.isDisjoint(with: supportedIDs))
        #expect(pendingIDs.union(supportedIDs) == Self.allIDs, "uncovered: \(Self.allIDs.subtracting(pendingIDs).subtracting(supportedIDs).sorted())")
        #expect(pendingIDs.count + supportedIDs.count == FixtureCoverage.expectedCaseCount)
    }

    /// PR2 enables the three session files, PR3 the twelve directory and membership files, PR4 the nine pairing/primary files,
    /// PR5 the three bridge files.
    /// A PR that enables more must edit this set with the skip list.
    @Test func replayableSetMatchesPRStage() {
        #expect(FixtureCoverage.replayable == ["session_challenge.json", "session_login.json", "session_logout.json",
                                               "card_get.json", "card_put.json", "card_key.json", "card_keys.json", "grants.json", "members.json",
                                               "membership.json", "device_get.json", "device_put.json", "revocation_feed.json",
                                               "revocation_get.json", "revocations_post.json",
                                               "accounts.json", "pair_device_post.json", "pair_host_post.json", "pair_poll.json",
                                               "cert_challenge.json", "cert_rejection.json", "cert_request_get.json",
                                               "cert_requests_poll.json", "cert_requests_post.json",
                                               "bridge_device_post.json", "bridge_device_poll.json", "bridge_host_post.json"])
        #expect(!FixtureCoverage.pending.values.contains(.pr3))
        #expect(!FixtureCoverage.pending.values.contains(.pr4))
        #expect(!FixtureCoverage.pending.values.contains(.pr5))
        #expect(FixtureCoverage.pending.filter { $0.value == .pr2 }.keys.sorted() == ["host_hold.json", "host_poll.json"])
    }

    /// The p3 vector groups: `cases` (replayed by the P3/RidStore/CertQueue suites), `envelope_sizes`, `objects`, and the groups
    /// pending a later stage (`pendingVectorGroups`). A new group fails here until it is placed.
    @Test func p3VectorGroupsAreAccountedFor() throws {
        let root = try StrictJSON.parse(Vectors.data, maxBytes: .max, maxDepth: 64)
        for suite in ["1", "2"] {
            let p3 = try #require(root.object?["suites"]?.object?[suite]?.object?["p3"]?.object)
            let pending = Set(FixtureCoverage.pendingVectorGroups.keys.map { String($0.dropFirst(3)) })
            #expect(Set(p3.keys) == Set(["cases", "envelope_sizes", "objects"]).union(pending), "suite \(suite): \(p3.keys.sorted())")
            #expect(p3["restore"]?.array?.count == 34, "suite \(suite) restore")
        }
    }

    /// Every PR still has pending files, or is done (its files all replay).
    @Test func everyPRHasWork() {
        for pr in FixtureCoverage.PR.allCases {
            let open = FixtureCoverage.pending.values.contains(pr) || FixtureCoverage.caseOverrides.values.contains(pr)
            #expect(open != FixtureCoverage.done.contains(pr), "\(pr.rawValue)")
        }
    }
}
