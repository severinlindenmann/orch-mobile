import CryptoKit
import Foundation
import OrchProtocol
import OrchPush
import Security

/// Where the phone's hub secrets live (design B1, D-B1 to D-B3). Hub data lives in the Live realm under its own namespace: every item name
/// starts with `hub.<hub_id>.`, so it is keyed by `hub_id` (a second hub is additive later) and never shares a name with a direct pairing.
///
/// - `.keys` group (app only): the channel key (`channel-key`: a Secure Enclave key blob on a device, a software key in the Simulator and
///   on macOS), the channel session token (`session`) and the pairing record (`record`).
/// - `.push` group (app and notification extension): the agreement-only push key (`push-key`).
///
/// Nothing here can read a private key back.
public struct HubKeyCustody: Sendable {
    let keys: SecretVault
    let push: SecretVault
    let realm: Realm

    public init(keys: SecretVault, push: SecretVault, realm: Realm = .live) {
        precondition(keys.group == .keys && push.group == .push, "hub keys belong in .keys, the push key in .push")
        self.keys = keys; self.push = push; self.realm = realm
    }

    enum Purpose: String { case channelKey = "channel-key", session, record, pushKey = "push-key", pushState = "push-state" }

    func id(_ hubID: String, _ p: Purpose) throws -> SecretID {
        guard Hex.decode(hubID, length: 16) != nil else { throw VaultError.badName }
        return try SecretID(realm: realm, purpose: "hub.\(hubID).\(p.rawValue)")
    }

    private func map<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch VaultError.locked { throw CustodyError.locked }
        catch VaultError.duplicate { throw CustodyError.alreadyExists }
        catch let e as VaultError { throw CustodyError.vault(e) }
    }

    private func read(_ v: SecretVault, _ hubID: String, _ p: Purpose) throws -> Data? {
        do { return try map { try v.get(try id(hubID, p)) } } catch CustodyError.vault(.notFound) { return nil }
    }

    // MARK: channel key

    public func createChannelKey(hubID: String) throws -> HubChannelSigner {
        let blob: Data, signer: any Signer, kind: CustodyKind
        #if targetEnvironment(simulator) || os(macOS)
        let k = P256.Signing.PrivateKey()
        blob = k.rawRepresentation; signer = try HubSoftwareSigner(raw: blob); kind = .software
        #else
        guard SecureEnclave.isAvailable else { throw CustodyError.unavailable }
        let k: SecureEnclave.P256.Signing.PrivateKey
        do { k = try SecureEnclave.P256.Signing.PrivateKey(accessControl: SecureEnclaveCustody.accessControl()) }
        catch { throw CustodyError.unavailable }
        blob = k.dataRepresentation; signer = try SecureEnclaveSigner(blob: blob); kind = .secureEnclave
        #endif
        try map { try keys.putNew(blob, for: try id(hubID, .channelKey)) }
        return HubChannelSigner(signer: signer, custody: kind)
    }

    public func loadChannelKey(hubID: String) throws -> HubChannelSigner {
        guard let blob = try read(keys, hubID, .channelKey) else { throw CustodyError.missing }
        #if targetEnvironment(simulator) || os(macOS)
        guard let s = try? HubSoftwareSigner(raw: blob) else { throw CustodyError.orphaned }
        return HubChannelSigner(signer: s, custody: .software)
        #else
        guard let s = try? SecureEnclaveSigner(blob: blob) else { throw CustodyError.unavailable }
        return HubChannelSigner(signer: s, custody: .secureEnclave)
        #endif
    }

    public func deleteChannelKey(hubID: String) throws { try map { try keys.delete(try id(hubID, .channelKey)) } }

    // MARK: push key

    public func createPushKey(hubID: String) throws -> HubPushOpener {
        let k = P256.KeyAgreement.PrivateKey()
        try map { try push.putNew(k.rawRepresentation, for: try id(hubID, .pushKey)) }
        return try HubPushOpener(raw: k.rawRepresentation)
    }

    public func loadPushKey(hubID: String) throws -> HubPushOpener {
        guard let raw = try read(push, hubID, .pushKey) else { throw CustodyError.missing }
        guard let o = try? HubPushOpener(raw: raw) else { throw CustodyError.orphaned }
        return o
    }

    public func deletePushKey(hubID: String) throws { try map { try push.delete(try id(hubID, .pushKey)) } }

    // MARK: push material (what the notification extension reads: ONE item, `.push` group)

    /// Writes `hub.push.material` for the paired channel: the hub and channel ids, the label and the push key (read back from the `.push`
    /// group here, so the key is never handed around). One atomic `put`; the extension sees the old item or the new one, never half.
    public func publishPushMaterial(hubID: String, channelID: String, label: String) throws {
        let material = try HubPushMaterial(hubID: hubID, channelID: channelID, label: label, opener: try loadPushKey(hubID: hubID))
        let item = try SecretID(realm: realm, purpose: HubPushMaterial.purpose)
        try map { try push.put(try material.encoded(), for: item) }
    }

    public func pushMaterial() throws -> HubPushMaterial? {
        let item = try SecretID(realm: realm, purpose: HubPushMaterial.purpose)
        guard let data = try read(push, item) else { return nil }
        guard let m = try? HubPushMaterial.decode(data) else { throw CustodyError.orphaned }
        return m
    }

    public func deletePushMaterial() throws { try map { try push.delete(try SecretID(realm: realm, purpose: HubPushMaterial.purpose)) } }

    private func read(_ v: SecretVault, _ item: SecretID) throws -> Data? {
        do { return try map { try v.get(item) } } catch CustodyError.vault(.notFound) { return nil }
    }

    // MARK: push registration state (`.keys`, app only)

    public func pushState(hubID: String) throws -> HubPushState? {
        guard let d = try read(keys, hubID, .pushState) else { return nil }
        guard let s = try? HubPushState.decode(d) else { throw CustodyError.orphaned }
        return s
    }

    public func putPushState(_ state: HubPushState, hubID: String) throws { try map { try keys.put(try state.encoded(), for: try id(hubID, .pushState)) } }

    // MARK: channel session token (only ever in .keys, never in .push, a file or UserDefaults)

    public func putSessionToken(_ token: String, hubID: String) throws { try map { try keys.put(Data(token.utf8), for: try id(hubID, .session)) } }
    public func sessionToken(hubID: String) throws -> String? {
        try read(keys, hubID, .session).map { String(decoding: $0, as: UTF8.self) }
    }
    public func deleteSessionToken(hubID: String) throws { try map { try keys.delete(try id(hubID, .session)) } }

    // MARK: the pairing record (what the phone verified: card, origin, user, channel, certificate)

    public func putRecord(_ data: Data, hubID: String) throws { try map { try keys.put(data, for: try id(hubID, .record)) } }
    public func record(hubID: String) throws -> Data? { try read(keys, hubID, .record) }
    public func deleteRecord(hubID: String) throws { try map { try keys.delete(try id(hubID, .record)) } }

    /// The hubs this install holds a record for (D-B1: one in V3).
    public func pairedHubs() throws -> [String] {
        try map { try keys.ids() }.filter { $0.realm == realm && $0.ws == nil && $0.purpose.hasPrefix("hub.") && $0.purpose.hasSuffix(".record") }
            .map { String($0.purpose.dropFirst(4).dropLast(7)) }
    }

    /// Removes everything of one hub in this custody (used on a failed pairing and by the wipe of B6). Each delete is tried; the first
    /// error is rethrown after all were attempted.
    public func deleteAll(hubID: String) throws {
        var first: Error?
        for step: () throws -> Void in [{ try deletePushMaterial() }, { try deleteSessionToken(hubID: hubID) }, { try deleteRecord(hubID: hubID) },
                                         { try deletePushKey(hubID: hubID) }, { try deleteChannelKey(hubID: hubID) },
                                         { try map { try keys.delete(try id(hubID, .pushState)) } }] {
            do { try step() } catch { first = first ?? error }
        }
        if let first { throw first }
    }
}

#if targetEnvironment(simulator) || os(macOS)
struct HubSoftwareSigner: Signer {
    let key: P256.Signing.PrivateKey
    let publicKey: SigningPublicKey
    init(raw: Data) throws {
        key = try P256.Signing.PrivateKey(rawRepresentation: raw)
        publicKey = try SigningPublicKey(x963: key.publicKey.x963Representation)
    }
    func rawSignature(over message: Data) throws -> Data { try key.signature(for: message).rawRepresentation }
}
#endif
