import SwiftUI
import OrchUI

struct WorkspaceScreen: View {
    let services: any AppServices
    let workspaceID: String
    @State private var segment: WorkspaceSegment
    @State private var model: any WorkspaceModel
    @Environment(\.dynamicTypeSize) private var typeSize

    init(services: any AppServices, workspaceID: String, segment: WorkspaceSegment) {
        self.services = services
        self.workspaceID = workspaceID
        _segment = State(initialValue: segment)
        _model = State(initialValue: services.workspace(workspaceID))
    }

    private var segments: [WorkspaceSegment] {
        model.info.allowsTerminal ? WorkspaceSegment.allCases : WorkspaceSegment.allCases.filter { $0 != .terminal }
    }

    var body: some View {
        List {
            Section {
                header.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
            switch segment {
            case .questions: questions
            case .tickets: tickets
            case .files: files
            case .terminal: terminal
            }
        }
        .navigationTitle(model.info.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.workspaceSettings(workspaceID, confirmLeave: false)) {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("\(model.info.name) settings")
                .accessibilityIdentifier("ws.settings")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: OS.s3) {
            WorkspaceHeader(name: model.info.name, color: model.info.color, hostedBy: model.info.hostedBy,
                            clientHosted: model.info.clientHosted)
            HStack {
                Label(model.info.host, systemImage: "laptopcomputer").font(OF.meta).foregroundStyle(OC.textMuted)
                Spacer(minLength: 0)
            }
            ConnectionChip(state: model.info.connection)
            if case .offline = model.info.connection {
                Text("Saved copy · answers are off until you're back")
                    .font(OF.meta).foregroundStyle(OC.textMuted)
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
            .accessibilityLabel("Section: \(segment.title)")
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
            if model.waiting.isEmpty {
                Text("Nothing needs you here.").foregroundStyle(OC.textMuted)
            }
            ForEach(model.waiting) { q in
                NavigationLink(value: Route.question(workspace: workspaceID, id: q.id, autoSign: false)) {
                    HStack {
                        AttentionRail().frame(height: 36)
                        QuestionRow(question: q, color: model.info.color, workspaceName: model.info.name)
                    }
                }
                .accessibilityIdentifier("question.\(q.id)")
            }
        }
        Section("Answered") {
            if model.answered.isEmpty { Text("No answered questions yet.").foregroundStyle(OC.textMuted) }
            ForEach(model.answered) { q in
                NavigationLink(value: Route.question(workspace: workspaceID, id: q.id, autoSign: false)) {
                    VStack(alignment: .leading, spacing: OS.s1) {
                        Text(q.firstLine).lineLimit(2)
                        Label { Text(verbatim: "Answered by \(SafeText.inline(q.resolution?.byDeviceLabel ?? "")) · \(q.resolution.map { Fmt.relative($0.at) } ?? "")") } icon: { Image(systemName: "checkmark.circle") }.font(OF.meta).foregroundStyle(OC.ok)
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
            ForEach(model.tickets) { t in
                NavigationLink(value: Route.ticket(workspace: workspaceID, key: t.key)) {
                    TicketRow(ticket: t, progress: t.kind == .factoryEpic ? model.epicProgress(for: t.key) : nil)
                }
                .accessibilityIdentifier("ticket.\(t.key)")
            }
        }
    }

    // MARK: Files / Terminal

    @ViewBuilder
    private var files: some View {
        Section {
            VStack(alignment: .leading, spacing: OS.s3) {
                Label("Files travel through Drop", systemImage: "tray.and.arrow.down").font(OF.section)
                Text(verbatim: "Files and notes for \(model.info.name) are sent and received in Drop, so they stay encrypted for this workspace.")
                    .font(OF.body).foregroundStyle(OC.textMuted)
                NavigationLink(value: Route.drop) { Text("Open Drop").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("ws.files.openDrop")
            }
            .padding(.vertical, OS.s2)
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
                Text(ticket.key).font(OF.machine).foregroundStyle(OC.textMuted)
                if ticket.kind == .factoryEpic {
                    StatusChip("Factory epic", systemImage: "gearshape.2", color: OC.brand)
                }
                Spacer(minLength: 0)
            }
            Text(ticket.title)
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
                        Text(t.key).font(OF.machine).foregroundStyle(OC.textMuted)
                        Text(t.title).font(.title2.weight(.semibold))
                        TicketStateChip(state: t.state)
                        SafeTextView(t.body).font(OF.body)
                        Text(verbatim: "Updated \(Fmt.relative(t.updated))").font(OF.meta).foregroundStyle(OC.textMuted)
                    }
                }
                if t.kind == .factoryEpic {
                    let p = model.epicProgress(for: t.key)
                    Section("Epic progress") {
                        ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                            .accessibilityLabel("Epic progress")
                            .accessibilityValue("\(p.done) of \(p.total) tickets done")
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
                            Label { Text(verbatim: "\(epic) · \(model.ticket(key: epic)?.title ?? "")") } icon: { Image(systemName: "gearshape.2") }
                        }
                    }
                }
            } else {
                Text("This ticket is no longer available.")
            }
        }
        .navigationTitle(key)
        .navigationBarTitleDisplayMode(.inline)
    }
}
