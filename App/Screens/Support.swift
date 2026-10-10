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
}

extension WorkspaceInfo {
    @MainActor var color: Color { OC.wsHues[hue % OC.wsHues.count] }
}

extension Question {
    var firstLine: String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        return SafeText.hasUnsafe(line) ? SafeText.pieces(line).map {
            switch $0 { case .text(let s): s; case .marker(let m): m }
        }.joined() : line
    }
}

/// A row of workspace identity: rail, name and hosted marker (repeated in the sign sheet).
struct WorkspaceHeader: View {
    let name: String
    let color: Color
    let hostedBy: String?
    var clientHosted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: OS.s2) {
            HStack(spacing: OS.s3) {
                WorkspaceRail(color: color).frame(height: 24).clipShape(Capsule())
                Text(name).font(OF.wsName)
            }
            if hostedBy != nil || clientHosted { HostedMarker(hostedBy: hostedBy) }
        }
        .accessibilityElement(children: .combine)
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

/// Finds an element by identifier regardless of its type; used by nothing at runtime.
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
