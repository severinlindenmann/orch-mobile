import Foundation

/// Domain-separation labels of protocol v2 section 3. HKDF labels have no trailing `|` (fields are appended with
/// `|`); signature, AAD and hash labels end in `|`. The vectors file carries the HKDF labels under `labels` and the
/// tests compare them.
public enum Label {
    // HKDF info labels
    public static let kdfBridge = "orch/v2/bridge"
    public static let kdfBridgeMsg = "orch/v2/bridge-msg"
    public static let kdfPush = "orch/v2/push"
    public static let kdfPushMsg = "orch/v2/push-msg"
    public static let kdfWrapWK = "orch/v2/wrap-wk"
    public static let kdfWrapSK = "orch/v2/wrap-sk"
    public static let kdfWrapMsg = "orch/v2/wrap-msg"
    public static let kdfPair = "orch/v2/pair"
    public static let kdfSeal = "orch/v2/seal"
    public static let kdfCard = "orch/v2/card"
    public static let kdfDropContent = "orch/v2/drop-content"
    public static let kdfDropMeta = "orch/v2/drop-meta"
    public static let kdfLabel = "orch/v2/label"
    public static let kdfLabelMsg = "orch/v2/label-msg"
    // AAD labels
    public static let aadSeal = "orch/v2/seal-aad|"
    public static let aadPush = "orch/v2/push-aad|"
    public static let aadWrap = "orch/v2/wrap-aad|"
    public static let aadCard = "orch/v2/card-aad|"
    public static let aadLabel = "orch/v2/label-aad|"
    public static let aadDropMeta = "orch/v2/drop-meta-aad|"
    // signature labels
    public static let sigDeviceCert = "orch/v2/sig/device-cert|"
    public static let sigRevocation = "orch/v2/sig/revocation|"
    public static let sigCardWSK = "orch/v2/sig/card-wsk|"
    public static let sigWSDelegation = "orch/v2/sig/ws-delegation|"
    public static let sigCertChallenge = "orch/v2/sig/cert-challenge|"
    public static let sigPush = "orch/v2/sig/push|"
    public static let sigDecision = "orch/v2/sig/decision|"
    public static let sigMemberList = "orch/v2/sig/member-list|"
    public static let sigWKGrant = "orch/v2/sig/wk-grant|"
    public static let sigSKGrant = "orch/v2/sig/sk-grant|"
    public static let sigBridge = "orch/v2/sig/bridge|"
    public static let sigCertRequest = "orch/v2/sig/cert-request|"
    public static let sigEnrollRequest = "orch/v2/sig/enroll-request|"
    public static let sigDropObject = "orch/v2/sig/drop-object|"
    public static let sigDropClaim = "orch/v2/sig/drop-claim|"
    public static let sigWSEnvelope = "orch/v2/ws-envelope|"
    public static let sigWSCosign = "orch/v2/sig/ws-cosign|"
    public static let sigWebAuthnBind = "orch/v2/sig/webauthn-bind|"
    public static let sigRelayAuth = "orch/v2/sig/relay-auth|"
    public static let sigPublish = "orch/v2/publish|"
    // hash labels
    public static let hDeviceID = "orch/v2/id/device|"
    public static let hPersonID = "orch/v2/id/person|"
    public static let hPinPerson = "orch/v2/pin/person|"
    public static let hPinWorkspace = "orch/v2/pin/workspace|"
    public static let hSAS = "orch/v2/sas|"
    public static let hSASCert = "orch/v2/sas-cert|"
    public static let hDEKCommit = "orch/v2/dek-commit|"
    public static let hCardKeyCommit = "orch/v2/card-key-commit|"
    public static let hDropParent = "orch/v2/drop-parent|"
    public static let hWSEnvelope = "orch/v2/ws-envelope-hash|"
    public static let hQuestion = "orch/v2/question|"
    public static let hAssert = "orch/v2/assert|"
    public static let hWebAuthnReg = "orch/v2/webauthn-reg|"
    public static let macEnroll = "orch/v2/enroll|"
}

/// Suite 2 (`p256`) constants, section 1.1. This module implements no other suite (decision: suite 2 only).
public enum Suite2 {
    public static let id: UInt8 = 2
    public static let publicKeyLength = 65
    public static let signatureLength = 64
    public static let skewMs: Int64 = 300_000
}
