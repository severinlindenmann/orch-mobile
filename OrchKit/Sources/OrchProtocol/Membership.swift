import CryptoKit
import Foundation

/// A member list that passed `MemberList.verify` (signature and shape).
public struct MemberList: Equatable, Sendable {
    public struct Member: Equatable, Sendable {
        public let deviceID: ID16
        /// Raw scopes as signed; validated against the certificate in `check`.
        public let scopes: JSONValue
        public var scopeStrings: [String]? { scopes.array.flatMap { a in let s = a.compactMap(\.string); return s.count == a.count ? s : nil } }
    }
    public let workspace: ID16
    public let epoch: UInt32
    public let listSeq: Int64
    public let issuedMs: Int64
    public let members: [Member]

    /// What the relay (and a verifying phone) knows about the owner's devices.
    public struct Directory: Sendable {
        public struct GrantKey: Hashable, Sendable {
            public let device: ID16, epoch: UInt32
            public init(device: ID16, epoch: UInt32) { self.device = device; self.epoch = epoch }
        }
        public var ownerKey: SigningPublicKey
        public var certs: [ID16: JSONValue]
        public var revoked: Set<ID16>
        public var grants: Set<GrantKey>
        public init(ownerKey: SigningPublicKey, certs: [ID16: JSONValue], revoked: Set<ID16>, grants: Set<GrantKey>) {
            self.ownerKey = ownerKey; self.certs = certs; self.revoked = revoked; self.grants = grants
        }
    }

    public static let maxMembers = 1024
    static let fields: Set<String> = ["v", "suite", "kind", "workspace_id", "epoch", "list_seq", "issued_ms", "members"]

    /// Steps 1 and 2 of section 7.2: the signature with the card's `wsk_pub`, then the shape (field set, sorted unique hex
    /// ids, `epoch >= 1`). `bad_signature` or `malformed`.
    public static func verify(_ signed: JSONValue, wsk: SigningPublicKey) throws -> MemberList {
        let o: [String: JSONValue]
        do { o = try SignedObject.parse(signed).verify(kind: .memberList, key: wsk) }
        catch let r as Refusal where r == .badSignature { throw r }
        catch { throw Refusal.badSignature }
        return try parse(object: o)
    }

    /// Shape only (no signature): see `verify`.
    static func parse(object o: [String: JSONValue]) throws -> MemberList {
        guard o.hasExactly(fields), let ws = o.id16("workspace_id"), let epoch = o.positiveU32("epoch"),
              let seq = o["list_seq"]?.int, let issued = o["issued_ms"]?.int,
              let raw = o["members"]?.array, raw.count <= maxMembers else { throw Refusal.malformed }
        var members: [Member] = []
        for m in raw {
            guard let mo = m.object, mo.hasExactly(["device_id", "scopes"]), let id = mo.id16("device_id"),
                  let scopes = mo["scopes"] else { throw Refusal.malformed }
            members.append(Member(deviceID: id, scopes: scopes))
        }
        // sorted by device_id, no duplicates (lower-case hex sorts like the bytes)
        for (a, b) in zip(members, members.dropFirst()) where !a.deviceID.hex.utf8.lexicographicallyPrecedes(b.deviceID.hex.utf8) {
            throw Refusal.malformed
        }
        return MemberList(workspace: ws, epoch: epoch, listSeq: seq, issuedMs: issued, members: members)
    }

    /// What a device does with a list it fetched, given the last list it accepted (`known`, nil on first contact or late join,
    /// when the first list it sees may carry any epoch and `list_seq >= 1`). Identical list again (reconnect) and forward jumps
    /// (missed lists and rotations) pass; rollback, conflicting content under one `list_seq`, an epoch that falls, and a removal
    /// without an epoch bump are refused. Certificates and grants of other members are the relay's to check: a phone does not
    /// hold them (gap 27). The coordinator separately requires its own device and approved scopes.
    public func checkSnapshot(cardWorkspace: ID16, known: MemberList?) throws {
        guard workspace == cardWorkspace else { throw Refusal.otherWorkspace }
        guard let k = known else {
            guard listSeq >= 1 else { throw Refusal.badEpoch }
            return
        }
        if listSeq < k.listSeq { throw Refusal.staleList }
        if listSeq == k.listSeq {
            guard self == k else { throw Refusal.conflictingSnapshot }
            return
        }
        guard epoch >= k.epoch else { throw Refusal.badEpoch }
        let now = Set(members.map(\.deviceID))
        if epoch == k.epoch, k.members.contains(where: { !now.contains($0.deviceID) }) { throw Refusal.rotationRequired }
    }

    /// The rest of section 7.2 (checks 3 to 9), as the relay applies them before it publishes a list.
    /// `cardWorkspace` is the workspace of the card whose `wsk_pub` verified the list. `previous` is the last accepted list.
    /// `abandonedThrough` is the relay's trusted rotation retirement watermark, never a value supplied by a list.
    /// Failed attempts consume epochs without becoming active lists; only the epoch after that watermark may follow.
    public func checkRelayUpdate(cardWorkspace: ID16, previous: MemberList?, directory: Directory, nowMs: Int64, abandonedThrough: UInt32 = 0) throws {
        guard workspace == cardWorkspace else { throw Refusal.otherWorkspace }
        if let p = previous {
            guard listSeq > p.listSeq else { throw Refusal.staleList }
            let previousEpoch = max(p.epoch, abandonedThrough)
            guard (epoch == p.epoch && epoch > abandonedThrough) || (previousEpoch != UInt32.max && epoch == previousEpoch + 1) else { throw Refusal.badEpoch }
            let now = Set(members.map(\.deviceID))
            if p.members.contains(where: { !now.contains($0.deviceID) }), epoch != previousEpoch &+ 1 { throw Refusal.rotationRequired }
        } else if epoch != 1 || listSeq != 1 {
            throw Refusal.badEpoch
        }
        let ownerHex = Identifiers.personID(directory.ownerKey).hex
        for m in members {
            if directory.revoked.contains(m.deviceID) { throw Refusal.revoked }
            guard let certJSON = directory.certs[m.deviceID] else { throw Refusal.certInvalid }
            let cert: DeviceCertificate
            do { cert = try DeviceCertificate.verify(certJSON, personKey: directory.ownerKey, nowMs: nowMs, revoked: directory.revoked) }
            catch let r as Refusal where r == .certInvalid {
                let person = certJSON.object?["o"]?.object?["person_id"]?.string
                throw (person.map { !$0.bytesEqual(ownerHex) } ?? false) ? Refusal.otherPerson : r
            }
            guard cert.deviceID == m.deviceID else { throw Refusal.certInvalid }
            guard !cert.isScopedAgent, let scopes = m.scopeStrings, Scopes.isValid(scopes), scopes.count <= cert.scopesMax.count else {
                throw Refusal.scopeExceeded
            }
            guard directory.grants.contains(.init(device: m.deviceID, epoch: epoch)) else { throw Refusal.missingGrant }
        }
    }
}

/// A WK grant (section 7.3): `WK_e` sealed to one device, signed by `WSK`.
public struct VerifiedWKGrant: Sendable {
    public let epoch: UInt32
    public let wk: SymmetricKey
}

public enum WKGrant {
    static let fields: Set<String> = ["v", "suite", "kind", "workspace_id", "device_id", "epoch", "sealed"]
    public static let maxSealedBytes = 1024

    /// A device MUST verify the grant with the pinned `WSK` before it uses the key: `bad_signature`, then
    /// `not_for_this_device`, then the sealed key (`authenticationFailed` on a wrong key or tampering, `malformed` if it is
    /// not 32 bytes).
    package static func open(_ signed: JSONValue, wsk: SigningPublicKey, workspace: ID16, device: ID16, deviceKey: some KeyAgreer) throws -> VerifiedWKGrant {
        let o: [String: JSONValue]
        do { o = try SignedObject.parse(signed).verify(kind: .wkGrant, key: wsk) }
        catch let r as Refusal where r == .badSignature { throw r }
        catch { throw Refusal.badSignature }
        guard o.hasExactly(fields), let ws = o.id16("workspace_id"), let dev = o.id16("device_id"), let epoch = o.positiveU32("epoch"),
              let sealed = o.b64u("sealed"), sealed.count <= maxSealedBytes else { throw Refusal.malformed }
        guard ws == workspace, dev == device else { throw Refusal.notForThisDevice }
        let wk = try Sealing.open(with: deviceKey, recipientID: device, purpose: .wk, object: workspace, epoch: epoch, sealed: sealed)
        guard wk.count == 32 else { throw Refusal.malformed }
        return VerifiedWKGrant(epoch: epoch, wk: SymmetricKey(data: wk))
    }

    /// Host side: seal `WK_e` to the device's `dk_kx` and sign with `WSK`.
    package static func make(wsk: some Signer, workspace: ID16, device: ID16, deviceKey: AgreementPublicKey, epoch: UInt32,
                             wk: SymmetricKey) throws -> SignedObject {
        let sealed = try Sealing.seal(to: deviceKey, recipientID: device, purpose: .wk, object: workspace, epoch: epoch, plaintext: wk.rawBytes)
        return try SignedObject.sign(["v": 2, "suite": 2, "kind": "wk_grant", "workspace_id": .string(workspace.hex),
                                      "device_id": .string(device.hex), "epoch": .int(Int64(epoch)), "sealed": .string(B64U.encode(sealed))],
                                     kind: .wkGrant, signer: wsk)
    }
}
