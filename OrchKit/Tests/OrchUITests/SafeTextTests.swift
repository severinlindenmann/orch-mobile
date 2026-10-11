import Testing
@testable import OrchUI

@Suite struct SafeTextTests {
    @MainActor @Test func markersStayUnbrokenInProportionalText() {
        let a = SafeText.attributed("a\u{200B}b")
        #expect(String(a.characters).contains("⟨U+200B⟩"))
    }
    @Test func bidiControlsMarked() {
        #expect(SafeText.markers(in: "a\u{202E}b\u{202C}") == ["⟨U+202E⟩", "⟨U+202C⟩"])
        #expect(SafeText.markers(in: "x\u{2066}y\u{2069}") == ["⟨U+2066⟩", "⟨U+2069⟩"])
    }
    @Test func zeroWidthAndInvisibleMarked() {
        #expect(SafeText.hasUnsafe("a\u{200B}b"))
        #expect(SafeText.hasUnsafe("a\u{FEFF}b"))
        #expect(SafeText.hasUnsafe("a\u{3164}b"))
        #expect(SafeText.hasUnsafe("a\u{2060}b"))
    }
    @Test func variationSelectorsAlwaysMarked() {
        #expect(SafeText.hasUnsafe("a\u{FE00}"))
        #expect(SafeText.hasUnsafe("a\u{FE0D}"))
        #expect(SafeText.hasUnsafe("a\u{180B}"))
        #expect(SafeText.hasUnsafe("a\u{E0100}"))
        #expect(SafeText.hasUnsafe("a\u{E01EF}"))
    }
    @Test func emojiPresentationOnlyAfterEmoji() {
        #expect(!SafeText.hasUnsafe("\u{2764}\u{FE0F}"))
        #expect(SafeText.hasUnsafe("a\u{FE0F}"))
        #expect(SafeText.hasUnsafe("a\u{FE0E}"))
        #expect(SafeText.hasUnsafe("1\u{FE0F}"))
    }
    @Test func nonAsciiWhitespaceAndObjectReplacement() {
        for v in [0x00A0, 0x1680, 0x2000, 0x200A, 0x202F, 0x205F, 0x3000, 0xFFFC] {
            #expect(SafeText.hasUnsafe("a" + String(UnicodeScalar(UInt32(v))!) + "b"), "U+\(v)")
        }
        #expect(!SafeText.hasUnsafe("a b"))
    }
    @Test func zalgoMarked() {
        let z = "e" + String(repeating: "\u{0301}", count: 8)
        #expect(SafeText.markers(in: z) == ["⟨8 marks⟩"])
        #expect(!SafeText.hasUnsafe("e\u{0301}\u{0302}\u{0303}"))
    }
    @Test func literalMarkerIsNotAMarker() {
        let m = SafeText.markers(in: "⟨U+202E⟩")
        #expect(m == ["⟨U+27E8⟩", "⟨U+27E9⟩"])
        #expect(SafeText.inline("⟨U+202E⟩") == "⟨U+27E8⟩U+202E⟨U+27E9⟩")
    }
    @Test func inlineIsOneLineAndCapped() {
        #expect(SafeText.inline("a\nb") == "a b")
        #expect(SafeText.inline(String(repeating: "x", count: 100), limit: 10) == String(repeating: "x", count: 10) + "…")
    }
    @Test func labelNeutralisesDigitRuns() {
        #expect(!SafeText.label("Mac 493 128").contains("4"))
        #expect(SafeText.label("Mac 2") == "Mac 2")
        #expect(!SafeText.label("Mac 2", allowDigits: false).contains("2"))
    }
    @Test func lookAlikeOptionsAreAmbiguous() {
        #expect(SafeText.hasAmbiguousOptions(["Yes", "Yes"]))
        #expect(!SafeText.hasAmbiguousOptions(["Yes", "Yes\u{200B}"]))
        #expect(!SafeText.hasAmbiguousOptions(["Approve", "Reject"]))
    }
    @Test func cyrillicAndGreekLookAlikesAreAmbiguous() {
        #expect(SafeText.hasAmbiguousOptions(["Approve", "\u{0410}pprove"]))
        #expect(SafeText.hasAmbiguousOptions(["Yes", "Y\u{0435}s"]))
        #expect(SafeText.hasAmbiguousOptions(["NO", "N\u{039F}"]))
        #expect(!SafeText.hasAmbiguousOptions(["Approve", "Reject"]))
    }
    @Test func markdownIsLeftLiteral() {
        let p = SafeText.pieces("**x** [a](http://b)")
        #expect(p == [.text("**x** [a](http://b)")])
    }
}
