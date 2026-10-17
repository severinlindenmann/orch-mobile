import Foundation
import OrchProtocol

/// Where a tap on a notification goes (B10 phase 1). Only the hint push of "approve on your phone" is routed: a `ticket.update` whose id
/// is `ph_<ULID>` (core #628 contract (d)) opens the approvals list of its workspace. The push is a wake, never the data: the list is
/// read from the host (`phone.requests`), and an id that is not in that list is shown as nothing. Every other push keeps today's
/// behaviour (no routing).
public enum PushRoute: Equatable, Sendable {
    case approvals(workspaceHex: String)
    case none
}

public enum PushRouting {
    /// The id prefix of an approval hint (`ph_` + a ULID).
    public static let hintPrefix = "ph_"

    public static func isHintID(_ id: String) -> Bool { id.hasPrefix(hintPrefix) && ULID.isValid(String(id.dropFirst(hintPrefix.count))) }

    /// A verified payload (the extension's, after `PushProcessor.open`).
    public static func route(_ p: PushProcessor.Payload) -> PushRoute {
        p.kind.bytesEqual("ticket.update") && isHintID(p.id) ? .approvals(workspaceHex: p.workspace.hex) : .none
    }

    /// A delivered notification's `orch_key` userInfo (`<ws hex>/<id>`, set by `PushPresentation`): a tap on it. Only a well-formed key of a
    /// hint id routes; the kind is not in the key, but only a verified `ticket.update` push ever built one with a `ph_` id (the id is the host's
    /// and a `question` id is a different shape).
    public static func route(entityKey: String?) -> PushRoute {
        guard let entityKey else { return .none }
        let parts = entityKey.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, ID16(hex: parts[0]) != nil, isHintID(parts[1]) else { return .none }
        return .approvals(workspaceHex: parts[0])
    }
}
