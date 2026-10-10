import SwiftUI

/// Plain-text rendering for host-provided text (U7). Nothing is rewritten: unsafe scalars stay in the
/// text and are followed by a visible marker such as ⟨U+202E⟩, so the reader sees exactly what is signed.
public enum SafeText {
    public enum Piece: Equatable, Sendable {
        case text(String)
        case marker(String)
    }

    /// True for scalars that render invisibly or change layout direction.
    public static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" { return false }
        switch scalar.value {
        case 0x3164, 0x2800, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180E, 0xFFA0, 0x034F: return true
        default: break
        }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate:
            return true
        default:
            return false
        }
    }

    public static func markerLabel(for scalar: Unicode.Scalar) -> String {
        let hex = String(scalar.value, radix: 16, uppercase: true)
        return "⟨U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex + "⟩"
    }

    public static func pieces(_ input: String) -> [Piece] {
        var result: [Piece] = []
        var buffer = String.UnicodeScalarView()
        func flush() {
            if !buffer.isEmpty { result.append(.text(String(buffer))); buffer = .init() }
        }
        for scalar in input.unicodeScalars {
            if isUnsafe(scalar) {
                flush()
                result.append(.marker(markerLabel(for: scalar)))
            } else {
                buffer.append(scalar)
            }
        }
        flush()
        return result
    }

    public static func markers(in input: String) -> [String] {
        pieces(input).compactMap { if case .marker(let m) = $0 { return m } else { return nil } }
    }

    /// Single-line variant for host-supplied metadata (ticket keys, device labels): unsafe scalars are
    /// replaced by their marker text, newlines become spaces and length is capped.
    public static func inline(_ input: String, limit: Int = 80) -> String {
        var out = pieces(input.replacingOccurrences(of: "\n", with: " ")).map { piece -> String in
            switch piece { case .text(let t): t; case .marker(let m): m }
        }.joined()
        if out.count > limit { out = String(out.prefix(limit)) + "…" }
        return out
    }

    public static func hasUnsafe(_ input: String) -> Bool { !markers(in: input).isEmpty }

    /// Unsafe scalars are kept in the text (so bidi still applies visibly) and marked right after.
    /// The marker chip is isolated with LRI/PDI so a RLO cannot reorder the marker itself.
    @MainActor
    public static func attributed(_ input: String, font: Font = OF.machine) -> AttributedString {
        var out = AttributedString()
        // FSI ... PDI keeps any unterminated bidi override from reordering the rest of the screen.
        out += AttributedString("\u{2068}")
        for piece in pieces(input) {
            switch piece {
            case .text(let s):
                var part = AttributedString(s)
                part.font = font
                part.foregroundColor = OC.text
                out += part
            case .marker(let m):
                var part = AttributedString("\u{2066}" + m + "\u{2069}")
                part.font = font.bold()
                part.foregroundColor = OC.warn
                part.backgroundColor = OC.soft(OC.warn)
                out += part
            }
        }
        out += AttributedString("\u{2069}")
        return out
    }
}

/// The one text renderer for question text, shared by the question view and the sign sheet.
public struct SafeTextView: View {
    private let text: String
    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(SafeText.attributed(text))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.disabled)
            .accessibilityLabel(spoken)
    }

    private var spoken: String {
        SafeText.pieces(text).map {
            switch $0 {
            case .text(let s): return s
            case .marker(let m): return " unsafe character " + m + " "
            }
        }.joined()
    }
}
