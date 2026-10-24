import Foundation

// TEST-ONLY. Wraps a sealed hub push (the outer object) into the APNs body `xcrun simctl push` takes. The hub fixtures themselves
// (fresh keys, ids and sealed pushes) are made by scripts/make-push-fixture.swift; this one file is compiled as the SwiftPM target
// `OrchPushFixtures` and into that script (with the OrchProtocol sources). It protects nothing and never ships in a Release product.

public enum PushFixtures {
    /// The APNs body as `xcrun simctl push` takes it. `alert` is what the relay would put in the clear.
    public static func apns(outer: String, bundle: String = "io.severin.orch", aps: [String: Any]? = nil, extra: [String: Any] = [:]) -> Data {
        var body: [String: Any] = ["Simulator Target Bundle": bundle,
                                   "aps": aps ?? ["alert": ["title": "orch", "body": "New activity"], "mutable-content": 1, "sound": "default"],
                                   "o": outer]
        for (k, v) in extra { body[k] = v }
        return try! JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
    }
}
