#if DEBUG
import SwiftUI
import OrchClient
import OrchUI

/// Pair this iPhone with a hub (V3 dev; design B1): scan or paste the link, compare the fingerprint and the host, type the password and the
/// code, see the result. Deliberately minimal: the mockup (A4) is not picked yet, so only the essentials, in a layout that can be replaced.
struct HubPairingScreen: View {
    @Bindable var model: HubPairingModel
    @State private var scanning = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: OS.s5) {
                    switch model.state {
                    case .idle: entry
                    case .checking: progress("Checking the hub…")
                    case .confirm(let p): confirm(p)
                    case .working(let step): progress(Self.text(step))
                    case .paired(let s): done(s)
                    case .failed(let f): failed(f)
                    }
                }
                .padding(OS.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(OC.bg)
            .navigationTitle("Pair with a hub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if case .paired = model.state {} else { Button("Cancel") { model.cancel(); dismiss() }.accessibilityIdentifier("hub.cancel") }
                }
            }
            .sheet(isPresented: $scanning) {
                LiveScannerSheet { code in model.linkText = code; scanning = false; model.start() }
            }
        }
    }

    // MARK: states

    private var entry: some View {
        VStack(alignment: .leading, spacing: OS.s4) {
            Text("Connect this iPhone to your hub so it can ask you to sign. Scan the QR code your hub's admin shows you, or paste the link.").font(OF.body).foregroundStyle(OC.textMuted)
            Button { scanning = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity) }
                .buttonStyle(.orchProminent).accessibilityIdentifier("hub.scan")
            VStack(alignment: .leading, spacing: OS.s2) {
                Text("Pairing link").font(OF.meta).foregroundStyle(OC.textMuted)
                TextField("orch://hub-pair/…", text: $model.linkText, axis: .vertical)
                    .lineLimit(2...4).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .font(OF.machine).padding(OS.s3).orchCard().accessibilityIdentifier("hub.link")
            }
            Button("Continue") { model.start() }
                .buttonStyle(.orchSoftBrand).disabled(model.linkText.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("hub.continue")
        }
    }

    private func confirm(_ p: HubPairingPreview) -> some View {
        VStack(alignment: .leading, spacing: OS.s5) {
            VStack(alignment: .leading, spacing: OS.s3) {
                Text("Is this your hub?").font(OF.wsName)
                Text("Compare this fingerprint with the one next to the QR code in the hub's admin console.")
                    .font(OF.body).foregroundStyle(OC.textMuted)
                Text(verbatim: Self.fingerprintRows(p.fingerprint)).font(OF.machine).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("hub.fingerprint")
                LabeledContent("Address") { Text(verbatim: p.host).font(OF.machine).textSelection(.enabled) }.accessibilityIdentifier("hub.host")
            }
            .padding(OS.s4).orchCard()
            VStack(alignment: .leading, spacing: OS.s3) {
                Text("Hub password").font(OF.meta).foregroundStyle(OC.textMuted)
                SecureField("Password", text: $model.password).textContentType(.password).padding(OS.s3).orchCard()
                    .accessibilityIdentifier("hub.password")
                Text("Authenticator code").font(OF.meta).foregroundStyle(OC.textMuted)
                TextField("6-digit code", text: $model.totp).keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .padding(OS.s3).orchCard().accessibilityIdentifier("hub.totp")
                Text("Hub name (shown in notifications)").font(OF.meta).foregroundStyle(OC.textMuted)
                TextField("Name for this hub", text: $model.hubName).padding(OS.s3).orchCard().accessibilityIdentifier("hub.name")
                Text("The code from your authenticator app. Each code works once.").font(OF.meta).foregroundStyle(OC.textMuted)
            }
            Button("Pair this iPhone") { model.pair() }
                .buttonStyle(.orchProminent).disabled(model.password.isEmpty || model.totp.count != 6)
                .accessibilityIdentifier("hub.pair")
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: OS.s3) { ProgressView(); Text(text).font(OF.body) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(OS.s4).orchCard().accessibilityIdentifier("hub.progress")
    }

    private func done(_ s: HubPairingSummary) -> some View {
        VStack(alignment: .leading, spacing: OS.s4) {
            Label("Paired with \(s.label)", systemImage: "checkmark.seal.fill").font(OF.wsName).foregroundStyle(OC.ok)
                .accessibilityIdentifier("hub.paired")
            VStack(alignment: .leading, spacing: OS.s2) {
                LabeledContent("Address") { Text(verbatim: s.host).font(OF.machine) }
                Text(verbatim: Self.fingerprintRows(s.fingerprint)).font(OF.machine).foregroundStyle(OC.textMuted)
            }
            .padding(OS.s4).orchCard()
            Text("This iPhone's key stays on this iPhone. Your hub can now ask you to sign here.").font(OF.body).foregroundStyle(OC.textMuted)
            Button("Done") { dismiss() }.buttonStyle(.orchProminent).accessibilityIdentifier("hub.done")
        }
    }

    private func failed(_ f: HubPairingFailure) -> some View {
        VStack(alignment: .leading, spacing: OS.s4) {
            Label("Pairing didn't finish", systemImage: "exclamationmark.triangle.fill").font(OF.wsName).foregroundStyle(OC.danger)
            Text(verbatim: Self.text(f)).font(OF.body).accessibilityIdentifier("hub.failure")
            Text("This iPhone was not paired.").font(OF.meta).foregroundStyle(OC.textMuted)
            Button("Try again") { model.tryAgain() }.buttonStyle(.orchProminent).accessibilityIdentifier("hub.retry")
        }
    }

    // MARK: text

    static func fingerprintRows(_ fp: String) -> String {
        let g = fp.split(separator: " ")
        guard g.count == 8 else { return fp }
        return g[0..<4].joined(separator: " ") + "\n" + g[4..<8].joined(separator: " ")
    }

    static func text(_ s: HubPairingStep) -> String {
        switch s {
        case .signingIn: "Signing in…"
        case .creatingKey: "Creating this iPhone's key…"
        case .registering: "Registering this iPhone…"
        case .binding: "Finishing…"
        }
    }

    static func text(_ f: HubPairingFailure) -> String {
        switch f {
        case .badLink: "That isn't a hub pairing link, or it was cut off. Copy it again."
        case .alreadyPaired: "This iPhone is already paired with a hub. Leave that hub first."
        case .otherHub: "The hub that answered is not the hub in this link. Nothing was sent. Ask your admin for a new QR code."
        case .otherOrigin: "The address in this link is not the address the hub signed. Nothing was sent. Do not use this link."
        case .cardRefused(let c): c == "dev_refused" ? "This is a development hub, and this version of orch only pairs with real hubs."
            : "This hub could not be verified. Nothing was sent. (\(c))"
        case .badCredentials: "Check your password and enter a new authenticator code. A code works once, so wait for the next one."
        case .rateLimited: "Too many tries. Wait a little and try again."
        case .pairingCodeRejected: "The pairing code was used already or has run out. Ask your admin for a new QR code."
        case .noSession: "The sign-in ran out. Start again."
        case .hubRefused(let c): "The hub refused to pair. (\(c))"
        case .verification(let c): "The hub's answer did not check out, so this iPhone did not trust it. (\(c))"
        case .network: "Could not reach the hub. Check the connection and try again."
        case .custody: "This iPhone could not store the key. Is it unlocked, with a passcode set?"
        }
    }
}
#endif
