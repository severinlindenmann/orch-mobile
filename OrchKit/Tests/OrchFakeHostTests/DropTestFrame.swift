import Foundation
import OrchProtocol

/// Tests edit an upload as `{descriptor, wraps, blob: b64u}` (the pre-ODU2 stored form) and send the `ODU2` frame.
enum DropTestFrame {
    static func json(_ frame: Data) throws -> [String: JSONValue] {
        let (parts, blob) = try DropFrame.parse(frame)
        return ["descriptor": parts.descriptor, "wraps": .array(parts.wraps), "blob": .string(B64U.encode(blob))]
    }

    static func frame(_ json: [String: JSONValue]) throws -> Data {
        try DropFrame.encode(descriptor: json["descriptor"]!, wraps: json["wraps"]!.array!, blob: B64U.decode(json["blob"]!.string!)!)
    }

    /// The legacy JSON stored form, as a pending `drop_uploads.body` written by an earlier build.
    static func legacyBody(_ frame: Data) throws -> Data { try canonicalJSON(.object(json(frame))) }
}
