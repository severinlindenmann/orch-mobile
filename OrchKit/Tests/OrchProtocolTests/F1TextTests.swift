import Foundation
import Testing
@testable import OrchProtocol

@Suite struct F1TextTests {
    let t = F1Vectors.load("text")

    @Test func versionIsPinned() {
        #expect(F1Text.unicodeVersion == "16.0.0")
        #expect(t["unicode_version"].str == "16.0.0")
    }

    @Test func normalizeCasesMatchCore() throws {
        for c in t["normalize"].items {
            let out = try F1Text.normalize(c["input"].str)
            #expect(out.unicodeScalars.elementsEqual(c["output"].str.unicodeScalars), "\(c["name"].str)")
        }
    }

    @Test func keptInvisibleAreNotStripped() throws {
        for c in t["kept_invisible"].items {
            // zero width space, tag, BOM and private use are assigned in 16.0: kept, not repaired (11.3 refuses only the rules' list)
            let s = c["input"].str
            let out = try F1Text.normalize(s)
            #expect(out.unicodeScalars.elementsEqual(s.unicodeScalars), "\(c["name"].str)")
        }
    }

    @Test func refusedCasesAreRefused() {
        var n = 0
        for c in t["refused"].items where c["name"].str != "lone_surrogate" {
            #expect(!F1Text.isClean(c["input"].str), "\(c["name"].str)")
            #expect((try? F1Text.normalize(c["input"].str)) == nil, "normalize \(c["name"].str)")
            n += 1
        }
        #expect(n == 22)
    }

    @Test func notNormalisedInputsAreRefusedByCheck() {
        var n = 0
        for c in t["refused_not_normalised"].items {
            #expect(!F1Text.isClean(c["input"].str), "\(c["name"].str)")
            n += 1
        }
        #expect(n == t["refused_not_normalised"].items.count)
        #expect(n > 20)
    }

    @Test func lfAndTabAreAllowedCrIsNot() {
        #expect(F1Text.isClean("a\nb\tc"))
        #expect(!F1Text.isClean("a\rb"))
        #expect(!F1Text.isClean("a\nb", oneLine: true))
    }

    @Test func newerThanSixteenIsRefusedBeforeTheSignSheet() {
        // CJK Extension J (U+323B0) and Sidetic (U+10940) are assigned in Unicode 17.0, not 16.0
        #expect(!F1Text.isAssigned(0x323B0))
        #expect(!F1Text.isAssigned(0x10940))
        #expect(F1Text.isAssigned(0x10D40))   // Garay, new in 16.0
        #expect((try? F1Text.normalize("x\u{323B0}")) == nil)
    }

    @Test func normalizeIsIdempotent() throws {
        let once = try F1Text.normalize("e\u{301}\r\nx")
        #expect(try F1Text.normalize(once) == once)
        #expect(once == "\u{E9}\nx")
    }

    @Test func hangulComposesAlgorithmically() throws {
        #expect(try F1Text.normalize("\u{1112}\u{1161}\u{11AB}") == "\u{D55C}")
    }
}
