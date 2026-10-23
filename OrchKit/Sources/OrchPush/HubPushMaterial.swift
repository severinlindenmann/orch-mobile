import Foundation
import OrchProtocol

/// What the notification extension needs to open a hub push (design B4): ONE `.push` item, `hub.push.material`, written only by the app,
/// atomically (`put` replaces the whole item), and removed by the wipe. It holds the hub and channel ids it is for (the extension opens a hint only
/// when `outer.hub` and `outer.ch` are these, D10-3), the label the person gave the hub (the notification title, never anything the hub or
/// a push says) and the agreement-only push key. It never holds the channel key, a session token or anything that signs.
public struct HubPushMaterial: Sendable {
    /// The keychain account of the item (V3 has one hub per install, D-B1, so the extension finds it without knowing the hub id).
    public static let purpose = "hub.push.material"
    public static let maxBytes = 1024

    public let hubID: String
    public let channelID: String
    public let label: String
    public let opener: HubPushOpener

    package init(hubID: String, channelID: String, label: String, opener: HubPushOpener) throws {
        guard Hex.decode(hubID, length: 16) != nil, Hex.decode(channelID, length: 16) != nil, (1...200).contains(label.unicodeScalars.count)
        else { throw Refusal.malformed }
        self.hubID = hubID; self.channelID = channelID; self.label = label; self.opener = opener
    }

    package func encoded() throws -> Data {
        let data = try canonicalJSON(["v": 1, "hub_id": .string(hubID), "channel_id": .string(channelID), "label": .string(label),
                                      "push_key": .string(B64U.encode(opener.raw))])
        guard data.count <= Self.maxBytes else { throw Refusal.malformed }
        return data
    }

    /// Strict: exactly these members, nothing else. Anything unreadable is an error, and the extension then shows the generic text.
    public static func decode(_ data: Data) throws -> HubPushMaterial {
        guard data.count <= maxBytes, let o = try StrictJSON.parse(data, maxBytes: maxBytes).object,
              Set(o.keys) == ["v", "hub_id", "channel_id", "label", "push_key"], o["v"] == .int(1),
              let hub = o["hub_id"]?.string, let ch = o["channel_id"]?.string, let label = o["label"]?.string,
              let raw = o["push_key"]?.string.flatMap({ B64U.decode($0, length: 32) }) else { throw Refusal.malformed }
        return try HubPushMaterial(hubID: hub, channelID: ch, label: label, opener: try HubPushOpener(raw: raw))
    }
}
