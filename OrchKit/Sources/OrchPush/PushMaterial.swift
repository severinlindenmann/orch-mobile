import CryptoKit
import Foundation
import OrchProtocol

/// What the app publishes to the `.push` keychain group for one workspace (decision A9) and what the notification
/// extension reads: the pinned `wsk_pub`, `K_push(ws, epoch)` for each epoch held, the workspace display name and the
/// workspace generation (A11: the extension needs it for `ifNotRemoved`). Never `WK_e`: a push receiver does not need it.
///
/// Stored as ONE keychain item per (realm, ws), purpose `push.material`, so an update is atomic.
public struct PushMaterial: Equatable, Sendable {
    public static let purpose = "push.material"
    public static let maxBytes = 16 * 1024
    public static let maxNameScalars = 200
    public static let maxEpochs = 8

    public let generation: Int64
    public let name: String
    public let wsk: SigningPublicKey
    /// 32 raw bytes per epoch.
    public let kPush: [UInt32: Data]

    public init(generation: Int64, name: String, wsk: SigningPublicKey, kPush: [UInt32: Data]) throws {
        guard generation >= 0, kPush.count <= Self.maxEpochs, kPush.values.allSatisfy({ $0.count == 32 }),
              name.unicodeScalars.count <= Self.maxNameScalars else { throw PushMaterialError.invalid }
        self.generation = generation; self.name = name; self.wsk = wsk; self.kPush = kPush
    }

    /// The processor's view. `wsk` is the pinned key; nothing else about the workspace is trusted from here.
    public var keys: PushProcessor.WorkspaceKeys {
        .init(wsk: wsk, kPush: kPush.mapValues { SymmetricKey(data: $0) })
    }

    public func encoded() throws -> Data {
        let k = Dictionary(uniqueKeysWithValues: kPush.map { (String($0.key), JSONValue.string(B64U.encode($0.value))) })
        let data = try canonicalJSON(["v": 1, "gen": .int(generation), "name": .string(name),
                                      "wsk": .string(B64U.encode(wsk.x963)), "k": .object(k)])
        guard data.count <= Self.maxBytes else { throw PushMaterialError.invalid }
        return data
    }

    /// Strict: exactly these fields, every key 32 bytes, nothing extra.
    public static func decode(_ data: Data) throws -> PushMaterial {
        guard data.count <= maxBytes, let o = try? StrictJSON.parse(data, maxBytes: maxBytes).object,
              Set(o.keys) == ["v", "gen", "name", "wsk", "k"], o["v"] == .int(1),
              let gen = o["gen"]?.int, let name = o["name"]?.string,
              let wskBytes = o["wsk"]?.string.flatMap({ B64U.decode($0) }), let wsk = try? SigningPublicKey(x963: wskBytes),
              let kObj = o["k"]?.object else { throw PushMaterialError.invalid }
        var k: [UInt32: Data] = [:]
        for (e, v) in kObj {
            guard let epoch = UInt32(e), String(epoch) == e, let raw = v.string.flatMap({ B64U.decode($0) }) else { throw PushMaterialError.invalid }
            k[epoch] = raw
        }
        return try PushMaterial(generation: gen, name: name, wsk: wsk, kPush: k)
    }
}

public enum PushMaterialError: Error, Equatable, Sendable {
    case invalid
    /// Device locked before first unlock: temporary, not "no material".
    case locked
    case unavailable(Int32)
}

/// Where the notification extension gets its material. The production one reads the keychain; tests inject.
public protocol PushMaterialSource: Sendable {
    /// Every workspace of `realm` that has push material. Items that fail to parse are skipped (fail closed per item).
    func loadAll(realm: String) throws -> [ID16: PushMaterial]
}

/// Where the app writes. `SecretVault(group: .push)` is adapted in the app target; this module cannot see custody.
public protocol PushMaterialSink: Sendable {
    func put(_ data: Data, realm: String, ws: String, purpose: String) throws
    func delete(realm: String, ws: String, purpose: String) throws
}

/// The app's single writer of push material (called by pairing/session when a workspace is joined or an epoch changes,
/// BEFORE push registration; host-api v0 section 3).
public struct PushMaterialPublisher: Sendable {
    let sink: any PushMaterialSink
    public let realm: String
    public init(sink: any PushMaterialSink, realm: String) { self.sink = sink; self.realm = realm }

    /// Derives `K_push` for each `WK_e` here, so `WK_e` itself never reaches the push group.
    public func publish(workspace: ID16, generation: Int64, name: String, wsk: SigningPublicKey, wk: [UInt32: SymmetricKey]) throws {
        let k = wk.reduce(into: [UInt32: Data]()) { out, e in
            out[e.key] = KDF.kPush(wk: e.value, workspace: workspace, epoch: e.key).withUnsafeBytes { Data($0) }
        }
        try publish(workspace: workspace, material: PushMaterial(generation: generation, name: name, wsk: wsk, kPush: k))
    }

    public func publish(workspace: ID16, material: PushMaterial) throws {
        try sink.put(try material.encoded(), realm: realm, ws: workspace.hex, purpose: PushMaterial.purpose)
    }

    public func remove(workspace: ID16) throws {
        try sink.delete(realm: realm, ws: workspace.hex, purpose: PushMaterial.purpose)
    }
}
