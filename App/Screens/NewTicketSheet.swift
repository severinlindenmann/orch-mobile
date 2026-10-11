import SwiftUI
import OrchUI

/// Compose a ticket. The model keeps one creation ID for exactly these fields, so "Try again" after a failure creates at most once.
struct NewTicketSheet: View {
    let model: any WorkspaceModel
    let onClose: () -> Void
    @State private var title = ""
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?
    @State private var created: String?

    var body: some View {
        NavigationStack {
            Form {
                if let created {
                    Section {
                        Label { Text(verbatim: "Created \(created)") } icon: { Image(systemName: "checkmark.circle.fill") }
                            .foregroundStyle(OC.ok).accessibilityIdentifier("ticket.new.created")
                        Button("Done", action: onClose).accessibilityIdentifier("ticket.new.done")
                    }
                } else {
                    Section("Title") {
                        TextField("Title", text: $title).accessibilityIdentifier("ticket.new.title")
                    }
                    Section("Details") {
                        TextField("Details", text: $text, axis: .vertical).lineLimit(3...8).accessibilityIdentifier("ticket.new.body")
                    }
                    if let error {
                        Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle") }
                            .foregroundStyle(OC.warn).accessibilityIdentifier("ticket.new.error")
                    }
                    Section {
                        Button(error == nil ? "Create ticket" : "Try again") { Task { await send() } }
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || sending)
                            .accessibilityIdentifier("ticket.new.create")
                    } footer: {
                        Text("The ticket is created on the host. Trying again with the same text never creates it twice.")
                    }
                }
            }
            .navigationTitle("New ticket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel", action: onClose).accessibilityIdentifier("ticket.new.cancel") } }
        }
    }

    private func send() async {
        sending = true; defer { sending = false }
        switch await model.createTicket(title: title, body: text) {
        case .created(let key): created = key; error = nil
        case .failed(let message): error = message
        }
    }
}
