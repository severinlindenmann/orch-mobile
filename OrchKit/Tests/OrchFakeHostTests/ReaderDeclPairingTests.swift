import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
@testable import OrchClient
@testable import OrchFakeHost
@testable import OrchProtocol

/// H12d on the phone's pairing path: pair meta v2 (`reader_decl`, protocol 8.3), its persistence with the attempt, and the reader state
/// written at the join (host 9.3, 9.5; 11A.15.6 step 4).
@Suite struct ReaderDeclPairingTests {
    static let build = "1.0 (7)"
    static func harness(capability: ReaderKAT.Capability?? = nil, scenario: PairingScenario = .firstTime) async throws -> PairHarness {
        try await PairHarness.make(scenario, reader: ReaderRuntime(capability: capability ?? ReaderKAT.current, build: build))
    }

    @Test func pairMetaV2CarriesAVerifiableDeclarationBoundToTheAttempt() async throws {
        let h = try await Self.harness()
        let (offer, _) = try await h.startToHostCode()
        let rec = try #require(h.pairingRecord)
        let decl = try #require(rec.readerDecl)
        let (hostDecl, verdict) = try #require(await h.host.pairingReaderDecl(of: rec.deviceID))
        #expect(hostDecl == decl.json)                                         // verbatim
        #expect(verdict == .success(1))
        let o = try #require(decl.json.object?["o"]?.object)
        #expect(o["bind"] == ["via": "pair", "offer_id": .string(offer.offerID.hex), "attempt": .string(rec.attempt)])
        #expect(o["who"] == ["pk_pin": .string(B64U.encode(rec.pkPin))])        // no certificate: the link's pk_pin
        #expect(o["workspace_id"] == .string(rec.ws.hex) && o["device_id"] == .string(rec.deviceID.hex))
        #expect(o["kat"] == ["1": ["view": .string(ReaderKAT.expectedView1)]])
        #expect(decl.level == 1)
    }

    @Test func aCertifiedPhoneDeclaresItsPerson() async throws {
        let h = try await Self.harness(scenario: .existingCert)
        try await h.rig.enrollExistingCertificate(into: h.config)
        _ = await h.coordinator.start(link: try h.link(try await h.rig.newOffer()))
        await h.coordinator.poll()
        _ = try await h.drive(steps: 20, until: { _ in false })
        let rec = try #require(h.pairingRecord)
        let o = try #require(rec.readerDecl?.json.object?["o"]?.object)
        let who = try #require(o["who"]?.object?["person_id"]?.string)
        #expect(who == Identifiers.personID(await h.primary.publicKey).hex)
        let (_, verdict) = try #require(await h.host.pairingReaderDecl(of: rec.deviceID))
        #expect(verdict == .success(1))
    }

    @Test func theDeclarationIsPersistedWithTheAttemptAndResendsAreByteIdentical() async throws {
        let h = try await Self.harness()
        _ = try await h.startToHostCode()
        let first = try #require(h.pairingRecord)
        let bytes = try #require(first.readerDecl?.bytes)
        // encode/decode keeps the exact canonical bytes
        let again = try #require(PairingRecord.decode(try first.encode()))
        #expect(again.readerDecl?.bytes == bytes && again.readerDecl?.digest == first.readerDecl?.digest)
        // a restarted coordinator resumes with the stored declaration; the host's first stored declaration stays
        let before = try #require(await h.host.pairingReaderDecl(of: first.deviceID)).decl
        let restarted = PairingCoordinator(h.config)
        _ = await restarted.resume(ws: h.host.workspace)
        await restarted.poll()
        h.clock.advance(milliseconds: 20_000)
        await restarted.poll()
        let after = try #require(PairingRecord.decode(try h.vault.scoped(to: .demo).get(ws: h.host.workspace.hex, purpose: "pairing")))
        #expect(after.readerDecl?.bytes == bytes)
        #expect(try #require(await h.host.pairingReaderDecl(of: first.deviceID)).decl == before)
    }

    @Test func aBuildWhoseKATFailedSendsTheSixFieldMetaAndDeclaresNothing() async throws {
        let h = try await Self.harness(capability: .some(nil))
        _ = try await h.startToHostCode()
        let rec = try #require(h.pairingRecord)
        #expect(rec.readerDecl == nil)
        #expect(await h.host.pairingReaderDecl(of: rec.deviceID) == nil)
    }

    @Test func theJoinStoresTheDeclarationAndTheHighestLevelInTheKeysVault() async throws {
        let h = try await Self.harness()
        _ = try await h.startToHostCode()
        let decl = try #require(h.pairingRecord?.readerDecl)
        try await h.hostApproves()
        guard case .comparingPrimary = try await h.drive(until: isComparingPrimary) else { Issue.record("not comparingPrimary"); return }
        try await h.primaryApproves()
        let end = try await h.drive(until: { $0.isTerminal })
        guard case .ready = end else { Issue.record("\(end)"); return }
        let st = try #require(try ReaderStore.load(h.vault.scoped(to: .demo), ws: h.host.workspace))
        #expect(st.highest == 1 && st.decl?.bytes == decl.bytes && st.acked && st.build == Self.build)
        #expect(ReaderGate.rd(st) == decl.digest)
        // it lives in the `.keys` group beside the device keys, under the workspace's tag
        #expect(h.vaultItems.contains { $0.purpose == "reader.state" })
    }

    @Test func aNoDeclarationBuildStoresLevelZero() async throws {
        let h = try await Self.harness(capability: .some(nil))
        try await h.completeFirstTime()
        let st = try #require(try ReaderStore.load(h.vault.scoped(to: .demo), ws: h.host.workspace))
        #expect(st.highest == 0 && st.decl == nil)
        #expect(ReaderGate.rd(st) == nil)
    }
}
