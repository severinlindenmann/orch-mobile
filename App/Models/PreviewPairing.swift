import Foundation
import Observation
import OrchUI

/// Fake pairing coordinator driving the U5 states, including the Demo host and Demo primary panels.
/// Every transition checks the active pairing generation; cancellation returns instead of continuing (D1).
@MainActor @Observable
final class PreviewPairingModel: PairingFlowModel {
    private let world: PreviewWorld
    private(set) var state: PairingState
    private var task: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var generation = 0
    private var scenario: PairingScenario
    private var primaryExpires: Date?
    private(set) var demoPrimaryHasChallenge = false

    let demoHostCode = "K7QMX2"
    let demoPrimaryCertCode = "493 128"
    var hostLabel: String { SafeText.label("Demo Mac", limit: 24, allowDigits: false) }
    var isDemo: Bool { world.isDemo }

    init(world: PreviewWorld, start: PairingState?) {
        self.world = world
        self.scenario = world.pairingScenario
        self.state = start ?? .entry
        scheduleExpiryIfNeeded()
    }

    func submitLink(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard world.isDemo else { state = .refused(.relayNotConnected); return }
        guard let url = URL(string: trimmed), url.host == "relay.demo.invalid",
              url.path == "/app/pair" || url.path == "/pair", url.fragment?.isEmpty == false else {
            state = .refused(.invalidLink); return
        }
        scenario = world.pairingScenario
        let gen = begin()
        state = .connecting
        run(gen) { [self] in
            guard await pause(0.7, gen) else { return }
            switch scenario {
            case .echoWrongKey: state = .alarm(.echoWrongKey)
            case .linkUsed: state = .refused(.linkUsed)
            default: state = .comparingHost(sas: demoHostCode)
            }
        }
    }

    var demoOfferLink: String { "" }
    func demoNewLink() {}

    func useDemoInvitation() { submitLink("https://relay.demo.invalid/app/pair#demo-invitation") }

    func cancel() {
        _ = begin()          // invalidates every pending transition
        state = .entry
    }

    func hostApprove() {
        guard case .comparingHost = state else { return }
        switch scenario {
        case .rejectOnHost: state = .refused(.rejectedOnHost)
        case .existingCert: join()
        default:
            // The host code is cleared the moment cert_pending arrives.
            let deadline = Date().addingTimeInterval(600)
            state = .waitingPrimary(primaryLabel: "Demo Mac", deadline: deadline)
            primaryExpires = deadline
            scheduleExpiryIfNeeded()
        }
    }

    func hostReject() { guard case .comparingHost = state else { return }; state = .refused(.rejectedOnHost) }

    func primaryOpenRequest() {
        guard case .waitingPrimary(let label, let deadline) = state else { return }
        guard Date() < deadline else { expire(); return }
        if scenario == .r1Attack {
            _ = begin()
            state = .alarm(.r1Attack(primaryLabel: label)); return
        }
        demoPrimaryHasChallenge = true
        let exp = Date().addingTimeInterval(120)
        state = .comparingPrimary(primaryLabel: label, certCode: demoPrimaryCertCode, expires: exp)
        primaryExpires = exp
        scheduleExpiryIfNeeded()
    }

    func primaryApprove() {
        guard case .comparingPrimary(_, _, let expires) = state else { return }
        guard Date() < expires else { expire(); return }
        join()
    }

    func primaryReject() {
        switch state {
        case .comparingPrimary: _ = begin(); state = .denied(owner: "5c0574d0")
        case .waitingPrimary: _ = begin(); state = .refused(.rejectedOnPrimary)
        default: break
        }
    }

    func primaryTimeElapses() { if case .waitingPrimary = state { expire() } }
    func codeTimeElapses() { if case .comparingPrimary = state { expire() } }

    // MARK: Internals

    private func expire() {
        _ = begin()
        demoPrimaryHasChallenge = false
        primaryExpires = nil
        state = .expired
    }

    /// Starts a new generation; anything scheduled before is dead.
    private func begin() -> Int {
        generation += 1
        task?.cancel(); expiryTask?.cancel()
        return generation
    }

    private func scheduleExpiryIfNeeded() {
        let deadline: Date
        switch state {
        case .waitingPrimary(_, let d): deadline = d
        case .comparingPrimary(_, _, let e): deadline = e; demoPrimaryHasChallenge = true
        default: return
        }
        expiryTask?.cancel()
        let gen = generation
        expiryTask = Task { [weak self] in
            let wait = max(0, deadline.timeIntervalSinceNow)
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            guard let self, self.generation == gen else { return }
            self.expire()
        }
    }

    private func pause(_ seconds: Double, _ gen: Int) async -> Bool {
        do { try await Task.sleep(for: .seconds(seconds)) } catch { return false }
        return !Task.isCancelled && gen == generation
    }

    private func join() {
        let gen = begin()
        state = .joining
        run(gen) { [self] in
            guard await pause(0.7, gen) else { return }
            let id = "demo-lab"
            if !world.workspaces.contains(where: { $0.id == id }) {
                world.workspaces.append(WorkspaceInfo(
                    id: id, name: "Demo Lab", host: "Demo Mac", hue: 2, hostedBy: nil, clientHosted: false,
                    scopes: [.look, .decide], connection: .online, primaryLabel: "Demo Mac", notificationsOn: true, writeSupport: true))
            }
            state = .ready(workspaceName: "Demo Lab")
        }
    }

    private func run(_ gen: Int, _ body: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { await body() }
    }
}
