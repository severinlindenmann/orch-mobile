import CryptoKit
import Foundation
import Testing
@testable import OrchClient
@testable import OrchFakeHost
import OrchCustody
import OrchProtocol
import OrchStore

/// Sees every request that reaches the fake relay, can answer one itself, and can run code just before a request goes through.
actor DropRecordingSender: RequestSender, InProcessDemoSender {
    struct Seen: Sendable {
        let method: String, target: String, contentType: String?, ifMatch: String?
        let streamed: Bool
        /// The PUT frame (materialised from its file body inside `send`), nil for every other request.
        let frame: Data?
    }
    nonisolated let origin: String
    private let relay: FakeRelay
    private(set) var log: [Seen] = []
    private var answer: (@Sendable (WireRequest) async throws -> WireReply?)?
    private var before: (@Sendable (WireRequest) async throws -> Void)?
    init(_ relay: FakeRelay) { self.relay = relay; origin = relay.origin }
    func intercept(_ f: (@Sendable (WireRequest) async throws -> WireReply?)?) { answer = f }
    func beforeEach(_ f: (@Sendable (WireRequest) async throws -> Void)?) { before = f }
    func reset() { log = [] }
    func requests(_ method: String, containing part: String) -> [Seen] { log.filter { $0.method == method && $0.target.contains(part) } }

    func send(_ request: WireRequest) async throws -> WireReply {
        let isPut = request.method == "PUT" && request.target.hasSuffix("/versions")
        log.append(Seen(method: request.method, target: request.target, contentType: request.header("content-type"), ifMatch: request.header("if-match"),
                        streamed: request.bodyFile != nil, frame: isPut ? try request.materialized().body : nil))
        if let before { try await before(request) }
        if let answer, let reply = try await answer(request) { return reply }
        return try await relay.send(request)
    }
}

/// A one-shot switch the interception closures can flip.
final class DropFlag: @unchecked Sendable {
    private let lock = NSLock(); private var on: Bool
    init(_ on: Bool) { self.on = on }
    /// true exactly once while the flag was on
    func take() -> Bool { lock.withLock { let was = on; on = false; return was } }
}

func dropJSONReply(_ status: Int, _ fields: [String: JSONValue], headers: [String: String] = [:]) throws -> WireReply {
    var h = headers; h["content-type"] = "application/json"
    return try WireReply(status: status, headers: h, body: canonicalJSON(.object(fields)))
}

struct DropAlignmentWorld {
    let w: World
    let sender: DropRecordingSender
    let phone: Phone
    let service: DropService

    static func make(limits: RelayLimits = RelayLimits(), ownerKey: Bool = true) async throws -> DropAlignmentWorld {
        let w = try await World.drop(limits: limits)
        let sender = DropRecordingSender(w.relay)
        let transport = try RoutedRelayTransport(context: w.env.context, origin: w.env.context.origin, sender: sender, clientAddress: "test")
        let phone = try await w.makePhone(transport: transport)
        let raw = try await RelayClient(transport: w.transport).card(workspace: w.ws, session: w.phoneSession)
        let service = try DropService(session: phone.session, card: Card.verify(raw, ownerKey: w.primary.publicKey), ownerKey: ownerKey ? w.primary.publicKey : nil)
        return DropAlignmentWorld(w: w, sender: sender, phone: phone, service: service)
    }

    func advance(_ ms: Int64) { phone.clock.advance(milliseconds: ms); w.clock.advance(milliseconds: ms) }

    func storedHead(_ object: ID16, version: UInt32 = 1) async throws -> DropFrame.Parts {
        let db = try await phone.container.database()
        let body = try #require(await db.query("SELECT body FROM drop_uploads WHERE object=? AND version=?", [.text(object.hex), .int(Int64(version))]).first?.blob("body"))
        return try DropFrame.parse(body).parts
    }

    func retire(_ object: DropObject) async throws -> WireReply {
        let hash = try DropDescriptor.parentHash(of: object.descriptor.raw)
        let body = try canonicalJSON(["expect_version": .int(Int64(object.descriptor.version)), "expect_head": .string(B64U.encode(hash))])
        return try await w.relay.send(WireRequest(method: "POST", target: "/v2/drop/\(object.descriptor.object.hex)/retire",
            headers: ["authorization": "Bearer \(w.hostSession.token)", "content-type": "application/json"], body: body, clientAddress: "test"))
    }
}

@Suite struct DropRelayAlignmentTests {
    // MARK: list (item 1)

    @Test func listWalksEveryPageOfNext() async throws {
        var limits = RelayLimits(); limits.dropListPageSize = 2
        let a = try await DropAlignmentWorld.make(limits: limits)
        for i in 0..<5 { _ = try await a.service.send(Data("n\(i)".utf8), name: "f\(i)") }
        await a.sender.reset()
        let listed = try await a.service.listVerifiedRows(.sending)
        #expect(listed.objects.count == 5 && listed.blocked.isEmpty && listed.gone.isEmpty)
        let pages = await a.sender.requests("POST", containing: "/drop/list")
        #expect(pages.count == 3)
    }

    @Test func anObjectOnTwoPagesOfOneWalkAppearsOnceAtItsHigherVersion() async throws {
        let a = try await DropAlignmentWorld.make()
        let v1 = try await a.service.send(Data("one".utf8), name: "d", kind: .document)
        let query = try canonicalJSON(["workspace_id": .string(a.w.ws.hex), "direction": "sending"])
        let early = try json(await a.w.transport.dropList(query, session: a.w.phoneSession))["objects"]!.array!
        _ = try await a.service.send(Data("two".utf8), name: "d", document: v1)
        let late = try json(await a.w.transport.dropList(query, session: a.w.phoneSession))["objects"]!.array!
        await a.sender.intercept { r in
            guard r.target.hasSuffix("/drop/list") else { return nil }
            return try dropJSONReply(200, ["objects": .array(late + early), "next": .null])
        }
        let listed = try await a.service.list(.sending)
        #expect(listed.count == 1 && listed[0].descriptor.version == 2)
    }

    @Test func expiredAndRetiredObjectsAreListedAsGoneAndCannotBeOpened() async throws {
        let a = try await DropAlignmentWorld.make()
        let file = try await a.service.send(Data("f".utf8), name: "f", expiresMs: a.phone.clock.nowMs + 61_000)
        let doc = try await a.service.send(Data("d".utf8), name: "d", kind: .document)
        #expect(try await a.service.listVerifiedRows(.sending).objects.count == 2)
        #expect(try await a.retire(doc).status == 200)
        a.advance(62_000)
        let listed = try await a.service.listVerifiedRows(.sending)
        #expect(listed.objects.isEmpty && listed.blocked.isEmpty)
        let gone = Dictionary(uniqueKeysWithValues: listed.gone.map { ($0.object, $0) })
        #expect(gone[file.descriptor.object]?.reason == .expired && gone[file.descriptor.object]?.label == "Expired")
        #expect(gone[doc.descriptor.object]?.reason == .retired && gone[doc.descriptor.object]?.label == "Removed by your Mac")
        #expect(gone[doc.descriptor.object]?.tombstoneUntilMs != nil)
        // no open, no download: 410 is final and never a fork or rollback
        await #expect(throws: DropError.expired) { _ = try await a.service.download(file) }
        await #expect(throws: DropError.expired) { _ = try await a.service.download(doc) }
        // after the 30-day tombstone both are simply gone from the list
        a.advance(31 * 86_400_000)
        let later = try await a.service.listVerifiedRows(.sending)
        #expect(later.objects.isEmpty && later.gone.isEmpty)
    }

    @Test func anUnknownStateIsNotLiveAndAnUnknownKeyBlocksTheEntry() async throws {
        let a = try await DropAlignmentWorld.make()
        _ = try await a.service.send(Data("x".utf8), name: "x")
        _ = try await a.service.send(Data("y".utf8), name: "y")
        let query = try canonicalJSON(["workspace_id": .string(a.w.ws.hex), "direction": "sending"])
        let page = try json(await a.w.transport.dropList(query, session: a.w.phoneSession))
        var entries = page["objects"]!.array!.map { $0.object! }
        entries[0]["state"] = "frozen"
        entries[1]["surprise"] = true
        let frozen = entries
        await a.sender.intercept { r in
            guard r.target.hasSuffix("/drop/list") else { return nil }
            return try dropJSONReply(200, ["objects": .array(frozen.map { .object($0) }), "next": .null])
        }
        let listed = try await a.service.listVerifiedRows(.sending)
        #expect(listed.objects.isEmpty && listed.blocked.count == 1)
        #expect(listed.gone.count == 1 && listed.gone[0].reason == .unavailable)
    }

    @Test func aMalformedPageOrAStuckCursorFailsTheList() async throws {
        let a = try await DropAlignmentWorld.make()
        _ = try await a.service.send(Data("x".utf8), name: "x")
        let query = try canonicalJSON(["workspace_id": .string(a.w.ws.hex), "direction": "sending"])
        let page = try json(await a.w.transport.dropList(query, session: a.w.phoneSession))
        let objects = page["objects"]!
        for body in [["objects": objects], ["objects": objects, "next": .null, "extra": 1], ["objects": objects, "next": "abc"],
                     // a cursor that never moves would walk forever
                     ["objects": objects, "next": 5]] as [[String: JSONValue]] {
            await a.sender.intercept { r in
                guard r.target.hasSuffix("/drop/list") else { return nil }
                return try dropJSONReply(200, body)
            }
            await #expect(throws: (any Error).self) { _ = try await a.service.listVerifiedRows(.sending) }
        }
    }

    @Test func theChainIsReadFromDescriptorPagesAndOnlyPastTheHead() async throws {
        let a = try await DropAlignmentWorld.make()
        var object = try await a.service.send(Data("1".utf8), name: "d", kind: .document)
        object = try await a.service.send(Data("2".utf8), name: "d", document: object)
        _ = try await a.service.list(.sending)                  // the head (version 2) is persisted
        await a.sender.reset()
        object = try await a.service.send(Data("3".utf8), name: "d", document: object)
        #expect(object.descriptor.version == 3)
        let perVersion = await a.sender.log.filter { $0.method == "GET" && ($0.target.contains("/versions/1/descriptor") || $0.target.contains("/versions/2/descriptor")) }
        #expect(perVersion.isEmpty)
        let pages = await a.sender.requests("GET", containing: "/descriptors")
        #expect(pages.count == 1 && pages[0].target.hasSuffix("/descriptors?after=1"))
    }

    // MARK: upload (items 2 and 4)

    @Test func theUploadIsAnOctetStreamODU2FrameStreamedFromAFileWithoutABlobReadBack() async throws {
        let a = try await DropAlignmentWorld.make()
        await a.sender.reset()
        let object = try await a.service.send(Data("frame".utf8), name: "frame.txt")
        let puts = await a.sender.requests("PUT", containing: "/versions")
        #expect(puts.count == 1)
        let put = try #require(puts.first)
        #expect(put.contentType == "application/octet-stream" && put.ifMatch == "0" && put.streamed)
        let frame = try #require(put.frame)
        #expect(frame.prefix(4) == Data("ODU2".utf8))
        let parts = try DropFrame.parseHead(frame.prefix(DropFrame.prefixLength + DropFrame.maxHeadBytes), total: frame.count)
        #expect(frame.count == 8 + parts.headLength + Int(object.descriptor.contentLen))
        // the descriptor is the whole confirmation: no blob is read back
        #expect(await a.sender.requests("GET", containing: "/blob").isEmpty)
    }

    @Test func filesExpireSevenDaysLessTenMinutesAndDocumentsNeverExpire() async throws {
        let a = try await DropAlignmentWorld.make()
        let now = a.phone.clock.nowMs
        let file = try await a.service.send(Data("f".utf8), name: "f")
        let doc = try await a.service.send(Data("d".utf8), name: "d", kind: .document)
        #expect(file.descriptor.expiresMs == now + 604_800_000 - 600_000)
        #expect(doc.descriptor.expiresMs == nil)
        let next = try await a.service.send(Data("e".utf8), name: "d", document: doc)
        #expect(next.descriptor.expiresMs == nil)
        await #expect(throws: DropError.malformed) { _ = try await a.service.send(Data("x".utf8), name: "x", expiresMs: now + 90_000, kind: .document) }
        // a compose send seals with the same margin
        let ids = try await a.service.sealSend(UUID(), attachments: [DropSendAttachment(id: UUID(), data: Data("c".utf8), name: "c")])
        #expect(try await a.storedHead(ids[0].object).descriptor.object?["o"]?.object?["expires_ms"] == .int(now + 604_800_000 - 600_000))
    }

    @Test func aPendingJSONRowIsReframedNotResealed() async throws {
        let a = try await DropAlignmentWorld.make()
        let id = ID16.fresh(0x91), db = try await a.phone.container.database()
        let frame = try await a.w.dropBody(id: id)
        let legacy = try DropTestFrame.legacyBody(frame)
        try await db.execute("INSERT INTO drop_uploads(object,version,body,done) VALUES(?,1,?,0)", [.text(id.hex), .blob(legacy)])
        let results = try await a.service.resumeUploads()
        let sent = try #require(results.first).result.get()
        // the relay holds the very descriptor and blob that were sealed into the old row
        let parts = try DropFrame.parse(frame).parts
        let stored = try json(await a.w.transport.dropGet(objectID: id, version: 1, part: .descriptor, session: a.w.phoneSession))["descriptor"]
        #expect(stored == parts.descriptor && sent.signed == parts.descriptor)
        let migrated = try #require(await db.query("SELECT body FROM drop_uploads WHERE object=?", [.text(id.hex)]).first?.blob("body"))
        #expect(migrated == frame)
    }

    @Test func aDiscardRecordedForAJSONRowSurvivesTheMigration() async throws {
        let a = try await DropAlignmentWorld.make()
        let id = ID16.fresh(0x92), db = try await a.phone.container.database()
        let frame = try await a.w.dropBody(id: id)
        let legacy = try DropTestFrame.legacyBody(frame)
        let oldKey = "upload:\(id.hex):1:\(B64U.encode(Data(SHA256.hash(data: legacy))))"
        try await db.execute("INSERT INTO drop_uploads(object,version,body,done) VALUES(?,1,?,0)", [.text(id.hex), .blob(legacy)])
        try await db.execute("INSERT INTO drop_abandoned(key) VALUES(?)", [.text(oldKey)])
        let results = try await a.service.resumeUploads()
        #expect(results.count == 1)
        if case .failure(let e) = results[0].result { #expect(e as? DropError == .abandoned) } else { Issue.record("an abandoned upload was sent") }
        #expect(await a.sender.requests("PUT", containing: "/versions").isEmpty)
    }

    @Test func anExactRetryAnswers200AndCounts() async throws {
        let a = try await DropAlignmentWorld.make()
        let object = try await a.service.send(Data("once".utf8), name: "once")
        let db = try await a.phone.container.database()
        // the row is sent again (as after a lost answer whose read-back also failed): the relay recognises the descriptor
        try await db.execute("UPDATE drop_uploads SET done=0 WHERE object=?", [.text(object.descriptor.object.hex)])
        let hide = DropFlag(true)
        await a.sender.intercept { r in
            guard r.method == "GET", r.target.hasSuffix("/versions/1/descriptor"), hide.take() else { return nil }
            return try dropJSONReply(404, ["error": "not_found"])
        }
        await a.sender.reset()
        let again = try #require(try await a.service.resumeUploads().first).result.get()
        #expect(again.descriptor == object.descriptor)
        #expect(await a.sender.requests("PUT", containing: "/versions").count == 1)
    }

    // MARK: refusals (item 3)

    @Test func aFullQuotaIsTerminalForNowAndNotRetriedBeforeItsRetryAfter() async throws {
        let a = try await DropAlignmentWorld.make()
        await a.w.relay.scriptNextDropPut(try dropJSONReply(429, ["error": "quota_exceeded", "quota": "drop_ws"], headers: ["retry-after": "600"]))
        await #expect(throws: DropError.storageFull(quota: "drop_ws", retryAfterSeconds: 600)) { _ = try await a.service.send(Data("big".utf8), name: "big") }
        // the sealed row is kept; a retry inside the window sends nothing
        let pending = try await a.phone.container.database().query("SELECT object FROM drop_uploads WHERE done=0")
        #expect(pending.count == 1)
        await a.sender.reset()
        let early = try await a.service.resumeUploads()
        if case .failure(let e) = try #require(early.first).result { #expect(e as? DropError == .storageFull(quota: "drop_ws", retryAfterSeconds: 600)) }
        else { Issue.record("sent inside the back-off") }
        #expect(await a.sender.requests("PUT", containing: "/versions").isEmpty)
        // after the window the same row goes through
        a.advance(601_000)
        _ = try #require(try await a.service.resumeUploads().first).result.get()
        #expect(try await a.service.failedUploads().isEmpty)
    }

    @Test func aSlotCapARateLimitAnOverloadAreTransient() async throws {
        let a = try await DropAlignmentWorld.make()
        let cases: [(WireReply, Int)] = [
            (try dropJSONReply(429, ["error": "quota_exceeded", "quota": "slot"], headers: ["retry-after": "3"]), 3),
            (try dropJSONReply(429, ["error": "rate_limited"], headers: ["retry-after": "11"]), 11),
            (try dropJSONReply(503, ["error": "overloaded"], headers: ["retry-after": "7"]), 7)]
        for (i, (reply, seconds)) in cases.enumerated() {
            await a.w.relay.scriptNextDropPut(reply)
            await #expect(throws: DropError.retryLater(afterSeconds: seconds)) { _ = try await a.service.send(Data("t\(i)".utf8), name: "t\(i)") }
        }
        #expect(try await a.service.failedUploads().isEmpty)           // none is terminal
        a.advance(15_000)
        let results = try await a.service.resumeUploads()
        #expect(results.count == 3 && results.allSatisfy { if case .success = $0.result { true } else { false } })
    }

    @Test func a410IsExpiredForGoodOnlyOnceTheSignedExpiryHasPassed() async throws {
        let a = try await DropAlignmentWorld.make()
        await a.w.relay.scriptNextDropPut(try dropJSONReply(410, ["error": "expired"]))
        await #expect(throws: DropError.possiblyRemoved) { _ = try await a.service.send(Data("late".utf8), name: "late") }
        #expect(try await a.service.failedUploads().isEmpty)          // the status alone is a hint
        #expect(try await a.service.stalledUploads().count == 1)       // but the user is told ("Removed by the host? Retry or discard")
        // inside the back-off nothing is asked of the relay again
        await a.sender.reset()
        _ = try await a.service.resumeUploads()
        let dropRequests = await a.sender.log.filter { $0.target.contains("/drop/") }
        #expect(dropRequests.isEmpty)
        a.advance(8 * 86_400_000)
        _ = try await a.service.resumeUploads()
        #expect(try await a.service.failedUploads().first?.reason == "expired")
    }

    @Test func aRotationRequiredIsWaitedForNotFailed() async throws {
        let a = try await DropAlignmentWorld.make()
        await a.w.relay.scriptNextDropPut(try dropJSONReply(409, ["error": "rotation_required", "epoch": 1]))
        await #expect(throws: DropError.rotationPending) { _ = try await a.service.send(Data("w".utf8), name: "w") }
        #expect(try await a.service.failedUploads().isEmpty)
    }

    @Test func notEligibleAndWrapConflictOnAPutAreRejectedOrConflict() async throws {
        let a = try await DropAlignmentWorld.make()
        await a.w.relay.scriptNextDropPut(try dropJSONReply(403, ["error": "not_eligible"]))
        await #expect(throws: DropError.uploadRejected(status: 403)) { _ = try await a.service.send(Data("n".utf8), name: "n") }
        await a.w.relay.scriptNextDropPut(try dropJSONReply(413, ["error": "too_large"]))
        await #expect(throws: DropError.uploadRejected(status: 413)) { _ = try await a.service.send(Data("n2".utf8), name: "n2") }
        #expect(try await a.service.failedUploads().count == 2)
    }

    @Test func aStaleEpochRaceRewrapsTheSameDEKAndNeverTrustsTheHint() async throws {
        let a = try await DropAlignmentWorld.make()
        // the list moves to epoch 2 after the phone fetched the signed list and before its PUT arrives
        let w = a.w
        let rotate = DropFlag(true)
        await a.sender.beforeEach { r in
            guard r.method == "PUT", r.target.hasSuffix("/versions"), rotate.take() else { return }
            try await w.host.rotate(remaining: [(w.phone, World.all)], relay: w.relay, session: w.hostSession)
        }
        let sent = try await a.service.send(Data("rewrapped".utf8), name: "race")
        let puts = await a.sender.requests("PUT", containing: "/versions")
        #expect(puts.count == 2)
        let first = try DropFrame.parse(#require(puts[0].frame)), second = try DropFrame.parse(#require(puts[1].frame))
        // same descriptor and blob: nothing was resealed; only the wk wrap moved to the epoch the signed list confirms
        #expect(first.parts.descriptor == second.parts.descriptor && first.blob == second.blob)
        let wk = { (p: DropFrame.Parts) in try p.wraps.map(DropWrapRecord.init(json:)).filter { $0.targetKind == .wk }.map(\.keyVersion) }
        #expect(try wk(first.parts) == [1] && wk(second.parts) == [2])
        #expect(sent.descriptor.dekCommit == (try DropDescriptor(object: first.parts.descriptor.object!["o"]!.object!)).dekCommit)
        let url = try await a.service.download(sent)
        #expect(try Data(contentsOf: url) == Data("rewrapped".utf8))
    }

    @Test func aStaleEpochHintThatTheSignedListDoesNotConfirmChangesNothing() async throws {
        let a = try await DropAlignmentWorld.make()
        await a.w.relay.scriptNextDropPut(try dropJSONReply(409, ["error": "stale_epoch", "epoch": 9]))
        let sent = try await a.service.send(Data("lie".utf8), name: "lie")
        #expect(try await a.phone.session.currentEpoch() == 1)
        #expect(sent.wraps.filter { $0.targetKind == .wk }.map(\.keyVersion) == [1])
    }

    @Test func aBadWxkVersionRefreshesTheCardAndRewrapsTheSameDEK() async throws {
        let a = try await DropAlignmentWorld.make()
        let w = a.w
        // the host rotates the card key: card_seq 2, wxk_version 2, a new WXK; the phone still holds version 1
        let newWXK = SoftwareKeyAgreer()
        let host = w.host
        let ck = SymmetricKey(data: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let part = CardSealedPart(name: "Laptop", description: "Demo workspace", capabilities: ["drop"], hostedBy: nil)
        let delegation = try #require(await host.cardDelegation)
        let sealed = try Card.sealPart(part, ck: ck, workspace: host.workspace, cardSeq: 2)
        let card = try Card.make(delegation: delegation, workspace: host.workspace, wxk: newWXK.publicKey, wxkVersion: 2, owner: w.primary.personID,
                                 relayURL: w.env.context.origin, cardSeq: 2, issuedMs: w.clock.nowMs, sealed: sealed, ck: ck, wsk: host.wsk)
        try await w.relay.publishCard(card)
        let heldCard = await a.service.card
        let sent = try await a.service.send(Data("new card".utf8), name: "rotated")
        let puts = await a.sender.requests("PUT", containing: "/versions")
        #expect(puts.count == 2)
        let first = try DropFrame.parse(#require(puts[0].frame)).parts, second = try DropFrame.parse(#require(puts[1].frame)).parts
        #expect(first.descriptor == second.descriptor)
        let versions = { (p: DropFrame.Parts) in try p.wraps.map(DropWrapRecord.init(json:)).filter { $0.targetKind == .wxk }.map(\.keyVersion) }
        #expect(try versions(first) == [1] && versions(second) == [2])
        #expect(sent.wraps.contains { $0.targetKind == .wxk && $0.keyVersion == 2 })
        // the card was verified under the pinned owner: a service without that key cannot repair it and waits
        let blind = try DropService(session: a.phone.session, card: heldCard, ownerKey: nil)
        await #expect(throws: DropError.unavailableKey) { _ = try await blind.send(Data("x".utf8), name: "x") }
        #expect(try await blind.failedUploads().isEmpty)
    }

    // MARK: relay-shaped errors never fail a sealed upload (round 2)

    @Test func aHostile201OrAnUnauthorisedPutLeavesTheRowRetryable() async throws {
        let a = try await DropAlignmentWorld.make()
        let replies: [WireReply] = [try dropJSONReply(201, ["version": 1, "extra": true]), try dropJSONReply(201, ["nope": 1]),
                                    try dropJSONReply(401, ["error": "unauthenticated"]), try dropJSONReply(404, ["error": "not_found"]),
                                    try dropJSONReply(408, ["error": "malformed"])]
        for (i, reply) in replies.enumerated() {
            await a.w.relay.scriptNextDropPut(reply)
            await #expect(throws: (any Error).self) { _ = try await a.service.send(Data("h\(i)".utf8), name: "h\(i)") }
        }
        #expect(try await a.service.failedUploads().isEmpty)
        let rows = try await a.phone.container.database().query("SELECT done FROM drop_uploads")
        #expect(rows.count == 5 && rows.allSatisfy { $0.int("done") == 0 })
        a.advance(61_000)
        let results = try await a.service.resumeUploads()
        #expect(results.count == 5 && results.allSatisfy { if case .success = $0.result { true } else { false } })
    }

    @Test func aBadChainPageAfterTheReadBackNeverFailsAConfirmedUpload() async throws {
        let a = try await DropAlignmentWorld.make()
        let v1 = try await a.service.send(Data("1".utf8), name: "d", kind: .document)
        await a.sender.intercept { r in
            guard r.target.contains("/descriptors") else { return nil }
            return try dropJSONReply(200, ["descriptors": "not a list", "next": .null])
        }
        await #expect(throws: (any Error).self) { _ = try await a.service.send(Data("2".utf8), name: "d", document: v1) }
        #expect(try await a.service.failedUploads().isEmpty)
        #expect(try await a.service.confirmedUploads().count == 2)
    }

    @Test func aBadDescriptorPageBeforeTheReadBackLeavesTheRowPending() async throws {
        let a = try await DropAlignmentWorld.make()
        await a.sender.intercept { r in
            // a hostile read-back: the body is not the object the route promises
            guard r.method == "GET", r.target.hasSuffix("/versions/1/descriptor") else { return nil }
            return try dropJSONReply(200, ["descriptor": 5, "surprise": true])
        }
        await #expect(throws: DropError.retryLater(afterSeconds: 60)) { _ = try await a.service.send(Data("x".utf8), name: "x") }
        #expect(try await a.service.failedUploads().isEmpty)
    }

    @Test func manyTombstonesDoNotLockTheListOut() async throws {
        let a = try await DropAlignmentWorld.make()
        var built: [JSONValue] = []
        for i in 1...5000 {
            let state: JSONValue = i % 2 == 0 ? "retired" : "expired"
            built.append(.object(["n": .int(Int64(i)), "object_id": .string(String(format: "%032x", i)), "version": 1, "state": state,
                                  "tombstone_until_ms": .int(4_000_000_000_000), "descriptor": .null, "wraps": [], "claimed_by": .null]))
        }
        let entries = built
        await a.sender.intercept { r in
            guard r.target.hasSuffix("/drop/list") else { return nil }
            let after = (try StrictJSON.parse(r.body).object?["after"]?.int).map(Int.init) ?? 0
            let page = Array(entries[after..<min(after + 64, entries.count)])
            return try dropJSONReply(200, ["objects": .array(page), "next": after + 64 < entries.count ? .int(Int64(after + 64)) : .null])
        }
        let listed = try await a.service.listVerifiedRows(.sending)
        #expect(listed.gone.count == 5000 && listed.objects.isEmpty && listed.blocked.isEmpty)
    }

    @Test func staleStagedFramesAreSweptAtServiceStart() async throws {
        let a = try await DropAlignmentWorld.make()
        let dir = DropService.stageDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("orch-drop-\(UUID().uuidString)"), fresh = dir.appendingPathComponent("orch-drop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: old); try? FileManager.default.removeItem(at: fresh) }
        for u in [old, fresh] { try Data([1]).write(to: u) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: old.path)
        _ = try await a.service.resumeUploads()
        #expect(!FileManager.default.fileExists(atPath: old.path) && FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func aCorruptedStoredBlobIsNotRewrappedOrFailed() async throws {
        let a = try await DropAlignmentWorld.make()
        let id = ID16.fresh(0x96), db = try await a.phone.container.database()
        var frame = try await a.w.dropBody(id: id)
        frame[frame.count - 1] ^= 1
        try await db.execute("INSERT INTO drop_uploads(object,version,body,done) VALUES(?,1,?,0)", [.text(id.hex), .blob(frame)])
        try await a.w.host.rotate(remaining: [(a.w.phone, World.all)], relay: a.w.relay, session: a.w.hostSession)
        let results = try await a.service.resumeUploads()
        if case .failure(let e) = try #require(results.first).result { #expect(e as? DropError == .integrity) } else { Issue.record("rewrapped a corrupted blob") }
        #expect(try await db.query("SELECT body FROM drop_uploads WHERE object=?", [.text(id.hex)]).first?.blob("body") == frame)
    }

    @Test func quotaNamesAreClassifiedAgainstTheDocumentedList() throws {
        let stored = ["drop_ws", "drop_head_ws", "drop_account", "drop_versions", "drop_documents", "drop_device", "drop_device_head",
                      "drop_device_versions", "drop_device_documents", "drop_doc_versions"]
        for q in stored {
            let r = RelayRefusal(status: 429, code: .quotaExceeded, retryAfter: 600, quota: q)
            #expect(DropService.mapped(.relay(r)) as? DropError == .storageFull(quota: q, retryAfterSeconds: 600))
        }
        for q in ["slot", "drop_future_cap", nil] as [String?] {
            let r = RelayRefusal(status: 429, code: .quotaExceeded, retryAfter: 9, quota: q)
            #expect(DropService.mapped(.relay(r)) as? DropError == .retryLater(afterSeconds: 9))
        }
        let overloaded = RelayRefusal(status: 503, code: .overloaded, retryAfter: 4)
        #expect(DropService.mapped(.relay(overloaded)) as? DropError == .retryLater(afterSeconds: 4))
        let rotation = RelayRefusal(status: 409, code: .rotationRequired, epoch: 3)
        #expect(DropService.mapped(.relay(rotation)) as? DropError == .rotationPending)
    }

    @Test func aPageOfMoreThan64RowsIsRefused() async throws {
        let a = try await DropAlignmentWorld.make()
        var rows: [JSONValue] = []
        for i in 1...65 {
            rows.append(.object(["object_id": .string(String(format: "%032x", i)), "version": 1, "state": "retired", "descriptor": .null, "wraps": []]))
        }
        let page = rows
        await a.sender.intercept { r in
            guard r.target.hasSuffix("/drop/list") else { return nil }
            return try dropJSONReply(200, ["objects": .array(page), "next": .null])
        }
        await #expect(throws: DropError.tooLarge) { _ = try await a.service.listVerifiedRows(.sending) }
    }

    // MARK: a lying relay (its state is a hint)

    @Test func aRelayThatCallsALiveObjectRetiredOnlyHidesItAndPurgesNothing() async throws {
        let a = try await DropAlignmentWorld.make()
        let doc = try await a.service.send(Data("keep".utf8), name: "keep", kind: .document)
        let url = try await a.service.download(doc)
        let id = doc.descriptor.object.hex
        await a.sender.intercept { r in
            guard r.target.hasSuffix("/drop/list") else { return nil }
            let tomb: JSONValue = .object(["n": 9, "object_id": .string(id), "version": 1, "state": "retired", "tombstone_until_ms": .null,
                                           "descriptor": .null, "wraps": [], "claimed_by": "00000000000000000000000000000001"])
            return try dropJSONReply(200, ["objects": [tomb], "next": .null])
        }
        let listed = try await a.service.listVerifiedRows(.sending)
        #expect(listed.objects.isEmpty && listed.gone.first?.reason == .retired)
        #expect(FileManager.default.fileExists(atPath: url.path))                        // local plaintext untouched
        #expect(try await a.service.confirmedUploads().count == 1)                       // confirmation untouched
        await a.sender.intercept(nil)
        #expect(try await a.service.list(.sending).count == 1)                           // the truth comes back, the chain head was kept
    }

    @Test func aClaimedByHintDecidesNothing() async throws {
        let a = try await DropAlignmentWorld.make()
        _ = try await a.service.send(Data("c".utf8), name: "c")
        let query = try canonicalJSON(["workspace_id": .string(a.w.ws.hex), "direction": "sending"])
        var entries = try json(await a.w.transport.dropList(query, session: a.w.phoneSession))["objects"]!.array!.map { $0.object! }
        entries[0]["claimed_by"] = .string(a.w.ws.hex)
        let lied = entries
        await a.sender.intercept { r in
            guard r.target.hasSuffix("/drop/list") else { return nil }
            return try dropJSONReply(200, ["objects": .array(lied.map { .object($0) }), "next": .null])
        }
        let object = try #require(try await a.service.list(.sending).first)
        // only the verified descriptor and the wraps that open decide: a non-inbox object is not claimable whatever the hint says
        await #expect(throws: DropError.malformed) { try await a.service.claim(object) }
    }

    @Test func a200WithoutStoringConfirmsNothing() async throws {
        let a = try await DropAlignmentWorld.make()
        await a.sender.intercept { r in
            guard r.method == "PUT", r.target.hasSuffix("/versions") else { return nil }
            return try dropJSONReply(201, ["version": 1])
        }
        await #expect(throws: (any Error).self) { _ = try await a.service.send(Data("ghost".utf8), name: "ghost") }
        #expect(try await a.service.confirmedUploads().isEmpty)
        let rows = try await a.phone.container.database().query("SELECT done FROM drop_uploads")
        #expect(rows.count == 1 && rows[0].int("done") == 0)
    }

    @Test func a410OnAStoredPutIsConfirmedByTheReadBackAndOnAnEmptySlotIsNotTerminal() async throws {
        let a = try await DropAlignmentWorld.make()
        // the PUT commits but the answer says 410: the descriptor read-back is the judge
        let lie = DropFlag(true)
        await a.sender.intercept { [relay = a.w.relay] r in
            guard r.method == "PUT", r.target.hasSuffix("/versions"), lie.take() else { return nil }
            _ = try await relay.send(r)
            return try dropJSONReply(410, ["error": "expired"])
        }
        let stored = try await a.service.send(Data("real".utf8), name: "real")
        #expect(try await a.service.confirmedUploads().count == 1 && stored.descriptor.version == 1)
        // nothing stored and the signed expiry has not passed: the row stays pending, not failed
        await a.w.relay.scriptNextDropPut(try dropJSONReply(410, ["error": "expired"]))
        await #expect(throws: DropError.possiblyRemoved) { _ = try await a.service.send(Data("fake gone".utf8), name: "fg") }
        #expect(try await a.service.failedUploads().isEmpty)
    }

    // MARK: the FakeRelay follows the relay design (item 6)

    @Test func theFakeRelayHasNoUnprefixedDropRoutes() async throws {
        let w = try await World.drop(), id = ID16.fresh(0x93)
        for (method, target) in [("PUT", "/drop/\(id.hex)/versions"), ("POST", "/drop/list"), ("GET", "/drop/\(id.hex)/versions/1/descriptor"), ("POST", "/drop/\(id.hex)/claim")] {
            let r = try await w.relay.send(WireRequest(method: method, target: target, headers: ["authorization": "Bearer \(w.phoneSession.token)"], clientAddress: "test"))
            #expect(r.status == 404)
        }
    }

    @Test func readsAnswerInTheDocumentedOrderAndPutsFollowTheCASRules() async throws {
        let a = try await DropAlignmentWorld.make()
        let w = a.w, id = ID16.fresh(0x94)
        let absent = try await w.transport.dropGet(objectID: id, version: 1, part: .descriptor, session: w.phoneSession)
        #expect(absent.status == 404)
        let object = try await a.service.send(Data("e".utf8), name: "e", kind: .document)
        let missingVersion = try await w.transport.dropGet(objectID: object.descriptor.object, version: 7, part: .descriptor, session: w.phoneSession)
        #expect(missingVersion.status == 404)
        let etag = try await w.transport.dropGet(objectID: object.descriptor.object, version: 1, part: .descriptor, session: w.phoneSession)
        #expect(etag.status == 200 && etag.header("etag") == "\"1\"")
        // a retire answers 410 on every read and on a PUT of the id, never a fork
        #expect(try await a.retire(object).status == 200)
        let gone = try await w.transport.dropGet(objectID: object.descriptor.object, version: 1, part: .blob, session: w.phoneSession)
        #expect(gone.status == 410)
        let put = try await w.transport.dropPut(objectID: object.descriptor.object, ifMatch: 1, body: w.dropBody(id: object.descriptor.object, parent: object.descriptor), session: w.phoneSession)
        #expect(put.status == 410)
        // retiring again with the same precondition is idempotent inside the tombstone window; a moved head is version_conflict
        #expect(try await a.retire(object).status == 200)
    }

    @Test func listsAndWrapsAreFilteredToTheCaller() async throws {
        let a = try await DropAlignmentWorld.make()
        let object = try await a.service.send(Data("w".utf8), name: "w")
        let query = try canonicalJSON(["workspace_id": .string(a.w.ws.hex), "direction": "sending"])
        let device = try json(await a.w.transport.dropList(query, session: a.w.phoneSession))["objects"]!.array!
        let deviceWraps = try device[0].object!["wraps"]!.array!.map(DropWrapRecord.init(json:))
        #expect(!deviceWraps.contains { $0.targetKind == .wxk } && deviceWraps.contains { $0.targetKind == .wk } && deviceWraps.contains { $0.targetKind == .device })
        #expect(device[0].object!["object_id"] == .string(object.descriptor.object.hex) && device[0].object!["state"] == "live")
        let host = try await a.w.transport.dropGet(objectID: object.descriptor.object, version: 1, part: .wraps, session: a.w.hostSession)
        let hostWraps = try json(host)["wraps"]!.array!.map(DropWrapRecord.init(json:))
        #expect(hostWraps.contains { $0.targetKind == .wxk } && !hostWraps.contains { $0.targetKind == .device })
    }

    @Test func theQuotaBodyNamesTheCapAndCarriesRetryAfter() async throws {
        var limits = RelayLimits(); limits.dropDeviceVersions = 1
        let a = try await DropAlignmentWorld.make(limits: limits)
        _ = try await a.service.send(Data("1".utf8), name: "1")
        let body = try await a.w.dropBody(id: ID16.fresh(0x95))
        let r = try await a.w.transport.dropPut(objectID: ID16.fresh(0x95), ifMatch: 0, body: body, session: a.w.phoneSession)
        #expect(r.status == 429 && r.header("retry-after") == "600")
        #expect(try json(r) == ["error": "quota_exceeded", "quota": "drop_device_versions"])
    }
}
