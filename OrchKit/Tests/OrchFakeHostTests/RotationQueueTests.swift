import Foundation
import Testing
import OrchClient
import OrchProtocol
@testable import OrchFakeHost

extension FakeHost {
    // Signals from the host actor immediately before enqueueing, with no intervening suspension.
    fileprivate func signalledRotate(_ remaining: [(DemoKeys, [String])], relay: FakeRelay,
                                    session: RelaySession, entered: OpenGate) async throws {
        entered.open()
        try await rotate(remaining: remaining, relay: relay, session: session)
    }
}

@Suite struct RotationQueueTests {
    @Test(arguments: ["relay", "host", "both"])
    func retryFiltersRevokedDevicesAndCoalescesRosters(revokedAt: String) async throws {
        let w = try await World.make()
        let publication = OpenGate(open: false), entered = OpenGate(open: false)
        let calls = Counter()
        await w.host.setPublishHook {
            calls.bump()
            await publication.pass()
            if calls.value == 1 { throw TestCrash() }
        }
        let first = Task {
            try await w.host.rotate(remaining: [(w.primary.deviceKeys, World.all), (w.phone, ["look", "decide"])],
                                    relay: w.relay, session: w.hostSession)
        }
        while publication.entered == 0 { await Task.yield() }
        let second = Task {
            try await w.host.signalledRotate([(w.phone, ["decide", "look"]), (w.primary.deviceKeys, ["look"])],
                                            relay: w.relay, session: w.hostSession, entered: entered)
        }
        await entered.pass()
        publication.open()
        await #expect(throws: TestCrash.self) { try await first.value }
        await #expect(throws: TestCrash.self) { try await second.value }
        #expect(await w.host.rotationRequired)
        #expect(await w.host.epoch == 1)

        if revokedAt != "host" {
            try await w.relay.publishRevocation(try await w.primary.revoke(device: w.primaryID))
        }
        if revokedAt != "relay" { await w.host.markRevoked(w.primaryID) }
        _ = try await rotationRetry(w) { try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession) }

        // The failed attempt never left the host: the retry publishes the same next epoch (epochs never skip, P3-D7).
        #expect(await w.host.rotationRequired == false)
        #expect(await w.host.epoch == 2)
        #expect(calls.value == 2)
        #expect(await w.host.coreState().members[w.primaryID] == nil)
        #expect(await w.relay.hasGrant(workspace: w.ws, device: w.primaryID, epoch: 2) == false)
        #expect(await w.relay.hasGrant(workspace: w.ws, device: w.phoneID, epoch: 2))
        let fetched = try await RelayClient(transport: w.transport).memberList(workspace: w.ws, session: w.phoneSession)
        let verified = try MemberList.verify(fetched, wsk: w.host.wskPublic)
        #expect(verified.epoch == 2)
        #expect(verified.members.map(\.deviceID) == [w.phoneID])
    }

    @Test(arguments: [false, true], [false, true])
    func differingRostersPreserveRemovals(removalFirst: Bool, failFirst: Bool) async throws {
        let w = try await World.make()
        let publication = OpenGate(open: false), entered = OpenGate(open: false)
        let calls = Counter()
        await w.host.setPublishHook {
            calls.bump()
            #expect(await w.host.rotationRequired)
            await publication.pass()
            if failFirst && calls.value == 1 { throw TestCrash() }
        }
        let keeping = [(w.primary.deviceKeys, World.all), (w.phone, ["look", "decide"])]
        let removing = [(w.phone, ["look", "decide"])]
        let first = Task {
            try await w.host.rotate(remaining: removalFirst ? removing : keeping, relay: w.relay, session: w.hostSession)
        }
        while publication.entered == 0 { await Task.yield() }
        let second = Task {
            try await w.host.signalledRotate(removalFirst ? keeping : removing, relay: w.relay,
                                            session: w.hostSession, entered: entered)
        }
        await entered.pass()
        #expect(await w.host.rotationRequired)
        publication.open()
        if failFirst {
            await #expect(throws: TestCrash.self) { try await first.value }
            await #expect(throws: TestCrash.self) { try await second.value }
            #expect(await w.host.rotationRequired)
            #expect(await w.host.epoch == 1)
            _ = try await rotationRetry(w) { try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession) }
        } else {
            try await first.value
            try await second.value
        }
        // A failed removal followed by an attempted re-add leaves identical pending rosters.
        let publications = failFirst ? 1 : 2
        #expect(calls.value == publications + (failFirst ? 1 : 0))
        #expect(await w.host.rotationRequired == false)
        let epoch = await w.host.epoch
        // Epochs never skip: an attempt that never left the host consumes none. Only a removal committed first and then a second
        // (filtered, re-add) publication reaches epoch 3; a removal arriving during the first attempt is folded into it.
        #expect(epoch == (removalFirst && !failFirst ? 3 : 2), "epoch \(epoch) calls \(calls.value)")
        #expect(await w.host.coreState().members[w.primaryID] == nil)
        #expect(await w.relay.hasGrant(workspace: w.ws, device: w.primaryID, epoch: epoch) == false)
        #expect(await w.relay.hasGrant(workspace: w.ws, device: w.phoneID, epoch: epoch))
        let fetched = try await RelayClient(transport: w.transport).memberList(workspace: w.ws, session: w.phoneSession)
        let verified = try MemberList.verify(fetched, wsk: w.host.wskPublic)
        #expect(verified.members.map(\.deviceID) == [w.phoneID])
    }

    @Test func publicRotationCannotRestoreADeviceRemovedByInFlightRevocation() async throws {
        let w = try await World.make()
        _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession)
        let publication = OpenGate(open: false), entered = OpenGate(open: false)
        let calls = Counter()
        await w.host.setPublishHook {
            calls.bump()
            #expect(await w.host.rotationRequired)
            await publication.pass()
        }
        let record = try await w.primary.revoke(device: w.primaryID)
        let (envelope, header) = try await w.sealedRequest(rid: ID16.fresh(0x74),
                                                        meta: ["op": "revocation", "record": record])
        let revocation = Task { await w.host.process(envelope: envelope, mailbox: header.rid) }
        while publication.entered == 0 { await Task.yield() }
        let rotation = Task {
            try await w.host.signalledRotate([(w.primary.deviceKeys, World.all), (w.phone, ["look", "decide"])],
                                            relay: w.relay, session: w.hostSession, entered: entered)
        }
        await entered.pass()
        publication.open()
        try await rotation.value
        let chunks = await revocation.value
        let reply = try openChunk(#require(chunks.first), wk: await w.host.wkFor(1))
        #expect(reply.meta == HostRefusal.alreadyDone(status: "completed").meta)    // old-epoch reply after its rotation (orch-29 Q12)
        #expect(calls.value == 2)
        #expect(await w.host.epoch == 3)
        #expect(await w.host.rotationRequired == false)
        #expect(await w.host.coreState().members[w.primaryID] == nil)
        #expect(await w.relay.hasGrant(workspace: w.ws, device: w.primaryID, epoch: 3) == false)
    }

    @Test func sameRosterCallsJoinOneRotation() async throws {
        let w = try await World.make()
        let publication = OpenGate(open: false), entered = OpenGate(open: false)
        let calls = Counter()
        await w.host.setPublishHook { calls.bump(); await publication.pass() }
        let remaining = [(w.primary.deviceKeys, World.all), (w.phone, ["look", "decide"])]
        let first = Task { try await w.host.rotate(remaining: remaining, relay: w.relay, session: w.hostSession) }
        while publication.entered == 0 { await Task.yield() }
        let second = Task {
            try await w.host.signalledRotate(Array(remaining.reversed()), relay: w.relay,
                                            session: w.hostSession, entered: entered)
        }
        await entered.pass()
        publication.open()
        try await first.value
        try await second.value
        #expect(calls.value == 1)
        #expect(await w.host.epoch == 2)
        #expect(await w.host.rotationRequired == false)
    }
}
