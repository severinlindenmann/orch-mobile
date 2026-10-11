import Foundation
import OrchClient
import OrchCustody
import OrchProtocol

/// The named scenarios of host-api section 6. A scenario sets how the fakes behave (who is reachable, what a compromised host asks
/// for, which key is echoed); it never decides for a human. Host approval and primary confirmation are explicit calls
/// (`FakeHost.approvePairing`, `FakePrimary.approve`) that name the compared codes, and a shipped Demo gives no scenario a way to make
/// them. `plan` says what a T0 driver will explicitly do and what outcome the phone must reach.
public enum PairingScenario: String, CaseIterable, Sendable {
    case firstTime, existingCert, hostIsPrimary, primaryOffline, linkUsed, r1Attack, echoWrongKey, otherPerson
    case rejectOnHost, rejectOnPrimary, revokeAfter

    public enum Outcome: Equatable, Sendable {
        case ready
        case rejected
        /// The primary's PK-signed rejection reached the phone and verified (`PairingState.denied`).
        case denied
        case expired(PairingExpiry)
        case alarm(PairingAlarmKind)
        case failed(PairingFailure)
    }

    public struct Plan: Equatable, Sendable {
        /// The host's human approves after comparing (an explicit input).
        public let hostApproves: Bool
        /// A second code is shown on the phone and the primary's human acts on it: `true` confirms, `false` rejects, `nil` is not asked.
        public let primaryAction: Bool?
        /// The phone shows a pairing code (SAS) before anything else.
        public let showsHostCode: Bool
        public let outcome: Outcome
    }

    public var plan: Plan {
        switch self {
        case .firstTime: Plan(hostApproves: true, primaryAction: true, showsHostCode: true, outcome: .ready)
        case .existingCert: Plan(hostApproves: true, primaryAction: nil, showsHostCode: true, outcome: .ready)
        case .hostIsPrimary: Plan(hostApproves: true, primaryAction: nil, showsHostCode: true, outcome: .ready)
        case .primaryOffline: Plan(hostApproves: true, primaryAction: nil, showsHostCode: true, outcome: .expired(.certification))
        case .linkUsed: Plan(hostApproves: false, primaryAction: nil, showsHostCode: false, outcome: .failed(.linkUsed))
        case .r1Attack: Plan(hostApproves: true, primaryAction: nil, showsHostCode: true, outcome: .alarm(.r1Challenge))
        case .echoWrongKey: Plan(hostApproves: false, primaryAction: nil, showsHostCode: false, outcome: .alarm(.echoWrongKey))
        case .otherPerson: Plan(hostApproves: false, primaryAction: nil, showsHostCode: false, outcome: .failed(.otherPerson))
        case .rejectOnHost: Plan(hostApproves: false, primaryAction: nil, showsHostCode: true, outcome: .rejected)
        case .rejectOnPrimary: Plan(hostApproves: true, primaryAction: false, showsHostCode: true, outcome: .denied)
        case .revokeAfter: Plan(hostApproves: true, primaryAction: true, showsHostCode: true, outcome: .ready)
        }
    }
}

/// A Demo workspace with a primary and a host, wired for one scenario. Built only from a `DemoEnvironment`, so it exists only in the
/// Demo realm and the in-process relay. Screens never receive it.
public actor PairingRig {
    public nonisolated let env: DemoEnvironment
    public nonisolated let primary: FakePrimary
    public nonisolated let host: FakeHost
    public nonisolated let scenario: PairingScenario
    /// Another person's authority (for `otherPerson`).
    public nonisolated let foreign: FakePrimary
    public private(set) var primaryOnline: Bool

    private init(env: DemoEnvironment, primary: FakePrimary, host: FakeHost, scenario: PairingScenario, foreign: FakePrimary) {
        self.env = env; self.primary = primary; self.host = host; self.scenario = scenario; self.foreign = foreign
        primaryOnline = scenario != .primaryOffline
    }

    /// The workspace is published with the primary's own device as its only member; the phone is not part of it.
    public static func make(env: DemoEnvironment, scenario: PairingScenario, name: String = "Laptop", clientHosted: Bool = false,
                            hostedBy: String? = nil) async throws -> PairingRig {
        let primary = DemoSetup.makeAuthority(env)
        let host = try DemoSetup.makeHost(env, primary: primary, name: name, clientHosted: clientHosted, hostedBy: hostedBy)
        let primaryCert = try await primary.certifyOwnDevice()
        _ = try await host.publishInitial(relay: env.relay, transport: env.transport,
                                          devices: [(primary.deviceKeys, primaryCert, ["look", "decide", "operate", "type"])])
        switch scenario {
        case .hostIsPrimary: try await host.setHostIsPrimary(true)
        case .r1Attack: await host.setR1Attack(true)
        case .echoWrongKey: await host.setEchoWrongKey(.signing)
        default: break
        }
        return PairingRig(env: env, primary: primary, host: host, scenario: scenario, foreign: DemoSetup.makeAuthority(env))
    }

    public func newOffer(scopes: [String] = ["look", "decide"]) async throws -> PairingOffer { try await host.createOffer(scopes: scopes) }

    public func setPrimaryOnline(_ v: Bool) { primaryOnline = v }

    /// Lets the fakes act: the host answers pairing requests and moves `cert_pending` on, and (if reachable) the primary reads its
    /// queue. It never approves or confirms anything.
    @discardableResult
    public func pump() async throws -> Int {
        let n = try await host.pumpPairing(relay: env.relay, transport: env.transport)
        if primaryOnline { await primary.processInbox(relay: env.relay) }
        return n
    }

    /// `existingCert`: this iPhone is already one of the owner's devices (it was paired with another workspace before).
    public func enrollExistingCertificate(into config: PairingConfig) async throws {
        let id = try config.context.deviceIdentity(custody: config.custody, createIfMissing: true)
        let cert = try await primary.certify(DemoKeys(id.publicKeys), label: "Demo iPhone", scopesMax: ["look", "decide", "operate"])
        try await PairingCoordinator(config).adoptCertificate(cert, owner: primary.publicKey)
    }

    /// `otherPerson`: this iPhone holds a certificate from a different person.
    public func enrollForeignCertificate(into config: PairingConfig) async throws {
        let id = try config.context.deviceIdentity(custody: config.custody, createIfMissing: true)
        let cert = try await foreign.certify(DemoKeys(id.publicKeys), label: "Demo iPhone", scopesMax: ["look"])
        try await PairingCoordinator(config).adoptCertificate(cert, owner: foreign.publicKey)
    }

    /// `revokeAfter`: the owner revokes the joined device. The relay drops its sessions, grants and card key wraps; the host removes it
    /// from the roster and rotates for the remaining members. Returns the PK-signed record (what the phone fetches and verifies).
    @discardableResult
    public func revokeAfterJoin(device: ID16) async throws -> JSONValue {
        let record = try await primary.revoke(device: device)
        try await env.relay.publishRevocation(record)
        await host.markRevoked(device)
        let remaining = (await host.rosterEntries()).filter { $0.0.deviceID != device }
        let session = try await host.currentSession(transport: env.transport)
        try await host.rotate(remaining: remaining, relay: env.relay, session: session)
        return record
    }
}
