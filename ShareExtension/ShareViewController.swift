import SwiftUI
import UIKit
import OrchUI

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareComposeView(onCancel: { [weak self] in
            self?.extensionContext?.cancelRequest(
                withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }
}

private struct ShareComposeView: View {
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Text("Sharing comes in a later milestone.").foregroundStyle(OC.textMuted)
            }
            .navigationTitle("Share to orch")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {}.disabled(true) }
            }
        }
        .tint(OC.brand)
    }
}
