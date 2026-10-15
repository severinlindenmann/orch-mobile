import Foundation
import OrchClient
import OrchProtocol

/// Compatibility type for earlier UI wiring. Demo files now come from DropService.
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
        DemoViewHosts(laptop: try makeHost(env, primary: primary, name: "Laptop", demoDropFixtures: true),
                      clientVM: try makeHost(env, primary: primary, name: "Client VM", clientHosted: true, hostedBy: "Example Client", demoDropFixtures: true),
                      dropMetadata: [])
    }
}

public extension DemoSetup {
    /// Phone-authored Sending fixture. Called after pairing a phone with operate scope; the host
    /// never receives the phone's signing handle. The returned object is a real durable upload.
    @discardableResult
    static func seedDropSending(_ service: DropService) async throws -> DropObject {
        try await service.requireDemo()
        return try await service.send(Data("Sent from the Demo phone.\n".utf8), name: "phone-note.txt", mime: "text/plain")
    }
}
