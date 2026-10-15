import SwiftUI

/// How an answered question shows who signed it (H12d, host 9.11 `READER_VIEWS_1`: `questions[].answer.signer {device, auth}`).
/// `auth` is the wire value F1 section 11.4 lists. `convenience` is a click-to-sign answer with no presence check, and says so; a value
/// this build does not know has no label (`nil`): the parser refuses it before any screen sees it, and a screen must never invent one.
public enum SignerAuthLabel {
    public static let convenience = "convenience (no presence)"

    public static func text(forWire auth: String) -> String? {
        switch auth {
        case "convenience": return convenience
        case "passphrase": return "passphrase"
        case "secure-enclave": return "Secure Enclave"
        case "secure-enclave-unlocked": return "Secure Enclave, unlocked"
        case "webauthn": return "security key"
        case "tpm": return "TPM"
        case "windows-hello": return "Windows Hello"
        default: return nil
        }
    }

    /// `d_` plus the first 8 hex digits, for a one-line display; the full id stays in the accessibility label.
    public static func shortDevice(_ device: String) -> String { String(device.prefix(10)) + "…" }
}

/// One line under an answered question: "Signed with <auth> on d_1234abcd…". Convenience is set apart in the warning colour so it is
/// never read as a presence-checked signature.
public struct SignerLine: View {
    private let auth: String
    private let device: String

    public init(auth: String, device: String) { self.auth = auth; self.device = device }

    public var body: some View {
        if let label = SignerAuthLabel.text(forWire: auth) {
            Label {
                Text(verbatim: "Signed with \(label) on \(SignerAuthLabel.shortDevice(device))")
            } icon: {
                Image(systemName: auth == "convenience" ? "hand.raised.slash" : "checkmark.seal")
            }
            .font(OF.meta)
            .foregroundStyle(auth == "convenience" ? OC.warn : OC.textMuted)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Signed with \(label) on device \(device)"))
            .accessibilityIdentifier("signer.line")
        }
    }
}
