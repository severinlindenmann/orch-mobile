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
                .strokeBorder(frame == .primary ? OC.info : OC.brand, lineWidth: frame == .primary ? 3 : 2)
        )
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(title). Code \(code.filter { $0 != " " }.map(String.init).joined(separator: " "))."))
        .accessibilityIdentifier(identifier)
    }
}

/// Capsule for one-line chips; a rounded rectangle at accessibility sizes, where the label wraps and a capsule's ends cut through the text.
private struct ChipBackground: ViewModifier {
    let fill: Color
    @Environment(\.dynamicTypeSize) private var typeSize
    func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize {
            content.background(fill, in: RoundedRectangle(cornerRadius: OR.control, style: .continuous))
        } else {
            content.background(fill, in: Capsule())
        }
    }
}

private extension View {
    func chipBackground(_ fill: Color) -> some View { modifier(ChipBackground(fill: fill)) }
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
            .labelStyle(.titleAndIcon)           // a List row would otherwise be free to pick icon-only
            .font(OF.meta)
            .foregroundStyle(color)
            .lineLimit(2)
            .padding(.horizontal, OS.s3).padding(.vertical, OS.s1)
            .chipBackground(OC.soft(color))
            .fixedSize(horizontal: false, vertical: true)   // natural height inside list rows and stacks
    }
}

/// Client-hosted marker: the addon-orange chip (icon plus words). It has no dismiss affordance by design (D-6).
public struct HostedMarker: View {
    private let name: String?
    public init(hostedBy name: String?) { self.name = name }
    public var body: some View {
        Label { Text(verbatim: name.map { "Hosted by \(SafeText.inline($0, limit: 40))" } ?? "Hosted by (unknown)") }
            icon: { Image(systemName: "building.2") }
            .font(OF.meta)
            .foregroundStyle(OC.hosted)
            .padding(.horizontal, OS.s3).padding(.vertical, OS.s1 + 1)
            .chipBackground(OC.soft(OC.hosted))
            .fixedSize(horizontal: false, vertical: true)
    }
}

public struct DemoChip: View {
    private let compact: Bool
    /// `compact`: the single-word "Demo" badge for tight headers (the explanation lives in the simulation notice below).
    public init(compact: Bool = false) { self.compact = compact }
    public var body: some View {
        Label(compact ? "Demo" : "Demo · simulated", systemImage: "theatermasks")
            .font(OF.meta).foregroundStyle(OC.demo)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)   // never wider than its container at AX sizes
            .padding(.horizontal, OS.s3).padding(.vertical, OS.s1)
            .chipBackground(OC.soft(OC.demo))
            .accessibilityLabel("Demo mode, simulated")
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
        content
            .background(OC.surface, in: RoundedRectangle(cornerRadius: OR.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: OR.card, style: .continuous).strokeBorder(OC.line, lineWidth: 1))
    }
}

public extension View {
    func orchCard() -> some View { modifier(CardBackground()) }
}

/// Signed details (ws, question id, content hash): shown on the question and the sign sheet alike.
public struct SignedDetails: View {
    private let rows: [(String, String)]
    @State private var open = false
    public init(workspaceID: String, questionID: String, optionID: String? = nil, contentHash: String) {
        var r = [("Workspace", workspaceID), ("Question id", questionID)]
        if let optionID { r.append(("Answer id", optionID)) }
        r.append(("Content hash", contentHash))
        rows = r
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

/// Prominent action with explicit on-colour text (contrast), used instead of `.borderedProminent`. 48 pt tall, full width.
public struct OrchProminentButtonStyle: ButtonStyle {
    private let tint: Color?
    private let foreground: Color?
    @Environment(\.isEnabled) private var enabled
    public init(tint: Color? = nil, foreground: Color? = nil) { self.tint = tint; self.foreground = foreground }
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(foreground ?? OC.onBrand)
            .padding(.vertical, OS.s3).padding(.horizontal, OS.s4)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background((tint ?? OC.brand).opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// Soft secondary action: tinted fill, 44 pt minimum, used for "Stop sending", "They are different", "Remind me later".
public struct OrchSoftButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case neutral, danger, brand }
    private let kind: Kind
    @Environment(\.isEnabled) private var enabled
    public init(_ kind: Kind = .neutral) { self.kind = kind }
    public func makeBody(configuration: Configuration) -> some View {
        let (fg, bg): (Color, Color) = switch kind {
        case .neutral: (OC.text, OC.surface2)
        case .danger: (OC.danger, OC.soft(OC.danger))
        case .brand: (OC.brand, OC.soft(OC.brand))
        }
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(fg)
            .padding(.vertical, OS.s3).padding(.horizontal, OS.s4)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}

public extension ButtonStyle where Self == OrchProminentButtonStyle {
    static var orchProminent: OrchProminentButtonStyle { OrchProminentButtonStyle() }
    static var orchDanger: OrchProminentButtonStyle { OrchProminentButtonStyle(tint: OC.danger, foreground: OC.onDanger) }
}

public extension ButtonStyle where Self == OrchSoftButtonStyle {
    static var orchSoft: OrchSoftButtonStyle { OrchSoftButtonStyle(.neutral) }
    static var orchSoftDanger: OrchSoftButtonStyle { OrchSoftButtonStyle(.danger) }
    static var orchSoftBrand: OrchSoftButtonStyle { OrchSoftButtonStyle(.brand) }
}

/// Answer option: outlined card so host text keeps normal text contrast.
public struct OrchOptionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(OS.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 48)
            .background(OC.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(OC.lineStrong, lineWidth: 1.5))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.5)
    }
}

/// Always-visible honesty line: these screens are not yet wired to a real workspace.
public struct SimulationNotice: View {
    public init() {}
    public var body: some View {
        Label("Demo — simulated workspace. The protocol is real; the Mac is not.", systemImage: "info.circle")
            .font(OF.meta).foregroundStyle(OC.textMuted)
            .accessibilityIdentifier("simulation.notice")
    }
}
