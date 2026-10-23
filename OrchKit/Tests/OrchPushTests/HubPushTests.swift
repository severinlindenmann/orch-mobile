import CryptoKit
import Foundation
import OrchCustody
import OrchProtocol
import OrchTestVectors
import Testing
@testable import OrchPush

/// B4: the notification extension and the mailbox intake open hub pushes with the PUSH key only (agreement-only), against orch-hub's `push_seal`
/// vector, show fixed text under the person's own hub label, and fail to the generic text.
private enum HV {
    static let root: JSONValue = { try! StrictJSON.parse(OrchTestVectors.Vectors.hub, maxBytes: .max, maxDepth: 64) }()
    static var seal: JSONValue { root["phase4"]["relay_routes"]["push_seal"] }
    static var hub: String { root["ids"]["hub"].string! }
    static var channel: String { seal["channel_id"].string! }
    static var messageID: String { seal["msg_id"].string! }
    static var sealed: String { seal["sealed"].string! }
    static var tsMs: Int64 { seal["payload"]["ts_ms"].int! }
    static var ref: String { seal["payload"]["ref"].string! }
    static func opener() -> HubPushOpener {
        var s = Array(Hex.decode(root["keys"]["push_alice_phone"]["seed"].string!)!)
        for i in stride(from: 31, through: 0, by: -1) { if s[i] == 255 { s[i] = 0 } else { s[i] += 1; break } }
        return try! HubPushOpener(raw: Data(s))
    }
    static func material(label: String = "Work hub") -> HubPushMaterial {
        try! HubPushMaterial(hubID: hub, channelID: channel, label: label, opener: opener())
    }
    static func outer(hub: String? = nil, ch: String? = nil, id: String? = nil, c: String? = nil) -> String {
        String(decoding: try! canonicalJSON(["v": 2, "hub": .string(hub ?? Self.hub), "ch": .string(ch ?? channel), "id": .string(id ?? messageID),
                                             "c": .string(c ?? sealed)]), as: UTF8.self)
    }
}

private struct StubHubSource: HubPushMaterialSource {
    var material: HubPushMaterial?
    var fails = false
    func load() throws -> HubPushMaterial? { if fails { throw PushMaterialError.locked }; return material }
}

private struct NoWorkspaces: PushMaterialSource { func loadAll(realm: String) throws -> [ID16: PushMaterial] { [:] } }

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("orch-b4-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func handler(_ dir: URL, source: StubHubSource?, now: Int64 = HV.tsMs + 1000) -> PushHandler {
    PushHandler(material: NoWorkspaces(), hubMaterial: source, pushDir: dir, now: { Date(timeIntervalSince1970: Double(now) / 1000) })
}

@Suite struct HubPushNSETests {
    @Test func outerShapeIsExact() {
        let good = Data(HV.outer().utf8)
        #expect(HubPushOuter.parse(good)?.messageID == HV.messageID)
        #expect(HubPushOuter.isHub(good))
        #expect(HubPushOuter.parse(Data(#"{"v":2,"hub":"\#(HV.hub)","ch":"\#(HV.channel)","id":"\#(HV.messageID)","c":"AAAA","x":1}"#.utf8)) == nil)
        #expect(HubPushOuter.parse(Data(HV.outer(hub: "zz").utf8)) == nil)
        #expect(HubPushOuter.parse(Data(#"{"v":1,"hub":"\#(HV.hub)","ch":"\#(HV.channel)","id":"\#(HV.messageID)","c":"AAAA"}"#.utf8)) == nil)
        // a direct-mode outer is not a hub push
        #expect(!HubPushOuter.isHub(Data(#"{"v":2,"ws":"00","epoch":1,"c":"AA"}"#.utf8)))
    }

    @Test func opensTheVectorWithTheHubLabelAndFixedText() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = handler(dir, source: StubHubSource(material: HV.material(label: "Work hub"))).handle(o: HV.outer())
        #expect(r.outcome == .shown)
        #expect(r.presentation.title == "Work hub")
        #expect(r.presentation.body == "A signature request is waiting")   // the vector's type is `prepare`
        // nothing of the payload (ref, ids) reaches the screen or the routing keys
        for text in [r.presentation.title, r.presentation.body] { #expect(!text.contains(HV.ref) && !text.contains(HV.channel)) }
        #expect(r.presentation.userInfo.isEmpty && r.presentation.entityKey == nil && r.presentation.threadID == nil)
    }

    @Test func needsYouHasItsOwnFixedLine() {
        #expect(PushPresentation.hubHint(.needsYou, label: "Work hub").body == "Something needs you")
        #expect(PushPresentation.hubHint(.prepare, label: "").title == PushPresentation.genericTitle)
        // the label is app-authored but still stripped of control and bidi characters
        #expect(PushPresentation.hubHint(.prepare, label: "A\u{202E}B\nC").title == "AB C")
    }

    @Test func aSecondDeliveryOfTheSameIdIsAReplay() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = handler(dir, source: StubHubSource(material: HV.material()))
        #expect(h.handle(o: HV.outer()).outcome == .shown)
        let again = h.handle(o: HV.outer())
        #expect(again.outcome == .droppedReplay && again.presentation == .generic)
    }

    @Test func theMailboxAndThePushShareOneReplayStore() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let intake = HubPushIntake(pushDir: dir)
        let m = HV.material()
        let first = intake.accept(material: m, hubID: HV.hub, channelID: HV.channel, messageID: HV.messageID, sealed: HV.sealed, nowMs: HV.tsMs + 5)
        guard case .hint(let hint) = first else { Issue.record("not opened: \(first)"); return }
        #expect(hint.type == .prepare && hint.ref == HV.ref)
        // the extension then finds the id already handled
        #expect(handler(dir, source: StubHubSource(material: m)).handle(o: HV.outer()).outcome == .droppedReplay)
        #expect(intake.accept(material: m, hubID: HV.hub, channelID: HV.channel, messageID: HV.messageID, sealed: HV.sealed, nowMs: HV.tsMs + 5) == .dropped(.replay))
    }

    @Test func staleAndFutureHintsAreDropped() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = HV.material(), intake = HubPushIntake(pushDir: dir)
        let day: Int64 = 24 * 3600 * 1000
        #expect(intake.accept(material: m, hubID: HV.hub, channelID: HV.channel, messageID: HV.messageID, sealed: HV.sealed, nowMs: HV.tsMs + day + 1) == .dropped(.stale))
        #expect(intake.accept(material: m, hubID: HV.hub, channelID: HV.channel, messageID: HV.messageID, sealed: HV.sealed, nowMs: HV.tsMs - 300_001) == .dropped(.stale))
        // the edges are inclusive
        #expect(intake.accept(material: m, hubID: HV.hub, channelID: HV.channel, messageID: HV.messageID, sealed: HV.sealed, nowMs: HV.tsMs + day) != .dropped(.stale))
    }

    @Test func onlyItsOwnHubAndChannelOpen() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = StubHubSource(material: HV.material()), h = handler(dir, source: src)
        let rogueHub = HV.root["ids"]["hub_rogue"].string!, bob = HV.root["ids"]["channel_bob_browser"].string!
        for o in [HV.outer(hub: rogueHub), HV.outer(ch: bob)] {
            let r = h.handle(o: o)
            #expect(r.presentation == .generic && r.outcome == .droppedNoMaterial)
        }
        // a tampered seal, another id, a seal of the wrong shape
        #expect(h.handle(o: HV.outer(id: String(repeating: "0", count: 32))).presentation == .generic)
        #expect(h.handle(o: HV.outer(c: "AAAA")).presentation == .generic)
        #expect(h.handle(o: #"{"v":2,"hub":"\#(HV.hub)"}"#).outcome == .droppedVerification)
    }

    @Test func anotherPushKeyCannotOpenIt() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let other = try HubPushMaterial(hubID: HV.hub, channelID: HV.channel, label: "x", opener: HubPushOpener(raw: Data(P256.KeyAgreement.PrivateKey().rawRepresentation)))
        let r = handler(dir, source: StubHubSource(material: other)).handle(o: HV.outer())
        #expect(r.presentation == .generic && r.outcome == .droppedVerification)
    }

    @Test func noMaterialOrALockedKeychainIsGenericText() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(handler(dir, source: nil).handle(o: HV.outer()).outcome == .droppedNoMaterial)
        #expect(handler(dir, source: StubHubSource(material: nil)).handle(o: HV.outer()).outcome == .droppedNoMaterial)
        #expect(handler(dir, source: StubHubSource(material: HV.material(), fails: true)).handle(o: HV.outer()).presentation == .generic)
    }

    @Test func theMaterialItemHoldsThePushKeyOnlyAndIsStrict() throws {
        let m = HV.material()
        let data = try m.encoded()
        let back = try HubPushMaterial.decode(data)
        #expect(back.hubID == m.hubID && back.channelID == m.channelID && back.label == m.label && back.opener.publicKey == m.opener.publicKey)
        // extra members (a channel key, a token) are refused: the item is exactly these five
        var o = try StrictJSON.parse(data, maxBytes: 1024).object!
        for extra in ["channel_key", "session", "token"] {
            o[extra] = "x"
            #expect(throws: (any Error).self) { try HubPushMaterial.decode(try canonicalJSON(.object(o))) }
            o[extra] = nil
        }
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("session") && !text.contains("channel-key"))
    }

    @Test func theOpenerIsAgreementOnly() {
        // `HubPushOpener` wraps a CryptoKit KeyAgreement key: it has no signing call at all, and its only operation is `openPush`.
        let mirror = Mirror(reflecting: HV.opener())
        #expect(mirror.children.allSatisfy { $0.value is P256.KeyAgreement.PrivateKey || $0.value is AgreementPublicKey })
    }
}
