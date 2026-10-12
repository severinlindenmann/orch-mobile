import CryptoKit
import Foundation
import Testing
@testable import OrchProtocol

@Suite struct SecReviewTests {
    // MARK: bridge
    struct BridgeFixture {
        let wsk = SoftwareSigner(), member = SoftwareSigner()
        let ws = ID16.random(), dev = ID16.random(), rid = ID16.random()
        let wk = SymmetricKey(size: .bits256)
        var ctx: Bridge.DeviceContext { .init(workspace: ws, device: dev, wsk: wsk.publicKey, wk: [3: wk]) }
        func env(seq: UInt64, flags: Bridge.Flags = [.last], ts: UInt64, meta: JSONValue = ["ok": true], signer: SoftwareSigner? = nil,
                 rid r: ID16? = nil) throws -> Data {
            let h = Bridge.Header(direction: .toDevice, flags: flags, workspace: ws, device: dev, rid: r ?? rid, seq: seq, tsMs: ts, epoch: 3)
            return try Bridge.seal(header: h, channelKey: Bridge.channelKey(header: h, wk: wk)!, signer: signer ?? wsk,
                                   plaintext: Bridge.frame(meta: meta))
        }
        func mb(_ seq: UInt64, last: Bool = true, stream: Bool = false) -> Bridge.MailboxPosition { .init(id: rid, index: seq, last: last, stream: stream) }
    }

    @Test func bridgeReplayAndForgery() throws {
        let f = BridgeFixture(), now: Int64 = 1_000_000_000
        let pend: [ID16: Bridge.PendingRequest] = [f.rid: .init(epoch: 3)]
        let e0 = try f.env(seq: 0, ts: UInt64(now))
        let (o1, t1) = Bridge.checkResponse(e0, context: f.ctx, pending: pend, mailbox: f.mb(0), nowMs: now)
        guard case .accept = o1 else { Issue.record("first"); return }
        // replay of the same chunk
        #expect(Bridge.checkResponse(e0, context: f.ctx, pending: t1, mailbox: f.mb(0), nowMs: now).outcome == .drop(.unknownRequest))
        // member device (has WK) forging a host response: pin failure
        let forged = try f.env(seq: 0, ts: UInt64(now), signer: f.member)
        #expect(Bridge.checkResponse(forged, context: f.ctx, pending: pend, mailbox: f.mb(0), nowMs: now).outcome == .drop(.hostSignature(pinFailure: true)))
        // header tamper (rid swapped, mailbox follows) -> signature fails
        var t = e0; let rid2 = ID16.random(); t.replaceSubrange(40..<56, with: rid2.bytes)
        let p2: [ID16: Bridge.PendingRequest] = [rid2: .init(epoch: 3)]
        let o3 = Bridge.checkResponse(t, context: f.ctx, pending: p2, mailbox: .init(id: rid2, index: 0, last: true, stream: false), nowMs: now).outcome
        #expect(o3 == .drop(.hostSignature(pinFailure: false)))
        // truncated / oversized
        #expect(Bridge.checkResponse(e0.dropLast(), context: f.ctx, pending: pend, mailbox: f.mb(0), nowMs: now).outcome == .drop(.hostSignature(pinFailure: false)))
        #expect(Bridge.checkResponse(Data(count: Bridge.maxChunk + 1), context: f.ctx, pending: pend, mailbox: f.mb(0), nowMs: now).outcome == .drop(.size))
        // slice input (non-zero startIndex)
        let sliced = (Data([0, 0, 0]) + e0).dropFirst(3)
        if case .accept = Bridge.checkResponse(sliced, context: f.ctx, pending: pend, mailbox: f.mb(0), nowMs: now).outcome {} else { Issue.record("slice") }
        // stale ts
        let old = try f.env(seq: 0, ts: UInt64(now - 400_000))
        #expect(Bridge.checkResponse(old, context: f.ctx, pending: pend, mailbox: f.mb(0), nowMs: now).outcome == .drop(.staleTimestamp))
        // unframe hostile length
        #expect(throws: (any Error).self) { try Bridge.unframe(Data([0xFF, 0xFF, 0xFF, 0xFF, 0x7B, 0x7D])) }
    }

    /// After the `last` chunk the rid is retired; a further signed chunk is dropped.
    @Test func bridgeChunkAfterLast() throws {
        let f = BridgeFixture(), now: Int64 = 1_000_000_000
        let pend: [ID16: Bridge.PendingRequest] = [f.rid: .init(epoch: 3)]
        let (_, t1) = Bridge.checkResponse(try f.env(seq: 0, ts: UInt64(now)), context: f.ctx, pending: pend, mailbox: f.mb(0), nowMs: now)
        let (o2, _) = Bridge.checkResponse(try f.env(seq: 1, ts: UInt64(now)), context: f.ctx, pending: t1, mailbox: f.mb(1), nowMs: now)
        #expect(o2 == .drop(.unknownRequest), "a further host chunk after `last` must be dropped")
    }

    /// A second stale_timestamp refusal for a rid that already adopted an offset gets the normal window check.
    @Test func bridgeSecondStaleRefusal() throws {
        let f = BridgeFixture(), now: Int64 = 1_000_000_000
        let pend: [ID16: Bridge.PendingRequest] = [f.rid: .init(epoch: 3, offsetAdopted: true)]
        let e = try f.env(seq: 0, flags: [.last, .refusal], ts: 1, meta: ["refusal": "stale_timestamp", "host_ms": .int(now)])
        let o = Bridge.checkResponse(e, context: f.ctx, pending: pend, mailbox: f.mb(0), nowMs: now).outcome
        #expect(o == .drop(.staleTimestamp))
    }

    // MARK: member list
    func cert(_ pk: SoftwareSigner, _ dev: SoftwareSigner, scopes: [String] = ["look", "decide"]) throws -> JSONValue {
        try SignedObject.sign(["v": 2, "suite": 2, "kind": "device_cert", "device_id": .string(Identifiers.deviceID(dev.publicKey).hex),
                               "person_id": .string(Identifiers.personID(pk.publicKey).hex),
                               "dk_sig_pub": .string(B64U.encode(dev.publicKey.x963)), "dk_kx_pub": .string(B64U.encode(SoftwareKeyAgreer().publicKey.x963)),
                               "label_sealed": .string(B64U.encode(Data(count: 40))), "created_ms": 1, "expires_ms": .null,
                               "scopes_max": .array(scopes.map { .string($0) })], kind: .deviceCert, signer: pk).json
    }
    func list(_ ws: ID16, epoch: Int64, seq: Int64, ids: [ID16], scopes: [String] = ["look"], person: ID16, persons: [ID16] = []) -> MemberList {
        let sorted = ids.sorted { $0.hex < $1.hex }
        return try! MemberList.parse(object: ["v": 2, "suite": 2, "kind": "member_list", "workspace_id": .string(ws.hex), "epoch": .int(epoch),
                                              "list_seq": .int(seq), "issued_ms": 1, "persons": .array(persons.map { .string($0.hex) }),
                                              "wk_commit": testWKCommit(ws, epoch),
                                              "members": .array(sorted.map { ["device_id": .string($0.hex), "person_id": .string(person.hex),
                                                                               "scopes": .array(scopes.map { .string($0) })] })])
    }

    @Test func memberListChecks() throws {
        let pk = SoftwareSigner(), a = SoftwareSigner(), b = SoftwareSigner()
        let ida = Identifiers.deviceID(a.publicKey), idb = Identifiers.deviceID(b.publicKey), ws = ID16.random()
        let me = Identifiers.personID(pk.publicKey)
        var dir = MemberList.Directory(ownerKey: pk.publicKey, certs: [ida: try cert(pk, a), idb: try cert(pk, b)], revoked: [],
                                       grants: [.init(device: ida, epoch: 1), .init(device: idb, epoch: 1), .init(device: ida, epoch: 2)])
        let l1 = list(ws, epoch: 1, seq: 1, ids: [ida, idb], person: me)
        try l1.checkRelayUpdate(cardWorkspace: ws, previous: nil, directory: dir, nowMs: 10)
        // removal without rotation
        #expect(throws: Refusal.rotationRequired) { try list(ws, epoch: 1, seq: 2, ids: [ida], person: me).checkRelayUpdate(cardWorkspace: ws, previous: l1, directory: dir, nowMs: 10) }
        try list(ws, epoch: 2, seq: 2, ids: [ida], person: me).checkRelayUpdate(cardWorkspace: ws, previous: l1, directory: dir, nowMs: 10)
        // revoked
        dir.revoked = [idb]
        #expect(throws: Refusal.revoked) { try l1.checkRelayUpdate(cardWorkspace: ws, previous: nil, directory: dir, nowMs: 10) }
        dir.revoked = []
        // scope beyond cert
        #expect(throws: Refusal.scopeExceeded) {
            try list(ws, epoch: 1, seq: 1, ids: [ida], scopes: ["look", "decide", "operate"], person: me).checkRelayUpdate(cardWorkspace: ws, previous: nil, directory: dir, nowMs: 10)
        }
        // a cert filed under another device id must not admit that id
        let ghost = ID16.random()
        dir.certs[ghost] = try cert(pk, a); dir.grants.insert(.init(device: ghost, epoch: 1))
        #expect(throws: Refusal.certInvalid) { try list(ws, epoch: 1, seq: 1, ids: [ghost], person: me).checkRelayUpdate(cardWorkspace: ws, previous: nil, directory: dir, nowMs: 10) }
        // P3-D6: an entry naming another person than its certificate's; a listed person without a member device (G0a review 1);
        // another person's device needs that person in `persons` and an account key.
        let bob = SoftwareSigner(), bobDev = SoftwareSigner(), bobID = Identifiers.personID(bob.publicKey), idc = Identifiers.deviceID(bobDev.publicKey)
        #expect(throws: Refusal.otherPerson) { try list(ws, epoch: 1, seq: 1, ids: [ida], person: bobID).checkRelayUpdate(cardWorkspace: ws, previous: nil, directory: dir, nowMs: 10) }
        #expect(throws: Refusal.otherPerson) { try list(ws, epoch: 1, seq: 1, ids: [ida], person: me, persons: [bobID]).checkRelayUpdate(cardWorkspace: ws, previous: nil, directory: dir, nowMs: 10) }
        dir.certs[idc] = try cert(bob, bobDev); dir.grants.insert(.init(device: idc, epoch: 2))
        let withBob = try MemberList.parse(object: ["v": 2, "suite": 2, "kind": "member_list", "workspace_id": .string(ws.hex), "epoch": 2, "list_seq": 2,
                                                    "issued_ms": 1, "persons": [.string(bobID.hex)], "wk_commit": testWKCommit(ws, 2),
                                                    "members": .array([(ida, me), (idc, bobID)].sorted { $0.0.hex < $1.0.hex }.map {
                                                        ["device_id": .string($0.0.hex), "person_id": .string($0.1.hex), "scopes": ["look"]] })])
        #expect(throws: Refusal.otherPerson) { try withBob.checkRelayUpdate(cardWorkspace: ws, previous: l1, directory: dir, nowMs: 10) }   // no account
        dir.persons[bobID] = bob.publicKey
        try withBob.checkRelayUpdate(cardWorkspace: ws, previous: l1, directory: dir, nowMs: 10)
        // a first list must name a device of the card owner
        dir.grants.insert(.init(device: idc, epoch: 1))
        #expect(throws: Refusal.otherPerson) {
            try list(ws, epoch: 1, seq: 1, ids: [idc], person: bobID, persons: [bobID]).checkRelayUpdate(cardWorkspace: ws, previous: nil, directory: dir, nowMs: 10)
        }
    }

    @Test func hostedMarker() {
        #expect(HostedMarker.decide(delegationClientHosted: true, hostedBy: nil).marker)
        #expect(HostedMarker.decide(delegationClientHosted: true, hostedBy: "").marker)
        #expect(HostedMarker.decide(delegationClientHosted: false, hostedBy: "x").marker)
        #expect(!HostedMarker.decide(delegationClientHosted: false, hostedBy: nil).marker)
    }

    // MARK: cert challenge / ledger
    @Test func challengeR1() throws {
        let pk = SoftwareSigner(), phoneSig = SoftwareSigner(), phoneKx = SoftwareKeyAgreer(), evil = SoftwareSigner()
        let ws = ID16.random(), me = Identifiers.deviceID(phoneSig.publicKey), offer = ID16.random(), att = String(repeating: "d", count: 32)
        let c = PairingAttemptContext(workspace: ws, offer: offer, device: me, dkSig: phoneSig.publicKey, dkKx: phoneKx.publicKey, attempt: att,
                                      earlierAttempts: [], acceptedRequestID: nil)
        func ch(_ sig: SigningPublicKey, _ kx: AgreementPublicKey, dev: ID16, signer: SoftwareSigner) throws -> JSONValue {
            try CertChallenge.sign(["v": 2, "suite": 2, "kind": "cert_challenge", "request_id": .string(ID16.random().hex), "workspace_id": .string(ws.hex),
                                    "person_id": .string(Identifiers.personID(signer.publicKey).hex), "offer_id": .string(offer.hex),
                                    "attempt": .string(att), "device_id": .string(dev.hex),
                                    "dk_sig_pub": .string(B64U.encode(sig.x963)), "dk_kx_pub": .string(B64U.encode(kx.x963)),
                                    "primary_nonce": .string(B64U.encode(Data(count: 32))), "expires_ms": 100], primary: signer).json
        }
        _ = try CertChallenge.check(try ch(phoneSig.publicKey, phoneKx.publicKey, dev: me, signer: pk), pk: pk.publicKey, attempt: c, nowMs: 50)
        // host substitutes its own sig key, keeps the phone's id
        #expect(throws: CertChallengeDrop.notMyKey) {
            try CertChallenge.check(try ch(evil.publicKey, phoneKx.publicKey, dev: me, signer: pk), pk: pk.publicKey, attempt: c, nowMs: 50)
        }
        #expect(throws: CertChallengeDrop.notMyKey) {
            try CertChallenge.check(try ch(phoneSig.publicKey, SoftwareKeyAgreer().publicKey, dev: me, signer: pk), pk: pk.publicKey, attempt: c, nowMs: 50)
        }
        // challenge signed by a different person key
        #expect(throws: CertChallengeDrop.challengeSignature) {
            try CertChallenge.check(try ch(phoneSig.publicKey, phoneKx.publicKey, dev: me, signer: evil), pk: pk.publicKey, attempt: c, nowMs: 50)
        }
    }

    @Test func ledgerFlow() throws {
        let pk = SoftwareSigner(), wsk = SoftwareSigner(), primaryKx = SoftwareKeyAgreer(), primaryID = ID16.random()
        let ws = ID16.random(), person = Identifiers.personID(pk.publicKey)
        let del = try WorkspaceDelegation.sign(workspace: ws, wsk: wsk.publicKey, clientHosted: false, issuedMs: 1, owner: pk)
        let ck = SymmetricKey(size: .bits256)
        let sealed = try Card.sealPart(.init(name: "n", description: "d", capabilities: [], hostedBy: nil), ck: ck, workspace: ws, cardSeq: 1)
        let card = try Card.verify(try Card.make(delegation: del, workspace: ws, wxk: SoftwareKeyAgreer().publicKey, wxkVersion: 1, owner: person,
                                                 relayURL: "https://r.example", cardSeq: 1, issuedMs: 1, sealed: sealed, ck: ck, wsk: wsk), ownerKey: pk.publicKey)
        func req(_ id: ID16, scopes: [String] = ["look"], now: Int64) throws -> JSONValue {
            let d = SoftwareSigner()
            let inner = CertRequestInner(deviceID: Identifiers.deviceID(d.publicKey), dkSig: d.publicKey, dkKx: SoftwareKeyAgreer().publicKey,
                                         label: "x", scopesMax: scopes, offerID: ID16.random(), attempt: String(repeating: "e", count: 32))
            return try CertRequest.make(wsk: wsk, requestID: id, workspace: ws, person: person, primary: primaryID, primaryKey: primaryKx.publicKey,
                                        inner: inner, createdMs: now).json
        }
        var L = PrimaryLedger()
        let r1 = ID16.random(), r2 = ID16.random()
        _ = try CertRequest.openAsPrimary(try req(r1, now: 1000), card: card, myPerson: person, me: primaryID, myKey: primaryKx, ledger: &L, nowMs: 1000)
        #expect(throws: Refusal.requestOpen) {
            try CertRequest.openAsPrimary(try req(r2, now: 1000), card: card, myPerson: person, me: primaryID, myKey: primaryKx, ledger: &L, nowMs: 1000)
        }
        #expect(throws: Refusal.replayed) {
            try CertRequest.openAsPrimary(try req(r1, now: 1000), card: card, myPerson: person, me: primaryID, myKey: primaryKx, ledger: &L, nowMs: 1000)
        }
        #expect(throws: Refusal.expired) { var l = L; _ = try l.issueChallenge(requestID: r1, primaryNonce: Data(count: 32), primary: pk, nowMs: 1000 + CertRequest.lifetimeMs) }
        _ = try L.issueChallenge(requestID: r1, primaryNonce: Data(count: 32), primary: pk, nowMs: 1000)
        #expect(throws: Refusal.replayed) { try L.issueChallenge(requestID: r1, primaryNonce: Data(repeating: 1, count: 32), primary: pk, nowMs: 1000) }
        // a certificate is never wider than the request asked for
        #expect(throws: Refusal.scopeExceeded) {
            var l = L; _ = try l.signCertificate(requestID: r1, labelSealed: Data(count: 40), createdMs: 2000, expiresMs: nil, scopesMax: ["look", "decide", "operate", "type"], primary: pk)
        }
        #expect(throws: Refusal.scopeExceeded) {
            var l = L; _ = try l.signCertificate(requestID: r1, labelSealed: Data(count: 40), createdMs: 2000, expiresMs: nil, scopesMax: ["look", "decide"], primary: pk)
        }
        _ = L
        _ = try L.signCertificate(requestID: r1, labelSealed: Data(count: 40), createdMs: 2000, expiresMs: nil, scopesMax: ["look"], primary: pk)
        #expect(throws: Refusal.alreadySigned) {
            try L.signCertificate(requestID: r1, labelSealed: Data(count: 40), createdMs: 2000, expiresMs: nil, scopesMax: ["look"], primary: pk)
        }
        // a drop-scoped request is refused
        #expect(throws: Refusal.scopeExceeded) {
            try CertRequest.openAsPrimary(try req(r2, scopes: ["drop:" + ID16.random().hex], now: 3000), card: card, myPerson: person, me: primaryID,
                                          myKey: primaryKx, ledger: &L, nowMs: 3000)
        }
    }

    // MARK: relay URL
    @Test func relayURLs() {
        let bad = ["https://user@host.com", "https://host.com/", "https://HOST.com", "https://host.com:0", "https://host.com:", "https://.host",
                   "https://host.", "https://[::1]", "http://localhost.evil.com", "http://127.0.0.1@evil.com", "http://evil.com", "https://h\u{0}st",
                   "https://hést.com", "https://host.com?x", "https://host.com#x", "ftp://host", "https://host.com:080", " https://a.com",
                   "https://a.com\n", "HTTPS://a.com", "https://a_b.com", "http://[::1", "http://localhost:99999x", "https://a.com:123456"]
        for u in bad { #expect(!RelayURL.isValid(u), "\(u)") }
        let good = ["https://a", "https://r.example.com:8443", "http://localhost", "http://[::1]:80", "http://127.0.0.1:1"]
        for u in good { #expect(RelayURL.isValid(u), "\(u)") }
        for u in ["https://a.com:99999", "https://a.com:65536", "https://0x7f000001", "https://2130706433", "https://1.2.3.4", "https://a..b", "https://a.0xFF",
                  "https://a.123", "https://example.123", "https://127.1", "https://0177.0.0.1", "https://0x7f.1", "https://0x"] { #expect(!RelayURL.isValid(u), "\(u)") }
        // punycode stays valid: a UI shows the ASCII host and never decodes it
        for u in ["https://xn--pple-43d.com", "https://localhost", "https://a.com:65535", "https://a1.b2", "https://0xg.com", "https://x0x7f.com", "https://123.example.com", "https://0xdead.example.com", "https://1password.com", "https://0x.example.com"] { #expect(RelayURL.isValid(u), "\(u)") }
    }

    // MARK: drop
    @Test func dropBlobTamper() throws {
        let dek = SymmetricKey(size: .bits256), obj = ID16.random()
        let pt = Data((0..<100).map { UInt8($0) })
        let blob = try DropBlob.encrypt(dek: dek, object: obj, version: 1, plaintext: pt, chunkSize: 32)
        #expect(try DropBlob.decrypt(dek: dek, object: obj, version: 1, blob: blob) == pt)
        let hdr = blob.prefix(40), step = 48
        let chunks = stride(from: 40, to: blob.count, by: step).map { blob.subdata(in: $0..<min($0 + step, blob.count)) }
        #expect(chunks.count == 4)
        // reorder
        #expect(throws: (any Error).self) { try DropBlob.decrypt(dek: dek, object: obj, version: 1, blob: hdr + chunks[1] + chunks[0] + chunks[2] + chunks[3]) }
        // truncate at chunk boundary
        #expect(throws: (any Error).self) { try DropBlob.decrypt(dek: dek, object: obj, version: 1, blob: hdr + chunks[0] + chunks[1] + chunks[2]) }
        // append a duplicate
        #expect(throws: (any Error).self) { try DropBlob.decrypt(dek: dek, object: obj, version: 1, blob: blob + chunks[3]) }
        // other object/version
        #expect(throws: (any Error).self) { try DropBlob.decrypt(dek: dek, object: ID16.random(), version: 1, blob: blob) }
        #expect(throws: (any Error).self) { try DropBlob.decrypt(dek: dek, object: obj, version: 2, blob: blob) }
        // header chunk size changed
        var h2 = blob; h2[28 + 3] = 64
        #expect(throws: (any Error).self) { try DropBlob.decrypt(dek: dek, object: obj, version: 1, blob: h2) }
        // huge declared chunk size, tiny blob
        var h3 = blob; h3.replaceSubrange(28..<32, with: Bytes.u32(UInt32(Drop.maxChunkSize)))
        #expect(throws: (any Error).self) { try DropBlob.decrypt(dek: dek, object: obj, version: 1, blob: h3) }
    }

    func desc(_ obj: ID16, version: Int64, parentHash: JSONValue, space: ID16) -> [String: JSONValue] {
        ["v": 2, "suite": 2, "kind": "drop_object", "object_id": .string(obj.hex), "space_id": .string(space.hex), "space_kind": "workspace",
         "object_kind": "document", "version": .int(version), "parent": .int(version - 1), "parent_hash": parentHash, "author_kind": "device",
         "author_id": .string(ID16.random().hex), "content_hash": .string(B64U.encode(Data(count: 32))), "content_len": 0,
         "dek_commit": .string(B64U.encode(Data(count: 32))), "meta": .string(B64U.encode(Data(count: 20))), "recipients": "inbox",
         "origin": "human", "created_ms": 1, "expires_ms": .null]
    }

    @Test func dropChainAndPut() throws {
        let a = ID16.random(), b = ID16.random(), sp = ID16.random(), sp2 = ID16.random()
        let a1 = desc(a, version: 1, parentHash: .null, space: sp)
        let h1 = JSONValue.string(B64U.encode(try DropDescriptor.parentHash(of: a1)))
        let a2 = desc(a, version: 2, parentHash: h1, space: sp)
        try DropDocument.verifyChain([a1, a2])
        // fork: wrong parent hash
        #expect(throws: DropDocument.Fork.self) { try DropDocument.verifyChain([a1, desc(a, version: 2, parentHash: .string(B64U.encode(Data(count: 32))), space: sp)]) }
        // rollback via put
        var st = DropDocument.State(current: 0, head: nil)
        #expect(DropDocument.checkPut(state: &st, ifMatch: "0", descriptor: a1).status == 201)
        #expect(DropDocument.checkPut(state: &st, ifMatch: "0", descriptor: a1).status == 409)
        #expect(DropDocument.checkPut(state: &st, ifMatch: "01", descriptor: a2).status == 428)
        // FINDING probe: version 2 naming another object/space accepted into a's chain
        let b2 = desc(b, version: 2, parentHash: h1, space: sp2)
        #expect(throws: DropDocument.Fork.self) { try DropDocument.verifyChain([a1, b2]) }
        var st2 = st
        #expect(DropDocument.checkPut(state: &st2, ifMatch: "1", descriptor: b2).status == 409)
        #expect(st2 == st)
        // the same object in another space, or as another kind, is refused as well
        var otherSpace = a2; otherSpace["space_id"] = .string(sp2.hex)
        #expect(throws: DropDocument.Fork.self) { try DropDocument.verifyChain([a1, otherSpace]) }
        var otherKind = a2; otherKind["space_kind"] = "shared"
        var st4 = st
        #expect(DropDocument.checkPut(state: &st4, ifMatch: "1", descriptor: otherKind).status == 409)
        var st5 = st
        #expect(DropDocument.checkPut(state: &st5, ifMatch: "1", descriptor: a2).status == 201)
        // Kelvin sign in parent_hash: bytes compare
        if case .string(let s) = h1, s.contains("K") {
            let k = desc(a, version: 2, parentHash: .string(s.replacingOccurrences(of: "K", with: "\u{212A}")), space: sp)
            var st3 = st
            #expect(DropDocument.checkPut(state: &st3, ifMatch: "1", descriptor: k).status == 409)
        }
    }

    @Test func dropClaim() throws {
        let wskA = SoftwareSigner(), wskB = SoftwareSigner(), wsA = ID16.random(), wsB = ID16.random(), obj = ID16.random()
        let dek = SymmetricKey(size: .bits256)
        let wxkA = SoftwareKeyAgreer()
        let wxWrap = try DropWrap.wrapToKey(kind: .wxk, to: wxkA.publicKey, target: wsA, keyVersion: 1, object: obj, version: 1, dek: dek)
        func claim(_ s: SoftwareSigner, ws: ID16, epoch: UInt32 = 4) throws -> JSONValue {
            let r = try DropWrap.wrapWithSecret(kind: .wk, secret: SymmetricKey(size: .bits256), target: ws, keyVersion: epoch, object: obj, version: 1, dek: dek)
            return try DropClaim.make(wsk: s, object: obj, workspace: ws, wrap: r).json
        }
        let cards = [wsA: wskA.publicKey, wsB: wskB.publicKey], epochs: [ID16: UInt32] = [wsA: 4, wsB: 4]
        var st = DropClaim.Stored(object: obj, version: 1, state: .inbox, wraps: [wxWrap])
        // non-recipient workspace
        #expect(DropClaim.check(stored: &st, claim: try claim(wskB, ws: wsB), cards: cards, epochs: epochs).error == "not_eligible")
        // B signs a claim naming A
        #expect(DropClaim.check(stored: &st, claim: try claim(wskB, ws: wsA), cards: cards, epochs: epochs).error == "bad_signature")
        // stale epoch
        #expect(DropClaim.check(stored: &st, claim: try claim(wskA, ws: wsA, epoch: 3), cards: cards, epochs: epochs).error == "malformed")
        #expect(DropClaim.check(stored: &st, claim: try claim(wskA, ws: wsA), cards: cards, epochs: epochs).status == 200)
        #expect(DropClaim.check(stored: &st, claim: try claim(wskB, ws: wsB), cards: cards, epochs: epochs).error == "already_claimed")
        // wrap moved to another object fails AAD
        let w = try DropWrap.wrapWithSecret(kind: .wk, secret: dek, target: wsA, keyVersion: 1, object: obj, version: 1, dek: dek)
        let moved = DropWrapRecord(object: ID16.random(), version: 1, targetKind: .wk, target: wsA, keyVersion: 1, wrap: w.wrap)
        #expect(throws: (any Error).self) { try DropWrap.unwrap(moved, with: .wk(dek)) }
        let moved2 = DropWrapRecord(object: obj, version: 1, targetKind: .sk, target: wsA, keyVersion: 1, wrap: w.wrap)
        #expect(throws: (any Error).self) { try DropWrap.unwrap(moved2, with: .sk(dek)) }
    }
}
