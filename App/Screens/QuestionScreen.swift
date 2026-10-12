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
                AdaptiveStack {
                    WorkspaceHeader(name: info.name, color: info.color, hostedBy: info.hostedBy, clientHosted: info.clientHosted)
                    if services.settings.isDemo { DemoChip() }
                }
                if let q = ws.question(id: questionID) {
                    Text(verbatim: "\(q.displayTicket) · asked \(Fmt.relative(q.created))").font(OF.meta).foregroundStyle(OC.textMuted)
                        .padding(.horizontal, OS.s3).padding(.vertical, OS.s1)
                        .background(OC.surface2, in: Capsule())
                    SafeTextView(q.text)
                        .padding(OS.s4).orchCard()
                        .accessibilityIdentifier("question.text")
                    // A submission still being checked is shown as such even if a snapshot already carries the resolution.
                    if let r = q.resolution, !services.home.pendingDecisions.contains(where: { $0.questionID == q.id }) {
                        resolved(q, r)
                    } else {
                        answers(q, info)
                    }
                    SignedDetails(workspaceID: q.workspaceID, questionID: q.id, contentHash: q.contentHash)
                    SimulationNotice()
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
            // Lock/background: an unsent review is dropped for good (U7). A submission already sent
            // or being checked is never "cancelled" (U8): the sheet keeps its state.
            guard phase == .background, let item = signing else { return }
            item.model.invalidate()
            guard item.model.phase == .invalidated else { return }   // sending/checking keep going
            signing = nil
            notice = "Review dropped because the app was left. Choose your answer again to read the question afresh."
        }
    }

    @ViewBuilder
    private func resolved(_ q: Question, _ r: Resolution) -> some View {
        VStack(alignment: .leading, spacing: OS.s2) {
            Label { Text(verbatim: "Answered by \(SafeText.inline(r.byDeviceLabel, limit: 40)) · \(Fmt.relative(r.at))") }
                icon: { Image(systemName: "checkmark.circle.fill") }
                .font(OF.body).foregroundStyle(OC.ok)
            if let label = r.answerLabel(in: q.options) {
                SafeTextView(label, strictLabel: true)
            } else {
                Text(verbatim: Resolution.unknownAnswer).font(OF.meta).foregroundStyle(OC.textMuted)
                    .accessibilityIdentifier("question.resolution.unknownAnswer")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("question.resolution")
    }

    @ViewBuilder
    private func answers(_ q: Question, _ info: WorkspaceInfo) -> some View {
        let pending = services.home.pendingDecisions.first { $0.questionID == q.id }
        let labels = q.options.map(\.label)
        let refusal = SafeText.optionRefusal(labels)
        let block = info.answerBlock
        if let notice { Label(notice, systemImage: "info.circle").font(OF.meta).foregroundStyle(OC.warn) }
        if pending != nil {
            VStack(alignment: .leading, spacing: OS.s2) {
                Text("You submitted").font(OF.meta).foregroundStyle(OC.textMuted)
                SafeTextView(pending?.optionLabel ?? "", strictLabel: true).accessibilityIdentifier("question.pending.answer")
                Button { startSigning(pending?.optionID ?? "") } label: {
                    Label("Checking whether your answer was received", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered).accessibilityIdentifier("question.pending")
            }
        } else {
            Text("Choose an answer").font(OF.section)
            ForEach(q.options) { option in
                Button { startSigning(option.id) } label: { SafeTextView(option.label, strictLabel: true) }
                    .buttonStyle(OrchOptionButtonStyle())
                    .disabled(block != nil || refusal != nil)
                    .accessibilityIdentifier("question.option.\(option.id)")
                    .accessibilityHint("Opens a review before you sign")
            }
            if let block { Text(verbatim: block).font(OF.meta).foregroundStyle(OC.textMuted) }
            if let refusal {
                Label { Text(verbatim: refusal.message) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(OF.meta).foregroundStyle(OC.warn)
                    .accessibilityIdentifier(refusal.questionIdentifier)
            }
        }
    }

    private func startSigning(_ optionID: String) {
        notice = nil
        signing = SigningItem(model: services.review(workspaceID: workspaceID, questionID: questionID, optionID: optionID))
    }
}

// MARK: Sign sheet (U7)

private struct ArmKey: Hashable { let atEnd: Bool; let revision: Int }

/// The exact signed text in monospace. Open from the start when the text has hidden or look-alike characters.
private struct ExactTextDisclosure: View {
    let review: ReviewValue
    @State private var open: Bool

    init(review: ReviewValue) {
        self.review = review
        _open = State(initialValue: review.hasUnsafeContent)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: OS.s2) {
                Text("Question").font(OF.meta).foregroundStyle(OC.textMuted)
                Text(SafeText.attributed(review.text, style: .exact)).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(SafeText.spoken(review.text))
                Text("Your answer").font(OF.meta).foregroundStyle(OC.textMuted)
                Text(SafeText.attributed(review.optionLabel, style: .exact, strictLabel: true)).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(SafeText.spoken(review.optionLabel, strictLabel: true))
            }
            .padding(.top, OS.s2)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sign.exactText")
        } label: { Text("Exact text (monospace)").font(OF.section) }
    }
}

struct SignSheet: View {
    let model: any QuestionReviewModel
    let onClose: () -> Void
    @State private var atEndRevision: Int?
    @State private var armedRevision: Int?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 0) {
            switch model.load {
            case .loading:
                ProgressView("Reading the question…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("sign.loading")
            case .failed(let message):
                VStack(spacing: OS.s4) {
                    stateView("exclamationmark.triangle", OC.warn, "Couldn't read the question", message, id: "sign.loadFailed")
                    Button { Task { await model.loadReview() } } label: { Text("Try again") }
                        .buttonStyle(.orchProminent).accessibilityIdentifier("sign.retryLoad")
                    Button("Close", role: .cancel, action: onClose)
                }
                .padding(OS.s4).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                if let review = model.review { content(review) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OC.bg)
        .transaction { $0.animation = nil }          // V5: security surface never animates
        .interactiveDismissDisabled(model.phase == .sending)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(26)
        .task { await model.loadReview() }
    }

    @ViewBuilder
    private func content(_ review: ReviewValue) -> some View {
        if review.isDemo { DemoStripe() }
        ScrollView {
            VStack(alignment: .leading, spacing: OS.s4) {
                AdaptiveStack {
                    WorkspaceHeader(name: review.workspaceName, color: OC.wsHues[review.hue % OC.wsHues.count],
                                    hostedBy: review.hostedBy, clientHosted: review.clientHosted)
                    if review.isDemo { DemoChip() }
                }
                Text("You are signing").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: OS.s1) {
                    Text(verbatim: "Question \(SafeText.inline(review.ticket, limit: 24))").font(OF.meta).foregroundStyle(OC.textFaint)
                    SafeTextView(review.text).accessibilityIdentifier("sign.text")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(OS.s3)
                .background(OC.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: OS.s1) {
                    Text("Selected answer").font(.footnote.weight(.bold)).foregroundStyle(OC.brand)
                    SafeTextView(review.optionLabel, strictLabel: true).accessibilityIdentifier("sign.answer")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(OS.s3)
                .background(OC.soft(OC.brand), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(OC.brand, lineWidth: 2))
                if review.hasUnsafeContent {
                    Label("Some text contains characters that cannot be seen or that look like other characters. They are marked in orange so you can see exactly what is signed.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(OF.meta).foregroundStyle(OC.warn)
                        .accessibilityIdentifier("sign.unsafeNotice")
                }
                VStack(alignment: .leading, spacing: OS.s1) {
                    Text(verbatim: "\(Fmt.plural(lineCount(review.text), "line", "lines")) · \(review.text.count) characters · hash \(review.contentHash.prefix(4))·\(review.contentHash.dropFirst(4).prefix(4))")
                        .font(OF.meta).foregroundStyle(OC.textMuted)
                    fingerprint(review.contentHash)
                    Text("The text ends with").font(OF.meta).foregroundStyle(OC.textMuted)
                    Text(SafeText.attributed(tail(review.text), style: .exact)).clipped()
                        .accessibilityLabel(SafeText.spoken(tail(review.text))).accessibilityIdentifier("sign.tail")
                }
                ExactTextDisclosure(review: review)
                SignedDetails(workspaceID: review.workspaceID, questionID: review.questionID,
                              optionID: review.optionID, contentHash: review.contentHash)
                if typeSize.isAccessibilitySize { footer(review) }
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
        .task(id: ArmKey(atEnd: atEndRevision == review.revision, revision: review.revision)) {
            armedRevision = nil
            guard atEndRevision == review.revision else { return }
            try? await Task.sleep(for: .milliseconds(800))
            if !Task.isCancelled { armedRevision = review.revision }
        }
        if !typeSize.isAccessibilitySize {
            Divider()
            footer(review).padding(OS.s4).background(OC.surface)
        }
    }

    /// The content hash prefix in four-character groups so two fingerprints can be compared at a glance.
    private func fingerprint(_ hash: String) -> some View {
        let groups = stride(from: 0, to: min(hash.count, 16), by: 4).map { i -> String in
            let start = hash.index(hash.startIndex, offsetBy: i)
            let end = hash.index(start, offsetBy: min(4, min(hash.count, 16) - i))
            return String(hash[start..<end])
        }
        return FlowLayout(spacing: OS.s2) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                Text(verbatim: group).font(.footnote.monospaced().weight(.medium))
                    .padding(.horizontal, OS.s2).padding(.vertical, 3)
                    .background(OC.surface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Fingerprint " + groups.joined(separator: ", ")))
        .accessibilityIdentifier("sign.fingerprint")
    }

    private func tail(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.count > 40 ? "…" : "") + trimmed.suffix(40)
    }

    private func lineCount(_ text: String) -> Int { text.split(separator: "\n", omittingEmptySubsequences: false).count }

    // MARK: Footer by phase

    @ViewBuilder
    private func footer(_ review: ReviewValue) -> some View {
        VStack(spacing: OS.s3) {
            switch model.phase {
            case .ready:
                if let refusal = review.optionsRefusal {
                    stateView("exclamationmark.octagon", OC.danger, "Can't be checked here", refusal.message, id: "sign.refused")
                    Button(role: .cancel, action: onClose) { Text("Cancel").frame(maxWidth: .infinity, minHeight: 44) }
                        .foregroundStyle(OC.brand).accessibilityIdentifier("sign.cancel")
                } else {
                    if review.hasUnsafeContent {
                        VStack(alignment: .leading, spacing: OS.s1) {
                            Label("Hidden or look-alike characters", systemImage: "exclamationmark.triangle.fill")
                                .font(OF.section).foregroundStyle(OC.warn)
                            Text("This text has characters you cannot see or that look like other letters. They are marked, and the exact text is open above. Check it before you sign.")
                                .font(OF.meta).foregroundStyle(OC.text)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(OS.s3)
                        .background(OC.soft(OC.warn), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(OC.warn, lineWidth: 1.5))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("sign.unsafeWarning")
                    }
                    HStack(alignment: .firstTextBaseline, spacing: OS.s2) {
                        Text("Answer").font(OF.meta).foregroundStyle(OC.textMuted)
                        SafeTextView(review.optionLabel, strictLabel: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button { Task { await model.sign() } } label: { Label("Sign and send", systemImage: "signature") }
                        .buttonStyle(.orchProminent)
                        .disabled(armedRevision != review.revision)
                        .accessibilityIdentifier("sign.confirm")
                        .accessibilityHint(armedRevision == review.revision ? "" : "Scroll to the end of the text to continue")
                    if armedRevision != review.revision {
                        Text(atEndRevision == review.revision ? "Hold on…" : "Scroll to the end to continue")
                            .font(OF.meta).foregroundStyle(OC.textMuted).accessibilityIdentifier("sign.hint")
                    }
                    Button(role: .cancel, action: onClose) { Text("Cancel").frame(maxWidth: .infinity, minHeight: 44) }
                        .foregroundStyle(OC.brand).accessibilityIdentifier("sign.cancel")
                }
            case .rereading:
                ProgressView("Reading the question again…").accessibilityIdentifier("sign.rereading")
            case .invalidated:
                stateView("hourglass.bottomhalf.filled", OC.warn, "Review expired",
                          "The question must be read afresh. Close this and choose your answer again.", id: "sign.invalidated")
                doneButton
            case .sending:
                ProgressView("Sending…").accessibilityIdentifier("sign.sending")
            case .accepted:
                stateView("checkmark.seal.fill", OC.ok, review.isDemo ? "Sent and accepted by the Demo host" : "Sent and accepted",
                          review.isDemo ? "The Demo host verified your signature and applied your answer." : "Your answer was applied.",
                          id: "sign.accepted")
                doneButton
            case .alreadyAnswered(let by, let at):
                stateView("person.crop.circle.badge.exclamationmark", OC.warn, "Your answer wasn't applied",
                          "\(SafeText.inline(by, limit: 40)) answered this at \(Fmt.time(at)).", id: "sign.alreadyAnswered")
                doneButton
            case .questionChanged:
                stateView("arrow.triangle.2.circlepath", OC.warn, "The question changed",
                          "Read it again before you answer.", id: "sign.questionChanged")
                Button { Task { await model.reread() } } label: { Text("Read it again") }
                    .buttonStyle(.orchProminent).accessibilityIdentifier("sign.reread")
                Button("Cancel", role: .cancel, action: onClose)
            case .checking:
                stateView("clock.arrow.circlepath", OC.info, "Checking whether your answer was received",
                          "Your answer is not sent again until this is settled. If you close this, orch keeps checking for a short while and shows it on Home.", id: "sign.checking")
                Button { Task { await model.checkWhetherReceived() } } label: { Text("Check again").frame(maxWidth: .infinity).padding(.vertical, OS.s2) }
                    .buttonStyle(.bordered).accessibilityIdentifier("sign.recheck")
                Button("Close and keep checking", action: onClose).accessibilityIdentifier("sign.closeChecking")
            case .notApplied:
                stateView("eye.slash", OC.warn, "Your answer wasn't applied",
                          "The host recorded it but did not apply it: this question is not visible to this iPhone. Nothing is sent again.", id: "sign.notApplied")
                doneButton
            case .needsRetry:
                stateView("exclamationmark.arrow.circlepath", OC.warn, "Your answer was not delivered",
                          "The relay gave up delivering it and the question is still open. Nothing is sent again unless you tap Send again: it sends the same signed answer, after checking the question.", id: "sign.needsRetry")
                Button { Task { await model.sendAgain() } } label: { Text("Send again").frame(maxWidth: .infinity).padding(.vertical, OS.s2) }
                    .buttonStyle(.orchProminent).accessibilityIdentifier("question.sendAgain")
                Button("Close", action: onClose).accessibilityIdentifier("sign.closeNeedsRetry")
            case .unlockToContinue:
                stateView("lock.fill", OC.warn, "Unlock to continue", "Unlock this iPhone to sign.", id: "sign.unlock")
                Button("Read it again and continue") { model.retryAfterUnlock() }.buttonStyle(.bordered).accessibilityIdentifier("sign.unlockRetry")
                Button("Cancel", role: .cancel, action: onClose)
            case .notSent:
                stateView("wifi.exclamationmark", OC.warn, "Not sent",
                          "Nothing was signed and nothing was stored. Check the connection, then choose your answer again.", id: "sign.notSent")
                doneButton
            case .custodyUnavailable:
                stateView("key.slash", OC.danger, "Signing key not available",
                          "This iPhone can no longer sign for this workspace. Re-pair it to continue.", id: "sign.custody")
                doneButton
            }
            Text("This unlocked iPhone signs with its device key.")
                .font(OF.meta).foregroundStyle(OC.textMuted).multilineTextAlignment(.center)
                .accessibilityIdentifier("sign.footnote")
            SimulationNotice()
        }
    }

    private var doneButton: some View {
        Button(action: onClose) { Text("Done") }
            .buttonStyle(.orchProminent).accessibilityIdentifier("sign.done")
    }

    private func stateView(_ icon: String, _ color: Color, _ title: String, _ detail: String, id: String) -> some View {
        VStack(spacing: OS.s2) {
            Image(systemName: icon).font(.title).foregroundStyle(color)
            Text(verbatim: title).font(OF.section).multilineTextAlignment(.center)
            Text(verbatim: detail).font(OF.body).foregroundStyle(OC.textMuted).multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }
}
