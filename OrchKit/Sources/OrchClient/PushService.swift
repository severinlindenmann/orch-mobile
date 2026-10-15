import Foundation
import OrchCustody
import OrchProtocol
import OrchStore

/// The APNs environment a registration names (`env` of protocol 19.10). It follows the build's signing, never the build configuration.
public enum PushEnvironment: String, Sendable, Equatable {
    case sandbox, production

    /// Resolves the environment from the app's provisioning profile (`embedded.mobileprovision`, a CMS blob around an XML plist whose
    /// `Entitlements` carry `aps-environment`): `development` is `sandbox`, `production` is `production`.
    /// - A profile with an unknown or missing `aps-environment` has no push entitlement: nil (no registration).
    /// - No profile on a device is a TestFlight or App Store build, whose APNs tokens are production tokens.
    /// - The Simulator never registers (nil).
    public static func resolve(provisioningProfile: Data?, isSimulator: Bool) -> PushEnvironment? {
        if isSimulator { return nil }
        guard let profile = provisioningProfile else { return .production }
        guard let plist = embeddedPlist(profile),
              let root = (try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil)) as? [String: Any],
              let entitlements = root["Entitlements"] as? [String: Any], let aps = entitlements["aps-environment"] as? String else { return nil }
        switch aps {
        case "development": return .sandbox
        case "production": return .production
        default: return nil
        }
    }

    /// The XML plist inside the CMS envelope (found by its markers; the envelope's signature is not checked: the OS already verified the
    /// profile when it installed the app, and the value only picks which APNs host the relay uses).
    static func embeddedPlist(_ data: Data) -> Data? {
        guard let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        return data.subdata(in: start.lowerBound..<end.upperBound)
    }
}

/// What a register or unregister attempt came to. Nothing here is a crash and nothing is retried in a tight loop.
public enum PushRegistrationOutcome: Equatable, Sendable {
    /// 200: the relay holds exactly this registration.
    case registered(ID16)
    /// 200 on an unregister (also when nothing was registered).
    case removed
    /// 404 `not_found`: push is not configured on this relay. The caller stops asking until the next launch.
    case pushOff
    /// 403 `not_eligible` (not a member, or a `drop:` device) or `revoked`: asking again changes nothing.
    case refused(String)
    /// 429: the caller waits (`retryAfter` seconds when the relay said so) and does not retry this launch.
    case rateLimited(retryAfter: Int?)
    /// The relay could not be reached or answered something unusable. Retryable on the next launch or foreground.
    case failed(String)
}

/// Registers this device's APNs token with the relay for ONE workspace (P3-D40, protocol 19.10) and hands the App the notification
/// extension's key material. Holds no key: the session signs the login, `K_push` is derived inside it.
///
/// One registration per (device, workspace, env, topic). The registration id is 16 random bytes persisted in the workspace store BEFORE the
/// request, so a lost reply retries the same body (the relay answers 200 for the same id and body, free). A changed token needs a new id
/// (the same id with another body is 409 `registration_conflict`); a new id retires the old one at the relay.
public struct PushService: Sendable {
    public static let topic = "io.severin.orch"
    let session: WorkspaceSession
    public init(session: WorkspaceSession) { self.session = session }

    public var workspace: ID16 { session.workspace }

    /// The notification extension's material for this workspace (see `WorkspaceSession.pushKeyMaterial`): pinned `WSK` x963 and
    /// `K_push(e)` per epoch.
    public func keyMaterial(maxEpochs: Int = 8) async throws -> (wsk: SigningPublicKey, kPush: [UInt32: Data]) {
        try await session.pushKeyMaterial(maxEpochs: maxEpochs)
    }

    /// Registers (or refreshes) `token` for this workspace. Safe to call at every launch.
    public func register(token: String, env: PushEnvironment) async -> PushRegistrationOutcome {
        let container = await session.pushContainer
        let ws = session.workspace
        let client = RelayClient(transport: await session.pushTransport)
        do {
            var row = try await container.pushRegistration(env: env.rawValue)
            var id: ID16
            if let row, row.token == token, let existing = ID16(hex: row.registrationID) { id = existing }
            else { id = await session.pushEntropy().id16(); try await container.savePushRegistration(env: env.rawValue, registrationID: id.hex, token: token); row = nil }
            for attempt in 0..<2 {
                do {
                    let chosen = id
                    try await session.pushRelay { s in
                        try await client.registerPush(workspace: ws, registrationID: chosen, env: env.rawValue, topic: Self.topic, token: token, session: s)
                    }
                    try await container.confirmPushRegistration(env: env.rawValue, registrationID: id.hex, nowMs: await session.pushWallMs())
                    return .registered(id)
                } catch ClientError.relay(let r) where r.code == .registrationConflict && attempt == 0 {
                    // The relay holds this id with another body (or it is another device's): mint a new one and register once more.
                    id = await session.pushEntropy().id16()
                    try await container.savePushRegistration(env: env.rawValue, registrationID: id.hex, token: token)
                }
            }
            return .failed("registration_conflict")
        } catch { return Self.outcome(of: error) }
    }

    /// Removes every registration this device holds in this workspace (`registration_id: null`; works after the host removed the device).
    /// 404 (push off) counts as done: there is nothing to remove. The local record goes only after the relay answered.
    public func unregisterAll() async -> PushRegistrationOutcome {
        let ws = session.workspace
        let client = RelayClient(transport: await session.pushTransport)
        let container = await session.pushContainer
        do {
            try await session.pushRelay { s in try await client.unregisterPush(workspace: ws, registrationID: nil, session: s) }
            try? await container.clearPushRegistrations()
            return .removed
        } catch { return Self.outcome(of: error) }
    }

    static func outcome(of error: any Error) -> PushRegistrationOutcome {
        if case ClientError.relay(let r) = error {
            switch r.code {
            case .notFound: return .pushOff
            case .notEligible, .revoked, .notForThisDevice: return .refused(r.code.rawValue)
            case .rateLimited, .quotaExceeded: return .rateLimited(retryAfter: r.retryAfter)
            default: return .failed(r.code.rawValue)
            }
        }
        return .failed("\(error)")
    }

    /// Unregisters `workspace` with a device session of its own, without a `WorkspaceSession`: for the cleanup that outlives a Leave, while
    /// the realm's device key still exists. `null` removes every registration of this device in the workspace.
    public static func unregisterAll(workspace: ID16, identity: DeviceIdentity, transport: any RelayTransport) async -> PushRegistrationOutcome {
        let client = RelayClient(transport: transport)
        do {
            let opened = try await client.openDeviceSession(identity: identity, deviceID: Identifiers.deviceID(identity.sig.publicKey))
            try await client.unregisterPush(workspace: workspace, registrationID: nil, session: opened.session)
            return .removed
        } catch { return outcome(of: error) }
    }
}
