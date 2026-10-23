import Foundation
import LocalAuthentication

// Face ID before each proof (design B3, decision R2). V3 has no hardware per-use biometry on the channel key, so the app asks for it itself:
// `LAContext` with `.deviceOwnerAuthenticationWithBiometrics` ONLY (no passcode fallback), and a changed `evaluatedPolicyDomainState` since
// pairing (a face or finger was added or removed) means "sign in again": the channel session is dropped and nobody signs until the person
// has signed in with the password and a code. The release design is a hardware-bound second SE key (`.biometryCurrentSet`), which will mean
// re-pairing.

/// The part of `LAContext` the gate uses, so a test can stand in for it and record which policy was asked for.
public protocol BiometricContext: AnyObject {
    var localizedFallbackTitle: String? { get set }
    var evaluatedPolicyDomainState: Data? { get }
    func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool
    func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws -> Bool
}

extension LAContext: BiometricContext {}

public enum BiometryFailure: Error, Equatable, Sendable {
    /// No Face ID / Touch ID on this device, or it is switched off for the app.
    case unavailable
    case notEnrolled
    case lockedOut
    /// The person cancelled (or the app went to the background). Nothing was signed; the request is still live.
    case cancelled
    /// The face did not match. Nothing was signed; the request is still live.
    case failed
    /// The set of enrolled faces or fingers is not the one at pairing, or none was recorded: sign in again.
    case changed
}

public struct BiometricGate: Sendable {
    /// The one policy this gate ever asks for: biometry only, never the device passcode.
    public static let policy: LAPolicy = .deviceOwnerAuthenticationWithBiometrics

    let makeContext: @Sendable () -> any BiometricContext

    public init(makeContext: @escaping @Sendable () -> any BiometricContext = { LAContext() }) { self.makeContext = makeContext }

    /// The current `evaluatedPolicyDomainState` (what the pairing records as the baseline), or nil when biometry is not usable.
    public func currentDomainState() -> Data? {
        let c = makeContext()
        c.localizedFallbackTitle = ""
        var err: NSError?
        guard c.canEvaluatePolicy(Self.policy, error: &err) else { return nil }
        return c.evaluatedPolicyDomainState
    }

    /// Face ID for one proof. `baseline` is the domain state recorded at pairing: anything else (including none) is `changed`.
    public func authenticate(reason: String, baseline: Data?) async throws {
        let c = makeContext()
        c.localizedFallbackTitle = ""   // no "Enter password" button: the policy has no passcode fallback anyway
        var err: NSError?
        guard c.canEvaluatePolicy(Self.policy, error: &err) else { throw Self.map(err) }
        guard let baseline, let now = c.evaluatedPolicyDomainState, now == baseline else { throw BiometryFailure.changed }
        do {
            guard try await c.evaluatePolicy(Self.policy, localizedReason: reason) else { throw BiometryFailure.failed }
        } catch let f as BiometryFailure { throw f } catch { throw Self.map(error as NSError) }
        // the set of faces cannot have changed during the prompt, but the state is read again: the proof follows only a match on the
        // very state that was recorded
        guard c.evaluatedPolicyDomainState == baseline else { throw BiometryFailure.changed }
    }

    static func map(_ e: NSError?) -> BiometryFailure {
        guard let e, e.domain == LAError.errorDomain, let code = LAError.Code(rawValue: e.code) else { return .unavailable }
        switch code {
        case .biometryNotEnrolled: return .notEnrolled
        case .biometryLockout: return .lockedOut
        case .userCancel, .appCancel, .systemCancel: return .cancelled
        case .authenticationFailed: return .failed
        default: return .unavailable
        }
    }
}
