import AVFoundation
import SwiftUI
import VisionKit
import OrchUI

// The QR scanner of the hub pairing screen.
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

struct HubScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var availability = ScannerAvailability.current()

    var body: some View {
        NavigationStack {
            Group {
                if availability == .available {
                    HubScanner(onCode: onCode).ignoresSafeArea()
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

struct HubScanner: UIViewControllerRepresentable {
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
