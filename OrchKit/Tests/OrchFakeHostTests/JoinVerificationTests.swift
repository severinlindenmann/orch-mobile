import CryptoKit
import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
import OrchStore
@testable import OrchClient
@testable import OrchFakeHost
@testable import OrchProtocol

/// What the phone fetches after `approved`, and the checks that gate the install (host-api section 3: card, CK, member list, grant).
@Suite struct JoinVerificationTests {
    struct Fetched {
        let card: JSONValue, list: JSONValue, grants: [JSONValue], wrap: HostAPI.CardKey
        let h: PairHarness
        var approved: PairingRecord.Approved { .init(scopes: ["look", "decide"], cert: .null, epoch: 1) }

        func verify(card: JSONValue? = nil, list: JSONValue? = nil, grants: [JSONValue]? = nil, wrap: HostAPI.CardKey? = nil,
                    origin: String = DemoRelay.origin, approved: PairingRecord.Approved? = nil, pk: SigningPublicKey? = nil, wsk: SigningPublicKey? = nil,
                    workspace: ID16? = nil) throws -> PairingCoordinator.VerifiedJoin {
            try PairingCoordinator.verify(cardJSON: card ?? self.card, listJSON: list ?? self.list, grantJSONs: grants ?? self.grants, cardKey: wrap ?? self.wrap,
                                          identity: h.env.device, deviceID: h.phoneID, workspace: workspace ?? h.host.workspace, origin: origin,
                                          wsk: wsk ?? h.host.wskPublic, pk: pk ?? h.primary.publicKey, approved: approved ?? self.approved)
        }
    }

    /// An honest join, then everything the phone would have fetched for it.
    func joined(_ h: PairHarness) async throws -> Fetched {
        guard case .ready = try await h.completeFirstTime() else { throw PairHarness.PairError.notReached("ready") }
        return try await fetched(h)
    }

    func fetched(_ h: PairHarness) async throws -> Fetched {
        let client = RelayClient(transport: h.env.transport)
        let s = try await client.openDeviceSession(identity: h.env.device, deviceID: h.phoneID).session
        let card = try await client.card(workspace: h.host.workspace, session: s)
        return Fetched(card: card, list: try await client.memberList(workspace: h.host.workspace, session: s),
                       grants: try await client.grants(workspace: h.host.workspace, session: s),
                       wrap: try await client.cardKey(workspace: h.host.workspace, cardSequence: 1, session: s), h: h)
    }

    func reason(_ body: () throws -> Any) -> String? {
        do { _ = try body(); return nil } catch let e { return Mirror(reflecting: e).children.first.map { "\($0.value)" } ?? "\(e)" }
    }

    func failure(_ f: Fetched, _ call: () throws -> PairingCoordinator.VerifiedJoin) -> String? {
        do { _ = try call(); return nil } catch is JoinPendingMarker { return "pending" } catch { return "\(error)" }
    }

    @Test func testCardWrongCKRejected() async throws {
        // end to end: a host that seals the wrong CK to the phone gets nothing installed and no name shown
        let h = try await PairHarness.make(.firstTime)
        await h.host.setHostile { $0.wrapKey = SymmetricKey(size: .bits256) }
        let log = StateLog(); await log.attach(h.coordinator)
        let end = try await h.completeFirstTime()
        await log.settled(h.coordinator); await log.stop()
        #expect(end == .failed(.verification(reason: "card_key")))
        let ws = try await h.env.index.workspaces(), rows = try await h.env.index.pairings(), prof = try await h.env.index.profile(ws: h.host.workspace.hex)
        #expect(ws.isEmpty && rows.isEmpty && prof == nil && h.vaultItems.isEmpty)             // no partial install, no WK left behind
        #expect(!FileManager.default.fileExists(atPath: try h.env.layout.wsDir(h.host.workspace.hex).path))
        #expect(await !log.states.contains { if case .ready = $0 { return true }; return false })
        // pure: a wrap of another key, a wrap of another sequence or device, and a tampered wrap all fail locally; no plaintext-name fallback
        let g = try await PairHarness.make(.firstTime)
        let f = try await joined(g)
        let other = try CardKeyWrap.seal(ck: SymmetricKey(size: .bits256), to: g.env.device.publicKeys.kx, deviceID: g.phoneID, workspace: g.host.workspace, cardSeq: 1)
        #expect(failure(f) { try f.verify(wrap: HostAPI.CardKey(workspace: g.host.workspace, device: g.phoneID, cardSeq: 1, sealed: other)) } == "JoinFailure(reason: \"card_key\")")
        var torn = f.wrap.sealed; torn[torn.count - 1] ^= 1
        #expect(failure(f) { try f.verify(wrap: HostAPI.CardKey(workspace: g.host.workspace, device: g.phoneID, cardSeq: 1, sealed: torn)) } == "JoinFailure(reason: \"card_key\")")
        #expect(failure(f) { try f.verify(wrap: HostAPI.CardKey(workspace: g.host.workspace, device: g.phoneID, cardSeq: 2, sealed: f.wrap.sealed)) } == "JoinFailure(reason: \"card_key_target\")")
        #expect(failure(f) { try f.verify(wrap: HostAPI.CardKey(workspace: g.host.workspace, device: .random(), cardSeq: 1, sealed: f.wrap.sealed)) } == "JoinFailure(reason: \"card_key_target\")")
        #expect(failure(f) { try f.verify() } == nil)
    }

    @Test func testHostedMarkerCannotBeHidden() async throws {
        // a client-hosted workspace whose sealed part says nothing: the PK-signed flag still shows the marker, as "(unknown)"
        let h = try await PairHarness.make(.firstTime, clientHosted: true, hostedBy: nil, name: "Client VM")
        guard case .ready(let handle) = try await h.completeFirstTime() else { Issue.record("not ready"); return }
        #expect(handle.joined.hosted == HostedMarker(marker: true, hostedBy: HostedMarker.unknownName) && handle.joined.name == "Client VM")
        let profile = try #require(try await h.env.index.profile(ws: h.host.workspace.hex))
        #expect(profile.clientHosted && profile.hostedMarker && profile.hostedBy == HostedMarker.unknownName)
        // a named host
        let n = try await PairHarness.make(.firstTime, clientHosted: true, hostedBy: "Example Client", name: "Client VM")
        guard case .ready(let nh) = try await n.completeFirstTime() else { Issue.record("not ready"); return }
        #expect(nh.joined.hosted == HostedMarker(marker: true, hostedBy: "Example Client"))
        // a name without the flag still shows the marker (a host can only add the warning)
        let m = try await PairHarness.make(.firstTime, clientHosted: false, hostedBy: "Somebody")
        guard case .ready(let mh) = try await m.completeFirstTime() else { Issue.record("not ready"); return }
        #expect(mh.joined.hosted == HostedMarker(marker: true, hostedBy: "Somebody"))
        // and a plain workspace has none
        let p = try await PairHarness.make(.firstTime)
        guard case .ready(let ph) = try await p.completeFirstTime() else { Issue.record("not ready"); return }
        #expect(ph.joined.hosted == HostedMarker(marker: false, hostedBy: nil))
        // the flag in the delegation is PK-signed: a card whose delegation says client_hosted:false cannot be made from this host's WSK alone
        let f = try await fetched(n)
        let verified = try Card.verify(f.card, ownerKey: n.primary.publicKey)
        #expect(verified.delegation.clientHosted)
        var forged = try #require(f.card.object)
        var d = try #require(forged["delegation"]?.object); var dob = try #require(d["o"]?.object)
        dob["client_hosted"] = false; d["o"] = .object(dob); forged["delegation"] = .object(d)
        #expect(throws: Refusal.self) { _ = try Card.verify(.object(forged), ownerKey: n.primary.publicKey) }
    }

    @Test func testApprovedNotExtendedWithCK() async throws {
        let h = try await PairHarness.make(.firstTime)
        let f = try await joined(h)
        // the joined scopes are exactly the approved ones: nothing in the card or CK widens them
        let profile = try #require(try await h.env.index.profile(ws: h.host.workspace.hex))
        #expect(profile.scopes == ["look", "decide"])
        // a list that gives the device more than was approved fails the join
        let wider = try await h.host.memberList([(h.primary.deviceID, World.all), (h.phoneID, ["look", "decide", "operate"])], epoch: 1, listSeq: 9)
        #expect(failure(f) { try f.verify(list: wider) } == "JoinFailure(reason: \"member_scopes\")")
        let narrower = try await h.host.memberList([(h.primary.deviceID, World.all), (h.phoneID, ["look"])], epoch: 1, listSeq: 9)
        #expect(failure(f) { try f.verify(list: narrower) } == "JoinFailure(reason: \"member_scopes\")")
        // end to end with a host that lists more than it approved
        // (approved: look only, within the certificate's look+decide; the list says look+decide)
        let g = try await PairHarness.make(.firstTime)
        await g.host.setHostile { $0.listScopes = ["look", "decide"] }
        _ = try await g.startToHostCode()
        try await g.hostApproves(scopes: ["look"])
        _ = try await g.drive(until: isComparingPrimary)
        try await g.primaryApproves()
        let endState = try await g.drive(until: { $0.isTerminal })
        #expect(endState == .failed(.verification(reason: "member_scopes")))
        let installed = try await g.env.index.workspaces()
        #expect(installed.isEmpty && g.vaultItems.isEmpty)
    }

    @Test func testCardOriginMatchesLink() async throws {
        let h = try await PairHarness.make(.firstTime)
        let f = try await joined(h)
        // the verified card names the relay it lives on; any other reviewed origin fails the join, byte for byte
        for other in ["https://relay.demo.invalid:443", "https://RELAY.demo.invalid", "https://relay.example.org", "http://relay.demo.invalid", "https://relay.demo.invalid/"] {
            #expect(failure(f) { try f.verify(origin: other) } == "JoinFailure(reason: \"card_origin\")", "\(other)")
        }
        #expect(failure(f) { try f.verify(origin: DemoRelay.origin) } == nil)
        // a Demo link naming any other origin never gets a request out
        let offer = try await h.rig.newOffer()
        let tampered = offer.link.replacingOccurrences(of: "https://relay.demo.invalid", with: "https://relay.example.org")
        let g = try await PairHarness.make(.firstTime)
        let before = await g.relay.requestsReceived
        let state = await g.coordinator.start(link: try PairingLink.parse(tampered))
        #expect(state == .failed(.realm(.externalOrigin)))
        let after = await g.relay.requestsReceived, leftovers = try await g.env.index.pairings()
        #expect(after == before && leftovers.isEmpty)
        // the pins in the link still decide: a link for a workspace whose card names another origin cannot be made by the relay (it
        // publishes only its own origin), and a card for another workspace or WSK fails identity
        #expect(failure(f) { try f.verify(workspace: .random()) } == "JoinFailure(reason: \"card_identity\")")
        #expect(failure(f) { try f.verify(wsk: SoftwareSigner().publicKey) } == "JoinFailure(reason: \"card_identity\")")
        #expect(failure(f) { try f.verify(pk: SoftwareSigner().publicKey) } == "JoinFailure(reason: \"card_other_person\")")
    }

    @Test func testJoinRequiresOwnMemberScopesAndEpoch() async throws {
        let h = try await PairHarness.make(.firstTime)
        let f = try await joined(h)
        // this device must be in the list, with exactly the approved scopes
        let without = try await h.host.memberList([(h.primary.deviceID, World.all)], epoch: 1, listSeq: 9)
        #expect(failure(f) { try f.verify(list: without) } == "JoinFailure(reason: \"member_scopes\")")
        // the list epoch is at least the approved epoch, and the installed grant is the list epoch
        let approvedLater = PairingRecord.Approved(scopes: ["look", "decide"], cert: .null, epoch: 2)
        #expect(failure(f) { try f.verify(approved: approvedLater) } == "JoinFailure(reason: \"member_epoch\")")
        let epoch2 = try await h.host.memberList([(h.primary.deviceID, World.all), (h.phoneID, ["look", "decide"])], epoch: 2, listSeq: 9)
        #expect(failure(f) { try f.verify(list: epoch2) } == "pending")                    // no grant for epoch 2 yet: stays joining
        let g2 = try await h.host.grant(for: DemoKeys(h.env.device.publicKeys), epoch: 2)
        #expect(failure(f) { try f.verify(list: epoch2, grants: f.grants + [g2]) } == nil)
        // a grant for epoch 3 (a later rotation) against an epoch-2 list is not the list's epoch
        let g3 = try await h.host.grant(for: DemoKeys(h.env.device.publicKeys), epoch: 3)
        #expect(failure(f) { try f.verify(list: epoch2, grants: [g3]) } == "JoinFailure(reason: \"grant_epoch\")")
        // a grant signed by another key, or for another device, is not a grant
        #expect(failure(f) { try f.verify(grants: []) } == "JoinFailure(reason: \"grant\")")
        let foreign = try WKGrant.make(wsk: SoftwareSigner(), workspace: h.host.workspace, device: h.phoneID, deviceKey: h.env.device.publicKeys.kx, epoch: 1, wk: SymmetricKey(size: .bits256)).json
        #expect(failure(f) { try f.verify(grants: [foreign]) } == "JoinFailure(reason: \"grant\")")
        // a list signed by anyone but the pinned WSK
        #expect(failure(f) { try f.verify(wsk: h.primary.publicKey) } == "JoinFailure(reason: \"card_identity\")")
        let forgedList = try FakeHostForgery.list(workspace: h.host.workspace, members: [(h.phoneID, ["look", "decide"])], seq: 9)
        #expect(failure(f) { try f.verify(list: forgedList) } == "JoinFailure(reason: \"member_list\")")
        // end to end: a host that leaves the device out of the list, or claims a later epoch than it lists
        // (the relay serves grants only to listed members, so the phone waits, then offers a retry; nothing is installed)
        let o = try await PairHarness.make(.firstTime)
        await o.host.setHostile { $0.omitFromList = true }
        #expect(try await o.completeFirstTime() == .failed(.joiningTimedOut))
        let held = try await o.env.index.workspaces()
        #expect(held.isEmpty && o.vaultItems.map(\.purpose) == ["pairing"])
        await o.coordinator.cancel()
        #expect(o.vaultItems.isEmpty)
        let e = try await PairHarness.make(.firstTime)
        await e.host.setHostile { $0.approvedEpoch = 5 }
        #expect(try await e.completeFirstTime() == .failed(.verification(reason: "member_epoch")))
        let none = try await e.env.index.workspaces()
        #expect(none.isEmpty && e.vaultItems.isEmpty)
    }

    @Test func testJoinCommitsOneWorkspaceAndEveryPieceOrNone() async throws {
        let h = try await PairHarness.make(.firstTime)
        guard case .ready(let handle) = try await h.completeFirstTime() else { Issue.record("not ready"); return }
        let j = handle.joined
        #expect(j.name == "Laptop" && j.epoch == 1 && j.generation == 1 && j.origin == DemoRelay.origin)
        let ws = try await h.env.index.workspaces()
        #expect(ws.map(\.ws) == [h.host.workspace.hex])
        let profile = try #require(try await h.env.index.profile(ws: h.host.workspace.hex))
        #expect(profile.name == "Laptop" && profile.cardSeq == 1 && profile.epoch == 1 && profile.origin == DemoRelay.origin)
        #expect(profile.wskPub == B64U.encode(h.host.wskPublic.x963) && profile.pkPub == B64U.encode(h.primary.publicKey.x963))
        // the pending record is gone; WK_1 and the (kept) certificate are in the vault; the pairing secret is not
        let purposes = Set(h.vaultItems.map(\.purpose))
        #expect(purposes == ["wk.1"])
        #expect(try h.vault.scoped(to: .demo).get(purpose: "device.cert").isEmpty == false)
        #expect(try await h.env.index.pairings().isEmpty)
        // the session works: epoch 1 key installed, same workspace
        #expect(try await j.session.currentEpoch() == 1 && j.session.workspace == h.host.workspace)
        // a second pairing of the same workspace is refused while it is on this iPhone
        let again = try await h.rig.newOffer()
        #expect(await PairingCoordinator(h.config).start(link: try h.link(again)) == .failed(.alreadyMember))
        // an existing certificate (D-1) is reused: a second workspace does not ask the primary
        let second = try DemoSetup.makeHost(h.env, primary: h.primary, name: "Desk")
        // directory certificates are immutable per device (cert_conflict otherwise): the primary's stored one is reused
        let stored = await h.relay.certificate(device: h.primary.deviceID)
        let cert: JSONValue
        if let stored { cert = stored } else { cert = try await h.primary.certifyOwnDevice() }
        _ = try await second.publishInitial(relay: h.relay, transport: h.env.transport, devices: [(h.primary.deviceKeys, cert, World.all)])
        let offer2 = try await second.createOffer()
        let c2 = PairingCoordinator(h.config)
        _ = await c2.start(link: try h.link(offer2))
        for _ in 0..<60 {
            _ = try await second.pumpPairing(relay: h.relay, transport: h.env.transport)
            await c2.poll(); h.clock.advance(milliseconds: 1000)
            if isComparingHost(await c2.state) { break }
        }
        try await second.approvePairing(device: h.phoneID, confirmedComparison: true, relay: h.relay, transport: h.env.transport)
        for _ in 0..<60 {
            _ = try await second.pumpPairing(relay: h.relay, transport: h.env.transport)
            await c2.poll(); h.clock.advance(milliseconds: 1000)
            if (await c2.state).isTerminal { break }
        }
        #expect(isReady(await c2.state))
        #expect(await h.primary.openPrompts().isEmpty)
    }
}

typealias JoinPendingMarker = PairingCoordinator.JoinPendingError
