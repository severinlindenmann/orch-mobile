import SwiftUI
import OrchUI

struct WorkspaceScreen: View {
    let services: any AppServices
    let workspaceID: String
    @State private var segment: WorkspaceSegment
    @State private var model: any WorkspaceModel
    @State private var composing = false
    @State private var newTicket = false
    @Environment(\.dynamicTypeSize) private var typeSize

    init(services: any AppServices, workspaceID: String, segment: WorkspaceSegment) {
        self.services = services
        self.workspaceID = workspaceID
        _segment = State(initialValue: segment)
        _model = State(initialValue: services.workspace(workspaceID))
    }

    private var segments: [WorkspaceSegment] {
        WorkspaceSegment.allCases.filter { ($0 != .terminal || model.info.allowsTerminal) && ($0 != .files || services.capabilities.drop) }
    }

    var body: some View {
        List {
            Section {
                header.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
            switch segment {
            case .questions: questions
            case .tickets: tickets
            case .files where services.capabilities.drop: files
            case .files: Section { RouteUnavailable(text: "Files aren't available for this workspace realm.") }
            case .terminal: terminal
            }
        }
        .navigationTitle(model.info.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.workspaceSettings(workspaceID, confirmLeave: false)) {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(Text(verbatim: "\(model.info.displayName) settings"))
                .accessibilityIdentifier("ws.settings")
            }
        }
        .sheet(isPresented: $newTicket) { NewTicketSheet(model: model) { newTicket = false } }
        .sheet(isPresented: $composing) {
            if services.capabilities.drop { DropComposeSheet(model: services.drop, preset: workspaceID) {} }
        }
        .task(id: segment) {
            if segment == .files, services.capabilities.drop { await services.drop.refreshDrop() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: OS.s2) {
            WorkspaceHeader(name: model.info.name, color: model.info.color, hostedBy: model.info.hostedBy,
                            clientHosted: model.info.clientHosted)
            AdaptiveStack {
                ConnectionChip(state: model.info.connection)
                if let message = model.info.lifecycle.message { Text(verbatim: message).font(OF.meta).foregroundStyle(OC.textMuted) }
                if let alarm = model.info.keyAlarm {
                    Text(verbatim: alarm).font(OF.meta).foregroundStyle(OC.danger).accessibilityIdentifier("ws.keyAlarm")
                }
                Text(verbatim: model.info.displayHost).font(OF.meta).foregroundStyle(OC.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let block = model.info.answerBlock, model.info.scopes.contains(.decide) {
                Text(verbatim: block).font(OF.meta).foregroundStyle(OC.textMuted)
            }
            segmentControl
        }
        .padding(.vertical, OS.s2)
    }

    @ViewBuilder
    private var segmentControl: some View {
        if typeSize.isAccessibilitySize {
            Menu {
                ForEach(segments, id: \.self) { s in
                    Button(s.title) { segment = s }.accessibilityIdentifier("ws.segment.\(s.rawValue)")
                }
            } label: {
                Label(segment.title, systemImage: "list.bullet").frame(maxWidth: .infinity, alignment: .leading)
                    .padding(OS.s3).background(OC.surface2, in: RoundedRectangle(cornerRadius: OR.control, style: .continuous))
            }
            .accessibilityIdentifier("ws.segment.menu")
            .accessibilityLabel(Text(verbatim: "Section: \(segment.title)"))
        } else {
            HStack(spacing: 2) {
                ForEach(segments, id: \.self) { s in
                    Button { segment = s } label: {
                        Text(s.title).font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity).padding(.vertical, OS.s2)
                            .background(segment == s ? OC.surface : Color.clear,
                                        in: RoundedRectangle(cornerRadius: OR.control - 2, style: .continuous))
                            .foregroundStyle(segment == s ? OC.text : OC.textMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ws.segment.\(s.rawValue)")
                    .accessibilityAddTraits(segment == s ? .isSelected : [])
                }
            }
            .padding(2)
            .background(OC.surface2, in: RoundedRectangle(cornerRadius: OR.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: OR.control, style: .continuous).strokeBorder(OC.line))
        }
    }

    // MARK: Questions

    @ViewBuilder
    private var questions: some View {
        Section("Waiting") {
            if model.macOnlyCount > 0 {
                Label(model.macOnlyCount == 1 ? "1 question needs your Mac" : "\(model.macOnlyCount) questions need your Mac", systemImage: "desktopcomputer")
                    .font(OF.meta).foregroundStyle(OC.warn).accessibilityIdentifier("ws.macOnly")
            }
            if model.waiting.isEmpty, model.macOnlyCount == 0 {
                Text(model.info.isLive ? "Nothing needs you here." : "Nothing was waiting when last checked.")
                    .foregroundStyle(OC.textMuted)
            }
            ForEach(model.waiting) { q in
                NavigationLink(value: Route.question(workspace: workspaceID, id: q.id, autoSign: false)) {
                    QuestionRow(question: q, color: model.info.color, workspaceName: model.info.displayName)
                }
                .accessibilityIdentifier("question.\(q.id)")
            }
        }
        Section("Answered") {
            if model.answered.isEmpty { Text("No answered questions yet.").foregroundStyle(OC.textMuted) }
            ForEach(model.answered) { q in
                NavigationLink(value: Route.question(workspace: workspaceID, id: q.id, autoSign: false)) {
                    VStack(alignment: .leading, spacing: OS.s1) {
                        Text(verbatim: q.firstLine).lineLimit(2)
                        Label { Text(verbatim: "Answered by \(SafeText.inline(q.resolution?.byDeviceLabel ?? "", limit: 40)) · \(q.resolution.map { Fmt.relative($0.at) } ?? "")") }
                            icon: { Image(systemName: "checkmark.circle") }
                            .font(OF.meta).foregroundStyle(OC.ok)
                    }
                    .accessibilityElement(children: .combine)
                }
                .accessibilityIdentifier("question.\(q.id)")
            }
        }
    }

    // MARK: Tickets

    @ViewBuilder
    private var tickets: some View {
        Section("Tickets") {
            if model.canCreateTickets {
                Button { newTicket = true } label: { Label("New ticket", systemImage: "plus") }
                    .accessibilityIdentifier("ws.newTicket")
            }
            ForEach(model.tickets) { t in
                NavigationLink(value: Route.ticket(workspace: workspaceID, key: t.key)) {
                    TicketRow(ticket: t, progress: t.kind == .factoryEpic ? model.epicProgress(for: t.key) : nil)
                }
                .accessibilityIdentifier("ticket.\(t.key)")
            }
            if model.ticketsIncomplete {
                Text("Showing the newest tickets only. The full list is on your Mac.").font(OF.meta).foregroundStyle(OC.textMuted)
                    .accessibilityIdentifier("ws.ticketsIncomplete")
            }
        }
    }

    // MARK: Files (this workspace's Drop items)

    @ViewBuilder
    private var files: some View {
        let items = services.drop.items(workspace: workspaceID)
        Section {
            Button { composing = true } label: {
                Label { Text(verbatim: "Send to \(model.info.displayName)") } icon: { Image(systemName: "square.and.arrow.up") }
            }
            .accessibilityIdentifier("ws.files.send")
            TabAwareLink(route: .drop) { Text("Open Drop") }
                .accessibilityIdentifier("ws.files.openDrop")
        }
        Section("Files and notes in Drop") {
            if items.isEmpty { Text("Nothing in Drop for this workspace.").foregroundStyle(OC.textMuted) }
            ForEach(items) { item in
                NavigationLink(value: Route.dropItem(item.id)) { DropRow(item: item, workspaces: services.drop.workspaces) }
                    .accessibilityIdentifier("ws.file.\(item.presentationID)")
                    .task(id: services.drop.dropRefreshRevision) { await services.drop.verifyDropRow(item.id) }
            }
        }
    }

    @ViewBuilder
    private var terminal: some View {
        Section {
            EmptyState(systemImage: "terminal", title: "Later",
                       detail: "A terminal for this workspace is not part of this version.")
                .accessibilityIdentifier("ws.terminal.later")
        }
    }
}

struct TicketRow: View {
    let ticket: Ticket
    let progress: EpicProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: OS.s2) {
            HStack {
                Text(verbatim: ticket.displayKey).font(OF.machine).foregroundStyle(OC.textMuted)
                if ticket.kind == .factoryEpic {
                    StatusChip("Factory epic", systemImage: "gearshape.2", color: OC.brand)
                }
                Spacer(minLength: 0)
            }
            Text(verbatim: ticket.displayTitle)
            HStack {
                TicketStateChip(state: ticket.state)
                if let progress, progress.total > 0 {
                    Text(verbatim: "\(progress.done) of \(progress.total) done").font(OF.meta).foregroundStyle(OC.textMuted)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct TicketStateChip: View {
    let state: TicketState
    var body: some View {
        switch state {
        case .open: StatusChip("Open", systemImage: "circle", color: OC.textMuted)
        case .inProgress: StatusChip("In progress", systemImage: "circle.lefthalf.filled", color: OC.brand)
        case .done: StatusChip("Done", systemImage: "checkmark.circle.fill", color: OC.ok)
        }
    }
}

struct TicketScreen: View {
    let services: any AppServices
    let workspaceID: String
    let key: String

    var body: some View {
        let model = services.workspace(workspaceID)
        List {
            if let t = model.ticket(key: key) {
                Section {
                    VStack(alignment: .leading, spacing: OS.s3) {
                        Text(verbatim: t.displayKey).font(OF.machine).foregroundStyle(OC.textMuted)
                        Text(verbatim: t.displayTitle).font(.title2.weight(.semibold))
                        TicketStateChip(state: t.state)
                        SafeTextView(t.body, style: .prose)
                        Text(verbatim: "Updated \(Fmt.relative(t.updated))").font(OF.meta).foregroundStyle(OC.textMuted)
                    }
                }
                if t.kind == .factoryEpic {
                    let p = model.epicProgress(for: t.key)
                    Section("Epic progress") {
                        ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                            .accessibilityLabel("Epic progress")
                            .accessibilityValue(Text(verbatim: "\(p.done) of \(p.total) tickets done"))
                            .accessibilityIdentifier("ticket.epicProgress")
                        Text(verbatim: "\(p.done) of \(p.total) tickets done").font(OF.meta)
                        ForEach(model.children(of: t.key)) { child in
                            NavigationLink(value: Route.ticket(workspace: workspaceID, key: child.key)) {
                                TicketRow(ticket: child, progress: nil)
                            }
                        }
                    }
                } else if let epic = t.epicKey {
                    Section("Part of") {
                        NavigationLink(value: Route.ticket(workspace: workspaceID, key: epic)) {
                            Label { Text(verbatim: "\(SafeText.inline(epic, limit: 24)) · \(model.ticket(key: epic)?.displayTitle ?? "")") }
                                icon: { Image(systemName: "gearshape.2") }
                        }
                    }
                }
            } else {
                Text("This ticket is no longer available.")
            }
        }
        .navigationTitle(Text(verbatim: SafeText.inline(key, limit: 24)))
        .navigationBarTitleDisplayMode(.inline)
    }
}
