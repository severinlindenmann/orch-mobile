import SwiftUI
import OrchUI

/// Compose a ticket (C2b, R2 title-only): a type and a one-line title, checked as typed. "Review" reads the workspace afresh for the next
/// key and opens the creation sheet, which shows exactly what is signed (type, title, owner) and discloses that the key is assigned when
/// sent. Sign is armed only after the whole sheet was scrolled to its end and 800 ms passed. A signed creation is settled, never signed
/// again from here; a draft that is still being checked shows that when the form is opened again.
struct NewTicketSheet: View {
    let model: any WorkspaceModel
    let onClose: () -> Void
    @State private var type = "feature"
    @State private var title = ""
    @State private var reviewing = false
    @State private var error: String?
    @State private var review: CreationValue?
    @State private var phase: CreationPhase = .ready
    @State private var loaded = false

    private var problem: String? { title.isEmpty ? nil : LiveWorkspace.titleProblem(title) }

    var body: some View {
        NavigationStack {
            Group {
                if let review { CreationSheet(review: review, phase: $phase, model: model, onClose: onClose, onReviewAgain: reviewAgain) }
                else if phase == .checking || phase == .createdUnconfirmed { checkingForm }
                else if let outcome = CreationOutcome(phase) { settledForm(outcome) }
                else { form }
            }
            .navigationTitle(review == nil ? "New ticket" : "Review the ticket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onClose).accessibilityIdentifier("ticket.new.cancel").disabled(phase == .sending)
                }
            }
        }
        .interactiveDismissDisabled(phase == .sending)
        .onAppear(perform: loadDraft)
    }

    private var form: some View {
        Form {
            Section("Type") {
                Picker("Type", selection: $type) {
                    ForEach(TicketTypes.all, id: \.self) { t in Text(TicketTypes.label(t)).tag(t) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("ticket.new.type")
            }
            Section {
                TextField("Title", text: $title).accessibilityIdentifier("ticket.new.title")
                if let problem {
                    Label { Text(verbatim: problem) } icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(OF.meta).foregroundStyle(OC.warn).accessibilityIdentifier("ticket.new.titleError")
                }
            } header: { Text("Title") } footer: {
                Text("One line. Details, description and epic are added on your Mac.")
            }
            if let error {
                Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .foregroundStyle(OC.warn).accessibilityIdentifier("ticket.new.error")
            }
            Section {
                Button { Task { await startReview() } } label: {
                    if reviewing { ProgressView("Reading the workspace…") } else { Text("Review") }
                }
                .disabled(title.isEmpty || problem != nil || reviewing || !model.canCreateTickets)
                .accessibilityIdentifier("ticket.new.review")
            } footer: {
                Text("You see exactly what is signed before you sign it. The host assigns the ticket's key when it is created.")
            }
        }
    }

    private var checkingForm: some View {
        Form {
            Section {
                Label(phase == .createdUnconfirmed ? "Your ticket was created; not yet confirmed" : "Checking whether your ticket was created",
                      systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(OC.info).accessibilityIdentifier("ticket.new.checking")
                Text(verbatim: SafeText.inline(title, limit: 200)).font(OF.body)
                Text("It is not signed or sent again until this is settled.").font(OF.meta).foregroundStyle(OC.textMuted)
                Button("Check again") { Task { await recheck() } }
                    .accessibilityIdentifier("ticket.new.recheck")
                Button("Close and keep checking", action: onClose).accessibilityIdentifier("ticket.new.closeChecking")
            }
        }
    }

    /// A creation settled from the form (after the sheet was closed or the app relaunched): its result, never the form with the signed
    /// title and Review again. Only "Not created; review again" leads back to the form; a landing offers a new, empty ticket.
    private func settledForm(_ outcome: CreationOutcome) -> some View {
        Form {
            Section {
                outcome.view
                if case .needsReview = phase {
                    Button("Review again") { phase = .ready }.accessibilityIdentifier("ticket.new.reviewAgain")
                } else {
                    Button("Done", action: onClose).accessibilityIdentifier("ticket.new.done")
                    Button("New ticket") { phase = .ready }.accessibilityIdentifier("ticket.new.another")
                }
            }
        }
    }

    /// Settles the pending creation again (reads only). Once it is settled for good (landed, exists, refused) the signed title and type
    /// are gone from the form: a new ticket starts empty, under a new review.
    private func recheck() async {
        let p = await model.checkCreation()
        switch p {
        case .created, .resentAfterChange, .landedUnconfirmed, .ticketExists, .refused:
            title = ""; type = "feature"; phase = p
        case .notSent(let message):
            // nothing is pending any more (settled elsewhere): start empty, never with the signed title
            title = ""; type = "feature"; error = message; phase = .ready
        default:
            phase = p
        }
    }

    private func loadDraft() {
        guard !loaded else { return }
        loaded = true
        guard let d = model.loadCreationDraft() else { return }
        if TicketTypes.all.contains(d.type) { type = d.type }
        title = d.title
        if d.pending { phase = .checking }
    }

    private func startReview() async {
        reviewing = true; defer { reviewing = false }
        error = nil
        switch await model.reviewCreation(type: type, title: title) {
        case .reviewed(let v): phase = .ready; review = v
        case .failed(let message): error = message
        }
    }

    private func reviewAgain() {
        review = nil
        phase = .ready
    }
}

private struct CreationArmKey: Hashable { let atEnd: Bool; let revision: Int }

/// The creation arming sheet: everything signed (type, title, owner), the key disclosure, and the signed details. The same arming rule
/// as the answer sheet: scroll to the end, then 800 ms.
struct CreationSheet: View {
    let review: CreationValue
    @Binding var phase: CreationPhase
    let model: any WorkspaceModel
    let onClose: () -> Void
    let onReviewAgain: () -> Void
    @State private var atEndRevision: Int?
    @State private var armedRevision: Int?

    var body: some View {
        VStack(spacing: 0) {
            if review.isDemo { DemoStripe() }
            ScrollView {
                VStack(alignment: .leading, spacing: OS.s4) {
                    AdaptiveStack {
                        WorkspaceHeader(name: review.workspaceName, color: OC.wsHues[review.hue % OC.wsHues.count], hostedBy: nil, clientHosted: false)
                        if review.isDemo { DemoChip() }
                    }
                    Text("You are creating").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: OS.s2) {
                        row("Type", TicketTypes.label(review.ticketType), id: "create.type")
                        VStack(alignment: .leading, spacing: OS.s1) {
                            Text("Title").font(OF.meta).foregroundStyle(OC.textFaint)
                            SafeTextView(review.title).accessibilityIdentifier("create.title")
                        }
                        row("Owner", "You (\(SafeText.inline(review.owner, limit: 20)))", id: "create.owner")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(OS.s3)
                    .background(OC.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Label { Text(verbatim: review.disclosure) } icon: { Image(systemName: "number") }
                        .font(OF.body).accessibilityIdentifier("create.disclosure")
                    Text("If another ticket takes that key first, orch signs again with the next free key, without changing anything else.")
                        .font(OF.meta).foregroundStyle(OC.textMuted)
                    if review.hasUnsafeContent {
                        Label("The title contains characters that cannot be seen or that look like other characters. They are marked in orange.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(OF.meta).foregroundStyle(OC.warn).accessibilityIdentifier("create.unsafeNotice")
                    }
                    VStack(alignment: .leading, spacing: OS.s1) {
                        Text("Signed details").font(.footnote.weight(.bold)).foregroundStyle(OC.textMuted)
                        Text(verbatim: "Owner \(SafeText.inline(review.owner, limit: 200))").font(.system(.footnote, design: .monospaced))
                        Text(verbatim: "Ticket uid \(review.uid)").font(.system(.footnote, design: .monospaced))
                        Text(verbatim: "Workspace \(review.workspaceID)").font(.system(.footnote, design: .monospaced))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("create.details")
                    footer
                }
                .padding(OS.s4)
            }
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 4
            } action: { _, reached in
                if reached { atEndRevision = review.revision }
            }
            .scrollBounceBehavior(.basedOnSize)
            .id(review.revision)
            .task(id: CreationArmKey(atEnd: atEndRevision == review.revision, revision: review.revision)) {
                armedRevision = nil
                guard atEndRevision == review.revision else { return }
                try? await Task.sleep(for: .milliseconds(800))
                if !Task.isCancelled { armedRevision = review.revision }
            }
        }
        .background(OC.bg)
        .transaction { $0.animation = nil }
    }

    private func row(_ name: String, _ value: String, id: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).font(OF.meta).foregroundStyle(OC.textFaint).frame(width: 64, alignment: .leading)
            Text(verbatim: value).font(OF.body)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: OS.s3) {
            switch phase {
            case .ready where review.hasUnsafeContent:
                // fail closed like the answer sheet's refusal (#86): hidden or look-alike characters in anything the signature binds or the
                // sheet shows (the title, the workspace name) mean there is no Sign button. The draft stays; the person edits the title.
                state("exclamationmark.octagon", OC.danger, "Can't be checked here",
                      "The title or the workspace name has characters you cannot see or that look like other letters. Change the title, or create the ticket on your Mac.",
                      id: "create.refused")
                Button(role: .cancel, action: onClose) { Text("Cancel").frame(maxWidth: .infinity, minHeight: 44) }
                    .foregroundStyle(OC.brand).accessibilityIdentifier("create.cancel")
            case .ready:
                Button { Task { await sign() } } label: { Label("Sign and create", systemImage: "signature") }
                    .buttonStyle(.orchProminent)
                    .disabled(armedRevision != review.revision)
                    .accessibilityIdentifier("create.confirm")
                    .accessibilityHint(armedRevision == review.revision ? "Signs and creates the ticket" : "Scroll to the end to continue")
                if armedRevision != review.revision {
                    Text(atEndRevision == review.revision ? "Hold on…" : "Scroll to the end to continue")
                        .font(OF.meta).foregroundStyle(OC.textMuted).accessibilityIdentifier("create.hint")
                }
                Button(role: .cancel, action: onClose) { Text("Cancel").frame(maxWidth: .infinity, minHeight: 44) }
                    .foregroundStyle(OC.brand).accessibilityIdentifier("create.cancel")
            case .sending:
                ProgressView("Sending…").accessibilityIdentifier("create.sending")
            case .created, .resentAfterChange, .landedUnconfirmed, .refused, .ticketExists:
                CreationOutcome(phase)?.view
                done
            case .checking, .createdUnconfirmed:
                state("clock.arrow.circlepath", OC.info,
                      phase == .createdUnconfirmed ? "Your ticket was created; not yet confirmed" : "Checking whether your ticket was created",
                      "It is not signed or sent again until this is settled. If you close this, orch keeps checking.", id: "create.checking")
                Button("Check again") { Task { phase = await model.checkCreation() } }.buttonStyle(.bordered).accessibilityIdentifier("create.recheck")
                Button("Close and keep checking", action: onClose).accessibilityIdentifier("create.closeChecking")
            case .needsReview:
                CreationOutcome(phase)?.view
                Button("Review again", action: onReviewAgain).buttonStyle(.orchProminent).accessibilityIdentifier("create.reviewAgain")
            case .unlockToContinue:
                state("lock.fill", OC.warn, "Unlock to continue", "Unlock this iPhone, then review the ticket again.", id: "create.unlock")
                Button("Review again", action: onReviewAgain).buttonStyle(.bordered).accessibilityIdentifier("create.reviewAgain")
            case .invalidated:
                state("hourglass.bottomhalf.filled", OC.warn, "Review expired", "Review the ticket again before you sign.", id: "create.invalidated")
                Button("Review again", action: onReviewAgain).buttonStyle(.orchProminent).accessibilityIdentifier("create.reviewAgain")
            case .notSent(let message):
                state("wifi.exclamationmark", OC.warn, "Not sent", message, id: "create.notSent")
                Button("Review again", action: onReviewAgain).buttonStyle(.bordered).accessibilityIdentifier("create.reviewAgain")
            }
            Text(review.isDemo ? "Demo key (passphrase custody, this app only)." : "Signed by this iPhone's Secure Enclave key.")
                .font(OF.meta).foregroundStyle(OC.textMuted).multilineTextAlignment(.center)
                .accessibilityIdentifier("create.footnote")
        }
    }

    private var done: some View {
        Button(action: onClose) { Text("Done") }.buttonStyle(.orchProminent).accessibilityIdentifier("create.done")
    }

    private func state(_ icon: String, _ color: Color, _ title: String, _ detail: String, id: String) -> some View {
        CreationOutcome(icon: icon, color: color, title: title, detail: detail, id: id).view
    }

    private func sign() async {
        guard phase == .ready, armedRevision == review.revision else { return }
        phase = .sending
        phase = await model.create(review)
    }
}

/// How a settled creation reads, the same in the creation sheet and in the form that settles it after a relaunch.
@MainActor
struct CreationOutcome {
    let icon: String, color: Color, title: String, detail: String, id: String

    init(icon: String, color: Color, title: String, detail: String, id: String) {
        self.icon = icon; self.color = color; self.title = title; self.detail = detail; self.id = id
    }

    /// nil for a phase that is not settled (ready, sending, checking) or that leads back to a review (unlock, expired, not sent).
    init?(_ phase: CreationPhase) {
        switch phase {
        case .created(let key):
            self.init(icon: "checkmark.seal.fill", color: OC.ok, title: "Created \(SafeText.inline(key, limit: 24))",
                      detail: "The host created the ticket you signed.", id: "create.created")
        case .resentAfterChange(let key):
            self.init(icon: "checkmark.seal.fill", color: OC.ok, title: "The workspace changed; sent again (\(SafeText.inline(key, limit: 24)))",
                      detail: "Another ticket took the key first, so yours was signed again with the next key. Nothing else changed.", id: "create.resent")
        case .landedUnconfirmed:
            self.init(icon: "checkmark.circle", color: OC.ok, title: "Sent and recorded",
                      detail: "The ticket was created. It can't be shown here as signed.", id: "create.landedUnconfirmed")
        case .needsReview(let message):
            self.init(icon: "arrow.triangle.2.circlepath", color: OC.warn, title: "Not created; review again", detail: message, id: "create.needsReview")
        case .refused:
            self.init(icon: "eye.slash", color: OC.warn, title: "The ticket wasn't created",
                      detail: "The host refused it for good. Nothing is sent again.", id: "create.refused")
        case .ticketExists(let key):
            // none of this review's attempts can be named as its creator: it may still be the one sent from here
            self.init(icon: "doc.on.doc", color: OC.info,
                      title: key.map { "This ticket already exists (\(SafeText.inline($0, limit: 24)))" } ?? "This ticket already exists",
                      detail: "It may be the one you sent; check on your Mac.", id: "create.ticketExists")
        case .ready, .sending, .checking, .createdUnconfirmed, .unlockToContinue, .invalidated, .notSent:
            return nil
        }
    }

    var view: some View {
        VStack(spacing: OS.s2) {
            Image(systemName: icon).font(.title).foregroundStyle(color)
            Text(verbatim: title).font(OF.section).multilineTextAlignment(.center)
            Text(verbatim: detail).font(OF.body).foregroundStyle(OC.textMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }
}
