import Foundation
import OrchCoordination
import OrchProtocol

// Hub pushes (design B4, orch-hub protocol 10.8.2): sealed to the channel's PUSH key, opened by the notification extension and by the app's
// mailbox catch-up through the same intake, so one replay store sees every id once. A hint is never an authority.

/// Where the notification extension gets the hub material (one `.push` item). The production one reads the keychain; tests inject.
public protocol HubPushMaterialSource: Sendable {
    /// The paired hub's push material, nil when this install has none. Throws `PushMaterialError.locked` before first unlock.
    func load() throws -> HubPushMaterial?
}

/// The extension's keychain reader for `hub.push.material`: read-only, explicit `.push` access group, no signing, no network.
public struct KeychainHubPushMaterialSource: HubPushMaterialSource {
    let accessGroup: String?
    public init?(accessGroupPrefix prefix: String) {
        guard KeychainPushMaterialSource.validPrefix(prefix) else { return nil }
        accessGroup = prefix + KeychainPushMaterialSource.groupSuffix
    }

    public static func fromBundle(_ bundle: Bundle = .main) -> KeychainHubPushMaterialSource? {
        (bundle.object(forInfoDictionaryKey: "OrchAppIdentifierPrefix") as? String).flatMap { KeychainHubPushMaterialSource(accessGroupPrefix: $0) }
    }

    #if DEBUG
    /// TEST-ONLY: no access group in the query.
    public init(unscopedForTests: Void) { accessGroup = nil }
    #endif

    public func load() throws -> HubPushMaterial? {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: HubPushMaterial.purpose,
                                  kSecAttrService: "orch:\(PushHandler.Realm.live):-", kSecAttrSynchronizable: false,
                                  kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        if let g = accessGroup { q[kSecAttrAccessGroup] = g }
        #if os(macOS)
        q[kSecUseDataProtectionKeychain] = true
        #endif
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        if status == errSecInteractionNotAllowed { throw PushMaterialError.locked }
        guard status == errSecSuccess else { throw PushMaterialError.unavailable(status) }
        guard let data = out as? Data else { throw PushMaterialError.invalid }
        return try? HubPushMaterial.decode(data)
    }
}

/// The relay's `outer` of a hub push: exactly `{v: 2, hub, ch, id, c}` (protocol 10.8.1 send).
public struct HubPushOuter: Equatable, Sendable {
    public let hubID: String, channelID: String, messageID: String, sealed: String

    /// nil unless the bytes are exactly that shape. `isHub` below tells a hub push from a direct one by its members.
    public static func parse(_ raw: Data) -> HubPushOuter? {
        guard raw.count <= PushProcessor.maxOuterBytes, let m = try? StrictJSON.parse(raw, maxBytes: PushProcessor.maxOuterBytes).object,
              Set(m.keys) == ["v", "hub", "ch", "id", "c"], m["v"] == .int(2), let hub = m["hub"]?.string, let ch = m["ch"]?.string,
              let id = m["id"]?.string, let c = m["c"]?.string, Hex.decode(hub, length: 16) != nil, Hex.decode(ch, length: 16) != nil,
              Hex.decode(id, length: 16) != nil, B64U.decode(c) != nil else { return nil }
        return HubPushOuter(hubID: hub, channelID: ch, messageID: id, sealed: c)
    }

    /// The outer names a hub (`hub` member): this is the hub path even when the rest is malformed (it then shows generic text).
    public static func isHub(_ raw: Data) -> Bool {
        guard raw.count <= PushProcessor.maxOuterBytes, let m = try? StrictJSON.parse(raw, maxBytes: PushProcessor.maxOuterBytes).object else { return false }
        return m["hub"] != nil
    }
}

/// Opens a hub hint and applies the replay rules, the one place for the push and the mailbox. State lives in the push App Group, per channel
/// (`<pushDir>/state/hub/<channel_id>/replay.0.json`), under the same flock and crash-safe write as the direct-mode replay.
public struct HubPushIntake: Sendable {
    public static let realm = "hub"
    let store: ReplayStore

    public init(pushDir: URL) { store = ReplayStore(pushDir: pushDir, realm: Self.realm) }

    public enum Verdict: Equatable, Sendable {
        /// Opened, fresh and unseen: recorded durably BEFORE this returns (so before anything is shown).
        case hint(HubPushHint)
        case dropped(PushProcessor.DropReason)
    }

    /// Protocol 10.8.2: the phone opens a hint only when `hub` and `ch` are its own pairing's, the seal opens, `ts_ms` is within
    /// [now - 24 h, now + 300 s] and the `id` was not handled before.
    public func accept(material: HubPushMaterial, hubID: String, channelID: String, messageID: String, sealed: String, nowMs: Int64) -> Verdict {
        guard hubID == material.hubID, channelID == material.channelID, let channel = ID16(hex: channelID) else { return .dropped(.noKey) }
        let hint: HubPushHint
        do { hint = try material.opener.openPush(sealed: sealed, hubID: hubID, channelID: channelID, messageID: messageID) }
        catch { return .dropped(.tag) }
        do {
            return try store.transact(workspace: channel, generation: 0, nowMs: nowMs) { current -> (Verdict, PushProcessor.WorkspaceReplay?) in
                let state = current.pruned()
                if hint.tsMs <= state.notBeforeTs { return (.dropped(.replay), state) }
                if let why = PushProcessor.checkTimestamp(tsMs: hint.tsMs, nowMs: nowMs, floorNowMs: state.maxShownTs, lastShown: state.last(id: messageID)) {
                    return (.dropped(why), state)
                }
                let advanced = state.recording(messageID, hint.tsMs)
                if state.last(id: messageID) == nil, advanced.lastShown.count > PushProcessor.maxEntriesPerWorkspace { return (.dropped(.capacity), state) }
                return (.hint(hint), advanced)
            }
        } catch { return .dropped(.capacity) }
    }

    /// Where one channel's replay state lives.
    public func stateDirectory(channelID: ID16) -> URL { store.stateDir(workspace: channelID) }

    /// Forgets the replay state of one channel (the wipe of B6).
    public func purge(channelID: String) {
        guard let ch = ID16(hex: channelID) else { return }
        try? FileManager.default.removeItem(at: store.stateDir(workspace: ch))
    }
}

extension PushPresentation {
    /// A hub hint on the lock screen: the title is the label the person chose at pairing (app-authored), the body one of two fixed lines. Nothing from
    /// the hub, the relay or the payload is shown, not even `ref` (and nothing that would be signed is on this screen).
    public static func hubHint(_ kind: HubPushHint.Kind, label: String) -> PushPresentation {
        let name = NotificationText.safe(label, limit: 80)
        let body = kind == .prepare ? "A signature request is waiting" : "Something needs you"
        return PushPresentation(style: .event, title: name.isEmpty ? genericTitle : name, body: body, threadID: nil, entityKey: nil,
                                removesDelivered: nil, sound: true, simulated: false)
    }
}
