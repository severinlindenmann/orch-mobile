import CryptoKit
import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
import OrchTestVectors
@testable import OrchClient
@testable import OrchFakeHost
@testable import OrchProtocol

// FakePrimary against the cert_request vector groups. The vectors' keys are fixed and their private scalars are (rightly) not in
// shipped code, so the vector requests cannot be replayed into FakePrimary. Instead each named case is rebuilt with fresh keys and
// the same shape, fed through FakePrimary (section 8.4 step 2, in order), and the outcome must be the vector's: the same ok / refusal
// code, the same warning, the same ledger behaviour. The pure functions themselves are held to the byte-exact vectors in
// OrchProtocolTests.

extension J { var isNull: Bool { v.isNull } }

@Suite struct PrimaryCertRequestVectorTests {
    struct Rig {
        let h: PairHarness
        let ws: ID16
        let phone: DemoKeys
        var primary: FakePrimary { h.primary }
        var host: FakeHost { h.host }
        var card: VerifiedCard
        let clock: TestClock

        static func make(clientHosted: Bool = false) async throws -> Rig {
            let h = try await PairHarness.make(.firstTime, clientHosted: clientHosted, hostedBy: clientHosted ? "Example Client" : nil)
            let card = try Card.verify(try await h.host.card(), ownerKey: h.primary.publicKey)
            return Rig(h: h, ws: h.host.workspace, phone: DemoKeys(sig: SoftwareSigner().publicKey, kx: SoftwareKeyAgreer().publicKey), card: card, clock: h.clock)
        }

        func request(id: ID16 = .random(), wsk: SoftwareSigner? = nil, primaryDevice: ID16? = nil, scopes: [String] = ["look", "decide", "operate", "type"],
                     keys: DemoKeys? = nil, createdMs: Int64? = nil) async throws -> JSONValue {
            let k = keys ?? phone
            let inner = CertRequestInner(deviceID: k.deviceID, dkSig: k.sig, dkKx: k.kx, label: "Severin's iPhone", scopesMax: scopes, offerID: .random())
            let signer = wsk ?? host.wsk
            return try CertRequest.make(wsk: signer, requestID: id, workspace: ws, person: primary.personID, primary: primaryDevice ?? primary.deviceID,
                                        primaryKey: primary.deviceKeys.kx, inner: inner, createdMs: createdMs ?? clock.nowMs).json
        }
    }

    @Test func testPrimaryCertRequestVectors() async throws {
        let vec = J(try StrictJSON.parse(OrchTestVectors.Vectors.data, maxBytes: .max))["suites"]["2"]["cert_request"]
        let cases = vec["cases"].items
        #expect(cases.count == 10)
        var ok = 0
        for c in cases {
            let name = c["name"].str
            let want = c["steps"].items.map { $0["expect"] }
            var got: [Result<PrimaryPrompt, Refusal>] = []
            let rig = try await Rig.make(clientHosted: name == "from_a_client_hosted_workspace_warns")
            let relay = rig.h.relay
            switch name {
            case "valid", "from_a_client_hosted_workspace_warns":
                got.append(await rig.primary.open(request: try await rig.request(), card: rig.card, relay: relay))
            case "expired":
                let r = try await rig.request(createdMs: rig.clock.nowMs - CertRequest.lifetimeMs)        // now == expires
                got.append(await rig.primary.open(request: r, card: rig.card, relay: relay))
            case "signed_by_another_workspace":
                got.append(await rig.primary.open(request: try await rig.request(wsk: SoftwareSigner()), card: rig.card, relay: relay))
            case "not_for_this_device":
                got.append(await rig.primary.open(request: try await rig.request(primaryDevice: .random()), card: rig.card, relay: relay))
            case "card_of_another_person":
                // a workspace that belongs to someone else: the primary refuses before anything else
                let other = try await PairHarness.make(.firstTime)
                let card = try Card.verify(try await other.host.card(), ownerKey: other.primary.publicKey)
                got.append(await rig.primary.open(request: try await rig.request(), card: card, relay: relay))
            case "drop_scope_refused":
                let drop = "drop:" + ID16.random().hex
                got.append(await rig.primary.open(request: try await rig.request(scopes: [drop]), card: rig.card, relay: relay))
            case "replayed_request_id":
                let r = try await rig.request()
                got.append(await rig.primary.open(request: r, card: rig.card, relay: relay))
                rig.clock.advance(milliseconds: 5)
                got.append(await rig.primary.open(request: r, card: rig.card, relay: relay))
            case "second_open_request_for_the_workspace":
                got.append(await rig.primary.open(request: try await rig.request(), card: rig.card, relay: relay))
                rig.clock.advance(milliseconds: 5)
                got.append(await rig.primary.open(request: try await rig.request(), card: rig.card, relay: relay))
            case "inner_with_a_host_nonce_is_malformed":
                var inner = try canonicalJSONObject(from: rig, extra: ["host_nonce": "AAAA"])
                inner["offer_id"] = .string(ID16.random().hex)
                got.append(await rig.primary.open(request: try await rig.requestWithRawInner(inner), card: rig.card, relay: relay))
            default: Issue.record("unmapped case \(name)")
            }
            #expect(got.count == want.count, "\(name)")
            for (g, w) in zip(got, want) {
                switch g {
                case .success(let p):
                    ok += 1
                    #expect(!w["ok"].isNull, "\(name) accepted")
                    #expect(p.deviceID == rig.phone.deviceID && p.deviceLabel == w["ok"]["label"].str && p.scopesAsked == w["ok"]["scopes_max"].items.map(\.str), "\(name)")
                    #expect(p.clientHostedWarning == (w["warning"].str == "client_hosted"), "\(name)")
                case .failure(let r): #expect(r.rawValue == w["refuse"].str, "\(name)")
                }
            }
            // a refused request is open nowhere: no challenge was posted for it
            if want.allSatisfy({ !$0["refuse"].isNull }) { #expect(await relay.certRequestQueueSize() == 0, "\(name)") }
        }
        #expect(ok == 4)         // valid, client hosted, replayed (first), second_open (first)
    }

    @Test func testPrimaryOpenCases() async throws {
        let vec = J(try StrictJSON.parse(OrchTestVectors.Vectors.data, maxBytes: .max))["suites"]["2"]["cert_request"]
        let cases = vec["open_cases"].items
        #expect(cases.count == 5)
        var signedCerts = 0
        for c in cases {
            let name = c["name"].str
            let rig = try await Rig.make()
            let relay = rig.h.relay
            var current: PrimaryPrompt?
            for st in c["steps"].items {
                switch st["op"].str {
                case "open":
                    if name == "next_request_after_the_first_expired", st["now_ms"].i64 == 1_790_000_600_000 { rig.clock.advance(milliseconds: CertRequest.lifetimeMs) }
                    let r = await rig.primary.open(request: try await rig.request(), card: rig.card, relay: relay)
                    guard case .success(let p) = r else { Issue.record("\(name): open refused \(r)"); continue }
                    current = p
                case "reject":
                    try await rig.primary.reject(request: current!.requestID, relay: relay)
                case "challenge": break                                         // FakePrimary draws and posts its challenge on open
                case "sign":
                    if name == "sign_after_expiry_refused" { rig.clock.advance(milliseconds: CertRequest.lifetimeMs) }
                    do {
                        let cert = try await rig.primary.approve(request: current!.requestID, confirmedComparison: true, relay: relay)
                        signedCerts += 1
                        #expect(!st["expect"]["ok"].isNull, "\(name)")
                        _ = try DeviceCertificate.verify(cert, personKey: rig.primary.publicKey, nowMs: rig.clock.nowMs)
                    } catch {
                        #expect(st["expect"]["refuse"].str != "", "\(name)")
                        // after a rejection the prompt is gone (unknown request); after expiry the ledger refuses `expired`
                        if name == "sign_after_expiry_refused" { #expect("\(error)".contains("expired"), "\(name): \(error)") }
                        else { #expect(error as? PrimaryError == .unknownRequest, "\(name): \(error)") }
                    }
                default: Issue.record("unknown op")
                }
            }
            if name == "sign_after_reject_refused" { let l = await rig.primary.ledgerSnapshot(); #expect(l.signed.isEmpty && !l.rejected.isEmpty) }
        }
        #expect(signedCerts == 1)
    }

    @Test func testChallengeCodeAndSignedCertificate() async throws {
        let rig = try await Rig.make()
        let relay = rig.h.relay
        guard case .success(let p) = await rig.primary.open(request: try await rig.request(), card: rig.card, relay: relay) else { Issue.record("open"); return }
        // the code is over the primary's own challenge, which names exactly the phone's keys and a nonce drawn after them
        let session = try await rig.host.openSession(transport: rig.h.env.transport)
        let ch = try #require(try await relay.certChallenge(workspace: rig.ws, requestID: p.requestID, token: session.token))
        let checked = try CertChallenge.check(ch, pk: rig.primary.publicKey, workspace: rig.ws, device: rig.phone.deviceID, dkSig: rig.phone.sig, dkKx: rig.phone.kx, nowMs: rig.clock.nowMs)
        #expect(checked.certCode == p.certCode)
        // approval needs the explicit confirmation
        await #expect(throws: PrimaryError.comparisonNotConfirmed) { _ = try await rig.primary.approve(request: p.requestID, confirmedComparison: false, relay: relay) }
        // narrowing is allowed, widening is not
        await #expect(throws: Refusal.scopeExceeded) { _ = try await rig.primary.approve(request: p.requestID, scopesMax: ["look", "decide", "operate", "type", "x"], confirmedComparison: true, relay: relay) }
        let cert = try await rig.primary.approve(request: p.requestID, scopesMax: ["look"], confirmedComparison: true, relay: relay)
        let dc = try DeviceCertificate.verify(cert, personKey: rig.primary.publicKey, nowMs: rig.clock.nowMs)
        #expect(dc.signingKey == rig.phone.sig && dc.agreementKey == rig.phone.kx && dc.scopesMax == ["look"])
        // once per request
        await #expect(throws: PrimaryError.unknownRequest) { _ = try await rig.primary.approve(request: p.requestID, confirmedComparison: true, relay: relay) }
        #expect(await rig.primary.ledgerSnapshot().signed == [p.requestID])
    }

    func canonicalJSONObject(from rig: Rig, extra: [String: JSONValue]) throws -> [String: JSONValue] {
        var o: [String: JSONValue] = ["device_id": .string(rig.phone.deviceID.hex), "dk_sig_pub": .string(B64U.encode(rig.phone.sig.x963)),
                                      "dk_kx_pub": .string(B64U.encode(rig.phone.kx.x963)), "label": "Severin's iPhone",
                                      "scopes_max": ["look", "decide", "operate", "type"], "offer_id": .string(ID16.random().hex)]
        for (k, v) in extra { o[k] = v }
        return o
    }
}

extension PrimaryCertRequestVectorTests.Rig {
    /// A request whose sealed inner is exactly these bytes (the host nonce case: no honest code produces it).
    func requestWithRawInner(_ inner: [String: JSONValue]) async throws -> JSONValue {
        let rid = ID16.random()
        let sealed = try Sealing.seal(to: primary.deviceKeys.kx, recipientID: primary.deviceID, purpose: .certRequest, object: rid, epoch: 0,
                                      plaintext: canonicalJSON(.object(inner)))
        return try SignedObject.sign([
            "v": 2, "suite": 2, "kind": "cert_request", "request_id": .string(rid.hex), "workspace_id": .string(ws.hex),
            "person_id": .string(primary.personID.hex), "primary_device_id": .string(primary.deviceID.hex), "created_ms": .int(clock.nowMs),
            "expires_ms": .int(clock.nowMs + CertRequest.lifetimeMs), "sealed": .string(B64U.encode(sealed))], kind: .certRequest, signer: host.wsk).json
    }
}
