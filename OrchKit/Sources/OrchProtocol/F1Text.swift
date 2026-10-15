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
public enum F1Text {
    public static let unicodeVersion = Unicode16Data.version

    public struct Violation: Error, Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case control, bidiControl, unassigned, notNFC, lineFeedInOneLine, tooLong, empty }
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

    /// Byte length of the UTF-8 encoding (the answer text cap is 4 096 bytes).
    public static func utf8Length(_ s: String) -> Int { s.utf8.count }
}
