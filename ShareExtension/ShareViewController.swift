import SwiftUI
import UIKit
import UniformTypeIdentifiers
import OrchUI
import OrchShareStaging

/// Native compose for "Share to orch" (A10). It stages plaintext into the share App Group and nothing else: no
/// keychain, custody, signing or network. The app seals and uploads on its next activation.
final class ShareViewController: UIViewController {
    private var model: ShareModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let model = ShareModel(providers: providers) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        } cancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
        self.model = model
        let host = UIHostingController(rootView: ShareComposeView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        model.start()
    }
}

// MARK: Model

@MainActor @Observable
final class ShareModel {
    enum Phase: Equatable {
        case loading
        case choosing
        case saving
        case saved
        case noWorkspaces
        case unreadable
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var targets: [ShareTarget] = []
    var destination: String?
    var note = ""
    /// Short non-sensitive reason shown with the unreadable state (support evidence; no paths or names).
    private(set) var unreadableReason = ""
    /// Path-free support lines behind "Details" on the unreadable screen (same as the app's "Share targets status").
    private(set) var details: [ShareDiagnostics.Line] = []
    let summary: [String]

    private let providers: [NSItemProvider]
    private let finish: () -> Void
    private let cancelRequest: () -> Void
    private var area: ShareArea?
    private var session: StagingSession?
    private var saveTask: Task<Void, Never>?

    init(providers: [NSItemProvider], finish: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.providers = providers; self.finish = finish; self.cancelRequest = cancel
        summary = providers.prefix(ShareLimits.maxItems + 1).map { ShareModel.describe($0) }
    }

    /// Reads the destinations index; unreadable or empty means nothing is retained and nothing can be saved.
    static let groupIdentifier = "group.io.severin.orch.share"

    func start() {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.groupIdentifier) else {
            unreadableReason = "no app group container"
            details = ShareDiagnostics.collect(groupID: Self.groupIdentifier, root: nil)
            phase = .unreadable; return
        }
        let area = ShareArea(shareGroupRoot: root)
        self.area = area
        Task.detached { ShareInbox(area: area).sweep() }   // expiry janitor
        do {
            targets = try ShareTargetIndex.load(from: area)
            phase = .choosing
        } catch ShareError.noWorkspaces {
            details = ShareDiagnostics.collect(groupID: Self.groupIdentifier, root: root, lockTimeout: 0.5)
            phase = .noWorkspaces
        }
        catch {
            unreadableReason = ShareModel.code(for: error)
            details = ShareDiagnostics.collect(groupID: Self.groupIdentifier, root: root, lockTimeout: 0.5)
            phase = .unreadable
        }
    }

    var canSave: Bool { phase == .choosing && destination != nil && !providers.isEmpty }

    func save() {
        guard canSave, let area, let target = targets.first(where: { $0.id == destination }) else { return }
        guard providers.count <= ShareLimits.maxItems else { phase = .failed("You can share up to 5 items at a time."); return }
        phase = .saving
        let providers = providers
        let note = note
        // No App Group container may ever be a copy source (the share group is refused by the stager itself).
        let forbidden = ["group.io.severin.orch", "group.io.severin.orch.share"].compactMap {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
        saveTask = Task { [weak self] in
            do {
                let session = try StagingSession(area: area, target: target, extraForbiddenRoots: forbidden)
                self?.session = session
                for p in providers {
                    try Task.checkCancellation()
                    try await ProviderStager.stage(p, into: session)
                }
                try Task.checkCancellation()
                try session.commit(note: note)
                self?.phase = .saved
            } catch {
                self?.session?.cancel()
                if error is CancellationError { return }
                self?.phase = .failed(ShareModel.message(for: error))
            }
        }
    }

    func cancel() {
        saveTask?.cancel()
        session?.cancel()
        cancelRequest()
    }

    func done() { finish() }

    func retry() { phase = .choosing }

    /// Fixed, non-sensitive code for support evidence: never interpolates the error (it may carry paths).
    static func code(for error: Error) -> String {
        switch error as? ShareError {
        case .noWorkspaces: "index: none"
        case .unreadable: "index: unreadable"
        case .index(let f): "index: \(f.code)"
        case .tooManyItems: "index: items"
        case .tooLarge: "index: size"
        case .empty: "index: empty"
        case .unsupported: "index: type"
        case .destinationRemoved: "index: removed"
        case .cancelled: "index: cancelled"
        case .busy: "index: busy"
        case .io: "index: io"
        case nil: "index: other"
        }
    }

    static func message(for error: Error) -> String {
        switch error as? ShareError {
        case .tooManyItems: "You can share up to 5 items at a time."
        case .tooLarge: "That is more than 25 MB. Nothing was saved."
        case .destinationRemoved: "That workspace was removed from this iPhone. Nothing was saved."
        case .unsupported: "orch can't send one of these items. Nothing was saved."
        case .empty: "There is nothing to save."
        case .busy: "orch is busy. Nothing was saved. Try again in a moment."
        default: "Couldn't save. Nothing was kept."
        }
    }

    // MARK: Providers

    static func describe(_ p: NSItemProvider) -> String {
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || p.registeredContentTypes.contains(where: { $0.conforms(to: .data) && !$0.conforms(to: .text) && !$0.conforms(to: .url) }) {
            return SafeText.inline(p.suggestedName ?? "File", limit: 40)
        }
        if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) { return "Link" }
        if p.hasItemConformingToTypeIdentifier(UTType.text.identifier) { return "Text" }
        return SafeText.inline(p.suggestedName ?? "Item", limit: 40)
    }
}

// MARK: View

private struct ShareComposeView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Share to orch")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { model.cancel() }.accessibilityIdentifier("share.cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if model.phase == .saved {
                            Button("Done") { model.done() }.accessibilityIdentifier("share.done")
                        } else {
                            Button("Save to send") { model.save() }
                                .disabled(!model.canSave).accessibilityIdentifier("share.save")
                        }
                    }
                }
        }
        .tint(OC.brand)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noWorkspaces:
            ShareProblemView(kind: .noWorkspaces, reason: "", lines: model.details)
        case .unreadable:
            ShareProblemView(kind: .unreadable, reason: model.unreadableReason, lines: model.details)
        case .saved:
            ShareStatusMessage(text: "Saved. Open orch to send.", detail: nil, id: "share.status.saved")
                .frame(maxHeight: .infinity)
        case .failed(let text):
            VStack {
                ShareStatusMessage(text: text, detail: nil, id: "share.status.failed").frame(maxHeight: .infinity)
                Button("Try again") { model.retry() }.accessibilityIdentifier("share.retry")
            }
        case .choosing, .saving:
            Form {
                Section("Send to") {
                    ForEach(model.targets) { t in
                        Button {
                            model.destination = t.id
                        } label: {
                            HStack {
                                Capsule().fill(OC.wsHues[abs(t.hue) % OC.wsHues.count]).frame(width: 4, height: 24)
                                Text(verbatim: t.realm == "demo" ? SafeText.inline(t.name, limit: 32) + " (Demo)" : SafeText.inline(t.name, limit: 40)).foregroundStyle(OC.text)
                                Spacer()
                                if model.destination == t.id { Image(systemName: "checkmark").foregroundStyle(OC.brand) }
                            }
                        }
                        .accessibilityIdentifier("share.destination.\(t.ws)")
                        .accessibilityAddTraits(model.destination == t.id ? .isSelected : [])
                    }
                }
                Section("Items") {
                    ForEach(Array(model.summary.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line).lineLimit(1)
                    }
                }
                Section("Note") {
                    TextField("Short note (optional)", text: $model.note, axis: .vertical).lineLimit(1...3)
                        .accessibilityIdentifier("share.note")
                }
                if model.phase == .saving {
                    Section { ProgressView("Saving").accessibilityIdentifier("share.saving") }
                }
            }
            .disabled(model.phase == .saving)
        }
    }
}
