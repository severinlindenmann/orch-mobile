import Foundation
import Testing
import OrchClient
import OrchCustody
import OrchFakeHost
import OrchProtocol
import OrchTestVectors
@testable import OrchProtocol

@Suite struct RelayAuthTests {
    var vec: J { J(try! StrictJSON.parse(OrchTestVectors.Vectors.data, maxBytes: .max))["suites"]["2"]["relay_auth"] }

    /// A person that is not a Demo authority, so a live-context relay accepts its certificates. Test-only.
    func person() -> (pk: SoftwareSigner, id: ID16) {
        let pk = SoftwareSigner(); return (pk, Identifiers.personID(pk.publicKey))
    }

    func cert(_ pk: SoftwareSigner, for pub: SigningPublicKey, nowMs: Int64) throws -> JSONValue {
        let pid = Identifiers.personID(pk.publicKey)
        return try SignedObject.sign([
            "v": 2, "suite": 2, "kind": "device_cert", "device_id": .string(Identifiers.deviceID(pub).hex), "person_id": .string(pid.hex),
            "dk_sig_pub": .string(B64U.encode(pub.x963)), "dk_kx_pub": .string(B64U.encode(SoftwareKeyAgreer().publicKey.x963)),
            "label_sealed": .string(B64U.encode(Data(count: 40))), "created_ms": .int(nowMs), "expires_ms": .null,
            "scopes_max": ["look"]], kind: .deviceCert, signer: pk).json
    }

    @Test func testRelayAuthVectors() async throws {
        let v = vec
        let origin = v["origin"].str, challenge = v["challenge"].hexData, id = v["id"].id
        // Leaf: the signed bytes, byte for byte, and the signature verifies under the case's key.
        #expect(try RelayAuth.signedBytes(origin: origin, challenge: challenge, kind: .device, id: id) == v["signed_bytes"].hexData)
        let cases = v["cases"].items
        #expect(cases.count == 6)
        for c in cases {
            // Each case runs through FakeRelay's HTTP routes: the relay issues the challenge (pinned via entropy), the client posts the
            // vector's own signature, and the status and error code are the vector's.
            let pub = c["steps"].items[0]["pub"].sigPub
            #expect(Identifiers.deviceID(pub) == id)
            let clock = TestClock(wallStartMs: 1_790_000_000_000)
            let entropy = QueuedEntropy([challenge])
            let ctx = try RealmContext.live(origin: origin)
            let relay = FakeRelay(context: ctx, clock: clock, wall: clock, entropy: entropy)
            let p = person()
            await relay.registerOwner(p.pk.publicKey)
            try await relay.publishCertificate(try cert(p.pk, for: pub, nowMs: clock.nowMs))
            let sender = Sender(relay: relay, ctx: ctx)
            let issued = try HostAPI.challenge(try HostAPI.expect(try await sender.t.challenge()))
            #expect(issued.challenge == challenge)
            #expect(issued.expiresMs == c["state"]["challenges"][v["challenge"].str].int ?? 1_790_000_060_000)
            for step in c["steps"].items {
                clock.advance(milliseconds: step["now_ms"].i64 - clock.nowMs)
                var body: [String: JSONValue] = ["challenge": .string(B64U.encode(challenge)), "kind": .string(step["kind"].str),
                                                 "id": .string(step["id"].str), "sig": .string(B64U.encode(step["sig"].hexData))]
                body["host_api"] = 0
                let reply = try await sender.t.login(try canonicalJSON(.object(body)))
                #expect(reply.status == step["expect"]["status"].i64.asInt, "\(c["name"].str)")
                if let e = step["expect"]["error"].string {
                    #expect(errorCode(reply) == e, "\(c["name"].str)")
                    #expect(try json(reply)["host_api"] == nil)      // a section 14 refusal never carries host_api
                } else {
                    let l = try HostAPI.login(reply.body)
                    #expect(l.expiresMs == step["now_ms"].i64 + 15 * 60_000)
                }
            }
        }
    }

    final class Sender { let t: RoutedRelayTransport<FakeRelay>
        init(relay: FakeRelay, ctx: RealmContext) { t = try! RoutedRelayTransport(context: ctx, origin: ctx.origin, sender: relay, clientAddress: "198.51.100.9") } }

    @Test func challengeIsSingleUseExpiresAtSixtySecondsAndSessionAtFifteenMinutes() async throws {
        let w = try await World.make()
        let c = RelayClient(transport: w.transport)
        // 60 s challenge: signing too late fails with `expired`, and the challenge is gone either way.
        let ch = try HostAPI.challenge(try HostAPI.expect(try await w.transport.challenge()))
        #expect(ch.expiresMs == w.clock.nowMs + 60_000)
        let sig = try RelayAuth.sign(w.env.device.sig, origin: w.env.context.origin, challenge: ch.challenge, kind: .device, id: w.phoneID)
        w.clock.advance(milliseconds: 60_000)
        let late = try await w.transport.login(HostAPI.loginBody(challenge: ch.challenge, kind: .device, id: w.phoneID, signature: sig))
        #expect(late.status == 401 && errorCode(late) == "expired")
        let again = try await w.transport.login(HostAPI.loginBody(challenge: ch.challenge, kind: .device, id: w.phoneID, signature: sig))
        #expect(errorCode(again) == "unknown_challenge")
        // 15 min session: usable until expiry, then 401 unauthenticated (adapter error, with host_api).
        let opened = try await c.openDeviceSession(identity: w.env.device, deviceID: w.phoneID, origin: w.env.context.origin)
        #expect(opened.expiresMs == w.clock.nowMs + 15 * 60_000)
        _ = try await c.card(workspace: w.ws, session: opened.session)
        w.clock.advance(milliseconds: 15 * 60_000 - 1)
        _ = try await c.card(workspace: w.ws, session: opened.session)
        w.clock.advance(milliseconds: 1)
        await #expect(throws: ClientError.adapter(.unauthenticated)) { _ = try await c.card(workspace: w.ws, session: opened.session) }
    }

    @Test func loginSignsTheRelaysOwnOriginAndKnownIdentitiesOnly() async throws {
        let w = try await World.make()
        // The relay builds the signed bytes with its own origin: a client that signs a different one is refused.
        let ch = try HostAPI.challenge(try HostAPI.expect(try await w.transport.challenge()))
        let wrong = try RelayAuth.sign(w.env.device.sig, origin: "https://relay.example.org", challenge: ch.challenge, kind: .device, id: w.phoneID)
        let r = try await w.transport.login(HostAPI.loginBody(challenge: ch.challenge, kind: .device, id: w.phoneID, signature: wrong))
        #expect(r.status == 401 && errorCode(r) == "bad_signature")
        // An id with no certificate gets the same answer as a wrong signature (no oracle) and still uses up the challenge.
        let ch2 = try HostAPI.challenge(try HostAPI.expect(try await w.transport.challenge()))
        let stranger = SoftwareSigner(); let sid = Identifiers.deviceID(stranger.publicKey)
        let sig = try RelayAuth.sign(stranger, origin: w.env.context.origin, challenge: ch2.challenge, kind: .device, id: sid)
        let r2 = try await w.transport.login(HostAPI.loginBody(challenge: ch2.challenge, kind: .device, id: sid, signature: sig))
        #expect(r2.status == 401 && errorCode(r2) == "bad_signature")
        let r3 = try await w.transport.login(HostAPI.loginBody(challenge: ch2.challenge, kind: .device, id: sid, signature: sig))
        #expect(errorCode(r3) == "unknown_challenge")
        // A device signature presented as a workspace login, and the reverse, never verifies.
        let ch3 = try HostAPI.challenge(try HostAPI.expect(try await w.transport.challenge()))
        let asDevice = try RelayAuth.sign(w.env.device.sig, origin: w.env.context.origin, challenge: ch3.challenge, kind: .device, id: w.phoneID)
        let r4 = try await w.transport.login(HostAPI.loginBody(challenge: ch3.challenge, kind: .workspace, id: w.phoneID, signature: asDevice))
        #expect(r4.status == 401)
        // Malformed bodies still consume a valid challenge.
        let ch4 = try HostAPI.challenge(try HostAPI.expect(try await w.transport.challenge()))
        let junk = try canonicalJSON(["host_api": 0, "challenge": .string(B64U.encode(ch4.challenge)), "kind": "device", "id": "nothex", "sig": "x"])
        #expect(try await w.transport.login(junk).status == 400)
        let r5 = try await w.transport.login(HostAPI.loginBody(challenge: ch4.challenge, kind: .device, id: w.phoneID, signature: asDevice))
        #expect(errorCode(r5) == "unknown_challenge")
        // The workspace host logs in with WSK and gets a workspace session.
        #expect(!w.hostSession.token.isEmpty)
    }

    @Test func revokedDeviceKeepsASessionButNoMembership() async throws {
        let w = try await World.make()
        let rec = try await w.primary.revoke(device: w.phoneID)
        try await w.relay.publishRevocation(rec)
        let c = RelayClient(transport: w.transport)
        // Login still works (the device may fetch its own record); every membership route says revoked, which is unsigned.
        let s = try await c.openDeviceSession(identity: w.env.device, deviceID: w.phoneID, origin: w.env.context.origin).session
        await #expect(throws: ClientError.relay(RelayRefusal(status: 403, code: .revoked))) { _ = try await c.card(workspace: w.ws, session: s) }
        let fetched = try await c.revocation(device: w.phoneID, session: s)
        let p = try Revocation.verify(fetched, personKey: w.primary.publicKey, cert: DeviceCertificate.verify(w.phoneCert, personKey: w.primary.publicKey, nowMs: w.clock.nowMs).identity)
        #expect(p.deviceID == w.phoneID)
        // Only its own record, and never with another device's session.
        await #expect(throws: ClientError.relay(RelayRefusal(status: 403, code: .notForThisDevice))) { _ = try await c.revocation(device: w.primaryID, session: s) }
        // No record, no 404 oracle beyond the device's own id.
        let w2 = try await World.make()
        await #expect(throws: ClientError.adapter(.notFound)) { _ = try await RelayClient(transport: w2.transport).revocation(device: w2.phoneID, session: w2.phoneSession) }
    }
}

extension Int64 { var asInt: Int { Int(self) } }
