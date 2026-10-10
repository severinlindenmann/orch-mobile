import SwiftUI

/// Spaced monospaced code (SAS, cert code). Static: never animates (V5).
public struct CodeDisplay: View {
    public enum Frame: Sendable { case host, primary }
    private let code: String
    private let title: String
    private let frame: Frame
    private let identifier: String

    public init(code: String, title: String, frame: Frame, identifier: String) {
        self.code = code; self.title = title; self.frame = frame; self.identifier = identifier
    }

    public var body: some View {
        VStack(spacing: OS.s3) {
            Label(title, systemImage: frame == .primary ? "key.horizontal" : "laptopcomputer")
                .font(OF.section)
                .foregroundStyle(frame == .primary ? OC.info : OC.text)
                .multilineTextAlignment(.center)
            Text(code)
                .font(OF.code)
                .kerning(6)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(OC.text)
        }
        .padding(OS.s6)
        .frame(maxWidth: .infinity)
        .background(OC.surface, in: RoundedRectangle(cornerRadius: OR.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OR.card, style: .continuous)
                .strokeBorder(frame == .primary ? OC.info : OC.lineStrong, lineWidth: frame == .primary ? 3 : 1)
        )
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). Code \(code.filter { $0 != " " }.map(String.init).joined(separator: " ")).")
        .accessibilityIdentifier(identifier)
    }
}

public struct StatusChip: View {
    private let text: String
    private let systemImage: String
    private let color: Color
    public init(_ text: String, systemImage: String, color: Color) {
        self.text = text; self.systemImage = systemImage; self.color = color
    }
    public var body: some View {
        Label(text, systemImage: systemImage)
            .font(OF.meta)
            .foregroundStyle(color)
            .padding(.horizontal, OS.s3).padding(.vertical, OS.s1)
            .background(OC.soft(color), in: Capsule())
    }
}

/// Client-hosted marker. It has no dismiss affordance by design (D-6).
public struct HostedMarker: View {
    private let name: String?
    public init(hostedBy name: String?) { self.name = name }
    public var body: some View {
        Label(name.map { "Hosted by \($0)" } ?? "Hosted by (unknown)", systemImage: "building.2")
            .font(OF.meta)
            .foregroundStyle(OC.hosted)
            .padding(OS.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OC.soft(OC.hosted), in: RoundedRectangle(cornerRadius: OR.control, style: .continuous))
    }
}

public struct DemoChip: View {
    public init() {}
    public var body: some View {
        Label("Demo", systemImage: "theatermasks")
            .font(OF.meta).foregroundStyle(OC.demo)
            .padding(.horizontal, OS.s3).padding(.vertical, OS.s1)
            .background(OC.soft(OC.demo), in: Capsule())
            .accessibilityLabel("Demo mode")
    }
}

/// Thin violet stripe shown under the status bar on every screen in Demo.
public struct DemoStripe: View {
    public init() {}
    public var body: some View {
        Rectangle().fill(OC.demo).frame(height: 3).accessibilityHidden(true)
    }
}

public struct CardBackground: ViewModifier {
    public init() {}
    public func body(content: Content) -> some View {
        content.background(OC.surface, in: RoundedRectangle(cornerRadius: OR.card, style: .continuous))
    }
}

public extension View {
    func orchCard() -> some View { modifier(CardBackground()) }
}

/// Signed details (ws, question id, content hash): shown on the question and the sign sheet alike.
public struct SignedDetails: View {
    private let rows: [(String, String)]
    @State private var open = false
    public init(workspaceID: String, questionID: String, contentHash: String) {
        rows = [("Workspace", workspaceID), ("Question id", questionID), ("Content hash", contentHash)]
    }
    public var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: OS.s2) {
                ForEach(rows, id: \.0) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.0).font(OF.meta).foregroundStyle(OC.textMuted)
                        Text(verbatim: SafeText.inline(row.1, limit: 100)).font(OF.machine)
                    }
                    .accessibilityElement(children: .combine)
                }
            }.padding(.top, OS.s2)
        } label: {
            Text("Signed details").font(OF.section)
        }
        .accessibilityIdentifier("sign.details")
    }
}
