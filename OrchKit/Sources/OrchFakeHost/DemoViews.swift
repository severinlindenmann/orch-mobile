import Foundation
import OrchClient
import OrchProtocol

/// Descriptive fixtures only. They confer no Drop read/write capability and contain no file bytes.
public struct DemoDropMetadata: Sendable, Equatable {
    public let objectID: ID16
    public let name: String
    public let byteCount: Int
    public let kind: String
}
public struct DemoViewHosts: Sendable {
    public let laptop: FakeHost
    public let clientVM: FakeHost
    public let dropMetadata: [DemoDropMetadata]
}
public extension DemoSetup {
    /// Both hosts still require explicit pairing approval. Names and hostedBy travel only in signed cards.
    static func makeViewHosts(_ env: DemoEnvironment, primary: FakePrimary) throws -> DemoViewHosts {
        DemoViewHosts(laptop: try makeHost(env, primary: primary, name: "Laptop"),
                      clientVM: try makeHost(env, primary: primary, name: "Client VM", clientHosted: true, hostedBy: "Example Client"),
                      dropMetadata: [DemoDropMetadata(objectID: env.entropy.id16(), name: "Review notes.txt", byteCount: 1024, kind: "file"),
                                     DemoDropMetadata(objectID: env.entropy.id16(), name: "Pairing checklist", byteCount: 120, kind: "note")])
    }
}
