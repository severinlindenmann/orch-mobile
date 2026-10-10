import Foundation
import OrchProtocol

/// Fake-only host-api v0 signed kind. Deliberately outside OrchProtocol's signed-object vectors.
/// The signature covers label || canonicalJSON({kind, workspace_id, epoch}).
enum RotationAbandon {
    static let label = "orch.host-api.0.rotation_abandon"

    static func signed(workspace: ID16, epoch: UInt32, signer: some Signer) throws -> JSONValue {
        let object: [String: JSONValue] = ["kind": "rotation_abandon", "workspace_id": .string(workspace.hex), "epoch": .int(Int64(epoch))]
        return try SignedObject(object: object, signature: Signature.sign(signer, label: label, message: canonicalJSON(.object(object)))).json
    }

    static func verify(_ value: JSONValue, workspace: ID16, key: SigningPublicKey) throws -> UInt32 {
        let signed = try SignedObject.parse(value)
        let o = signed.object
        guard Set(o.keys) == ["kind", "workspace_id", "epoch"], o["kind"] == "rotation_abandon",
              o["workspace_id"] == .string(workspace.hex), let epoch = o["epoch"]?.int,
              epoch > 0, epoch <= Int64(UInt32.max) else { throw Refusal.malformed }
        guard Signature.verify(key, signature: signed.signature, label: label, message: try canonicalJSON(.object(o))) else {
            throw Refusal.badSignature
        }
        return UInt32(epoch)
    }
}
