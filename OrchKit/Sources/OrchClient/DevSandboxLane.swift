import Foundation
import OrchCustody
import OrchProtocol

// The Simulator dev-sandbox lane (host 11A.17, C2b increment 5): `convenience` answers from a Simulator build to a throwaway dev sandbox.
//
// Compiled ONLY under `DEBUG && targetEnvironment(simulator)`. A device build (any configuration) and a Release Simulator build contain none
// of it (`scripts/check-dev-sandbox-symbols.sh` looks for the `DevSandbox` symbols with `nm`). Even in a Debug Simulator build of the normal
// app the lane is off: it needs a `DevSandboxLaneEnabler`, which only the `OrchDevSandbox` target's App code mints (`ORCH_DEV_SANDBOX`).
// UX guard only: the host's core admission (P5, L2, L8) is the gate; a tampered client is refused there.
#if DEBUG && targetEnvironment(simulator)

/// Proof that the App is the `OrchDevSandbox` variant. Minted only by App code under `#if ORCH_DEV_SANDBOX`; SwiftPM targets cannot see the
/// app's compile flags, so the App hands it in through `WorkspaceSessionConfig`, `RestoreConfig` and `PairingConfig`. Application
/// enforcement, not cryptographic attestation.
public struct DevSandboxLaneEnabler: Sendable {
    public init() {}
}

/// The lane's fixed facts. `DevSandboxLane` is also the sentinel type the symbol check looks for.
package enum DevSandboxLane {
    /// The one dev relay origin (variant only; core production code holds no allow-list, O2).
    package static let relayOrigin = "https://relay.dev.severin.io"

    /// The variant talks to the dev relay only (owner ruling, 15 Oct: no http loopback in the app, not even in Debug; the Simulator e2e uses
    /// `https://relay.dev.severin.io`).
    package static func admitsOrigin(_ origin: String) -> Bool { origin == relayOrigin }

    /// What a screen says when the host does not offer Simulator answers (or the fresh read failed).
    package static let hostRefusesText = "This host does not accept Simulator answers"
}

/// One fresh `whoami` read that said `relay.dev.sim_convenience == true`, `ops.answer == 1` and `r6_ready == true` in the same reply.
package struct DevSandboxGrant: Sendable, Equatable {
    package let sandbox: String
    package let readAtMs: Int64
}

/// What the App shows: whether this session is on the lane, and the sandbox id (id8) of the last whoami that carried `relay.dev`.
public struct DevSandboxStatus: Sendable, Equatable {
    public let laneActive: Bool
    public let sandbox: String?
    public init(laneActive: Bool, sandbox: String?) { self.laneActive = laneActive; self.sandbox = sandbox }
}

/// The first column-R `whoami` after a join (owner note 4: never pair a Simulator into a real workspace).
public enum DevSandboxCheck: Sendable, Equatable {
    /// The host serves `relay.dev`: a dev sandbox (its id8).
    case sandbox(String)
    /// The read succeeded and carries no `relay.dev`: not a dev sandbox. The person leaves.
    case notASandbox
    /// The read failed: nothing is known yet.
    case unknown
}

extension RealmContext {
    /// A Live context for the variant, which talks to exactly one relay: the dev relay (`https`). Any other origin is refused. Needs the enabler, so only the variant's App code can ask.
    public static func liveDevSandbox(origin: String, pinnedOwner: SigningPublicKey? = nil, enabler: DevSandboxLaneEnabler) throws -> RealmContext {
        guard DevSandboxLane.admitsOrigin(origin) else { throw RealmViolation.invalidOrigin }
        return try live(origin: origin, pinnedOwner: pinnedOwner)
    }
}

extension LiveTransport {
    /// The Live transport for a variant context: as `make` (`https` only).
    public static func makeDevSandbox(context: RealmContext, enabler: DevSandboxLaneEnabler, directPath: DirectPathFlag? = nil) throws -> some RelayTransport {
        guard context.realm == .live else { throw TransportError.realm(.wrongTransport) }
        let sender = try NWRequestSender(origin: context.origin)
        return try RoutedRelayTransport(context: context, origin: context.origin, sender: sender, clientAddress: clientAddress, directPath: directPath)
    }
}

extension WorkspaceSessionConfig {
    func carrying(_ enabler: DevSandboxLaneEnabler?) -> WorkspaceSessionConfig { var c = self; c.devSandboxEnabler = enabler; return c }
}

#endif
