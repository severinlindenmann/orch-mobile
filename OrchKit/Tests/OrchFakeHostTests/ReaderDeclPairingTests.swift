import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
@testable import OrchClient
@testable import OrchFakeHost
@testable import OrchProtocol

/// H12d on the phone's pairing path: pair meta v2 (`reader_decl`, protocol 8.3), its persistence with the attempt, and the reader state
/// written at the join (host 9.3, 9.5; 11A.15.6 step 4).
@Suite struct ReaderDeclPairingTests {
    static let build = "1.0 (7)"
    static func harness(capability: ReaderKAT.Capability?? = nil, scenario: PairingScenario = .firstTime) async throws -> PairHarness {
        try await PairHarness.make(scenario, reader: ReaderRuntime(capability: capability ?? ReaderKAT.current, build: build))
    }

    @Test func pairMetaV2CarriesAVerifiableDeclarationBoundToTheAttempt() async throws {
        let h = try await Self.harness()
        let (offer, _) = try await h.startToHostCode()
        let rec = try #require(h.pairingRecord)
        let decl = try #require(rec.readerDecl)
        let (hostDecl, verdict) = try #require(await h.host.pairingReaderDecl(of: rec.deviceID))
        #expect(hostDecl == decl.json)                                         // verbatim
        #expect(verdict == .success(1))
        let o = try #require(decl.json.object?["o"]?.object)
        #expect(o["bind"] == ["via": "pair", "offer_id": .string(offer.offerID.hex), "attempt": .string(rec.attempt)])
        #expect(o["who"] == ["pk_pin": .string(B64U.encode(rec.pkPin))])        // no certificate: the link's pk_pin
        #expect(o["workspace_id"] == .string(rec.ws.hex) && o["device_id"] == .string(rec.deviceID.hex))
        #expect(o["kat"] == ["1": ["view": .string(ReaderKAT.expectedView1)]])
        #expect(decl.level == 1)
    }

    @Test func aCertifiedPhoneDeclaresItsPerson() async throws {
        let h = try await Self.harness(scenario: .existingCert)
        try await h.rig.enrollExistingCertificate(into: h.config)
        _ = await h.coordinator.start(link: try h.link(try await h.rig.newOffer()))
        await h.coordinator.poll()
        _ = try await h.drive(steps: 20, until: { _ in false })
        let rec = try #require(h.pairingRecord)
        let o = try #require(rec.readerDecl?.json.object?["o"]?.object)
        let who = try #require(o["who"]?.object?["person_id"]?.string)
        #expect(who == Identifiers.personID(await h.primary.publicKey).hex)
        let (_, verdict) = try #require(await h.host.pairingReaderDecl(of: rec.deviceID))
        #expect(verdict == .success(1))
    }

    @Test func theDeclarationIsPersistedWithTheAttemptAndResendsAreByteIdentical() async throws {
        let h = try await Self.harness()
        _ = try await h.startToHostCode()
        let first = try #require(h.pairingRecord)
        let bytes = try #require(first.readerDecl?.bytes)
        // encode/decode keeps the exact canonical bytes
        let again = try #require(PairingRecord.decode(try first.encode()))
        #expect(again.readerDecl?.bytes == bytes && again.readerDecl?.digest == first.readerDecl?.digest)
        // a restarted coordinator resumes with the stored declaration; the host's first stored declaration stays
        let before = try #require(await h.host.pairingReaderDecl(of: first.deviceID)).decl
        let restarted = PairingCoordinator(h.config)
        _ = await restarted.resume(ws: h.host.workspace)
        await restarted.poll()
        h.clock.advance(milliseconds: 20_000)
        await restarted.poll()
        let after = try #require(PairingRecord.decode(try h.vault.scoped(to: .demo).get(ws: h.host.workspace.hex, purpose: "pairing")))
        #expect(after.readerDecl?.bytes == bytes)
        #expect(try #require(await h.host.pairingReaderDecl(of: first.deviceID)).decl == before)
    }

    @Test func aBuildWhoseKATFailedSendsTheSixFieldMetaAndDeclaresNothing() async throws {
        let h = try await Self.harness(capability: .some(nil))
        _ = try await h.startToHostCode()
        let rec = try #require(h.pairingRecord)
        #expect(rec.readerDecl == nil)
        #expect(await h.host.pairingReaderDecl(of: rec.deviceID) == nil)
    }

    @Test func theJoinStoresTheDeclarationAndTheHighestLevelInTheKeysVault() async throws {
        let h = try await Self.harness()
        _ = try await h.startToHostCode()
        let decl = try #require(h.pairingRecord?.readerDecl)
        try await h.hostApproves()
        guard case .comparingPrimary = try await h.drive(until: isComparingPrimary) else { Issue.record("not comparingPrimary"); return }
        try await h.primaryApproves()
        let end = try await h.drive(until: { $0.isTerminal })
        guard case .ready = end else { Issue.record("\(end)"); return }
        let st = try #require(try ReaderStore.load(h.vault.scoped(to: .demo), ws: h.host.workspace))
        #expect(st.highest == 1 && st.decl?.bytes == decl.bytes && st.acked && st.build == Self.build)
        #expect(ReaderGate.rd(st) == decl.digest)
        // it lives in the `.keys` group beside the device keys, under the workspace's tag
        #expect(h.vaultItems.contains { $0.purpose == "reader.state" })
    }

    @Test func aNoDeclarationBuildStoresLevelZero() async throws {
        let h = try await Self.harness(capability: .some(nil))
        try await h.completeFirstTime()
        let st = try #require(try ReaderStore.load(h.vault.scoped(to: .demo), ws: h.host.workspace))
        #expect(st.highest == 0 && st.decl == nil)
        #expect(ReaderGate.rd(st) == nil)
    }
}

/// H12d persistence rules after the join: the downgrade refusal (O3), the re-declaration on a new build (O5) and `rd` (protocol 8.6).
@Suite struct ReaderStateRulesTests {
    private func joined(build: String = ReaderDeclPairingTests.build) async throws -> PairHarness {
        let h = try await ReaderDeclPairingTests.harness()
        try await h.completeFirstTime()
        await h.env.context.shutdownParticipants()
        return h
    }

    private func restoreConfig(_ h: PairHarness, _ reader: ReaderRuntime) -> RestoreConfig {
        RestoreConfig(context: h.env.context, transport: h.env.transport, index: h.env.index, vault: h.vault, custody: h.custody, clock: h.clock,
                      wall: h.clock, reader: reader)
    }

    private func level(_ l: Int, build: String = ReaderDeclPairingTests.build) -> ReaderRuntime {
        ReaderRuntime(capability: l == 0 ? nil : ReaderKAT.current, build: build)
    }

    @Test func aBuildBelowTheMarkerRefusesToOpenTheWorkspace() async throws {
        let h = try await joined()
        let out = try await WorkspaceRestoration.restore(restoreConfig(h, level(0)))
        #expect(out.handles.isEmpty && out.skipped.map(\.reason) == [ReaderGate.skipReason])
        #expect(ReaderGate.updateMessage == "Update orch to open this workspace")
        // the workspace is kept (nothing erased), and a build at the marker's level opens it
        #expect(try await h.env.index.workspaces().count == 1)
        let ok = try await WorkspaceRestoration.restore(restoreConfig(h, level(1)))
        #expect(ok.handles.count == 1 && ok.skipped.isEmpty)
        await h.env.context.shutdownParticipants()
    }

    @Test func aSessionBuiltDirectlyBelowTheMarkerIsRefused() async throws {
        let h = try await joined()
        let ok = try #require(try await WorkspaceRestoration.restore(restoreConfig(h, level(1))).handles.first)
        var cfg = ok.joined.session.configuration
        cfg.reader = level(0)
        await #expect(throws: SessionError.readerDowngrade) { _ = try await WorkspaceSession(cfg) }
        await h.env.context.shutdownParticipants()
    }

    @Test func theMarkerNeverFallsAndAnUnreadableOneFailsClosed() async throws {
        let h = try await joined()
        let vault = h.vault.scoped(to: .demo)
        let st = try #require(try ReaderStore.load(vault, ws: h.host.workspace))
        // a later lower-level state (a level-0 declaration after a failed KAT) does not lower the highest level
        let id = try h.env.context.deviceIdentity(custody: h.custody, createIfMissing: false)
        let zero = try ReaderDeclaration.make(workspace: h.host.workspace, dkSig: id.publicKeys.sig, dkKx: id.publicKeys.kx,
                                              who: .person(Identifiers.personID(await h.primary.publicKey)), level: 0, kat: [:], bind: .declare,
                                              createdMs: 1, signer: id.sig)
        let lowered = st.recording(zero, build: "0.9 (1)", acked: false)
        #expect(lowered.highest == 1)
        try vault.put(Data("not json".utf8), ws: h.host.workspace.hex, purpose: "reader.state")
        let out = try await WorkspaceRestoration.restore(restoreConfig(h, level(1)))
        #expect(out.handles.isEmpty && out.skipped.map(\.reason) == ["reader_state"])
    }

    @Test func aNewBuildDeclaresAgainBeforeAnyOtherOp() async throws {
        let h = try await joined()
        let first = try #require(try ReaderStore.load(h.vault.scoped(to: .demo), ws: h.host.workspace)?.decl)
        // same build, acknowledged: nothing to declare
        let same = try #require(try await WorkspaceRestoration.restore(restoreConfig(h, level(1))).handles.first).joined.session
        #expect(try await same.readerDeclareRequest() == nil)
        await h.env.context.shutdownParticipants()
        // a new build: a fresh `via:"declare"` declaration, persisted unacknowledged, the marker kept
        let newBuild = level(1, build: "1.1 (8)")
        let handle = try #require(try await WorkspaceRestoration.restore(restoreConfig(h, newBuild)).handles.first)
        let session = handle.joined.session
        let req = try #require(try await session.readerDeclareRequest())
        #expect(req.declaration.via == "declare" && req.declaration.digest != first.digest && req.declaration.level == 1)
        #expect(req.meta == ["op": "reader.declare", "reader_decl": req.declaration.json])
        let idk = try h.env.context.deviceIdentity(custody: h.custody, createIfMissing: false)
        var ctx = ReaderDecl.Context(workspace: h.host.workspace, dkSig: idk.publicKeys.sig, dkKx: idk.publicKeys.kx,
                                     who: .person(Identifiers.personID(await h.primary.publicKey)), bind: .declare)
        ctx.expectedKAT = [1: ["view": ReaderKAT.expectedView1]]
        #expect(ReaderDecl.check(req.declaration.json, ctx) == .success(1))
        let st = try #require(try await session.readerState())
        #expect(!st.acked && st.build == "1.1 (8)" && st.highest == 1 && st.decl == req.declaration)
        // a retry re-sends the stored bytes; once acknowledged nothing is due
        #expect(try await session.readerDeclareRequest()?.declaration.bytes == req.declaration.bytes)
        try await session.readerDeclareAcknowledged()
        #expect(try await session.readerDeclareRequest() == nil)
        #expect(try await session.currentReaderDigest() == req.declaration.digest)
        await h.env.context.shutdownParticipants()
    }

    @Test func requestsWaitForTheDeclarationOnceRdIsSwitchedOn() async throws {
        let h = try await joined()
        let handle = try #require(try await WorkspaceRestoration.restore(restoreConfig(h, level(1, build: "2.0 (1)"))).handles.first)
        var cfg = handle.joined.session.configuration
        cfg.sendsReaderDigest = true
        await h.env.context.shutdownParticipants()
        let s = try await WorkspaceSession(cfg)
        await #expect(throws: SessionError.readerDeclarationRequired) { _ = try await s.readerDigestForRequest() }
        _ = try await s.readerDeclareRequest()
        try await s.readerDeclareAcknowledged()
        #expect(try await s.readerDigestForRequest() == (try await s.currentReaderDigest()))
        // with the switch off (today) no request carries `rd` and nothing waits
        var off = cfg; off.sendsReaderDigest = false
        await h.env.context.shutdownParticipants()
        let t = try await WorkspaceSession(off)
        #expect(try await t.readerDigestForRequest() == nil)
        await h.env.context.shutdownParticipants()
    }

    @Test func rdIsInjectedOnceIntoTheSealedMetaAndIsStable() throws {
        let rd = "sha256:" + String(repeating: "a", count: 64)
        let plain = try Bridge.frame(meta: ["op": "http", "method": "GET", "path": "/api/status"], data: Data("x".utf8))
        let with = try ReaderRD.inject(into: plain, rd: rd)
        let (meta, data) = try Bridge.unframe(with)
        #expect(meta.object?["rd"] == .string(rd) && meta.object?["op"] == "http" && data == Data("x".utf8))
        // idempotent and first-wins (a re-seal of a request keeps its first rd); nil rd leaves the bytes alone
        #expect(try ReaderRD.inject(into: with, rd: "sha256:" + String(repeating: "b", count: 64)) == with)
        #expect(try ReaderRD.inject(into: plain, rd: nil) == plain)
        #expect(try ReaderRD.inject(into: plain, rd: rd) == with)
    }
}
