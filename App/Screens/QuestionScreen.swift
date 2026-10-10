import SwiftUI
import OrchUI

private struct SigningItem: Identifiable {
    let id = UUID()
    let model: any QuestionReviewModel
}

struct QuestionScreen: View {
    let services: any AppServices
    let workspaceID: String
    let questionID: String
    let autoSign: Bool
    @State private var signing: SigningItem?
    @State private var notice: String?
    @State private var didAutoSign = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let ws = services.workspace(workspaceID)
        let info = ws.info
        ScrollView {
            VStack(alignment: .leading, spacing: OS.s4) {
                WorkspaceHeader(name: info.name, color: info.color, hostedBy: info.hostedBy, clientHosted: info.clientHosted)
                if let q = ws.question(id: questionID) {
                    Text("\(q.ticket) · asked \(Fmt.relative(q.created))").font(OF.meta).foregroundStyle(OC.textMuted)
                    SafeTextView(q.text)
                        .padding(OS.s4).orchCard()
                        .accessibilityIdentifier("question.text")
                    if let r = q.resolution {
                        Label("Answered by \(r.byDeviceLabel) · \(Fmt.relative(r.at)): \(q.options.first { $0.id == r.optionID }?.label ?? r.optionID)",
                              systemImage: "checkmark.circle.fill")
                            .font(OF.body).foregroundStyle(OC.ok)
                            .accessibilityIdentifier("question.resolution")
                    } else {
                        if let notice { Label(notice, systemImage: "info.circle").font(OF.meta).foregroundStyle(OC.warn) }
                        Text("Choose an answer").font(OF.section)
                        ForEach(q.options) { option in
                            Button { startSigning(option.id) } label: {
                                Text(option.label).frame(maxWidth: .infinity).padding(.vertical, OS.s2)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(isOffline(info))
                            .accessibilityIdentifier("question.option.\(option.id)")
                            .accessibilityHint("Opens a review before you sign")
                        }
                        if isOffline(info) {
                            Text("Saved copy · answers are off until you're back").font(OF.meta).foregroundStyle(OC.textMuted)
                        }
                    }
                } else {
                    EmptyState(systemImage: "questionmark.circle", title: "This question is no longer available")
                }
            }
            .padding(OS.s4)
        }
        .background(OC.bg)
        .navigationTitle("Question")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $signing) { item in
            SignSheet(model: item.model) { signing = nil }
        }
        .onAppear {
            if autoSign, !didAutoSign, let q = ws.question(id: questionID), q.isOpen, let first = q.options.first {
                didAutoSign = true
                startSigning(first.id)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Lock/background invalidates the staged review (U7).
            if phase == .background, let item = signing {
                item.model.invalidate()
                signing = nil
                notice = "Review cancelled because the app was left. Open the question again to review it."
            }
        }
    }

    private func isOffline(_ info: WorkspaceInfo) -> Bool {
        if case .offline = info.connection { return true }
        return false
    }

    private func startSigning(_ optionID: String) {
        notice = nil
        signing = SigningItem(model: services.review(workspaceID: workspaceID, questionID: questionID, optionID: optionID))
    }
}

// MARK: Sign sheet (U7)

struct SignSheet: View {
    let model: any QuestionReviewModel
    let onClose: () -> Void
    @State private var atEnd = false
    @State private var armed = false
    @State private var detailsOpen = false

    private var review: ReviewValue { model.review }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: OS.s4) {
                    WorkspaceHeader(name: review.workspaceName, color: OC.wsHues[review.hue % OC.wsHues.count],
                                    hostedBy: review.hostedBy, clientHosted: review.hostedBy != nil)
                    Text("You are signing").font(OF.section)
                    VStack(alignment: .leading, spacing: OS.s2) {
                        Text("Question \(review.ticket)").font(OF.meta).foregroundStyle(OC.textMuted)
                        SafeTextView(review.text)
                            .accessibilityIdentifier("sign.text")
                    }
                    .padding(OS.s4)
                    .background(OC.surface2, in: RoundedRectangle(cornerRadius: OR.control, style: .continuous))
                    VStack(alignment: .leading, spacing: OS.s1) {
                        Text("The text ends with").font(OF.meta).foregroundStyle(OC.textMuted)
                        Text(SafeText.attributed(tail(review.text))).accessibilityIdentifier("sign.tail")
                    }
                    Text("\(lineCount(review.text)) lines · \(review.text.count) characters · hash \(review.contentHash.prefix(4))·\(review.contentHash.dropFirst(4).prefix(4))")
                        .font(OF.meta).foregroundStyle(OC.textMuted)
                    VStack(alignment: .leading, spacing: OS.s1) {
                        Text("Your answer").font(OF.meta).foregroundStyle(OC.textMuted)
                        Text(review.optionLabel).font(OF.section)
                            .accessibilityIdentifier("sign.answer")
                    }
                    if SafeText.hasUnsafe(review.text) {
                        Label("This text contains characters that cannot be seen. They are marked in orange so you can see exactly what is signed.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(OF.meta).foregroundStyle(OC.warn)
                            .accessibilityIdentifier("sign.unsafeNotice")
                    }
                    DisclosureGroup(isExpanded: $detailsOpen) {
                        VStack(alignment: .leading, spacing: OS.s2) {
                            detail("Workspace", review.workspaceID)
                            detail("Question id", review.questionID)
                            detail("Content hash", review.contentHash)
                        }.padding(.top, OS.s2)
                    } label: {
                        Text("Signed details").font(OF.section)
                    }
                    .accessibilityIdentifier("sign.details")
                    Color.clear.frame(height: 1)
                        .onAppear { atEnd = true }
                        .accessibilityHidden(true)
                }
                .padding(OS.s4)
            }
            Divider()
            footer.padding(OS.s4).background(OC.surface)
        }
        .background(OC.bg)
        .id(review.revision)
        .transaction { $0.animation = nil }          // V5: security surface never animates
        .interactiveDismissDisabled(model.phase == .sending || armed)
        .presentationDetents([.large])
        .task(id: "\(atEnd)-\(review.revision)") {
            armed = false
            guard atEnd else { return }
            try? await Task.sleep(for: .milliseconds(800))
            if !Task.isCancelled { armed = true }
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(OF.meta).foregroundStyle(OC.textMuted)
            Text(value).font(OF.machine).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private func tail(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = trimmed.suffix(40)
        return (trimmed.count > 40 ? "…" : "") + t
    }

    private func lineCount(_ text: String) -> Int { text.split(separator: "\n", omittingEmptySubsequences: false).count }

    // MARK: Footer by phase

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: OS.s3) {
            switch model.phase {
            case .ready:
                Button { Task { await model.sign() } } label: {
                    Text("Sign and send").frame(maxWidth: .infinity).padding(.vertical, OS.s2)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!armed)
                .accessibilityIdentifier("sign.confirm")
                .accessibilityHint(armed ? "" : "Scroll to the end of the text to continue")
                if !armed {
                    Text(atEnd ? "Hold on…" : "Scroll to the end to continue")
                        .font(OF.meta).foregroundStyle(OC.textMuted).accessibilityIdentifier("sign.hint")
                }
                Button("Cancel", role: .cancel, action: onClose).accessibilityIdentifier("sign.cancel")
            case .sending:
                ProgressView("Sending…").accessibilityIdentifier("sign.sending")
            case .accepted:
                stateView("checkmark.seal.fill", OC.ok, "Sent and accepted", "Your answer was applied.", id: "sign.accepted")
                doneButton
            case .alreadyAnswered(let by, let at):
                stateView("person.crop.circle.badge.exclamationmark", OC.warn, "Already answered",
                          "\(by) answered this at \(Fmt.time(at)). Your answer was not sent.", id: "sign.alreadyAnswered")
                doneButton
            case .questionChanged:
                stateView("arrow.triangle.2.circlepath", OC.warn, "The question changed",
                          "Read it again before you answer.", id: "sign.questionChanged")
                Button { atEnd = false; armed = false; Task { await model.reread() } } label: {
                    Text("Read it again").frame(maxWidth: .infinity).padding(.vertical, OS.s2)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .accessibilityIdentifier("sign.reread")
                Button("Cancel", role: .cancel, action: onClose)
            case .checking:
                stateView("clock.arrow.circlepath", OC.info, "Checking whether your answer was received",
                          "Your answer is not sent again until this is settled.", id: "sign.checking")
                Button { Task { await model.checkWhetherReceived() } } label: {
                    Text("Check again").frame(maxWidth: .infinity).padding(.vertical, OS.s2)
                }
                .buttonStyle(.bordered).accessibilityIdentifier("sign.recheck")
            case .unlockToContinue:
                stateView("lock.fill", OC.warn, "Unlock to continue", "Unlock this iPhone to sign.", id: "sign.unlock")
                Button("Try again") { model.retryAfterUnlock() }.buttonStyle(.bordered)
                Button("Cancel", role: .cancel, action: onClose)
            case .custodyUnavailable:
                stateView("key.slash", OC.danger, "Signing key not available",
                          "This iPhone can no longer sign for this workspace. Re-pair it to continue.", id: "sign.custody")
                doneButton
            }
            Text("This unlocked iPhone signs with its device key.")
                .font(OF.meta).foregroundStyle(OC.textMuted).multilineTextAlignment(.center)
                .accessibilityIdentifier("sign.footnote")
        }
    }

    private var doneButton: some View {
        Button { onClose() } label: { Text("Done").frame(maxWidth: .infinity).padding(.vertical, OS.s2) }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .accessibilityIdentifier("sign.done")
    }

    private func stateView(_ icon: String, _ color: Color, _ title: String, _ detail: String, id: String) -> some View {
        VStack(spacing: OS.s2) {
            Image(systemName: icon).font(.title).foregroundStyle(color)
            Text(title).font(OF.section).multilineTextAlignment(.center)
            Text(detail).font(OF.body).foregroundStyle(OC.textMuted).multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }
}
