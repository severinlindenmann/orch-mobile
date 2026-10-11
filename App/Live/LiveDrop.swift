import Foundation
import Observation
import OrchClient
import OrchProtocol
import OrchStore
import OrchCoordination

/// One pairing generation. Cached plaintext metadata never crosses this model's lifetime.
@MainActor @Observable
final class LiveDrop {
    let service: DropService
    unowned let workspace: LiveWorkspace
    private(set) var revision = 0
    private(set) var status: String?
    private(set) var alarm = false
    private(set) var loading = false
    var objects: [String: DropObject] = [:]
    var downloads: [String: DropDownload] = [:]
    var rows: [DropItem] = []
    var failures: [DropUploadFailure] = []
    var previewURL: URL?
    var usable: Bool { workspace.usable && !alarm }

    init(service: DropService, workspace: LiveWorkspace) {
        self.service = service; self.workspace = workspace
    }
    func cancelUI(clear: Bool) {
        revision += 1; previewURL = nil
        if clear { downloads = [:]; objects = [:]; rows = [] }
    }
    func report(_ error: any Error) {
        if error is CancellationError || (error as? DropError) == .suspended { return }
        switch error {
        case SQLiteError.busy, TombstoneError.lockFailed: status = "Busy lock: try again"
        case DropError.rollback, DropError.integrity, DropStoreError.rollback, is CryptoFailure:
            alarm = true; status = "Verification alarm"; downloads = [:]; previewURL = nil
        case DropError.unavailableKey: status = "Key unavailable: retry later"
        case DropError.unauthorized: status = "Action unavailable"
        default: status = "Unavailable: retry later"
        }
    }
}
