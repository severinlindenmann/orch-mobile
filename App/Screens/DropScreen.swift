import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import OrchUI
import QuickLook

struct DropScreen: View {
    let services: any AppServices
    @State private var direction: DropDirection = .received
    @State private var composing: Bool

    init(services: any AppServices, startComposing: Bool = false) {
        self.services = services
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
                if let status = model.dropStatus { Text(verbatim: status).accessibilityIdentifier("drop.status") }
                let items = model.items(direction)
                if items.isEmpty {
                    Text(direction == .received ? "Nothing received yet." : "Nothing is being sent.")
                        .foregroundStyle(OC.textMuted)
                }
                ForEach(items) { item in
                    NavigationLink(value: Route.dropItem(item.id)) { DropRow(item: item, workspaces: model.workspaces) }
                        .accessibilityIdentifier("drop.item.\(item.presentationID)")
                        .task { await model.verifyDropRow(item.id) }
                }
            }
            Section {
                Label("Demo: real encrypted transfers within this iPhone.", systemImage: "info.circle")
                    .font(OF.meta).foregroundStyle(OC.demo).accessibilityIdentifier("drop.simulatedBanner")
                Text("Files and notes expire after 7 days. Links are shown as text and never opened for you.")
                    .font(OF.meta).foregroundStyle(OC.textMuted)

            }
        }
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
    let item: DropItem
    let workspaces: [WorkspaceInfo]

    var body: some View {
        let ws = workspaces.first { $0.id == item.workspaceID }
        HStack(spacing: OS.s3) {
            WorkspaceRail(color: ws?.color ?? OC.lineStrong).frame(height: 40).clipShape(Capsule())
            VStack(alignment: .leading, spacing: OS.s1) {
                HStack {
                    if item.unread { Circle().fill(OC.youMark).frame(width: 8, height: 8).accessibilityLabel("Unread") }
                    Text(verbatim: item.displayName).lineLimit(1)
                }
                Text(verbatim: item.verified ? "\(ws?.displayName ?? "") · \(Fmt.bytes(item.bytes)) · expires \(Fmt.relative(item.expires))" : "\(ws?.displayName ?? "") · Metadata not verified")
                    .font(OF.meta).foregroundStyle(OC.textMuted)
                if item.quarantineJob != nil {
                    Label("Destination removed. Choose another destination.", systemImage: "exclamationmark.triangle")
                        .font(OF.meta).foregroundStyle(OC.warn)
                } else if item.direction == .sending {
                    Label(item.simulatedDone ? "Sent (confirmed)" : "Sending…",
                          systemImage: item.simulatedDone ? "checkmark.circle" : "arrow.up.circle")
                        .font(OF.meta).foregroundStyle(item.simulatedDone ? OC.ok : OC.info)
                }
            }
        }
        .accessibilityElement(children: .combine)
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
                        Text(verbatim: "\(item.kind.rawValue.capitalized) · \(Fmt.bytes(item.bytes)) · from \(item.displayFrom)")
                            .font(OF.meta).foregroundStyle(OC.textMuted)
                    }
                }
                Section("Details") {
                    LabeledContent("Expires", value: Fmt.relative(item.expires))
                    LabeledContent("Versions", value: "\(item.versions)")
                    LabeledContent("Direction", value: item.direction == .received ? "Received" : "Sending")
                }
                if item.quarantineJob != nil {
                    Section("Choose another destination") {
                        Text("The workspace this was meant for was removed from this iPhone. Nothing was sent. It is kept here until you pick where it goes, or it expires.")
                            .font(OF.meta).foregroundStyle(OC.textMuted)
                        ForEach(model.workspaces.filter { $0.lifecycle == .live }) { ws in
                            Button { model.redirectQuarantined(id: item.id, to: ws.id) } label: {
                                HStack {
                                    WorkspaceRail(color: ws.color).frame(height: 24).clipShape(Capsule())
                                    Text(verbatim: ws.displayName).foregroundStyle(OC.text)
                                }
                            }
                            .accessibilityIdentifier("drop.redirect.\(ws.id)")
                        }
                    }
                }
                if let drop = (services as? LiveServices)?.dropState(itemID) {
                    if let status = drop.status { Text(verbatim: status) }
                    Button("Open") { Task { await drop.open(item.id) } }
                        .disabled(!drop.usable || !item.verified || item.bytes == 0)
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
    private var canSend: Bool { model.workspaces.contains { $0.id == destination && $0.lifecycle == .live } && (!attachments.isEmpty || !note.isEmpty) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Demo: real encrypted transfers within this iPhone.", systemImage: "theatermasks")
                        .foregroundStyle(OC.demo)
                        .accessibilityIdentifier("drop.demoLabel")
                }
                Section("1. Send to") {
                    ForEach(model.workspaces.filter { $0.lifecycle == .live }) { ws in
                        Button { destination = ws.id } label: {
                            HStack {
                                WorkspaceRail(color: ws.color).frame(height: 24).clipShape(Capsule())
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
                    Button { add(DropAttachment(id: UUID(), name: "Sample file (not a real pick)", bytes: 12_000, isSample: true)) } label: {
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
                guard case .success(let urls) = result else { return }
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    add(DropAttachment(id: UUID(), name: url.lastPathComponent, bytes: size))
                }
            }
            .onChange(of: photos) { _, items in
                let picked = items
                photos = []
                Task {
                    for (i, item) in picked.enumerated() {
                        // Real size from the picked data; nothing is invented.
                        let data = try? await item.loadTransferable(type: Data.self)
                        add(DropAttachment(id: UUID(), name: "Photo \(attachments.count + i + 1)", bytes: data?.count ?? 0))
                    }
                }
            }
        }
        .tint(OC.brand)
    }

    private func add(_ a: DropAttachment) {
        if attachments.count >= DropLimits.maxAttachments { error = "You can send up to 5 attachments."; return }
        if total + a.bytes > DropLimits.maxBytes { error = "That would be more than 25 MB."; return }
        error = nil
        attachments.append(a)
    }
}
