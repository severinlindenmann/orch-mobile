import Foundation
import OrchTestVectors
import Testing
@testable import OrchProtocol

/// Replays the custodial vectors the phone implements (`prepared_*`, `built_*`, `render_*`) and the allow-list and facts of design B3.
@Suite struct HubSignVectorTests {
    @Test func theFileHasTheCasesWeReplay() {
        #expect(HubVectors.cases("prepared").count == 5)
        #expect(HubVectors.cases("built").count == 5)
        #expect(HubVectors.cases("render").count == 3)
    }

    @Test func preparedCases() {
        for c in HubVectors.cases("prepared") {
            let a = c["args"]
            var digest: Data?
            let err = HubVectors.run(c) { digest = try HubSign.checkPrepared(ctx: a["ctx"], digestHex: a["digest_hex"].str) }
            #expect(err == HubVectors.errorCode(c), "\(c["name"].str)")
            if HubVectors.errorCode(c) == nil { #expect(digest.map(Hex.encode) == c["expect"]["ok"]["digest_hex"].str, "\(c["name"].str)") }
        }
    }

    @Test func builtCases() {
        for c in HubVectors.cases("built") {
            let a = c["args"]
            let err = HubVectors.run(c) { try HubSign.checkBuilt(action: a["action"], log: a["log"].str, event: a["event"]) }
            #expect(err == HubVectors.errorCode(c), "\(c["name"].str)")
        }
    }

    @Test func renderCases() {
        for c in HubVectors.cases("render") {
            #expect(HubSign.renderText(c["args"]["text"].str) == c["expect"]["ok"]["shown"].str, "\(c["name"].str)")
        }
    }

    @Test func digestIsTheVectorsDigest() throws {
        let p = HubVectors.root["phase4"]["prepare"]
        #expect(Hex.encode(try HubSign.digest(ofContext: p["ctx"])) == p["digest_hex"].str)
    }

    @Test func renderEscapesTheRefusedCharactersAndKeepsLF() {
        #expect(HubSign.renderText("a\tb") == "a<U+0009>b")            // TAB is a control character: refused by the 8.5 rule
        #expect(HubSign.renderText("a\u{85}b") == "a<U+0085>b")         // C1
        #expect(HubSign.renderText("x\u{200B}y") == "x<U+200B>y")       // format (zero width space)
        #expect(HubSign.renderText("x\u{2028}y") == "x<U+2028>y")       // line separator
        #expect(HubSign.renderText("x\u{FE0F}y") == "x<U+FE0F>y")       // variation selector (default ignorable)
        #expect(HubSign.renderText("x\u{E000}y") == "x<U+E000>y")       // private use
        #expect(HubSign.renderText("x\u{0378}y") == "x<U+0378>y")       // unassigned
        #expect(HubSign.renderText("Grüße 日本 ✓\nzwei") == "Grüße 日本 ✓\nzwei")
    }

    @Test func shortHashIsTwelveHexInGroupsOfFour() {
        #expect(HubSign.shortHash("sha256:3d3f5e93357cf4b89511c728d2d7995ebc233f435574ef9b95de0259f3247987") == "3d3f 5e93 3574")
        #expect(HubSign.shortHash("sha256:3D3F") == nil)
        #expect(HubSign.shortHash("md5:3d3f5e93357cf4b89511c728d2d7995ebc233f435574ef9b95de0259f3247987") == nil)
    }
}
