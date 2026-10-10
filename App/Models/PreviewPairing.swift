import Foundation
import Observation

/// Fake pairing coordinator driving the U5 states, including the Demo host and Demo primary panels.
@MainActor @Observable
final class PreviewPairingModel: PairingFlowModel {
    private let world: PreviewWorld
    private(set) var state: PairingState
    private var task: Task<Void, Never>?
    private var scenario: PairingScenario
    private(set) var demoPrimaryHasChallenge = false

    let demoHostCode = "K7QMX2"
    let demoPrimaryCertCode = "493 128"
    let hostLabel = "Demo Mac"
    var isDemo: Bool { world.isDemo }

    init(world: PreviewWorld, start: PairingState?) {
        self.world = world
        self.scenario = world.pairingScenario
        self.state = start ?? .entry
        if case .comparingPrimary = state { demoPrimaryHasChallenge = true }
    }

    func submitLink(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard world.isDemo else { state = .refused(.relayNotConnected); return }
        guard let url = URL(string: trimmed), url.host == "relay.demo.invalid",
              url.path == "/app/pair" || url.path == "/pair", url.fragment?.isEmpty == false else {
            state = .refused(.invalidLink); return
        }
        scenario = world.pairingScenario
        state = .connecting
        run { [self] in
            try? await Task.sleep(for: .milliseconds(700))
            switch scenario {
            case .echoWrongKey: state = .alarm(.echoWrongKey)
            case .linkUsed: state = .refused(.linkUsed)
            case .existingCert: state = .comparingHost(sas: demoHostCode)
            default: state = .comparingHost(sas: demoHostCode)
            }
        }
    }

    func useDemoInvitation() { submitLink("https://relay.demo.invalid/app/pair#demo-invitation") }

    func cancel() {
        task?.cancel()
        state = .entry
    }

    func hostApprove() {
        guard case .comparingHost = state else { return }
        switch scenario {
        case .rejectOnHost: state = .refused(.rejectedOnHost)
        case .existingCert: join()
        default:
            // The host code is cleared the moment cert_pending arrives.
            state = .waitingPrimary(primaryLabel: world.workspaces.first?.primaryLabel ?? "Demo Mac",
                                    deadline: Date().addingTimeInterval(600))
        }
    }

    func hostReject() { state = .refused(.rejectedOnHost) }

    func primaryOpenRequest() {
        guard case .waitingPrimary(let label, _) = state else { return }
        if scenario == .r1Attack {
            state = .alarm(.r1Attack(primaryLabel: label)); return
        }
        demoPrimaryHasChallenge = true
        state = .comparingPrimary(primaryLabel: label, certCode: demoPrimaryCertCode,
                                  expires: Date().addingTimeInterval(120))
    }

    func primaryApprove() {
        guard case .comparingPrimary = state else { return }
        join()
    }

    func primaryReject() { state = .refused(.rejectedOnPrimary) }

    func primaryTimeElapses() { state = .expired }

    private func join() {
        state = .joining
        run { [self] in
            try? await Task.sleep(for: .milliseconds(700))
            let id = "demo-lab"
            if !world.workspaces.contains(where: { $0.id == id }) {
                world.workspaces.append(WorkspaceInfo(
                    id: id, name: "Demo Lab", host: "Demo Mac", hue: 2, hostedBy: nil, clientHosted: false,
                    scopes: [.look, .decide], connection: .online, primaryLabel: "Demo Mac", notificationsOn: true))
            }
            state = .ready(workspaceName: "Demo Lab")
        }
    }

    private func run(_ body: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { await body() }
    }
}
