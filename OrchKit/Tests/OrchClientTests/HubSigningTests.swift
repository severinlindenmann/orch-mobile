import Foundation
import LocalAuthentication
import OrchCustody
import OrchFakeHost
import OrchProtocol
import Testing
@testable import OrchClient

/// Custodial signing from the phone (design B3) against the in-process fake hub: the allow-list, the digest recomputed from ctx, ctx over
/// `shown`, the phone bindings, Face ID (biometry only, domain state), offline, expiry, and a lost answer.
private final class Clock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var ms: Int64 = 1_790_000_000_000
    var nowMs: Int64 { lock.withLock { ms } }
    func advance(_ d: Int64) { lock.withLock { ms += d } }
}

/// A sender in front of the fake hub that can go offline, or lose the answer to one path after the hub handled it.
private final class Link: RequestSender, @unchecked Sendable {
    let inner: FakeHub
    private let lock = NSLock()
    private var _offline = false, _loseAnswerOf: String?
    var origin: String { inner.origin }
    init(_ inner: FakeHub) { self.inner = inner }
    var offline: Bool { get { lock.withLock { _offline } } set { lock.withLock { _offline = newValue } } }
    var loseAnswerOf: String? { get { lock.withLock { _loseAnswerOf } } set { lock.withLock { _loseAnswerOf = newValue } } }
    func send(_ request: WireRequest) async throws -> WireReply {
        if offline { throw TransportError.disconnected }
        let r = try await inner.send(request)
        if let p = loseAnswerOf, request.target.hasSuffix(p) { throw TransportError.disconnected }
        return r
    }
}

/// Stands in for `LAContext`: records the policy it was asked for, answers from a script.
private final class MockLA: BiometricContext, @unchecked Sendable {
    nonisolated(unsafe) static var policies: [LAPolicy] = []
    nonisolated(unsafe) static var fallbackTitles: [String?] = []
    nonisolated(unsafe) static var domainState: Data? = Data("faces-1".utf8)
    nonisolated(unsafe) static var canError: LAError.Code?
    nonisolated(unsafe) static var evalError: LAError.Code?
    nonisolated(unsafe) static var evaluations = 0
    nonisolated(unsafe) static var onEvaluate: (() -> Void)?
    static func reset() { policies = []; fallbackTitles = []; domainState = Data("faces-1".utf8); canError = nil; evalError = nil; evaluations = 0; onEvaluate = nil }

    var localizedFallbackTitle: String? { didSet { Self.fallbackTitles.append(localizedFallbackTitle) } }
    var evaluatedPolicyDomainState: Data? { Self.domainState }
    func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool {
        Self.policies.append(policy)
        if let c = Self.canError { error?.pointee = NSError(domain: LAError.errorDomain, code: c.rawValue); return false }
        return true
    }
    func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws -> Bool {
        Self.policies.append(policy); Self.evaluations += 1; Self.onEvaluate?()
        if let c = Self.evalError { throw NSError(domain: LAError.errorDomain, code: c.rawValue) }
        return true
    }
}

private struct Rig {
    let hub: FakeHub
    let link: Link
    let clock = Clock()
    let backend = InMemoryVaultBackend()
    let custody: HubKeyCustody
    let session: HubSignSession
    let hubID: String
    static let faces = Data("faces-1".utf8)

    /// Pairs with the fake hub (recording the biometry baseline), then builds the sign session.
    init(faces: Data? = Rig.faces, contentLink: Bool = true, workspaces: Bool = false) async throws {
        MockLA.reset()
        let clock = self.clock
        let h = FakeHub(origin: "https://hub.dev.orch.example", wall: clock)
        let l = Link(h)
        hub = h; link = l
        let cust = HubKeyCustody(keys: SecretVault(group: .keys, backend: backend), push: SecretVault(group: .push, backend: backend))
        custody = cust
        let make: @Sendable (String) throws -> any RequestSender = { _ in l }
        var baseline: (@Sendable () -> Data?)?
        if let f = faces { baseline = { @Sendable in f } }
        let coordinator = HubPairingCoordinator(HubPairingConfig(custody: cust, verifier: HubVerifier(devMode: true), wall: clock, makeSender: make,
                                                                  biometryBaseline: baseline))
        guard case .confirm = await coordinator.begin(link: h.pairingLink),
              case .paired(let s) = await coordinator.complete(password: h.password, totp: h.totp, label: "Dev hub") else { throw TransportError.disconnected }
        hubID = s.hubID
        let ws = h.workspaceID
        session = HubSignSession(HubSignConfig(custody: cust, verifier: HubVerifier(devMode: true), wall: clock, makeSender: make,
                                               biometry: BiometricGate(makeContext: { MockLA() }),
                                               isMyWorkspace: { workspaces && $0 == ws },
                                               contentLink: { o, _, _ in contentLink ? URL(string: o + "/") : nil }),
                                 hubID: s.hubID)
    }

    var plan: HubSignAction { .approveGate(log: hub.ticketLog, gate: "plan", hash: FakeHub.contentHash) }
    func prepare(_ a: HubSignAction? = nil) async throws -> HubSignPrompt { try await session.prepare(workspaceID: hub.workspaceID, action: a ?? plan) }
}

private func failure(_ body: () async throws -> some Any) async -> HubSignFailure? {
    do { _ = try await body(); return nil } catch let f as HubSignFailure { return f } catch { return .custody }
}

@Suite(.serialized) struct HubSigningTests {
    @Test func signsAGateApprovalAfterFaceID() async throws {
        let rig = try await Rig()
        let p = try await rig.prepare()
        #expect(p.facts.sentence == "Approve the plan gate")
        #expect(p.facts.gate == "plan" && p.facts.gateGen == 2 && p.facts.shortHash == "3d3f 5e93 357c")
        #expect(p.contentLink != nil)
        #expect(MockLA.evaluations == 0)                      // nothing asked for before Confirm
        let receipt = try await rig.session.confirm(preparedID: p.preparedID)
        #expect(MockLA.evaluations == 1)
        #expect(receipt.type == "gate.approved" && receipt.log == rig.hub.ticketLog && receipt.hubLabel == "Dev hub")
        #expect(rig.hub.signedEvents.map(\.type) == ["gate.approved"])   // the fake hub verified the proof under the channel key
        // single use: a second Confirm signs nothing
        #expect(await failure { try await rig.session.confirm(preparedID: p.preparedID) } == .notLive)
        #expect(rig.hub.signedEvents.count == 1)
    }

    @Test func signsAllFourDecisionTypes() async throws {
        let rig = try await Rig()
        let log = rig.hub.ticketLog, h = FakeHub.contentHash
        let actions: [HubSignAction] = [.answerQuestion(log: log, question: "Q1", hash: h, option: "a", text: nil),
                                        .approveGate(log: log, gate: "code", hash: h), .requestChanges(log: log, gate: "plan", hash: h, text: "Add tests"),
                                        .giveVerdict(log: log, outcome: "pass", hash: h, text: nil)]
        for a in actions {
            let p = try await rig.prepare(a)
            #expect(p.facts.sentence != nil)
            _ = try await rig.session.confirm(preparedID: p.preparedID)
        }
        #expect(rig.hub.signedEvents.map(\.type) == ["question.answered", "gate.approved", "gate.changes_requested", "verdict.given"])
        let code = try await rig.prepare(.approveGate(log: log, gate: "code", hash: h))
        #expect(code.facts.sources == [HubSign.Source(repo: "orch-core", sha: "9f2c1a7b")])
        let verdict = try await rig.prepare(.giveVerdict(log: log, outcome: "pass", hash: h, text: nil))
        #expect(verdict.facts.sources.map(\.repo) == ["orch-core", "orch-mobile"])
    }

    // MARK: allow-list

    @Test func nothingOutsideTheFourTypesCanBeConfirmed() async throws {
        for type in ["ticket.moved", "people.changed", "visibility.changed", "settings.changed", "addon.purged", "workspace.created", "question.asked", "x"] {
            var f = FakeHub.Faults(); f.buildType = type
            let rig = try await Rig(workspaces: true)
            rig.hub.faults = f
            // self-started with a decision the hub then builds as another type
            #expect(await failure { try await rig.prepare() } == .notSignable(type: type), "\(type)")
            // pushed: the same refusal, before any Confirm exists
            let id = rig.hub.lastPreparedID ?? "none"
            #expect(id != "none" && (await failure { try await rig.session.open(preparedID: id) }) == .notSignable(type: type), "\(type)")
            #expect(await failure { try await rig.session.confirm(preparedID: rig.hub.lastPreparedID ?? "none") } == .notLive)
            #expect(rig.hub.signedEvents.isEmpty && MockLA.evaluations == 0)
        }
    }

    @Test func theActionTypeCannotBeAnythingButADecision() {
        // the only way to start a signature is HubSignAction, whose four cases are the allow-list
        let types = [HubSignAction.answerQuestion(log: "L", question: "Q1", hash: "h", option: nil, text: "t"), .approveGate(log: "L", gate: "plan", hash: "h"),
                     .requestChanges(log: "L", gate: "plan", hash: "h", text: "t"), .giveVerdict(log: "L", outcome: "pass", hash: "h", text: nil)]
            .map { $0.json.object?["type"]?.string ?? "" }
        #expect(types == HubSign.decisionTypes)
    }

    @Test func movesAreNotSignableOnThePhone() {
        for t in ["ticket.moved", "people.changed", "visibility.changed", "addon.disabled", "addon.purged", "policy.changed", "settings.changed"] {
            #expect(!HubSign.isDecisionType(t), "\(t)")
        }
    }

    // MARK: ctx wins

    @Test func theHubsShownBlockIsNeverRead() async throws {
        var f = FakeHub.Faults(); f.lyingShown = true
        let rig = try await Rig()
        rig.hub.faults = f
        let p = try await rig.prepare()
        #expect(p.facts.sentence == "Approve the plan gate")           // from ctx; the hub's `shown` said "Mark the ticket as read"
        #expect(!p.facts.fields.contains { $0.value.contains("Mark the ticket") })
    }

    @Test func aDigestOfAnotherEventIsRefusedAndNothingIsHeld() async throws {
        var f = FakeHub.Faults(); f.wrongDigest = true
        let rig = try await Rig()
        rig.hub.faults = f
        #expect(await failure { try await rig.prepare() } == .changed(code: "event_changed"))
        #expect(await failure { try await rig.session.confirm(preparedID: rig.hub.lastPreparedID ?? "none") } == .notLive)
        #expect(rig.hub.signedEvents.isEmpty && MockLA.evaluations == 0)
    }

    @Test func anEventForAnotherChannelOrWorkspaceIsRefused() async throws {
        var f = FakeHub.Faults(); f.buildChannel = String(repeating: "ab", count: 16)
        let rig = try await Rig()
        rig.hub.faults = f
        #expect(await failure { try await rig.prepare() } == .changed(code: "event_changed"))
        var g = FakeHub.Faults(); g.buildWorkspace = String(repeating: "cd", count: 16)
        rig.hub.faults = g
        #expect(await failure { try await rig.prepare() } == .changed(code: "event_changed"))
    }

    @Test func aBuiltEventThatIsNotTheActionIsRefused() async throws {
        var f = FakeHub.Faults(); f.buildType = "verdict.given"
        let rig = try await Rig()
        rig.hub.faults = f
        #expect(await failure { try await rig.prepare() } == .changed(code: "event_changed"))
        #expect(rig.hub.signedEvents.isEmpty)
    }

    @Test func aPushedRequestNeedsAWorkspaceTheCallerVouchesFor() async throws {
        let stranger = try await Rig(workspaces: false)
        let p = try await stranger.prepare()                        // self-started: the workspace is the one asked for
        #expect(await failure { try await stranger.session.open(preparedID: p.preparedID) } == .changed(code: "event_changed"))
        let mine = try await Rig(workspaces: true)
        let q = try await mine.prepare()
        let opened = try await mine.session.open(preparedID: q.preparedID)
        #expect(opened.facts == q.facts)
        _ = try await mine.session.confirm(preparedID: opened.preparedID)
    }

    @Test func contentBoundDecisionsNeedALinkQuestionsDoNot() async throws {
        let rig = try await Rig(contentLink: false)
        #expect(await failure { try await rig.prepare() } == .contentNotReachable)
        let q = try await rig.prepare(.answerQuestion(log: rig.hub.ticketLog, question: "Q1", hash: FakeHub.contentHash, option: nil, text: "yes"))
        #expect(q.contentLink == nil)
    }

    // MARK: Face ID

    @Test func faceIDIsBiometryOnlyWithNoPasscodeFallback() async throws {
        let rig = try await Rig()
        let p = try await rig.prepare()
        _ = try await rig.session.confirm(preparedID: p.preparedID)
        #expect(MockLA.policies.count >= 2 && MockLA.policies.allSatisfy { $0 == .deviceOwnerAuthenticationWithBiometrics })
        #expect(!MockLA.policies.contains(.deviceOwnerAuthentication))
        #expect(MockLA.fallbackTitles.allSatisfy { $0 == "" })
        #expect(BiometricGate.policy == .deviceOwnerAuthenticationWithBiometrics)
    }

    @Test func aCancelledFaceIDSignsNothingAndKeepsTheRequestLive() async throws {
        let rig = try await Rig()
        let p = try await rig.prepare()
        MockLA.evalError = .userCancel
        #expect(await failure { try await rig.session.confirm(preparedID: p.preparedID) } == .biometry(.cancelled))
        MockLA.evalError = .authenticationFailed
        #expect(await failure { try await rig.session.confirm(preparedID: p.preparedID) } == .biometry(.failed))
        #expect(rig.hub.signedEvents.isEmpty)
        MockLA.evalError = nil
        _ = try await rig.session.confirm(preparedID: p.preparedID)
        #expect(rig.hub.signedEvents.count == 1)
    }

    @Test func aChangedSetOfFacesMeansSignInAgain() async throws {
        let rig = try await Rig()
        let p = try await rig.prepare()
        MockLA.domainState = Data("faces-2".utf8)                  // a face was added after pairing
        #expect(await failure { try await rig.session.confirm(preparedID: p.preparedID) } == .signInAgain)
        #expect(MockLA.evaluations == 0)                           // not even asked
        #expect(rig.hub.signedEvents.isEmpty)
        #expect(try rig.custody.sessionToken(hubID: rig.hubID) == nil)   // the channel session is dropped
        #expect(await failure { try await rig.prepare() } == .signInAgain)
        #expect(await failure { try await rig.session.confirm(preparedID: p.preparedID) } == .notLive)
    }

    @Test func noRecordedBaselineMeansSignInAgain() async throws {
        let rig = try await Rig(faces: nil)
        let p = try await rig.prepare()
        #expect(await failure { try await rig.session.confirm(preparedID: p.preparedID) } == .signInAgain)
        #expect(rig.hub.signedEvents.isEmpty)
    }

    @Test func biometryErrorsAreMappedAndNothingIsSigned() async throws {
        let rig = try await Rig()
        let p = try await rig.prepare()
        MockLA.canError = .biometryNotEnrolled
        #expect(await failure { try await rig.session.confirm(preparedID: p.preparedID) } == .biometry(.notEnrolled))
        MockLA.canError = .biometryLockout
        #expect(await failure { try await rig.session.confirm(preparedID: p.preparedID) } == .biometry(.lockedOut))
        MockLA.canError = .biometryNotAvailable
        #expect(await failure { try await rig.session.confirm(preparedID: p.preparedID) } == .biometry(.unavailable))
        #expect(rig.hub.signedEvents.isEmpty)
    }

    @Test func theBaselineIsKeptWithThePairingAndWipedWithIt() async throws {
        let rig = try await Rig()
        #expect(try rig.custody.biometryBaseline(hubID: rig.hubID) == Rig.faces)
        try rig.custody.deleteAll(hubID: rig.hubID)
        #expect(try rig.custody.biometryBaseline(hubID: rig.hubID) == nil)
    }

    // MARK: offline, expiry, lost answers

    @Test func offlineNothingIsPreparedOrSignedOrQueued() async throws {
        let rig = try await Rig()
        rig.link.offline = true
        #expect(await failure { try await rig.prepare() } == .offline)
        rig.link.offline = false
        let p = try await rig.prepare()
        rig.link.offline = true
        #expect(await failure { try await rig.session.confirm(preparedID: p.preparedID) } == .offline)
        #expect(MockLA.evaluations == 0 && rig.hub.signedEvents.isEmpty)    // no Face ID, no proof, while the hub does not answer
        rig.link.offline = false
        _ = try await rig.session.confirm(preparedID: p.preparedID)         // still live: the person may try again when the hub is back
        #expect(rig.hub.signedEvents.count == 1)
    }

    @Test func neverSignsAtOrAfterExpiryMinusFiveSeconds() async throws {
        let rig = try await Rig()
        let p = try await rig.prepare()
        rig.clock.advance(120_000 - 5_000)                          // exactly expires_ms - 5 s
        #expect(await failure { try await rig.session.confirm(preparedID: p.preparedID) } == .expired)
        #expect(MockLA.evaluations == 0 && rig.hub.signedEvents.isEmpty)
        let q = try await rig.prepare()
        let clock = rig.clock
        MockLA.onEvaluate = { clock.advance(116_000) }              // Face ID took so long that the request ran out
        #expect(await failure { try await rig.session.confirm(preparedID: q.preparedID) } == .expired)
        #expect(rig.hub.signedEvents.isEmpty)
    }

    @Test func aLostAnswerIsUnknownAndNeverRetried() async throws {
        let rig = try await Rig()
        let p = try await rig.prepare()
        rig.link.loseAnswerOf = "/sign/sign"
        #expect(await failure { try await rig.session.confirm(preparedID: p.preparedID) } == .unknownOutcome)
        rig.link.loseAnswerOf = nil
        #expect(await failure { try await rig.session.confirm(preparedID: p.preparedID) } == .notLive)   // not sent again
        #expect(rig.hub.signedEvents.count == 1)
    }

    @Test func hubRefusalsAreMappedToFixedFailures() async throws {
        let rig = try await Rig()
        var f = FakeHub.Faults(); f.signError = "channel_revoked"
        let p = try await rig.prepare()
        rig.hub.faults = f
        #expect(await failure { try await rig.session.confirm(preparedID: p.preparedID) } == .hub(code: "channel_revoked"))
        #expect(rig.hub.signedEvents.isEmpty)
    }

    @Test func anExpiredChannelSessionMeansSignInAgain() async throws {
        let rig = try await Rig()
        rig.clock.advance(13 * 3_600_000)
        #expect(await failure { try await rig.prepare() } == .signInAgain)
    }

    // MARK: only one caller of the proof

    @Test func theProofIsMadeOnlyInTheSignSession() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        var callers: [String] = []
        let en = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let u as URL in en where u.pathExtension == "swift" {
            let text = try String(contentsOf: u, encoding: .utf8)
            if text.contains(".proof(context") { callers.append(u.lastPathComponent) }
        }
        #expect(callers == ["HubSigning.swift"], "\(callers)")
        // and the app target (a separate module) cannot reach the package-level call at all
        let app = sources.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")
        let appFiles = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for u in appFiles { #expect(!(try String(contentsOf: u, encoding: .utf8)).contains(".proof(context"), "\(u.lastPathComponent)") }
    }
}
