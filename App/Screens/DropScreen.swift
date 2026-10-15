import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import OrchUI
import QuickLook
import OrchProtocol

struct DropScreen: View {
    let services: any AppServices
    @State private var direction: DropDirection = .received
    @State private var composing: Bool
    private let startComposing: Bool

    init(services: any AppServices, startComposing: Bool = false) {
        self.services = services
        self.startComposing = startComposing
        _composing = State(initialValue: startComposing)
    }

    private var model: any DropModel { services.drop }

    var body: some View {
        List {
            Section {
                Picker("Direction", selection: $direction) {
                    Text("Received").tag(DropDirection.received)
                    Text("Sending").tag(DropDirection.sending)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("drop.direction")
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(model.workspaces.filter { $0.lifecycle != .live }) { ws in
                    Text(verbatim: "\(ws.displayName): unavailable")
                }
                if let live = services as? LiveServices,
                   live.live.contains(where: { $0.drop?.loading == true || $0.drop?.sending == true || !($0.drop?.verifying.isEmpty ?? true) }) || live.shareStatus?.hasPrefix("Importing") == true {
                    ProgressView().accessibilityIdentifier("drop.progress")
                }
                let items = model.items(direction)
                if items.isEmpty {
                    Text(direction == .received ? "Nothing received yet." : "Nothing is being sent.")
                        .foregroundStyle(OC.textMuted)
                }
                ForEach(items) { item in
                    NavigationLink(value: Route.dropItem(item.id)) { DropRow(item: item, workspaces: model.workspaces) }
                        .accessibilityIdentifier("drop.item.\(item.presentationID)")
                        .task(id: model.dropRefreshRevision) { await model.verifyDropRow(item.id) }
                }
            }
            if direction == .sending, let live = services as? LiveServices {
                if live.shareStatus != nil {
                    Button { live.onRetryShared?() } label: { Text("Retry share import") }
                        .buttonStyle(.orchSoftBrand).accessibilityIdentifier("drop.share.retry")
                    Button { live.onStopShared?() } label: { Text("Stop sending share jobs") }
                        .buttonStyle(.orchSoftDanger).accessibilityIdentifier("drop.share.stop")
                }
                ForEach(live.live, id: \.info.id) { ws in
                    if let drop = ws.drop {
                        ForEach(drop.failures, id: \.object) { failure in
                            Section("Failed upload") {
                                Text(verbatim: ws.info.displayName)
                                Text(verbatim: failure.reason)
                                Button { Task { await drop.resolve(failure, retry: true) } } label: { Text("Retry") }
                                    .buttonStyle(.orchSoftBrand)
                                    .disabled(!drop.canOperate).accessibilityIdentifier("drop.retry")
                                Button { Task { await drop.resolve(failure, retry: false) } } label: { Text("Stop sending") }
                                    .buttonStyle(.orchSoftDanger)
                                    .disabled(!drop.canOperate).accessibilityIdentifier("drop.stop")
                                Text("Already-committed relay content may remain.")
                            }
                        }
                        Button { Task { await drop.foreground() } } label: { Text("Resume pending uploads") }
                            .buttonStyle(.orchSoft)
                            .disabled(!drop.canOperate).accessibilityIdentifier("drop.resume")
                    }
                }
            }
            #if DEBUG
            if let live = services as? LiveServices, live.options.uiTesting {
                Section("Demo test controls") {
                    Button("Stage pending transfer") { Task { await live.demoDropPending() } }.accessibilityIdentifier("drop.demo.pending")
                    Button("Reject next upload") { Task { await live.demoDropReject() } }.accessibilityIdentifier("drop.demo.reject")
                    Button("Add inbox item") { Task { await live.demoDropInbox() } }.accessibilityIdentifier("drop.demo.inbox")
                    Button("Expire downloads and foreground") { live.demoDropExpire() }.accessibilityIdentifier("drop.demo.expire")
                }
            }
            #endif
            Section {
                Label("Demo: real encrypted transfers within this iPhone.", systemImage: "info.circle")
                    .font(OF.meta).foregroundStyle(OC.demo).accessibilityIdentifier("drop.simulatedBanner")
                Text("Files and notes expire after 7 days. Links are shown as text and never opened for you.")
                    .font(OF.meta).foregroundStyle(OC.textMuted)

            }
        }
        .scrollContentBackground(.hidden)
        .background(OC.bg)
        .contentMargins(.bottom, 24, for: .scrollContent)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(.regularMaterial, for: .tabBar)
        // Pinned below the list (not above, so a late status never shifts the segmented control) so the current transfer status is always on screen (rows taller than before would otherwise
        // scroll it out of the lazy list).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let status = model.dropStatus {
                Text(verbatim: status).font(OF.meta).foregroundStyle(OC.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, OS.s4).padding(.vertical, OS.s2)
                    .background(OC.surface2)
                    .accessibilityIdentifier("drop.status")
            }
        }
        .onChange(of: startComposing) { _, request in if request { composing = true } }
        .task { await model.refreshDrop() }
        .refreshable { await model.refreshDrop() }
        .navigationTitle("Drop")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Send", systemImage: "square.and.arrow.up") { composing = true }
                    .accessibilityIdentifier("drop.compose")
            }
        }
        .sheet(isPresented: $composing) { DropComposeSheet(model: model, preset: nil) { direction = .sending } }
    }
}

struct DropRow: View {
    @ScaledMetric(relativeTo: .body) private var iconBox = 36.0
    @Environment(\.dynamicTypeSize) private var typeSize
    let item: DropItem
    let workspaces: [WorkspaceInfo]

    private var icon: String {
        switch item.kind {
        case .file: item.direction == .sending ? "arrow.up.doc" : "doc"
        case .note: "note.text"
        case .url: "link"
        }
    }

    var body: some View {
        let ws = workspaces.first { $0.id == item.workspaceID }
        HStack(alignment: .top, spacing: OS.s3) {
            Image(systemName: icon).foregroundStyle(OC.textMuted)
                .frame(width: iconBox, height: iconBox)
                .background(OC.surface2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: OS.s1) {
                HStack {
                    if item.unread { Circle().fill(OC.brand).frame(width: 8, height: 8).accessibilityLabel("Unread") }
                    Text(verbatim: item.displayName).font(OF.section).lineLimit(2)
                    if item.blocked { Image(systemName: "exclamationmark.shield.fill").foregroundStyle(OC.danger).accessibilityLabel("Verification alarm") }
                }
                Text(verbatim: item.verified ? "\(ws?.displayName ?? "") · \(Fmt.bytes(item.bytes))" : (ws?.displayName ?? ""))
                    .font(OF.meta).foregroundStyle(OC.textMuted)
                // Compact status line. Plain stacks (no custom Layout): chips keep their natural height inside a list row.
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: OS.s1) { statusParts(item) }
                } else {
                    HStack(spacing: OS.s2) { statusParts(item) }
                }
                if item.quarantineJob != nil {
                    Label("Destination removed. Choose another destination.", systemImage: "exclamationmark.triangle")
                        .font(OF.meta).foregroundStyle(OC.warn)
                } else if item.direction == .sending {
                    Label(item.stopped ? "Stopped sending" : (item.simulatedDone ? "Sent (confirmed)" : "Sending…"),
                          systemImage: item.simulatedDone ? "checkmark.circle" : "arrow.up.circle")
                        .font(OF.meta).foregroundStyle(item.simulatedDone ? OC.ok : OC.info)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

@MainActor @ViewBuilder
private func statusParts(_ item: DropItem) -> some View {
    if item.outdated {
        StatusChip("May be outdated", systemImage: "clock.badge.exclamationmark", color: OC.warn).fixedSize(horizontal: false, vertical: true)
    } else if item.verified {
        StatusChip("Verified", systemImage: "checkmark.shield", color: OC.ok).fixedSize()
        if item.hasSignedExpiry {
            let left = Fmt.timeLeft(item.expires)
            Text(verbatim: "expires " + Fmt.relative(item.expires)).font(OF.meta).foregroundStyle(OC.textMuted)
                .lineLimit(2).minimumScaleFactor(0.8).fixedSize(horizontal: false, vertical: true)   // wraps at AX sizes, never "expires in 1 w…"
            if left.urgent { StatusChip(left.text, systemImage: "clock", color: OC.warn).fixedSize() }
        } else {
            Text("no signed expiry").font(OF.meta).foregroundStyle(OC.textMuted)
        }
    } else {
        StatusChip("Metadata not verified", systemImage: "exclamationmark.triangle", color: OC.danger)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct DropItemScreen: View {
    let services: any AppServices
    let itemID: String

    var body: some View {
        let model = services.drop
        List {
            if let item = model.item(id: itemID) {
                let ws = model.workspaces.first { $0.id == item.workspaceID }
                Section {
                    VStack(alignment: .leading, spacing: OS.s2) {
                        if let ws { WorkspaceHeader(name: ws.name, color: ws.color, hostedBy: ws.hostedBy, clientHosted: ws.clientHosted) }
                        Text(verbatim: item.displayName).font(.title2.weight(.semibold))
                        Text(verbatim: item.verified ? "\(item.kind.rawValue.capitalized) · \(Fmt.bytes(item.bytes)) · from \(item.displayFrom)" : "Metadata not verified · from \(item.displayFrom)")
                            .font(OF.meta).foregroundStyle(OC.textMuted)
                    }
                }
                Section("Details") {
                    LabeledContent("Expires", value: item.hasSignedExpiry ? Fmt.relative(item.expires) : "No signed expiry")
                    if let mime = item.mime { LabeledContent("Type", value: mime) }
                    LabeledContent("Versions", value: "\(item.versions)")
                    LabeledContent("Direction", value: item.direction == .received ? "Received" : "Sending")
                }
                if item.quarantineJob != nil {
                    Section("Choose another destination") {
                        Text("The workspace this was meant for was removed from this iPhone. Nothing was sent. It is kept here until you pick where it goes, or it expires.")
                            .font(OF.meta).foregroundStyle(OC.textMuted)
                        ForEach(model.workspaces.filter { model.canSend(to: $0.id) }) { ws in
                            Button { model.redirectQuarantined(id: item.id, to: ws.id) } label: {
                                HStack {
                                    Image(systemName: "laptopcomputer").foregroundStyle(OC.textMuted)
                                    Text(verbatim: ws.displayName).foregroundStyle(OC.text)
                                }
                            }
                            .accessibilityIdentifier("drop.redirect.\(ws.id)")
                        }
                    }
                }
                if let drop = (services as? LiveServices)?.dropState(itemID) {
                    if let status = drop.status { Text(verbatim: status) }
                    if drop.objects[item.id]?.descriptor.recipients == .inbox {
                        Button("Claim") { Task { await drop.claim(item.id) } }
                            .disabled(!drop.canOperate).accessibilityIdentifier("drop.claim")
                    }
                    Button("Open") { Task { await drop.open(item.id) } }
                        .disabled(!drop.usable || !item.verified || item.bytes == 0 || item.outdated)
                        .accessibilityIdentifier("drop.open")
                }
                if let text = item.text {
                    Section(item.kind == .url ? "Link (shown as text, never opened)" : "Note") {
                        SafeTextView(text, style: .prose).accessibilityIdentifier("drop.item.text")
                    }
                } else {
                    Section {
                        Label(item.verified && item.bytes == 0 ? "This file is empty." : "Preview opens after the file is decrypted and checked.",
                              systemImage: "lock.doc").foregroundStyle(OC.textMuted)
                    }
                }
            } else {
                Text("This item is no longer available.")
            }
        }
        .navigationTitle("Item")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.markRead(id: itemID) }
        .task { await model.verifyDropRow(itemID) }
        .quickLookPreview(Binding(get: { (services as? LiveServices)?.dropState(itemID)?.previewURL },
                                 set: { (services as? LiveServices)?.dropState(itemID)?.previewURL = $0 }))
    }
}

// MARK: Compose (U11): destination first, then attachment, note, expiry

struct DropComposeSheet: View {
    let model: any DropModel
    let preset: String?
    let onSent: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var photoTask: Task<Void, Never>?
    @State private var importRevision = 0
    @State private var visible = false
    @State private var destination: String?
    @State private var attachments: [DropAttachment] = []
    @State private var note = ""
    @State private var photos: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var error: String?

    init(model: any DropModel, preset: String?, onSent: @escaping () -> Void) {
        self.model = model; self.preset = preset; self.onSent = onSent
        _destination = State(initialValue: preset)
    }

    private var total: Int { attachments.reduce(0) { $0 + $1.bytes } }
    private var destinationAvailable: Bool { model.workspaces.contains { $0.id == destination && model.canSend(to: $0.id) } }
    private var canSend: Bool { destinationAvailable && (!attachments.isEmpty || !note.isEmpty) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Demo: real encrypted transfers within this iPhone.", systemImage: "theatermasks")
                        .foregroundStyle(OC.demo)
                        .accessibilityIdentifier("drop.demoLabel")
                }
                Section("1. Send to") {
                    ForEach(model.workspaces.filter { model.canSend(to: $0.id) }) { ws in
                        Button { destination = ws.id } label: {
                            HStack {
                                Image(systemName: "laptopcomputer").foregroundStyle(OC.textMuted)
                                Text(verbatim: ws.displayName).foregroundStyle(OC.text)
                                if ws.isHosted { Image(systemName: "building.2").foregroundStyle(OC.hosted)
                                    .accessibilityLabel("Client hosted") }
                                Spacer()
                                if destination == ws.id { Image(systemName: "checkmark").foregroundStyle(OC.brand) }
                            }
                        }
                        .accessibilityIdentifier("drop.destination.\(ws.id)")
                        .accessibilityAddTraits(destination == ws.id ? .isSelected : [])
                    }
                }
                Section("2. Attachments (up to 5, 25 MB total)") {
                    ForEach(attachments) { a in
                        HStack {
                            Text(verbatim: SafeText.inline(a.name, limit: 40)).lineLimit(1)
                            Spacer()
                            Text(verbatim: Fmt.bytes(a.bytes)).font(OF.meta)
                        }
                    }
                    .onDelete { attachments.remove(atOffsets: $0) }
                    PhotosPicker(selection: $photos, maxSelectionCount: DropLimits.maxAttachments, matching: .any(of: [.images, .videos])) {
                        Label("Choose photos", systemImage: "photo")
                    }
                    .accessibilityIdentifier("drop.photos")
                    Button { importing = true } label: { Label("Choose files", systemImage: "folder") }
                        .accessibilityIdentifier("drop.files")
                    Button { add(DropAttachment(id: UUID(), name: "Sample file.txt", bytes: 12_000, isSample: true, data: Data(repeating: 65, count: 12_000))) } label: {
                        Label("Add a sample attachment", systemImage: "doc.badge.plus")
                    }
                    .accessibilityIdentifier("drop.sample")
                    if let error { Text(verbatim: error).font(OF.meta).foregroundStyle(OC.danger) }
                }
                Section("3. Note") {
                    TextField("Short note (optional)", text: $note, axis: .vertical).lineLimit(1...4)
                        .accessibilityIdentifier("drop.note")
                }
                Section("4. Expires") {
                    LabeledContent("Expires after", value: "7 days")
                }
            }
            .navigationTitle("Send to a workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("drop.cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        if let destination {
                            model.send(DropDraft(workspaceID: destination, attachments: attachments, note: note))
                            onSent(); dismiss()
                        }
                    }
                    .disabled(!canSend).accessibilityIdentifier("drop.send")
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard visible, scenePhase == .active, destinationAvailable, case .success(let urls) = result else { return }
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= DropLimits.maxBytes else { error = "That would be more than 25 MB."; continue }
                        let data = try Data(contentsOf: url)
                        add(DropAttachment(id: UUID(), name: url.lastPathComponent, bytes: data.count, data: data))
                    } catch { self.error = "Could not read this file." }
                }
            }
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                photoTask?.cancel(); importRevision += 1
                let mine = importRevision
                photos = []
                photoTask = Task { @MainActor in
                    for (i, item) in items.enumerated() {
                        guard !Task.isCancelled, visible, scenePhase == .active, destinationAvailable, mine == importRevision else { return }
                        let data = try? await item.loadTransferable(type: Data.self)
                        guard !Task.isCancelled, visible, scenePhase == .active, destinationAvailable, mine == importRevision else { return }
                        guard let data else { error = "Could not read this photo."; continue }
                        add(DropAttachment(id: UUID(), name: "Photo \(attachments.count + i + 1)", bytes: data.count, data: data))
                    }
                    if mine == importRevision { photoTask = nil }
                }
            }
        }
        .tint(OC.brand)
        .onAppear { visible = true }
        .onDisappear { visible = false; cancelImports() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { cancelImports() } }
        .onChange(of: destinationAvailable) { _, available in if !available { cancelImports() } }
    }

    private func cancelImports() {
        importRevision += 1; photoTask?.cancel(); photoTask = nil
        photos = []; attachments = []; note = ""; importing = false
    }

    private func add(_ a: DropAttachment) {
        if attachments.count >= DropLimits.maxAttachments { error = "You can send up to 5 attachments."; return }
        if total + a.bytes > DropLimits.maxBytes { error = "That would be more than 25 MB."; return }
        error = nil
        attachments.append(a)
    }
}
