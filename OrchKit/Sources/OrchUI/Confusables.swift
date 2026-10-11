import Foundation

/// Look-alike detection for host text on signing surfaces, after Unicode TS #39 (security mechanisms).
///
/// **Partial.** No ICU or confusables.txt is bundled: `prototype` is a compact hand-picked subset of confusables.txt
/// (Cyrillic, Greek, Armenian, Cherokee, Lisu, Coptic, Hebrew, a few Latin-extended and CJK letters, look-alike punctuation);
/// NFKD covers full-width, mathematical and other compatibility forms. The table misses most of confusables.txt, so it is
/// never the only line of defence:
/// - option labels (what the user taps and signs) fail closed on an allowlist instead (`SafeText.optionRefusal`):
///   plain ASCII only, or all labels in one non-Latin, left-to-right script none of whose words imitates Latin;
/// - option sets whose skeletons collide are refused as well;
/// - question prose is informational and must stay readable, so it is marked, not refused: the heuristics in `flags`
///   can miss look-alikes the table does not know (they are best effort, not fail closed).
enum Confusables {
    enum Script: Hashable {
        case latin, smallCapital, greek, coptic, cyrillic, armenian, cherokee, lisu, cjk, other

        var name: String {
            switch self {
            case .latin: "Latin"
            case .smallCapital: "small capital"
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
        add("ıɑɡǀǃɩ", "iaglli")
        m[0x01C3] = "!"
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

    /// Scripts that imitate Latin; a word in one of them next to Latin, or one that reads as Latin, is marked.
    private static let imitating: Set<Script> = [.smallCapital, .greek, .coptic, .cyrillic, .armenian, .cherokee, .lisu]
    /// Never used for prose a user of this app writes: always marked.
    private static let alwaysMarked: Set<Script> = [.smallCapital, .coptic, .cherokee, .lisu]
    /// CJK letters that look like Latin letters or punctuation (ㅣ ノ ニ 一 ロ 口 ー).
    private static let cjkLookalikes: Set<UInt32> = [0x3163, 0x1175, 0x30CE, 0x30CB, 0x4E00, 0x30ED, 0x53E3, 0x30FC]

    static func isRightToLeft(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF: return true
        default: return false
        }
    }

    private struct Word {
        let range: Range<Int>
        let line: Int
        var letters: [(Int, Script)] = []
        var scripts: Set<Script> { Set(letters.map(\.1)) }
        var isLatin: Bool { scripts.contains(.latin) }
        var hasASCIIDigit = false
        var hasRTL = false
    }

    /// At least half the letters have a Latin prototype ("Ассерт", "οκ", "ןן"): the word can be read as Latin.
    private static func readsAsLatin(_ w: Word, _ scalars: [Unicode.Scalar]) -> Bool {
        guard !w.letters.isEmpty else { return false }
        let mapped = w.letters.filter { prototype[scalars[$0.0].value] != nil }.count
        return mapped * 2 >= w.letters.count
    }

    /// Scalar offset → marker for every scalar a reader could take for something else (prose rules).
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
            var j = i
            while j < scalars.count, isWordScalar(scalars[j]) { j += 1 }
            var w = Word(range: i..<j, line: line)
            for k in i..<j {
                if let m = alwaysFlag(scalars[k]) { out[k] = m; continue }
                if (0x30...0x39).contains(scalars[k].value) { w.hasASCIIDigit = true }
                if let sc = script(scalars[k]) {
                    w.letters.append((k, sc))
                    if isRightToLeft(scalars[k]) { w.hasRTL = true }
                }
            }
            words.append(w)
            i = j
        }
        for (n, w) in words.enumerated() where !w.letters.isEmpty {
            let lineWords = words.filter { $0.line == w.line }
            let lineHasLatin = lineWords.contains(where: \.isLatin)
            // Scripts with at least one single-script word that does not read as Latin: real prose in that script.
            let native = Set(lineWords.compactMap { x -> Script? in
                guard x.scripts.count == 1, let sc = x.scripts.first, sc != .latin, sc != .cjk, !readsAsLatin(x, scalars) else { return nil }
                return sc
            })
            let neighbours = [n - 1, n + 1].filter { words.indices.contains($0) && words[$0].line == w.line }.map { words[$0] }
            let nextToLatin = neighbours.contains(where: \.isLatin)
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
                    for (k, _) in w.letters where scalars[k].value > 0x7F && prototype[scalars[k].value] != nil {
                        out[k] = markerLabel("look-alike", scalars[k])
                    }
                case .cjk:
                    if nextToLatin { for (k, _) in w.letters where cjkLookalikes.contains(scalars[k].value) { mark(k, sc) } }
                case _ where alwaysMarked.contains(sc):
                    for (k, _) in w.letters { mark(k, sc) }
                default:
                    let reads = readsAsLatin(w, scalars)
                    if (imitating.contains(sc) && nextToLatin) || (reads && (lineHasLatin || !native.contains(sc))) {
                        for (k, _) in w.letters { mark(k, sc) }
                    }
                }
            }
            // Right-to-left letters next to Latin or digits reorder them ("ש 10 20" shows as "20 10 ש").
            if w.hasRTL, lineHasLatin || lineWords.contains(where: \.hasASCIIDigit),
               let first = w.letters.first(where: { isRightToLeft(scalars[$0.0]) }), out[first.0] == nil {
                out[first.0] = markerLabel("right-to-left", scalars[first.0])
            }
        }
        return out
    }

    // MARK: Option labels (fail closed)

    /// The only scalars an option label may contain unless the set qualifies for `isSingleScriptSet`.
    static func isPlainLabelScalar(_ s: Unicode.Scalar) -> Bool {
        isASCIIAlnum(s) || " .,:;!?'\"()-/&+%#_".unicodeScalars.contains(s)
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

    /// Localisation exception: every label uses ASCII digits/space/punctuation plus letters (and combining marks) of exactly one
    /// non-Latin, non-imitating-only, left-to-right script, and no word of any label reads as Latin through the table.
    static func isSingleScriptSet(_ labels: [String]) -> Bool {
        var only: Script?
        for label in labels {
            let scalars = Array(label.unicodeScalars)
            var word: [Unicode.Scalar] = []
            func wordReadsAsLatin() -> Bool {
                let letters = word.filter { script($0) != nil }
                return !letters.isEmpty && letters.allSatisfy { prototype[$0.value] != nil }
            }
            for s in scalars + [" "] {
                if isPlainLabelScalar(s) {
                    if isASCIIAlnum(s), !(0x30...0x39).contains(s.value) { return false }   // ASCII letter: not single-script
                    if wordReadsAsLatin() { return false }
                    word = []
                    continue
                }
                switch s.properties.generalCategory {
                case .nonspacingMark, .spacingMark:
                    guard !word.isEmpty else { return false }
                    word.append(s)
                default:
                    guard let sc = script(s), sc != .latin, !alwaysMarked.contains(sc), !isRightToLeft(s) else { return false }
                    if let only, only != sc { return false }
                    only = sc
                    word.append(s)
                }
            }
        }
        return only != nil
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
