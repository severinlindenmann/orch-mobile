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

/// Regression tests for the PR #49 review: every spoof must be marked, and every spoofed option set refused.
@Suite struct SigningSpoofRegressionTests {
    private func refused(_ labels: [String]) -> Bool { SafeText.optionRefusal(labels) != nil }
    private func marked(_ s: String) -> Bool { SafeText.hasUnsafe(s) }
    private func strictMarked(_ s: String) -> Bool { SafeText.hasUnsafe(s, strictLabel: true) }

    @Test func reviewSpoofPairsAreRefusedAndMarked() {
        let pairs: [[String]] = [
            ["ok", "\u{043E}\u{043A}"],                                        // ок
            ["skip", "\u{0455}\u{043A}\u{0456}\u{0440}"],                      // ѕкір
            ["OK", "\u{2C9E}\u{2C94}"],                                        // ⲞⲔ (Coptic)
            ["APPROVE", "\u{1D00}\u{1D18}\u{1D18}\u{0280}\u{1D0F}\u{1D20}\u{1D07}"], // ᴀᴘᴘʀᴏᴠᴇ
            ["Apply", "\u{0410}\u{0440}\u{0440}\u{3163}\u{0443}"],             // Аррㅣу
            ["Deploy", "Dep\u{3163}oy"],
            ["Don't", "Don\u{2019}t"],
            ["Deploy - prod", "Deploy \u{2013} prod"],
        ]
        for p in pairs {
            #expect(refused(p), "\(p)")
            #expect(strictMarked(p[1]), "\(p[1])")
        }
        #expect(SafeText.optionRefusal(["Don't", "Don\u{2019}t"]) == .ambiguous)
        #expect(SafeText.optionRefusal(["Deploy - prod", "Deploy \u{2013} prod"]) == .ambiguous)
        #expect(SafeText.optionRefusal(["ok", "\u{043E}\u{043A}"]) != nil)
        #expect(SafeText.optionRefusal(["Deploy", "Dep\u{3163}oy"]) == .ambiguous)
        #expect(SafeText.optionRefusal(["Deploy", "Ship\u{3163}t"]) == .nonStandard)
    }

    @Test func finalRoundLeftovers() {
        // Stroked Latin-1 letters fold to their base letter, so these pairs are ambiguous.
        #expect(SafeText.optionRefusal(["Ok", "\u{00D8}k"]) == .ambiguous)      // Øk
        #expect(SafeText.optionRefusal(["Do it", "\u{00D0}o it"]) == .ambiguous) // Ðo it
        // Dotless i in an otherwise plain-ASCII word reads as "i" and is marked; in a Turkish word it is not.
        #expect(marked("Turn \u{0131}t on"))
        #expect(!marked("Kap\u{0131} a\u{00E7}\u{0131}k"))                     // Kapı açık
        // Superscript letter n is not a prose exemption.
        #expect(marked("2\u{207F} items"))
        #expect(!marked("10 m\u{00B2}"))
    }

    @Test func reviewSpoofsMarkedInProse() {
        let spoofs = [
            "\u{043E}\u{043A}",                                        // ок
            "\u{0455}\u{043A}\u{0456}\u{0440}",                        // ѕкір
            "\u{03BF}\u{03BA}",                                        // οκ
            "\u{2C9E}\u{2C94}",                                        // ⲞⲔ
            "\u{1D00}\u{1D18}\u{1D18}\u{0280}\u{1D0F}\u{1D20}\u{1D07}", // ᴀᴘᴘʀᴏᴠᴇ
            "\u{0280}\u{1D07}\u{1D0A}\u{1D07}\u{1D04}\u{1D1B}",        // ʀᴇᴊᴇᴄᴛ
            "\u{AB7A}\u{ABAF}\u{ABAF}\u{AB7C}\u{ABB2}\u{AB72}",        // ꭺꮯꮯꭼꮲꭲ (Cherokee small)
            "\u{0410}\u{0441}\u{0441}\u{0435}\u{0440}\u{0442}",        // Ассерт
            "\u{05DF}\u{05DF}",                                        // ןן
            "\u{0410}\u{0440}\u{0440}\u{04CF}\u{0443}\u{4E00}",        // Аррӏу一
            "\u{0410}\u{0440}\u{0440}\u{3163}\u{0443}",                // Аррㅣу
            "Dep\u{3163}oy",
            "\u{05E9} 10 20",
        ]
        for s in spoofs {
            #expect(marked(s), "\(s)")
            #expect(marked("Reply " + s + " to continue"), "in Latin context: \(s)")
            #expect(strictMarked(s), "as option label: \(s)")
        }
    }

    @Test func addingCJKNeverSuppressesMarking() {
        // Every letter of "Аррӏу一" is marked, the CJK one included.
        #expect(SafeText.markers(in: "\u{0410}\u{0440}\u{0440}\u{04CF}\u{0443}\u{4E00}").count == 6)
        #expect(SafeText.markers(in: "Dep\u{3163}oy") == ["⟨CJK U+3163⟩"])
        #expect(SafeText.markers(in: "Apply \u{30CE} now").count == 1)
        #expect(!SafeText.hasUnsafe("iPhone\u{7528}"))                 // iPhone用: CJK in a Latin word, not a look-alike
    }

    @Test func compatibilityAndInvisibleOptionLabelsRefused() {
        for spoof in ["\u{1D5A0}pprove", "\u{24B6}pprove", "Approve\u{00B2}", "\u{FF21}pprove", "Retry \u{0661}",
                      "Ap\u{200D}prove", "Approve\u{E0041}", "Approve\u{FE00}", "Ap\u{00AD}prove", "Approve\u{200B}"] {
            #expect(SafeText.optionRefusal(["Reject", spoof]) != nil, "\(spoof)")
            #expect(strictMarked(spoof), "\(spoof)")
            if spoof != "Approve\u{00B2}" { #expect(marked(spoof), "prose: \(spoof)") }   // "m²" is fine in prose
        }
    }

    @Test func plainOptionLabelsPass() {
        #expect(SafeText.optionRefusal(["Approve", "Reject"]) == nil)
        #expect(SafeText.optionRefusal(["Yes, ship it (v2.1)", "No - wait 10% / retry #3", "Don't & stop!"]) == nil)
        #expect(!strictMarked("Yes, ship it (v2.1)"))
    }

    @Test func localisedAnswerSetsAreRefusedForNow() {
        // D2: no single-script exception until a stricter test exists ("Сапсеӏ"/"Ассерт" and "вуе"/"Нет" qualified before).
        for set in [["\u{0414}\u{0430}", "\u{041D}\u{0435}\u{0442}"], ["\u{662F}", "\u{5426}"],
                    ["\u{0421}\u{0430}\u{043F}\u{0441}\u{0435}\u{04CF}", "\u{0410}\u{0441}\u{0441}\u{0435}\u{0440}\u{0442}"],
                    ["\u{0432}\u{0443}\u{0435}", "\u{041D}\u{0435}\u{0442}"], ["\u{05DB}\u{05DF}", "\u{05DC}\u{05D0}"]] {
            #expect(SafeText.optionRefusal(set) == .nonStandard, "\(set)")
            #expect(set.allSatisfy { strictMarked($0) })
        }
    }

    @Test func latin1LettersAllowedAccentsFoldInSkeleton() {
        #expect(SafeText.optionRefusal(["Übernehmen", "Später", "Señal", "Straße"]) == nil)
        #expect(!strictMarked("Übernehmen"))
        #expect(SafeText.optionRefusal(["Cafe", "Café"]) == .ambiguous)
        #expect(SafeText.optionRefusal(["Resume", "R\u{00E9}sum\u{00E9}"]) == .ambiguous)
        #expect(SafeText.optionRefusal(["2 × 3", "6"]) == .nonStandard)
        #expect(SafeText.optionRefusal(["6 ÷ 3", "6"]) == .nonStandard)
        #expect(SafeText.optionRefusal(["Yes", "No ~ maybe {x} [y] <z> `q` \\ ^ $ * = @ |"]) == nil)   // all printable ASCII
    }

    /// Scanner: "parser-differential / fail-open allowlist". The allowlist runs per scalar on the exact signed string.
    @Test func allowlistIsPerScalarNotPerGrapheme() {
        for spoof in ["o\u{0338}k", "Cafe\u{0301}", "A\u{20DD}pprove", "Yes\u{FE0F}", "OK\u{1F44D}\u{1F3FD}",
                      "Dev\u{1F468}\u{200D}\u{1F4BB}", "1\u{FE0F}\u{20E3}", "Approve\u{0300}", "\u{0041}\u{030A}"] {
            #expect(SafeText.optionRefusal([spoof, "Reject"]) == .nonStandard, "\(spoof.unicodeScalars.map { String($0.value, radix: 16) })")
            #expect(strictMarked(spoof))
        }
        // Swift String == is canonical equivalence: "Café" == "Cafe\u{301}". The check must not inherit it.
        #expect("Caf\u{00E9}" == "Cafe\u{0301}")
        #expect(SafeText.optionRefusal(["Caf\u{00E9}", "Reject"]) == nil)
        #expect(SafeText.optionRefusal(["Cafe\u{0301}", "Reject"]) == .nonStandard)
        #expect(SafeText.optionRefusal(["Caf\u{00E9}", "Cafe\u{0301}"]) != nil)
        // The marker names the exact combining scalar the signature covers.
        #expect(SafeText.markers(in: "Cafe\u{0301}", strictLabel: true) == ["⟨character U+0301⟩"])
    }

    @Test func refusalMessagesAndIdentifiers() {
        #expect(SafeText.OptionRefusal.nonStandard.message ==
                "This question's answers contain non-standard characters, so orch won't sign them here. Answer on your Mac, or ask the agent to use plain text.")
        #expect(SafeText.OptionRefusal.ambiguous.message == "Two answers look the same on this iPhone. Answer on your Mac.")
        #expect(SafeText.OptionRefusal.nonStandard.questionIdentifier == "question.nonStandard")
        #expect(SafeText.OptionRefusal.ambiguous.questionIdentifier == "question.ambiguous")
    }

    @Test func markersNeverChangeTheSignedText() {
        // Look-alike markers are inserted between pieces; the text pieces rebuild the exact signed scalars.
        for s in ["\u{0410}\u{0441}\u{0441}\u{0435}\u{0440}\u{0442}", "Dep\u{3163}oy", "Caf\u{00E9}", "Cafe\u{0301}",
                  "\u{2C9E}\u{2C94} \u{05E9} 10 20", "x\u{0430}\u{0301}pp \u{FF21} \u{212A}"] {
            for strict in [false, true] {
                let rebuilt = SafeText.pieces(s, strictLabel: strict).compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
                #expect(Array(rebuilt.unicodeScalars) == Array(s.unicodeScalars), "\(s) strict=\(strict)")
            }
        }
    }

    @Test func tunedProseFalsePositives() {
        #expect(!marked("Объединить PR 12?"))
        #expect(!marked("Area: 12 m², add ½ cup, orch™"))
        #expect(!marked("Dosya kap\u{0131}s\u{0131} a\u{00E7}\u{0131}k m\u{0131}?"))
        // RTL: only the words directly next to the digits are marked, not every RTL word on the line.
        #expect(SafeText.markers(in: "\u{0647}\u{0644} \u{0646}\u{0646}\u{0634}\u{0631} 12 \u{0627}\u{0644}\u{0622}\u{0646} \u{0631}\u{062C}\u{0627}\u{0621}").count == 2)
        #expect(!marked("\u{0647}\u{0644} \u{0646}\u{0646}\u{0634}\u{0631} \u{0627}\u{0644}\u{0622}\u{0646}"))
    }

    @Test func letterlikeAndHangulExtensions() {
        #expect(SafeText.markers(in: "\u{212A}eep") == ["⟨letterlike U+212A⟩"])
        #expect(marked("\u{2126}"))
        #expect(marked("Reply \u{212A} now"))
        #expect(SafeText.optionRefusal(["Keep", "\u{212A}eep"]) != nil)
        #expect(SafeText.markers(in: "\u{A960}\u{D7B0}", strictLabel: true) == ["⟨CJK U+A960⟩", "⟨CJK U+D7B0⟩"])
    }

    @Test func longHostTextStaysLinear() {
        let unit = "Approve \u{0430}pprove \u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{05E9} 10 \u{4E00}x "
        func build(_ sep: String) -> String {
            var s = ""
            while s.utf8.count < 64 * 1024 { s += unit + sep }
            return s
        }
        for text in [build(""), build("\n")] {
            let clock = ContinuousClock()
            let elapsed = clock.measure { _ = SafeText.pieces(text) }
            // Quadratic per-line scans took seconds here; linear is ~tens of ms even in debug. Generous bound for CI.
            #expect(elapsed < .seconds(2), "\(elapsed)")
            #expect(SafeText.hasUnsafe(text))
        }
    }

    @Test func ordinaryParagraphsStayUnmarked() {
        for s in [
            "Sollen wir die Änderungen übernehmen und den Build für morgen früh planen?",
            "Voulez-vous déployer la version corrigée maintenant ou attendre la revue ?",
            "Привет! Мы готовы выкатить сборку на сервер, ок? Ответ нужен до вечера.",
            "Γειά σου κόσμε, είναι έτοιμη η νέα έκδοση για δοκιμή;",
            "我们现在部署新版本吗？测试已经全部通过。",
            "هل نقوم بنشر الإصدار الجديد الآن؟",
        ] {
            #expect(!SafeText.hasUnsafe(s), "\(s): \(SafeText.markers(in: s))")
        }
    }
}
