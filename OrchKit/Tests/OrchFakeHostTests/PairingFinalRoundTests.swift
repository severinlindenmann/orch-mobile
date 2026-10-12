import Foundation
@testable import OrchCoordination
import Testing
import OrchClient
import OrchProtocol
import OrchStore
@testable import OrchClient
@testable import OrchFakeHost

@Suite struct PairingFinalRoundTests {
    @Test(arguments: ["install.begin", "install.container", "install.precommit"])
    func busyLockDuringInstallPreservesPairing(point: String) async throws {
        let h = try await PairHarness.make(.firstTime)
        try await h.driveToJoining()
        let before = try #require(h.pairingRecord)
        let dir = h.env.index.layout.tombstones.directories[0]
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = openCoordinationLock(dir.appendingPathComponent("tombstones.lock").path)
        #expect(fd >= 0)
        defer { flock(fd, LOCK_UN); close(fd) }
        try h.env.index.layout.prepareWorkspace(h.wsHex)
        let sentinel = try h.env.index.layout.wsDir(h.wsHex).appendingPathComponent("keep")
        try Data("keep".utf8).write(to: sentinel)
        await h.coordinator.setHook { name in
            if name == point { #expect(flock(fd, LOCK_EX | LOCK_NB) == 0) }
        }
        await h.coordinator.poll()
        #expect(await h.coordinator.state == .joining)
        #expect(h.pairingRecord == before)
        #expect(try await h.env.index.pairing(ws: h.wsHex)?.terminal == nil)
        #expect(try await h.env.index.pairing(ws: h.wsHex) != nil)
        #expect(try await h.env.index.workspaces().isEmpty)
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
        flock(fd, LOCK_UN)
        await h.coordinator.setHook { _ in }
        h.clock.advance(milliseconds: 2_001)
        await h.coordinator.poll()
        guard case .ready = await h.coordinator.state else {
            Issue.record("join did not succeed after lock release"); return
        }
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
        #expect(try await h.env.index.workspaces().count == 1)
        #expect(h.pairingRecord == nil)
    }

    @Test func unreadableTombstonesPreservePairing() async throws { try await checkTombstones(locked: false) }
    @Test func lockedTombstonesPreservePairing() async throws { try await checkTombstones(locked: true) }

    private func checkTombstones(locked: Bool) async throws {
        let h = try await PairHarness.make(.firstTime)
        _ = try await h.startToHostCode()
        let before = try #require(h.pairingRecord)
        let dir = h.env.index.layout.tombstones.directories[0]
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("tombstones.json")
        var fd: Int32 = -1
        if locked {
            fd = openCoordinationLock(dir.appendingPathComponent("tombstones.lock").path)
            #expect(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0)
        } else { try Data("unreadable JSON".utf8).write(to: file) }
        let c = h.fresh()
        #expect(await c.recover() == false)
        #expect(await c.resume(ws: h.host.workspace) == .failed(.custody))
        if locked { flock(fd, LOCK_UN); close(fd) }
        else { try Data("[]".utf8).write(to: file) }
        #expect(h.pairingRecord == before)
        #expect(try await h.env.index.pairing(ws: h.wsHex)?.terminal == nil)
        #expect(await c.resume(ws: h.host.workspace) == .connecting(origin: DemoRelay.origin))
        try h.env.index.layout.tombstones.write(TombstoneRecord(realm: "demo", ws: h.wsHex, generation: before.generation))
        _ = await h.fresh().resume(ws: h.host.workspace)
        #expect(h.pairingRecord == nil)
        #expect(try await h.env.index.pairing(ws: h.wsHex) == nil)
    }

    @Test(arguments: [31_536_000_000 as Int64, -31_536_000_000])
    func hostileYearOffsetIsRefused(offset: Int64) async throws {
        let h = try await PairHarness.make(.firstTime)
        let forge = PairForge(h: h, link: try h.link(try await h.rig.newOffer()))
        _ = await h.coordinator.start(link: forge.link)
        for _ in 0..<20 {
            try await forge.pump { _ in ["refusal": "stale_timestamp", "host_ms": .int(h.clock.nowMs + offset),
                "wsk_pub": .string(B64U.encode(h.host.wskPublic.x963))] }
            await h.coordinator.poll()
            if await h.coordinator.state.isTerminal { break }
            h.clock.advance(milliseconds: 1000)
        }
        #expect(await h.coordinator.state == .failed(.clockWrong))
        #expect(h.pairingRecord == nil)
    }

    @Test func laterSignedCorrectionCannotExtendChallenge() async throws {
        let h = try await PairHarness.make(.firstTime)
        let forge = PairForge(h: h, link: try h.link(try await h.rig.newOffer()))
        _ = await h.coordinator.start(link: forge.link)
        let ch = try await forge.challenge(nonce: forge.nonceA, expiresDelta: -500_000)      // after start: it names this attempt and its keys
        var seen = 0
        var first: Int64?
        for _ in 0..<40 {
            let k = seen
            seen += try await forge.pump { _ in
                if k == 0 { return forge.pending(nonce: forge.nonceA) }
                if k == 1 { return forge.certPending(challenge: ch) }
                return ["refusal": "stale_timestamp", "host_ms": .int(h.clock.nowMs - 3_600_000),
                        "wsk_pub": .string(B64U.encode(h.host.wskPublic.x963))]
            }
            await h.coordinator.poll()
            if case .comparingPrimary(_, _, let exp) = await h.coordinator.state {
                if first == nil { first = exp }
                #expect(exp == first)
            }
            if (h.pairingRecord?.offsetMs ?? 0) < 0 { break }
            h.clock.advance(milliseconds: 1000)
        }
        let end = try #require(first)
        #expect((-3_610_000 ... -3_600_000).contains(h.pairingRecord?.offsetMs ?? 0))
        h.clock.advance(milliseconds: end - h.clock.nowMs)
        guard case .waitingPrimary(_, let deadline, let expired) = await h.coordinator.state else {
            Issue.record("challenge remained visible past its original deadline"); return
        }
        #expect(expired && deadline == end)
    }

    struct FrozenWall: WallClock { let nowMs: Int64 }

    @Test func firstAnswerCapUsesMonotonicTime() async throws {
        let h = try await PairHarness.make(.firstTime)
        var cfg = h.config
        cfg.wall = FrozenWall(nowMs: h.clock.nowMs)
        let c = PairingCoordinator(cfg)
        _ = await c.start(link: try h.link(try await h.rig.newOffer()))
        h.clock.advance(milliseconds: 60_000)
        await c.poll()
        #expect(await c.state == .failed(.linkUsed))
        #expect(h.pairingRecord == nil)
    }
    @Test(arguments: ["preApproval", "certPending", "joinAttempt", "joinRetry"])
    func remainingCapsUseMonotonicTime(stage: String) async throws {
        let h = try await PairHarness.make(.firstTime)
        _ = try await h.startToHostCode()
        if stage == "certPending" {
            try await h.hostApproves()
            _ = try await h.drive(until: isComparingPrimary)
        } else if stage.hasPrefix("join") {
            try await h.hostApproves()
            _ = try await h.drive(until: isComparingPrimary)
            try await h.primaryApproves()
            try await h.driveToJoining0()
        }
        var cfg = h.config
        cfg.wall = FrozenWall(nowMs: h.clock.nowMs)
        let c = PairingCoordinator(cfg)
        _ = await c.resume(ws: h.host.workspace)
        h.clock.advance(milliseconds: stage == "joinAttempt" ? 60_000 : 660_000)
        await c.poll()
        let expected: PairingState = switch stage {
        case "preApproval": .expired(.beforeApproval)
        case "certPending": .expired(.certification)
        case "joinAttempt": .failed(.joiningTimedOut)
        default: .expired(.afterApproval)
        }
        #expect(await c.state == expected)
    }

    @Test(arguments: [60_000 as Int64, 600_000])
    func joinCannotCommitAfterDeadlineDuringInstall(delay: Int64) async throws {
        let h = try await PairHarness.make(.firstTime)
        try await h.driveToJoining()
        let clock = h.clock
        await h.coordinator.setHook { name in
            if name == "install.precommit" { clock.advance(milliseconds: delay) }
        }
        await h.coordinator.poll()
        #expect(await h.coordinator.state == (delay == 60_000 ? .failed(.joiningTimedOut) : .expired(.afterApproval)))
        #expect(try await h.env.index.workspaces().isEmpty)
        if delay == 60_000 { #expect(h.pairingRecord?.approved != nil) }
    }

}
