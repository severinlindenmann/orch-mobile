import Foundation
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
import OrchPush

/// What a realm may offer on this iPhone. Feature gating asks the capability, never `isDemo`: "not Demo" does not mean "everything
/// production is enabled". Demo has every capability on; a Live realm will start with Drop, share and push off (docs/live-mode.md).
struct RealmCapabilities: Equatable, Sendable {
    /// Drop tab, Drop card, Drop routes, a workspace's Files segment, and the `LiveDrop` service behind them.
    var drop: Bool
    /// Destinations offered to the share extension, and any import/upload work for them.
    var share: Bool
    /// APNs registration and the notification permission prompt (not only the UI that shows them).
    var push: Bool
    /// Scenario controls, fake host/primary panels, fault and offline simulation, notification simulation, `SimulationNotice`.
    var demoControls: Bool

    static let demo = RealmCapabilities(drop: true, share: true, push: true, demoControls: true)
    static let none = RealmCapabilities(drop: false, share: false, push: false, demoControls: false)
}

/// One realm's lifetime. A transition invalidates it; every late completion (pairing, session, decision) checks it before it writes,
/// signs or registers anything, so a handle that outlives its realm is inert. Main-actor confined.
@MainActor
final class RealmLifetime {
    private(set) var isActive = true
    func invalidate() { isActive = false }
}

/// What the app needs from a realm's runtime, Demo or (later) Live: coordinator construction, workspace restoration, wipe and shutdown.
/// Nothing Demo-specific is reachable through it (see `DemoControls`).
@MainActor
protocol RealmRuntime: AnyObject, Sendable {
    var realm: Realm { get }
    /// What this realm offers. The services' capabilities are exactly these while the runtime is attached, and none otherwise.
    var capabilities: RealmCapabilities { get }
    /// The realm's clock in epoch milliseconds (Demo: the shared, fast-forwardable Demo clock).
    var nowMs: Int64 { get }
    var deviceLabel: String { get set }
    func date(forMs ms: Int64) -> Date
    /// A pairing coordinator on the realm's one context. Throws while the runtime is not booted (Live: no index yet).
    func makeCoordinator() throws -> PairingCoordinator
    /// Workspaces committed in an earlier launch, rebuilt as joined handles. Demo has none: its boot wipes the previous realm.
    func restoreWorkspaces() async throws -> [JoinedHandle]
    /// The local, resumable wipe of one workspace.
    func wipe(workspace: ID16, generation: Int64) async throws
    /// Synchronously ends the realm's generation (`RealmContext.invalidate`): from this call on, nothing built on the realm's context can
    /// sign, seal, send or commit durable state (custody leases, transport, workspace store, vault writes, pairing commit), and no
    /// operation that already passed its check is still running when it returns. Idempotent. `LiveServices.teardown` calls it as its
    /// first statement, before any await.
    func invalidate()
    /// Cancels and awaits (bounded) every session and pairing coordinator built on the realm. Call after `invalidate`. `LiveServices.retire`
    /// uses it so a retired graph never leaves a running session behind (L1).
    func drain() async
    /// The realm's write fence, for the few writes that happen outside OrchClient (the ticket draft file, push material): they run inside
    /// `performFenced`, so a finished realm cannot write into its successor.
    var writeFence: (any WriteFence)? { get }
    /// Wipes the whole realm (workspaces, directory, device keys). Order: the realm generation is invalidated (`invalidate`), every
    /// pairing coordinator and `WorkspaceSession` built on the realm is cancelled and awaited (bounded), then the wipe runs. The
    /// app-level lifetime fence (`RealmLifetime`) is invalidated by the services before this runs.
    func shutdown() async throws
    @discardableResult func rebuildPresentationGate() async -> Bool
    /// Where a workspace keeps its unsent new-ticket draft (inside its own directory, which the wipe deletes).
    func draftURL(workspace: ID16) -> URL?
}

/// Demo-only controls: scenarios, the fake host and primary, fault and lock simulation, notification simulation and Drop seeding.
/// Only the Demo runtime conforms; non-Demo code paths reach it through `LiveServices.demo` and never see Demo types otherwise.
@MainActor
protocol DemoControls: RealmRuntime {
    var clock: TestClock { get }
    var faults: ScriptedFaults { get }
    var lock: SimulatedLock { get }
    var env: DemoEnvironment { get }
    var primary: FakePrimary { get }
    var speed: Int64 { get set }
    var primaryOnline: Bool { get }
    func entry(for workspace: ID16) -> DemoRuntime.Entry?
    func createInvitation(scenario: PairingScenario) async throws -> DemoRuntime.Invitation
    func fastForward(seconds: Int)
    func markJoined(_ workspace: ID16)
    func askDemoQuestion(workspace: ID16) async -> ID16?
    func simulatePush(workspace: ID16, name: String, generation: Int64, label: String, questionID: String?, delay: TimeInterval) async -> PushSimulator.Result?
    /// Seeds the Demo laptop's "sending" Drop row (the Demo Drop fixture).
    func seedDropFixture(into drop: LiveDrop, workspace: ID16) async
}
