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
            let relay = FakeRelay(testingContext: ctx, clock: clock, wall: clock, entropy: entropy)
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
        let opened = try await c.openDeviceSession(identity: w.env.device, deviceID: w.phoneID)
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

    @Test func aRevokedDeviceGetsNoSessionAndReadsItsRecordWithoutOne() async throws {
        let w = try await World.make()
        let c = RelayClient(transport: w.transport)
        // The record route is session-less; before any revocation there is nothing to find.
        await #expect(throws: ClientError.adapter(.notFound)) { _ = try await c.revocation(device: w.phoneID) }
        #expect(await w.relay.sessionCount() == 2)                // the phone's and the host's
        let rec = try await w.primary.revoke(device: w.phoneID)
        try await w.relay.publishRevocation(rec)
        // Publishing the revocation ends the device's sessions at once.
        #expect(await w.relay.sessionCount() == 1)
        await #expect(throws: ClientError.adapter(.unauthenticated)) { _ = try await c.card(workspace: w.ws, session: w.phoneSession) }
        // A fresh login for the revoked device is refused after the signature verifies: 403 revoked, no token.
        await #expect(throws: ClientError.relay(RelayRefusal(status: 403, code: .revoked))) {
            _ = try await c.openDeviceSession(identity: w.env.device, deviceID: w.phoneID)
        }
        #expect(await w.relay.sessionCount() == 1)
        // A wrong signature still looks like any other wrong signature (the revocation is not an oracle for strangers).
        let ch = try HostAPI.challenge(try HostAPI.expect(try await w.transport.challenge()))
        let wrong = try RelayAuth.sign(SoftwareSigner(), origin: w.env.context.origin, challenge: ch.challenge, kind: .device, id: w.phoneID)
        let r = try await w.transport.login(HostAPI.loginBody(challenge: ch.challenge, kind: .device, id: w.phoneID, signature: wrong))
        #expect(r.status == 401 && errorCode(r) == "bad_signature")
        // The record is fetched with no session at all, verifies with the pinned PK, and is the device's own.
        let fetched = try await c.revocation(device: w.phoneID)
        let p = try Revocation.verify(fetched, personKey: w.primary.publicKey, cert: DeviceCertificate.verify(w.phoneCert, personKey: w.primary.publicKey, nowMs: w.clock.nowMs).identity)
        #expect(p.deviceID == w.phoneID)
        // Raw: no Authorization header is needed, and a junk one is ignored rather than trusted or refused.
        for auth in [nil, "Bearer junk"] as [String?] {
            var h = ["Orch-Host-API": "0"]; if let auth { h["Authorization"] = auth }
            let raw = try await w.relay.send(WireRequest(method: "GET", target: "/mobile/host-api/0/devices/\(w.phoneID.hex)/revocation", headers: h, clientAddress: "a"))
            let keys = Set(try json(raw).keys)
            #expect(raw.status == 200 && keys == ["host_api", "record"])
        }
        // A device that was not revoked has no record: 404, for the same route.
        await #expect(throws: ClientError.adapter(.notFound)) { _ = try await c.revocation(device: w.primaryID) }
        // Revocation drops what the device held: its grants, its card-key wrap, its queued requests.
        #expect(await w.relay.grantCount(workspace: w.ws, device: w.phoneID) == 0)
        #expect(await w.relay.hasCardKeyWrap(workspace: w.ws, device: w.phoneID, cardSeq: 1) == false)
    }

    @Test func revocationDropsQueuedRequestsOfTheRevokedDevice() async throws {
        let w = try await World.make()
        let rid = ID16.fresh(0x91)
        _ = try await w.transport.bridgePost(try w.envelope(rid: rid), route: BridgeRoute(workspaceID: w.ws, requestID: rid), session: w.phoneSession)
        #expect(await w.relay.liveMailboxCount(workspace: w.ws, device: w.phoneID) == 1)
        #expect(try await w.relay.pendingRequests(workspace: w.ws, token: w.hostSession.token).count == 1)
        try await w.relay.publishRevocation(try await w.primary.revoke(device: w.phoneID))
        #expect(await w.relay.liveMailboxCount(workspace: w.ws, device: w.phoneID) == 0)
        #expect(try await w.relay.pendingRequests(workspace: w.ws, token: w.hostSession.token).isEmpty)
        let bodies = await w.relay.storedBodyCount(), boxes = await w.relay.mailboxCount()
        #expect(bodies == 0 && boxes == 0)
    }
}

extension Int64 { var asInt: Int { Int(self) } }
