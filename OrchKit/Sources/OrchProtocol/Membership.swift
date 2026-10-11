import CryptoKit
import Foundation

/// A member list that passed `MemberList.verify` (signature and shape).
public struct MemberList: Equatable, Sendable {
    public struct Member: Equatable, Sendable {
        public let deviceID: ID16
        /// The person the entry names; check 8 binds it to the device certificate's person (P3-D6).
        public let personID: ID16
        /// Raw scopes as signed; validated against the certificate in `check`.
        public let scopes: JSONValue
        public var scopeStrings: [String]? { scopes.array.flatMap { a in let s = a.compactMap(\.string); return s.count == a.count ? s : nil } }
        package init(deviceID: ID16, personID: ID16, scopes: JSONValue) { self.deviceID = deviceID; self.personID = personID; self.scopes = scopes }
    }
    public let workspace: ID16
    public let epoch: UInt32
    public let listSeq: Int64
    public let issuedMs: Int64
    /// Persons other than the card owner whose devices this list may name (P3-D6 / D39): sorted, unique. A WSK-signed
    /// authorization statement, not proof of F1 roles.
    public let persons: [ID16]
    public let members: [Member]
    /// Q10 (one `WK` per epoch, ever): `H("orch/v2/wk-commit|" || workspace_id || u32(epoch) || WK_epoch)`, 32 bytes. A device
    /// seals only under a grant whose key this commits (`WKCommit`); the relay refuses another commit at its current epoch.
    public let wkCommit: Data

    /// Does this list commit to `wk` at its own workspace and epoch?
    public func commits(_ wk: SymmetricKey) -> Bool { WKCommit.matches(wkCommit, workspace: workspace, epoch: epoch, wk: wk) }

    /// What the relay (and a verifying phone) knows about the devices a list may name.
    public struct Directory: Sendable {
        public struct GrantKey: Hashable, Sendable {
            public let device: ID16, epoch: UInt32
            public init(device: ID16, epoch: UInt32) { self.device = device; self.epoch = epoch }
        }
        /// The card owner's account key.
        public var ownerKey: SigningPublicKey
        /// Account keys of other persons (directory accounts), by person id.
        public var persons: [ID16: SigningPublicKey]
        public var certs: [ID16: JSONValue]
        public var revoked: Set<ID16>
        public var grants: Set<GrantKey>
        public init(ownerKey: SigningPublicKey, persons: [ID16: SigningPublicKey] = [:], certs: [ID16: JSONValue], revoked: Set<ID16>,
                    grants: Set<GrantKey>) {
            self.ownerKey = ownerKey; self.persons = persons; self.certs = certs; self.revoked = revoked; self.grants = grants
        }
    }

    public static let maxMembers = 1024
    static let fields: Set<String> = ["v", "suite", "kind", "workspace_id", "epoch", "list_seq", "issued_ms", "persons", "members", "wk_commit"]
    static let memberFields: Set<String> = ["device_id", "person_id", "scopes"]

    /// Steps 1 and 2 of section 7.2: the signature with the card's `wsk_pub`, then the shape (field set, sorted unique hex
    /// ids, `epoch >= 1`). `bad_signature` or `malformed`.
    public static func verify(_ signed: JSONValue, wsk: SigningPublicKey) throws -> MemberList {
        let o: [String: JSONValue]
        do { o = try SignedObject.parse(signed).verify(kind: .memberList, key: wsk) }
        catch let r as Refusal where r == .badSignature { throw r }
        catch { throw Refusal.badSignature }
        return try parse(object: o)
    }

    /// Shape only (no signature): see `verify`. Fails closed: exact field sets, lower-case 16-byte hex ids, `persons` and
    /// `members` strictly increasing (sorted, no duplicates), `list_seq` in `1 ... 2^53-1`, `issued_ms` an integer, `wk_commit`
    /// exactly 32 bytes of canonical b64u.
    static func parse(object o: [String: JSONValue]) throws -> MemberList {
        guard o.hasExactly(fields), let ws = o.id16("workspace_id"), let epoch = o.positiveU32("epoch"),
              let commit = o.b64u("wk_commit", length: WKCommit.length),
              let seq = o["list_seq"]?.int, seq >= 1, seq <= maxSafeInt, let issued = o["issued_ms"]?.int,
              let rawPersons = o["persons"]?.array, rawPersons.count <= maxMembers,
              let raw = o["members"]?.array, raw.count <= maxMembers else { throw Refusal.malformed }
        var persons: [ID16] = []
        for p in rawPersons {
            guard let id = p.string.flatMap({ ID16(hex: $0) }) else { throw Refusal.malformed }
            persons.append(id)
        }
        var members: [Member] = []
        for m in raw {
            guard let mo = m.object, mo.hasExactly(memberFields), let id = mo.id16("device_id"), let person = mo.id16("person_id"),
                  let scopes = mo["scopes"] else { throw Refusal.malformed }
            members.append(Member(deviceID: id, personID: person, scopes: scopes))
        }
        // sorted, no duplicates (lower-case hex sorts like the bytes)
        for (a, b) in zip(persons, persons.dropFirst()) where !a.hex.utf8.lexicographicallyPrecedes(b.hex.utf8) { throw Refusal.malformed }
        for (a, b) in zip(members, members.dropFirst()) where !a.deviceID.hex.utf8.lexicographicallyPrecedes(b.deviceID.hex.utf8) {
            throw Refusal.malformed
        }
        return MemberList(workspace: ws, epoch: epoch, listSeq: seq, issuedMs: issued, persons: persons, members: members, wkCommit: commit)
    }

    /// What a device does with a list it fetched, given the last list it accepted (`known`, nil on first contact or late join,
    /// when the first list it sees may carry any epoch and `list_seq >= 1`). Identical list again (reconnect) and forward jumps
    /// (missed lists and rotations, including an epoch that rises by more than one, P3-D6) pass; rollback, conflicting content
    /// under one `list_seq`, an epoch that falls, and a removal without an epoch bump are refused. Two lists at one epoch with
    /// different `wk_commit` are the local alarm `wk_commit_conflict` (Q10), checked first: it holds whatever their order.
    /// Certificates and grants of other members are the relay's to check: a phone does not hold them (gap 27). The coordinator
    /// separately requires its own device and approved scopes.
    public func checkSnapshot(cardWorkspace: ID16, known: MemberList?) throws {
        guard workspace == cardWorkspace else { throw Refusal.otherWorkspace }
        guard let k = known else {
            guard listSeq >= 1 else { throw Refusal.badEpoch }
            return
        }
        if epoch == k.epoch, wkCommit != k.wkCommit { throw Refusal.wkCommitConflict }
        if listSeq < k.listSeq { throw Refusal.staleList }
        if listSeq == k.listSeq {
            guard self == k else { throw Refusal.conflictingSnapshot }
            return
        }
        guard epoch >= k.epoch else { throw Refusal.badEpoch }
        let now = Set(members.map(\.deviceID))
        if epoch == k.epoch, k.members.contains(where: { !now.contains($0.deviceID) }) { throw Refusal.rotationRequired }
    }

    /// The rest of section 7.2 (checks 3 to 9), as the relay applies them before it publishes a list. `cardWorkspace` is the
    /// workspace of the card whose `wsk_pub` verified the list; `previous` is the last accepted list. Epochs never skip and
    /// nothing retires an epoch: atomic publication (P3-D7) leaves no partial rotation at the relay.
    ///
    /// Per member, in the relay's order: `revoked`; a stored certificate (`cert_invalid`); the certificate's person equals the
    /// entry's `person_id` and is the card owner or in `persons`, with a directory account (`other_person`); the certificate
    /// verifies under that account key now (`cert_invalid`, `cert_expired`) for exactly this device; scopes (`scope_exceeded`);
    /// the grant at this epoch (`missing_grant`). Then every `persons` entry needs a member device (`other_person`), and the
    /// first list a device of the owner (`other_person`).
    public func checkRelayUpdate(cardWorkspace: ID16, previous: MemberList?, directory: Directory, nowMs: Int64) throws {
        guard workspace == cardWorkspace else { throw Refusal.otherWorkspace }
        try checkSequence(previous: previous.map { Previous(listSeq: $0.listSeq, epoch: $0.epoch, members: Set($0.members.map(\.deviceID)),
                                                            wkCommit: $0.wkCommit) })
        try checkMembers(directory: directory, nowMs: nowMs)
        try checkPersons(owner: Identifiers.personID(directory.ownerKey), first: previous == nil)
    }

    /// The relay's stored list as `checkSequence` reads it. `wkCommit` is nil for a stored list without one (never accepted
    /// since Q10; a same-epoch successor is then `wk_commit_changed`).
    public struct Previous: Sendable {
        public var listSeq: Int64, epoch: UInt32, members: Set<ID16>, wkCommit: Data?
        public init(listSeq: Int64, epoch: UInt32, members: Set<ID16>, wkCommit: Data?) {
            self.listSeq = listSeq; self.epoch = epoch; self.members = members; self.wkCommit = wkCommit
        }
    }

    /// How far one publication may move the epoch (Q10): a host that skips epochs it burned (refused publications whose keys it
    /// retains, never reseals) stays within this of the relay's epoch, and a first list within this of 1.
    public static let maxEpochStep: UInt32 = 1 << 16

    /// Checks 4 to 7 as decided for Q10 (one `WK` per epoch, ever): a first list has `1 <= epoch <= 2^16` (any `list_seq >= 1`,
    /// which the shape already requires); then `list_seq` strictly increases (`stale_list`), `prev <= epoch <= prev + 2^16`
    /// (`bad_epoch`), a removal needs `epoch > prev` (`rotation_required`), and a list at the same epoch carries the same
    /// `wk_commit` (`wk_commit_changed`).
    public func checkSequence(previous: Previous?) throws {
        guard let p = previous else {
            guard epoch >= 1, epoch <= Self.maxEpochStep else { throw Refusal.badEpoch }
            return
        }
        guard listSeq > p.listSeq else { throw Refusal.staleList }
        guard epoch >= p.epoch, UInt64(epoch) <= UInt64(p.epoch) + UInt64(Self.maxEpochStep) else { throw Refusal.badEpoch }
        let now = Set(members.map(\.deviceID))
        if !p.members.isSubset(of: now), epoch == p.epoch { throw Refusal.rotationRequired }
        if epoch == p.epoch, p.wkCommit != wkCommit { throw Refusal.wkCommitChanged }
    }

    /// Check 8 and 9 for every member (see `checkRelayUpdate`).
    public func checkMembers(directory: Directory, nowMs: Int64) throws {
        let owner = Identifiers.personID(directory.ownerKey)
        let allowed = Set(persons).union([owner])
        for m in members {
            try Self.checkMemberCertificate(m, owner: owner, allowed: allowed, directory: directory, nowMs: nowMs)
            guard directory.grants.contains(.init(device: m.deviceID, epoch: epoch)) else { throw Refusal.missingGrant }
        }
    }

    /// Every `persons` entry has a member device of that person in this list, and a first list names a device of the owner
    /// (`other_person`; G0a review 1, check 4).
    public func checkPersons(owner: ID16, first: Bool) throws {
        let bound = Set(members.map(\.personID))
        guard Set(persons).isSubset(of: bound) else { throw Refusal.otherPerson }
        if first, !bound.contains(owner) { throw Refusal.otherPerson }
    }

    /// The write-time certificate check of one member (also used for grants and wraps, which name members only).
    public static func checkMemberCertificate(_ m: Member, owner: ID16, allowed: Set<ID16>, directory: Directory, nowMs: Int64) throws {
        if directory.revoked.contains(m.deviceID) { throw Refusal.revoked }
        guard let certJSON = directory.certs[m.deviceID], let co = certJSON.object?["o"]?.object else { throw Refusal.certInvalid }
        guard let person = co["person_id"]?.string.flatMap({ ID16(hex: $0) }), person == m.personID, allowed.contains(person) else {
            throw Refusal.otherPerson
        }
        guard let key = person == owner ? directory.ownerKey : directory.persons[person] else { throw Refusal.otherPerson }
        let cert = try DeviceCertificate.verify(certJSON, personKey: key, nowMs: nowMs, revoked: directory.revoked)
        guard cert.deviceID == m.deviceID else { throw Refusal.certInvalid }
        guard !cert.isScopedAgent, let scopes = m.scopeStrings, Scopes.isValid(scopes), scopes.count <= cert.scopesMax.count,
              Array(cert.scopesMax.prefix(scopes.count)) == scopes else { throw Refusal.scopeExceeded }
    }
}

/// Q10's key commitment: `wk_commit = b64u(H("orch/v2/wk-commit|" || workspace_id || u32(epoch) || WK))` (SHA-256, the 16 raw
/// bytes of the workspace id, the epoch big-endian). Binding the workspace and epoch keeps one key from answering for another.
public enum WKCommit {
    public static let length = 32

    public static func compute(workspace: ID16, epoch: UInt32, wk: SymmetricKey) -> Data {
        Data(SHA256.hash(data: Data(Label.hWKCommit.utf8) + workspace.bytes + Bytes.u32(epoch) + wk.rawBytes))
    }

    /// Constant-time comparison against a commitment taken from a verified list.
    public static func matches(_ commit: Data, workspace: ID16, epoch: UInt32, wk: SymmetricKey) -> Bool {
        let mine = compute(workspace: workspace, epoch: epoch, wk: wk)
        guard commit.count == mine.count else { return false }
        return zip(commit, mine).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
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
