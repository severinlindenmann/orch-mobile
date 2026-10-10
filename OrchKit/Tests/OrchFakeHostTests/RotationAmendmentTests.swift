import Foundation
import Testing
import OrchClient
import OrchProtocol
@testable import OrchFakeHost

@Suite struct RotationAmendmentTests {
    @Test(arguments: [false, true])
    func expiredSessionRecovers(resubmit: Bool) async throws {
        var limits = RelayLimits(); limits.sessionLifetimeMs = 1000
        let w = try await World.make(limits: limits)
        w.clock.advance(milliseconds: 1001)
        let remaining = [(w.phone, ["look", "decide"])]
        await #expect(throws: (any Error).self) {
            try await w.host.rotate(remaining: remaining, relay: w.relay, session: w.hostSession)
        }
        let fresh = try await w.host.openSession(transport: w.transport)
        if resubmit { try await w.host.rotate(remaining: remaining, relay: w.relay, session: fresh) }
        else { _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: fresh) }
        #expect(await w.host.rotationRequired == false)
        #expect(await w.host.epoch == 3)
        #expect(await w.relay.hasGrant(workspace: w.ws, device: w.phoneID, epoch: 3))
    }

    @Test func authenticatedRetirement() async throws {
        let w = try await World.make()
        func body(_ epoch: UInt32, wrongKey: Bool = false) async throws -> JSONValue {
            let o: JSONValue = ["kind": "rotation_abandon", "workspace_id": .string(w.ws.hex), "epoch": .int(Int64(epoch))]
            let signer = await w.host.wsk
            let signingKey = wrongKey ? SoftwareSigner() : signer
            let sig = try Signature.sign(signingKey, label: "orch.host-api.0.rotation_abandon", message: canonicalJSON(o))
            return ["o": o, "sig": .string(B64U.encode(sig))]
        }
        func send(_ value: JSONValue, token: String? = nil) async throws -> WireReply {
            try await w.relay.send(WireRequest(method: "POST", target: "/mobile/host-api/0/workspaces/\(w.ws.hex)/rotation-abandon",
                headers: [HostAPI.versionHeader: "0", "authorization": "Bearer \(token ?? w.hostSession.token)"],
                body: canonicalJSON(value), clientAddress: "198.51.100.7"))
        }
        try await w.relay.putGrant(try await w.host.grant(for: w.phone, epoch: 2), token: w.hostSession.token)
        #expect(try await send(["kind": "rotation_abandon", "workspace_id": .string(w.ws.hex), "epoch": 2]).status == 400)
        #expect(try await send(body(2, wrongKey: true)).status == 403)
        #expect(try await send(body(2), token: w.phoneSession.token).status == 401)
        #expect(try await send(body(2), token: "invalid").status == 401)
        #expect(try await send(body(100)).status == 409)
        #expect(await w.relay.hasGrant(workspace: w.ws, device: w.phoneID, epoch: 2))
        let skip = try await w.host.memberList([], epoch: 3, listSeq: 2)
        await #expect(throws: (any Error).self) { try await w.relay.publishMemberList(skip, token: w.hostSession.token) }
        #expect(try await send(body(2)).status == 200)
        #expect(try await send(body(2)).status == 200)
        #expect(await w.relay.hasGrant(workspace: w.ws, device: w.phoneID, epoch: 2) == false)
        let retired = try await w.host.memberList([], epoch: 2, listSeq: 2)
        await #expect(throws: (any Error).self) { try await w.relay.publishMemberList(retired, token: w.hostSession.token) }
        try await w.relay.publishMemberList(skip, token: w.hostSession.token)
    }

    @Test func lostRetirementAcknowledgementRetriesBeforeAllocation() async throws {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        let route = "POST /mobile/host-api/0/workspaces/\(w.ws.hex)/rotation-abandon"
        faults.enqueue(.disconnect, at: .afterCommitBeforeResponse, routePrefix: route)
            .enqueue(.disconnect, at: .afterCommitBeforeResponse, routePrefix: route)
        let calls = Counter()
        await w.host.setPublishHook {
            calls.bump()
            if calls.value == 1 { throw TestCrash() }
        }
        await #expect(throws: TestCrash.self) {
            try await w.host.rotate(remaining: [(w.phone, ["look"])], relay: w.relay, session: w.hostSession)
        }
        _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession)
        #expect(await w.host.rotationEpoch == 2)
        #expect(calls.value == 1)
        #expect(await w.host.rotationRequired)
        _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession)
        #expect(await w.host.epoch == 3)
        #expect(calls.value == 2)
        #expect(await w.host.rotationRequired == false)
    }

    @Test func publicationRetriesBackOff() async throws {
        let w = try await World.make()
        let calls = Counter()
        await w.host.setPublishHook { calls.bump(); throw TestCrash() }
        await #expect(throws: TestCrash.self) {
            try await w.host.rotate(remaining: [(w.phone, ["look"])], relay: w.relay, session: w.hostSession)
        }
        let start = ContinuousClock.now
        _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession)
        #expect(start.duration(to: .now) >= .milliseconds(100))
        #expect(calls.value == 2)
    }
}
