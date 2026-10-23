#if DEBUG
import Foundation
import Observation
import OrchClient
import OrchFakeHost

/// The hub home's model (design B2). It renders the coordinator's state and filters nothing in: what the user may see is the hub's decision.
/// The selection (switcher) only narrows what is already shown. Nothing here signs or can enable signing from a cached answer.
@MainActor @Observable
final class HubHomeModel {
    private(set) var state: HubHomeState = .notPaired
    /// `nil` is "All workspaces".
    var selected: String?
    private(set) var item: ItemState = .idle
    private(set) var loaded = false

    enum ItemState: Equatable { case idle, loading, detail(HubItemDetail), offline, failed(String), ended }

    @ObservationIgnored private let runtime: HubRuntime
    @ObservationIgnored private var task: Task<Void, Never>?

    init(runtime: HubRuntime = .shared) { self.runtime = runtime }

    var snapshot: HubSnapshot? {
        switch state {
        case .live(let s): s
        case .offline(let s): s
        default: nil
        }
    }

    var isLive: Bool { if case .live = state { true } else { false } }

    var selectedWorkspace: HubWorkspace? { snapshot?.workspaces.first { $0.id == selected } }

    /// The rows the list shows for the current selection.
    var rows: [HubNeedsYouRow] {
        guard let s = snapshot else { return [] }
        guard let sel = selected, s.workspaces.contains(where: { $0.id == sel }) else { return s.needsYou.rows }
        return s.rows(in: sel)
    }

    /// A sign button may be enabled only from a live answer, for an online workspace, when the hub hints it (the hub's prepare decides).
    func signEnabled(_ row: HubNeedsYouRow) -> Bool {
        guard isLive, !row.summaryOnly, let ws = snapshot?.workspaces.first(where: { $0.id == row.workspaceID }) else { return false }
        // a selective workspace has no list hint: the shared item's own `f1` decides (the item answer carries a decision only when it names one)
        return ws.online && (row.signable || (row.mode == .selective && row.kind != "needs_you"))
    }

    func open() async {
        if !loaded { state = await runtime.home.restore(); loaded = true }
        state = await runtime.home.refresh()
        if let sel = selected, snapshot?.workspaces.contains(where: { $0.id == sel }) != true { selected = nil }
    }

    func refresh() async { state = await runtime.home.refresh(); if snapshot?.workspaces.contains(where: { $0.id == selected }) != true { selected = nil } }

    func load(_ row: HubNeedsYouRow) async {
        item = .loading
        switch await runtime.home.item(workspaceID: row.workspaceID, itemID: row.itemID) {
        case .detail(let d): item = .detail(d)
        case .offline: item = .offline
        case .refused(let code): item = .failed(code)
        case .ended(let s): state = s; item = .ended
        }
    }

    /// Password and code go straight to the coordinator and are cleared by the caller; nothing is kept here.
    func signInAgain(password: String, totp: String) async { state = await runtime.home.signInAgain(password: password, totp: totp) }

    func clearItem() { item = .idle }
}
#endif
