import CryptoKit
import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
import OrchStore
import OrchTestVectors
@testable import OrchFakeHost
@testable import OrchProtocol

let httpGet: JSONValue = ["op": "http", "method": "GET", "path": "/v2/snapshot", "headers": .object([:])]

@Suite struct DeviceVectorTests {
    @Test func testBridgeDeviceCases() async throws {
        let cases = bridgeVectors()["device_cases"].items
        #expect(cases.count == 11)
        var accepted = 0
        for c in cases {
            let name = c["name"].str, e = c["expect"], ctx = c["ctx"]
            let w = try await World.make(publish: false)
            let index = w.env.index
            let wsID = ctx["workspace"].id
            try await index.addWorkspace(ws: wsID.hex, generation: 1)
            let container = try await WorkspaceContainer(index: index, ws: wsID.hex, generation: 1)
            let clock = TestClock()
            var cfg = WorkspaceSessionConfig(context: w.env.context, workspace: wsID, generation: 1, identity: w.env.device,
                                             wsk: try SigningPublicKey(x963: B64U.decode(ctx["wsk_pub"].str)!), container: container,
                                             vault: w.vault.scoped(to: .demo), transport: w.transport, clock: clock, wall: clock)
            cfg.deviceID = ctx["device"].id
            let session = try await WorkspaceSession(cfg)
            for (k, v) in ctx["wk"].v.object! { try await session.install(epoch: UInt32(k)!, key: keyFromHex(v.string!)) }
            // G2b D4: keys are read only at or below a verified head; these bridge vectors predate it, so the head is the top key epoch
            let top = ctx["wk"].v.object!.keys.compactMap { Int64($0) }.max() ?? 1
            try await container.database().execute("INSERT INTO member_list_head(id, list_seq, epoch, digest, members) VALUES(1,1,?,?,'')",
                                                   [.int(top), .blob(Data(count: 32))])
            try await session.setClockOffset(ctx["offset_ms"].i64)
            var pending: [ID16: Bridge.PendingRequest] = [:]
            for (k, v) in ctx["pending"].v.object! {
                let o = v.object!
                pending[ID16(hex: k)!] = Bridge.PendingRequest(next: UInt64(o["next"]!.int!), stream: o["stream"]!.bool!, epoch: UInt32(o["epoch"]!.int!),
                                                               offsetAdopted: o["offset_adopted"]?.bool ?? false)
            }
            let mb = c["mailbox"]
            let pos = Bridge.MailboxPosition(id: mb["id"].id, index: UInt64(mb["idx"].i64), last: mb["last"].v.bool!, stream: mb["stream"].v.bool!)
            let (out, table) = try await session.check(response: c["envelope"].hexData, mailbox: pos, pending: pending, nowMs: c["now_ms"].i64)
            switch out {
            case .accept(let a):
                accepted += 1
                #expect(e["result"].str == "accept", "\(name)")
                #expect(a.last == e["last"].v.bool && a.refusal == e["refusal"].v.bool, "\(name)")
                #expect(a.meta == e["meta"].v && a.data == e["data"].hexData, "\(name)")
                #expect(a.offsetMs == e["offset_ms"].int && !a.clockWrong, "\(name)")
                #expect(a.fetchGrants == (e["fetch_grants"].v.bool ?? false), "\(name)")
                let rid = mb["id"].id
                // resulting state: the next index advances, or the rid is retired on its last chunk
                #expect(table[rid] == (a.last ? nil : Bridge.PendingRequest(next: pending[rid]!.next + 1, stream: pending[rid]!.stream, epoch: pending[rid]!.epoch)), "\(name)")
            case .drop(let why):
                #expect(e["result"].str == "drop" && e["why"].str == why.code, "\(name)")
                if case .hostSignature(let pin) = why { #expect(pin == e["pin_failure"].v.bool, "\(name)") }
                #expect(table == pending, "\(name)")
            }
        }
        #expect(accepted == 3)
    }
}

@Suite struct RevocationOpVectorTests {
    @Test func testRevocationOpVectors() throws {
        let s2 = J(try StrictJSON.parse(OrchTestVectors.Vectors.data, maxBytes: .max, maxDepth: 64))["suites"]["2"]
        let cases = s2["revocation_op"].items
        #expect(cases.count == 5)
        for c in cases {
            let st = c["state"]
            var core = HostBridgeCore(workspace: ID16.fresh(1), epoch: 1)
            core.revoked = Set((st["revoked"].v.array ?? []).map { ID16(hex: $0.string!)! })
            for (k, v) in st["members"].v.object! { core.members[ID16(hex: k)!] = v.array!.map { $0.string! } }
            let owner = try SigningPublicKey(x963: B64U.decode(st["owner_pk_pub"].str)!)
            let r = core.applyRevocation(c["meta"].v, ownerKey: owner)
            let e = c["expect"]
            if let ok = e["ok"].string {
                #expect(r == .ok(device: ID16(hex: ok)!, rotate: e["rotate"].v.bool!), "\(c["name"].str)")
            } else {
                #expect(r == .refuse(e["refuse"].str), "\(c["name"].str)")
            }
            // resulting state
            let after = c["state_after"]
            #expect(Set(core.revoked.map(\.hex)) == Set((after["revoked"].v.array ?? []).map { $0.string! }), "\(c["name"].str)")
            #expect(Set(core.members.keys.map(\.hex)) == Set(after["members"].v.object!.keys), "\(c["name"].str)")
        }
    }
}

@Suite struct SessionTests {
    func echo() -> HostHandler { { req in .response(status: 200, headers: ["content-type": "application/json"], data: Data("ok:\(req.device.hex.prefix(4))".utf8)) } }

    @Test func roundTripThroughRealBytesAndDurableSeq() async throws {
        let w = try await World.make()
        await w.host.setHandler(echo())
        let phone = try await w.makePhone()
        #expect(try await phone.session.currentEpoch() == 1)
        let r1 = try await w.serve(phone) { try await phone.session.exchange(meta: httpGet) }
        #expect(r1.status == 200 && r1.headers == ["content-type": "application/json"] && r1.data == Data("ok:\(w.phoneID.hex.prefix(4))".utf8))
        #expect(try await phone.session.nextSeq() == 2)
        // A new session object over the same container (an app restart) continues the sequence and finds the keys in custody.
        let again = try await w.makePhone(install: false)
        let e2 = try await again.session.currentEpoch(), n2 = try await again.session.nextSeq()
        #expect(e2 == 1 && n2 == 2)
        let r2 = try await w.serve(again) { try await again.session.exchange(meta: httpGet) }
        #expect(r2.status == 200)
        #expect(try await again.session.nextSeq() == 3)
        // Host side: both sequence numbers were consumed in order.
        let hc = await w.host.coreState()
        #expect(hc.seq[w.phoneID]!.high == 2)
    }

    @Test func requestIsPersistedBeforeItIsSentAndResendIsByteIdentical() async throws {
        let faults = ScriptedFaults().enqueue(.drop, at: .beforeQueue)
        let w = try await World.make(faults: faults)
        await w.host.setHandler(echo())
        let phone = try await w.makePhone()
        let s = phone.session
        await #expect(throws: TransportError.disconnected) { _ = try await s.exchange(meta: httpGet) }
        let pending = try await s.pendingRequests()
        #expect(pending.count == 1 && pending[0].seq == 1 && pending[0].epoch == 1)
        let stored = try await s.storedEnvelope(rid: pending[0].rid)!
        #expect(try await w.relay.pendingRequests(workspace: w.ws, token: w.hostSession.token).isEmpty)       // never reached the relay
        let rid = pending[0].rid
        let r = try await w.serve(phone) { try await s.resend(rid: rid) }
        #expect(r.status == 200)
        // The relay and host saw exactly the stored bytes.
        #expect(await w.host.coreState().rids[rid]?.digest == (try Bridge.Parts(envelope: stored)).digest)
        #expect(try await s.pendingRequests().isEmpty)
    }

    @Test func testLostResponseReplaysStoredEnvelope() async throws {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        let counter = Counter()
        await w.host.setHandler({ _ in counter.bump(); return .response(status: 200, headers: [:], data: Data("done".utf8)) })
        let phone = try await w.makePhone()
        let s = phone.session
        faults.enqueue(.disconnect, at: .pollDelivery)
        await #expect(throws: TransportError.disconnected) { _ = try await s.exchange(meta: httpGet) }       // posted, answer never read
        let pending = try await s.pendingRequests()
        #expect(pending.count == 1)
        let rid = pending[0].rid
        let stored = try await s.storedEnvelope(rid: rid)!
        #expect(try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession) == 1)
        #expect(counter.value == 1)
        // Within the answer's 60 s body lifetime: the same rid, re-sent byte for byte, reads the stored answer (P3-D9/D22).
        w.clock.advance(milliseconds: 30_000); phone.clock.advance(milliseconds: 30_000)
        let r = try await w.serve(phone) { try await s.resend(rid: rid) }
        #expect(r.status == 200 && r.data == Data("done".utf8))
        #expect(counter.value == 1)                                                             // replayed, not run again
        #expect(try await s.storedEnvelope(rid: rid) == nil)
        #expect(stored.count > Bridge.overhead)
    }

    @Test func anExpiredAnswerIsStoredAgainFromTheHostsExactBytes() async throws {
        // Q11 (P3-D27, orch-relay d3816ea): once the host's answer chunk expired (60 s) the relay keeps its digest; the host re-posts
        // the EXACT bytes it kept for the requeued copy, the relay stores them again for 60 s, and the same rid gets its answer.
        // The handler does not run again and nothing is re-signed.
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        let counter = Counter()
        await w.host.setHandler({ _ in counter.bump(); return .response(status: 200, headers: [:], data: Data("done".utf8)) })
        let phone = try await w.makePhone()
        let s = phone.session
        faults.enqueue(.disconnect, at: .pollDelivery)
        await #expect(throws: TransportError.disconnected) { _ = try await s.exchange(meta: httpGet) }
        let p = try await s.pendingRequests()[0]
        #expect(try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession) == 1)
        w.clock.advance(milliseconds: 61_000); phone.clock.advance(milliseconds: 61_000)
        let seq = try await s.nextSeq()
        let r = try await w.serve(phone) { try await s.resend(rid: p.rid) }
        #expect(r.data == Data("done".utf8))
        let seqAfter = try await s.nextSeq()
        #expect(counter.value == 1 && seqAfter == seq)
        let record = try #require(await w.relay.ridRecord(workspace: w.ws, device: w.phoneID, rid: p.rid))
        let chunk = try #require(record.chunks[0])
        #expect(record.requeues == 1)
        #expect(chunk.restores == 1)
    }

    @Test func testExpiredOrUnknownRidReconcilesByQuestion() async throws {
        // The host lost its answer: a re-send is already_done(unknown), which the session reports as uncertain (the caller
        // reconciles by reading state; nothing is re-signed or re-run).
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        await w.host.setHandler(echo())
        let phone = try await w.makePhone()
        let s = phone.session
        faults.enqueue(.disconnect, at: .pollDelivery)
        await #expect(throws: TransportError.disconnected) { _ = try await s.exchange(meta: httpGet) }
        let p = try await s.pendingRequests()[0]
        _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession)
        await w.host.forgetOutcome(rid: p.rid)
        await w.relay.forgetResponses(workspace: w.ws, device: w.phoneID, rid: p.rid)        // the answer never reached the relay
        w.clock.advance(milliseconds: 61_000); phone.clock.advance(milliseconds: 61_000)
        await #expect(throws: SessionError.uncertain(logical: p.logical)) { _ = try await w.serve(phone) { try await s.resend(rid: p.rid) } }
        #expect(try await s.pendingRequests().isEmpty)
        // Past the host's 900 s record window the envelope is not even sent again.
        faults.enqueue(.disconnect, at: .pollDelivery)
        await #expect(throws: TransportError.disconnected) { _ = try await s.exchange(meta: httpGet) }
        let q = try await s.pendingRequests()[0]
        let before = await w.relay.requestsReceived
        w.clock.advance(milliseconds: 900_000); phone.clock.advance(milliseconds: 900_000)
        await #expect(throws: SessionError.uncertain(logical: q.logical)) { _ = try await s.resend(rid: q.rid) }
        #expect(await w.relay.requestsReceived == before)
    }

    @Test func testStaleEpochFetchesGrantsAndResendsAsNewRequest() async throws {
        let w = try await World.make()
        await w.host.setHandler(echo())
        let phone = try await w.makePhone()
        let s = phone.session
        let first = try await w.serve(phone) { try await s.exchange(meta: httpGet) }
        #expect(first.status == 200)
        // The host rotates (e.g. a device left): the phone still believes in epoch 1.
        try await w.host.rotate(remaining: [(w.primary.deviceKeys, World.all), (w.phone, ["look", "decide"])], relay: w.relay, session: w.hostSession)
        #expect(try await s.currentEpoch() == 1)
        let r = try await w.serve(phone) { try await s.exchange(meta: httpGet) }
        #expect(r.status == 200)
        #expect(try await s.currentEpoch() == 2)
        let hc = await w.host.coreState()
        // seq 1 ran. seq 2 (a NEW rid at epoch 1) was refused by the relay with its unsigned stale_epoch hint (P3-D8) and never
        // reached the host; the phone refetched the SIGNED list and grants, and seq 3 ran at epoch 2 under a new rid.
        #expect(hc.seq[w.phoneID]!.high == 3 && hc.rids.count == 2)
        #expect(!hc.rids.values.map(\.outcome).contains(.refusal(.staleEpoch(epoch: 2))))
        #expect(try await s.pendingRequests().isEmpty)
        // The new epoch is the one it seals under from now on.
        let r3 = try await w.serve(phone) { try await s.exchange(meta: httpGet) }
        let hc3 = await w.host.coreState()
        #expect(r3.status == 200 && hc3.seq[w.phoneID]!.high == 4)
    }

    @Test func staleEpochForADeviceWithoutANewGrantFailsClosed() async throws {
        let w = try await World.make()
        await w.host.setHandler(echo())
        let phone = try await w.makePhone()
        let s = phone.session
        // Rotate with the phone left out: its old request is refused stale_epoch (it is still in the host roster until the
        // list changes, so re-add it to the host roster only) and no grant exists for epoch 2.
        try await w.host.rotate(remaining: [(w.primary.deviceKeys, World.all)], relay: w.relay, session: w.hostSession)
        await w.host.setRoster([(w.primary.deviceKeys, World.all), (w.phone, ["look", "decide"])])
        do { _ = try await w.serve(phone) { try await s.exchange(meta: httpGet) }; Issue.record("expected failure") }
        catch {
            // grants route says not_eligible: the phone is no longer a member
            #expect(error as? ClientError == .relay(RelayRefusal(status: 403, code: .notEligible)))
        }
        #expect(try await s.currentEpoch() == 1)                      // never moves
    }

    @Test func testStaleTimestampAdoptsOffsetOnceAndRetries() async throws {
        let w = try await World.make()
        await w.host.setHandler(echo())
        let phone = try await w.makePhone(skewMs: 600_000)              // the phone's clock runs ten minutes ahead
        let s = phone.session
        let r = try await w.serve(phone) { try await s.exchange(meta: httpGet) }
        #expect(r.status == 200)
        let off = try await s.clockOffsetMs()
        #expect(abs(off + 600_000) < 5_000)
        let hc = await w.host.coreState()
        let staleTS = hc.rids.values.contains { if case .refusal(.staleTimestamp)? = $0.outcome { return true }; return false }
        #expect(hc.rids.count == 2 && staleTS)
        // With the offset in place the next request is accepted first time.
        let r2 = try await w.serve(phone) { try await s.exchange(meta: httpGet) }
        let hc2 = await w.host.coreState()
        #expect(r2.status == 200 && hc2.rids.count == 3)
    }

    @Test func hostRefusalsAreTypedAndSealed() async throws {
        let w = try await World.make()
        await w.host.setHandler(echo())
        let phone = try await w.makePhone()
        let s = phone.session
        // (a write's scope is the R2 table's `decide`, checked by the host's own admission: SubmitAdmissionTests, literal codes)
        // the retired v0 creation op is refused before anything is sealed, in Demo too (no exemption since increment 3)
        let nt: JSONValue = ["op": "new_ticket", "host_api": 0, "creation_id": .string(ID16.fresh(5).hex), "title": "t", "body": "", "epic_key": .null]
        await #expect(throws: ViewError.writesUnavailable) { _ = try await w.serve(phone) { try await s.exchange(meta: nt) } }
        // an op outside the closed table is forbidden_scope (R2, 11A.5)
        await #expect(throws: R2.MetaError.forbiddenScope) { _ = try await w.serve(phone) { try await s.exchange(meta: ["op": "nope"]) } }   // refused locally
        // removed from the host roster (bad state on the host): not_member, sealed and host-signed
        await w.host.setRoster([(w.primary.deviceKeys, World.all)])
        await #expect(throws: ClientError.host(.notMember)) { _ = try await w.serve(phone) { try await s.exchange(meta: httpGet) } }
        // revoked
        let rec = try await w.primary.revoke(device: w.phoneID)
        _ = rec
        await w.host.markRevoked(w.phoneID)
        await #expect(throws: ClientError.host(.revoked)) { _ = try await w.serve(phone) { try await s.exchange(meta: httpGet) } }
    }

    @Test func largeResponsesAreChunkedAndReassembled() async throws {
        let w = try await World.make()
        let big = Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        await w.host.setHandler({ _ in .response(status: 200, headers: [:], data: big) })
        let phone = try await w.makePhone()
        let s = phone.session
        let r = try await w.serve(phone) { try await s.exchange(meta: httpGet) }
        #expect(r.data == big)
        // The chunks are exactly what chunk binding demands: contiguous indexes, LAST only on the final one.
        let rid = ID16.fresh(0)
        _ = rid
        let hc = await w.host.coreState()
        if case .stored(let chunks)? = hc.rids.values.first?.outcome {
            #expect(chunks.count == 3)
            let parts = try chunks.map { try Bridge.Parts(envelope: $0) }
            #expect(parts.map { $0.header.seq } == [0, 1, 2] && parts.map { $0.header.flagSet.contains(.last) } == [false, false, true])
            #expect(chunks.allSatisfy { $0.count <= Bridge.maxChunk })
        } else { Issue.record("no stored response") }
    }

    @Test func pollFaultsAreSurvivedAndCorruptChunksDropped() async throws {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        await w.host.setHandler({ _ in .response(status: 200, headers: [:], data: Data(repeating: 9, count: 300_000)) })
        let phone = try await w.makePhone(timeout: .seconds(10))
        let s = phone.session
        // reordered and duplicated chunks are put back in order
        faults.enqueue(.reorder, at: .pollDelivery).enqueue(.duplicate, at: .pollDelivery)
        let r = try await w.serve(phone) { try await s.exchange(meta: httpGet) }
        #expect(r.data.count == 300_000)
        // a corrupted chunk is dropped; the next clean poll delivers it, with nothing lost or accepted twice
        faults.enqueue(.corrupt, at: .pollDelivery)
        let r2 = try await w.serve(phone) { try await s.exchange(meta: httpGet) }
        #expect(r2.data.count == 300_000)
    }

    @Test func memberDeviceSignedResponsesCountAsPinFailures() async throws {
        let w = try await World.make()
        await w.host.setHandler(echo())
        await w.host.setResponseSigner(SoftwareSigner())
        let phone = try await w.makePhone(timeout: .seconds(2))
        let s = phone.session
        // The tag opens (a holder of the channel key sealed it) but WSK did not sign it: dropped, and counted.
        for _ in 0..<3 {
            do { _ = try await w.serve(phone, steps: 60) { try await s.exchange(meta: httpGet) }; Issue.record("expected noResponse") }
            catch SessionError.noResponse {} catch { Issue.record("\(error)") }
        }
        #expect(try await s.pinFailures() >= 3)
        await #expect(throws: SessionError.pairAgain) { _ = try await s.exchange(meta: httpGet) }
    }

    @Test func staleGenerationCannotSendOrStore() async throws {
        let w = try await World.make()
        await w.host.setHandler(echo())
        let phone = try await w.makePhone()
        let s = phone.session
        _ = try await w.serve(phone) { try await s.exchange(meta: httpGet) }
        let before = await w.relay.requestsReceived
        _ = try await w.env.index.recordTombstone(ws: w.ws.hex, generation: 1)         // the workspace was left
        await #expect(throws: SessionError.staleGeneration) { _ = try await s.exchange(meta: httpGet) }
        await #expect(throws: SessionError.staleGeneration) { try await s.refreshGrants() }
        #expect(await w.relay.requestsReceived == before)                              // not one byte left the phone
        // A session cannot be bound to the other realm's storage.
        let liveVault = SecretVault(group: .keys, backend: InMemoryVaultBackend()).scoped(to: .live)
        let c = TestClock()
        let cfg = WorkspaceSessionConfig(context: w.env.context, workspace: w.ws, generation: 1, identity: w.env.device, wsk: w.host.wskPublic,
                                         container: phone.container, vault: liveVault, transport: w.transport, clock: c, wall: c)
        await #expect(throws: RealmViolation.wrongStore) { _ = try await WorkspaceSession(cfg) }
    }

    @Test func keysAndSeqLiveInTheirStoresNotInMemory() async throws {
        let w = try await World.make()
        let phone = try await w.makePhone()
        // WK is in realm-tagged custody under the workspace, and the container's high-water mark is its epoch.
        let ids = try w.vault.ids().filter { $0.ws == w.ws.hex }
        #expect(ids.map(\.purpose) == ["wk.1"] && ids.allSatisfy { $0.realm == .demo })
        #expect(try await phone.container.epochHighWater() == 1)
        // A different key for an installed epoch is refused (the held list commits the installed one), never a replacement.
        await #expect(throws: SessionError.wkCommitMismatch(1)) { try await phone.session.install(epoch: 1, key: SymmetricKey(size: .bits256)) }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    var value: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}
