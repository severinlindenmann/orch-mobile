import SwiftUI

/// Plain-text rendering for host-provided text (U7). Nothing is rewritten: unsafe scalars stay in the
/// text and are followed by a visible marker such as ⟨U+202E⟩. The marker delimiters U+27E8/U+27E9 are
/// themselves marked when they occur in host text, so a literal "⟨U+202E⟩" can never imitate a marker.
public enum SafeText {
    public enum Piece: Equatable, Sendable {
        case text(String)
        case marker(String)
    }

    /// `previous` is the scalar directly before (for emoji variation selectors).
    public static func isUnsafe(_ scalar: Unicode.Scalar, after previous: Unicode.Scalar? = nil) -> Bool {
        let v = scalar.value
        if v == 0x0A { return false }
        if v == 0x27E8 || v == 0x27E9 { return true }            // marker delimiters
        if (0xFE00...0xFE0D).contains(v) || (0x180B...0x180F).contains(v) || (0xE0100...0xE01EF).contains(v) {
            return true
        }
        if v == 0xFE0E || v == 0xFE0F {                          // text/emoji presentation: only after an emoji base
            if let p = previous, p.value > 0x7F, p.properties.isEmoji { return false }
            return true
        }
        if v == 0xFFFC { return true }
        switch v {
        case 0x3164, 0x2800, 0x115F, 0x1160, 0x17B4, 0x17B5, 0xFFA0, 0x034F: return true
        default: break
        }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate:
            return true
        case .spaceSeparator:
            return v != 0x20
        default:
            return false
        }
    }

    public static func markerLabel(for scalar: Unicode.Scalar) -> String {
        let hex = String(scalar.value, radix: 16, uppercase: true)
        return "⟨U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex + "⟩"
    }

    private static func isMark(_ s: Unicode.Scalar) -> Bool {
        if (0xFE00...0xFE0F).contains(s.value) { return false }
        switch s.properties.generalCategory {
        case .nonspacingMark, .enclosingMark: return true
        default: return false
        }
    }

    public static func pieces(_ input: String) -> [Piece] {
        var result: [Piece] = []
        var buffer = String.UnicodeScalarView()
        func flush() {
            if !buffer.isEmpty { result.append(.text(String(buffer))); buffer = .init() }
        }
        var previous: Unicode.Scalar?
        for character in input {
            let scalars = Array(character.unicodeScalars)
            let marks = scalars.filter(isMark).count
            let zalgo = marks > 3
            for scalar in scalars {
                if zalgo && isMark(scalar) { continue }
                if isUnsafe(scalar, after: previous) {
                    flush()
                    result.append(.marker(markerLabel(for: scalar)))
                } else {
                    buffer.append(scalar)
                }
                previous = scalar
            }
            if zalgo {
                flush()
                result.append(.marker("⟨\(marks) marks⟩"))
            }
        }
        flush()
        return result
    }

    public static func markers(in input: String) -> [String] {
        pieces(input).compactMap { if case .marker(let m) = $0 { return m } else { return nil } }
    }

    public static func hasUnsafe(_ input: String) -> Bool { !markers(in: input).isEmpty }

    /// Single-line variant for host-supplied metadata: markers become text, newlines spaces, length is capped.
    public static func inline(_ input: String, limit: Int = 80) -> String {
        var out = pieces(input.replacingOccurrences(of: "\n", with: " ")).map { piece -> String in
            switch piece { case .text(let t): t; case .marker(let m): m }
        }.joined()
        if out.count > limit { out = String(out.prefix(limit)) + "…" }
        return out
    }

    /// Short label for pairing screens. Digit runs of 3+ are neutralised (they could pass for a code);
    /// with `allowDigits == false` (alarm screens) no digit survives.
    public static func label(_ input: String, limit: Int = 24, allowDigits: Bool = true) -> String {
        let marked = inline(input, limit: 200)
        var out = ""
        var run = ""
        var digits = 0
        func flush() {
            if digits >= 3 || (!allowDigits && digits > 0) { out += "…" } else { out += run }
            run = ""; digits = 0
        }
        for c in marked {
            if c.isNumber { run.append(c); digits += 1 }
            else if digits > 0 && (c == " " || c == "-" || c == ".") { run.append(c) }
            else { flush(); out.append(c) }
        }
        flush()
        out = out.trimmingCharacters(in: .whitespaces)
        if out.count > limit { out = String(out.prefix(limit)) + "…" }
        return out
    }

    private static let confusables: [Character: Character] = {
        var m: [Character: Character] = [:]
        let pairs: [(String, String)] = [
            ("АВЕКМНОРСТХаеорсухі", "ABEKMHOPCTXaeopcuxi"),     // Cyrillic
            ("ΑΒΕΖΗΙΚΜΝΟΡΤΥΧο", "ABEZHIKMNOPTYXo"),           // Greek
        ]
        for (from, to) in pairs { for (f, t) in zip(from, to) { m[f] = t } }
        return m
    }()

    /// Reduces common Cyrillic/Greek look-alikes to Latin so "Approve" and "Аpprove" collide.
    public static func skeleton(_ input: String) -> String {
        String(inline(input, limit: 400).trimmingCharacters(in: .whitespaces).map { confusables[$0] ?? $0 })
    }

    /// Two answers whose skeletons are equal cannot be told apart by the reader: refuse.
    public static func hasAmbiguousOptions(_ labels: [String]) -> Bool {
        let skeletons = labels.map(skeleton)
        return Set(skeletons).count != skeletons.count || skeletons.contains { $0.isEmpty }
    }

    public enum Style: Sendable { case signing, prose }

    @MainActor
    public static func attributed(_ input: String, style: Style = .signing) -> AttributedString {
        let font: Font = style == .signing ? OF.machine : OF.body
        var out = AttributedString()
        // FSI ... PDI keeps an unterminated bidi override from reordering the rest of the screen.
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

    public static func spoken(_ input: String) -> String {
        pieces(input).map {
            switch $0 {
            case .text(let s): return s
            case .marker(let m): return " unsafe character " + m + " "
            }
        }.joined()
    }
}

/// The one text renderer for host-supplied text. Never Markdown, never links, clipped to its frame.
public struct SafeTextView: View {
    private let text: String
    private let style: SafeText.Style
    public init(_ text: String, style: SafeText.Style = .signing) { self.text = text; self.style = style }

    public var body: some View {
        Text(SafeText.attributed(text, style: style))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .clipped()
            .textSelection(.disabled)
            .accessibilityLabel(SafeText.spoken(text))
    }
}
