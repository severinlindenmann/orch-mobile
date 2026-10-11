import Foundation
import Testing
import OrchClient
@testable import OrchFakeHost
@testable import OrchProtocol
import OrchTestVectors

/// PR3 preconditions for the directory and membership fixtures, mirroring orch-relay's own replay seeds
/// (tests/directory_support.py `seed`/`prepare_case`, tests/members_support.py `load_state`/`prepare_fixture`, at 386a6cb): the
/// vector certificates, card, revocation and p3 membership state, edited per scenario exactly as the reference edits its tables.
enum PR3Replay {
    static let directoryFiles: Set<String> = ["card_get.json", "card_put.json", "device_get.json", "device_put.json",
                                              "revocation_feed.json", "revocation_get.json", "revocations_post.json"]
    static let membersFiles: Set<String> = ["membership.json", "members.json", "grants.json", "card_keys.json", "card_key.json"]
    static var files: Set<String> { directoryFiles.union(membersFiles) }

    static let v: JSONValue = (try? StrictJSON.parse(Vectors.data, maxBytes: .max))?.object?["suites"]?.object?["2"] ?? .null
    static func id(_ name: String) -> ID16 { ID16(hex: v.object!["ids"]!.object![name]!.string!)! }
    static var person: ID16 { id("person_alice") }
    static var bob: ID16 { id("person_bob") }
    static var device: ID16 { id("device_phone") }
    static var primary: ID16 { id("device_primary") }
    static var ws: ID16 { id("workspace_a") }
    static func cert(_ name: String) -> JSONValue { v.object!["certs"]!.object!["signed"]!.object![name]! }
    static var card: JSONValue { v.object!["card"]!.object!["card"]! }
    static var record: JSONValue { v.object!["revocations"]!.array![0].object!["signed"]! }
    static func key(_ name: String) throws -> SigningPublicKey {
        try SigningPublicKey(x963: Hex.decode(v.object!["keys"]!.object![name]!.object!["pub"]!.string!)!)
    }
    static func signer(_ name: String) throws -> SoftwareSigner {
        try SoftwareSigner(testScalar: scalar(fromSeed: Hex.decode(v.object!["keys"]!.object![name]!.object!["seed"]!.string!)!))
    }
    static var p3Cases: [JSONValue] { v.object!["p3"]!.object!["cases"]!.array! }
    static var base: JSONValue { p3Cases.first { $0.object?["name"]?.string == "second_person_and_grants_in_one_commit" }! }
    static var baseBody: JSONValue { base.object!["args"]!.object!["body"]! }

    /// A signed object re-signed after an edit of its `o` (the reference's `signed(o, key)`).
    static func resigned(_ signed: JSONValue, by key: String, kind: SignedKind, _ edit: (inout [String: JSONValue]) -> Void) throws -> JSONValue {
        var o = signed.object!["o"]!.object!
        edit(&o)
        return try SignedObject.sign(o, kind: kind, signer: try signer(key)).json
    }

    static func row(_ cert: JSONValue, now: Int64, accounts: [ID16: SigningPublicKey]) -> FakeRelay.DeviceRow {
        let o = cert.object!["o"]!.object!
        let person = ID16(hex: o["person_id"]!.string!)!
        let info = accounts[person].flatMap { try? DeviceCertificate.verify(cert, personKey: $0, nowMs: now) }
        return FakeRelay.DeviceRow(cert: cert, personID: person, expiresMs: o["expires_ms"]?.int,
                                   scopesMax: (o["scopes_max"]?.array ?? []).compactMap(\.string), info: info)
    }

    /// directory_support.seed: Alice's account, three devices, the card with Alice's phone as the only member (list `{}`), holder 1,
    /// the FAKE-device and FAKE-workspace sessions.
    static func baseSeed(_ relay: FakeRelay, now: Int64, devices: Bool = true, card withCard: Bool = true) async throws {
        let pk = try key("person_alice.sig")
        let certs = devices ? ["phone", "primary", "laptop"].map { cert($0) } : []
        let card = Self.card, ws = Self.ws, person = Self.person, device = Self.device
        let verified = try Card.verify(card, ownerKey: pk)
        await relay.seed { r in
            r.owners[person] = pk
            for c in certs { let x = row(c, now: now, accounts: r.owners); r.devices[ID16(hex: c.object!["o"]!.object!["device_id"]!.string!)!] = x }
            if withCard {
                var w = FakeRelay.Workspace()
                w.card = FakeRelay.CardRow(json: card, wsk: verified.wsk, ownerPersonID: person, cardSeq: 1, verified: verified)
                w.everPersons = [person]; w.everDevices = [device: 1]
                w.members = [device: FakeRelay.MemberRow(personID: person, scopes: ["look"])]
                w.listJSON = .object([:]); w.listSeq = 1; w.epoch = 1
                w.holder = FakeRelay.Holder(gen: 1, leaseUntilMs: now + 40_000)
                r.workspaces[ws] = w
            }
            r.sessions["FAKE-device"] = .init(kind: .device, id: device, expiresMs: now + 900_000)
            r.sessions["FAKE-workspace"] = .init(kind: .workspace, id: ws, expiresMs: now + 900_000)
        }
    }

    /// members_support.load_state: the base seed, then the p3 state and directory (accounts, certificates, revocations, list,
    /// members, grants, wraps, obligations, live receipts, card sequence).
    static func loadState(_ relay: FakeRelay, state: JSONValue, directory: JSONValue, now: Int64) async throws {
        try await baseSeed(relay, now: now)
        var accountKeys: [ID16: SigningPublicKey] = [person: try key("person_alice.sig")]
        for (p, pub) in directory.object?["persons"]?.object ?? [:] { accountKeys[ID16(hex: p)!] = try SigningPublicKey(x963: Hex.decode(pub.string!)!) }
        let st = state.object!, ws = Self.ws, person = Self.person, record = Self.record
        let certs = (directory.object?["certs"]?.object ?? [:]).values.map { $0 }
        let revoked = (directory.object?["revoked"]?.array ?? []).map { ID16(hex: $0.string!)! }
        var signedList: JSONValue?
        if let o = st["list"], o != .null { signedList = try SignedObject.sign(o.object!, kind: .memberList, signer: try signer("wsk_a.sig")).json }
        let list = signedList, accounts = accountKeys
        await relay.seed { r in
            r.owners = accounts
            r.devices = [:]
            for c in certs { r.devices[ID16(hex: c.object!["o"]!.object!["device_id"]!.string!)!] = row(c, now: now, accounts: accounts) }
            for d in revoked { r.revocationRows[d] = .init(record: record, personID: person, reason: "lost", cursor: 1) }
            var w = r.workspaces[ws]!
            w.members = [:]; w.listJSON = nil; w.listSeq = 0; w.epoch = 0; w.everPersons = []; w.everDevices = [:]
            for p in st["ever_persons"]?.array ?? [] { w.everPersons.insert(ID16(hex: p.string!)!) }
            for d in st["ever_devices"]?.array ?? [] { w.everDevices[ID16(hex: d.string!)!] = 1 }
            if let list, let o = list.object?["o"]?.object {
                w.listJSON = list; w.listSeq = o["list_seq"]!.int!; w.epoch = UInt32(o["epoch"]!.int!)
                for m in o["members"]!.array! {
                    let mo = m.object!
                    w.members[ID16(hex: mo["device_id"]!.string!)!] = .init(personID: ID16(hex: mo["person_id"]!.string!)!, scopes: mo["scopes"]!)
                }
            }
            for (k, g) in st["grants"]?.object ?? [:] {
                let parts = k.split(separator: "/")
                w.grants[.init(device: ID16(hex: String(parts[0]))!, epoch: UInt32(parts[1])!)] = g
            }
            for (d, x) in st["wraps"]?.object ?? [:] {
                w.cardKeys[ID16(hex: d)!, default: [:]][UInt32(x.object!["card_seq"]!.int!)] = x.object!["sealed"]!.string!
            }
            for (d, x) in st["rotation_due"]?.object ?? [:] {
                w.rotationDue[ID16(hex: d)!] = .init(cursor: x.object!["revocation_cursor"]!.int!, epoch: UInt32(x.object!["epoch"]!.int!))
            }
            for (h, res) in st["publications"]?.object ?? [:] {
                let ok = res.object!["ok"]!.object!
                w.receipts[Hex.decode(h)!] = .init(listSeq: ok["list_seq"]!.int!, epoch: UInt32(ok["epoch"]!.int!), acceptedMs: now)
            }
            w.card!.cardSeq = UInt32(st["card_seq"]!.int!)
            r.workspaces[ws] = w
        }
    }

    /// Seeds one case; false when the scenario has no seed (the caller records it).
    static func seed(_ f: Fixtures.File, _ c: Fixtures.Case, _ relay: FakeRelay) async throws -> Bool {
        let now = c.given["now_ms"]?.int ?? 1_790_000_000_000
        let scenario = c.given["scenario"]?.string ?? c.name
        let name = String(f.fileName.dropLast(5))
        if membersFiles.contains(f.fileName) { return try await seedMembers(name, scenario, relay, now: now) }
        return try await seedDirectory(name, scenario, c, relay, now: now)
    }

    private static func seedMembers(_ name: String, _ scenario: String, _ relay: FakeRelay, now: Int64) async throws -> Bool {
        var committed = base.object!["expect"]!.object!["state"]!.object!
        committed["publications"] = .object([:])
        try await loadState(relay, state: name == "membership" ? base.object!["state"]! : .object(committed),
                            directory: base.object!["args"]!.object!["directory"]!, now: now)
        let ws = Self.ws, device = Self.device, person = Self.person, record = Self.record
        let body = baseBody
        if name == "members" { await relay.seed { r in r.workspaces[ws]!.listJSON = body.object!["member_list"]! } }
        switch scenario {
        case "cert_invalid":
            await relay.seed { r in r.devices[device]!.cert = .object([:]); r.devices[device]!.info = nil }
        case "bad_signature":
            let pk = try key("person_alice.sig")
            await relay.seed { r in r.workspaces[ws]!.card!.wsk = pk }
        case "cert_expired":
            let c = try resigned(cert("phone"), by: "person_alice.sig", kind: .deviceCert) { $0["expires_ms"] = .int(now) }
            await relay.seed { r in r.devices[device]!.cert = c; r.devices[device]!.expiresMs = now }
        case "not_eligible":
            let primary = Self.primary
            await relay.seed { r in
                r.sessions["FAKE-workspace"] = .init(kind: .device, id: primary, expiresMs: now + 900_000)
                r.workspaces[ws]!.members = [:]
            }
        case "revoked":
            await relay.seed { r in r.revocationRows[device] = .init(record: record, personID: person, reason: "lost", cursor: 1) }
        case "other_person":
            let bobPhone = cert("bob_phone")
            await relay.seed { r in r.devices[device]!.cert = bobPhone }
        case "scope_exceeded":
            let c = try resigned(cert("phone"), by: "person_alice.sig", kind: .deviceCert) {
                $0["scopes_max"] = [.string("drop:" + ws.hex)]; $0["expires_ms"] = .int(now + 10_000)
            }
            await relay.seed { r in r.devices[device]!.cert = c }
        case "rotation_required", "stale_list":
            var o = body.object!["member_list"]!.object!["o"]!.object!
            o["list_seq"] = 1; o["epoch"] = 1
            let list = try SignedObject.sign(o, kind: .memberList, signer: try signer("wsk_a.sig")).json
            let laptop = id("device_laptop")
            await relay.seed { r in
                r.workspaces[ws]!.listJSON = list; r.workspaces[ws]!.listSeq = 1; r.workspaces[ws]!.epoch = 1
                if scenario == "rotation_required" { r.workspaces[ws]!.members[laptop] = .init(personID: person, scopes: ["look"]) }
            }
        case "not_for_this_device" where name == "card_keys":
            var o = body.object!["member_list"]!.object!["o"]!.object!
            o["members"] = .array(o["members"]!.array!.filter { $0.object?["device_id"] != .string(device.hex) })
            let list = try SignedObject.sign(o, kind: .memberList, signer: try signer("wsk_a.sig")).json
            await relay.seed { r in r.workspaces[ws]!.listJSON = list; r.workspaces[ws]!.members[device] = nil }
        case "grant_conflict":
            await relay.seed { r in r.workspaces[ws]!.grants[.init(device: device, epoch: 1)] = .object([:]) }
        case "stale_card":
            await relay.seed { r in r.workspaces[ws]!.card!.cardSeq = 2 }
        case "wrap_conflict":
            await relay.seed { r in r.workspaces[ws]!.cardKeys[device, default: [:]][1] = "other" }
        case "not_found":
            await relay.seed { r in
                switch name {
                case "members": r.workspaces[ws]!.listJSON = nil
                case "grants": r.workspaces[ws]!.grants = [:]
                default: r.workspaces[ws]!.cardKeys = [:]
                }
            }
        case "authorized_current_state", "exact_bytes_already_committed", "malformed", "wrong_suite", "unauthenticated", "not_for_this_device",
             "bad_epoch", "fenced", "missing_grant", "other_workspace", "too_large", "victim_person_without_member":
            break
        default:
            return false
        }
        return true
    }

    private static func seedDirectory(_ name: String, _ scenario: String, _ c: Fixtures.Case, _ relay: FakeRelay, now: Int64) async throws -> Bool {
        try await baseSeed(relay, now: now, card: name != "device_put")
        let ws = Self.ws, device = Self.device, primary = Self.primary, person = Self.person, record = Self.record
        let bobKey = try key("person_bob.sig")
        if c.request["headers"]?["Authorization"]?.string == "Bearer FAKE-workspace-token" {
            await relay.seed { r in r.sessions["FAKE-workspace-token"] = .init(kind: .workspace, id: ws, expiresMs: now + 900_000) }
        }
        if name == "device_put", c.name == "resigned_identical" {
            let original = p3Cases.first { $0.object?["name"]?.string == "certificate_directory_resigned_retry" }!
                .object!["state"]!.object![device.hex]!
            await relay.seed { r in r.devices[device]!.cert = original }
        }
        if scenario == "other_workspace_person_refused" { await relay.seed { r in r.workspaces[ws]!.everPersons = [] } }
        if name == "device_put", scenario == "rate_limited" { await relay.seed { r in r.devices[device] = nil } }
        if name == "revocation_feed", c.name == "filtered_workspace_feed" {
            let other = try resigned(record, by: "person_alice.sig", kind: .revocation) { $0["device_id"] = .string(primary.hex) }
            await relay.seed { r in r.revocationRows[primary] = .init(record: other, personID: person, reason: "lost", cursor: 2) }
        }
        if name == "revocation_feed" {
            // the feed's target is revoked; its caller is another live device of the person
            await relay.seed { r in r.sessions["FAKE-device"] = .init(kind: .device, id: primary, expiresMs: now + 900_000) }
        }
        if name == "revocation_get" || name == "revocation_feed" || scenario == "revoked" {
            await relay.seed { r in
                r.revocationRows[device] = .init(record: record, personID: person, reason: "lost", cursor: 1)
                if name == "revocation_feed", scenario == "revoked" { r.sessions["FAKE-device"] = .init(kind: .device, id: device, expiresMs: now + 900_000) }
            }
        }
        if name == "card_put", c.name == "first_card_without_session" || scenario == "rate_limited" || scenario == "other_person" {
            await relay.seed { r in r.workspaces = [:] }
        }
        func windowFull(_ purpose: String, _ duration: Int64, _ cap: Int) async {
            // full until 20 s from now: the fixtures' Retry-After
            await relay.seed { r in r.rateWindows[purpose + "|fixture|" + String(duration)] = .init(endMs: now + 20_000, count: cap) }
        }
        switch scenario {
        case "cert_expired" where name != "device_put":
            await relay.seed { r in for d in Array(r.devices.keys) { r.devices[d]!.expiresMs = now } }
        case "cert_invalid":
            if name == "device_put" { await relay.seed { r in r.owners[person] = bobKey } }
            else { await relay.seed { r in for d in Array(r.devices.keys) { r.devices[d]!.cert = .object([:]) } } }
        case "bad_signature" where name != "card_put":
            await relay.seed { r in r.owners[person] = bobKey }
        case "not_eligible":
            if name == "device_get" || name == "revocation_feed" {
                await relay.seed { r in
                    for t in Array(r.sessions.keys) { r.sessions[t] = .init(kind: .workspace, id: ws, expiresMs: now + 900_000) }
                    r.workspaces[ws]!.everPersons = []
                }
            } else {
                await relay.seed { r in
                    r.workspaces[ws]!.members = [:]
                    if name == "card_put" { for t in Array(r.sessions.keys) { r.sessions[t] = .init(kind: .device, id: device, expiresMs: now + 900_000) } }
                }
            }
        case "other_person":
            switch name {
            case "revocations_post": await relay.seed { r in r.devices[device] = nil }
            case "card_put": await relay.seed { r in r.owners[person] = bobKey }
            default: await relay.seed { r in r.devices = [:]; r.owners = [:] }
            }
        case "cert_conflict":
            var other = cert("phone").object!
            var o = other["o"]!.object!
            o["label_sealed"] = .string(B64U.encode(Data("other".utf8)))
            other["o"] = .object(o)
            let conflicting = JSONValue.object(other)
            await relay.seed { r in r.devices[device]!.cert = conflicting }
        case "not_found":
            switch name {
            case "device_get":
                await relay.seed { r in
                    r.sessions["FAKE-device"] = .init(kind: .device, id: primary, expiresMs: now + 900_000)
                    r.workspaces[ws]!.members = [:]; r.devices[device] = nil
                }
            case "card_get": await relay.seed { r in r.workspaces = [:] }
            default: await relay.seed { r in r.revocationRows = [:] }
            }
        case "rate_limited":
            switch name {
            case "device_put": await windowFull("certificate-address", 3_600_000, 30)
            case "revocations_post": await windowFull("revocation-address", 60_000, 10)
            case "revocation_get": await windowFull("revocation-read", 60_000, 60)
            case "card_put": await windowFull("card-address", 3_600_000, 10)
            default: return false
            }
        case "authorized_current_state", "exact_bytes_already_committed", "malformed", "wrong_suite", "unauthenticated", "too_large",
             "delegation_mismatch", "fenced", "cert_expired", "bad_signature", "revoked", "other_workspace_person_refused",
             "Same canonical signed object, different valid P-256 signature; no state change",
             "W ever_devices contains only the phone; records for the same person's other devices are excluded before pagination",
             "bad_wxk_version", "delegation_changed", "other_workspace", "stale_card", "wsk_changed", "wxk_changed_without_version":
            break
        default:
            return false
        }
        if name == "card_put" {
            var old = card.object!
            var o = old["o"]!.object!
            switch scenario {
            case "bad_wxk_version": o["card_seq"] = 0; o["wxk_version"] = 3
            case "stale_card": o["card_seq"] = 2
            case "wsk_changed": o["wsk_pub"] = .string(B64U.encode(try key("person_alice.sig").x963))
            case "wxk_changed_without_version": o["card_seq"] = 0; o["wxk_pub"] = .string(B64U.encode(try key("person_alice.sig").x963))
            case "other_workspace": o["workspace_id"] = .string(String(repeating: "0", count: 32))
            case "delegation_changed":
                var d = old["delegation"]!.object!
                var dob = d["o"]!.object!
                dob["client_hosted"] = true
                d["o"] = .object(dob); old["delegation"] = .object(d)
            default: break
            }
            old["o"] = .object(o)
            let stored = JSONValue.object(old)
            if stored != card { await relay.seed { r in r.workspaces[ws]?.card?.json = stored } }
        }
        return true
    }
}

/// The p3 membership state vectors (vectors_v2.json `p3.cases`, op `membership`): each state is loaded into the FakeRelay the way
/// orch-relay's members_support.load_state does, the body is sent byte for byte (`body_raw` where the vector gives one), and the
/// result and the post-state are compared. A refused publication leaves every table exactly as it was.
@Suite struct P3MembershipVectorTests {
    static func snapshot(_ relay: FakeRelay) async -> JSONValue {
        let ws = PR3Replay.ws
        return await relay.inspect { r in
            guard let w = r.workspaces[ws] else { return .null }
            var grants: [String: JSONValue] = [:]
            for (k, g) in w.grants { grants[k.device.hex + "/" + String(k.epoch)] = g }
            var wraps: [String: JSONValue] = [:]
            for (d, bySeq) in w.cardKeys { for (seq, sealed) in bySeq { wraps[d.hex + "/" + String(seq)] = .string(sealed) } }
            var due: [String: JSONValue] = [:]
            for (d, x) in w.rotationDue { due[d.hex] = ["revocation_cursor": .int(x.cursor), "epoch": .int(Int64(x.epoch))] }
            var receipts: [String: JSONValue] = [:]
            for (h, x) in w.receipts { receipts[Hex.encode(h)] = ["list_seq": .int(x.listSeq), "epoch": .int(Int64(x.epoch))] }
            var members: [String: JSONValue] = [:]
            for (d, m) in w.members { members[d.hex] = ["person_id": .string(m.personID.hex), "scopes": m.scopes] }
            return .object([
                "list": w.listJSON?.object?["o"] ?? .null, "list_seq": .int(w.listSeq), "epoch": .int(Int64(w.epoch)), "members": .object(members),
                "grants": .object(grants), "wraps": .object(wraps), "rotation_due": .object(due), "publications": .object(receipts),
                "ever_persons": .array(w.everPersons.map(\.hex).sorted().map { .string($0) }),
                "ever_devices": .array(w.everDevices.keys.map(\.hex).sorted().map { .string($0) }),
                "card_seq": .int(Int64(w.card?.cardSeq ?? 0)),
            ])
        }
    }

    @Test func membershipStateTransitions() async throws {
        let cases = PR3Replay.p3Cases.filter { $0.object?["op"]?.string == "membership" }
        #expect(cases.count == 29)
        var accepted = 0, refused = 0
        for c in cases {
            let co = c.object!, name = co["name"]!.string!, args = co["args"]!.object!
            let now = args["now_ms"]!.int!
            let relay = FakeRelay(testingContext: try RealmContext.live(origin: fixtureOrigin), clock: ContinuousClock(), wall: MutableWall(now))
            try await PR3Replay.loadState(relay, state: co["state"]!, directory: args["directory"]!, now: now)
            let before = await Self.snapshot(relay)
            let raw = try args["body_raw"]?.string.map { Data($0.utf8) } ?? canonicalJSON(args["body"]!)
            let reply = try await relay.send(WireRequest(method: "PUT", target: "/v2/workspaces/\(PR3Replay.ws.hex)/membership",
                headers: ["Authorization": "Bearer FAKE-workspace", "Orch-Holder": "1", "Content-Type": "application/json"],
                body: raw, clientAddress: "vector"))
            let got = try StrictJSON.parse(reply.body, maxBytes: .max)
            let result: JSONValue = reply.status == 200 ? ["ok": got] : ["refuse": got.object?["error"] ?? .null]
            let expect = co["expect"]!.object!
            #expect(result == expect["result"], "\(name): \(result)")
            let after = await Self.snapshot(relay)
            if expect["result"]?.object?["refuse"] != nil {
                refused += 1
                #expect(after == before, "\(name): a refused publication changed state")
            } else {
                accepted += 1
                let want = expect["state"]!.object!
                let a = after.object!
                #expect(a["list"] == want["list"], "\(name) list")
                // the relay's member table is exactly the accepted list's entries
                var members: [String: JSONValue] = [:]
                for m in want["list"]?.object?["members"]?.array ?? [] {
                    let mo = m.object!
                    members[mo["device_id"]!.string!] = ["person_id": mo["person_id"]!, "scopes": mo["scopes"]!]
                }
                #expect(a["members"] == .object(members), "\(name) members")
                #expect(a["grants"] == want["grants"], "\(name) grants")
                var wraps: [String: JSONValue] = [:]
                for (d, x) in want["wraps"]?.object ?? [:] { wraps[d + "/" + String(x.object!["card_seq"]!.int!)] = x.object!["sealed"]! }
                #expect(a["wraps"] == .object(wraps), "\(name) wraps")
                #expect(a["rotation_due"] == want["rotation_due"], "\(name) rotation_due")
                #expect(a["ever_persons"] == want["ever_persons"], "\(name) ever_persons")
                #expect(a["ever_devices"] == want["ever_devices"], "\(name) ever_devices")
                #expect(Set(a["publications"]!.object!.keys) == Set(want["publications"]!.object!.keys), "\(name) publications")
                #expect(a["card_seq"] == want["card_seq"], "\(name) card_seq")
            }
        }
        #expect(accepted + refused == 29 && accepted > 0 && refused > 0)
    }
}
