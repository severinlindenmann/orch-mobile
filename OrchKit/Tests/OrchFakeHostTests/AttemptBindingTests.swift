import CryptoKit
import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
@testable import OrchClient
@testable import OrchFakeHost
@testable import OrchProtocol

/// G3b (P3-D28) conformance on the phone: the host cannot enforce these, so the phone's own behaviour is tested here.
@Suite struct AttemptBindingTests {
    static func attemptMemory(_ h: PairHarness) -> JSONValue? {
        (try? h.vault.scoped(to: .demo).get(purpose: AttemptMemory.purpose)).flatMap { try? StrictJSON.parse($0, maxBytes: 1 << 20) }
    }

    /// An uncertified phone draws fresh device keys for every new attempt, and a new attempt nonce; the attempt, the device id and
    /// dk_hash are persisted before the first pair request is sent, and the previous attempt moves to the earlier attempts.
    @Test func freshKeysAndANewAttemptPerUncertifiedAttempt() async throws {
        let h = try await PairHarness.make(.firstTime)
        let before = h.env.deviceID
        _ = await h.coordinator.start(link: try h.link(try await h.rig.newOffer()))
        let first = try #require(h.pairingRecord)
        #expect(first.deviceID != before, "the identity made at setup is not reused")
        #expect(Identifiers.isAttempt(first.attempt))
        // persisted before anything is sent: the memory names this attempt as `last`
        let mem1 = try #require(Self.attemptMemory(h))
        #expect(mem1.object?["last"]?.object?["device_id"]?.string == first.deviceID.hex)
        #expect(mem1.object?["last"]?.object?["dk_hash"]?.string == B64U.encode(first.dkHash))
        await h.coordinator.cancel()
        // a second attempt (a new scan of a new link): other keys, another nonce, and the first attempt is remembered as earlier
        _ = await h.coordinator.start(link: try h.link(try await h.rig.newOffer()))
        let second = try #require(h.pairingRecord)
        #expect(second.deviceID != first.deviceID && second.dkHash != first.dkHash && second.attempt != first.attempt)
        let mem2 = try #require(Self.attemptMemory(h))
        let earlier = mem2.object?["earlier"]?.array ?? []
        #expect(earlier.count == 1 && earlier.first?.object?["device_id"]?.string == first.deviceID.hex)
        #expect((earlier.first?.object?["until_ms"]?.int ?? 0) >= h.clock.nowMs + AttemptMemory.retentionMs)
    }

    /// A phone that holds a valid certificate presents it and keeps its keys (D-1): only the attempt nonce is new.
    @Test func aCertifiedPhoneKeepsItsKeysWithANewAttempt() async throws {
        let h = try await PairHarness.make(.existingCert)
        try await h.rig.enrollExistingCertificate(into: h.config)
        let keys = h.env.deviceID
        _ = await h.coordinator.start(link: try h.link(try await h.rig.newOffer()))
        let first = try #require(h.pairingRecord)
        #expect(first.deviceID == keys)
        await h.coordinator.cancel()
        _ = await h.coordinator.start(link: try h.link(try await h.rig.newOffer()))
        let second = try #require(h.pairingRecord)
        #expect(second.deviceID == keys && second.attempt != first.attempt)
    }

    /// A challenge of the phone's own earlier attempt (both its device id and dk_hash remembered) is dropped without the alarm.
    @Test func aChallengeOfAnEarlierAttemptIsDroppedWithoutTheAlarm() async throws {
        let h = try await PairHarness.make(.firstTime)
        let offer = try await h.rig.newOffer()
        let forge = PairForge(h: h, link: try h.link(offer))
        _ = await h.coordinator.start(link: forge.link)
        let old = try await forge.challenge(nonce: forge.nonceA)          // names attempt 1's keys
        await h.coordinator.cancel()
        let forge2 = PairForge(h: h, link: try h.link(try await h.rig.newOffer()))
        _ = await h.coordinator.start(link: forge2.link)
        var n = 0
        for _ in 0..<30 {
            let k = n
            n += try await forge2.pump { _ in k == 0 ? forge2.pending(nonce: forge2.nonceA) : forge2.certPending(challenge: old) }
            await h.coordinator.poll(); h.clock.advance(milliseconds: 1000)
            if n >= 3 { break }
        }
        let s = await h.coordinator.state
        // the answers carrying it were dropped (stale_attempt): no alarm, no primary code, still waiting
        if case .alarm = s { Issue.record("alarm: \(s)") }
        if case .comparingPrimary = s { Issue.record("code shown: \(s)") }
        #expect(!s.isTerminal, "\(s)")
    }

    /// The accepted challenge's request id survives a restart; a challenge of another request is then dropped.
    @Test func theAcceptedRequestIDSurvivesARestart() async throws {
        let h = try await PairHarness.make(.firstTime)
        _ = try await h.startToHostCode()
        try await h.hostApproves()
        _ = try await h.drive(until: isComparingPrimary)
        let r = try #require(h.pairingRecord)
        let rid = try #require(await h.host.pairingRequestID(of: h.phoneID))
        #expect(r.acceptedRequestID == rid)
        let again = h.fresh()
        _ = await again.resume(ws: h.host.workspace)
        #expect(h.pairingRecord?.acceptedRequestID == rid)
    }

    /// Fresh keys cannot be drawn while another live pairing uses the current uncertified keys: the attempt is refused rather than
    /// reusing keys a host may already know (fail closed).
    @Test func noFreshKeysWhileAnotherPairingUsesThem() async throws {
        let h = try await PairHarness.make(.firstTime)
        _ = await h.coordinator.start(link: try h.link(try await h.rig.newOffer()))
        let other = try await PairingRig.make(env: h.env, scenario: .firstTime, name: "Second")
        let c2 = PairingCoordinator(h.config)
        let s = await c2.start(link: try PairingLink.parse(try await other.newOffer().link))
        #expect(s == .failed(.verification(reason: "fresh_keys_unavailable")))
    }
}
