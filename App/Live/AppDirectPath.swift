import Foundation
import OrchClient

/// B8: the app's ONE direct-path flag (persisted in UserDefaults) and the notice the UI observes. `flag` goes to `PairingConfig.directPath`
/// and the Live `RoutedRelayTransport`; `onSwitchedOff` makes a mid-session cut-over show "This workspace now uses your hub".
@MainActor
final class AppDirectPath: ObservableObject {
    nonisolated static let flag = DirectPathFlag(store: UserDefaultsDirectPathStore())
    static let shared = AppDirectPath()

    @Published private(set) var closed: Set<String>

    private init() {
        closed = Self.flag.closedWorkspaces
        Self.flag.onSwitchedOff { [weak self] ws in Task { @MainActor in self?.closed.insert(ws) } }
    }

    func usesHub(_ workspaceID: String) -> Bool { closed.contains(workspaceID.lowercased()) }

    /// "Use direct connection again".
    func reenable(_ workspaceID: String) {
        Self.flag.reenable(workspace: workspaceID)
        closed = Self.flag.closedWorkspaces
    }
}
