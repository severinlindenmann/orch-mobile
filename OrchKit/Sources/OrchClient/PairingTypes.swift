import Foundation
import OrchCustody
import OrchProtocol
import OrchStore

/// Why a pairing stopped without a workspace (the terminal explanations of host-api section 6). Fixed local texts; nothing the
/// host sent is shown as an explanation.
public enum PairingFailure: Error, Equatable, Sendable {
    /// No authenticated answer within 60 s, or `pairing_closed`: "this link was used by someone else: reject it on your Mac".
    case linkUsed
    /// The workspace belongs to another person ("this workspace belongs to someone else"); nothing was sent or the host refused.
    case otherPerson
    /// The link names a relay origin this realm may not reach (Demo: anything but the in-process relay).
    case realm(RealmViolation)
    /// The host refused the request with a verified refusal.
    case hostRefused(code: String)
    /// The phone's clock is further than 24 h from the host's.
    case clockWrong
    /// Verification of the join failed; nothing was installed. `reason` is a short stable tag.
    case verification(reason: String)
    /// The join could not reach the relay for 60 s. Retryable with `retryJoin()`; transport loss is not rejection.
    case joiningTimedOut
    /// The workspace is already on this iPhone.
    case alreadyMember
    /// The device keys are missing or unusable.
    case custody
    /// B8: the workspace's hub mode is full (or it reported `cut_over`): "This workspace now uses your hub". Nothing was sent.
    case usesHub
}

public enum PairingExpiry: String, Sendable, Equatable {
    /// The local 10-minute cap before the host approved (or the host said `expired`).
    case beforeApproval = "before_approval"
    /// cert_pending ran 10 minutes without a certificate.
    case certification
    /// The 10-minute window for retrying a join after the approval ended (or the certificate expired first).
    case afterApproval = "after_approval"
}

/// The full-screen alarm (host-api section 6). Terminal; it survives a restart. It never carries a code.
public struct PairingAlarm: Sendable, Equatable {
    public let kind: PairingAlarmKind
    /// A safe local primary label, or "your primary device".
    public let primaryLabel: String
    public static let genericPrimary = "your primary device"

    public init(kind: PairingAlarmKind, primaryLabel: String?) {
        self.kind = kind
        self.primaryLabel = PairingAlarm.safeLabel(primaryLabel)
    }

    /// The host chooses the label text, so only a short, plain one is ever shown inside an instruction.
    public static func safeLabel(_ l: String?) -> String {
        guard let l, !l.isEmpty, l.unicodeScalars.count <= 40, l.unicodeScalars.allSatisfy({
            $0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == " " || $0 == "-" || $0 == "_" || $0 == "." || $0 == "'" || $0.value == 0x2019
        }) else { return genericPrimary }
        return l
    }

    public var instruction: String {
        switch kind {
        case .echoWrongKey: "Reject on your Mac (host)"
        case .r1Challenge: "Reject on \(primaryLabel); do not confirm any code there; this host may be compromised"
        case .pinSubstitution, .regression:
            "Abandon this pairing. Reject any outstanding prompt on your Mac (host) and on \(primaryLabel)"
        case .foreignRejection:
            "Abandon this pairing: the owner turned down a request for another device in this workspace. Reject any prompt on your Mac (host)"
        }
    }
}

/// A verified, committed join.
public struct JoinedWorkspace: Sendable {
    public let workspace: ID16
    public let generation: Int64
    /// From the signed, opened card (D-6), never from the bridge.
    public let name: String
    public let hosted: HostedMarker
    public let scopes: [String]
    public let epoch: UInt32
    public let origin: String
    public let session: WorkspaceSession
    package let dropCard: VerifiedCard
    public var downloadContainer: WorkspaceContainer { session.cfg.container }
    public func makeDropService() throws -> DropService { try DropService(session: session, card: dropCard) }
    /// Relay push registration and the notification extension's key material for this workspace (P3-D40).
    public func makePushService() -> PushService { PushService(session: session) }
}

/// One state per U5 screen. Codes appear only in `comparingHost` and `comparingPrimary`, never together.
public enum PairingState: Sendable, Equatable {
    case idle
    case parsing
    case connecting(origin: String)
    /// The 6-character pairing code, to compare with the host.
    case comparingHost(code: String)
    /// "Open orch on <primary>" with a countdown to `deadlineMs` (an estimate until a challenge exists).
    case waitingPrimary(primaryLabel: String, deadlineMs: Int64, challengeExpired: Bool)
    /// `cert_code`, to compare with the primary; hidden the moment `expiresMs` passes.
    case comparingPrimary(code: String, primaryLabel: String, expiresMs: Int64)
    case joining
    case ready(JoinedHandle)
    case alarm(PairingAlarm)
    case rejected
    /// "Denied by the owner": the owner's PK-signed rejection of exactly this attempt verified (protocol-v2 section 8.3, G3b).
    /// Attributed to the pinned owner (`owner` = the person of the link's `pk_pin`), never to the host-supplied primary label.
    case denied(owner: ID16)
    case expired(PairingExpiry)
    case failed(PairingFailure)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .ready, .alarm, .rejected, .denied, .expired, .cancelled: true
        case .failed(let f): f != .joiningTimedOut
        default: false
        }
    }
}

/// `JoinedWorkspace` made `Equatable` for state comparison (by workspace and generation).
public struct JoinedHandle: Sendable, Equatable {
    public let joined: JoinedWorkspace
    public static func == (a: Self, b: Self) -> Bool { a.joined.workspace == b.joined.workspace && a.joined.generation == b.joined.generation }
}

public struct PairingConfig: Sendable {
    public var context: RealmContext
    public var transport: any RelayTransport
    public var index: WorkspaceIndex
    /// The `.keys` vault; the coordinator addresses only `context.realm` items through it.
    public var vault: SecretVault
    public var custody: any DeviceKeyCustody
    public var clock: any Clock<Duration>
    public var wall: any WallClock
    public var entropy: any Entropy
    /// The device label the host shows, e.g. "Severin's iPhone".
    public var deviceLabel: String
    /// H12d: the running build's runtime KAT result and identity (`.production` in the app).
    public var reader: ReaderRuntime
    /// C2b: the Demo environment's write grant, handed to every session this coordinator builds (nil in Live).
    public var processLocalWriteGrant: ProcessLocalWriteGrant?
    /// B8: the direct-path flag (nil: no gate, direct stays on).
    public var directPath: DirectPathFlag?
    #if DEBUG && targetEnvironment(simulator)
    /// The Simulator dev-sandbox lane's enabler (`DevSandboxLane.swift`): minted by the `OrchDevSandbox` App target only; nil everywhere else.
    public var devSandboxEnabler: DevSandboxLaneEnabler?
    #endif

    public init(context: RealmContext, transport: any RelayTransport, index: WorkspaceIndex, vault: SecretVault, custody: any DeviceKeyCustody,
                clock: any Clock<Duration>, wall: any WallClock, entropy: any Entropy = SystemEntropy(), deviceLabel: String,
                reader: ReaderRuntime = .production, processLocalWriteGrant: ProcessLocalWriteGrant? = nil) {
        self.context = context; self.transport = transport; self.index = index; self.vault = vault; self.custody = custody
        self.clock = clock; self.wall = wall; self.entropy = entropy; self.deviceLabel = deviceLabel; self.reader = reader
        self.processLocalWriteGrant = processLocalWriteGrant
    }
}
