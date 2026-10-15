import CryptoKit
import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
import OrchStore
@testable import OrchClient
@testable import OrchFakeHost
@testable import OrchProtocol

actor Flag { var v = false; func set() { v = true } }

@Suite struct SecReviewTests {
    // A1: after joiningTimedOut, run() never sleeps: does cancel() still get into the actor?
    @Test func secRunLoopAfterJoiningTimeout() async throws {
        let o = try await PairHarness.make(.firstTime)
        await o.host.setHostile { $0.omitFromList = true }
        #expect(try await o.completeFirstTime() == .failed(.joiningTimedOut))
        let runner = Task { await o.coordinator.run() }
        let done = Flag()
        let canceller = Task { await o.coordinator.cancel(); await done.set() }
        let cancelledInTime = await eventually("cancel() completes while run() is active", timeoutSeconds: 60) { await done.v }
        print("SEC A1: cancel completed within 60s while run() active: \(cancelledInTime)")
        runner.cancel()
        _ = await canceller.value
        print("SEC A1: after runner.cancel, vault items: \(o.vaultItems.map(\.purpose))")
        #expect(cancelledInTime, "run() spins on the actor after joiningTimedOut; cancel() starves")
    }

    // A2: secret retention after joiningTimedOut (no run loop): S stays in the vault indefinitely
    @Test func secSecretRetainedAfterJoinTimeout() async throws {
        let o = try await PairHarness.make(.firstTime)
        await o.host.setHostile { $0.omitFromList = true }
        #expect(try await o.completeFirstTime() == .failed(.joiningTimedOut))
        o.clock.advance(milliseconds: 7 * 24 * 3600 * 1000)
        await o.coordinator.poll()
        print("SEC A2: state after 7 days: \(await o.coordinator.state); vault: \(o.vaultItems.map(\.purpose))")
        #expect(!o.vaultItems.contains { $0.purpose == "pairing" }, "pending secret retained indefinitely after joiningTimedOut")
    }

    // A3: cancel racing the join commit
    @Test func secCancelRacesCommit() async throws {
        var bad = 0, runs = 0
        for k in [0, 1, 2, 3, 5, 8, 12, 16, 20, 25, 30, 40, 50, 60, 80, 100, 130, 160, 200, 300] {
            let h = try await PairHarness.make(.firstTime)
            _ = try await h.startToHostCode()
            try await h.hostApproves()
            _ = try await h.drive(until: isComparingPrimary)
            try await h.primaryApproves()
            _ = try await h.drive(steps: 40, until: { $0 == .joining || $0.isTerminal })
            guard await h.coordinator.state == .joining else { continue }
            runs += 1
            let p = Task { await h.coordinator.poll() }
            for _ in 0..<k { await Task.yield() }
            await h.coordinator.cancel()
            await p.value
            let s = await h.coordinator.state
            let ws = try await h.env.index.workspaces()
            let items = h.vaultItems.map(\.purpose)
            if case .cancelled = s, !ws.isEmpty { bad += 1; print("SEC A3 k=\(k): cancelled but committed workspace; vault=\(items)") }
            if isReady(s) && !items.contains("wk.1") { bad += 1; print("SEC A3 k=\(k): ready without WK; vault=\(items)") }
        }
        print("SEC A3: runs=\(runs) inconsistent=\(bad)")
        #expect(bad == 0)
    }

    // A4: link parsing table
    @Test func secLinkParsing() throws {
        let ws = String(repeating: "a", count: 32), of = String(repeating: "b", count: 32)
        let p = B64U.encode(Data(repeating: 7, count: 32))
        let frag = "v2.\(ws).\(of).\(p).\(p).\(p)"
        let cases: [(String, Bool)] = [
            ("https://relay.example/app/pair#\(frag)", true),
            ("https://relay.example/pair#\(frag)", true),
            ("https://relay.example:443/app/pair#\(frag)", true),
            ("HTTPS://relay.example/app/pair#\(frag)", false),
            ("https://Relay.example/app/pair#\(frag)", false),
            ("https://relay.example/app/pair/#\(frag)", false),
            ("https://relay.example/app/pair?x=1#\(frag)", false),
            ("https://u@relay.example/app/pair#\(frag)", false),
            ("https://relay.example/app/pair#\(frag).x", false),
            ("https://relay.example/app/pair##\(frag)", false),
            ("https://relay.example/app/pair#\(frag.uppercased())", false),
            ("https://1.2.3.4/app/pair#\(frag)", false),
            ("orch://pair?relay=https%3A%2F%2Frelay.example#\(frag)", true),
            ("orch://pair?relay=https%3a%2f%2frelay.example#\(frag)", true),
            ("orch://pair?relay=https%3A%2F%2Frelay.example%2Fx#\(frag)", false),
            ("orch://pair?relay=https%3A%2F%2Frelay.example&relay=https%3A%2F%2Fevil.example#\(frag)", false),
            ("orch://pair?relay=https%3A%2F%2Fu%40relay.example#\(frag)", false),
            ("orch://pair#\(frag)", false),
            ("orch://pair?relay=https://relay.example#\(frag)", true),
            ("orch://pair?relay=https%3A%2F%2Frelay.example%23#\(frag)", false),
            ("orch://pair?relay=http%3A%2F%2Flocalhost%3A8080#\(frag)", true),
            ("https://xn--rlay-ira.example/app/pair#\(frag)", true),
        ]
        for (s, ok) in cases {
            let r = try? PairingLink.parse(s)
            if (r != nil) != ok { Issue.record("parse mismatch for \(s): got \(String(describing: r))") }
            if let r { #expect(!"\(r)".contains(p) && !String(reflecting: r).contains(p)); var d = ""; dump(r, to: &d); #expect(!d.contains(p)) }
        }
    }
}
