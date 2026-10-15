import Foundation
import Observation
import OrchCoordination
import OrchCustody
import OrchShareStaging

/// Owns the active realm and replaces its entire service graph on every transition (decision: one active realm, explicit destructive
/// switch). The view layer keys on `epoch`, so navigation stacks, sheets and pairing presentations of the outgoing realm are dropped
/// with it; the outgoing services are retired first, which ends their lifetime and makes every late completion inert.
///
/// Demo is entered from Welcome. `.live` is entered at launch only: a persisted Live install (written by the Live invitation flow, B2b)
/// restores on every relaunch. There is no Welcome entry or link intake for Live yet.
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
    /// Where the leave in progress (or the failed one awaiting Retry) is going; cleared when a leave completes.
    @ObservationIgnored private var retryThenDemo: Bool?
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
        completeShareRemovals()
        publish()
        booted = true
    }

    private func publish() {
        if services.resetIncomplete { state = .recoveryRequired }
        else if services.isLive || (services.hasLiveInstall && services.liveBootError != nil) {
            state = .live
            if let error = services.liveBootError { notice = error }
        }
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
        // One active realm: a Live install on record (even one that failed to start) is left explicitly, never replaced silently.
        guard !services.hasLiveInstall else { notice = "Leave Live first to try Demo."; return }
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
    func realmLeave(thenDemo requested: Bool) {
        guard state != .leaving, state != .starting else { return }
        // N1: a retry after a failed wipe goes where the failed one was going (Welcome, or Demo for "Reset Demo data").
        let thenDemo = state == .recoveryRequired ? (retryThenDemo ?? requested) : requested
        retryThenDemo = thenDemo
        let outgoing = services
        let label = outgoing.deviceLabel
        notice = nil
        if let realm = outgoing.shareRealm { retireShareTargets(realms: [realm]) }
        else if outgoing.hasLiveInstall { retireShareTargets(realms: [Realm.live.rawValue]) }     // a Live that never started
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
            self.retryThenDemo = nil
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
    ///
    /// If any step before the publish fails, the filtered list is NOT published: the entries stay and the index is marked stale
    /// (the extension then offers nothing), so a destination is never in neither the journal nor the index. `realms == nil` means
    /// every realm (a boot into Welcome has no live destination at all).
    private func retireShareTargets(realms: Set<String>?) {
        guard let area = shareArea else { return }
        let inbox = ShareInbox(area: area)
        do {
            let persisted = try ShareTargetIndex.persisted(from: area)
            let gone = persisted.filter { realms?.contains($0.realm) ?? true }
            for t in gone { try journalRemoval(inbox, TombstoneRecord(realm: t.realm, ws: t.ws, generation: t.generation)) }
            try inbox.replayRemovals()
            try ShareTargetIndex.publish(persisted.filter { t in !gone.contains(t) }, to: area)
            inbox.purgeTombstoned()
        } catch {
            ShareTargetIndex.recordPublishSkipped("fence: " + ShareTargetIndex.PublishStatus.code(error), in: area)
        }
    }

    /// The journal write (a test seam for a failing journal).
    @ObservationIgnored var journalRemoval: (ShareInbox, TombstoneRecord) throws -> Void = { try $0.recordRemoval($1) }

    /// Launch: finishes what an earlier leave left behind. A boot with no realm retires only the destinations of realms whose storage is
    /// wiped at boot (Demo): they are stale. Live destinations are never retired here, because a failed or absent Live runtime (a boot
    /// error, an unfinished wipe, a restore that failed before first unlock) would burn their generation for good; only an explicit
    /// Leave Live or Reset retires them. In any realm the pending journal is replayed and tombstoned plaintext purged.
    private func completeShareRemovals() {
        guard let area = shareArea else { return }
        if services.realm == nil { retireShareTargets(realms: [Realm.demo.rawValue]) }
        let inbox = ShareInbox(area: area)
        try? inbox.replayRemovals()
        inbox.purgeTombstoned()
    }

    func waitForTransition() async { await transitionTask?.value }
}
