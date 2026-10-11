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

/// Collects every state the coordinator publishes (the observation stream, not a sample).
actor StateLog {
    private(set) var states: [PairingState] = []
    private var task: Task<Void, Never>?
    func attach(_ c: PairingCoordinator) async {
        let stream = await c.states()
        task = Task { for await s in stream { self.add(s) } }
    }
    private func add(_ s: PairingState) { states.append(s) }
    func stop() { task?.cancel() }
    /// Waits for a published snapshot, not `state`: expiry may change that getter without publishing.
    func settled(_ c: PairingCoordinator) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            if states.last == (await c.lastPublishedState) { return }
            await Task.yield()
        }
        Issue.record("StateLog did not consume the last published state within 60 s: log=\(states.last.map { "\($0)" } ?? "empty")")
    }
    var showedHostCode: Bool { states.contains { isComparingHost($0) } }
    var showedPrimaryCode: Bool { states.contains { isComparingPrimary($0) } }
}

extension PairHarness {
    func hostApproves(scopes: [String]? = nil) async throws {
        try await host.approvePairing(device: phoneID, scopes: scopes, confirmedComparison: true, relay: relay, transport: env.transport)
    }

    func primaryApproves(scopesMax: [String]? = nil) async throws {
        let p = try #require(await primary.openPrompts().first)
        try await primary.approve(request: p.requestID, scopesMax: scopesMax, confirmedComparison: true, relay: relay)
    }

    /// Starts and drives to the host comparison; returns the code.
    func startToHostCode(scopes: [String] = ["look", "decide"]) async throws -> (offer: PairingOffer, code: String) {
        let offer = try await rig.newOffer(scopes: scopes)
        _ = await coordinator.start(link: try link(offer))
        guard case .comparingHost(let code) = try await drive(until: isComparingHost) else { throw PairError.notReached("comparingHost") }
        return (offer, code)
    }

    enum PairError: Error { case notReached(String) }

    /// The whole first-time flow with explicit human inputs. Returns the final state.
    @discardableResult
    func completeFirstTime() async throws -> PairingState {
        _ = try await startToHostCode()
        try await hostApproves()
        guard case .comparingPrimary = try await drive(until: isComparingPrimary) else { throw PairError.notReached("comparingPrimary") }
        try await primaryApproves()
        return try await drive(until: { $0.isTerminal || $0 == .failed(.joiningTimedOut) })
    }

    var vaultItems: [SecretID] { ((try? vault.ids()) ?? []).filter { $0.realm == .demo && $0.ws == host.workspace.hex } }
}

@Suite struct PairingFlowTests {
    // MARK: scenarios

    @Test func testPairingScenarioMatrix() async throws {
        #expect(Set(PairingScenario.allCases.map(\.rawValue)) == ["firstTime", "existingCert", "hostIsPrimary", "primaryOffline", "linkUsed", "r1Attack",
                                                                  "echoWrongKey", "otherPerson", "rejectOnHost", "rejectOnPrimary", "revokeAfter"])
        for scenario in PairingScenario.allCases {
            let h = try await PairHarness.make(scenario)
            let plan = scenario.plan
            let name = scenario.rawValue
            let log = StateLog(); await log.attach(h.coordinator)
            let offer = try await h.rig.newOffer()
            let link = try h.link(offer)
            let before = await h.relay.requestsReceived
            switch scenario {
            case .existingCert: try await h.rig.enrollExistingCertificate(into: h.config)
            case .otherPerson: try await h.rig.enrollForeignCertificate(into: h.config)
            case .linkUsed:
                // someone else consumes the offer first
                let intruder = SoftwareSigner(), intruderKx = SoftwareKeyAgreer()
                try await PairForge(h: h, link: link).sendPair(signer: intruder, keys: DemoKeys(sig: intruder.publicKey, kx: intruderKx.publicKey), label: "Intruder")
                try await h.rig.pump()
            default: break
            }
            _ = await h.coordinator.start(link: link)
            var final: PairingState
            if scenario == .otherPerson {
                final = await h.coordinator.state
                // refused locally, nothing sent
                #expect(await h.relay.requestsReceived == before, "\(name)")
                #expect(await h.host.pendingPairings().isEmpty, "\(name)")
            } else if plan.showsHostCode {
                guard case .comparingHost(let code) = try await h.drive(until: isComparingHost) else { Issue.record("\(name): no host code"); continue }
                #expect(await h.host.pendingPairings().first?.sas == code, "\(name)")
                // the host's human acts (explicit input; the default is reject)
                if plan.hostApproves { try await h.hostApproves() } else { try await h.host.rejectPairing(device: h.phoneID) }
                switch scenario {
                case .firstTime, .revokeAfter, .rejectOnPrimary:
                    guard case .comparingPrimary(let cc, let label, _) = try await h.drive(until: isComparingPrimary) else { Issue.record("\(name): no cert code"); continue }
                    #expect(label == "Demo Mac" && cc != code, "\(name)")
                    #expect(await h.primary.openPrompts().first?.certCode == cc, "\(name)")
                    if plan.primaryAction == true { try await h.primaryApproves() }
                    else {
                        let p = try #require(await h.primary.openPrompts().first)
                        try await h.primary.reject(request: p.requestID, relay: h.relay)
                    }
                    final = try await h.drive(until: { $0.isTerminal })
                case .primaryOffline:
                    guard case .waitingPrimary = try await h.drive(until: isWaitingPrimary) else { Issue.record("\(name): not waiting"); continue }
                    final = try await h.drive(steps: 800, until: { $0.isTerminal })
                default:
                    final = try await h.drive(until: { $0.isTerminal })
                }
            } else {
                // echoWrongKey / linkUsed: the failure comes before any host code
                final = try await h.drive(until: { $0.isTerminal })
            }
            await log.settled(h.coordinator); await log.stop()
            switch plan.outcome {
            case .ready: #expect(isReady(final), "\(name): \(final)")
            case .rejected: #expect(final == .rejected, "\(name): \(final)")
            case .expired(let e): #expect(final == .expired(e), "\(name): \(final)")
            case .alarm(let k): #expect({ if case .alarm(let a) = final { return a.kind == k }; return false }(), "\(name): \(final)")
            case .failed(let f): #expect(final == .failed(f), "\(name): \(final)")
            }
            #expect(await log.showedHostCode == plan.showsHostCode, "\(name)")
            // the primary's code is shown only in the flows that ask the primary and where its challenge names the phone's keys
            #expect(await log.showedPrimaryCode == (scenario == .firstTime || scenario == .revokeAfter || scenario == .rejectOnPrimary), "\(name)")
            // scenario-specific state of the world
            let ws = h.host.workspace
            switch scenario {
            case .existingCert, .hostIsPrimary:
                let noPrompts = await h.primary.openPrompts().isEmpty, queue = await h.relay.certRequestQueueSize()
                #expect(noPrompts && queue == 0, "\(name): no primary prompt")
                #expect(await h.relay.hasGrant(workspace: ws, device: h.phoneID, epoch: 1), "\(name)")
            case .rejectOnHost, .primaryOffline, .r1Attack, .echoWrongKey, .linkUsed, .otherPerson, .rejectOnPrimary:
                #expect(await h.noKeyMaterial(for: h.phoneID), "\(name)")
                #expect(await !h.relay.hasCertificate(h.phoneID), "\(name): no certificate")
                if scenario == .rejectOnPrimary { #expect(await h.primary.ledgerSnapshot().signed.isEmpty, "\(name): never signed") }
            case .firstTime, .revokeAfter:
                let g = await h.relay.hasGrant(workspace: ws, device: h.phoneID, epoch: 1), w = await h.relay.hasCardKeyWrap(workspace: ws, device: h.phoneID, cardSeq: 1)
                #expect(g && w, "\(name)")
            }
            if scenario == .revokeAfter, case .ready(let handle) = final {
                let record = try await h.rig.revokeAfterJoin(device: h.phoneID)
                // the revoked device gets no session; its record is public and PK-signed
                let login = try? await RelayClient(transport: h.env.transport).openDeviceSession(identity: h.env.device, deviceID: h.phoneID)
                #expect(login == nil)
                let fetched = try await RelayClient(transport: h.env.transport).revocation(device: h.phoneID)
                #expect(fetched == record)
                let cert = try DeviceCertificate.verify(try #require(await h.relay.certificate(device: h.phoneID)), personKey: h.primary.publicKey, nowMs: h.clock.nowMs)
                _ = try Revocation.verify(fetched, personKey: h.primary.publicKey, cert: cert.identity)
                let gc = await h.relay.grantCount(workspace: ws, device: h.phoneID), wr = await h.relay.hasCardKeyWrap(workspace: ws, device: h.phoneID, cardSeq: 1)
                #expect(gc == 0 && !wr)
                #expect(await h.host.epoch == 2)
                // the wipe removes every dependent item of the joined workspace
                let wipe = LocalWipe(index: h.env.index)
                try await wipe.wipe(ws: handle.joined.workspace.hex, generation: handle.joined.generation)
                try? h.vault.scoped(to: .demo).wipe(ws: handle.joined.workspace.hex)
                #expect(try await h.env.index.workspaces().isEmpty && h.vaultItems.isEmpty)
            }
        }
    }

    // MARK: invariant

    @Test func testNoGrantOrCardWrapBeforeValidCertificate() async throws {
        // pending / cert_pending (before the primary signs)
        do {
            let h = try await PairHarness.make(.firstTime)
            _ = try await h.startToHostCode()
            #expect(await h.noKeyMaterial(for: h.phoneID))                     // pending
            try await h.hostApproves()
            guard case .comparingPrimary = try await h.drive(until: isComparingPrimary) else { Issue.record("no challenge"); return }
            #expect(await h.noKeyMaterial(for: h.phoneID))                     // cert_pending, with the primary's challenge showing
            #expect(await h.host.pairingState(of: h.phoneID) == "cert_pending")
            // the relay itself refuses key material for a device without a certificate (defence in depth)
            let session = try await h.host.openSession(transport: h.env.transport)
            let keys = DemoKeys(h.env.device.publicKeys)
            await #expect(throws: ClientError.self) { try await h.relay.putGrant(try await h.host.grant(for: keys, epoch: 1), token: session.token) }
            await #expect(throws: ClientError.self) { try await h.relay.putCardKeyWrap(device: h.phoneID, cardSeq: 1, sealed: try await h.host.cardKeyWrap(for: keys), token: session.token) }
            #expect(await h.noKeyMaterial(for: h.phoneID))
            // and the host will not finish a join without one
            await #expect(throws: PairingApprovalError.self) { try await h.host.completeJoin(device: h.phoneID, relay: h.relay, transport: h.env.transport) }
            #expect(await h.noKeyMaterial(for: h.phoneID))
            // a valid certification publishes both, in section 8.3 step 6 (and the list names the device only after its grant)
            try await h.primaryApproves()
            guard case .ready = try await h.drive(until: { $0.isTerminal }) else { Issue.record("not ready"); return }
            #expect(await h.relay.hasGrant(workspace: h.host.workspace, device: h.phoneID, epoch: 1))
            #expect(await h.relay.hasCardKeyWrap(workspace: h.host.workspace, device: h.phoneID, cardSeq: 1))
            #expect(await h.relay.memberListSeq(workspace: h.host.workspace) == 2)
        }
        // rejectOnHost
        do {
            let h = try await PairHarness.make(.rejectOnHost)
            _ = try await h.startToHostCode()
            try await h.host.rejectPairing(device: h.phoneID)
            #expect(try await h.drive(until: { $0 == .rejected }) == .rejected)
            #expect(await h.nothingFor(h.phoneID))
        }
        // rejectOnPrimary
        do {
            let h = try await PairHarness.make(.rejectOnPrimary)
            _ = try await h.startToHostCode()
            try await h.hostApproves()
            _ = try await h.drive(until: isComparingPrimary)
            let p = try #require(await h.primary.openPrompts().first)
            try await h.primary.reject(request: p.requestID, relay: h.relay)
            #expect(try await h.drive(until: { $0 == .rejected }) == .rejected)
            #expect(await h.nothingFor(h.phoneID))
            #expect(await h.primary.ledgerSnapshot().signed.isEmpty)
            await #expect(throws: PrimaryError.self) { _ = try await h.primary.approve(request: p.requestID, confirmedComparison: true, relay: h.relay) }
        }
        // primaryOffline, through the host's 10-minute expiry
        do {
            let h = try await PairHarness.make(.primaryOffline)
            _ = try await h.startToHostCode()
            try await h.hostApproves()
            #expect(try await h.drive(steps: 800, until: { $0.isTerminal }) == .expired(.certification))
            #expect(await h.nothingFor(h.phoneID))
            #expect(await h.host.pairingState(of: h.phoneID) == "expired")
        }
        // r1Attack
        do {
            let h = try await PairHarness.make(.r1Attack)
            _ = try await h.startToHostCode()
            try await h.hostApproves()
            #expect(isAlarm(try await h.drive(until: isAlarm)))
            #expect(await h.nothingFor(h.phoneID))
            // even a human who matches nothing and confirms on the primary certifies only the attacker's key, never the phone's
            if let p = await h.primary.openPrompts().first {
                #expect(p.deviceID != h.phoneID)
            }
        }
    }

    // MARK: alarms

    @Test func testR1AlarmHidesBothCodes() async throws {
        let h = try await PairHarness.make(.r1Attack)
        let log = StateLog(); await log.attach(h.coordinator)
        let (_, hostCode) = try await h.startToHostCode()
        try await h.hostApproves()
        guard case .alarm(let alarm) = try await h.drive(until: isAlarm) else { Issue.record("no alarm"); return }
        await log.settled(h.coordinator)
        #expect(alarm.kind == .r1Challenge)
        // the attacker's challenge names another key: the primary has a code, the phone shows none and never did
        let prompt = try #require(await h.primary.openPrompts().first)
        #expect(prompt.deviceID != h.phoneID)
        #expect(await !log.showedPrimaryCode)
        let after = await log.states.drop { !isAlarm($0) }
        #expect(after.count >= 1 && after.allSatisfy(isAlarm))          // nothing but the alarm after the alarm
        // the instruction names the primary and carries no code
        #expect(alarm.instruction == "Reject on Demo Mac; do not confirm any code there; this host may be compromised")
        #expect(!alarm.instruction.contains(hostCode) && !alarm.instruction.contains(prompt.certCode))
        // the alarm is terminal: further polls change nothing and send nothing
        let sent = await h.relay.accepted
        for _ in 0..<30 { try await h.rig.pump(); await h.coordinator.poll(); h.clock.advance(milliseconds: 1000) }
        let now = await h.coordinator.state, acc = await h.relay.accepted
        #expect(now == .alarm(alarm) && acc == sent)
        await log.stop()
    }

    @Test func testEchoWrongKeyAlarmBeforeSAS() async throws {
        for wrong in [FakeHost.EchoedKey.signing, .exchange] {
            let h = try await PairHarness.make(.echoWrongKey)
            await h.host.setEchoWrongKey(wrong)
            let log = StateLog(); await log.attach(h.coordinator)
            let offer = try await h.rig.newOffer()
            _ = await h.coordinator.start(link: try h.link(offer))
            guard case .alarm(let a) = try await h.drive(until: isAlarm) else { Issue.record("no alarm"); return }
            await log.settled(h.coordinator)
            #expect(a.kind == .echoWrongKey && a.instruction == "Reject on your Mac (host)")
            let hc = await log.showedHostCode, pc = await log.showedPrimaryCode
            #expect(!hc && !pc)         // before any SAS
            await log.stop()
        }
    }

    @Test func testAlarmInstructionsPersistAcrossRestart() async throws {
        for scenario in [PairingScenario.r1Attack, .echoWrongKey] {
            let h = try await PairHarness.make(scenario)
            let offer = try await h.rig.newOffer()
            _ = await h.coordinator.start(link: try h.link(offer))
            if scenario == .r1Attack { _ = try await h.drive(until: isComparingHost); try await h.hostApproves() }
            guard case .alarm(let alarm) = try await h.drive(until: isAlarm) else { Issue.record("\(scenario): no alarm"); return }
            // no secret survives: only the alarm row remains
            #expect(h.vaultItems.isEmpty)
            let rows = try await PairingCoordinator.pending(in: h.env.index)
            #expect(rows.count == 1 && rows[0].terminal == "alarm:" + alarm.kind.rawValue)
            // restart: a fresh coordinator shows the same alarm with the same instruction, no code, and sends nothing
            let sent = await h.relay.requestsReceived
            let restarted = PairingCoordinator(h.config)
            let state = await restarted.resume(ws: h.host.workspace)
            #expect(state == .alarm(alarm) && (state == .alarm(alarm)))
            if case .alarm(let again) = state { #expect(again.instruction == alarm.instruction) }
            for _ in 0..<5 { await restarted.poll(); h.clock.advance(milliseconds: 6000) }
            #expect(await h.relay.requestsReceived == sent)
            // the person reads it and dismisses it: the row goes away
            await restarted.dismiss()
            #expect(try await PairingCoordinator.pending(in: h.env.index).isEmpty)
        }
        // a host-chosen label never lands inside an instruction unless it is short and plain
        #expect(PairingAlarm(kind: .r1Challenge, primaryLabel: "MacBook Pro").instruction.hasPrefix("Reject on MacBook Pro;"))
        for hostile in ["\u{202E}evil", String(repeating: "x", count: 41), "Mac\nReject here", "", "<b>Mac</b>", "Mac; confirm now"] {
            #expect(PairingAlarm(kind: .r1Challenge, primaryLabel: hostile).primaryLabel == "your primary device", "\(hostile.debugDescription)")
        }
        #expect(PairingAlarm(kind: .r1Challenge, primaryLabel: nil).instruction == "Reject on your primary device; do not confirm any code there; this host may be compromised")
    }

    // MARK: pins and chains

    @Test func testPairingPinsAndMonotonicChains() async throws {
        let h0 = try await PairHarness.make(.firstTime)
        _ = h0
        // each script answers the phone's pair / pair_status requests in order; `nil` is silence
        struct Case { let name: String; let kind: PairingAlarmKind?; let script: @Sendable (PairForge, Int, String) async throws -> JSONValue? }
        let cases: [Case] = [
            Case(name: "sas_nonce substitution", kind: .pinSubstitution) { f, n, op in n == 0 ? f.pending(nonce: f.nonceA) : f.pending(nonce: f.nonceB) },
            Case(name: "pending after cert_pending", kind: .regression) { f, n, op in
                switch n { case 0: f.pending(nonce: f.nonceA); case 1: f.certPending(challenge: nil); default: f.pending(nonce: f.nonceA) } },
            Case(name: "pending after approved-less challenge", kind: .regression) { f, n, op in
                switch n { case 0: f.pending(nonce: f.nonceA); case 1: try await f.certPending(challenge: f.challenge(nonce: f.nonceA)); default: f.pending(nonce: f.nonceA) } },
            Case(name: "challenge substitution", kind: .pinSubstitution) { f, n, op in
                switch n { case 0: f.pending(nonce: f.nonceA); case 1: try await f.certPending(challenge: f.challenge(nonce: f.nonceA)); default: try await f.certPending(challenge: f.challenge(nonce: f.nonceB)) } },
            Case(name: "challenge request id substitution", kind: .pinSubstitution) { f, n, op in
                switch n { case 0: f.pending(nonce: f.nonceA); case 1: try await f.certPending(challenge: f.challenge(nonce: f.nonceA)); default: try await f.certPending(challenge: f.challenge(nonce: f.nonceA, request: .random())) } },
            Case(name: "challenge expiry changed", kind: .pinSubstitution) { f, n, op in
                switch n { case 0: f.pending(nonce: f.nonceA); case 1: try await f.certPending(challenge: f.challenge(nonce: f.nonceA)); default: try await f.certPending(challenge: f.challenge(nonce: f.nonceA, expiresDelta: 1000)) } },
            Case(name: "challenge withdrawn", kind: .regression) { f, n, op in
                switch n { case 0: f.pending(nonce: f.nonceA); case 1: try await f.certPending(challenge: f.challenge(nonce: f.nonceA)); default: f.certPending(challenge: nil) } },
            Case(name: "certificate before any host code", kind: .regression) { f, n, op in try await f.approved(for: f.phone) },
        ]
        for c in cases {
            let h = try await PairHarness.make(.firstTime)
            let offer = try await h.rig.newOffer()
            let forge = PairForge(h: h, link: try h.link(offer))
            _ = await h.coordinator.start(link: forge.link)
            var seen = 0
            var final = await h.coordinator.state
            for _ in 0..<120 {
                let n = seen
                let answered = try await forge.pump { op in try await c.script(forge, n, op) }
                seen += answered
                await h.coordinator.poll()
                h.clock.advance(milliseconds: 1000)
                final = await h.coordinator.state
                if final.isTerminal { break }
            }
            guard case .alarm(let a) = final else { Issue.record("\(c.name): \(final)"); continue }
            #expect(a.kind == c.kind, "\(c.name): \(a.kind)")
            let clean = await h.noKeyMaterial(for: h.phoneID)
            #expect(h.vaultItems.isEmpty && clean, "\(c.name)")
        }

        // an identical repeat is allowed, and the code never changes under the person
        do {
            let h = try await PairHarness.make(.firstTime)
            let offer = try await h.rig.newOffer()
            let forge = PairForge(h: h, link: try h.link(offer))
            _ = await h.coordinator.start(link: forge.link)
            let ch = try await forge.challenge(nonce: forge.nonceA)
            var codes: [String] = []
            var n = 0
            for _ in 0..<80 {
                let k = n
                n += try await forge.pump { _ in k == 0 ? forge.pending(nonce: forge.nonceA) : forge.certPending(challenge: ch) }
                await h.coordinator.poll(); h.clock.advance(milliseconds: 1000)
                if case .comparingPrimary(let code, _, _) = await h.coordinator.state, codes.last != code { codes.append(code) }
                if codes.count == 1 && n >= 5 { break }
            }
            #expect(codes.count == 1 && n >= 5)
            #expect(codes.first == (try Identifiers.certCode(challengeObject: .object(try #require(ch.object?["o"]?.object)))))
            // the code is hidden the instant the challenge expires, whatever was last polled
            h.clock.advance(milliseconds: 600_000)
            guard case .waitingPrimary(_, _, let expired) = await h.coordinator.state else { Issue.record("code still shown"); return }
            #expect(expired)
        }
    }

    @Test func testApprovedCertMatchesPinnedChallenge() async throws {
        // 1. the honest flow: the certificate is for exactly the keys the primary's challenge named
        do {
            let h = try await PairHarness.make(.firstTime)
            _ = try await h.startToHostCode()
            try await h.hostApproves()
            _ = try await h.drive(until: isComparingPrimary)
            let prompt = try #require(await h.primary.openPrompts().first)
            let cert = try await h.primary.approve(request: prompt.requestID, confirmedComparison: true, relay: h.relay)
            let dc = try DeviceCertificate.verify(cert, personKey: h.primary.publicKey, nowMs: h.clock.nowMs)
            #expect(dc.signingKey == h.env.device.publicKeys.sig && dc.agreementKey == h.env.device.publicKeys.kx)
            guard case .ready = try await h.drive(until: { $0.isTerminal }) else { Issue.record("not ready"); return }
        }
        // 2. a certificate that is not for these keys, not for this device, or from a PK that is not the pin never moves the phone on
        let h = try await PairHarness.make(.firstTime)
        let offer = try await h.rig.newOffer()
        let forge = PairForge(h: h, link: try h.link(offer))
        _ = await h.coordinator.start(link: forge.link)
        let ch = try await forge.challenge(nonce: forge.nonceA)
        let strangerKeys = DemoKeys(sig: SoftwareSigner().publicKey, kx: SoftwareKeyAgreer().publicKey)
        let otherPK = SoftwareSigner()
        let wrongKeys = try await forge.approved(for: strangerKeys)
        let foreignPK = try await forge.approved(for: forge.phone, signedBy: otherPK, pk: otherPK.publicKey)
        let otherKx = try await forge.approved(for: DemoKeys(sig: forge.phone.sig, kx: SoftwareKeyAgreer().publicKey))
        var n = 0
        for _ in 0..<60 {
            let k = n
            n += try await forge.pump { _ in
                switch k { case 0: forge.pending(nonce: forge.nonceA); case 1: forge.certPending(challenge: ch); case 2: wrongKeys; case 3: foreignPK; default: otherKx } }
            await h.coordinator.poll(); h.clock.advance(milliseconds: 1000)
            if n >= 6 { break }
        }
        guard case .comparingPrimary = await h.coordinator.state else { Issue.record("moved on: \(await h.coordinator.state)"); return }
        #expect(h.vaultItems.count == 1)                                  // only the pending record
        let clean = await h.noKeyMaterial(for: h.phoneID), ws = try await h.env.index.workspaces()
        #expect(ws.isEmpty && clean)
    }

    // MARK: rate limits and cadence

    @Test func testCertPendingTenMinutesWithinRateLimits() async throws {
        let h = try await PairHarness.make(.primaryOffline)          // the longest honest run: cert_pending until the host's 10 minutes end
        _ = try await h.startToHostCode()
        try await h.hostApproves()
        let startMs = h.clock.nowMs
        var perMinutePosts: [Int64: Int] = [:]
        var lastAccepted = await h.relay.accepted
        var final = await h.coordinator.state
        for _ in 0..<760 {
            try await h.rig.pump()
            await h.coordinator.poll()
            let a = await h.relay.accepted
            // host responses are posts too; count only growth in the phone's posts by minute
            perMinutePosts[(h.clock.nowMs - startMs) / 60_000, default: 0] += a - lastAccepted
            lastAccepted = a
            h.clock.advance(milliseconds: 1000)
            final = await h.coordinator.state
            if final.isTerminal { break }
        }
        #expect(final == .expired(.certification))
        #expect(await h.relay.rateLimited == 0)
        // at least 3x headroom against 60 posts / minute (phone posts plus host answers) at every minute
        #expect(perMinutePosts.values.max() ?? 0 <= 20, "\(perMinutePosts)")
        #expect(h.clock.nowMs - startMs >= CertRequest.lifetimeMs)
        #expect(await h.noKeyMaterial(for: h.phoneID))
    }

    @Test func testPairingHonorsRetryAfter() async throws {
        // a 429 with Retry-After: 30 (longer than the 20 s backoff): nothing reaches the relay for 30 s, however often the screen asks
        var limits = RelayLimits(); limits.pairPollsPerMinutePerAddress = 1; limits.retryAfterSeconds = 30
        let h = try await PairHarness.make(.firstTime, limits: limits)
        let offer = try await h.rig.newOffer()
        _ = await h.coordinator.start(link: try h.link(offer))
        await h.coordinator.poll()                       // POST and the one GET the address is allowed this minute
        var limitedAt: Int64?
        for _ in 0..<20 {
            h.clock.advance(milliseconds: 1000)
            await h.coordinator.poll()
            if await h.relay.rateLimited > 0 { limitedAt = h.clock.nowMs; break }
        }
        let t0 = try #require(limitedAt)
        let received = await h.relay.requestsReceived
        for _ in 0..<29 {
            h.clock.advance(milliseconds: 1000)
            await h.coordinator.poll()
        }
        var now = await h.relay.requestsReceived
        #expect(h.clock.nowMs - t0 == 29_000 && now == received)
        h.clock.advance(milliseconds: 1000)
        await h.coordinator.poll()
        now = await h.relay.requestsReceived
        #expect(now > received)                          // Retry-After over: it tries again
        // a Retry-After longer than any local backoff is a minimum too (90 s on a status poll after the first answer)
        var l3 = RelayLimits(); l3.pairPollsPerMinutePerAddress = 120; l3.pairPostsPerMinutePerWorkspace = 1; l3.retryAfterSeconds = 90
        let k = try await PairHarness.make(.firstTime, limits: l3)
        _ = try await k.startToHostCode()                // the one allowed POST (the pair request) has been used
        var lim: Int64?
        for _ in 0..<60 { await k.coordinator.poll(); if await k.relay.rateLimited > 0 { lim = k.clock.nowMs; break }; try await k.rig.pump(); k.clock.advance(milliseconds: 1000) }
        let t1 = try #require(lim)
        let r1 = await k.relay.requestsReceived
        for _ in 0..<89 { k.clock.advance(milliseconds: 1000); await k.coordinator.poll() }
        let r2 = await k.relay.requestsReceived
        #expect(k.clock.nowMs - t1 == 89_000 && r2 == r1)

        // a transport failure backs off 20 s, then 40, then 60 (never faster)
        let faults = ScriptedFaults()
        let g = try await PairHarness.make(.firstTime, faults: faults)
        _ = try await g.startToHostCode()                // past the first answer: only the 10-minute cap runs now
        faults.enqueue(.drop, at: .beforeQueue, times: 3)
        var attempts: [Int64] = []
        var seen = await g.relay.requestsReceived
        for _ in 0..<300 {
            await g.coordinator.poll()
            let n = await g.relay.requestsReceived
            if n > seen { attempts.append(g.clock.nowMs); seen = n }
            if attempts.count >= 4 { break }
            g.clock.advance(milliseconds: 1000)
        }
        let gaps = zip(attempts.dropFirst(), attempts).map { ($0 - $1) / 1000 }
        #expect(gaps.count == 3 && gaps[0] >= 20 && gaps[1] >= 40 && gaps[2] >= 60, "\(gaps)")
        #expect(gaps.count == 3 && gaps[0] < 25 && gaps[1] < 45 && gaps[2] < 65, "\(gaps)")
    }

    // MARK: cancel and expiry

    @Test func testCancelErasesPendingSecrets() async throws {
        // a custody with no keys: the pairing creates them, and cancel removes them because nothing else uses them
        let h = try await PairHarness.make(.firstTime)
        let fresh = DefaultCustody.make(vault: SecretVault(group: .keys, backend: InMemoryVaultBackend()))
        var cfg = h.config; cfg.custody = fresh
        let c = PairingCoordinator(cfg)
        let offer = try await h.rig.newOffer()
        _ = await c.start(link: try h.link(offer))
        #expect(fresh.status(realm: .demo) == .present)
        let row = try await h.env.index.pairing(ws: h.host.workspace.hex)
        #expect(h.vaultItems.count == 1 && row != nil)
        // pending state is persisted: ws/offer, S, pins, request
        let saved = try #require(PairingRecord.decode(try h.vault.scoped(to: .demo).get(ws: h.host.workspace.hex, purpose: "pairing")))
        #expect(saved.ws == h.host.workspace && saved.offer == offer.offerID && saved.secret?.count == 32 && saved.origin == DemoRelay.origin)
        #expect(saved.inflight == nil)
        await c.poll()
        #expect(PairingRecord.decode(try h.vault.scoped(to: .demo).get(ws: h.host.workspace.hex, purpose: "pairing"))?.inflight != nil)
        await c.cancel()
        #expect(await c.state == .cancelled)
        let row2 = try await h.env.index.pairing(ws: h.host.workspace.hex), wss = try await h.env.index.workspaces()
        #expect(h.vaultItems.isEmpty && row2 == nil && wss.isEmpty)
        #expect(fresh.status(realm: .demo) == .missing)                     // keys this pairing made, and nothing else uses
        // a late response cannot recreate the cancelled pairing
        try await h.rig.pump()
        await c.poll()
        let st = await c.state, rows = try await h.env.index.pairings()
        #expect(st == .cancelled && h.vaultItems.isEmpty && rows.isEmpty)

        // existing identity and certificate are kept (D-1); only the pairing is erased. Cancel in cert_pending
        let g = try await PairHarness.make(.firstTime)
        _ = try await g.startToHostCode()
        try await g.hostApproves()
        _ = try await g.drive(until: isComparingPrimary)
        let before = g.env.device.publicKeys
        await g.coordinator.cancel()
        #expect(await g.coordinator.state == .cancelled && g.vaultItems.isEmpty && g.custody.status(realm: .demo) == .present)
        #expect(g.env.device.publicKeys == before)
        // cancel cannot un-use the offer or retract: the host keeps its record; the primary can still be asked to reject
        #expect(await g.host.pairingState(of: g.phoneID) == "cert_pending")
        // no code survives anywhere in the coordinator
        let after = await g.coordinator.state
        #expect(after == .cancelled)
    }

    @Test func testPairingResumeAtExpiry() async throws {
        // before the 10-minute cap: the stored request is polled again and the comparison UI is cleared first
        do {
            let h = try await PairHarness.make(.firstTime)
            let (_, code) = try await h.startToHostCode()
            let restarted = PairingCoordinator(h.config)
            h.clock.advance(milliseconds: 120_000)
            let s = await restarted.resume(ws: h.host.workspace)
            #expect(s == .connecting(origin: DemoRelay.origin))                    // no code until it is verified again
            for _ in 0..<30 {
                try await h.rig.pump(); await restarted.poll(); h.clock.advance(milliseconds: 1000)
                if isComparingHost(await restarted.state) { break }
            }
            #expect(await restarted.state == .comparingHost(code: code))           // recomputed from verified inputs, identical
        }
        // after the cap: expired, and the secrets are gone
        do {
            let h = try await PairHarness.make(.firstTime)
            _ = try await h.startToHostCode()
            let restarted = PairingCoordinator(h.config)
            h.clock.advance(milliseconds: 600_000)
            #expect(await restarted.resume(ws: h.host.workspace) == .expired(.beforeApproval))
            let rows = try await h.env.index.pairings()
            #expect(h.vaultItems.isEmpty && rows.isEmpty)
        }
        // in cert_pending: the challenge's own expiry is the deadline, never extended by a restart
        do {
            let h = try await PairHarness.make(.firstTime)
            _ = try await h.startToHostCode()
            try await h.hostApproves()
            guard case .comparingPrimary(let code, _, let exp) = try await h.drive(until: isComparingPrimary) else { Issue.record("no code"); return }
            h.clock.advance(milliseconds: 200_000)
            let restarted = PairingCoordinator(h.config)
            #expect(await restarted.resume(ws: h.host.workspace) == .connecting(origin: DemoRelay.origin))
            for _ in 0..<60 {
                try await h.rig.pump(); await restarted.poll(); h.clock.advance(milliseconds: 1000)
                if isComparingPrimary(await restarted.state) { break }
            }
            guard case .comparingPrimary(let again, _, let exp2) = await restarted.state else { Issue.record("no code after restart"); return }
            #expect(again == code && exp2 == exp)
            // past the challenge expiry plus the grace, a restart ends the pairing
            h.clock.advance(milliseconds: 700_000)
            let late = PairingCoordinator(h.config)
            #expect(await late.resume(ws: h.host.workspace) == .expired(.certification))
            #expect(h.vaultItems.isEmpty)
        }
    }

    // MARK: restart mid-join

    @Test func testRestartAfterApprovalContinuesTheJoin() async throws {
        let h = try await PairHarness.make(.firstTime)
        _ = try await h.startToHostCode()
        try await h.hostApproves()
        _ = try await h.drive(until: isComparingPrimary)
        try await h.primaryApproves()
        // the host approves; the phone sees `approved` and is "joining" -- a restart finds the approval stored
        _ = try await h.drive(until: { $0 == .joining || isReady($0) })
        let restarted = PairingCoordinator(h.config)
        if isReady(await h.coordinator.state) { return }               // finished before the restart: nothing to resume
        #expect(await restarted.resume(ws: h.host.workspace) == .joining)
        for _ in 0..<20 { await restarted.poll(); h.clock.advance(milliseconds: 1000); if isReady(await restarted.state) { break } }
        #expect(isReady(await restarted.state))
    }
}

@Suite struct PairingLoopTests {
    @Test func stateLogSettlesAfterAnUnpublishedExpiry() async throws {
        let h = try await PairHarness.make(.firstTime)
        let log = StateLog(); await log.attach(h.coordinator)
        _ = try await h.startToHostCode()
        try await h.hostApproves()
        _ = try await h.drive(until: isComparingPrimary)
        #expect(isComparingPrimary(await h.coordinator.lastPublishedState))
        h.clock.advance(milliseconds: 600_000)
        #expect(!isComparingPrimary(await h.coordinator.state))
        await log.settled(h.coordinator)
        #expect(isComparingPrimary(await log.states.last ?? .idle))
        await log.stop()
    }

    /// The run loop sleeps on the injected clock and polls when due; the code is hidden at the challenge's expiry without any poll.
    @Test func testRunLoopDrivesThePairingAndHidesTheCodeAtExpiry() async throws {
        let h = try await PairHarness.make(.firstTime)
        let log = StateLog(); await log.attach(h.coordinator)
        let offer = try await h.rig.newOffer()
        _ = await h.coordinator.start(link: try h.link(offer))
        let runner = Task { await h.coordinator.run() }
        // The clock advances only while run() is parked on it; the fakes act between ticks.
        func tick(pump: Bool = true, _ until: @escaping @Sendable (PairingState) -> Bool) async throws -> PairingState {
            let r = try await h.tickRunLoop(pump: pump, until: until)
            if !r.met { Issue.record("run loop did not reach the expected state: \(r.diagnostics)") }
            return r.state
        }
        guard case .comparingHost = try await tick(isComparingHost) else { Issue.record("no host code"); return }
        try await h.hostApproves()
        guard case .comparingPrimary = try await tick(isComparingPrimary) else { Issue.record("no cert code"); return }
        // time passes on the primary's side with nobody acting but run(): the code disappears at expires_ms by itself
        let hidden = try await tick(pump: false, { if case .waitingPrimary(_, _, true) = $0 { return true }; return false })
        guard case .waitingPrimary(_, _, let challengeExpired) = hidden else { Issue.record("code still shown: \(hidden)"); runner.cancel(); return }
        #expect(challengeExpired)
        await log.settled(h.coordinator)
        let seen = await log.states
        if let i = seen.lastIndex(where: isComparingPrimary) { #expect(seen[(i + 1)...].allSatisfy { !isComparingPrimary($0) }) }
        runner.cancel(); await log.stop()
    }

    @Test func testLostFirstAnswerIsRecoveredByTheSameKeys() async throws {
        // the pair request is posted, the host is unreachable, the phone re-sends the same pairing request (same keys) after a while;
        // the host answers `pending` for the holder (a resend), and the phone gets its code
        let h = try await PairHarness.make(.firstTime)
        let offer = try await h.rig.newOffer()
        _ = await h.coordinator.start(link: try h.link(offer))
        await h.coordinator.poll()
        for _ in 0..<16 { h.clock.advance(milliseconds: 1000); await h.coordinator.poll() }
        #expect(await h.relay.accepted >= 2)                             // two pair requests are waiting
        try await h.rig.pump()
        guard case .comparingHost(let code) = try await h.drive(until: isComparingHost) else { Issue.record("no code after the resend"); return }
        let panel = await h.host.pendingPairings()
        #expect(panel.first?.sas == code && panel.count == 1)
        // a different consumer with other keys is then refused: the offer is single use
        let intruder = SoftwareSigner()
        let forge = PairForge(h: h, link: try h.link(offer))
        try await forge.sendPair(signer: intruder, keys: DemoKeys(sig: intruder.publicKey, kx: SoftwareKeyAgreer().publicKey), label: "Intruder")
        try await h.rig.pump()
        #expect(await h.host.pendingPairings().count == 1)
    }

    @Test func testNothingIsShownFromStoredStateAfterARestart() async throws {
        let h = try await PairHarness.make(.firstTime)
        _ = try await h.startToHostCode()
        let restarted = PairingCoordinator(h.config)
        _ = await restarted.resume(ws: h.host.workspace)
        // however often the screen asks, until a fresh verified answer arrives no code is shown
        for _ in 0..<3 { await restarted.poll(); #expect(!isComparingHost(await restarted.state)) ; h.clock.advance(milliseconds: 100) }
        #expect(await restarted.state == .connecting(origin: DemoRelay.origin))
    }
}
