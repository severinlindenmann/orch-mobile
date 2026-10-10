#if DEBUG
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import OrchShareStaging
import OrchUI

/// DEBUG-only fixture for the share-extension XCUITest (decision T2). It presents a genuine
/// `UIActivityViewController` with file, text and URL items that match the extension's activation rule, so the
/// test drives the real installed extension process (not an in-app composer) and then checks the result here.
struct ShareFixtureScreen: View {
    let openDrop: () -> Void
    @State private var status = "No staged jobs checked yet."

    var body: some View {
        List {
            Section("Share sample items with the installed extension") {
                Button("Share file, text and link") { present(file: true, text: true, url: true) }.accessibilityIdentifier("share.fixture.mixed")
                Button("Share a file") { present(file: true, text: false, url: false) }.accessibilityIdentifier("share.fixture.file")
                Button("Share text") { present(file: false, text: true, url: false) }.accessibilityIdentifier("share.fixture.text")
                Button("Share a link") { present(file: false, text: false, url: true) }.accessibilityIdentifier("share.fixture.url")
            }
            Section("After sharing") {
                Button("Check staged jobs") { inspect() }.accessibilityIdentifier("share.fixture.inspect")
                Text(verbatim: status).accessibilityIdentifier("share.fixture.status")
                Button("Import now") { NotificationCenter.default.post(name: .orchDebugShareRefresh, object: nil) }
                    .accessibilityIdentifier("share.fixture.import")
                Button("Open Drop") { openDrop() }.accessibilityIdentifier("share.fixture.drop")
            }
        }
        .navigationTitle("Share fixture")
    }

    private func present(file: Bool, text: Bool, url: Bool) {
        var items: [Any] = []
        if file {
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("orch-share-fixture.txt")
            try? Data("fixture file contents".utf8).write(to: u)
            items.append(u)
        }
        if text { items.append("orch fixture text") }
        if url, let u = URL(string: "https://example.invalid/orch-fixture") { items.append(u) }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async { status = "Share sheet closed." }
        }
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              var top = scene.keyWindow?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        vc.popoverPresentationController?.sourceView = top.view
        top.present(vc, animated: true)
    }

    private func inspect() {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ShareBridge.groupIdentifier) else {
            status = "No App Group container."; return
        }
        let jobs = ShareInbox(area: ShareArea(shareGroupRoot: root)).peekReady()
        let kinds = jobs.flatMap { $0.manifest.items.map(\.kind.rawValue) }.sorted().joined(separator: ",")
        status = "ready jobs: \(jobs.count) items: \(kinds)"
    }
}
#endif
