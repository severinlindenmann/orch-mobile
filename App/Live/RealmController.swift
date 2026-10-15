import Foundation
import Observation
import OrchCoordination
import OrchShareStaging

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
    /// A visible explanation when a requested realm could not start (shown over Welcome).
    private(set) var notice: String?
    /// The share extension's App Group area (nil where the group is unavailable: unit tests, unsigned builds).
    @ObservationIgnored var shareArea: ShareArea? = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: ShareBridge.groupIdentifier).map { ShareArea(shareGroupRoot: $0) }
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
        notice = nil
        let label = services.deviceLabel
        let next = makeServices(options, defaults)
        next.deviceLabel = label
        replaceServices(with: next)
        state = .starting
        transitionTask = Task { [weak self] in await self?.bootDemo(next) }
    }

    /// Boots `next` into Demo. A Demo that cannot start leaves a visible notice instead of silently landing on Welcome.
    private func bootDemo(_ next: LiveServices) async {
        await next.boot(enterDemo: true, launch: false)
        transitionTask = nil
        guard services === next else { return }
        if !next.isDemo && !next.resetIncomplete { notice = "Demo could not start. Try again." }
        publish()
    }

    /// Leaves the current realm completely, then lands on Welcome, or boots Demo again when `thenDemo` ("Reset Demo data").
    ///
    /// Ordering: everything that can still reach the outgoing realm is cut off synchronously, before any await: the share destinations
    /// are retired, the outgoing view graph is dropped (`epoch`), and its lifetime is invalidated. Then the wipe runs. A failed wipe
    /// parks the controller in `recoveryRequired` with the outgoing realm still in place; the destination is never activated meanwhile.
    func realmLeave(thenDemo: Bool) {
        guard state != .leaving, state != .starting else { return }
        let outgoing = services
        let label = outgoing.deviceLabel
        notice = nil
        retireShareTargets(realm: outgoing.shareRealm)
        state = .leaving
        epoch += 1
        outgoing.teardown()
        transitionTask = Task { [weak self] in
            await outgoing.waitForReset()
            guard let self else { return }
            guard self.services === outgoing else { self.transitionTask = nil; return }
            if outgoing.resetIncomplete {
                self.transitionTask = nil
                self.state = .recoveryRequired
                self.epoch += 1
                return
            }
            let next = self.makeServices(self.options, self.defaults)
            next.deviceLabel = thenDemo ? label : "iPhone"
            self.replaceServices(with: next)
            if thenDemo {
                self.state = .starting
                await self.bootDemo(next)       // the one boot of the target realm; waitForTransition covers it
            } else {
                await next.boot(launch: false)
                self.transitionTask = nil
                self.publish()
            }
        }
    }

    /// The share fence: tombstones every persisted destination of the outgoing realm (durable journal, coordination record, staged and
    /// quarantined plaintext purged), then republishes what remains (other realms' entries, in practice none). Synchronous and
    /// independent of any view. A share sheet already open can no longer finish staging (`destinationRemoved`), and the next graph
    /// replays the same journal, so nothing of the outgoing realm survives the leave.
    private func retireShareTargets(realm: String?) {
        guard let area = shareArea, let realm else { return }
        let inbox = ShareInbox(area: area)
        let persisted = (try? ShareTargetIndex.persisted(from: area)) ?? []
        for t in persisted where t.realm == realm {
            try? inbox.recordRemoval(TombstoneRecord(realm: t.realm, ws: t.ws, generation: t.generation))
        }
        try? inbox.replayRemovals()
        try? ShareTargetIndex.publish(persisted.filter { $0.realm != realm }, to: area)
        inbox.purgeTombstoned()
    }

    func waitForTransition() async { await transitionTask?.value }
}
