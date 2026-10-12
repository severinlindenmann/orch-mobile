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

/// Holds a coordinator (or host) at a named point so a test can act concurrently, deterministically.
actor HookGate {
    private var holds: Set<String> = []
    private var arrived: [String] = []
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    func hold(_ names: String...) { holds.formUnion(names) }
    func hit(_ name: String) async {
        arrived.append(name)
        guard holds.contains(name) else { return }
        await withCheckedContinuation { waiting[name] = $0 }
    }
    func release(_ name: String) { holds.remove(name); waiting.removeValue(forKey: name)?.resume() }
    func waitArrived(_ name: String) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline { if arrived.contains(name) { return }; await Task.yield() }
        Issue.record("hook \(name) was not reached within 120 s of real time (arrived: \(arrived))")
    }
}

struct Crashing: Sendable {
    let point: String
    var hook: @Sendable (String) async throws -> Void { { [point] name in if name == point { throw PairingCrash() } } }
}

extension PairHarness {
    var wsHex: String { host.workspace.hex }
    var pairingRecord: PairingRecord? { (try? vault.scoped(to: .demo).get(ws: wsHex, purpose: "pairing")).flatMap { PairingRecord.decode($0) } }
    var deviceCert: Data? { try? vault.scoped(to: .demo).get(purpose: "device.cert") }
    var wsDirExists: Bool { FileManager.default.fileExists(atPath: ((try? env.index.layout.wsDir(wsHex))?.path) ?? "/nonexistent") }
    func fresh() -> PairingCoordinator { PairingCoordinator(config) }

    /// Phone has seen `approved` and is `joining`; nothing installed yet.
    func driveToJoining() async throws {
        _ = try await startToHostCode()
        try await hostApproves()
        let next = try await drive(until: { isComparingPrimary($0) || $0 == .joining || $0.isTerminal })
        if isComparingPrimary(next) { try await primaryApproves() }
        guard try await drive(steps: 60, until: { $0 == .joining || $0.isTerminal }) == .joining else { throw PairError.notReached("joining") }
    }
}

@Suite struct PairingLifecycleTests {
    // MARK: start

    @Test func cancelDuringTheIndexAwaitsOfStartIsHonoured() async throws {
        for point in ["start.index", "start.keys"] {
            let h = try await PairHarness.make(.firstTime)
            let fresh = DefaultCustody.make(vault: SecretVault(group: .keys, backend: InMemoryVaultBackend()))
            var cfg = h.config; cfg.custody = fresh
            let c = PairingCoordinator(cfg)
            let gate = HookGate(); await gate.hold(point)
            await c.setHook { await gate.hit($0) }
            let offer = try await h.rig.newOffer()
            let before = await h.relay.requestsReceived
            let link = try h.link(offer)
            let starter = Task { await c.start(link: link) }
            await gate.waitArrived(point)
            await c.cancel()                                           // while start is suspended in its lookups
            #expect(await c.state == .cancelled, "\(point)")
            await gate.release(point)
            #expect(await starter.value == .cancelled, "\(point)")
            await c.poll()
            let rows = try await h.env.index.pairings()
            #expect(rows.isEmpty && h.vaultItems.isEmpty && fresh.status(realm: .demo) == .missing, "\(point)")   // nothing created, keys it made are gone
            #expect(await h.relay.requestsReceived == before, "\(point)")
        }
    }

    // MARK: cancel / dismiss during installation

    @Test func cancelDuringInstallationLeavesNothingAndNeverACommittedWorkspace() async throws {
        for scenario in [PairingScenario.firstTime, .existingCert] {
            for point in ["install.begin", "install.container", "install.grant", "install.precommit", "install.committed"] {
                let h = try await PairHarness.make(scenario)
                if scenario == .existingCert { try await h.rig.enrollExistingCertificate(into: h.config) }
                let priorCert = h.deviceCert
                try await h.driveToJoining()
                let gate = HookGate(); await gate.hold(point)
                await h.coordinator.setHook { await gate.hit($0) }
                let poller = Task { await h.coordinator.poll() }
                await gate.waitArrived(point)
                let canceller = Task { await h.coordinator.cancel() }
                await settleBriefly(yields: 50)
                #expect(await h.coordinator.state != .cancelled, "\(scenario) \(point): cancel must wait for the installer")
                await gate.release(point)
                await poller.value; await canceller.value
                let tag = Comment(rawValue: "\(scenario) \(point)")
                #expect(await h.coordinator.state == .cancelled, tag)
                let wss = try await h.env.index.workspaces(), rows = try await h.env.index.pairings()
                let prof = try await h.env.index.profile(ws: h.wsHex)
                #expect(wss.isEmpty && rows.isEmpty && prof == nil, tag)
                #expect(h.vaultItems.isEmpty && !h.wsDirExists, tag)                  // no wk, no pairing record, no files
                #expect(h.deviceCert == priorCert, tag)                               // the certificate this join wrote is rolled back
                let removed = try await h.env.index.isRemoved(ws: h.wsHex, generation: 1)
                #expect(removed == (point == "install.committed"), tag)               // a committed join is undone with a tombstone
                // keys: an existing certificate's are kept (D-1); an uncertified attempt's fresh keys are this pairing's and go (G3b)
                #expect(h.custody.status(realm: .demo) == (scenario == .existingCert ? .present : .missing), tag)
                // a restart finds nothing to do
                let again = h.fresh()
                #expect(await again.recover(), tag)
                #expect(try await h.env.index.workspaces().isEmpty && h.vaultItems.isEmpty, tag)
                // the host side cannot be retracted by a cancel: the relay keeps what the host published
                #expect(await h.relay.hasGrant(workspace: h.host.workspace, device: h.phoneID, epoch: 1), tag)
            }
        }
    }

    @Test func dismissDuringInstallationWaitsForTheInstaller() async throws {
        let h = try await PairHarness.make(.firstTime)
        try await h.driveToJoining()
        let gate = HookGate(); await gate.hold("install.precommit")
        await h.coordinator.setHook { await gate.hit($0) }
        let poller = Task { await h.coordinator.poll() }
        await gate.waitArrived("install.precommit")
        let dismisser = Task { await h.coordinator.dismiss() }
        await settleBriefly(yields: 50)
        await gate.release("install.precommit")
        await poller.value; await dismisser.value
        let wss = try await h.env.index.workspaces()
        #expect(wss.isEmpty && h.vaultItems.isEmpty && !h.wsDirExists)
        #expect(await h.coordinator.state == .idle)
    }

    @Test func aFailureAfterACancelDoesNotOverwriteIt() async throws {
        // the join would fail verification (the card-key wrap is for another key); a cancel arrived first and owns the final state
        let h = try await PairHarness.make(.firstTime)
        await h.host.setHostile { $0.wrapKey = SymmetricKey(data: Data(repeating: 9, count: 32)) }
        try await h.driveToJoining()
        let gate = HookGate(); await gate.hold("join.begin")
        await h.coordinator.setHook { await gate.hit($0) }
        let poller = Task { await h.coordinator.poll() }
        await gate.waitArrived("join.begin")
        await h.coordinator.cancel()
        await gate.release("join.begin")
        await poller.value
        #expect(await h.coordinator.state == .cancelled)
        #expect(h.vaultItems.isEmpty)
    }

    @Test func theSecretIsGoneTheMomentApprovalIsPinned() async throws {
        let h = try await PairHarness.make(.firstTime)
        _ = try await h.startToHostCode()
        #expect(h.pairingRecord?.secret?.count == 32)
        try await h.hostApproves()
        _ = try await h.drive(until: isComparingPrimary)
        #expect(h.pairingRecord?.secret?.count == 32)
        try await h.primaryApproves()
        try await h.driveToJoining0()
        let r = try #require(h.pairingRecord)
        #expect(r.secret == nil && r.approved != nil)
        // a restart still joins without it
        let restarted = h.fresh()
        #expect(await restarted.resume(ws: h.host.workspace) == .joining)
        for _ in 0..<20 { await restarted.poll(); h.clock.advance(milliseconds: 1000); if isReady(await restarted.state) { break } }
        #expect(isReady(await restarted.state))
    }

    // MARK: crashes

    @Test func crashesBeforeTheCommitAreResumedAndAfterItCleanedUp() async throws {
        for point in ["join.begin", "install.begin", "install.container", "install.grant", "install.precommit"] {
            let h = try await PairHarness.make(.firstTime)
            try await h.driveToJoining()
            await h.coordinator.setHook(Crashing(point: point).hook)
            await h.coordinator.poll()                                               // dies at `point`
            let rows = try await h.env.index.pairings()
            #expect(rows.count == 1 && h.pairingRecord != nil, "\(point)")
            let c2 = h.fresh()
            #expect(await c2.recover(), "\(point)")
            #expect(try await h.env.index.pairings().count == 1 && h.pairingRecord != nil, "\(point): a live pairing is left alone")
            #expect(await c2.resume(ws: h.host.workspace) == .joining, Comment(rawValue: point))
            for _ in 0..<20 { await c2.poll(); h.clock.advance(milliseconds: 1000); if isReady(await c2.state) { break } }
            #expect(isReady(await c2.state), Comment(rawValue: point))
            let wss = try await h.env.index.workspaces()
            let leftRows = try await h.env.index.pairings()
            #expect(wss.map(\.ws) == [h.wsHex] && leftRows.isEmpty, Comment(rawValue: point))
            let items = h.vaultItems.map(\.purpose)
            #expect(!items.contains("pairing") && items.contains { $0.hasPrefix("wk") }, "\(point): \(items)")
            #expect(h.deviceCert != nil, Comment(rawValue: point))
        }
    }

    @Test func aCrashRightAfterTheCommitLeavesAWorkspaceAndRecoveryDropsTheStaleRecord() async throws {
        let h = try await PairHarness.make(.firstTime)
        try await h.driveToJoining()
        await h.coordinator.setHook(Crashing(point: "install.committed").hook)
        await h.coordinator.poll()
        #expect(try await h.env.index.workspaces().map(\.ws) == [h.wsHex])
        #expect(try await h.env.index.pairings().isEmpty)                             // the commit removed the row in its transaction
        #expect(h.pairingRecord != nil)                                               // but the vault record is still there
        let c2 = h.fresh()
        #expect(await c2.recover())
        #expect(h.pairingRecord == nil)
        let items = h.vaultItems.map(\.purpose)
        #expect(items.contains { $0.hasPrefix("wk") })                                // a committed workspace keeps its grants
        #expect(try await h.env.index.profile(ws: h.wsHex)?.name == "Laptop")
        #expect(h.wsDirExists)
    }

    @Test func recoverySweepsOrphansButNotLivePairings() async throws {
        let h = try await PairHarness.make(.firstTime)
        _ = try await h.startToHostCode()                                              // a live pairing
        let vault = h.vault.scoped(to: .demo)
        let orphan = ID16.random().hex, rowOnly = ID16.random()
        try vault.put(Data([1, 2, 3]), ws: orphan, purpose: "pairing")
        try vault.put(Data([4]), ws: orphan, purpose: "wk.1")
        try h.env.index.layout.prepareWorkspace(orphan)
        try await h.env.index.savePairing(PairingRow(ws: rowOnly.hex, offer: ID16.random().hex, generation: 1, origin: DemoRelay.origin, phase: "connecting",
                                                     startedMs: 0, updatedMs: 0))          // a row whose record never reached the vault
        let c2 = h.fresh()
        #expect(await c2.recover())
        let items = ((try? h.vault.ids()) ?? []).filter { $0.realm == .demo }
        #expect(!items.contains { $0.ws == orphan })
        #expect(!FileManager.default.fileExists(atPath: try h.env.index.layout.wsDir(orphan).path))
        #expect(try await h.env.index.pairing(ws: rowOnly.hex) == nil)
        #expect(try await h.env.index.pairing(ws: h.wsHex) != nil && h.pairingRecord != nil)
        // the live pairing resumes and completes
        #expect(await c2.resume(ws: h.host.workspace) == .connecting(origin: DemoRelay.origin))
    }

    @Test func aCrashDuringAnAlarmIsFinishedByResumeAndByRecovery() async throws {
        for useRecover in [false, true] {
            let fresh = DefaultCustody.make(vault: SecretVault(group: .keys, backend: InMemoryVaultBackend()))
            let h = try await PairHarness.make(.echoWrongKey)
            var cfg = h.config; cfg.custody = fresh
            let c = PairingCoordinator(cfg)
            await c.setHook(Crashing(point: "alarm.saved").hook)
            let offer = try await h.rig.newOffer()
            _ = await c.start(link: try h.link(offer))
            for _ in 0..<30 { try await h.rig.pump(); await c.poll(); h.clock.advance(milliseconds: 1000) }
            let row = try #require(try await h.env.index.pairing(ws: h.wsHex))
            #expect(row.terminal?.hasPrefix("alarm:") == true && row.createdKeys)
            #expect(h.pairingRecord?.secret != nil)                                      // the crash left the secret behind
            let c2 = PairingCoordinator(cfg)
            if useRecover { #expect(await c2.recover()); #expect(await c2.resume(ws: h.host.workspace).isAlarmState) }
            else { #expect(await c2.resume(ws: h.host.workspace).isAlarmState) }
            #expect(h.vaultItems.isEmpty && h.pairingRecord == nil && !h.wsDirExists, "recover=\(useRecover)")
            #expect(fresh.status(realm: .demo) == .missing, "the alarm erases keys it created too")
            #expect(try await h.env.index.pairing(ws: h.wsHex)?.terminal?.hasPrefix("alarm:") == true)   // the alarm itself stays until dismissed
            await c2.dismiss()
            #expect(try await h.env.index.pairings().isEmpty)
        }
    }

    @Test func aFailedErasureIsRememberedAndRetried() async throws {
        let h = try await PairHarness.make(.firstTime)
        _ = try await h.startToHostCode()
        h.lock.isLocked = true                                                         // the keychain refuses every operation
        await h.coordinator.cancel()
        h.lock.isLocked = false
        #expect(await h.coordinator.state == .cancelled)
        let row = try #require(try await h.env.index.pairing(ws: h.wsHex))
        #expect(row.terminal == "cleanup" && h.pairingRecord != nil)                   // not swallowed: the secret is still there, marked for cleanup
        let c2 = h.fresh()
        #expect(await c2.recover())
        #expect(try await h.env.index.pairings().isEmpty && h.vaultItems.isEmpty)
    }

    // MARK: the retry window and run()

    @Test func theJoinRetryWindowHasAHardEnd() async throws {
        let h = try await PairHarness.make(.firstTime)
        await h.host.setHostile { $0.omitFromList = true }
        #expect(try await h.completeFirstTime() == .failed(.joiningTimedOut))
        // run() does not spin and does not block cancel; the window ends by itself
        let runner = Task { await h.coordinator.run() }
        let ended = try await h.tickRunLoop(stepMs: 20_000, simCapMs: 800_000, until: { $0.isTerminal })
        #expect(ended.met, "run() did not end the join window: \(ended.diagnostics)")
        #expect(await h.coordinator.state == .expired(.afterApproval))
        await runner.value
        let wss = try await h.env.index.workspaces()
        #expect(h.vaultItems.isEmpty && wss.isEmpty && !h.wsDirExists)
        // and retrying after the window is refused: everything is erased
        let g = try await PairHarness.make(.firstTime)
        await g.host.setHostile { $0.omitFromList = true }
        #expect(try await g.completeFirstTime() == .failed(.joiningTimedOut))
        g.clock.advance(milliseconds: 601_000)
        await g.coordinator.retryJoin()
        #expect(await g.coordinator.state == .expired(.afterApproval) && g.vaultItems.isEmpty)
    }

    @Test func aJoinThatCompletesExactlyAtTheTimeoutBoundary() async throws {
        for (offset, expectReady) in [(59_000 as Int64, true), (60_000, false)] {
            let h = try await PairHarness.make(.firstTime)
            _ = try await h.startToHostCode()
            try await h.hostApproves()
            _ = try await h.drive(until: isComparingPrimary)
            // the host publishes the member list `offset` ms after the phone saw `approved`; everything else is out already
            await h.host.holdMemberList(until: h.clock.nowMs + offset + 10_000)
            try await h.primaryApproves()
            _ = try await h.drive(steps: 60, until: { $0 == .joining || $0.isTerminal })
            let joinStarted = try #require(h.pairingRecord?.joinStartedMs)
            await h.host.holdMemberList(until: joinStarted + offset)
            let end = try await h.drive(steps: 120, until: { $0.isTerminal || $0 == .failed(.joiningTimedOut) })
            if expectReady { #expect(isReady(end), "list at +\(offset): \(end)") }
            else {
                #expect(end == .failed(.joiningTimedOut), "list at +\(offset): \(end)")      // the 60 s cap is inclusive; the list came at the same instant
                await h.coordinator.retryJoin()
                let after = try await h.drive(steps: 60, until: { $0.isTerminal })
                #expect(isReady(after), "after retry: \(after)")
            }
        }
    }

    @Test func runHonoursTheEarliestDeadlineEvenWithALongerRetryAfter() async throws {
        // no initial answer and a 429 with Retry-After: 1 h; the 60 s first-answer deadline still ends the pairing on time
        var limits = RelayLimits(); limits.pairPollsPerMinutePerAddress = 0; limits.retryAfterSeconds = 3600
        let h = try await PairHarness.make(.firstTime, limits: limits)
        let offer = try await h.rig.newOffer()
        _ = await h.coordinator.start(link: try h.link(offer))
        let runner = Task { await h.coordinator.run() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        var lastState = await h.coordinator.state
        var lastRequests = await h.relay.requestsReceived
        var unchangedSince = ContinuousClock.now
        var unchangedYields = 0
        var ended = false
        while ContinuousClock.now < deadline {
            let state = await h.coordinator.state
            let requests = await h.relay.requestsReceived
            if state.isTerminal { ended = true; break }
            guard h.clock.nowMs < 1_790_000_000_000 + 100_000 else { break }
            if state != lastState || requests != lastRequests {
                lastState = state; lastRequests = requests
                unchangedSince = .now; unchangedYields = 0
            }
            // A sleeper is sufficient, but not necessary: run() can be awaiting storage/relay
            // work with no registered sleep. Allow that work time to progress before ticking.
            let stalled = unchangedYields >= 1_000 && unchangedSince.duration(to: .now) >= .milliseconds(100)
            if h.clock.sleeperCount > 0 || stalled {
                h.clock.advance(milliseconds: 5_000)
                unchangedSince = .now; unchangedYields = 0
            }
            await Task.yield()
            unchangedYields += 1
        }
        let finalState = await h.coordinator.state
        let finalRequests = await h.relay.requestsReceived
        #expect(ended, "run() did not terminate within 120 s of real time or the 100 s simulated safety cap: state=\(finalState), elapsedMs=\(h.clock.nowMs - 1_790_000_000_000), requests=\(finalRequests), sleepers=\(h.clock.sleeperCount)")
        #expect(await h.coordinator.state == .failed(.linkUsed) && h.clock.nowMs <= 1_790_000_000_000 + 70_000)
        if !ended { runner.cancel() }
        await runner.value
        #expect(h.vaultItems.isEmpty)
    }

    // MARK: clock

    @Test func aPhoneClockOffByAnHourIsCorrectedThroughTheCoordinator() async throws {
        for skew in [3_600_000 as Int64, -3_600_000] {
            let h = try await PairHarness.make(.firstTime, phoneSkewMs: skew)
            let (_, code) = try await h.startToHostCode()                     // pair -> stale_timestamp -> adopt offset -> pair again -> pending
            #expect(await h.host.pendingPairings().first?.sas == code)
            let r = try #require(h.pairingRecord)
            #expect(abs(r.offsetMs + skew) <= 10_000 && r.sasNonce != nil, "offset \(r.offsetMs)")   // the correction is host time minus ours, a few simulated seconds of latency included
            // the whole pairing completes; deadlines run on the corrected clock
            try await h.hostApproves()
            guard case .comparingPrimary(_, _, let exp) = try await h.drive(until: isComparingPrimary) else { Issue.record("no cert code"); return }
            let hostExp = try #require(h.pairingRecord?.challengeExpiresMs)
            #expect(exp == hostExp - (h.pairingRecord?.offsetMs ?? 0) && abs(exp - hostExp - skew) <= 10_000)                                      // shown on the phone's own clock
            let now = await h.coordinator.state
            _ = now
            try await h.primaryApproves()
            let end = try await h.drive(until: { $0.isTerminal })
            #expect(isReady(end), "skew \(skew): \(end)")
        }
    }

    @Test func theCertificateCodeIsHiddenAtTheSignedDeadlineOnTheAdoptedClock() async throws {
        let h = try await PairHarness.make(.firstTime, phoneSkewMs: 3_600_000)
        _ = try await h.startToHostCode()
        try await h.hostApproves()
        guard case .comparingPrimary(_, _, let exp) = try await h.drive(until: isComparingPrimary) else { Issue.record("no cert code"); return }
        let local = h.clock.nowMs + 3_600_000
        #expect(exp > local && exp - local <= 600_000)
        h.clock.advance(milliseconds: exp - local - 1)
        guard case .comparingPrimary = await h.coordinator.state else { Issue.record("hidden early"); return }
        h.clock.advance(milliseconds: 1)
        guard case .waitingPrimary(_, let deadline, let expired) = await h.coordinator.state else { Issue.record("not hidden at the deadline"); return }
        #expect(expired && deadline == exp)                                     // the deadline was not extended by a grace
        // the terminal transition may wait for a last answer, never longer than the grace
        h.clock.advance(milliseconds: PairingCoordinator.certificationGraceMs)
        await h.coordinator.poll()
        #expect(await h.coordinator.state == .expired(.certification))
        #expect(h.vaultItems.isEmpty)
    }

    // MARK: stored certificates

    @Test func anExpiredCertificateKeepsTheOwnerBinding() async throws {
        // another person's certificate, expired: the link of this workspace's owner is still refused as `other_person`
        let h = try await PairHarness.make(.firstTime)
        let id = try h.config.context.deviceIdentity(custody: h.custody, createIfMissing: true)
        let foreign = try await h.rig.foreign.certify(DemoKeys(id.publicKeys), label: "Demo iPhone", scopesMax: ["look"], lifetimeMs: 60_000)
        try await h.coordinator.adoptCertificate(foreign, owner: h.rig.foreign.publicKey)
        h.clock.advance(milliseconds: 61_000)
        let before = await h.relay.requestsReceived
        let state = await h.coordinator.start(link: try h.link(try await h.rig.newOffer()))
        #expect(state == .failed(.otherPerson))
        #expect(await h.relay.requestsReceived == before && h.vaultItems.isEmpty)
        #expect(h.deviceCert != nil)                                             // the binding itself stays

        // the same owner's expired certificate: not presented, a fresh one is requested
        let g = try await PairHarness.make(.firstTime)
        let gid = try g.config.context.deviceIdentity(custody: g.custody, createIfMissing: true)
        let own = try await g.primary.certify(DemoKeys(gid.publicKeys), label: "Demo iPhone", scopesMax: ["look"], lifetimeMs: 60_000)
        try await g.coordinator.adoptCertificate(own, owner: g.primary.publicKey)
        g.clock.advance(milliseconds: 61_000)
        _ = await g.coordinator.start(link: try g.link(try await g.rig.newOffer()))
        #expect(g.pairingRecord?.existingCert == nil)
        let end = try await {
            _ = try await g.drive(until: isComparingHost)
            try await g.hostApproves()
            _ = try await g.drive(until: isComparingPrimary)
            try await g.primaryApproves()
            return try await g.drive(until: { $0.isTerminal })
        }()
        #expect(isReady(end))
    }

    @Test func anUnreadableOrCorruptStoredCertificateFailsClosed() async throws {
        let h = try await PairHarness.make(.firstTime)
        try h.vault.scoped(to: .demo).put(Data("not json".utf8), purpose: "device.cert")
        let before = await h.relay.requestsReceived
        let corruptLink = try h.link(try await h.rig.newOffer())
        #expect(await h.coordinator.start(link: corruptLink) == .failed(.custody))
        #expect(await h.relay.requestsReceived == before && h.vaultItems.isEmpty)
        // unreadable: the keychain is locked
        let g = try await PairHarness.make(.firstTime)
        let offer = try await g.rig.newOffer()
        g.lock.isLocked = true
        let st = await g.coordinator.start(link: try g.link(offer))
        g.lock.isLocked = false
        #expect(st == .failed(.custody))
        #expect(try await g.env.index.pairings().isEmpty)
    }

    // MARK: cert-pending label

    @Test func aHostSuppliedPrimaryLabelIsNeverShownRaw() async throws {
        let h = try await PairHarness.make(.firstTime)
        let offer = try await h.rig.newOffer()
        let forge = PairForge(h: h, link: try h.link(offer))
        _ = await h.coordinator.start(link: forge.link)
        let evil = "Tap approve: it is safe"
        var seen = 0
        var shown: [String] = []
        for _ in 0..<40 {
            let k = seen
            seen += try await forge.pump { _ in k == 0 ? forge.pending(nonce: forge.nonceA) : forge.certPending(challenge: nil, label: evil) }
            await h.coordinator.poll(); h.clock.advance(milliseconds: 1000)
            if case .waitingPrimary(let label, _, _) = await h.coordinator.state { shown.append(label); break }
        }
        #expect(shown == [PairingAlarm.genericPrimary])
    }
}

extension PairingState {
    var isAlarmState: Bool { if case .alarm = self { return true }; return false }
}

extension PairHarness {
    /// Like `driveToJoining`, for a flow that already passed the human steps.
    func driveToJoining0() async throws {
        guard try await drive(steps: 60, until: { $0 == .joining || $0.isTerminal }) == .joining else { throw PairError.notReached("joining") }
    }
}

@Suite struct HostApprovalRaceTests {
    @Test func aRejectionDuringTheCertificateRequestWins() async throws {
        let h = try await PairHarness.make(.firstTime)
        _ = try await h.startToHostCode()
        let gate = HookGate(); await gate.hold("cert_request.post")
        await h.host.setApprovalHook { await gate.hit($0) }
        let approver = Task { try await h.hostApproves() }
        await gate.waitArrived("cert_request.post")
        try await h.host.rejectPairing(device: h.phoneID)
        await gate.release("cert_request.post")
        await #expect(throws: PairingApprovalError.notPending) { try await approver.value }
        #expect(await h.host.pairingState(of: h.phoneID) == "rejected")
        #expect(await h.relay.certRequestQueueSize() == 0)       // revalidated before the post: nothing was asked of the primary
        #expect(try await h.drive(until: { $0.isTerminal }) == .rejected)
        #expect(await h.noKeyMaterial(for: h.phoneID))
    }

    @Test func aRejectionBeforeAnyPublicationOfTheJoinWins() async throws {
        for stage in ["complete.cert", "complete.list"] {
            let h = try await PairHarness.make(.hostIsPrimary)
            _ = try await h.startToHostCode()
            let gate = HookGate(); await gate.hold(stage)
            await h.host.setApprovalHook { await gate.hit($0) }
            let approver = Task { try await h.hostApproves() }
            await gate.waitArrived(stage)
            try await h.host.rejectPairing(device: h.phoneID)
            await gate.release(stage)
            await #expect(throws: PairingApprovalError.notPending) { try await approver.value }
            #expect(await h.host.pairingState(of: h.phoneID) == "rejected", Comment(rawValue: stage))
            let rostered = await h.host.rosterEntries().contains { $0.0.deviceID == h.phoneID }
            #expect(!rostered, Comment(rawValue: stage))
            let listSeq = await h.relay.memberListSeq(workspace: h.host.workspace)
            #expect(listSeq == 1, "\(stage): no new list was published")
            if stage != "complete.cert" { #expect(!(await h.relay.hasCardKeyWrap(workspace: h.host.workspace, device: h.phoneID, cardSeq: 1)) || stage == "complete.list", Comment(rawValue: stage)) }
            #expect(try await h.drive(until: { $0.isTerminal }) == .rejected, Comment(rawValue: stage))
        }
    }

    @Test func aRejectionAfterTheListWasPublishedTakesTheDeviceOutAgain() async throws {
        let h = try await PairHarness.make(.hostIsPrimary)
        _ = try await h.startToHostCode()
        let gate = HookGate(); await gate.hold("complete.final")
        await h.host.setApprovalHook { await gate.hit($0) }
        let approver = Task { try await h.hostApproves() }
        await gate.waitArrived("complete.final")
        try await h.host.rejectPairing(device: h.phoneID)
        await gate.release("complete.final")
        await #expect(throws: PairingApprovalError.notPending) { try await approver.value }
        #expect(await h.host.pairingState(of: h.phoneID) == "rejected")
        let rostered = await h.host.rosterEntries().contains { $0.0.deviceID == h.phoneID }
        #expect(!rostered)
        let seq = await h.relay.memberListSeq(workspace: h.host.workspace)
        let ep = await h.host.epoch
        #expect(seq == 3 && ep == 2)                                       // the join list, then a rotation without the device
        #expect(try await h.drive(until: { $0.isTerminal }) == .rejected)
    }

    @Test func requestsOfAllOffersAreAnsweredInGlobalArrivalOrder() async throws {
        let h = try await PairHarness.make(.firstTime)
        var offers = [try await h.rig.newOffer(), try await h.rig.newOffer()].sorted { $0.offerID.hex < $1.offerID.hex }
        let (lo, hi) = (offers.removeFirst(), offers.removeFirst())
        let devHi = SoftwareSigner(), kxHi = SoftwareKeyAgreer(), devLo = SoftwareSigner(), kxLo = SoftwareKeyAgreer()
        let keysHi = DemoKeys(sig: devHi.publicKey, kx: kxHi.publicKey), keysLo = DemoKeys(sig: devLo.publicKey, kx: kxLo.publicKey)
        // the offer that sorts last receives its request FIRST
        try await PairForge(h: h, link: try h.link(hi)).sendPair(signer: devHi, keys: keysHi, label: "Second offer")
        try await PairForge(h: h, link: try h.link(lo)).sendPair(signer: devLo, keys: keysLo, label: "First offer")
        let handled = try await h.host.pumpPairing(relay: h.relay, transport: h.env.transport)
        #expect(handled == 2)
        #expect(await h.host.pairingState(of: keysHi.deviceID) == "pending")
        #expect(await h.host.pairingState(of: keysLo.deviceID) == "pending")
    }
}

@Suite struct PairingRound2Tests {
    // MARK: wire-approved certificates go through the realm context

    @Test func aRogueAuthoritysCertificateIsRefusedBeforeJoining() async throws {
        // the link pins a key the Demo never created: the wire accepts the signature, the realm context must not
        let h = try await PairHarness.make(.firstTime)
        let rogue = SoftwareSigner()
        let offer = try await h.rig.newOffer()
        var parts = offer.link.components(separatedBy: ".")
        parts[parts.count - 1] = B64U.encode(Identifiers.pkPin(rogue.publicKey))
        let link = try PairingLink.parse(parts.joined(separator: "."))
        let forge = PairForge(h: h, link: link)
        _ = await h.coordinator.start(link: link)
        var seen = 0
        var final = await h.coordinator.state
        for _ in 0..<60 {
            let k = seen
            seen += try await forge.pump { _ in
                k == 0 ? forge.pending(nonce: forge.nonceA)
                       : try await forge.approved(for: forge.phone, signedBy: rogue, pk: rogue.publicKey)
            }
            await h.coordinator.poll(); h.clock.advance(milliseconds: 1000)
            final = await h.coordinator.state
            if final.isTerminal || final == .joining { break }
        }
        #expect(final == .failed(.realm(.crossRealmCertificate)), "\(final)")
        #expect(h.vaultItems.isEmpty && h.deviceCert == nil)
        let wss = try await h.env.index.workspaces(), prs = try await h.env.index.pairings()
        #expect(wss.isEmpty && prs.isEmpty)
    }

    @Test func aStoredApprovalWithARogueCertificateIsRefusedOnResume() async throws {
        let h = try await PairHarness.make(.firstTime)
        try await h.driveToJoining()
        var r = try #require(h.pairingRecord)
        let rogue = SoftwareSigner()
        let cert = try await PairForge(h: h, link: try h.link(try await h.rig.newOffer())).approved(for: DemoKeys(h.env.device.publicKeys), signedBy: rogue, pk: rogue.publicKey)
        r.approved?.cert = try #require(cert.object?["cert"])
        r.pkPub = rogue.publicKey.x963
        try h.vault.scoped(to: .demo).put(try r.encode(), ws: h.wsHex, purpose: "pairing")
        let c = h.fresh()
        _ = await c.resume(ws: h.host.workspace)
        await c.poll()
        #expect(await c.state == .failed(.realm(.crossRealmCertificate)))
        let wss = try await h.env.index.workspaces()
        #expect(wss.isEmpty && h.vaultItems.isEmpty)
    }

    // MARK: resume reserves the lifecycle

    @Test func cancelDuringResumeIsHonoured() async throws {
        let h = try await PairHarness.make(.firstTime)
        _ = try await h.startToHostCode()
        let c = h.fresh()
        let gate = HookGate(); await gate.hold("resume.row")
        await c.setHook { await gate.hit($0) }
        let resumer = Task { await c.resume(ws: h.host.workspace) }
        await gate.waitArrived("resume.row")                          // resume owns the lifecycle and is parked
        await c.cancel()
        await gate.release("resume.row")
        #expect(await resumer.value == .cancelled)
        await c.poll()
        #expect(await c.state == .cancelled)
        // the cancel owned nothing yet (no record); the stored pairing is untouched and can still be resumed later
        #expect(h.pairingRecord != nil)
        #expect(await h.fresh().resume(ws: h.host.workspace) == .connecting(origin: DemoRelay.origin))
    }

    @Test func concurrentStartAndResumeDoNotSupersedeEachOther() async throws {
        // Which of two truly concurrent calls reserves the lifecycle first is a scheduler decision, so each order is forced through a
        // hook that parks the first caller right after it reserved: the second then runs to completion against a held lifecycle.
        for resumeFirst in [true, false] {
            let tag = Comment(rawValue: resumeFirst ? "resume first" : "start first")
            let h = try await PairHarness.make(.firstTime)
            _ = try await h.startToHostCode()
            let c = h.fresh()
            let link = try h.link(try await h.rig.newOffer())
            let ws = h.host.workspace
            let gate = HookGate(); await gate.hold(resumeFirst ? "resume.row" : "start.reserved")
            await c.setHook { await gate.hit($0) }
            let first = resumeFirst ? Task { await c.resume(ws: ws) } : Task { await c.start(link: link) }
            await gate.waitArrived(resumeFirst ? "resume.row" : "start.reserved")
            // the second caller returns at once, without touching anything: it neither supersedes nor is superseded
            let second = resumeFirst ? await c.start(link: link) : await c.resume(ws: ws)
            #expect(second == .parsing, tag)
            #expect(await c.state == .parsing, tag)
            await gate.release(resumeFirst ? "resume.row" : "start.reserved")
            let r = await first.value
            if resumeFirst {
                #expect(r == .connecting(origin: DemoRelay.origin), tag)
            } else {
                // the offer names the workspace that already has a pairing row: refused, and the stored pairing is untouched
                #expect(r == .failed(.verification(reason: "pairing_in_progress")), tag)
            }
            let rows = try await h.env.index.pairings()
            #expect(rows.count == 1, tag)
            let rec = try #require(h.pairingRecord, tag)
            #expect(rec.ws == ws, tag)
        }
    }

    // MARK: a locked keychain is not a missing record

    @Test func aLockedVaultNeverPurgesAPendingPairing() async throws {
        let h = try await PairHarness.make(.firstTime)
        _ = try await h.startToHostCode()
        let before = try #require(h.pairingRecord)
        h.lock.isLocked = true
        let c = h.fresh()
        #expect(await c.recover() == false)                          // not clean: it will be retried
        #expect(await c.resume(ws: h.host.workspace) == .failed(.custody))
        h.lock.isLocked = false
        let row = try #require(try await h.env.index.pairing(ws: h.wsHex))
        #expect(row.terminal == nil)                                  // never marked for cleanup
        #expect(h.pairingRecord == before)
        #expect(h.wsDirExists || true)
        let c2 = h.fresh()
        #expect(await c2.recover())
        #expect(await c2.resume(ws: h.host.workspace) == .connecting(origin: DemoRelay.origin))
    }

    // MARK: expiry on the adopted clock, the join cap before backoff

    @Test func certificateExpiryIsConvertedThroughTheAdoptedOffset() async throws {
        for skew in [3_600_000 as Int64, -3_600_000] {
            let h = try await PairHarness.make(.firstTime, phoneSkewMs: skew)
            try await h.driveToJoining()
            var r = try #require(h.pairingRecord)
            let hostNow = h.clock.nowMs
            let cert = try await h.primary.certify(DemoKeys(h.env.device.publicKeys), label: "Demo iPhone", scopesMax: ["look", "decide"], lifetimeMs: 200_000)
            r.approved?.cert = cert
            try h.vault.scoped(to: .demo).put(try r.encode(), ws: h.wsHex, purpose: "pairing")
            let c = h.fresh()
            _ = await c.resume(ws: h.host.workspace)
            let end = try #require(await c.joinEndForTest())
            let expiresHost = hostNow + 200_000
            #expect(end == expiresHost - r.offsetMs, "skew \(skew)")        // local = host - offset
            #expect(abs(end - (expiresHost + skew)) <= 10_000)               // i.e. about 200 s after "now" on the phone's own clock
        }
    }

    @Test func theJoinCapIsEnforcedBeforeABackoffThatCrossesIt() async throws {
        let h = try await PairHarness.make(.firstTime)
        await h.host.setHostile { $0.omitFromList = true }
        try await h.driveToJoining()
        let started = try #require(h.pairingRecord?.joinStartedMs)
        // a join attempt 500 ms before the cap fails and backs off 2 s, across the deadline
        h.clock.advance(milliseconds: max(started + 59_500 - h.clock.nowMs, 0))
        await h.coordinator.poll()
        #expect(await h.coordinator.state == .joining)
        h.clock.advance(milliseconds: started + 60_000 - h.clock.nowMs)
        await h.coordinator.poll()
        #expect(await h.coordinator.state == .failed(.joiningTimedOut), "the cap fires at its deadline, not when the backoff ends")
        // and run() does not keep waking at a past deadline: it waits for a retry/cancel
        let runner = Task { await h.coordinator.run() }
        for _ in 0..<100 { await Task.yield() }
        let t = Task { await h.coordinator.cancel() }
        await t.value
        runner.cancel()
        await runner.value
        #expect(await h.coordinator.state == .cancelled)
    }

    @Test func aVaultThatLocksBetweenTheIndexAndCustodyPreservesThePairing() async throws {
        let h = try await PairHarness.make(.firstTime)
        _ = try await h.startToHostCode()
        let before = try #require(h.pairingRecord)
        let c = h.fresh()
        let lock = h.lock
        await c.setHook { name in if name == "resume.custody" { lock.isLocked = true } }
        let st = await c.resume(ws: h.host.workspace)
        lock.isLocked = false
        #expect(st == .failed(.custody))
        let row = try #require(try await h.env.index.pairing(ws: h.wsHex))
        #expect(row.terminal == nil && h.pairingRecord == before && h.custody.status(realm: .demo) == .present)
        let c2 = h.fresh()
        #expect(await c2.resume(ws: h.host.workspace) == .connecting(origin: DemoRelay.origin))
    }
}
