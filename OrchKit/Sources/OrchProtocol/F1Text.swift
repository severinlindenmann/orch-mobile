import Foundation

/// Text rules for everything a phone signs or hashes (F1 / ticket-format section 11.3, host section 11A.14 14.2): UTF-8,
/// NFC with Unicode 16.0 tables, LF and TAB allowed, no CR, no other C0 control, no DEL, no C1, no bidi control and no code point
/// unassigned in Unicode 16.0.
///
/// The Swift runtime's Unicode version varies by OS, so this file never asks it: the assigned ranges, combining classes and
/// canonical (de)compositions of 16.0 come from `Unicode16Data` (generated from orch-core's bundle, see that file's header) and NFC
/// is implemented here (UAX 15), a port of orch-core `canon/text.py`. The host refuses a violating string with `validation.text`
/// and never normalises a signed string, so the phone normalises phone-authored text BEFORE the sign sheet (`normalize`) and
/// signs only text that `check` accepts.
///
/// NEVER use Foundation's `precomposedStringWithCanonicalMapping` (or `String` equality as a normalisation test) on a path that is signed
/// or hashed: it follows the OS's Unicode version and is wrong for some sequences (an audit found 164 mismatches against the 16.0
/// tables in 300 000 random strings, among them Tibetan). `FieldRules` in the tests fails if the symbol appears in OrchProtocol.
public enum F1Text {
    public static let unicodeVersion = Unicode16Data.version

    public struct Violation: Error, Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case control, bidiControl, unassigned, notNFC, lineFeedInOneLine }
        public let kind: Kind
        /// Index in Unicode scalars (not bytes) of the first offending scalar.
        public let index: Int
    }

    public static let bidiControls: Set<UInt32> = [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0x200E, 0x200F, 0x061C]

    // MARK: tables (parsed once)

    private struct Tables: Sendable {
        let assigned: [(UInt32, UInt32)]
        let ccc: [(UInt32, UInt32, UInt8)]
        let decomp: [UInt32: [UInt32]]
        let compose: [UInt64: UInt32]
        let cf: [(UInt32, UInt32)]
        let marks: [(UInt32, UInt32)]
        let casefold: [UInt32: [UInt32]]

        init() {
            func rows(_ s: String) -> [[UInt32]] {
                s.split(separator: "\n").map { $0.split(separator: " ").compactMap { UInt32($0, radix: 16) } }
            }
            assigned = rows(Unicode16Data.assigned).map { ($0[0], $0[1]) }
            // combining classes are decimal in the third column
            ccc = Unicode16Data.ccc.split(separator: "\n").map { line in
                let p = line.split(separator: " ")
                return (UInt32(p[0], radix: 16)!, UInt32(p[1], radix: 16)!, UInt8(p[2])!)
            }
            var d: [UInt32: [UInt32]] = [:]
            for r in rows(Unicode16Data.decomp) { d[r[0]] = Array(r.dropFirst()) }
            decomp = d
            var c: [UInt64: UInt32] = [:]
            for r in rows(Unicode16Data.composable) {
                let parts = d[r[0]]!
                c[Tables.key(parts[0], parts[1])] = r[0]
            }
            compose = c
            cf = rows(Unicode16Data.cf).map { ($0[0], $0[1]) }
            marks = rows(Unicode16Data.marks).map { ($0[0], $0[1]) }
            var f: [UInt32: [UInt32]] = [:]
            for r in rows(Unicode16Data.casefold) { f[r[0]] = Array(r.dropFirst()) }
            casefold = f
        }
        static func key(_ a: UInt32, _ b: UInt32) -> UInt64 { (UInt64(a) << 32) | UInt64(b) }
    }

    private static let tables = Tables()

    private static func inRanges(_ r: [(UInt32, UInt32)], _ cp: UInt32) -> Bool {
        var lo = 0, hi = r.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cp < r[mid].0 { hi = mid - 1 } else if cp > r[mid].1 { lo = mid + 1 } else { return true }
        }
        return false
    }

    /// Assigned (General_Category not Cn) in Unicode 16.0, whatever the OS ships. Surrogates and private use count as assigned.
    public static func isAssigned(_ cp: UInt32) -> Bool { inRanges(tables.assigned, cp) }

    private static func ccc(_ cp: UInt32) -> UInt8 {
        let t = tables.ccc
        var lo = 0, hi = t.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cp < t[mid].0 { hi = mid - 1 } else if cp > t[mid].1 { lo = mid + 1 } else { return t[mid].2 }
        }
        return 0
    }

    // MARK: NFC (UAX 15)

    private static let sBase: UInt32 = 0xAC00, lBase: UInt32 = 0x1100, vBase: UInt32 = 0x1161, tBase: UInt32 = 0x11A7
    private static let lCount: UInt32 = 19, vCount: UInt32 = 21, tCount: UInt32 = 28
    private static var nCount: UInt32 { vCount * tCount }
    private static var sCount: UInt32 { lCount * nCount }

    private static func fullDecomp(_ cp: UInt32, into out: inout [UInt32]) {
        if cp >= sBase && cp < sBase + sCount {
            let s = cp - sBase
            out.append(lBase + s / nCount)
            out.append(vBase + (s % nCount) / tCount)
            if s % tCount != 0 { out.append(tBase + s % tCount) }
            return
        }
        guard let d = tables.decomp[cp] else { out.append(cp); return }
        for p in d { fullDecomp(p, into: &out) }
    }

    private static func composePair(_ a: UInt32, _ b: UInt32) -> UInt32? {
        if a >= lBase && a < lBase + lCount && b >= vBase && b < vBase + vCount {
            return sBase + ((a - lBase) * vCount + (b - vBase)) * tCount
        }
        if a >= sBase && a < sBase + sCount && (a - sBase) % tCount == 0 && b > tBase && b < tBase + tCount {
            return a + (b - tBase)
        }
        return tables.compose[Tables.key(a, b)]
    }

    /// Unicode 16.0 NFC of the scalars of `text`, independent of the OS. Does not check the text rules.
    public static func nfc(_ text: String) -> String {
        var cps: [UInt32] = []
        for u in text.unicodeScalars { fullDecomp(u.value, into: &cps) }
        // canonical ordering: stable sort of each run of non-starters by combining class
        var i = 0
        while i < cps.count {
            if ccc(cps[i]) == 0 { i += 1; continue }
            var j = i
            while j < cps.count && ccc(cps[j]) != 0 { j += 1 }
            let run = cps[i..<j].enumerated().sorted { a, b in
                let ca = ccc(a.element), cb = ccc(b.element)
                return ca != cb ? ca < cb : a.offset < b.offset
            }.map(\.element)
            cps.replaceSubrange(i..<j, with: run)
            i = j
        }
        var out: [UInt32] = []
        var starter = -1
        var lastClass: UInt8 = 0
        for cp in cps {
            let cls = ccc(cp)
            if starter >= 0, let comp = composePair(out[starter], cp), lastClass < cls || lastClass == 0 {
                out[starter] = comp
                continue
            }
            if cls == 0 { starter = out.count }
            lastClass = cls
            out.append(cp)
        }
        var s = String.UnicodeScalarView()
        for cp in out { s.append(Unicode.Scalar(cp)!) }
        return String(s)
    }

    // MARK: checks

    /// Returns normally when `text` follows section 11.3 as-is; never normalises. `oneLine` also refuses LF (titles, labels).
    public static func check(_ text: String, oneLine: Bool = false) throws {
        var idx = 0
        for u in text.unicodeScalars {
            let cp = u.value
            if (cp < 0x20 && cp != 0x0A && cp != 0x09) || (cp >= 0x7F && cp <= 0x9F) { throw Violation(kind: .control, index: idx) }
            if bidiControls.contains(cp) { throw Violation(kind: .bidiControl, index: idx) }
            if !isAssigned(cp) { throw Violation(kind: .unassigned, index: idx) }
            if oneLine && cp == 0x0A { throw Violation(kind: .lineFeedInOneLine, index: idx) }
            idx += 1
        }
        let n = nfc(text)
        if !n.unicodeScalars.elementsEqual(text.unicodeScalars) {
            var k = 0
            for (a, b) in zip(text.unicodeScalars, n.unicodeScalars) { if a != b { break }; k += 1 }
            throw Violation(kind: .notNFC, index: k)
        }
    }

    public static func isClean(_ text: String, oneLine: Bool = false) -> Bool { (try? check(text, oneLine: oneLine)) != nil }

    /// For phone-authored text entering a signed field: CRLF and lone CR become LF, then NFC, then `check` (so a character
    /// newer than Unicode 16.0, a control or a bidi control is refused, not repaired). Idempotent.
    public static func normalize(_ text: String, oneLine: Bool = false) throws -> String {
        var scalars = String.UnicodeScalarView()
        var prevCR = false
        for u in text.unicodeScalars {
            if u.value == 0x0D { scalars.append("\n"); prevCR = true; continue }
            if u.value == 0x0A && prevCR { prevCR = false; continue }
            prevCR = false
            scalars.append(u)
        }
        let n = nfc(String(scalars))
        try check(n, oneLine: oneLine)
        return n
    }

    // MARK: plain text of structured questions (ticket-format 5.6.1, core `canon/text.py` check_plain / fold)

    /// The Unicode `White_Space` property (PropList 16.0, 25 code points), pinned: `whitespacesAndNewlines` differs.
    static let whiteSpace: Set<UInt32> = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005,
                                          0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000]

    /// Empty, or every scalar has the White_Space property.
    public static func isBlank(_ text: String) -> Bool { text.unicodeScalars.allSatisfy { whiteSpace.contains($0.value) } }

    /// F1's named non-Cf look-alikes of an invisible character (core `_EXTRA_INVISIBLE`).
    private static func extraInvisible(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x034F, 0x115F, 0x1160, 0x2028, 0x2029, 0x2800, 0x3164, 0xFFA0, 0x17B4...0x17B5, 0x180B...0x180F, 0xFE00...0xFE0F, 0xE0100...0xE01EF: return true
        default: return false
        }
    }

    private static func privateUse(_ cp: UInt32) -> Bool {
        (0xE000...0xF8FF).contains(cp) || (0xF0000...0xFFFFD).contains(cp) || (0x100000...0x10FFFD).contains(cp)
    }

    /// Whether `text` holds a character a signing surface must not show as plain text (core `suspicious()`): bidi controls, every Cf
    /// character, the named look-alikes, private use, or a leading mark.
    public static func hasSuspicious(_ text: String) -> Bool {
        for (i, u) in text.unicodeScalars.enumerated() {
            let cp = u.value
            if bidiControls.contains(cp) || extraInvisible(cp) || inRanges(tables.cf, cp) || privateUse(cp) || (i == 0 && inRanges(tables.marks, cp)) { return true }
        }
        return false
    }

    /// `NFC(fullCaseFold(NFC(s)))` with the bundled Unicode 16.0 CaseFolding C+F table: the one comparison form for "the same title".
    public static func fold(_ text: String) -> String {
        var s = String.UnicodeScalarView()
        for u in nfc(text).unicodeScalars {
            if let f = tables.casefold[u.value] { for cp in f { s.append(Unicode.Scalar(cp)!) } } else { s.append(u) }
        }
        return nfc(String(s))
    }

    /// Core `check_plain`: `check` (never mutates), not blank, no tab in a one-line field, no suspicious character, at most `limit`
    /// scalars and 4096 UTF-8 bytes. Returns normally or throws; `reason` names the failed rule for a plain "cannot verify" line.
    public static func checkPlain(_ text: String, oneLine: Bool, limit: Int) throws {
        try check(text, oneLine: oneLine)
        if isBlank(text) { throw PlainViolation.blank }
        if oneLine && text.unicodeScalars.contains(where: { $0.value == 0x09 }) { throw PlainViolation.tabInOneLine }
        if hasSuspicious(text) { throw PlainViolation.invisible }
        if text.unicodeScalars.count > limit { throw PlainViolation.tooLong }
        if text.utf8.count > 4096 { throw PlainViolation.tooManyBytes }
    }

    public enum PlainViolation: Error, Equatable, Sendable { case blank, tabInOneLine, invisible, tooLong, tooManyBytes }

    public static func isPlain(_ text: String, oneLine: Bool, limit: Int) -> Bool { (try? checkPlain(text, oneLine: oneLine, limit: limit)) != nil }
}
