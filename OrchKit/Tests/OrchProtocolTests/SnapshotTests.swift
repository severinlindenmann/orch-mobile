import CryptoKit
import Foundation
import Testing
@testable import OrchProtocol

/// Device snapshot validation (a phone reconnecting, missing rotations, joining late) versus relay publication rules.
@Suite struct SnapshotTests {
    struct Rig {
        let owner = SoftwareSigner(), wsk = SoftwareSigner(), ws = ID16.random()
        var ownerID: ID16 { Identifiers.personID(owner.publicKey) }
        func delegation(_ wsk: SoftwareSigner? = nil) throws -> SignedObject {
            try WorkspaceDelegation.sign(workspace: ws, wsk: (wsk ?? self.wsk).publicKey, clientHosted: false, issuedMs: 1, owner: owner)
        }
        func card(seq: UInt32, wxk: SoftwareKeyAgreer, version: UInt32, name: String = "n", signer: SoftwareSigner? = nil, delegation d: SignedObject? = nil) throws -> VerifiedCard {
            let ck = SymmetricKey(size: .bits256)
            let sealed = try Card.sealPart(.init(name: name, description: "d", capabilities: [], hostedBy: nil), ck: ck, workspace: ws, cardSeq: seq)
            let s = signer ?? wsk
            return try Card.verify(Card.make(delegation: d ?? delegation(s), workspace: ws, wxk: wxk.publicKey, wxkVersion: version, owner: ownerID,
                                             relayURL: "https://r.example", cardSeq: seq, issuedMs: 1, sealed: sealed, ck: ck, wsk: s), ownerKey: owner.publicKey)
        }
    }

    @Test func cardSnapshots() throws {
        let r = Rig(), x1 = SoftwareKeyAgreer(), x2 = SoftwareKeyAgreer(), x3 = SoftwareKeyAgreer()
        let c1 = try r.card(seq: 1, wxk: x1, version: 1)
        // late join: no known card, any sequence and version
        try Card.checkSnapshot(known: nil, next: try r.card(seq: 9, wxk: x3, version: 4))
        // reconnect: the identical card again
        try Card.checkSnapshot(known: c1.head, next: c1)
        // the relay's publication rule refuses the same card; the device does not use it
        #expect(throws: Refusal.staleCard) { try Card.checkRelayUpdate(previous: c1.head, next: c1) }
        // missed rotations: seq 1 -> 5, wxk_version 1 -> 3
        let c5 = try r.card(seq: 5, wxk: x3, version: 3)
        try Card.checkSnapshot(known: c1.head, next: c5)
        #expect(throws: Refusal.badWxkVersion) { try Card.checkRelayUpdate(previous: c1.head, next: c5) }
        // next step after a jump
        try Card.checkSnapshot(known: c5.head, next: try r.card(seq: 6, wxk: x3, version: 3))
        // rollback
        #expect(throws: Refusal.staleCard) { try Card.checkSnapshot(known: c5.head, next: c1) }
        #expect(throws: Refusal.staleCard) { try Card.checkSnapshot(known: c5.head, next: try r.card(seq: 4, wxk: x3, version: 3)) }
        // same sequence, different content
        #expect(throws: Refusal.conflictingSnapshot) { try Card.checkSnapshot(known: c1.head, next: try r.card(seq: 1, wxk: x1, version: 1, name: "other")) }
        // WXK versions never fall; the key changes exactly with the version
        #expect(throws: Refusal.badWxkVersion) { try Card.checkSnapshot(known: c5.head, next: try r.card(seq: 6, wxk: x2, version: 2)) }
        #expect(throws: Refusal.wxkChangedWithoutVersion) { try Card.checkSnapshot(known: c5.head, next: try r.card(seq: 6, wxk: x1, version: 3)) }
        #expect(throws: Refusal.badWxkVersion) { try Card.checkSnapshot(known: c5.head, next: try r.card(seq: 6, wxk: x3, version: 4)) }
        // identity pins: another WSK (with its own delegation), another delegation for the same WSK, another workspace
        let otherWSK = SoftwareSigner()
        #expect(throws: Refusal.wskChanged) { try Card.checkSnapshot(known: c1.head, next: try r.card(seq: 2, wxk: x1, version: 1, signer: otherWSK)) }
        let reissued = try WorkspaceDelegation.sign(workspace: r.ws, wsk: r.wsk.publicKey, clientHosted: true, issuedMs: 2, owner: r.owner)
        #expect(throws: Refusal.delegationChanged) { try Card.checkSnapshot(known: c1.head, next: try r.card(seq: 2, wxk: x1, version: 1, delegation: reissued)) }
        var r2 = Rig(); _ = r2
        let foreign = Rig()
        #expect(throws: Refusal.otherWorkspace) { try Card.checkSnapshot(known: c1.head, next: try foreign.card(seq: 2, wxk: x1, version: 1)) }
        r2 = foreign
    }

    func list(_ ws: ID16, epoch: Int64, seq: Int64, ids: [ID16], scopes: [String] = ["look"]) throws -> MemberList {
        try MemberList.parse(object: ["v": 2, "suite": 2, "kind": "member_list", "workspace_id": .string(ws.hex), "epoch": .int(epoch), "list_seq": .int(seq),
                                      "issued_ms": 1, "members": .array(ids.sorted { $0.hex < $1.hex }.map { ["device_id": .string($0.hex), "scopes": .array(scopes.map { .string($0) })] })])
    }

    @Test func memberListSnapshots() throws {
        let ws = ID16.random(), a = ID16.random(), b = ID16.random(), c = ID16.random()
        let l = try list(ws, epoch: 1, seq: 1, ids: [a, b])
        // late join: the first list the device sees may be far along
        try list(ws, epoch: 3, seq: 7, ids: [a, b]).checkSnapshot(cardWorkspace: ws, known: nil)
        #expect(throws: Refusal.badEpoch) { try list(ws, epoch: 1, seq: 0, ids: [a]).checkSnapshot(cardWorkspace: ws, known: nil) }
        // reconnect: identical
        try l.checkSnapshot(cardWorkspace: ws, known: l)
        // additions in the same epoch, and jumps over missed lists and rotations
        try list(ws, epoch: 1, seq: 2, ids: [a, b, c]).checkSnapshot(cardWorkspace: ws, known: l)
        try list(ws, epoch: 4, seq: 9, ids: [a]).checkSnapshot(cardWorkspace: ws, known: l)
        // rollback and same-seq conflict
        let l5 = try list(ws, epoch: 2, seq: 5, ids: [a, b])
        #expect(throws: Refusal.staleList) { try l.checkSnapshot(cardWorkspace: ws, known: l5) }
        #expect(throws: Refusal.conflictingSnapshot) { try list(ws, epoch: 2, seq: 5, ids: [a]).checkSnapshot(cardWorkspace: ws, known: l5) }
        #expect(throws: Refusal.conflictingSnapshot) { try list(ws, epoch: 2, seq: 5, ids: [a, b], scopes: ["look", "decide"]).checkSnapshot(cardWorkspace: ws, known: l5) }
        // the epoch never falls, and a removal needs an epoch bump
        #expect(throws: Refusal.badEpoch) { try list(ws, epoch: 1, seq: 6, ids: [a, b]).checkSnapshot(cardWorkspace: ws, known: l5) }
        #expect(throws: Refusal.rotationRequired) { try list(ws, epoch: 2, seq: 6, ids: [a]).checkSnapshot(cardWorkspace: ws, known: l5) }
        try list(ws, epoch: 3, seq: 6, ids: [a]).checkSnapshot(cardWorkspace: ws, known: l5)
        // another workspace
        #expect(throws: Refusal.otherWorkspace) { try l.checkSnapshot(cardWorkspace: ID16.random(), known: nil) }
    }
}

@Suite struct CertScopeNarrowingTests {
    @Test func primaryMayNarrowButNeverWiden() throws {
        let pk = SoftwareSigner(), wsk = SoftwareSigner(), primaryKx = SoftwareKeyAgreer(), primaryID = ID16.random()
        let ws = ID16.random(), person = Identifiers.personID(pk.publicKey), ck = SymmetricKey(size: .bits256)
        let del = try WorkspaceDelegation.sign(workspace: ws, wsk: wsk.publicKey, clientHosted: false, issuedMs: 1, owner: pk)
        let sealed = try Card.sealPart(.init(name: "n", description: "d", capabilities: [], hostedBy: nil), ck: ck, workspace: ws, cardSeq: 1)
        let card = try Card.verify(try Card.make(delegation: del, workspace: ws, wxk: SoftwareKeyAgreer().publicKey, wxkVersion: 1, owner: person,
                                                 relayURL: "https://r.example", cardSeq: 1, issuedMs: 1, sealed: sealed, ck: ck, wsk: wsk), ownerKey: pk.publicKey)
        let d = SoftwareSigner()
        let inner = CertRequestInner(deviceID: Identifiers.deviceID(d.publicKey), dkSig: d.publicKey, dkKx: SoftwareKeyAgreer().publicKey,
                                     label: "x", scopesMax: ["look", "decide"], offerID: .random())
        let req = try CertRequest.make(wsk: wsk, requestID: .random(), workspace: ws, person: person, primary: primaryID, primaryKey: primaryKx.publicKey, inner: inner, createdMs: 1000)
        var ledger = PrimaryLedger()
        let a = try CertRequest.openAsPrimary(req.json, card: card, myPerson: person, me: primaryID, myKey: primaryKx, ledger: &ledger, nowMs: 1000)
        _ = try ledger.issueChallenge(requestID: a.requestID, primaryNonce: Data(count: 32), primary: pk, nowMs: 1000)
        for wider in [["look", "decide", "operate"], ["look", "decide", "operate", "type"]] {
            #expect(throws: Refusal.scopeExceeded) { var l = ledger; _ = try l.signCertificate(requestID: a.requestID, labelSealed: Data(count: 40), createdMs: 2000, expiresMs: nil, scopesMax: wider, primary: pk) }
        }
        let cert = try ledger.signCertificate(requestID: a.requestID, labelSealed: Data(count: 40), createdMs: 2000, expiresMs: nil, scopesMax: ["look"], primary: pk)
        #expect(try DeviceCertificate.verify(cert.json, personKey: pk.publicKey, nowMs: 2000).scopesMax == ["look"])
    }
}
