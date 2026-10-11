import Foundation

/// Look-alike detection for host text on signing surfaces, after Unicode TS #39 (security mechanisms).
/// Source: `prototype` is derived from Unicode confusables.txt (UTS #39), Unicode License v3 — a hand-picked subset plus a
/// few own additions (к, κ, CJK ㅣ 一 ロ); no code from other implementations.
///
/// **Partial.** No ICU or confusables.txt is bundled: `prototype` is a compact hand-picked subset of confusables.txt
/// (Cyrillic, Greek, Armenian, Cherokee, Lisu, Coptic, Hebrew, a few Latin-extended and CJK letters, look-alike punctuation);
/// NFKD covers full-width, mathematical and other compatibility forms. The table misses most of confusables.txt, so it is
/// never the only line of defence:
/// - option labels (what the user taps and signs) fail closed on a per-scalar allowlist instead (`SafeText.optionRefusal`):
///   printable ASCII and precomposed Latin-1 letters only; localised (non-Latin) answer sets are refused for now (gaps.md);
/// - option sets whose skeletons collide are refused as well;
/// - question prose is informational and must stay readable, so it is marked, not refused: the heuristics in `flags`
///   can miss look-alikes the table does not know (they are best effort, not fail closed).
enum Confusables {
    enum Script: Hashable {
        case latin, smallCapital, letterlike, greek, coptic, cyrillic, armenian, cherokee, lisu, cjk, other

        var name: String {
            switch self {
            case .latin: "Latin"
            case .smallCapital: "small capital"
            case .letterlike: "letterlike"
            case .coptic: "Coptic"
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
        case 0x250...0x2AF, 0x1D00...0x1D2B: return .smallCapital   // IPA and small capitals: Latin, but imitate it
        case 0x41...0x5A, 0x61...0x7A, 0xAA, 0xBA, 0xC0...0x24F, 0x1D2C...0x1DBF, 0x1E00...0x1EFF,
             0x2C60...0x2C7F, 0xA720...0xA7FF, 0xAB30...0xAB6F, 0xFB00...0xFB06, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
            return .latin
        case 0x2B0...0x2FF: return nil                     // spacing modifier letters: handled as punctuation/compat
        case 0x2C80...0x2CFF: return .coptic
        case 0x370...0x3FF, 0x1F00...0x1FFF: return .greek
        case 0x400...0x52F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F: return .cyrillic
        case 0x530...0x58F, 0xFB13...0xFB17: return .armenian
        case 0x13A0...0x13FF, 0xAB70...0xABBF: return .cherokee
        case 0xA4D0...0xA4FF: return .lisu
        case 0x212A, 0x2126: return .letterlike             // Kelvin K, Ohm Ω: canonically K and Ω, so NFC hides them
        case 0x1100...0x11FF, 0xA960...0xA97F, 0xD7B0...0xD7FF, 0x2E80...0x2FDF, 0x3040...0x30FF, 0x3100...0x318F, 0x31A0...0x31FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF66...0xFF9F, 0x20000...0x3FFFF:
            return .cjk
        default: return .other
        }
    }

    /// Non-ASCII scalar → the ASCII it imitates (subset of UTS #39 confusables.txt).
    static let prototype: [UInt32: String] = {
        var m: [UInt32: String] = [:]
        func add(_ from: String, _ to: String) {
            precondition(from.unicodeScalars.count == to.unicodeScalars.count, "prototype table: unequal lengths")
            for (f, t) in zip(from.unicodeScalars, to.unicodeScalars) { m[f.value] = String(t) }
        }
        // Cyrillic
        add("АВЕКМНОРСТХЅІЈԚԜҮӀԌЗЬ", "ABEKMHOPCTXSIJQWYlG3b")
        add("аеорсухѕіјһԁԛԝӏүҽк", "aeopcyxsijhdqwlyek")
        // Greek
        add("ΑΒΕΖΗΙΚΜΝΟΡΤΥΧϹͿϒ", "ABEZHIKMNOPTYXCJY")
        add("οανιρυγϲϳκ", "oavipuycjk")
        // Armenian
        add("ՕՍՏԼ", "OUSL")
        add("օսցհոզ", "oughnq")
        // Cherokee
        add("ᎪᏴᏟᎬᏀᎻᎫᏦᏞᎷᏢᏚᏔᏙᏃᎠᎡᎢ", "ABCEGHJKLMPSWVZDRT")
        // Lisu
        add("ꓮꓐꓚꓓꓰꓝꓖꓧꓲꓙꓗꓡꓟꓠꓳꓑꓣꓢꓔꓴꓦꓪꓫꓬꓜ", "ABCDEFGHIJKLMNOPRSTUVWXYZ")
        // Latin-extended look-alikes
        add("ıɑɡǀɩ", "iagli")
        m[0x01C3] = "!"
        m[0x212A] = "K"
        // Stroked Latin-1 letters (allowed in labels) that read as their base letter: skeleton only.
        m[0x00D8] = "O"; m[0x00F8] = "o"; m[0x00D0] = "D"
        // Punctuation and symbols
        add("\u{201A}\u{037E}\u{0387}\u{0589}\u{05C3}\u{2236}\u{A789}\u{02F8}\u{2024}\u{2044}\u{2215}\u{2216}\u{2223}\u{05C0}\u{2212}\u{2010}\u{2011}\u{2012}\u{02D7}\u{02BC}\u{2032}\u{A78C}\u{02C8}\u{02B9}", ",;.:::::.//\\ll-----'''''")
        m[0x2033] = "\""
        // Coptic
        add("\u{2C80}\u{2C82}\u{2C8E}\u{2C92}\u{2C94}\u{2C98}\u{2C9A}\u{2C9E}\u{2CA2}\u{2CA4}\u{2CA6}\u{2CA8}\u{2CAC}",
            "ABHIKMNOPCTYX")
        add("\u{2C9F}\u{2CA3}\u{2CA5}", "opc")
        // Hebrew, CJK
        add("\u{05D5}\u{05DF}\u{05E1}", "llo")
        add("\u{3163}\u{1175}\u{30CE}\u{30CB}\u{4E00}\u{30ED}\u{53E3}\u{30FC}", "ll/=-OO-")
        // Dashes and quotes (skeleton only; prose keeps them unmarked)
        for v: UInt32 in [0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0xFE58, 0xFE63, 0x2043] { m[v] = "-" }
        m[0x2018] = "'"; m[0x2019] = "'"; m[0x201C] = "\""; m[0x201D] = "\""
        return m
    }()

    /// Punctuation and symbols that imitate ASCII punctuation; always marked, wherever they occur.
    private static let lookalikePunctuation: Set<UInt32> = [
        0x201A, 0x037E, 0x0387, 0x0589, 0x05C3, 0x2236, 0xA789, 0x02F8, 0x2024, 0x2027, 0x2044, 0x2215, 0x2216, 0x2223,
        0x05C0, 0x2212, 0x2010, 0x2011, 0x2012, 0x02D7, 0x02BC, 0x2032, 0xA78C, 0x02C8, 0x02B9, 0x2033, 0x01C3, 0xFF0E,
        0x0703, 0x0704, 0x16EB, 0x2E31, 0x30FB,
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

    /// Superscript/subscript digits and signs, vulgar fractions, ™ and ℠ read as what they are in prose ("m²", "½").
    /// Accepted risk, listed in gaps.md; option labels stay strict (`strictFlags`).
    private static func proseCompatExempt(_ v: UInt32) -> Bool {
        switch v {
        // 0x207F (superscript letter n) is deliberately not exempt.
        case 0xB2, 0xB3, 0xB9, 0x2070, 0x2074...0x207E, 0x2080...0x208E, 0xBC...0xBE, 0x2150...0x215F, 0x2189, 0x2120, 0x2122: return true
        default: return false
        }
    }

    /// Marked wherever it occurs: non-ASCII digits, look-alike punctuation, compatibility forms of letters/digits.
    private static func alwaysFlag(_ s: Unicode.Scalar) -> String? {
        let v = s.value
        if v < 0x80 { return nil }
        if s.properties.generalCategory == .decimalNumber { return markerLabel("digit", s) }
        if lookalikePunctuation.contains(v) { return markerLabel("look-alike", s) }
        if proseCompatExempt(v) { return nil }
        let str = String(s)
        let k = str.precomposedStringWithCompatibilityMapping
        if k != str.precomposedStringWithCanonicalMapping, k.unicodeScalars.contains(where: isASCIIAlnum) {
            return markerLabel("look-alike", s)
        }
        return nil
    }

    /// Scripts that imitate Latin; a word in one of them next to Latin, or one that reads as Latin, is marked.
    private static let imitating: Set<Script> = [.smallCapital, .letterlike, .greek, .coptic, .cyrillic, .armenian, .cherokee, .lisu]
    /// Never used for prose a user of this app writes: always marked.
    private static let alwaysMarked: Set<Script> = [.smallCapital, .letterlike, .coptic, .cherokee, .lisu]
    /// CJK letters that look like Latin letters or punctuation (ㅣ ノ ニ 一 ロ 口 ー).
    private static let cjkLookalikes: Set<UInt32> = [0x3163, 0x1175, 0x30CE, 0x30CB, 0x4E00, 0x30ED, 0x53E3, 0x30FC]

    static func isRightToLeft(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF: return true
        default: return false
        }
    }

    private struct Word {
        let line: Int
        var letters: [(Int, Script)] = []
        var scripts: Set<Script> = []
        var hasASCIIDigit = false
        var hasRTL = false
        var readsAsLatin = false
        var isLatin: Bool { scripts.contains(.latin) }
    }

    /// Scalar offset → marker for every scalar a reader could take for something else (prose rules).
    /// Linear in the input: words are scanned once, per-line facts are gathered in one pass, neighbours are by index.
    static func flags(_ scalars: [Unicode.Scalar]) -> [Int: String] {
        var out: [Int: String] = [:]
        var words: [Word] = []
        var line = 0
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            guard isWordScalar(s) else {
                if let m = alwaysFlag(s) { out[i] = m }
                if s.value == 0x0A || s.value == 0x0D || s.value == 0x2028 || s.value == 0x2029 { line += 1 }
                i += 1
                continue
            }
            var w = Word(line: line)
            var mapped = 0
            while i < scalars.count, isWordScalar(scalars[i]) {
                let c = scalars[i]
                if let m = alwaysFlag(c) { out[i] = m }
                else {
                    if (0x30...0x39).contains(c.value) { w.hasASCIIDigit = true }
                    if let sc = script(c) {
                        w.letters.append((i, sc))
                        w.scripts.insert(sc)
                        if prototype[c.value] != nil { mapped += 1 }
                        if isRightToLeft(c) { w.hasRTL = true }
                    }
                }
                i += 1
            }
            // At least half the letters have a Latin prototype ("Ассерт", "οκ", "ןן"): the word can be read as Latin.
            w.readsAsLatin = !w.letters.isEmpty && mapped * 2 >= w.letters.count
            words.append(w)
        }
        // Per line: any Latin word; scripts with real prose (a single-script word that does not read as Latin).
        var lineHasLatin = [Bool](repeating: false, count: line + 1)
        var native = [Set<Script>](repeating: [], count: line + 1)
        // Turkish-specific letters (ç ğ ş ö ü İ and capitals) on a line make a dotless ı there read as Turkish.
        var lineIsTurkish = [Bool](repeating: false, count: line + 1)
        let turkishLetters: Set<UInt32> = [0xE7, 0xC7, 0x11F, 0x11E, 0x15F, 0x15E, 0xF6, 0xD6, 0xFC, 0xDC, 0x130]
        for w in words {
            if w.isLatin { lineHasLatin[w.line] = true }
            if w.letters.contains(where: { turkishLetters.contains(scalars[$0.0].value) }) { lineIsTurkish[w.line] = true }
            if w.scripts.count == 1, let sc = w.scripts.first, sc != .latin, sc != .cjk, !w.readsAsLatin { native[w.line].insert(sc) }
        }
        for n in words.indices where !words[n].letters.isEmpty {
            let w = words[n]
            let prev = n > 0 && words[n - 1].line == w.line ? words[n - 1] : nil
            let next = n + 1 < words.count && words[n + 1].line == w.line ? words[n + 1] : nil
            let nextToLatin = prev?.isLatin == true || next?.isLatin == true
            let nextToDigits = prev?.hasASCIIDigit == true || next?.hasASCIIDigit == true
            let scripts = w.scripts
            let hasImitating = !scripts.isDisjoint(with: imitating)
            func mark(_ k: Int, _ sc: Script) { if out[k] == nil { out[k] = markerLabel(sc.name, scalars[k]) } }
            if scripts.count > 1 {
                // Mixed word: Latin dominates if present, everything else is marked. A CJK letter is exempt only in a word with
                // no Latin-imitating letters and only if it does not itself look like Latin; adding one never suppresses marking.
                for (k, sc) in w.letters where sc != .latin {
                    if sc == .cjk {
                        let lookalike = cjkLookalikes.contains(scalars[k].value) && (scripts.contains(.latin) || nextToLatin)
                        if !hasImitating && !lookalike { continue }
                    }
                    mark(k, sc)
                }
            } else if let sc = scripts.first {
                switch sc {
                case .latin:
                    // U+0131 dotless i is ordinary Turkish: left unmarked when its word has other non-ASCII letters ("açık")
                    // or its line has Turkish-specific letters ("kapısı açık"); otherwise ("Turn ıt on") it reads as "i".
                    let turkish = lineIsTurkish[w.line] || w.letters.contains { scalars[$0.0].value > 0x7F && scalars[$0.0].value != 0x131 }
                    for (k, _) in w.letters where scalars[k].value > 0x7F
                        && (scalars[k].value != 0x131 || !turkish) && prototype[scalars[k].value] != nil {
                        out[k] = markerLabel("look-alike", scalars[k])
                    }
                case .cjk:
                    if nextToLatin { for (k, _) in w.letters where cjkLookalikes.contains(scalars[k].value) { mark(k, sc) } }
                case _ where alwaysMarked.contains(sc):
                    for (k, _) in w.letters { mark(k, sc) }
                default:
                    // Reads as Latin, and either Latin is on the line or there is no real prose in this script around it.
                    // A Cyrillic/Greek word that does not read as Latin stays clean next to Latin ("Объединить PR 12?").
                    if w.readsAsLatin && (lineHasLatin[w.line] || !native[w.line].contains(sc)) {
                        for (k, _) in w.letters { mark(k, sc) }
                    }
                }
            }
            // Right-to-left letters directly next to Latin or digits reorder them ("ש 10 20" shows as "20 10 ש").
            if w.hasRTL, nextToLatin || nextToDigits,
               let first = w.letters.first(where: { isRightToLeft(scalars[$0.0]) }), out[first.0] == nil {
                out[first.0] = markerLabel("right-to-left", scalars[first.0])
            }
        }
        return out
    }

    // MARK: Option labels (fail closed)

    /// The only scalars an option label may contain, checked per Unicode scalar of the exact signed string (never per
    /// grapheme, never after normalisation): printable ASCII and the precomposed Latin-1 letters U+00C0–U+00FF except × ÷.
    /// Combining marks are refused outright, so "e\u{0301}", "o\u{0338}", "A\u{20DD}", variation selectors, ZWJ
    /// sequences and emoji modifiers never pass as ASCII.
    static func isPlainLabelScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x20...0x7E: return true
        case 0xD7, 0xF7: return false
        case 0xC0...0xFF: return true
        default: return false
        }
    }

    /// Strict marking for option labels: every scalar outside the allowlist gets a marker.
    static func strictFlags(_ scalars: [Unicode.Scalar]) -> [Int: String] {
        var out: [Int: String] = [:]
        for (k, s) in scalars.enumerated() where !isPlainLabelScalar(s) {
            if let sc = script(s) { out[k] = markerLabel(sc == .other ? "letter" : sc.name, s) }
            else if s.properties.generalCategory == .decimalNumber { out[k] = markerLabel("digit", s) }
            else { out[k] = markerLabel("character", s) }
        }
        return out
    }

    /// UTS #39-style skeleton of plain text: NFKD, drop combining marks (so "Café" and "Cafe" collide: fail closed), map each
    /// scalar to its prototype, fold the ASCII look-alikes (I/1/| → l, 0 → O, m → rn), NFD. Equal skeletons read the same.
    /// Normalisation happens only here, on a copy for comparison; the allowlist and the display see the signed scalars.
    static func skeleton(_ text: String) -> String {
        var out = ""
        for s in text.decomposedStringWithCompatibilityMapping.unicodeScalars {
            switch s.properties.generalCategory {
            case .nonspacingMark, .enclosingMark: continue
            default: break
            }
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
