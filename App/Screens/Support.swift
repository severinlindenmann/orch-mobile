import SwiftUI
import OrchUI

enum Fmt {
    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
    static func bytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
    static func plural(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
}

extension WorkspaceInfo {
    @MainActor var color: Color { OC.wsHues[hue % OC.wsHues.count] }

    /// D10: why answering is off for this workspace, nil when allowed.
    var answerBlock: String? {
        if !scopes.contains(.decide) { return "This iPhone may not answer for this workspace." }
        switch connection {
        case .online: return nil
        case .offline: return "Saved copy · answers are off until you're back."
        case .reconciling: return "Reconnecting · answers are off until the workspace is checked."
        }
    }
    var isLive: Bool { if case .online = connection { true } else { false } }
}

extension Question {
    /// First line, single-line, unsafe characters as visible markers (host text, so never raw).
    var firstLine: String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        return SafeText.inline(line, limit: 100)
    }
    var displayTicket: String { SafeText.inline(ticket, limit: 24) }
}

extension Ticket {
    var displayKey: String { SafeText.inline(key, limit: 24) }
    var displayTitle: String { SafeText.inline(title, limit: 120) }
}

extension DropItem {
    var displayName: String { SafeText.inline(name, limit: 60) }
    var displayFrom: String { SafeText.inline(from, limit: 30) }
}

/// Horizontal at normal sizes, vertical (leading) at accessibility sizes so nothing is truncated or split.
struct AdaptiveStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder let content: Content
    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: OS.s2) { content }
        } else {
            HStack { content }
        }
    }
}

/// Compact identity row: rail, name and (when hosted) the hosted warning. Names come from the workspace
/// record, never from question text.
struct WorkspaceHeader: View {
    let name: String
    let color: Color
    let hostedBy: String?
    var clientHosted: Bool = false

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let hosted = clientHosted || hostedBy != nil
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: OS.s2) {
                nameRow
                if hosted { HostedMarker(hostedBy: hostedBy) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("workspace.header")
        } else {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: OS.s3) {
                nameRow
                if hosted { HostedMarker(hostedBy: hostedBy).fixedSize() }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: OS.s2) {
                nameRow
                if hosted { HostedMarker(hostedBy: hostedBy) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: SafeText.inline(name, limit: 40)
                                 + (hosted ? ", " + (hostedBy.map { "hosted by " + SafeText.inline($0, limit: 40) } ?? "hosted by unknown") : "")))
        .accessibilityIdentifier("workspace.header")
        }
    }

    private var nameRow: some View {
        HStack(spacing: OS.s2) {
            WorkspaceRail(color: color).frame(height: 22).clipShape(Capsule())
            Text(verbatim: SafeText.inline(name, limit: 40)).font(OF.wsName).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ConnectionChip: View {
    let state: ConnectionState
    var body: some View {
        switch state {
        case .online: StatusChip("Live", systemImage: "circle.fill", color: OC.ok)
        case .offline(let since): StatusChip("Offline as of \(Fmt.time(since))", systemImage: "wifi.slash", color: OC.textMuted)
        case .reconciling: StatusChip("Reconnecting", systemImage: "arrow.triangle.2.circlepath", color: OC.warn)
        }
    }
}

struct EmptyState: View {
    let systemImage: String
    let title: String
    var detail: String?
    var body: some View {
        VStack(spacing: OS.s2) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(OC.textMuted)
            Text(title).font(OF.section)
            if let detail { Text(detail).font(OF.body).foregroundStyle(OC.textMuted).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity)
        .padding(OS.s6)
        .accessibilityElement(children: .combine)
    }
}
