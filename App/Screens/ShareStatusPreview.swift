#if DEBUG
import SwiftUI
import OrchShareStaging
import OrchUI

/// DEBUG-only (`--initial-route share-status/unreadable|none`): renders the share extension's unreadable / no-workspaces screens
/// (the same `ShareProblemView` source file the extension compiles) inside the extension's chrome, with sample Details lines. It exists
/// for the Dynamic Type and dark mode checks (owner e2e step 16); the real extension is driven by ShareExtensionTests.
struct ShareStatusPreview: View {
    let kind: ShareProblemView.Kind
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            ShareProblemView(kind: kind, reason: "index: unreadable", lines: Self.sampleLines)
                .navigationTitle("Share to orch")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") {}.accessibilityIdentifier("share.cancel") }
                    ToolbarItem(placement: .confirmationAction) { Button("Save to send") {}.disabled(true).accessibilityIdentifier("share.save") }
                }
        }
        .tint(OC.brand)
        .overlay(alignment: .topLeading) {
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement().accessibilityIdentifier("debug.scheme")
                .accessibilityValue(scheme == .dark ? "dark" : "light")
        }
    }

    static let sampleLines: [ShareDiagnostics.Line] = [
        .init("App Group", "group.io.severin.orch.share"),
        .init("Container", "resolvable"),
        .init("Container path form", "/private/… (device)"),
        .init("Share folder", "present, protection completeUntilFirstUserAuthentication"),
        .init("Path check", "ok"),
        .init("Index file", "present, 412 bytes, modified 2026-10-12 21:04:11, protection completeUntilFirstUserAuthentication"),
        .init("Last app publish", "2026-10-12 21:04:11: ok, 2 targets"),
        .init("Index decode", "failed: index: unreadable (version mismatch)"),
        .init("Tombstone lock", "free"),
        .init("Offered", "0 destinations")
    ]
}
#endif
