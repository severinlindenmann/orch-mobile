import Foundation
import Observation

/// Owns the active realm and replaces its entire service graph on every transition (decision: one active realm, explicit destructive
/// switch). The view layer keys on `epoch`, so navigation stacks, sheets and pairing presentations of the outgoing realm are dropped
/// with it; the outgoing services are retired first, which ends their lifetime and makes every late completion inert.
///
/// Only Demo is constructible today. `.live` exists as a state so the rest of the app is written against the final shape, but nothing
/// here can enter it yet (PR B adds the Live runtime together with pairing, restoration and a complete Live wipe).
@MainActor @Observable
final class RealmController: RealmTransitions {
    enum State: Equatable {
        case welcome
        case starting
        case demo
        case live
        case leaving
        /// A wipe did not finish: the outgoing realm stays in place (stopped, marked removal-incomplete) until Retry succeeds. The
        /// destination realm is not activated meanwhile.
        case recoveryRequired
    }

    let options: LaunchOptions
    private(set) var state: State = .welcome
    /// The current realm's service graph. Replaced, never reused, across transitions.
    private(set) var services: LiveServices
    /// Bumps on every graph replacement; the root view uses it as its identity.
    private(set) var epoch = 0
    private(set) var booted = false
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    /// Builds the next realm's services (a test seam).
    @ObservationIgnored var makeServices: (LaunchOptions, UserDefaults?) -> LiveServices = { options, defaults in
        LiveServices(options: options, resetFlags: defaults)
    }

    init(options: LaunchOptions, resetFlags: UserDefaults? = nil) {
        self.options = options
        // UI tests use a fresh preference suite per launch; every realm of this launch shares it.
        let shared = resetFlags ?? (options.uiTesting ? UserDefaults(suiteName: "orch.tests.\(UUID().uuidString)") : nil)
        defaults = shared
        services = LiveServices(options: options, resetFlags: shared)
        services.transitions = self
    }

    /// First launch: the realm the app was left in (a persisted or flagged Demo) or Welcome.
    func boot() async {
        guard !booted else { return }
        await services.boot()
        publish()
        booted = true
    }

    private func publish() {
        if services.resetIncomplete { state = .recoveryRequired }
        else { state = services.isDemo ? .demo : .welcome }
    }

    private func replaceServices(with next: LiveServices) {
        let previous = services
        previous.transitions = nil
        previous.retire()
        next.transitions = self
        services = next
        epoch += 1
    }

    // MARK: RealmTransitions

    /// Welcome -> Demo: a fresh service graph boots the Demo realm.
    func realmEnterDemo() {
        // Already in Demo (e.g. a forced Welcome route over a Demo launch): nothing to replace.
        guard state == .welcome, transitionTask == nil else { return }
        state = .starting
        let next = makeServices(options, defaults)
        replaceServices(with: next)
        transitionTask = Task { [weak self] in
            await next.boot(enterDemo: true)
            guard let self else { return }
            self.transitionTask = nil
            guard self.services === next else { return }
            self.publish()
        }
    }

    /// Demo -> Welcome (or -> Demo again for "Reset Demo data"): the outgoing realm is wiped completely first. A failed wipe parks the
    /// controller in `recoveryRequired` with the outgoing realm still in place; the destination is never activated meanwhile.
    func realmLeave(thenDemo: Bool) {
        guard state != .leaving, state != .starting else { return }
        let outgoing = services
        state = .leaving
        epoch += 1                 // the outgoing view graph (navigation, sheets, pairing) goes now
        outgoing.teardown(thenDemo: false)
        transitionTask = Task { [weak self] in
            await outgoing.waitForReset()
            guard let self else { return }
            self.transitionTask = nil
            guard self.services === outgoing else { return }
            if outgoing.resetIncomplete {
                self.state = .recoveryRequired
                self.epoch += 1
                return
            }
            let next = self.makeServices(self.options, self.defaults)
            self.replaceServices(with: next)
            await next.boot()
            self.state = .welcome
            if thenDemo { self.realmEnterDemo() }
        }
    }

    func waitForTransition() async { await transitionTask?.value }
}
