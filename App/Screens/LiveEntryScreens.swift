import AVFoundation
import SwiftUI
import VisionKit
import OrchClient
import OrchUI

/// The Live entry flow, presented above the realm's view graph: scan or paste, review the invitation, then the pairing itself.
struct LiveEntryFlow: View {
    let intake: LiveIntake

    var body: some View {
        Group {
            switch intake.screen {
            case .entry: LiveEntryScreen(intake: intake)
            case .review(let link): ReviewInvitationScreen(intake: intake, link: link)
            case .switchOffer(let link): SwitchOfferScreen(intake: intake, link: link)
            case .refused(let reason): InvitationRefusedScreen(intake: intake, reason: reason)
            case .leavingDemo: LeavingDemoScreen()
            case .pairing:
                if let model = intake.pairingModel { PairingScreen(model: model, onClose: { intake.dismiss() }).tint(OC.brand) }
            case nil: Color.clear
            }
        }
        .tint(OC.brand)
        // Feedback for an invitation that was ignored (one is under review, a pairing is running, Demo is being left): on EVERY screen.
        .overlay(alignment: .top) {
            if let notice = intake.notice {
                Button { intake.clearNotice() } label: {
                    Label { Text(verbatim: notice).multilineTextAlignment(.leading) } icon: { Image(systemName: "info.circle.fill") }
                        .font(OF.meta).foregroundStyle(OC.text).padding(OS.s3).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: OR.control, style: .continuous))
                        .padding(.horizontal, OS.s4).padding(.top, OS.s2)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("intake.notice")
                .accessibilityHint("Dismisses this message")
            }
        }
    }
}

private struct EntryChrome<Content: View>: View {
    let title: String
    let onCancel: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: OS.s4) { content }
                    .padding(OS.s5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(OC.bg)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onCancel {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel", action: onCancel).accessibilityIdentifier("live.cancel")
                    }
                }
            }
        }
    }
}

// MARK: Scan or paste

struct LiveEntryScreen: View {
    let intake: LiveIntake
    @State private var link = ""
    @State private var showScanner = false
    @State private var viaPasteButton = false
    @FocusState private var fieldFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        EntryChrome(title: "Pair your Mac", onCancel: { intake.dismiss() }) {
            OrbitMark(size: 40)
            Text("Connect to orch on your Mac").font(OF.display).accessibilityAddTraits(.isHeader)
            Text("On your Mac open orch, choose Remote, then Pair phone. Your Mac approves this iPhone.")
                .font(OF.body).foregroundStyle(OC.textMuted)
            Button { showScanner = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }
                .buttonStyle(.orchProminent).accessibilityIdentifier("live.scan")
            VStack(alignment: .leading, spacing: OS.s2) {
                Text("Or paste the pairing link").font(OF.section)
                TextField("Pairing link", text: $link, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(OS.s3).background(OC.surface, in: RoundedRectangle(cornerRadius: OR.control, style: .continuous))
                    .accessibilityIdentifier("live.paste")
                    .focused($fieldFocused)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { fieldFocused = false }.accessibilityIdentifier("live.keyboardDone")
                        }
                    }
                    // The link carries the pairing secret: kept out of the app-switcher snapshot and screenshots' accessibility text.
                    .privacySensitive()
                    .opacity(scenePhase == .active ? 1 : 0)
                if let error = intake.entryError {
                    Text(verbatim: error).font(OF.meta).foregroundStyle(OC.danger).accessibilityIdentifier("live.paste.error")
                }
                (typeSize >= .xxxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: OS.s2)) : AnyLayout(HStackLayout())) {
                    // PasteButton reads the clipboard only when the user taps it.
                    PasteButton(payloadType: String.self) { strings in if let s = strings.first { link = s; viaPasteButton = true } }
                    Button("Review invitation") { submit() }
                        .buttonStyle(.bordered)
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("live.review")
                }
            }
            if let notice = intake.notice { Text(verbatim: notice).font(OF.meta).foregroundStyle(OC.warn) }
        }
        .sheet(isPresented: $showScanner) {
            LiveScannerSheet { text in
                showScanner = false
                intake.handle(text: text, source: .scanned)
            }
        }
    }

    /// A failed parse empties the field (it may hold a secret); a good one empties it too and, when the text came from the clipboard
    /// through the paste button and the clipboard still holds exactly that, clears the clipboard.
    private func submit() {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        intake.handle(text: text, source: .pasted)
        if viaPasteButton, UIPasteboard.general.hasStrings, UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) == text,
           intake.entryError == nil {
            UIPasteboard.general.string = ""
        }
        viaPasteButton = false
        link = ""
    }
}

// MARK: Review

struct ReviewInvitationScreen: View {
    let intake: LiveIntake
    let link: PairingLink

    var body: some View {
        EntryChrome(title: "Review invitation", onCancel: { intake.dismiss() }) {
            Image(systemName: "exclamationmark.shield").font(OF.display).foregroundStyle(OC.brand).accessibilityHidden(true)
            Text("Review this invitation").font(OF.display).accessibilityAddTraits(.isHeader)
            // The invitation names a relay and a host; nothing about either is verified yet, so it is never called "your Mac" here.
            Text("Continuing pairs this iPhone with the host that made this invitation. Nothing is sent until you tap Connect.")
                .font(OF.body).foregroundStyle(OC.textMuted)
            VStack(alignment: .leading, spacing: OS.s2) {
                Text("Relay").font(OF.meta).foregroundStyle(OC.textMuted)
                // Read-only, ASCII (an international name shows as punycode, never decoded).
                Text(verbatim: link.reviewedOrigin).font(OF.machine.weight(.semibold)).textSelection(.enabled)
                    .accessibilityIdentifier("review.origin")
                Label(intake.source.label, systemImage: intake.source == .otherApp ? "arrow.up.forward.app" : "checkmark.circle")
                    .font(OF.meta).foregroundStyle(intake.source == .otherApp ? OC.warn : OC.textMuted)
                    .accessibilityIdentifier("review.source")
            }
            .padding(OS.s4).frame(maxWidth: .infinity, alignment: .leading).orchCard()
            Text("Only continue if you just started pairing on your Mac and this relay is yours.")
                .font(OF.section).foregroundStyle(OC.warn).accessibilityIdentifier("review.warning")
            Text("The workspace name is shown only after your Mac proves it.").font(OF.meta).foregroundStyle(OC.textMuted)
            Button { intake.connect(link) } label: { Text("Connect") }
                .buttonStyle(.orchProminent).accessibilityIdentifier("review.connect")
            Button { intake.dismiss() } label: { Text("Cancel") }
                .buttonStyle(.orchSoft)
        }
    }
}

// MARK: Demo is active

struct SwitchOfferScreen: View {
    let intake: LiveIntake
    let link: PairingLink
    @State private var confirm = false

    var body: some View {
        EntryChrome(title: "Invitation received", onCancel: { intake.dismiss() }) {
            Image(systemName: "theatermasks").font(OF.display).foregroundStyle(OC.demo).accessibilityHidden(true)
            Text("You are in the Demo").font(OF.display).accessibilityAddTraits(.isHeader).accessibilityIdentifier("switch.title")
            Text("An invitation was opened (\(intake.source.label.lowercased()); relay below). Demo and Live never run together, so using it means leaving the Demo, which deletes the Demo workspaces from this iPhone.")
                .font(OF.body).foregroundStyle(OC.textMuted)
            Text(verbatim: link.reviewedOrigin).font(OF.machine.weight(.semibold)).accessibilityIdentifier("switch.origin")
                .padding(OS.s4).frame(maxWidth: .infinity, alignment: .leading).orchCard()
            Button(role: .destructive) { confirm = true } label: { Text("Leave Demo and pair your Mac") }
                .buttonStyle(.orchSoftDanger).accessibilityIdentifier("switch.leave")
            Button { intake.dismiss() } label: { Text("Keep Demo") }
                .buttonStyle(.orchSoft).accessibilityIdentifier("switch.keep")
        }
        .alert("Leave Demo and pair your Mac?", isPresented: $confirm) {
            Button("Leave Demo", role: .destructive) { intake.leaveDemoAndPair() }
                .accessibilityIdentifier("switch.leave.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the Demo workspaces from this iPhone. You will review the invitation again before anything connects.")
        }
    }
}

struct LeavingDemoScreen: View {
    var body: some View {
        VStack(spacing: OS.s4) {
            ProgressView()
            Text("Leaving Demo…").font(OF.body).foregroundStyle(OC.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(OC.bg)
        .accessibilityIdentifier("switch.leaving")
    }
}

struct InvitationRefusedScreen: View {
    let intake: LiveIntake
    let reason: InvitationRefusal

    var body: some View {
        EntryChrome(title: "Invitation", onCancel: nil) {
            Image(systemName: "xmark.octagon").font(OF.display).foregroundStyle(OC.warn).accessibilityHidden(true)
            Text(verbatim: reason.title).font(OF.display).accessibilityAddTraits(.isHeader).accessibilityIdentifier("invitation.refused")
            Text(verbatim: reason.detail).font(OF.body).foregroundStyle(OC.textMuted)
            switch reason {
            case .differentOrigin(let existing, let offered):
                detail("This iPhone uses", existing)
                detail("This invitation", offered)
            case .unsupportedOrigin(let origin): detail("Relay", origin)
            default: EmptyView()
            }
            Button { intake.dismiss() } label: { Text("Close") }
                .buttonStyle(.orchSoft).accessibilityIdentifier("invitation.close")
        }
    }

    private func detail(_ label: String, _ origin: String) -> some View {
        VStack(alignment: .leading, spacing: OS.s1) {
            Text(verbatim: label).font(OF.meta).foregroundStyle(OC.textMuted)
            Text(verbatim: origin).font(OF.machine)
        }
    }
}

// MARK: Scanner (VisionKit)

/// Whether the in-app scanner can run. The scanner is the primary path; when it cannot run, the person is told why and pastes instead.
enum ScannerAvailability: Equatable {
    case available
    /// No supported camera (the Simulator, or a device without one).
    case noCamera
    /// The person has not been asked yet: the system prompt comes first, "camera off" is shown only after a refusal.
    case undetermined
    /// The camera exists but is off for orch (denied or restricted).
    case notAllowed

    static func resolve(isSupported: Bool, isAvailable: Bool, authorization: AVAuthorizationStatus) -> ScannerAvailability {
        guard isSupported else { return .noCamera }
        switch authorization {
        case .notDetermined: return .undetermined
        case .denied, .restricted: return .notAllowed
        case .authorized: return isAvailable ? .available : .notAllowed
        @unknown default: return .notAllowed
        }
    }

    @MainActor static func current() -> ScannerAvailability {
        resolve(isSupported: DataScannerViewController.isSupported, isAvailable: DataScannerViewController.isAvailable,
                authorization: AVCaptureDevice.authorizationStatus(for: .video))
    }

    var explanation: String {
        switch self {
        case .available, .undetermined: ""
        case .noCamera: "This device can't scan QR codes here. Paste the pairing link instead."
        case .notAllowed: "Camera access is off for orch. Turn it on in iOS Settings, or paste the pairing link instead."
        }
    }
}

struct LiveScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var availability = ScannerAvailability.current()

    var body: some View {
        NavigationStack {
            Group {
                if availability == .available {
                    LiveScanner(onCode: onCode).ignoresSafeArea()
                        .overlay(alignment: .bottom) {
                            Text("Point the camera at the QR code on your Mac.")
                                .font(OF.body).padding(OS.s3)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: OR.control, style: .continuous))
                                .padding(OS.s4)
                        }
                } else if availability == .undetermined {
                    ProgressView("Waiting for camera permission…").accessibilityIdentifier("scan.asking")
                } else {
                    VStack(spacing: OS.s4) {
                        Image(systemName: "qrcode").font(.system(size: 56)).foregroundStyle(OC.textMuted).accessibilityHidden(true)
                        Text("Scanning isn't available").font(OF.wsName).accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("scan.unavailable")
                        Text(verbatim: availability.explanation).font(OF.body).foregroundStyle(OC.textMuted)
                            .multilineTextAlignment(.center)
                        if availability == .notAllowed {
                            Button("Open iOS Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                            .buttonStyle(.bordered).accessibilityIdentifier("scan.openSettings")
                        }
                        Button { dismiss() } label: { Text("Paste link instead") }
                            .buttonStyle(.orchProminent).accessibilityIdentifier("scan.paste")
                    }
                    .padding(OS.s5)
                }
            }
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.accessibilityIdentifier("scan.cancel") } }
            .task {
                // Ask first; the Settings hint appears only after a refusal. (Not verifiable on the Simulator: device pass.)
                guard availability == .undetermined else { return }
                _ = await AVCaptureDevice.requestAccess(for: .video)
                availability = ScannerAvailability.current()
            }
        }
    }
}

struct LiveScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                           recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                           isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var delivered = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for case .barcode(let code) in addedItems {
                if let payload = code.payloadStringValue {
                    delivered = true
                    dataScanner.stopScanning()
                    onCode(payload)
                    return
                }
            }
        }
    }
}
