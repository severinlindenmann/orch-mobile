import Foundation
import OrchCustody
import OrchProtocol

/// Typed calls over any `RelayTransport`: login (section 12.2) and the verified-later fetches. It decodes the adapter
/// wrappers strictly and maps failures; it verifies no signature (that is the coordinator's job) and holds no keys.
public struct RelayClient: Sendable {
    public let transport: any RelayTransport
    public init(transport: any RelayTransport) { self.transport = transport }

    /// A session and its expiry. The bearer is redacted from every textual rendering.
    public struct Opened: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        public let session: RelaySession
        public let expiresMs: Int64
        public var description: String { "Opened(session: <redacted>, expiresMs: \(expiresMs))" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["expiresMs": expiresMs], displayStyle: .struct) }
    }

    /// challenge, sign with the device's `dk_sig`, login. The login is bound to this transport: the signed origin is
    /// `transport.context.origin` (never a caller-supplied or relay-named one), and the identity must carry the transport's
    /// realm. Both are checked before the first request, so a Demo key cannot sign a live origin and a live key cannot sign
    /// for Demo through any transport, including one that merely forwards to another.
    public func openDeviceSession(identity: DeviceIdentity, deviceID: ID16) async throws -> Opened {
        try transport.context.admit(identity: identity)
        guard Identifiers.deviceID(identity.sig.publicKey) == deviceID else { throw TransportError.invalidArgument }
        return try await openSession(kind: .device, id: deviceID, signer: identity.sig)
    }

    package func openSession(kind: RelayAuth.Kind, id: ID16, signer: some Signer) async throws -> Opened {
        let context = transport.context
        do { try context.generation?.check(); try context.admit(origin: context.origin) }
        catch let v as RealmViolation { throw TransportError.realm(v) }
        let ch = try HostAPI.challenge(try HostAPI.expect(try await transport.challenge()))
        let sig = try RelayAuth.sign(signer, origin: context.origin, challenge: ch.challenge, kind: kind, id: id)
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

    /// The device's PK-signed revocation record, fetched without a session (a revoked device has none; the record is public).
    public func revocation(device: ID16) async throws -> JSONValue {
        try HostAPI.revocation(try HostAPI.expect(try await transport.revocation(deviceID: device)))
    }
}
