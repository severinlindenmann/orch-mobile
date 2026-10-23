import Foundation

/// The APNs environment a registration names (`env` of protocol 19.10). It follows the build's signing, never the build configuration.
public enum PushEnvironment: String, Sendable, Equatable, Codable {
    case sandbox, production

    /// Resolves the environment from the app's provisioning profile (`embedded.mobileprovision`, a CMS blob around an XML plist whose
    /// `Entitlements` carry `aps-environment`): `development` is `sandbox`, `production` is `production`.
    /// - A profile with an unknown or missing `aps-environment` has no push entitlement: nil (no registration).
    /// - No profile on a device is a TestFlight or App Store build, whose APNs tokens are production tokens.
    /// - The Simulator never registers (nil).
    public static func resolve(provisioningProfile: Data?, isSimulator: Bool) -> PushEnvironment? {
        resolve(profile: provisioningProfile.map { .data($0) } ?? .absent, isSimulator: isSimulator)
    }

    /// What the app found where the provisioning profile belongs.
    public enum ProfileSource: Sendable, Equatable {
        /// No profile file: a TestFlight or App Store build.
        case absent
        /// A profile file exists but could not be read: unknown, so no registration (never "production by default").
        case unreadable
        case data(Data)
    }

    public static func resolve(profile source: ProfileSource, isSimulator: Bool) -> PushEnvironment? {
        if isSimulator { return nil }
        let profile: Data
        switch source {
        case .absent: return .production
        case .unreadable: return nil
        case .data(let d): profile = d
        }
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

/// The APNs topic (the app's bundle id). Registration itself goes through the hub (`HubPush`).
public enum PushService {
    public static let topic = "io.severin.orch"
}
