import Foundation

/// The APNs body the relay sends (P3-D40, protocol-v2 section 19.10), as far as the notification extension depends on it:
///
///     {"aps":{"alert":{"title":"orch","body":"New activity in orch"},"mutable-content":1},"o":<cj(outer) as a JSON string>}
///
/// at most 3 175 bytes for a 3 072-byte outer; no `badge`, `sound`, `thread-id`, `category` or `apns-collapse-id`. The extension reads
/// ONLY `o`, and only when it is a JSON string: the relay's alert text is never shown (the extension shows the verified payload, or the
/// same generic text). 
public enum RelayPushBody {
    /// The constant alert text the relay sends: the extension's own fallback, so a dropped payload looks identical.
    public static let alertTitle = PushPresentation.genericTitle
    public static let alertBody = PushPresentation.genericBody
    /// The most the relay sends for a maximal outer (APNs allows 4 096).
    public static let maxBodyBytes = 3175

    /// `userInfo["o"]` as a string, else nil. A number, array, object or missing value is nil: the handler then treats it as a drop
    /// and delivers generic text. The string is NOT re-validated here (`HubPushOuter` and `HubPushIntake` own size, shape and the seal).
    public static func outer(userInfo: [AnyHashable: Any]) -> String? { userInfo["o"] as? String }
}
