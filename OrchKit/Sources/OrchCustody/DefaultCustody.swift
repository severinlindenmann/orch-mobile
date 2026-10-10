/// The custody backend of this build, chosen at compile time (decision A6): Secure Enclave on a device,
/// software keys in the Simulator and on macOS. There is no runtime fallback from one to the other.
public enum DefaultCustody {
    #if targetEnvironment(simulator) || os(macOS)
    public static let isSecureEnclave = false
    public static func make(vault: SecretVault, lock: SimulatedLock = SimulatedLock()) -> any DeviceKeyCustody {
        SoftwareCustody(vault: vault, lock: lock)
    }
    #else
    public static let isSecureEnclave = true
    public static func make(vault: SecretVault) -> any DeviceKeyCustody {
        SecureEnclaveCustody(vault: vault)
    }
    #endif
}
