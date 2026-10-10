import CryptoKit
import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
import OrchStore
@testable import OrchFakeHost
@testable import OrchProtocol

// Fix round for slice 2a (review: Opus security FAIL, Codex CHANGES REQUESTED). The adversarial scenarios S1 to S5 are the
// reviewer's; they assert the fixed behaviour. Each regression test names the finding it covers.

/// Blocks callers until opened; stays open afterwards. `entered` counts callers that had to wait.
final class OpenGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var count = 0
    init(open: Bool = true) { opened = open }
    var entered: Int { lock.withLock { count } }
    func close() { lock.withLock { opened = false } }
    func pass() async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened { lock.unlock(); k.resume(); return }
            count += 1; waiters.append(k); lock.unlock()
        }
    }
    func open() {
        let w = lock.withLock { () -> [CheckedContinuation<Void, Never>] in opened = true; let w = waiters; waiters = []; return w }
        for k in w { k.resume() }
    }
}

/// Forwards to the real in-process transport, with gates and counters on the calls that matter.
final class GateTransport: RelayTransport, @unchecked Sendable {
    let inner: any RelayTransport
    let loginGate = OpenGate(), postGate = OpenGate(), grantsGate = OpenGate()
    private let lock = NSLock()
    private var posted = 0
    var posts: Int { lock.withLock { posted } }
    init(_ inner: any RelayTransport) { self.inner = inner }
    var context: RealmContext { inner.context }
    func challenge() async throws -> WireReply { try await inner.challenge() }
    func login(_ body: Data) async throws -> WireReply { await loginGate.pass(); return try await inner.login(body) }
    func pairingPost(_ envelope: Data, route: PairRoute) async throws -> WireReply { try await inner.pairingPost(envelope, route: route) }
    func pairingPoll(route: PairRoute, after: UInt64?) async throws -> WireReply { try await inner.pairingPoll(route: route, after: after) }
    func bridgePost(_ envelope: Data, route: BridgeRoute, session: RelaySession) async throws -> WireReply {
        lock.withLock { posted += 1 }
        await postGate.pass()
        return try await inner.bridgePost(envelope, route: route, session: session)
    }
    func bridgePoll(route: BridgeRoute, after: UInt64?, session: RelaySession) async throws -> WireReply { try await inner.bridgePoll(route: route, after: after, session: session) }
    func grants(workspaceID: ID16, epoch: UInt32?, session: RelaySession) async throws -> WireReply {
        await grantsGate.pass(); return try await inner.grants(workspaceID: workspaceID, epoch: epoch, session: session)
    }
    func memberList(workspaceID: ID16, session: RelaySession) async throws -> WireReply { try await inner.memberList(workspaceID: workspaceID, session: session) }
    func card(workspaceID: ID16, session: RelaySession) async throws -> WireReply { try await inner.card(workspaceID: workspaceID, session: session) }
    func cardKey(workspaceID: ID16, cardSequence: UInt32, session: RelaySession) async throws -> WireReply {
        try await inner.cardKey(workspaceID: workspaceID, cardSequence: cardSequence, session: session)
    }
    func registerPush(_ body: Data, session: RelaySession) async throws -> WireReply { try await inner.registerPush(body, session: session) }
    func unregisterPush(_ body: Data, session: RelaySession) async throws -> WireReply { try await inner.unregisterPush(body, session: session) }
    func revocation(deviceID: ID16) async throws -> WireReply { try await inner.revocation(deviceID: deviceID) }
    func dropPut(objectID: ID16, ifMatch: UInt32, body: Data, session: RelaySession) async throws -> WireReply {
        try await inner.dropPut(objectID: objectID, ifMatch: ifMatch, body: body, session: session)
    }
    func dropList(_ query: Data, session: RelaySession) async throws -> WireReply { try await inner.dropList(query, session: session) }
    func dropGet(objectID: ID16, version: UInt32, part: DropPart, session: RelaySession) async throws -> WireReply {
        try await inner.dropGet(objectID: objectID, version: version, part: part, session: session)
    }
}

/// A handler that parks until the test lets it go.
final class HandlerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false, released = false
    var isEntered: Bool { lock.withLock { entered } }
    func wait() async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            lock.lock()
            entered = true
            if released { lock.unlock(); k.resume() } else { continuation = k; lock.unlock() }
        }
    }
    func open() { let k = lock.withLock { () -> CheckedContinuation<Void, Never>? in released = true; let k = continuation; continuation = nil; return k }; k?.resume() }
}

struct TestCrash: Error, Equatable {}

extension FakeHost {
    func wkFor(_ e: UInt32) -> SymmetricKey { wk(e) }
    func setSeqWindow(_ d: ID16, high: UInt64, bitmap: UInt64 = 0) { core.seq[d] = SeqWindow(high: high, bitmap: bitmap) }
    func adoptStream(rid: ID16, owner: ID16) { core.streams[rid] = owner }
    /// A host restart that kept keys and roster but lost the named parts of its bridge state.
    func loseBridgeState(seq: Bool, rids: Bool) {
        if seq { core.seq = [:] }
        if rids { core.rids = [:] }
    }
}

extension World {
    /// A hand-sealed request from the phone (the session would persist and number it itself).
    func sealedRequest(rid: ID16, seq: UInt64 = 1, epoch: UInt32 = 1, flags: Bridge.Flags = [], meta: JSONValue = httpGet) async throws -> (Data, Bridge.Header) {
        let h = Bridge.Header(direction: .toHost, flags: flags, workspace: ws, device: phoneID, rid: rid, seq: seq, tsMs: UInt64(clock.nowMs), epoch: epoch,
                              salt: Data(repeating: UInt8(truncatingIfNeeded: seq), count: 16))
        let wk = await host.wkFor(epoch)
        return (try Bridge.seal(header: h, channelKey: Bridge.channelKey(header: h, wk: wk)!, signer: env.device.sig,
                                plaintext: Bridge.frame(meta: meta, data: Data())), h)
    }
}

/// Opens a host response chunk with the key of its own epoch.
func openChunk(_ chunk: Data, wk: SymmetricKey) throws -> (header: Bridge.Header, meta: JSONValue, data: Data) {
    let parts = try Bridge.Parts(envelope: chunk)
    let plain = try Bridge.openBody(parts, channelKey: Bridge.channelKey(header: parts.header, wk: wk)!)
    let (m, d) = try Bridge.unframe(plain)
    return (parts.header, m, d)
}

let unknownRefusal = HostRefusal.alreadyDone(status: "unknown")

@Suite struct Hardening2a {
    // MARK: 1. U8: a re-send is never re-signed

    // Reviewer's S1: the host's record of the original lives 900 s on the HOST's clock; a phone clock set back by ten
    // seconds must not take it past the window. The safety margin makes the phone give up long before.
    @Test func S1_resendAfterHostRecordExpiredIsNotReRun() async throws {
        let faults = ScriptedFaults()
        var lim = RelayLimits(); lim.sessionLifetimeMs = 7_200_000
        let w = try await World.make(faults: faults, limits: lim)
        let counter = Counter()
        await w.host.setHandler({ _ in counter.bump(); return .response(status: 200, headers: [:], data: Data("done".utf8)) })
        let phone = try await w.makePhone()
        let s = phone.session
        faults.enqueue(.disconnect, at: .pollDelivery)
        await #expect(throws: TransportError.disconnected) { _ = try await s.exchange(meta: ["op": "decision", "x": 1]) }
        let p = try await s.pendingRequests()[0]
        _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession)
        #expect(counter.value == 1)
        w.clock.advance(milliseconds: 901_000); phone.clock.advance(milliseconds: 891_000)
        let seqBefore = try await s.nextSeq()
        await #expect(throws: SessionError.uncertain(logical: p.logical)) { _ = try await w.serve(phone) { try await s.resend(rid: p.rid) } }
        #expect(counter.value == 1)
        #expect(try await s.nextSeq() == seqBefore)                       // nothing was re-signed
        #expect(await w.host.coreState().rids.count == 1)
        // Durable: pending is empty, the uncertain record has the immutable bytes, and a restart still has it.
        #expect(try await s.pendingRequests().isEmpty)
        let u = try await s.uncertainRequests()
        #expect(u.count == 1 && u[0].logical == p.logical && u[0].rid == p.rid && u[0].seq == p.seq)
        #expect(try Bridge.unframe(u[0].plaintext).0 == ["op": "decision", "x": 1])
        let again = try await w.makePhone(install: false)
        #expect(try await again.session.uncertainRequests() == u)
        await #expect(throws: SessionError.unknownRequest) { _ = try await again.session.resend(rid: ID16.fresh(9)) }
        await #expect(throws: SessionError.uncertain(logical: p.logical)) { _ = try await again.session.resend(rid: p.rid) }
        #expect(counter.value == 1)
        // Only reconciliation removes it.
        #expect(try await again.session.resolveUncertain(logical: p.logical) == 1)
        #expect(try await again.session.uncertainRequests().isEmpty)
    }

    @Test(arguments: [(299_000 as Int64, true), (301_000, false)])
    func resendWindowBoundary(ageMs: Int64, replayed: Bool) async throws {
        let faults = ScriptedFaults()
        var lim = RelayLimits(); lim.sessionLifetimeMs = 7_200_000
        let w = try await World.make(faults: faults, limits: lim)
        let counter = Counter()
        await w.host.setHandler({ _ in counter.bump(); return .response(status: 200, headers: [:], data: Data("done".utf8)) })
        let phone = try await w.makePhone()
        let s = phone.session
        faults.enqueue(.disconnect, at: .pollDelivery)
        await #expect(throws: TransportError.disconnected) { _ = try await s.exchange(meta: httpGet) }
        let p = try await s.pendingRequests()[0]
        _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession)
        w.clock.advance(milliseconds: ageMs); phone.clock.advance(milliseconds: ageMs)
        if replayed {
            let r = try await w.serve(phone) { try await s.resend(rid: p.rid) }
            #expect(r.data == Data("done".utf8))
        } else {
            await #expect(throws: SessionError.uncertain(logical: p.logical)) { _ = try await s.resend(rid: p.rid) }
        }
        #expect(counter.value == 1)
    }

    // The monotonic age counts too: a wall clock set back after the request was made does not extend the window.
    @Test func resendGateUsesMonotonicTimeWhenTheWallClockWasSetBack() async throws {
        let faults = ScriptedFaults()
        var lim = RelayLimits(); lim.sessionLifetimeMs = 7_200_000
        let w = try await World.make(faults: faults, limits: lim)
        let c = TestClock(wallStartMs: w.clock.nowMs)
        let index = w.env.index
        try await index.addWorkspace(ws: w.ws.hex, generation: 1)
        let container = try await WorkspaceContainer(index: index, ws: w.ws.hex, generation: 1)
        // wall time that can be set back independently of the monotonic clock
        final class Wall: WallClock, @unchecked Sendable { let base: TestClock; let lock = NSLock(); var back: Int64 = 0
            init(_ b: TestClock) { base = b }
            var nowMs: Int64 { lock.withLock { base.nowMs - back } }
            func setBack(_ ms: Int64) { lock.withLock { back = ms } } }
        let wall = Wall(c)
        let cfg = WorkspaceSessionConfig(context: w.env.context, workspace: w.ws, generation: 1, identity: w.env.device, wsk: w.host.wskPublic, container: container,
                                         vault: w.vault.scoped(to: .demo), transport: w.transport, clock: c, wall: wall, responseTimeout: .zero)
        let s = try await WorkspaceSession(cfg)
        try await s.refreshGrants()
        _ = faults
        await #expect(throws: SessionError.self) { _ = try await s.exchange(meta: httpGet) }
        let p = try await s.pendingRequests()[0]
        c.advance(milliseconds: 400_000)               // monotonic and wall: 400 s
        wall.setBack(399_000)                          // the user sets the clock back: wall age is now 1 s
        await #expect(throws: SessionError.uncertain(logical: p.logical)) { _ = try await s.resend(rid: p.rid) }
    }

    // Anything that would need a new seq, timestamp or epoch is `uncertain` on a re-send. Never re-signed.
    @Test(arguments: ["stale_sequence", "stale_epoch", "stale_timestamp"])
    func resendRefusedAsStaleIsUncertainNotReSigned(kind: String) async throws {
        let faults = ScriptedFaults()
        var lim = RelayLimits(); lim.sessionLifetimeMs = 7_200_000
        let w = try await World.make(faults: faults, limits: lim)
        let counter = Counter()
        await w.host.setHandler({ _ in counter.bump(); return .response(status: 200, headers: [:], data: Data()) })
        let phone = try await w.makePhone()
        let s = phone.session
        faults.enqueue(.drop, at: .beforeQueue)
        await #expect(throws: TransportError.disconnected) { _ = try await s.exchange(meta: httpGet) }       // never reached the relay
        let p = try await s.pendingRequests()[0]
        switch kind {
        case "stale_sequence": await w.host.setSeqWindow(w.phoneID, high: 100)
        case "stale_epoch": try await w.host.rotate(remaining: [(w.primary.deviceKeys, World.all), (w.phone, ["look", "decide"])], relay: w.relay, session: w.hostSession)
        default: w.clock.advance(milliseconds: 901_000)             // only the host's clock moved
        }
        await #expect(throws: SessionError.uncertain(logical: p.logical)) { _ = try await w.serve(phone) { try await s.resend(rid: p.rid) } }
        #expect(counter.value == 0)
        #expect(try await s.nextSeq() == 2)                          // no new seq was taken
        #expect(try await s.pendingRequests().isEmpty)
        let u = try await s.uncertainRequests()
        #expect(u.count == 1 && u[0].rid == p.rid)
        #expect(try await s.currentEpoch() == 1)
    }

    // MARK: 2. retries are atomic

    @Test(arguments: ["replace.inserted", "replace.deleted"])
    func crashBetweenTheStepsOfARetryLeavesTheOldAttemptRecoverable(point: String) async throws {
        let w = try await World.make()
        await w.host.setHandler({ _ in .response(status: 200, headers: [:], data: Data()) })
        let phone = try await w.makePhone()
        let s = phone.session
        try await w.host.rotate(remaining: [(w.primary.deviceKeys, World.all), (w.phone, ["look", "decide"])], relay: w.relay, session: w.hostSession)
        await s.setCrashHook { if $0 == point { throw TestCrash() } }
        await #expect(throws: TestCrash()) { _ = try await w.serve(phone) { try await s.exchange(meta: httpGet) } }
        // The refused attempt is still the one durable attempt; the replacement and its seq rolled back with it.
        let pending = try await s.pendingRequests()
        #expect(pending.count == 1 && pending[0].seq == 1 && pending[0].epoch == 1)
        #expect(try await s.nextSeq() == 2)
        #expect(try await s.storedEnvelope(rid: pending[0].rid) != nil)
        #expect(try await s.uncertainRequests().isEmpty)
        // Recovery: with the crash gone the next call goes on, and the old row is reconcilable (a re-send of a refused request is uncertain).
        await s.setCrashHook(nil)
        await #expect(throws: SessionError.uncertain(logical: pending[0].logical)) { _ = try await w.serve(phone) { try await s.resend(rid: pending[0].rid) } }
        #expect(try await s.uncertainRequests().count == 1)
        let r = try await w.serve(phone) { try await s.exchange(meta: httpGet) }
        #expect(r.status == 200)
    }

    @Test func aFailedGrantFetchLeavesTheRefusedAttemptInPlace() async throws {
        let w = try await World.make()
        await w.host.setHandler({ _ in .response(status: 200, headers: [:], data: Data()) })
        let phone = try await w.makePhone()
        let s = phone.session
        try await w.host.rotate(remaining: [(w.primary.deviceKeys, World.all)], relay: w.relay, session: w.hostSession)       // the phone is out
        await w.host.setRoster([(w.primary.deviceKeys, World.all), (w.phone, ["look", "decide"])])
        await #expect(throws: ClientError.relay(RelayRefusal(status: 403, code: .notEligible))) { _ = try await w.serve(phone) { try await s.exchange(meta: httpGet) } }
        let pending = try await s.pendingRequests()
        #expect(pending.count == 1 && pending[0].seq == 1)
        #expect(try await s.nextSeq() == 2)
    }

    @Test func cancellationDuringTheGrantFetchLeavesTheOldAttempt() async throws {
        let w = try await World.make()
        await w.host.setHandler({ _ in .response(status: 200, headers: [:], data: Data()) })
        let gate = GateTransport(w.transport)
        let phone = try await w.makePhone(transport: gate)
        let s = phone.session
        try await w.host.rotate(remaining: [(w.primary.deviceKeys, World.all), (w.phone, ["look", "decide"])], relay: w.relay, session: w.hostSession)
        gate.grantsGate.close()
        let t = Task { try await w.serve(phone) { try await s.exchange(meta: httpGet) } }
        while gate.grantsGate.entered == 0 { await Task.yield() }
        await s.cancelAll()
        gate.grantsGate.open()
        _ = await t.result
        let pending = try await s.pendingRequests()
        #expect(pending.count == 1 && pending[0].seq == 1)           // the refused attempt, not deleted and not duplicated
        #expect(try await s.uncertainRequests().isEmpty)
    }

    // MARK: 4. one driver per logical request

    @Test func concurrentResendsOfOneRowShareOneDriver() async throws {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        let counter = Counter()
        await w.host.setHandler({ _ in counter.bump(); return .response(status: 200, headers: [:], data: Data("once".utf8)) })
        let gate = GateTransport(w.transport)
        let phone = try await w.makePhone(transport: gate)
        let s = phone.session
        faults.enqueue(.drop, at: .beforeQueue)
        await #expect(throws: TransportError.disconnected) { _ = try await s.exchange(meta: httpGet) }
        let p = try await s.pendingRequests()[0]
        let before = gate.posts
        gate.postGate.close()
        let results = try await w.serve(phone) { () -> [BridgeResponse] in
            async let a = s.resend(rid: p.rid)
            async let b = s.resend(rid: p.rid)
            while gate.postGate.entered == 0 { await Task.yield() }
            for _ in 0..<100 { await Task.yield() }               // the second caller has had every chance to start its own driver
            gate.postGate.open()
            return try await [a, b]
        }
        #expect(results.count == 2 && results[0] == results[1] && results[0].data == Data("once".utf8))
        #expect(gate.posts == before + 1)
        #expect(counter.value == 1)
        #expect(try await s.pendingRequests().isEmpty)
        #expect(await w.host.coreState().rids.count == 1)
    }

    // MARK: 5. generation checked at dispatch

    @Test func aWorkspaceRemovedDuringALoginSendsNothing() async throws {
        let w = try await World.make()
        let gate = GateTransport(w.transport)
        let phone = try await w.makePhone(transport: gate)
        let s = phone.session
        w.clock.advance(milliseconds: 20 * 60_000); phone.clock.advance(milliseconds: 20 * 60_000)        // the cached relay session is gone
        gate.loginGate.close()
        let t = Task { try await s.exchange(meta: httpGet) }
        while gate.loginGate.entered == 0 { await Task.yield() }
        _ = try await w.env.index.recordTombstone(ws: w.ws.hex, generation: 1)                              // left while the login is suspended
        gate.loginGate.open()
        do { _ = try await t.value; Issue.record("expected staleGeneration") } catch { #expect(error as? SessionError == .staleGeneration) }
        #expect(gate.posts == 0)
    }

    // MARK: 3/9. durable uncertain, consecutive pin failures

    @Test func hostSaidUnknownIsDurableUncertain() async throws {
        let faults = ScriptedFaults()
        let w = try await World.make(faults: faults)
        await w.host.setHandler({ _ in .response(status: 200, headers: [:], data: Data()) })
        let phone = try await w.makePhone()
        let s = phone.session
        faults.enqueue(.disconnect, at: .pollDelivery)
        await #expect(throws: TransportError.disconnected) { _ = try await s.exchange(meta: httpGet) }
        let p = try await s.pendingRequests()[0]
        _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession)
        await w.host.forgetOutcome(rid: p.rid)
        w.clock.advance(milliseconds: 61_000); phone.clock.advance(milliseconds: 61_000)
        await #expect(throws: SessionError.uncertain(logical: p.logical)) { _ = try await w.serve(phone) { try await s.resend(rid: p.rid) } }
        let again = try await w.makePhone(install: false)
        let u = try await again.session.uncertainRequests()
        let stillPending = try await again.session.pendingRequests()
        #expect(u.map(\.logical) == [p.logical] && stillPending.isEmpty)
    }

    @Test func pinFailuresAreConsecutiveOnly() async throws {
        let w = try await World.make()
        await w.host.setHandler({ _ in .response(status: 200, headers: [:], data: Data()) })
        let phone = try await w.makePhone(timeout: .seconds(2))
        let s = phone.session
        func fail() async throws {
            do { _ = try await w.serve(phone, steps: 60) { try await s.exchange(meta: httpGet) }; Issue.record("expected noResponse") }
            catch SessionError.noResponse {} catch { Issue.record("\(error)") }
        }
        await w.host.setResponseSigner(SoftwareSigner())
        try await fail(); try await fail()
        #expect(try await s.pinFailures() == 2)
        await w.host.setResponseSigner(nil)
        let ok = try await w.serve(phone) { try await s.exchange(meta: httpGet) }
        let afterOK = try await s.pinFailures()
        #expect(ok.status == 200 && afterOK == 0)                                  // a verified answer ends the run
        await w.host.setResponseSigner(SoftwareSigner())
        try await fail(); try await fail()
        #expect(try await s.pinFailures() == 2)                                    // not 4: still no pairAgain
        await w.host.setResponseSigner(nil)
        let ok2 = try await w.serve(phone) { try await s.exchange(meta: httpGet) }
        #expect(ok2.status == 200)
    }

    // MARK: 6. nothing sealed under an old epoch after the handler

    private func answerAfterChange(_ change: @escaping @Sendable (World) async throws -> Void) async throws -> (World, [Data], Bridge.Header) {
        let w = try await World.make()
        let gate = HandlerGate()
        await w.host.setHandler({ _ in await gate.wait(); return .response(status: 200, headers: [:], data: Data("secret".utf8)) })
        let (env, h) = try await w.sealedRequest(rid: ID16.fresh(0x51), meta: ["op": "http", "method": "GET", "path": "/x", "headers": .object([:])])
        let host = w.host
        let t = Task { await host.process(envelope: env, mailbox: h.rid) }
        while !gate.isEntered { await Task.yield() }
        try await change(w)
        gate.open()
        return (w, await t.value, h)
    }

    private func expectOnlyUnknownRefusal(_ w: World, _ chunks: [Data], _ h: Bridge.Header) async throws {
        #expect(chunks.count == 1)
        let wk1 = await w.host.wkFor(1)
        for c in chunks {
            let o = try openChunk(c, wk: wk1)
            #expect(o.header.flagSet.contains(.refusal) && o.header.flagSet.contains(.last) && o.header.epoch == 1)
            #expect(o.meta == unknownRefusal.meta && o.data.isEmpty)
            #expect(c.range(of: Data("secret".utf8)) == nil)
        }
        let rec = await w.host.coreState().rids[h.rid]
        #expect(rec?.outcome == nil)                                       // nothing stored to replay later either
    }

    // Reviewer's S2: rotation and revocation while the handler runs.
    @Test func S2_responseSealedUnderOldEpochAfterRevocationDuringHandler() async throws {
        let (w, chunks, h) = try await answerAfterChange { w in
            try await w.host.rotate(remaining: [(w.primary.deviceKeys, World.all)], relay: w.relay, session: w.hostSession)
            await w.host.markRevoked(w.phoneID)
        }
        try await expectOnlyUnknownRefusal(w, chunks, h)
    }

    @Test func removalDuringTheHandlerGivesNoData() async throws {
        let (w, chunks, h) = try await answerAfterChange { w in await w.host.setRoster([(w.primary.deviceKeys, World.all)]) }
        try await expectOnlyUnknownRefusal(w, chunks, h)
    }

    @Test func rotationAloneDuringTheHandlerGivesNoDataUnderTheOldEpoch() async throws {
        let (w, chunks, h) = try await answerAfterChange { w in
            try await w.host.rotate(remaining: [(w.primary.deviceKeys, World.all), (w.phone, ["look", "decide"])], relay: w.relay, session: w.hostSession)
        }
        try await expectOnlyUnknownRefusal(w, chunks, h)
        #expect(await w.host.epoch == 2)
    }

    @Test func rotationEndsOpenStreamsWithAStaleEpochRefusal() async throws {
        let w = try await World.make()
        let gate = HandlerGate()
        await w.host.setHandler({ _ in await gate.wait(); return .response(status: 200, headers: [:], data: Data("frames".utf8)) })
        let (env, h) = try await w.sealedRequest(rid: ID16.fresh(0x52), flags: [.stream], meta: ["op": "http", "method": "GET", "path": "/s", "headers": .object([:])])
        let host = w.host
        let t = Task { await host.process(envelope: env, mailbox: h.rid) }
        while !gate.isEntered { await Task.yield() }
        #expect(await w.host.coreState().streams[h.rid] == w.phoneID)
        try await w.host.rotate(remaining: [(w.primary.deviceKeys, World.all), (w.phone, ["look", "decide"])], relay: w.relay, session: w.hostSession)
        #expect(await w.host.coreState().streams.isEmpty)
        let out = await w.host.takeOutbox()
        #expect(out.count == 1 && out[0].rid == h.rid)
        let o = try openChunk(out[0].chunk, wk: await w.host.wkFor(1))
        #expect(o.header.flagSet == [.last, .refusal, .stream] && o.header.epoch == 1 && o.header.rid == h.rid)
        #expect(o.meta == HostRefusal.staleEpoch(epoch: 2).meta && o.data.isEmpty)
        gate.open()
        #expect(await t.value.isEmpty)                                    // the late answer of the ended stream is discarded
    }

    // MARK: 7. revocation op rotates

    // Reviewer's S3, with epoch, grants and roster asserted through the bridge path.
    @Test func S3_revocationOpRotatesBeforeAnythingNewIsSealed() async throws {
        let w = try await World.make()
        await w.host.setHandler({ _ in .response(status: 200, headers: [:], data: Data("after".utf8)) })
        let phone = try await w.makePhone()
        let s = phone.session
        let rid = ID16.fresh(0x53)
        await w.host.adoptStream(rid: rid, owner: w.primaryID)                                              // an open stream of the device to be revoked
        let record = try await w.primary.revoke(device: w.primaryID)
        let r = try await w.serve(phone) { try await s.exchange(meta: ["op": "revocation", "record": record]) }
        #expect(r.status == 200)
        let core = await w.host.coreState()
        #expect(await w.host.epoch == 2 && core.epoch == 2 && core.keys[2] != nil && core.keys[1] != nil)
        #expect(core.revoked.contains(w.primaryID) && Set(core.members.keys) == [w.phoneID])
        #expect(core.streams[rid] == nil)
        #expect(await w.relay.hasGrant(workspace: w.ws, device: w.phoneID, epoch: 2))
        #expect(await w.relay.hasGrant(workspace: w.ws, device: w.primaryID, epoch: 2) == false)
        #expect((await w.relay.memberListSeq(workspace: w.ws) ?? 0) >= 2)
        // The phone follows: its next request is refused stale_epoch once, then runs at epoch 2.
        let next = try await w.serve(phone) { try await s.exchange(meta: httpGet) }
        let epochNow = try await s.currentEpoch()
        #expect(next.data == Data("after".utf8) && epochNow == 2)
    }

    @Test func aRevocationOfANonMemberDoesNotRotate() async throws {
        let w = try await World.make()
        let phone = try await w.makePhone()
        let s = phone.session
        let record = try await w.primary.revoke(device: ID16.fresh(0x77))
        let r = try await w.serve(phone) { try await s.exchange(meta: ["op": "revocation", "record": record]) }
        let hostEpoch = await w.host.epoch
        #expect(r.status == 200 && hostEpoch == 1)
    }

    // MARK: 8. unlisted pre-grants

    // Reviewer's S4: a next-epoch grant uploaded ahead of its list (section 7.2 order) is kept, not used.
    @Test func S4_preGrantForNextEpochDoesNotStrandThePhone() async throws {
        let w = try await World.make()
        await w.host.setHandler({ _ in .response(status: 200, headers: [:], data: Data("ok".utf8)) })
        try await w.relay.putGrant(try await w.host.grant(for: w.phone, epoch: 2), token: w.hostSession.token)
        let phone = try await w.makePhone()
        let s = phone.session
        #expect(try await s.currentEpoch() == 1)
        let r = try await w.serve(phone) { try await s.exchange(meta: httpGet) }
        let e1 = try await s.currentEpoch()
        #expect(r.data == Data("ok".utf8) && e1 == 1)
        #expect(try w.vault.ids().filter { $0.ws == w.ws.hex }.map(\.purpose).sorted() == ["wk.1", "wk.2"])         // kept
        // The host now reaches epoch 2 (list published): the first refusal confirms it and the stored grant is used.
        await w.host.installEpoch(2)
        try await w.relay.putGrant(try await w.host.grant(for: w.primary.deviceKeys, epoch: 2), token: w.hostSession.token)
        try await w.relay.publishMemberList(try await w.host.memberList([(w.primaryID, World.all), (w.phoneID, ["look", "decide"])], epoch: 2, listSeq: 2),
                                            token: w.hostSession.token)
        let r2 = try await w.serve(phone) { try await s.exchange(meta: httpGet) }
        let e2 = try await s.currentEpoch()
        #expect(r2.status == 200 && e2 == 2)
    }

    // MARK: S5, with the host's persistence contract

    // A relay replaying accepted bytes is harmless while the host kept EITHER the sequence window OR the rid store. Only a host
    // that loses both re-runs it, which is why a real host persists them atomically together (gaps.md).
    @Test(arguments: [(false, false, 1), (true, false, 1), (false, true, 1), (true, true, 2)])
    func S5_relayReplayAgainstAHostThatLostState(lostSeq: Bool, lostRids: Bool, runs: Int) async throws {
        let w = try await World.make()
        let counter = Counter()
        await w.host.setHandler({ _ in counter.bump(); return .response(status: 200, headers: [:], data: Data()) })
        let (env, h) = try await w.sealedRequest(rid: ID16.fresh(0x55))
        _ = await w.host.process(envelope: env, mailbox: h.rid)
        #expect(counter.value == 1)
        await w.host.loseBridgeState(seq: lostSeq, rids: lostRids)
        _ = await w.host.process(envelope: env, mailbox: h.rid)
        #expect(counter.value == runs)
    }
}

// MARK: 10/11. HostBridgeCore quotas and pruning

@Suite struct HostCoreLimitTests {
    struct Rig {
        var core: HostBridgeCore
        let signer = SoftwareSigner()
        let device: ID16
        let wk = SymmetricKey(data: Data(repeating: 4, count: 32))
        let ws = ID16.fresh(0x31)
        init() {
            device = Identifiers.deviceID(signer.publicKey)
            core = HostBridgeCore(workspace: ws, epoch: 1)
            core.keys[1] = wk; core.members[device] = ["look"]; core.devicePubs[device] = signer.publicKey
        }
        func request(_ n: UInt8, ts: Int64 = 1_790_000_000_000) throws -> (Data, ID16) {
            let rid = ID16.fresh(n)
            let h = Bridge.Header(direction: .toHost, workspace: ws, device: device, rid: rid, seq: UInt64(n), tsMs: UInt64(ts), epoch: 1,
                                  salt: Data(repeating: n, count: 16))
            return (try Bridge.seal(header: h, channelKey: Bridge.channelKey(header: h, wk: wk)!, signer: signer,
                                    plaintext: Bridge.frame(meta: httpGet, data: Data())), rid)
        }
    }
    let t0: Int64 = 1_790_000_000_000

    @Test func expiredRidRecordsArePruned() throws {
        var rig = Rig()
        let (e1, r1) = try rig.request(1)
        guard case .accept = rig.core.check(e1, mailbox: r1, nowMs: t0) else { Issue.record("accept"); return }
        #expect(rig.core.rids[r1] != nil)
        #expect(rig.core.rids[r1]?.until == t0 + 900_000)
        // Any later envelope, even garbage, finds the expired record gone.
        _ = rig.core.check(Data(), mailbox: nil, nowMs: t0 + 899_999)
        #expect(rig.core.rids[r1] != nil)
        _ = rig.core.check(Data(), mailbox: nil, nowMs: t0 + 900_000)
        #expect(rig.core.rids.isEmpty)
    }

    @Test func allowanceBoundary() throws {
        var rig = Rig()
        rig.core.limits.perDevice = 3; rig.core.limits.busyAllowance = 2
        var results: [String] = []
        for n in 1...7 {
            let (e, r) = try rig.request(UInt8(n), ts: t0)
            switch rig.core.check(e, mailbox: r, nowMs: t0) {
            case .accept: results.append("accept")
            case .refuse(let x, _): results.append(x.code)
            case .drop(let why): results.append("drop:" + why)
            case .replay: results.append("replay")
            }
            if n == 3 { #expect(rig.core.rids.count == 3) }
        }
        // 3 run; then busy is recorded up to perDevice + allowance (5 records); past that it is dropped.
        #expect(results == ["accept", "accept", "accept", "busy", "busy", "drop:busy_unrecordable", "drop:busy_unrecordable"])
        #expect(rig.core.rids.count == 5)
        #expect(rig.core.seq[rig.device]?.high == 3)                  // quota refusals precede the sequence step: seq 4..7 never consumed
        // A recorded busy refusal is replayed as busy for the same bytes, and records expire so the device recovers.
        let (e4, r4) = try rig.request(4, ts: t0)
        if case .refuse(.busy, _) = rig.core.check(e4, mailbox: r4, nowMs: t0 + 1) {} else { Issue.record("busy replay") }
        let (e8, r8) = try rig.request(8, ts: t0 + 900_001)
        guard case .accept = rig.core.check(e8, mailbox: r8, nowMs: t0 + 900_001) else { Issue.record("recovered"); return }
        #expect(rig.core.rids.count == 1)
    }

    @Test func maxRecordsBoundary() throws {
        var rig = Rig()
        rig.core.limits.maxRecords = 3
        var results: [String] = []
        for n in 1...5 {
            let (e, r) = try rig.request(UInt8(n), ts: t0)
            switch rig.core.check(e, mailbox: r, nowMs: t0) {
            case .accept: results.append("accept")
            case .refuse(let x, _): results.append(x.code)
            case .drop(let why): results.append("drop:" + why)
            case .replay: results.append("replay")
            }
        }
        #expect(results == ["accept", "accept", "accept", "drop:store_full", "drop:store_full"])
        #expect(rig.core.rids.count == 3)
        #expect(rig.core.seq[rig.device]?.high == 5)                 // the sequence is consumed before the record is attempted
        // A full store also drops a recorded refusal (quota path) instead of growing.
        rig.core.limits.perDevice = 1
        let (e6, r6) = try rig.request(6, ts: t0)
        #expect(rig.core.check(e6, mailbox: r6, nowMs: t0) == .drop("store_full"))
        #expect(rig.core.rids.count == 3)
    }
}

@Suite struct RotationGate2a {
    final class Fail: @unchecked Sendable { let l = NSLock(); var on = true
        var value: Bool { get { l.withLock { on } } set { l.withLock { on = newValue } } } }

    // A handler returning while the rotation's grants are being published must not seal data.
    @Test func handlerFinishingDuringPublicationGetsNoData() async throws {
        let w = try await World.make()
        let hgate = HandlerGate(), pub = HandlerGate()
        await w.host.setHandler({ _ in await hgate.wait(); return .response(status: 200, headers: [:], data: Data("secret".utf8)) })
        let (env, h) = try await w.sealedRequest(rid: ID16.fresh(0x61), meta: ["op": "http", "method": "GET", "path": "/x", "headers": .object([:])])
        let host = w.host
        let t = Task { await host.process(envelope: env, mailbox: h.rid) }
        while !hgate.isEntered { await Task.yield() }
        // pump registers the relay; then a revocation (of the primary) starts a rotation parked in publication
        _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession)
        await w.host.setPublishHook { await pub.wait() }
        let record = try await w.primary.revoke(device: w.primaryID)
        let (renv, rh) = try await w.sealedRequest(rid: ID16.fresh(0x62), seq: 2, meta: ["op": "revocation", "record": record])
        _ = rh
        let rt = Task { await host.process(envelope: renv, mailbox: rh.rid) }
        while !pub.isEntered { await Task.yield() }
        hgate.open()                                   // handler returns mid-publication
        for _ in 0..<200 { await Task.yield() }
        pub.open()
        let chunks = await t.value
        _ = await rt.value
        let o = try openChunk(chunks[0], wk: await w.host.wkFor(1))
        #expect(chunks.count == 1 && o.meta == unknownRefusal.meta)
        #expect(chunks[0].range(of: Data("secret".utf8)) == nil)
    }

    @Test func failedPublicationKeepsRotationRequiredAndRetries() async throws {
        let w = try await World.make()
        let counter = Counter()
        await w.host.setHandler({ _ in counter.bump(); return .response(status: 200, headers: [:], data: Data("data".utf8)) })
        _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession)
        let fail = Fail()
        await w.host.setPublishHook { if fail.value { throw TestCrash() } }
        let record = try await w.primary.revoke(device: w.primaryID)
        let (renv, rh) = try await w.sealedRequest(rid: ID16.fresh(0x63), seq: 1, meta: ["op": "revocation", "record": record])
        let c1 = await w.host.process(envelope: renv, mailbox: rh.rid)
        let m1 = try openChunk(c1[0], wk: await w.host.wkFor(1)).meta
        #expect(m1 == unknownRefusal.meta)
        let rr = await w.host.rotationRequired, ep = await w.host.epoch
        #expect(rr && ep == 1)
        // requests during rotationRequired get no data and do not run
        let (e2, h2) = try await w.sealedRequest(rid: ID16.fresh(0x64), seq: 2)
        let c2 = await w.host.process(envelope: e2, mailbox: h2.rid)
        let m2 = try openChunk(c2[0], wk: await w.host.wkFor(1)).meta
        #expect(c2.count == 1 && m2 == unknownRefusal.meta && counter.value == 0)
        // next pump retries; once it succeeds the epoch moves and requests work at epoch 2
        fail.value = false
        _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession)
        let rr2 = await w.host.rotationRequired, ep2 = await w.host.epoch
        #expect(!rr2 && ep2 == 2)
        let (e3, h3) = try await w.sealedRequest(rid: ID16.fresh(0x65), seq: 3, epoch: 2)
        let c3 = await w.host.process(envelope: e3, mailbox: h3.rid)
        let d3 = try openChunk(c3[0], wk: await w.host.wkFor(2)).data
        #expect(d3 == Data("data".utf8))
    }

    @Test func resubmittedRevocationRotatesAfterAFailedPublication() async throws {
        let w = try await World.make()
        _ = try await w.host.pump(relay: w.relay, transport: w.transport, session: w.hostSession)
        let fail = Fail()
        await w.host.setPublishHook { if fail.value { throw TestCrash() } }
        let record = try await w.primary.revoke(device: w.primaryID)
        let (e1, h1) = try await w.sealedRequest(rid: ID16.fresh(0x66), seq: 1, meta: ["op": "revocation", "record": record])
        _ = await w.host.process(envelope: e1, mailbox: h1.rid)
        fail.value = false
        let (e2, h2) = try await w.sealedRequest(rid: ID16.fresh(0x67), seq: 2, meta: ["op": "revocation", "record": record])
        let c = await w.host.process(envelope: e2, mailbox: h2.rid)
        let mc = try openChunk(c[0], wk: await w.host.wkFor(1)).meta
        #expect(mc.object?["status"] == .int(200))
        let rr3 = await w.host.rotationRequired, ep3 = await w.host.epoch
        #expect(ep3 == 2 && !rr3)
    }
}

extension FakeHost {
    func setPublishHook(_ h: (@Sendable () async throws -> Void)?) { publishHook = h }
    var rotationRequiredFlag: Bool { rotationRequired }
}
