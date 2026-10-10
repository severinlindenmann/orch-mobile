import CryptoKit
import Foundation
import Testing
import OrchClient
import OrchProtocol
@testable import OrchFakeHost

@Suite struct RotationInvariantTests {
    @Test(arguments: [false, true])
    func I1_gateBlocksData(replay: Bool) async throws {
        let w = try await World.make()
        await w.host.setHandler { _ in .response(status: 200, headers: [:], data: Data("secret".utf8)) }
        let (env, h) = try await w.sealedRequest(rid: .fresh(0x81))
        if replay { _ = await w.host.process(envelope: env, mailbox: h.rid) }
        await w.host.setPublishHook { throw TestCrash() }
        await #expect(throws: TestCrash.self) {
            try await w.host.rotate(remaining: [(w.phone, ["look", "decide"])], relay: w.relay, session: w.hostSession)
        }
        let chunks = await w.host.process(envelope: env, mailbox: h.rid)
        #expect(try openChunk(#require(chunks.first), wk: await w.host.wkFor(1)).data.isEmpty)
    }

    @Test(arguments: [1, 3])
    func I2_consistentCommit(failures: Int) async throws { try await recovery(failures: failures, removal: "none") }

    @Test(arguments: [1, 3])
    func I3_fetchedKeyIsNeverActivated(failures: Int) async throws { try await recovery(failures: failures, removal: "host") }

    @Test(arguments: ["host", "relay", "queued"])
    func I4_allRemovalSources(removal: String) async throws { try await recovery(failures: 1, removal: removal) }

    @Test(arguments: [false, true])
    func I5_serializedJoin(fail: Bool) async throws {
        let w = try await World.make()
        let gate = OpenGate(open: false), entered = OpenGate(open: false)
        let calls = Counter()
        await w.host.setPublishHook {
            calls.bump()
            await gate.pass()
            if fail { throw TestCrash() }
        }
        let remaining = [(w.phone, ["look", "decide"])]
        let first = Task { try await w.host.rotate(remaining: remaining, relay: w.relay, session: w.hostSession) }
        while gate.entered == 0 { await Task.yield() }
        let second = Task { try await w.host.invariantJoin(remaining, relay: w.relay, session: w.hostSession, entered: entered) }
        await entered.pass()
        gate.open()
        if fail {
            await #expect(throws: TestCrash.self) { try await first.value }
            await #expect(throws: TestCrash.self) { try await second.value }
        } else { try await first.value; try await second.value }
        #expect(calls.value == 1)
        #expect(await w.host.rotationRequired == fail)
    }

    @Test(arguments: [1, 3])
    func I6_pumpRetries(failures: Int) async throws { try await recovery(failures: failures, removal: "none") }

    @Test(arguments: ["host", "relay", "queued"])
    func I7_noSurvivingGrant(removal: String) async throws { try await recovery(failures: 1, removal: removal) }

    @Test(arguments: [false, true])
    func concurrentPublicRotationAndRevocation(fail: Bool) async throws {
        let w = try await World.make()
        _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession)
        let gate = OpenGate(open: false), entered = OpenGate(open: false)
        let calls = Counter()
        await w.host.setPublishHook {
            calls.bump()
            if calls.value == 1 {
                try await w.relay.putGrant(try await w.host.grant(for: w.phone, epoch: 2), token: w.hostSession.token)
                await gate.pass()
                if fail { throw TestCrash() }
            }
        }
        let record = try await w.primary.revoke(device: w.primaryID)
        let (env, h) = try await w.sealedRequest(rid: .fresh(0x82), meta: ["op": "revocation", "record": record])
        let rotation = Task {
            try await w.host.rotate(remaining: [(w.phone, ["look", "decide"]), (w.primary.deviceKeys, World.all)],
                                    relay: w.relay, session: w.hostSession)
        }
        while gate.entered == 0 { await Task.yield() }
        let revocation = Task { await w.host.invariantRevoke(env, rid: h.rid, entered: entered) }
        await entered.pass()
        gate.open()
        if fail { await #expect(throws: TestCrash.self) { try await rotation.value } }
        else { try await rotation.value }
        let chunks = await revocation.value
        let reply = try openChunk(#require(chunks.first), wk: await w.host.wkFor(1))
        if fail {
            #expect(reply.meta.object?["status"] == .int(200))
            #expect(try StrictJSON.parse(reply.data).object?["revoked"] == .bool(true))
        } else {
            #expect(reply.meta == HostRefusal.staleEpoch(epoch: 2).meta)
            let (retry, header) = try await w.sealedRequest(rid: .fresh(0x83), seq: 2, epoch: 2,
                meta: ["op": "revocation", "record": record])
            let retried = await w.host.process(envelope: retry, mailbox: header.rid)
            let completed = try openChunk(#require(retried.first), wk: await w.host.wkFor(2))
            #expect(completed.meta.object?["status"] == .int(200))
            #expect(try StrictJSON.parse(completed.data).object?["revoked"] == .bool(true))
        }
        _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession)
        #expect(await w.host.rotationRequired == false)
        #expect(await w.host.epoch == 3)
        #expect(await w.host.coreState().members[w.primaryID] == nil)
        #expect(await w.relay.hasGrant(workspace: w.ws, device: w.primaryID, epoch: 3) == false)
        #expect(await w.relay.hasGrant(workspace: w.ws, device: w.phoneID, epoch: 3))
        let list = try MemberList.verify(try await RelayClient(transport: w.transport).memberList(workspace: w.ws, session: w.phoneSession), wsk: w.host.wskPublic)
        #expect(list.epoch == 3)
        #expect(list.members.map(\.deviceID) == [w.phoneID])
    }

    @Test(arguments: ["host", "relay"])
    func fetchedGrantThenRealUploadFailure(revokeAt: String) async throws {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        faults.enqueue(.none, at: .beforeGrantPublication)
            .enqueue(.delay(.seconds(1)), at: .beforeGrantPublication)
        let rotation = Task {
            try await w.host.rotate(remaining: [(w.phone, ["look", "decide"]), (w.primary.deviceKeys, World.all)],
                                    relay: w.relay, session: w.hostSession)
        }
        while w.clock.sleeperCount == 0 { await Task.yield() }
        let grants = try await RelayClient(transport: w.transport).grants(workspace: w.ws, epoch: 2, session: w.phoneSession)
        let fetched = try WKGrant.open(#require(grants.first), wsk: w.host.wskPublic, workspace: w.ws,
                                       device: w.phoneID, deviceKey: w.env.device.kx)
        // Fail the suspended second upload through the relay's real target validation.
        try await w.relay.publishRevocation(try await w.primary.revoke(device: w.primaryID))
        w.clock.advance(milliseconds: 1000)
        await #expect(throws: (any Error).self) { try await rotation.value }
        #expect(await w.relay.hasGrant(workspace: w.ws, device: w.phoneID, epoch: 2) == false)
        if revokeAt == "host" { await w.host.markRevoked(w.phoneID) }
        else { try await w.relay.publishRevocation(try await w.primary.revoke(device: w.phoneID)) }
        _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession)
        let final = await w.host.epoch
        #expect(final == 3)
        #expect(await w.host.wkFor(final).withUnsafeBytes { Data($0) } != fetched.wk.withUnsafeBytes { Data($0) })
        #expect(await w.host.coreState().members.isEmpty)
        #expect(await w.relay.hasGrant(workspace: w.ws, device: w.phoneID, epoch: final) == false)
        #expect(await w.host.rotationRequired == false)
    }

    // Upload and fetch D's grant before failing the publication. This exercises the compromised-key
    // boundary even when the failure happens before the host's normal grant loop.
    private func recovery(failures: Int, removal: String) async throws {
        let w = try await World.make()
        let calls = Counter()
        let keys = CapturedRotationKeys()
        await w.host.setPublishHook {
            calls.bump()
            if calls.value <= failures {
                let e = UInt32(calls.value + 1)
                try await w.relay.putGrant(try await w.host.grant(for: w.phone, epoch: e), token: w.hostSession.token)
                let grants = try await RelayClient(transport: w.transport).grants(workspace: w.ws, epoch: e, session: w.phoneSession)
                let fetched = try WKGrant.open(#require(grants.first), wsk: w.host.wskPublic, workspace: w.ws,
                                               device: w.phoneID, deviceKey: w.env.device.kx)
                await keys.append(fetched.wk.withUnsafeBytes { Data($0) })
                throw TestCrash()
            }
        }
        let remaining = [(w.phone, ["look", "decide"]), (w.primary.deviceKeys, World.all)]
        await #expect(throws: TestCrash.self) {
            try await w.host.rotate(remaining: remaining, relay: w.relay, session: w.hostSession)
        }
        for attempt in 1...failures {
            #expect(await w.host.rotationRequired)
            #expect(await w.host.epoch == 1)
            #expect(await w.relay.hasGrant(workspace: w.ws, device: w.phoneID, epoch: UInt32(attempt + 1)) == false)
            if attempt < failures { _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession) }
        }
        if removal == "host" { await w.host.markRevoked(w.phoneID) }
        if removal == "relay" { try await w.relay.publishRevocation(try await w.primary.revoke(device: w.phoneID)) }
        if removal == "queued" {
            try await w.host.rotate(remaining: [(w.primary.deviceKeys, World.all)], relay: w.relay, session: w.hostSession)
        } else { _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession) }
        let final = await w.host.epoch
        #expect(final == UInt32(failures + 2))
        #expect(await w.host.rotationRequired == false)
        if removal == "none" {
            let list = try MemberList.verify(try await RelayClient(transport: w.transport).memberList(workspace: w.ws, session: w.phoneSession), wsk: w.host.wskPublic)
            #expect(list.epoch == final)
            #expect(Set(list.members.map(\.deviceID)) == Set([w.phoneID, w.primaryID]))
        }
        let key = await w.host.wkFor(final).withUnsafeBytes { Data($0) }
        #expect(await keys.values.count == failures)
        #expect(await keys.values.contains(key) == false)
        #expect(await w.host.coreState().epoch == final)
        #expect(await w.relay.hasGrant(workspace: w.ws, device: w.primaryID, epoch: final))
        #expect((await w.host.coreState().members[w.phoneID] != nil) == (removal == "none"))
        #expect(await w.relay.hasGrant(workspace: w.ws, device: w.phoneID, epoch: final) == (removal == "none"))
    }
}

private actor CapturedRotationKeys {
    var values: [Data] = []
    func append(_ value: Data) { values.append(value) }
}

extension FakeHost {
    fileprivate func invariantRevoke(_ envelope: Data, rid: ID16, entered: OpenGate) async -> [Data] {
        entered.open()
        return await process(envelope: envelope, mailbox: rid)
    }

    fileprivate func invariantJoin(_ remaining: [(DemoKeys, [String])], relay: FakeRelay,
                                   session: RelaySession, entered: OpenGate) async throws {
        entered.open()
        try await rotate(remaining: remaining, relay: relay, session: session)
    }
}
