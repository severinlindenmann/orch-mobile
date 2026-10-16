import SwiftUI
import OrchUI
import OrchProtocol

// B10 phase 1: "Approve on your phone". Minimal UI (logic first; a design pass may polish it).
//
// Wording rules (contract (e)): what the host merely says carries "per host, not signed"; what was recomputed is shown as content; no word
// about how strong a signature is. The person chooses Approve or Request changes; neither is pre-selected from the request.

/// The "Approvals waiting" section of the Questions tab.
struct ApprovalsSection: View {
    let services: any AppServices

    var body: some View {
        ForEach(services.home.approvalGroups) { group in
            Section {
                ForEach(group.requests) { r in
                    NavigationLink(value: Route.approval(workspace: group.workspace.id, id: r.id)) {
                        ApprovalRow(request: r)
                    }
                    .accessibilityIdentifier("approval.\(r.id)")
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Approvals waiting").font(OF.section).foregroundStyle(OC.text)
                    Text(verbatim: group.workspace.displayName).font(OF.meta).foregroundStyle(OC.textMuted)
                }
                .textCase(nil)
            } footer: {
                Text(ApprovalRequest.origin).font(OF.meta)
            }
        }
    }
}

struct ApprovalRow: View {
    let request: ApprovalRequest
    var body: some View {
        VStack(alignment: .leading, spacing: OS.s1) {
            Text(verbatim: "Approve the \(request.gateName)").font(OF.body)
            SafeTextView("\(request.ref) · \(request.title)").font(OF.meta).foregroundStyle(OC.textMuted)
            Text("\(ApprovalReviewValue.perHost) · \(ApprovalRequest.origin)").font(OF.meta).foregroundStyle(OC.textFaint)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Reads the gate behind a request, shows what the phone recomputed, and lets the person choose.
struct ApprovalReviewScreen: View {
    let services: any AppServices
    let workspaceID: String
    let requestID: String

    @State private var load: Load = .loading
    @State private var phase: ApprovalPhase?
    @State private var asking = false
    @State private var changeText = ""
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    enum Load: Equatable { case loading, ready(ApprovalReviewValue), failed(String) }

    private var model: any WorkspaceModel { services.workspace(workspaceID) }
    private var request: ApprovalRequest? { model.approvals.first { $0.id == requestID } }

    var body: some View {
        List {
            switch load {
            case .loading:
                ProgressView("Reading and checking").accessibilityIdentifier("approval.loading")
            case .failed(let message):
                Section {
                    Text(verbatim: message).accessibilityIdentifier("approval.failed")
                    Button("Reopen") { Task { await open() } }
                }
            case .ready(let v):
                content(v)
            }
        }
        .scrollContentBackground(.hidden)
        .background(OC.bg)
        .navigationTitle("Approval")
        .navigationBarTitleDisplayMode(.inline)
        .task { await open() }
    }

    private func open() async {
        phase = nil; asking = false; changeText = ""
        load = .loading
        if request == nil { await model.refreshApprovals() }
        guard let r = request else { load = .failed("This request is gone. It may have been answered or expired."); return }
        switch await model.reviewApproval(r) {
        case .reviewed(let v): load = .ready(v)
        case .failed(let message): load = .failed(message)
        }
    }

    @ViewBuilder
    private func content(_ v: ApprovalReviewValue) -> some View {
        Section {
            Text(verbatim: "\(v.gate == "plan" ? "Plan" : "Requirements") of \(v.ticketKey)").font(OF.wsName)
            hostLine("Ticket", v.ticketKey)
            hostLine("Title", v.ticketTitle)
            hostLine("Generation", String(v.gateGen))
            if let rule = v.policyWords { hostLine("Rule", rule) }
            Text(ApprovalRequest.origin).font(OF.meta).foregroundStyle(OC.textMuted)
        }
        if v.content.fullReview {
            Section("Everything that is signed") {
                Text("This gate has more than the usual parts. Read all of it.").font(OF.meta).foregroundStyle(OC.warn)
                ForEach(Array(v.content.rawLines.enumerated()), id: \.offset) { _, line in
                    SafeTextView(line).font(OF.machine)
                }
            }
            .accessibilityIdentifier("approval.fullReview")
        }
        ForEach(v.content.sections, id: \.id) { sec in
            Section(sec.title) {
                if sec.text.isEmpty { Text("(empty)").foregroundStyle(OC.textMuted) } else { SafeTextView(sec.text) }
            }
        }
        if !v.content.acceptance.isEmpty {
            Section("Acceptance criteria") {
                ForEach(v.content.acceptance, id: \.id) { a in SafeTextView("\(a.id)  \(a.text)") }
            }
        }
        if !v.content.tasks.isEmpty {
            Section("Plan") {
                ForEach(v.content.tasks, id: \.n) { t in
                    VStack(alignment: .leading, spacing: 2) {
                        SafeTextView("\(t.n). [\(t.id)] \(t.title)")
                        ForEach(t.verify, id: \.self) { SafeTextView("verify: \($0)").font(OF.machine).foregroundStyle(OC.textMuted) }
                    }
                }
            }
        }
        if !v.content.rows.isEmpty {
            Section("Details") {
                ForEach(Array(v.content.rows.enumerated()), id: \.offset) { _, row in SafeTextView("\(row.field): \(row.value)") }
            }
        }
        if !v.content.fullReview {
            Section {
                DisclosureGroup("Everything that is signed") {
                    ForEach(Array(v.content.rawLines.enumerated()), id: \.offset) { _, line in SafeTextView(line).font(OF.machine) }
                }
            }
        }
        decisionSection(v)
    }

    private func hostLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(OF.meta).foregroundStyle(OC.textMuted)
            VStack(alignment: .leading, spacing: 0) {
                SafeTextView(value)
                Text(ApprovalReviewValue.perHost).font(OF.meta).foregroundStyle(OC.textFaint)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func decisionSection(_ v: ApprovalReviewValue) -> some View {
        Section {
            if let phase, phase.isFinal {
                Label(phase.message, systemImage: "checkmark.circle").accessibilityIdentifier("approval.result")
                Button("Done") { dismiss() }
            } else {
                if let phase {
                    Text(verbatim: phase.message).foregroundStyle(OC.warn).accessibilityIdentifier("approval.result")
                    if phase == .changed || phase == .invalidated { Button("Reopen") { Task { await open() } } }
                }
                Text("You are approving the text above. Face ID signs this approval.").font(OF.meta).foregroundStyle(OC.textMuted)
                Button("Approve") { Task { await go(v, .approve) } }
                    .buttonStyle(.borderedProminent).disabled(busy)
                    .accessibilityIdentifier("approval.approve")
                if asking {
                    TextField("What should change?", text: $changeText, axis: .vertical).lineLimit(3...8)
                        .accessibilityIdentifier("approval.changeText")
                    Button("Send changes") { Task { await go(v, .changes(text: changeText)) } }
                        .buttonStyle(.bordered).disabled(busy || changeText.isEmpty)
                        .accessibilityIdentifier("approval.sendChanges")
                } else {
                    Button("Request changes") { asking = true }.buttonStyle(.bordered).disabled(busy)
                        .accessibilityIdentifier("approval.changes")
                }
            }
        }
    }

    private func go(_ v: ApprovalReviewValue, _ choice: ApprovalChoice) async {
        busy = true
        phase = await model.decide(v, choice: choice)
        busy = false
        if phase?.isFinal == true { await model.refreshApprovals() }
    }
}
