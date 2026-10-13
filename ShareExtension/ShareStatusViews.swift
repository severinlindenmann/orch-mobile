import SwiftUI
import OrchUI
import OrchShareStaging

/// The share extension's "nothing to share to" screens, in their own file so the app's DEBUG `share-status` route renders
/// the very same views (the extension itself needs the system share sheet; decision T2 covers that end to end).
struct ShareProblemView: View {
    enum Kind { case noWorkspaces, unreadable }
    let kind: Kind
    let reason: String
    let lines: [ShareDiagnostics.Line]

    var body: some View {
        // One scroll view: at accessibility sizes the message and the expanded Details must both stay reachable.
        ScrollView {
            VStack(spacing: 12) {
                switch kind {
                case .noWorkspaces:
                    ShareStatusMessage(text: "Open orch and pair a workspace", detail: "Then share again. Nothing was saved.", id: "share.status.none")
                case .unreadable:
                    ShareStatusMessage(text: "orch can't read its workspaces", detail: "Open orch and try again. Nothing was saved.\n(\(reason))", id: "share.status.unreadable")
                }
                ShareDetailsDisclosure(lines: lines).padding(.horizontal)
            }
        }
    }
}

struct ShareStatusMessage: View {
    let text: String
    let detail: String?
    let id: String
    var body: some View {
        VStack(spacing: 8) {
            Text(text).font(.headline).multilineTextAlignment(.center).accessibilityIdentifier(id)
            if let detail { Text(detail).font(.subheadline).foregroundStyle(OC.textMuted).multilineTextAlignment(.center) }
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}

/// "Details" on the unreadable screen: the ShareDiagnostics lines (no paths, names or content), selectable for support.
struct ShareDetailsDisclosure: View {
    let lines: [ShareDiagnostics.Line]
    var body: some View {
        DisclosureGroup("Details") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines) { line in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: line.label).font(.caption).foregroundStyle(OC.textMuted)
                        Text(verbatim: line.value).font(.caption.monospaced())
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .accessibilityIdentifier("share.status.details")
    }
}
