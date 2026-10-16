import SwiftUI
import OrchUI

// The Simulator dev-sandbox variant (host 11A.17.6): a red banner on every screen of a workspace and on the sign sheet, and the exact texts of
// the refusal and the footnote. The real views exist only in the OrchDevSandbox target (`ORCH_DEV_SANDBOX`); every other build gets no-ops,
// so no banner string or lane word is compiled into the TestFlight / App Store app.

extension View {
    /// Adds the banner above this screen while the workspace is on the dev-sandbox lane.
    @ViewBuilder
    func convenienceBanner(_ info: WorkspaceInfo?) -> some View {
        #if ORCH_DEV_SANDBOX
        self.safeAreaInset(edge: .top, spacing: 0) {
            if let info, info.devSandboxLane || info.devSandbox != nil || info.notADevSandbox {
                DevSandboxBanner(sandbox: info.devSandbox, warning: info.notADevSandbox)
            }
        }
        #else
        self
        #endif
    }
}

#if ORCH_DEV_SANDBOX
enum DevSandboxText {
    /// The banner, exactly. The id is the host's `whoami.relay.dev.sandbox` (eight hex digits), or a dash while no read carried it.
    static func banner(_ sandbox: String?) -> String { "DEV SANDBOX: convenience signing · \(sandbox ?? "—")" }
    static let hostRefuses = "This host does not accept Simulator answers"
    static let footnote = "Signed with this Simulator's software key (convenience, no presence check). Only this throwaway dev sandbox accepts it."
    static let notASandbox = "Not a dev sandbox. Remove this Simulator on your Mac."
}

struct DevSandboxBanner: View {
    let sandbox: String?
    var warning = false

    var body: some View {
        VStack(spacing: 2) {
            Text(verbatim: DevSandboxText.banner(sandbox))
                .font(OF.meta.weight(.bold))
                .accessibilityIdentifier("devsandbox.banner")
            if warning {
                Text(verbatim: DevSandboxText.notASandbox).font(OF.meta).accessibilityIdentifier("devsandbox.notSandbox")
            }
        }
        .foregroundStyle(Color.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, OS.s2).padding(.horizontal, OS.s3)
        .background(Color.red)
        .accessibilityElement(children: .combine)
    }
}
#endif
