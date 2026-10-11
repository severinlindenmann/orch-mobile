import Foundation

/// Look-alike detection for host text on signing surfaces, after Unicode TS #39 (security mechanisms).
///
/// **Partial by design.** No ICU or confusables.txt is bundled: `prototype` is a compact hand-picked subset of
/// confusables.txt covering the scripts that imitate Latin best (Cyrillic, Greek, Armenian, Cherokee, Lisu, a few
/// Latin-extended letters) plus look-alike punctuation; NFKD covers full-width, mathematical and other
/// compatibility forms. Two consequences are deliberate and fail closed:
/// - option sets whose skeletons collide are refused, even where the full table would not collide;
/// - any letter outside Latin in a word that also has Latin letters is marked, whether or not it is in the table.
enum Confusables {
    enum Script: Hashable {
        case latin, greek, cyrillic, armenian, cherokee, lisu, cjk, other

        var name: String {
            switch self {
            case .latin: "Latin"
            case .greek: "Greek"
            case .cyrillic: "Cyrillic"
            case .armenian: "Armenian"
            case .cherokee: "Cherokee"
            case .lisu: "Lisu"
            case .cjk: "CJK"
            case .other: "other script"
            }
        }
    }

    /// Coarse script of a letter; nil for anything that is not a letter (digits, marks, punctuation, modifier symbols).
    static func script(_ s: Unicode.Scalar) -> Script? {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: break
        default: return nil
        }
        let v = s.value
        switch v {
        case 0x41...0x5A, 0x61...0x7A, 0xAA, 0xBA, 0xC0...0x24F, 0x250...0x2AF, 0x1D00...0x1DBF, 0x1E00...0x1EFF,
             0x2C60...0x2C7F, 0xA720...0xA7FF, 0xAB30...0xAB6F, 0xFB00...0xFB06, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
            return .latin
        case 0x2B0...0x2FF: return nil                     // spacing modifier letters: handled as punctuation/compat
        case 0x370...0x3FF, 0x1F00...0x1FFF: return .greek
        case 0x400...0x52F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F: return .cyrillic
        case 0x530...0x58F, 0xFB13...0xFB17: return .armenian
        case 0x13A0...0x13FF, 0xAB70...0xABBF: return .cherokee
        case 0xA4D0...0xA4FF: return .lisu
        case 0x1100...0x11FF, 0x2E80...0x2FDF, 0x3040...0x30FF, 0x3100...0x318F, 0x31A0...0x31FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF66...0xFF9F, 0x20000...0x3FFFF:
            return .cjk
        default: return .other
        }
    }

    /// Non-ASCII scalar → the ASCII it imitates (subset of UTS #39 confusables.txt).
    static let prototype: [UInt32: String] = {
        var m: [UInt32: String] = [:]
        func add(_ from: String, _ to: String) {
            for (f, t) in zip(from.unicodeScalars, to.unicodeScalars) { m[f.value] = String(t) }
        }
        // Cyrillic
        add("АВЕКМНОРСТХЅІЈԚԜҮӀԌЗЬ", "ABEKMHOPCTXSIJQWYlG3b")
        add("аеорсухѕіјһԁԛԝӏүҽ", "aeopcyxsijhdqwlye")
        // Greek
        add("ΑΒΕΖΗΙΚΜΝΟΡΤΥΧϹͿϒ", "ABEZHIKMNOPTYXCJY")
        add("οανιρυγϲϳ", "oavipuycj")
        // Armenian
        add("ՕՍՏԼ", "OUSL")
        add("օսցհոզ", "oughnq")
        // Cherokee
        add("ᎪᏴᏟᎬᏀᎻᎫᏦᏞᎷᏢᏚᏔᏙᏃᎠᎡᎢ", "ABCEGHJKLMPSWVZDRT")
        // Lisu
        add("ꓮꓐꓚꓓꓰꓝꓖꓧꓲꓙꓗꓡꓟꓠꓳꓑꓣꓢꓔꓴꓦꓪꓫꓬꓜ", "ABCDEFGHIJKLMNOPRSTUVWXYZ")
        // Latin-extended look-alikes
        add("ıɑɡǀǃɩ", "iaglli")
        m[0x01C3] = "!"
        // Punctuation and symbols
        add("\u{201A}\u{037E}\u{0387}\u{0589}\u{05C3}\u{2236}\u{A789}\u{02F8}\u{2024}\u{2044}\u{2215}\u{2216}\u{2223}\u{05C0}\u{2212}\u{2010}\u{2011}\u{2012}\u{02D7}\u{02BC}\u{2032}\u{A78C}\u{02C8}\u{02B9}", ",;.:::::.//\\ll-----'''''")
        m[0x2033] = "\""
        return m
    }()

    /// Punctuation and symbols that imitate ASCII punctuation; always marked, wherever they occur.
    private static let lookalikePunctuation: Set<UInt32> = [
        0x201A, 0x037E, 0x0387, 0x0589, 0x05C3, 0x2236, 0xA789, 0x02F8, 0x2024, 0x2027, 0x2044, 0x2215, 0x2216, 0x2223,
        0x05C0, 0x2212, 0x2010, 0x2011, 0x2012, 0x02D7, 0x02BC, 0x2032, 0xA78C, 0x02C8, 0x02B9, 0x2033, 0x01C3, 0xFF0E,
        0x0589, 0x0703, 0x0704, 0x16EB, 0x2E31, 0x30FB,
    ]

    static func markerLabel(_ kind: String, _ s: Unicode.Scalar) -> String {
        let hex = String(s.value, radix: 16, uppercase: true)
        return "⟨" + kind + " U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex + "⟩"
    }

    private static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    private static func isASCIIAlnum(_ s: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(s.value) || (0x41...0x5A).contains(s.value) || (0x61...0x7A).contains(s.value)
    }

    /// Marked wherever it occurs: non-ASCII digits, look-alike punctuation, compatibility forms of letters/digits.
    private static func alwaysFlag(_ s: Unicode.Scalar) -> String? {
        let v = s.value
        if v < 0x80 { return nil }
        if s.properties.generalCategory == .decimalNumber { return markerLabel("digit", s) }
        if lookalikePunctuation.contains(v) { return markerLabel("look-alike", s) }
        let str = String(s)
        let k = str.precomposedStringWithCompatibilityMapping
        if k != str.precomposedStringWithCanonicalMapping, k.unicodeScalars.contains(where: isASCIIAlnum) {
            return markerLabel("look-alike", s)
        }
        return nil
    }

    /// Scalar offset → marker for every scalar a reader could take for something else.
    static func flags(_ scalars: [Unicode.Scalar]) -> [Int: String] {
        var out: [Int: String] = [:]
        var i = 0
        while i < scalars.count {
            guard isWordScalar(scalars[i]) else {
                if let m = alwaysFlag(scalars[i]) { out[i] = m }
                i += 1
                continue
            }
            var j = i
            while j < scalars.count, isWordScalar(scalars[j]) { j += 1 }
            flagWord(scalars, i..<j, into: &out)
            i = j
        }
        return out
    }

    private static func flagWord(_ scalars: [Unicode.Scalar], _ range: Range<Int>, into out: inout [Int: String]) {
        var letters: [(Int, Script)] = []
        for k in range {
            if let m = alwaysFlag(scalars[k]) { out[k] = m; continue }
            if let sc = script(scalars[k]) { letters.append((k, sc)) }
        }
        guard !letters.isEmpty else { return }
        let scripts = Set(letters.map(\.1))
        let nonCJK = scripts.subtracting([.cjk])
        let mixed = nonCJK.count > 1 || (scripts.contains(.cjk) && !nonCJK.isEmpty && !nonCJK.contains(.latin))
        if mixed {
            // Mixed-script word ("аpprove", "orch-аpp" is two words but "аpp" alone is caught below): mark the intruders.
            let dominant: Script = scripts.contains(.latin) ? .latin : letters[0].1
            for (k, sc) in letters where sc != dominant && sc != .cjk {
                out[k] = markerLabel(sc.name, scalars[k])
            }
        } else if !scripts.contains(.latin), !scripts.contains(.cjk),
                  letters.allSatisfy({ prototype[scalars[$0.0].value] != nil }) {
            // Whole-word look-alike: every letter of a non-Latin word imitates Latin ("аррӏе").
            for (k, sc) in letters { out[k] = markerLabel(sc.name, scalars[k]) }
        } else {
            for (k, sc) in letters where sc == .latin && scalars[k].value > 0x7F && prototype[scalars[k].value] != nil {
                out[k] = markerLabel("look-alike", scalars[k])
            }
        }
    }

    /// UTS #39 skeleton of plain text: NFKD, map each scalar to its prototype, fold the ASCII look-alikes
    /// (I/1/| → l, 0 → O, m → rn), NFD. Equal skeletons read the same.
    static func skeleton(_ text: String) -> String {
        var out = ""
        for s in text.decomposedStringWithCompatibilityMapping.unicodeScalars {
            if let p = prototype[s.value] { out += p; continue }
            switch s.value {
            case 0x49, 0x31, 0x7C: out += "l"
            case 0x30: out += "O"
            case 0x6D: out += "rn"
            default: out.unicodeScalars.append(s)
            }
        }
        return out.decomposedStringWithCanonicalMapping
    }
}
