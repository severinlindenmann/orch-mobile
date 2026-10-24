import Foundation
import Testing

/// Source-scan guard for the wipe barrier (design B6, L2-B6d-1; like B3's proof-caller test). The rule lives in `HubWorkBarrier.swift`: every
/// write of hub-scoped state takes a `HubWorkToken`. The compiler enforces it for the custody writes and the replay record (the token is a
/// required parameter); these scans keep it from being defeated: no `.unguarded` outside the allowed files, no write that bypasses the custody
/// methods, no new `func put/create/publish` in the custody without a token.
@Suite(.timeLimit(.minutes(2))) struct HubWorkBarrierGuardTests {
    /// OrchKit/Tests/OrchClientTests/<this file> -> the repo root.
    static let root: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    static let writers = ["createChannelKey", "createPushKey", "putSessionToken", "putRecord", "putPushState", "publishPushMaterial", "putBiometryBaseline"]

    /// Production Swift sources (never tests).
    static func sources() -> [(path: String, text: String)] {
        var out: [(String, String)] = []
        for dir in ["OrchKit/Sources", "App", "NotificationService"] {
            let base = root.appendingPathComponent(dir)
            guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let u as URL in e where u.pathExtension == "swift" {
                if let t = try? String(contentsOf: u, encoding: .utf8) { out.append((String(u.path.dropFirst(root.path.count + 1)), t)) }
            }
        }
        return out
    }

    /// Every call `.name(` ... balanced `)` in `text`.
    static func calls(_ names: [String], in text: String) -> [String] {
        let chars = Array(text)
        var found: [String] = []
        for n in names {
            var from = text.startIndex
            while let r = text.range(of: "." + n + "(", range: from..<text.endIndex) {
                var depth = 1
                var i = r.upperBound
                while i < text.endIndex, depth > 0 { if text[i] == "(" { depth += 1 } else if text[i] == ")" { depth -= 1 }; i = text.index(after: i) }
                found.append(String(text[r.lowerBound..<i]))
                from = i
            }
        }
        _ = chars
        return found
    }

    @Test func theScanSeesTheSources() {
        let s = Self.sources()
        #expect(s.contains { $0.path.hasSuffix("HubKeyCustody.swift") } && s.contains { $0.path.hasSuffix("HubWorkBarrier.swift") })
        #expect(s.contains { $0.path.hasPrefix("App/Hub/") })
    }

    @Test func everyCustodyWriteRequiresAToken() throws {
        let t = try #require(Self.sources().first { $0.path.hasSuffix("OrchCustody/HubKeyCustody.swift") }).text
        let decls = t.split(separator: "\n").filter {
            let l = $0.trimmingCharacters(in: .whitespaces)
            return (l.hasPrefix("public func ") || l.hasPrefix("package func ") || l.hasPrefix("func ")) &&
                (l.contains("func put") || l.contains("func create") || l.contains("func publish"))
        }
        #expect(decls.count >= Self.writers.count)
        for d in decls { #expect(d.contains("work: HubWorkToken"), "a custody write without the wipe barrier: \(d)") }
        // and each one runs its vault write inside `work.perform`
        for w in Self.writers {
            let i = try #require(t.range(of: "func \(w)("))
            let body = t[i.lowerBound...].prefix(1400)
            #expect(body.contains("work.perform"), "\(w) does not write under the barrier")
        }
    }

    @Test func everyCallerOfAWriterPassesARealToken() {
        for (path, text) in Self.sources() where !path.hasSuffix("HubKeyCustody.swift") {
            for c in Self.calls(Self.writers, in: text) {
                #expect(c.contains("work:") && !c.contains(".unguarded"), "\(path): write without a real wipe token: \(c.prefix(90))")
            }
        }
    }

    @Test func theReplayRecordIsWrittenUnderTheBarrier() throws {
        for (path, text) in Self.sources() {
            for c in Self.calls(["accept"], in: text) where c.contains("material:") {
                if path.hasSuffix("OrchPush/PushHandler.swift") { #expect(c.contains(".unguarded")); continue }   // the extension: no session
                #expect(c.contains("work:") && !c.contains(".unguarded"), "\(path): replay write without a wipe token")
            }
        }
        let intake = try #require(Self.sources().first { $0.path.hasSuffix("OrchPush/HubPush.swift") }).text
        let accept = try #require(intake.range(of: "public func accept("))
        #expect(intake[accept.lowerBound...].prefix(2400).contains("work.perform { try store.transact"))
    }

    @Test func theWipeIsNeverOptional() {
        // a component built without a wipe would write without a barrier; the configs and coordinators take `wipe: HubWipe`, never `HubWipe?`
        for (path, text) in Self.sources() {
            #expect(!text.contains("HubWipe?") && !text.contains("wipe: HubWipe? "), "\(path) has an optional wipe")
            #expect(!text.contains("HubWipe.workToken(cfg") && !text.contains("workToken(nil"), "\(path) asks for a token without a wipe")
        }
    }

    @Test func theCacheIsWrittenOnlyThroughAToken() {
        for (path, text) in Self.sources() {
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where line.contains("cache.write(") || line.contains(".cache.write(") {
                #expect(line.contains("work.perform"), "\(path):\(n + 1) writes the hub cache without the wipe barrier")
            }
            // the store itself is only written by the coordinator above (FileHubCache/InMemoryHubCache define `write`, they never call it)
            if !path.hasSuffix("OrchClient/HubCache.swift") { #expect(!text.contains("FileHubCache(directory:") || path.hasPrefix("App/"), "\(path) builds a cache store") }
        }
    }

    @Test func theUnguardedTokenExistsOnlyWhereItIsAllowed() {
        for (path, text) in Self.sources() where text.contains(".unguarded") {
            let ok = path.hasSuffix("OrchPush/HubWorkBarrier.swift") || path.hasSuffix("OrchPush/PushHandler.swift")
                || path.hasSuffix("OrchPush/HubPush.swift")         // a comment: the extension's replay write
            #expect(ok, "\(path) uses HubWorkToken.unguarded")
        }
    }

    @Test func nothingBesidesTheCustodyAndTheIntakeWritesHubStateDirectly() {
        for (path, text) in Self.sources() {
            let custody = path.hasSuffix("HubKeyCustody.swift") || path.hasSuffix("SecretVault.swift") || path.hasSuffix("HubPushMaterial.swift")
                || path.hasSuffix("OrchPush/HubPush.swift")         // the extension's read-only reader of the item
                || path.hasSuffix("App/Push/PushHarness.swift")     // DEBUG-only NSE test harness: installs a fixture into the real `.push` group (never in Release)
            if !custody {
                #expect(!text.contains("purpose: \"hub."), "\(path) names a hub.* vault item itself")
                #expect(!text.contains("HubPushMaterial.purpose"), "\(path) names the hub push material item itself")
            }
            // the `state/hub/` replay store is built only by the intake (which takes the token)
            if !path.hasSuffix("OrchPush/HubPush.swift") { #expect(!text.contains("realm: HubPushIntake.realm") && !text.contains("realm: \"hub\""), "\(path)") }
        }
    }

    @Test func everyHubComponentTakesATokenBeforeItsWork() throws {
        let src = Dictionary(uniqueKeysWithValues: Self.sources().map { ($0.path, $0.text) })
        func text(_ suffix: String) throws -> String { try #require(src.first { $0.key.hasSuffix(suffix) }).value }
        #expect(try text("OrchClient/HubPairing.swift").contains("cfg.wipe.workToken()"))
        #expect(try text("OrchClient/HubHome.swift").contains("wipe.workToken()"))
        #expect(try text("OrchClient/HubPush.swift").contains("cfg.wipe.workToken()"))
        #expect(try text("OrchClient/HubSigning.swift").contains("cfg.wipe.workToken()"))
        #expect(try text("App/Hub/HubPushDriver.swift").contains("runtime.wipe.workToken()"))
        // nobody asks "is a wipe pending?" instead of holding a token (the per-component check this barrier replaced)
        for suffix in ["OrchClient/HubPairing.swift", "OrchClient/HubPush.swift", "OrchClient/HubSigning.swift"] {
            let t = try text(suffix)
            #expect(!t.contains("wipe?.pending") && !t.contains("wipe.pending"), "\(suffix) tests pending instead of holding a token")
        }
    }
}
