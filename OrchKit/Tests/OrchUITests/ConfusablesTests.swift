import Testing
@testable import OrchUI

/// Spoof strings a hostile host could put on the signing surface (UTS #39 skeleton, partial table).
@Suite struct ConfusablesTests {
    @Test func fullWidthAndMathOptionsAreAmbiguous() {
        #expect(SafeText.hasAmbiguousOptions(["Approve", "\u{FF21}pprove"]))          // Ａpprove
        #expect(SafeText.hasAmbiguousOptions(["Approve", "\u{1D5A0}pprove"]))         // 𝖠pprove
        #expect(SafeText.hasAmbiguousOptions(["Yes", "\u{FF39}es"]))                  // Ｙes
    }
    @Test func cyrillicGreekArmenianCherokeeLisuOptionsAreAmbiguous() {
        #expect(SafeText.hasAmbiguousOptions(["Yes, ship it", "Yes, \u{0455}hip it"]))  // ѕ
        #expect(SafeText.hasAmbiguousOptions(["deploy", "\u{0501}eploy"]))            // ԁ
        #expect(SafeText.hasAmbiguousOptions(["v2", "\u{03BD}2"]))                    // ν
        #expect(SafeText.hasAmbiguousOptions(["Stop", "\u{054F}top"]))                // Տ
        #expect(SafeText.hasAmbiguousOptions(["Approve", "\u{13AA}pprove"]))          // Ꭺ
        #expect(SafeText.hasAmbiguousOptions(["Approve", "\u{A4EE}pprove"]))          // ꓮ
        #expect(SafeText.hasAmbiguousOptions(["Keep", "\u{039A}eep"]))                // Κ
    }
    @Test func lookalikeDigitsAndPunctuationAreAmbiguous() {
        #expect(SafeText.hasAmbiguousOptions(["Retry 10", "Retry 1O"]))
        #expect(SafeText.hasAmbiguousOptions(["Install", "lnstall"]))
        #expect(SafeText.hasAmbiguousOptions(["Rollback to 1.2", "Rollback to 1\u{2024}2"]))
        #expect(SafeText.hasAmbiguousOptions(["Set -1", "Set \u{2212}1"]))
        #expect(SafeText.hasAmbiguousOptions(["modern", "rnodern"]))
    }
    @Test func whitespaceAndNormalisationTricksAreAmbiguous() {
        #expect(SafeText.hasAmbiguousOptions(["Approve now", "Approve  now"]))
        #expect(SafeText.hasAmbiguousOptions(["Approve", "Approve\n"]))
        #expect(SafeText.hasAmbiguousOptions(["Caf\u{00E9}", "Cafe\u{0301}"]))
        #expect(SafeText.hasAmbiguousOptions(["Approve", "\u{2160}pprove"]) == false)   // Ⅰ vs A: different letters
        #expect(SafeText.hasAmbiguousOptions(["Install", "\u{2160}nstall"]))           // Ⅰnstall (Roman numeral one)
    }
    @Test func distinctOptionsStayDistinct() {
        #expect(!SafeText.hasAmbiguousOptions(["Approve", "Reject"]))
        #expect(!SafeText.hasAmbiguousOptions(["Ja", "Nein", "Später"]))
        #expect(!SafeText.hasAmbiguousOptions(["Да", "Нет"]))
        #expect(!SafeText.hasAmbiguousOptions(["Approve", "approve"]))
    }

    @Test func mixedScriptWordIsMarkedAtTheLetter() {
        #expect(SafeText.markers(in: "\u{0430}pprove") == ["⟨Cyrillic U+0430⟩"])
        #expect(SafeText.pieces("Deploy to staging-\u{0430}pi?") ==
                [.text("Deploy to staging-\u{0430}"), .marker("⟨Cyrillic U+0430⟩"), .text("pi?")])
        #expect(SafeText.markers(in: "orch-\u{0430}pp") == ["⟨Cyrillic U+0430⟩"])
        #expect(SafeText.markers(in: "N\u{039F}") == ["⟨Greek U+039F⟩"])
    }
    @Test func wholeWordLookalikeIsMarked() {
        // "аррӏе": every letter Cyrillic but reads as Latin "apple".
        #expect(SafeText.markers(in: "\u{0430}\u{0440}\u{0440}\u{04CF}\u{0435}").count == 5)
        #expect(SafeText.markers(in: "\u{0455}\u{0435}\u{0441}").count == 3)        // ѕес
    }
    @Test func compatibilityFormsAndDigitsMarked() {
        #expect(SafeText.markers(in: "\u{FF21}pprove") == ["⟨look-alike U+FF21⟩"])
        #expect(SafeText.markers(in: "\u{1D5A0}") == ["⟨look-alike U+1D5A0⟩"])
        #expect(SafeText.markers(in: "PR \u{0661}\u{0662}") == ["⟨digit U+0661⟩", "⟨digit U+0662⟩"])
        #expect(SafeText.markers(in: "evil\u{2024}com") == ["⟨look-alike U+2024⟩"])
        #expect(SafeText.markers(in: "\u{2212}1") == ["⟨look-alike U+2212⟩"])
    }
    @Test func ordinaryProseIsNotMarked() {
        for s in ["Ändern und übernehmen?", "Café résumé naïve", "Привет, мир", "Γειά σου κόσμε", "日本語 mode",
                  "Running tests…", "Deploy – then wait", "你好，世界？", "\u{2764}\u{FE0F} ok", "مرحبا"] {
            #expect(!SafeText.hasUnsafe(s), "\(s): \(SafeText.markers(in: s))")
        }
    }
    @Test func lookalikeMarkersAreSpokenAndInline() {
        #expect(SafeText.inline("\u{0430}pp") == "\u{0430}⟨Cyrillic U+0430⟩pp")
        #expect(SafeText.spoken("\u{0430}pp").contains("look-alike character ⟨Cyrillic U+0430⟩"))
        #expect(SafeText.spoken("a\u{200B}").contains("unsafe character ⟨U+200B⟩"))
    }
    @Test func markerFollowsTheWholeCharacter() {
        // A combining mark stays on its base letter; the marker never splits a grapheme.
        #expect(SafeText.pieces("x\u{0430}\u{0301}pp") == [.text("x\u{0430}\u{0301}"), .marker("⟨Cyrillic U+0430⟩"), .text("pp")])
    }
    @Test func mixedScriptWorkspaceNameMarkedInline() {
        #expect(SafeText.inline("orch-\u{0430}pp", limit: 40) == "orch-\u{0430}⟨Cyrillic U+0430⟩pp")
        #expect(SafeText.inline("orch-app", limit: 40) == "orch-app")
    }
    @Test func skeletonIgnoresLookalikeMarkers() {
        #expect(SafeText.skeleton("\u{0410}pprove") == SafeText.skeleton("Approve"))
    }
}
