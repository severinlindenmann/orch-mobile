import Foundation
import OrchClient
import OrchFakeHost
import OrchProtocol
@testable import OrchProtocol

/// Test-only helpers that build objects no honest actor would: signed by a stranger.
enum FakeHostForgery {
    static func list(workspace: ID16, members: [(ID16, [String])], seq: Int64) throws -> JSONValue {
        try SignedObject.sign([
            "v": 2, "suite": 2, "kind": "member_list", "workspace_id": .string(workspace.hex), "epoch": 1, "list_seq": .int(seq), "issued_ms": 0,
            "persons": [], "wk_commit": .string(B64U.encode(Data(count: 32))),
            "members": .array(members.sorted { $0.0.hex < $1.0.hex }.map { .object(["device_id": .string($0.0.hex), "person_id": .string(ID16.random().hex),
                                                                                     "scopes": .array($0.1.map { .string($0) })]) })],
                              kind: .memberList, signer: SoftwareSigner()).json
    }

    static func cert(by pk: SoftwareSigner, for keys: DemoKeys) throws -> JSONValue {
        try SignedObject.sign([
            "v": 2, "suite": 2, "kind": "device_cert", "device_id": .string(keys.deviceID.hex),
            "person_id": .string(Identifiers.personID(pk.publicKey).hex), "dk_sig_pub": .string(B64U.encode(keys.sig.x963)),
            "dk_kx_pub": .string(B64U.encode(keys.kx.x963)), "label_sealed": .string(B64U.encode(Data(count: 40))), "created_ms": 1_790_000_000_000,
            "expires_ms": .null, "scopes_max": ["look"]], kind: .deviceCert, signer: pk).json
    }
}

enum DemoCapabilityForTests {
    /// In-package tests may mint a capability directly (package access); the public-API target cannot.
    static func mint() -> DemoCapability { DemoCapability(id: ID16.random()) }
}
