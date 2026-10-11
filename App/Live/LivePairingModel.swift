import Foundation
import Observation
import OrchClient
import OrchFakeHost
import OrchProtocol
import OrchUI

/// The pairing flow over the real `PairingCoordinator`. The coordinator owns every state, code and deadline; this model maps them to the
/// screens and forwards explicit human actions. The Demo host and Demo primary panels drive the fakes' explicit approvals
/// (`approvePairing(confirmedComparison:)`, `FakePrimary.approve`); codes shown there come from the fakes' own derivations, not from the phone.
@MainActor @Observable
final class LivePairingModel: PairingFlowModel {
    private let services: LiveServices
    private(set) var state: PairingState = .entry
    private(set) var demoHostCode = ""
    private(set) var demoPrimaryCertCode = ""
    private(set) var demoPrimaryHasChallenge = false
    private(set) var demoOfferLink = ""
    var isDemo: Bool { services.isDemo }
    var hostLabel: String { "Demo Mac" }

    @ObservationIgnored private var coordinator: PairingCoordinator?
    @ObservationIgnored private var entry: DemoRuntime.Entry?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var invitationTask: Task<Void, Never>?
    @ObservationIgnored private var beginTask: Task<Void, Never>?
    @ObservationIgnored var beforeInvitation: (() async -> Void)?
    @ObservationIgnored private(set) var panelStarts = 0
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var panelTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var rejectedBy: PairingRefusal = .rejectedOnHost
    @ObservationIgnored private var joinedReported = false
    /// Counts every state the stream delivered: a sampled state read before a newer streamed one is dropped.
    @ObservationIgnored private var streamSeq = 0

    init(services: LiveServices, start: PairingState?) {
        self.services = services
        if let start, case .entry = start { state = .entry }
    }

    // MARK: Entry

    func submitLink(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isDemo else { state = .refused(.relayNotConnected); return }
        guard let link = try? PairingLink.parse(trimmed) else { state = .refused(.invalidLink); return }
        begin(link: link)
    }

    func useDemoInvitation() {
        generation += 1
        let mine = generation
        state = .connecting
        invitationTask?.cancel()
        invitationTask = Task {
            guard let runtime = await services.demoRuntime(), mine == generation else { return }
            do {
                let invitation = try await runtime.createInvitation(scenario: services.pairingScenario)
                guard mine == generation, let link = try? PairingLink.parse(invitation.link) else { return }
                begin(link: link)
            } catch { if mine == generation { state = .refused(.invalidLink) } }
        }
    }

    /// The host panel's "new pairing link": what the Remote tab on the Mac would show.
    func demoNewLink() {
        invitationTask?.cancel()
        generation += 1
        let mine = generation
        invitationTask = Task {
            guard let runtime = await services.demoRuntime(), mine == generation, !Task.isCancelled else { return }
            await beforeInvitation?()
            if let invitation = try? await runtime.createInvitation(scenario: services.pairingScenario) {
                guard mine == generation, !Task.isCancelled else { return }
                demoOfferLink = invitation.link
                entry = invitation.entry
                startPanelRefresh()
            }
        }
    }

    func waitForInvitation() async { await invitationTask?.value }

    private func begin(link: PairingLink) {
        generation += 1
        let mine = generation
        state = .connecting
        joinedReported = false
        rejectedBy = .rejectedOnHost
        beginTask?.cancel()
        beginTask = Task {
            guard let runtime = await services.demoRuntime(), mine == generation else { return }
            entry = runtime.entry(for: link.workspace)
            let coordinator = runtime.makeCoordinator()
            self.coordinator = coordinator
            startPanelRefresh()
            let stream = await coordinator.states()
            guard mine == generation, !Task.isCancelled else { return }
            stateTask?.cancel()
            stateTask = Task { [weak self] in
                for await s in stream {
                    guard let self, !Task.isCancelled, self.generation == mine else { return }
                    self.streamSeq += 1
                    self.apply(s, runtime: runtime)
                }
            }
            let first = await coordinator.start(link: link)
            guard mine == generation else { return }
            apply(first, runtime: runtime)
            if entry?.answers == false { runtime.fastForward(seconds: 61) }     // the link-used scenario: nobody ever answers
            runTask?.cancel()
            runTask = Task { await coordinator.run() }
        }
    }

    /// The pairing screen disappeared. An unfinished pairing is cancelled (nothing keeps running for a screen nobody sees); after a
    /// join only this model's own observers stop, never the coordinator or the joined workspace.
    func screenClosed() {
        cancel()
    }

    func cancel() {
        generation += 1
        invitationTask?.cancel(); beginTask?.cancel()
        // After a join the pairing is over: Cancel/Close must never reach the joined workspace through the coordinator.
        if case .ready = state { panelTask?.cancel(); stateTask?.cancel(); return }
        stateTask?.cancel(); runTask?.cancel(); panelTask?.cancel()
        let coordinator = self.coordinator
        self.coordinator = nil
        state = .entry
        demoHostCode = ""; demoPrimaryCertCode = ""; demoPrimaryHasChallenge = false
        entry = nil
        Task {
            await coordinator?.cancel()
            await coordinator?.dismiss()
        }
    }

    private var isTerminalState: Bool {
        switch state {
        case .ready, .alarm, .refused, .expired: true
        default: false
        }
    }

    // MARK: State mapping

    private func apply(_ s: OrchClient.PairingState, runtime: DemoRuntime) {
        switch s {
        case .idle, .parsing: break
        case .connecting: state = .connecting
        case .comparingHost(let code): state = .comparingHost(sas: code)
        case .waitingPrimary(_, _, let challengeExpired) where challengeExpired:
            // The challenge ran out: the code is hidden everywhere and nothing can be approved (no deadline is extended).
            state = .expired
        case .waitingPrimary(let label, let deadlineMs, _):
            state = .waitingPrimary(primaryLabel: label, deadline: runtime.date(forMs: deadlineMs))
        case .comparingPrimary(let code, let label, let expiresMs):
            state = .comparingPrimary(primaryLabel: label, certCode: code, expires: runtime.date(forMs: expiresMs))
        case .joining: state = .joining
        case .ready(let handle):
            if !joinedReported {
                joinedReported = true
                services.workspaceJoined(handle)
            }
            panelTask?.cancel()
            state = .ready(workspaceName: handle.joined.name)
        case .alarm(let alarm):
            switch alarm.kind {
            case .echoWrongKey: state = .alarm(.echoWrongKey)
            case .r1Challenge: state = .alarm(.r1Attack(primaryLabel: alarm.primaryLabel))
            case .pinSubstitution, .regression: state = .alarm(.substitution)
            }
        case .rejected: state = .refused(rejectedBy)
        case .expired: state = .expired
        case .failed(let f):
            switch f {
            case .linkUsed: state = .refused(.linkUsed)
            case .otherPerson: state = .refused(.otherPerson)
            case .realm: state = .refused(.invalidLink)
            case .hostRefused: state = .refused(.rejectedOnHost)
            case .clockWrong: state = .refused(.clockWrong)
            case .verification: state = .refused(.couldNotVerify)
            case .joiningTimedOut: state = .refused(.timedOut)
            case .alreadyMember: state = .refused(.alreadyMember)
            case .custody: state = .refused(.keysUnavailable)
            }
        case .cancelled: state = .entry
        }
    }

    // MARK: Demo host panel

    func hostApprove() {
        guard case .comparingHost = state, let host = entry?.host else { return }
        Task {
            guard let runtime = await services.demoRuntime() else { return }
            try? await host.approvePairing(device: runtime.env.deviceID, confirmedComparison: true, relay: runtime.env.relay,
                                           transport: runtime.env.transport)
        }
    }

    func hostReject() {
        guard case .comparingHost = state, let host = entry?.host else { return }
        rejectedBy = .rejectedOnHost
        beginTask?.cancel()
        beginTask = Task {
            guard let runtime = await services.demoRuntime() else { return }
            try? await host.rejectPairing(device: runtime.env.deviceID)
        }
    }

    // MARK: Demo primary panel

    func primaryOpenRequest() {
        guard case .waitingPrimary = state else { return }
        Task {
            guard let runtime = await services.demoRuntime(), runtime.primaryOnline else { return }
            await runtime.primary.processInbox(relay: runtime.env.relay)
        }
    }

    func primaryApprove() {
        guard case .comparingPrimary = state else { return }
        Task {
            guard let runtime = await services.demoRuntime() else { return }
            let device = runtime.env.deviceID
            guard let prompt = await runtime.primary.openPrompts().first(where: { $0.deviceID == device }) else { return }
            _ = try? await runtime.primary.approve(request: prompt.requestID, confirmedComparison: true, relay: runtime.env.relay)
        }
    }

    func primaryReject() {
        switch state {
        case .comparingPrimary, .waitingPrimary:
            rejectedBy = .rejectedOnPrimary
            Task {
                guard let runtime = await services.demoRuntime() else { return }
                let device = runtime.env.deviceID
                if let prompt = await runtime.primary.openPrompts().first(where: { $0.deviceID == device }) {
                    try? await runtime.primary.reject(request: prompt.requestID, relay: runtime.env.relay)
                } else {
                    // Nothing was opened yet: the human at the primary turns the request down, so the pairing ends here.
                    generation += 1
                    stateTask?.cancel(); runTask?.cancel()
                    await coordinator?.cancel()
                    state = .refused(.rejectedOnPrimary)
                }
            }
        default: break
        }
    }

    /// Both Demo clocks are the real shared clock moving forward: expiry comes from the coordinator, not from this model.
    func primaryTimeElapses() {
        guard case .waitingPrimary = state else { return }
        Task { await services.demoRuntime()?.fastForward(seconds: 601) }
    }

    func codeTimeElapses() {
        guard case .comparingPrimary(_, _, let expires) = state else { return }
        // Move the shared Demo clock exactly to the signed expiry (plus a second), never past what the coordinator would accept.
        Task { await services.demoRuntime()?.fastForward(seconds: max(1, Int(expires.timeIntervalSinceNow.rounded(.up)) + 1)) }
    }

    // MARK: Panel refresh (the fakes' own screens)

    private func startPanelRefresh() {
        panelStarts += 1
        panelTask?.cancel()
        let mine0 = generation
        panelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let runtime = await self.services.demoRuntime(), self.generation == mine0, !Task.isCancelled else { return }
                let device = runtime.env.deviceID
                // The coordinator derives its state from time (a code hides the instant it expires); sample it as well as the stream.
                if let c = self.coordinator, self.generation == mine0 {
                    let seq = self.streamSeq
                    let sampled = await c.state
                    // A newer streamed state wins over this older sample, and a terminal state is never overwritten.
                    if seq == self.streamSeq, self.generation == mine0, !self.isTerminalState { self.apply(sampled, runtime: runtime) }
                }
                if let host = self.entry?.host {
                    let pending = await host.pendingPairings().first { $0.device == device && $0.state == "pending" }
                    self.demoHostCode = pending?.sas ?? ""
                }
                let prompt = await runtime.primary.openPrompts().first { $0.deviceID == device }
                self.demoPrimaryCertCode = prompt?.certCode ?? ""
                self.demoPrimaryHasChallenge = prompt != nil
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }
}
