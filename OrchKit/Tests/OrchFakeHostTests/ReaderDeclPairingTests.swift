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
        // a record without the H12d keys (what an earlier build wrote) decodes, and stays without a declaration
        let raw = try #require(try StrictJSON.parse(try rec.encode()).object)
        #expect(raw["reader_decl"] == nil && raw["reader_build"] == nil)
        let legacy = try #require(PairingRecord.decode(try rec.encode()))
        #expect(legacy.readerDecl == nil && legacy.readerBuild == nil && legacy.attempt == rec.attempt)
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
        try ReaderStore.save(vault, ws: h.host.workspace, st.recording(zero, build: "0.9 (1)", acked: false))      // a real save, a real load
        let reloaded = try #require(try ReaderStore.load(vault, ws: h.host.workspace))
        #expect(reloaded.highest == 1 && reloaded.decl == zero && reloaded.build == "0.9 (1)")
        #expect(!ReaderGate.opens(reloaded, runningLevel: 0))
        try vault.put(Data("not json".utf8), ws: h.host.workspace.hex, purpose: "reader.state")
        let out = try await WorkspaceRestoration.restore(restoreConfig(h, level(1)))
        #expect(out.handles.isEmpty && out.skipped.map(\.reason) == ["reader_state"])
    }

    @Test func aLockedVaultIsNotADowngradeNorASkip() async throws {
        let h = try await joined()
        h.lock.isLocked = true
        #expect(throws: ReaderStoreError.locked) { _ = try ReaderStore.load(h.vault.scoped(to: .demo), ws: h.host.workspace) }
        await #expect(throws: (any Error).self) { _ = try await WorkspaceRestoration.restore(restoreConfig(h, level(1))) }
        h.lock.isLocked = false
        let ok = try await WorkspaceRestoration.restore(restoreConfig(h, level(1)))
        #expect(ok.handles.count == 1 && ok.skipped.isEmpty)
        await h.env.context.shutdownParticipants()
    }

    @Test func aCorruptMarkerGivesADistinctSessionError() async throws {
        let h = try await joined()
        let ok = try #require(try await WorkspaceRestoration.restore(restoreConfig(h, level(1))).handles.first)
        let cfg = ok.joined.session.configuration
        await h.env.context.shutdownParticipants()
        try h.vault.scoped(to: .demo).put(Data("x".utf8), ws: h.host.workspace.hex, purpose: "reader.state")
        await #expect(throws: SessionError.readerStateUnreadable) { _ = try await WorkspaceSession(cfg) }
    }

    @Test func aWorkspaceFromBeforeH12dOpensAndDeclaresOnFirstLaunch() async throws {
        let h = try await joined()
        try h.vault.scoped(to: .demo).delete(ws: h.host.workspace.hex, purpose: "reader.state")            // no marker at all
        let out = try await WorkspaceRestoration.restore(restoreConfig(h, level(1)))
        let session = try #require(out.handles.first).joined.session
        let before = try await session.readerState()
        #expect(out.skipped.isEmpty && before == nil)
        let req = try #require(try await session.readerDeclareRequest())
        #expect(req.declaration.via == "declare" && req.declaration.level == 1)
        let st = try #require(try await session.readerState())
        #expect(st.highest == 1 && !st.acked && st.decl == req.declaration)
        await h.env.context.shutdownParticipants()
    }

    @Test func aFastPhoneClockDoesNotMakeTheDeclarationFutureDated() async throws {
        // 10 minutes fast: the first pair request is refused as stale (proving nothing is stored), the offset is adopted and the
        // declaration is signed again with host time
        let h = try await PairHarness.make(.firstTime, phoneSkewMs: 600_000, reader: ReaderRuntime(capability: ReaderKAT.current, build: ReaderDeclPairingTests.build))
        _ = await h.coordinator.start(link: try h.link(try await h.rig.newOffer()))
        let initial = try #require(h.pairingRecord?.readerDecl)
        #expect(initial.createdMs > h.clock.nowMs + 300_000)                  // as first built: future-dated for the host
        _ = try await h.drive(until: isComparingHost)
        let rec = try #require(h.pairingRecord)
        let d = try #require(rec.readerDecl)
        #expect(d.bytes != initial.bytes)
        let (stored, verdict) = try #require(await h.host.pairingReaderDecl(of: rec.deviceID))
        #expect(verdict == .success(1) && stored == d.json)                     // the next request carried the corrected declaration
        #expect(d.createdMs <= h.clock.nowMs + 300_000 && abs(d.createdMs - h.clock.nowMs) < 120_000, "created \(d.createdMs) host \(h.clock.nowMs)")
        #expect(rec.offsetMs != 0)
    }

    @Test func aRestartWithTheClockMovedBackButNoStaleTimestampDoesNotSignAgain() async throws {
        // 100 s fast: inside the host window, so no stale_timestamp. The phone clock then steps back (NTP) across a restart.
        let h = try await PairHarness.make(.firstTime, phoneSkewMs: 100_000, reader: ReaderRuntime(capability: ReaderKAT.current, build: ReaderDeclPairingTests.build))
        _ = await h.coordinator.start(link: try h.link(try await h.rig.newOffer()))
        let d1 = try #require(h.pairingRecord?.readerDecl)
        var cfg = h.config
        cfg.wall = SkewedWall(base: h.clock, skewMs: 0)
        let restarted = PairingCoordinator(cfg)
        _ = await restarted.resume(ws: h.host.workspace)
        await restarted.poll()
        h.clock.advance(milliseconds: 20_000)
        await restarted.poll()
        let after = try #require(PairingRecord.decode(try h.vault.scoped(to: .demo).get(ws: h.host.workspace.hex, purpose: "pairing")))
        #expect(after.readerDecl?.bytes == d1.bytes)
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
        // column R: a READ frame, no idem (a read with one is req.invalid), no rd (exempt)
        #expect(try req.meta() == ["op": "reader.declare", "args": ["reader_decl": req.declaration.json]])
        let wire = try req.meta()
        #expect(wire.object?["idem"] == nil && wire.object?["rd"] == nil)
        #expect(R2.allOps["reader.declare"]?.kind == .read && R2.ops["reader.declare"] != nil)
        #expect(throws: R2.MetaError.reqInvalid) { try R2.checkMeta(["op": "reader.declare", "args": [:], "idem": "01J9ZK4Q7M3R8T2V6X0B5N1C9D"]) }
        #expect(throws: R2.MetaError.reqInvalid) { try R2.checkMeta(["op": "reader.declare", "args": [:], "rd": .string("sha256:" + String(repeating: "a", count: 64))]) }
        let idk = try h.env.context.deviceIdentity(custody: h.custody, createIfMissing: false)
        var ctx = ReaderDecl.Context(workspace: h.host.workspace, dkSig: idk.publicKeys.sig, dkKx: idk.publicKeys.kx,
                                     who: .person(Identifiers.personID(await h.primary.publicKey)), bind: .declare)
        ctx.expectedKAT = [1: ["view": ReaderKAT.expectedView1]]
        #expect(ReaderDecl.check(req.declaration.json, ctx) == .success(1))
        let st = try #require(try await session.readerState())
        #expect(!st.acked && st.build == "1.1 (8)" && st.highest == 1 && st.decl == req.declaration)
        // a retry re-sends the stored bytes; once acknowledged nothing is due
        #expect(try await session.readerDeclareRequest()?.declaration.bytes == req.declaration.bytes)
        #expect(try await session.readerDeclareAcknowledged(digest: "sha256:" + String(repeating: "0", count: 64)) == false)   // another digest: nothing
        let notYet = try await session.readerState()
        #expect(notYet?.acked == false)
        #expect(try await session.readerDeclareAcknowledged(digest: req.declaration.digest))
        #expect(try await session.readerDeclareRequest() == nil)
        #expect(try await session.currentReaderDigest() == req.declaration.digest)
        await h.env.context.shutdownParticipants()
    }

    @Test func requestsWaitForTheDeclarationOnceRdIsSwitchedOn() async throws {
        let h = try await joined()
        let handle = try #require(try await WorkspaceRestoration.restore(restoreConfig(h, level(1, build: "2.0 (1)"))).handles.first)
        var cfg = handle.joined.session.configuration
        // a restored session sends `rd` and does not wait for a declaration (H12d-3 is not built); the O5 gate stays available
        #expect(cfg.sendsReaderDigest && !cfg.blocksUntilDeclared)
        cfg.blocksUntilDeclared = true
        await h.env.context.shutdownParticipants()
        let s = try await WorkspaceSession(cfg)
        await #expect(throws: SessionError.readerDeclarationRequired) { _ = try await s.readerDigestForRequest() }
        var relaxed = cfg; relaxed.blocksUntilDeclared = false
        let r2 = try await WorkspaceSession(relaxed)
        _ = try await r2.readerDigestForRequest()            // does not throw: reads are not blocked while no declaration can be sent
        _ = try await s.readerDeclareRequest()
        let r = try #require(try await s.readerDeclareRequest())
        #expect(try await s.readerDeclareAcknowledged(digest: r.declaration.digest))
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

/// H12d `rd` through the session's real `prepare` (protocol 8.6): the stored, sealed request carries it.
@Suite struct ReaderDigestPrepareTests {
    final class Seen: @unchecked Sendable {
        private let lock = NSLock(); private var metas: [JSONValue] = []
        func add(_ m: JSONValue) { lock.withLock { metas.append(m) } }
        var all: [JSONValue] { lock.withLock { metas } }
    }

    /// A World whose phone holds a stored declaration (as after a pairing) and sends `rd`.
    private func world(faults: any FaultPolicy = NoFaults(), sends: Bool = true) async throws -> (World, Phone, ReaderDeclaration) {
        let w = try await World.make(faults: faults)
        let id = w.env.device
        let decl = try ReaderDeclaration.make(workspace: w.ws, dkSig: id.publicKeys.sig, dkKx: id.publicKeys.kx, who: .pkPin(Data(repeating: 7, count: 32)),
                                              level: 1, kat: ReaderKAT.current!.kat, bind: .pair(offer: ID16.fresh(3), attempt: String(repeating: "a", count: 32)),
                                              createdMs: w.clock.nowMs, signer: id.sig)
        let rt = ReaderRuntime(capability: ReaderKAT.current, build: ReaderDeclPairingTests.build)
        try ReaderStore.save(w.vault.scoped(to: .demo), ws: w.ws, ReaderStateRecord(decl: decl, highest: 1, build: rt.build, acked: true))
        let p = try await w.makePhone(reader: rt, sendsReaderDigest: sends)
        return (w, p, decl)
    }

    @Test func aPlainRequestAndAnAnswerCarryRdInTheSealedMeta() async throws {
        let (w, p, decl) = try await world()
        let seen = Seen()
        // the fake host's views demand exact field sets, so it is handed the request WITHOUT `rd` (recorded first)
        await w.host.setHandler { req in
            seen.add(req.meta)
            var m = req.meta.object ?? [:]; m["rd"] = nil
            return await w.host.handleView(HostRequest(device: req.device, scopes: req.scopes, meta: .object(m), data: req.data, epoch: req.epoch))
        }
        let api = BridgeWorkspaceAPI(session: p.session)
        let snap = try await w.serve(p) { try await api.snapshot() }
        let review = try await w.serve(p) { try await api.review(questionID: snap.questions[0].questionID) }
        let snapshot = try #require(review.snapshot)
        _ = try? await w.serve(p) { try await api.answer(snapshot, option: "approve") }
        let metas = seen.all
        #expect(metas.count >= 3)
        for m in metas { #expect(m.object?["rd"] == .string(decl.digest), "\(m.object?["op"]?.string ?? "?")") }
        // `rd` sits beside `op`, outside the signed event: the event in `args` is exactly the one signed
        let answer = try #require(metas.first { $0.object?["op"] == "answer" })
        var bare = answer.object!; bare["rd"] = nil
        #expect(Set(bare.keys) == ["op", "args", "idem"])
        #expect(bare["args"]?.object?["events"]?.array?.first?.object?["rd"] == nil)
    }

    @Test func withTheSwitchOffNothingCarriesRd() async throws {
        let (w, p, _) = try await world(sends: false)
        let seen = Seen()
        await w.host.setHandler { req in seen.add(req.meta); return await w.host.handleView(req) }
        _ = try await w.serve(p) { try await BridgeWorkspaceAPI(session: p.session).snapshot() }
        #expect(!seen.all.isEmpty && seen.all.allSatisfy { $0.object?["rd"] == nil })
    }

    @Test func theSizeLimitAppliesAfterRdIsInjected() async throws {
        let faults = ScriptedFaults().enqueue(.drop, at: .beforeQueue)
        let (_, p, _) = try await world(faults: faults)
        let meta = httpGet
        let base = try Bridge.frame(meta: meta, data: Data()).count
        // exactly the largest request that fits WITHOUT rd
        let data = Data(count: Bridge.maxRequest - Bridge.overhead - base)
        await #expect(throws: SessionError.tooLarge) { _ = try await p.session.exchange(meta: meta, data: data) }
    }

    @Test func aNewRidReplacementRefreshesRdAndASameRidReSealKeepsTheFirst() throws {
        let old = "sha256:" + String(repeating: "1", count: 64), new = "sha256:" + String(repeating: "2", count: 64)
        let first = try ReaderRD.inject(into: Bridge.frame(meta: ["op": "http"]), rd: old)
        let reseal = try ReaderRD.inject(into: first, rd: new, overwrite: false)
        #expect(try Bridge.unframe(reseal).meta.object?["rd"] == .string(old))
        let replaced = try ReaderRD.inject(into: first, rd: new, overwrite: true)
        #expect(try Bridge.unframe(replaced).meta.object?["rd"] == .string(new))
        // the alternative placement is inside `args` of a t:"req" frame, and leaves other frames alone
        let frame = try Bridge.frame(meta: ["t": "req", "op": "x", "args": [:]])
        #expect(try Bridge.unframe(ReaderRD.inject(into: frame, rd: new, placement: .argsField)).meta.object?["args"]?.object?["rd"] == .string(new))
        let plain = try Bridge.frame(meta: ["op": "http"])
        #expect(try ReaderRD.inject(into: plain, rd: new, placement: .argsField) == plain)
    }

    @Test func readerDeclareIsExemptFromRd() async throws {
        let faults = ScriptedFaults().enqueue(.drop, at: .beforeQueue)
        let (w, p, decl) = try await world(faults: faults)
        let cert: JSONValue = ["cert": .object([:]), "pk_pub": .string(B64U.encode(w.env.device.publicKeys.sig.x963))]
        try w.vault.scoped(to: .demo).put(try canonicalJSON(cert), purpose: "device.cert")
        // a new build: other ops would wait for the declaration, the declare itself does not
        let rt = ReaderRuntime(capability: ReaderKAT.current, build: "9.9 (9)")
        var cfg = p.session.configuration; cfg.reader = rt
        let s = try await WorkspaceSession(cfg)
        await #expect(throws: SessionError.readerDeclarationRequired) { _ = try await s.exchange(meta: httpGet) }
        let req = try #require(try await s.readerDeclareRequest())
        await #expect(throws: TransportError.disconnected) { _ = try await s.exchange(meta: try req.meta()) }
        let stored = try await s.pendingRequests()
        #expect(stored.count == 1)
        _ = decl
    }
}
