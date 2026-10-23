import Foundation

/// How a channel shows a string that comes from a workspace (orch-hub protocol 8.4 step 3, L2P4-2d; vectors `render_*`): every scalar the
/// text rule refuses, other than LF, is shown escaped as `<U+XXXX>`, so an agent-written title cannot hide or reorder what the person
/// reads. The hub already does this to everything it sends; the phone does it again (defence in depth, design B2) and then shows the
/// result through `SafeText`. Idempotent: the escape sequence is plain ASCII.
public enum HubText {
    private static let ignorable: [ClosedRange<UInt32>] = [
        0x00AD...0x00AD, 0x034F...0x034F, 0x061C...0x061C, 0x115F...0x1160, 0x17B4...0x17B5, 0x180B...0x180F, 0x200B...0x200F,
        0x202A...0x202E, 0x2060...0x206F, 0x3164...0x3164, 0xFE00...0xFE0F, 0xFEFF...0xFEFF, 0xFFA0...0xFFA0, 0xFFF0...0xFFF8,
        0x1BCA0...0x1BCA3, 0x1D173...0x1D17A, 0xE0000...0xE0FFF,
    ]

    private static func allowed(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: return false
        default: break
        }
        return !ignorable.contains { $0.contains(u.value) }
    }

    public static func render(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if u == "\n" || allowed(u) { out.append(u); continue }
            let hex = String(u.value, radix: 16, uppercase: true)
            out.append(contentsOf: ("<U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex + ">").unicodeScalars)
        }
        return String(out)
    }
}
