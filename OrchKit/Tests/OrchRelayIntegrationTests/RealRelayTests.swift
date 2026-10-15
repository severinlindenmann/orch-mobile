import Foundation
import Testing
import OrchCustody
import OrchProtocol
@testable import OrchClient

/// The phone client's real code paths (RelayClient -> RoutedRelayTransport -> NWRequestSender) against a locally started
/// orch-relay. Skipped unless `ORCH_RELAY_INTEGRATION=1` and the relay checkout and `uv` exist (see `RealRelayHarness.swift`).
@Suite(.serialized, .enabled(if: RealRelayEnvironment.available, "set ORCH_RELAY_INTEGRATION=1 with an orch-relay checkout and uv"))
struct RealRelayTests {
    struct Rig {
        let relay: RunningRelay
        let context: RealmContext
        let sender: NWRequestSender
        let transport: RoutedRelayTransport<NWRequestSender>
        let client: RelayClient
        let identity: DeviceIdentity
        let deviceID: ID16
        let pk: SoftwareSigner
        var person: ID16 { Identifiers.personID(pk.publicKey) }

        static func start() async throws -> Rig {
            let relay = try await RunningRelay.start()
            let ctx = try RealmContext.liveLoopbackForTesting(origin: relay.origin)
            let sender = try NWRequestSender(loopbackOrigin: relay.origin)
            let transport = try RoutedRelayTransport(context: ctx, origin: ctx.origin, sender: sender, clientAddress: "127.0.0.1")
            let custody = SoftwareCustody(vault: SecretVault(group: .keys, backend: InMemoryVaultBackend()))
            let id = try ctx.deviceIdentity(custody: custody, createIfMissing: true)
            return Rig(relay: relay, context: ctx, sender: sender, transport: transport, client: RelayClient(transport: transport), identity: id,
                       deviceID: Identifiers.deviceID(id.publicKeys.sig), pk: SoftwareSigner())
        }

        func cert() throws -> JSONValue {
            let keys = identity.publicKeys
            return try SignedObject.sign([
                "v": 2, "suite": 2, "kind": "device_cert", "device_id": .string(deviceID.hex), "person_id": .string(person.hex),
                "dk_sig_pub": .string(B64U.encode(keys.sig.x963)), "dk_kx_pub": .string(B64U.encode(keys.kx.x963)),
                "label_sealed": .string(B64U.encode(Data(repeating: 1, count: 40))),
                "created_ms": .int(Int64(Date().timeIntervalSince1970 * 1000)), "expires_ms": .null, "scopes_max": ["look"]],
                kind: .deviceCert, signer: pk).json
        }

        func createAccount() async throws -> ID16 {
            try await client.createAccount(invite: try await relay.createInvite(), pkPub: pk.publicKey, deviceCert: try cert(), identity: identity)
        }

        func refusal<T>(_ body: () async throws -> T) async -> RelayRefusal? {
            do { _ = try await body(); return nil } catch ClientError.relay(let r) { return r } catch { return nil }
        }
    }

    @Test func accountSessionLoginAndLogout() async throws {
        let rig = try await Rig.start(); defer { rig.relay.stop() }
        // challenge shape, straight through the sender
        let ch = try HostAPI.challenge(try HostAPI.expect(try await rig.transport.challenge()))
        #expect(ch.challenge.count == 32)
        // no account yet: the device is unknown, the answer is the typed bad_signature
        let before = await rig.refusal { try await rig.client.openDeviceSession(identity: rig.identity, deviceID: rig.deviceID) }
        #expect(before?.code == .badSignature)
        // a bad invite is refused, a real one creates the account
        let noInvite = await rig.refusal { try await rig.client.createAccount(invite: "nope", pkPub: rig.pk.publicKey, deviceCert: try rig.cert(), identity: rig.identity) }
        #expect(noInvite?.code == .notEligible)
        let person = try await rig.createAccount()
        #expect(person == rig.person)
        let opened = try await rig.client.openDeviceSession(identity: rig.identity, deviceID: rig.deviceID)
        #expect(opened.expiresMs > Int64(Date().timeIntervalSince1970 * 1000))
        // the session is accepted on an authenticated route (the workspace is unknown, so a typed refusal, not 401)
        let ws = ID16.random()
        let card = await rig.refusal { try await rig.client.card(workspace: ws, session: opened.session) }
        #expect(card != nil && card?.code != .unauthenticated)
        // logout ends it: the same token is now unauthenticated
        let out = try await rig.transport.logout(session: opened.session)
        #expect(out.status == 200)
        let after = await rig.refusal { try await rig.client.card(workspace: ws, session: opened.session) }
        #expect(after?.code == .unauthenticated)
    }

    @Test func workspaceReadsWithoutAHostAreTypedRefusals() async throws {
        let rig = try await Rig.start(); defer { rig.relay.stop() }
        _ = try await rig.createAccount()
        let s = try await rig.client.openDeviceSession(identity: rig.identity, deviceID: rig.deviceID).session
        let ws = ID16.random()
        func check(_ name: String, _ call: () async throws -> Void) async {
            do { try await call(); Issue.record("\(name) unexpectedly succeeded") }
            catch ClientError.relay(let r) { #expect([403, 404].contains(r.status), "\(name): \(r)") }
            catch { Issue.record("\(name): \(error)") }
        }
        await check("card") { _ = try await rig.client.card(workspace: ws, session: s) }
        await check("members") { _ = try await rig.client.memberList(workspace: ws, session: s) }
        await check("grants") { _ = try await rig.client.grants(workspace: ws, session: s) }
        await check("card-key") { _ = try await rig.client.cardKey(workspace: ws, cardSequence: 1, session: s) }
        // a bridge poll with a long-poll `wait` is accepted by the relay's strict query parser (typed refusal, not malformed)
        let route = BridgeRoute(workspaceID: ws, requestID: ID16.random())
        let poll = try await rig.transport.bridgePoll(route: route, after: nil, wait: 1, session: s)
        let r = HostAPI.failure(of: poll)
        guard case .relay(let refusal) = r else { Issue.record("poll: \(r)"); return }
        #expect(refusal.code != .malformed)
        let bad = await rig.refusal { _ = try HostAPI.expect(try await rig.transport.bridgePoll(route: route, after: 3, wait: 0, session: s)) }
        #expect(bad?.code != .malformed)
    }

    @Test func pairingPostAndPollAreTypedRefusalsForAnUnknownWorkspace() async throws {
        let rig = try await Rig.start(); defer { rig.relay.stop() }
        let route = PairRoute(workspaceID: ID16.random(), offerID: ID16.random(), requestID: ID16.random())
        let post = try await rig.transport.pairingPost(Data(repeating: 7, count: 64), route: route)
        guard case .relay(let p) = HostAPI.failure(of: post) else { Issue.record("post: \(post.status)"); return }
        #expect([400, 401, 404].contains(p.status))
        let poll = try await rig.transport.pairingPoll(route: route, after: nil, wait: 0)
        guard case .relay(let g) = HostAPI.failure(of: poll) else { Issue.record("poll: \(poll.status)"); return }
        #expect([401, 404].contains(g.status))
    }

    @Test func revocationReadPaginatedShapeAndNotFound() async throws {
        let rig = try await Rig.start(); defer { rig.relay.stop() }
        _ = try await rig.createAccount()
        // nothing revoked yet: first page, no pair -> not_found
        let none = await rig.refusal { try await rig.client.revocation(device: rig.deviceID, person: rig.person) }
        #expect(none?.code == .notFound && none?.status == 404)
        // the owner revokes the device (POST /v2/revocations is PK-signed and sessionless)
        let record = try SignedObject.sign(["v": 2, "suite": 2, "kind": "revocation", "person_id": .string(rig.person.hex),
                                            "device_id": .string(rig.deviceID.hex), "revoked_ms": .int(Int64(Date().timeIntervalSince1970 * 1000)),
                                            "reason": "lost"], kind: .revocation, signer: rig.pk).json
        let body = try canonicalJSON(.object(["record": record]))
        let posted = try await rig.sender.send(WireRequest(method: "POST", target: "/v2/revocations", headers: ["content-type": "application/json"],
                                                           body: body, clientAddress: "127.0.0.1"))
        #expect(posted.status == 200)
        // raw page: real shape
        let raw = try await rig.transport.revocation(deviceID: rig.deviceID, after: nil, limit: 32)
        let page = try HostAPI.revocationPage(try HostAPI.expect(raw))
        #expect(page.pairs.count == 1 && page.next == nil)
        #expect(page.pairs.first?.personID == rig.person && page.pairs.first?.provenance == .registry && page.pairs.first?.reason == "lost")
        // the client picks the pinned person's pair and the record verifies under the pinned PK
        let rec = try await rig.client.revocation(device: rig.deviceID, person: rig.person)
        let verified = try Revocation.verify(rec, personKey: rig.pk.publicKey, cert: DeviceCertificate.verify(try rig.cert(), personKey: rig.pk.publicKey, nowMs: Int64(Date().timeIntervalSince1970 * 1000)).identity)
        #expect(verified.deviceID == rig.deviceID)
        // another person's pair is not ours: not_found
        let other = await rig.refusal { try await rig.client.revocation(device: rig.deviceID, person: ID16.random()) }
        #expect(other?.code == .notFound)
        // the revoked device can no longer log in
        let login = await rig.refusal { try await rig.client.openDeviceSession(identity: rig.identity, deviceID: rig.deviceID) }
        #expect(login?.code == .revoked)
    }

    @Test func aMissingRouteIsNotFoundNotBadReply() async throws {
        let rig = try await Rig.start(); defer { rig.relay.stop() }
        for target in ["/v2/no-such-route", "/v2/drop/list"] {
            let reply = try await rig.sender.send(WireRequest(method: "GET", target: target, clientAddress: "127.0.0.1"))
            #expect(reply.status == 404 || reply.status == 405)
            if reply.status == 404 { #expect(HostAPI.failure(of: reply) == .relay(RelayRefusal(status: 404, code: .notFound))) }
        }
        // the relay's own not_found keeps its meaning
        let unknown = await rig.refusal { try await rig.client.revocation(device: ID16.random(), person: ID16.random()) }
        #expect(unknown?.code == .notFound)
    }

    @Test func aRelayRedirectIsRefusedNotFollowed() async throws {
        let rig = try await Rig.start(); defer { rig.relay.stop() }
        // FastAPI answers a trailing-slash path with a 307 to the slash-less one: the sender returns it and does not follow it.
        let reply = try await rig.sender.send(WireRequest(method: "GET", target: "/healthz/", clientAddress: "127.0.0.1"))
        #expect(reply.status == 307)
        #expect(reply.header("location") != nil)
        #expect(HostAPI.failure(of: reply) == .badReply)
    }
}
