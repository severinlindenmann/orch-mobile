import Foundation
import OrchCustody
import OrchProtocol

/// Typed calls over any `RelayTransport`: login (section 12.2) and the verified-later fetches. It decodes the adapter
/// wrappers strictly and maps failures; it verifies no signature (that is the coordinator's job) and holds no keys.
public struct RelayClient: Sendable {
    public let transport: any RelayTransport
    public init(transport: any RelayTransport) { self.transport = transport }

    public struct Opened: Equatable, Sendable { public let session: RelaySession; public let expiresMs: Int64 }

    /// challenge, sign with the device's `dk_sig`, login. The signed origin is the one the relay reports being; the
    /// client signs the origin of its own reviewed context, never one the relay names.
    public func openDeviceSession(identity: DeviceIdentity, deviceID: ID16, origin: String) async throws -> Opened {
        try await openSession(kind: .device, id: deviceID, signer: identity.sig, origin: origin)
    }

    package func openSession(kind: RelayAuth.Kind, id: ID16, signer: some Signer, origin: String) async throws -> Opened {
        let ch = try HostAPI.challenge(try HostAPI.expect(try await transport.challenge()))
        let sig = try RelayAuth.sign(signer, origin: origin, challenge: ch.challenge, kind: kind, id: id)
        let reply = try await transport.login(HostAPI.loginBody(challenge: ch.challenge, kind: kind, id: id, signature: sig))
        let l = try HostAPI.login(try HostAPI.expect(reply))
        return Opened(session: l.session, expiresMs: l.expiresMs)
    }

    public func grants(workspace: ID16, epoch: UInt32? = nil, session: RelaySession) async throws -> [JSONValue] {
        try HostAPI.grants(try HostAPI.expect(try await transport.grants(workspaceID: workspace, epoch: epoch, session: session)))
    }

    public func memberList(workspace: ID16, session: RelaySession) async throws -> JSONValue {
        try HostAPI.memberList(try HostAPI.expect(try await transport.memberList(workspaceID: workspace, session: session)))
    }

    public func card(workspace: ID16, session: RelaySession) async throws -> JSONValue {
        try HostAPI.card(try HostAPI.expect(try await transport.card(workspaceID: workspace, session: session)))
    }

    public func cardKey(workspace: ID16, cardSequence: UInt32, session: RelaySession) async throws -> HostAPI.CardKey {
        try HostAPI.cardKey(try HostAPI.expect(try await transport.cardKey(workspaceID: workspace, cardSequence: cardSequence, session: session)))
    }

    public func revocation(device: ID16, session: RelaySession) async throws -> JSONValue {
        try HostAPI.revocation(try HostAPI.expect(try await transport.revocation(deviceID: device, session: session)))
    }
}
