import Foundation
import OrchTestVectors
import Testing
@testable import OrchProtocol

/// Replays `origin_http.json` (shared with core, hub, publish, relay) against the phone's plain-http rule, and the pair-link scheme.
struct OriginHTTPTests {
    static let root: JSONValue = { try! StrictJSON.parse(OrchTestVectors.Vectors.originHTTP, maxBytes: .max, maxDepth: 8) }()

    @Test func accepted() {
        let list = Self.root["accept"].items
        #expect(!list.isEmpty)
        for o in list { #expect(RelayURL.isValid(o.str), "\(o.str)") }
    }

    @Test func refused() {
        let list = Self.root["refuse"].items
        #expect(!list.isEmpty)
        for o in list { #expect(!RelayURL.isValid(o.str), "\(o.str)") }
    }

    @Test func pairLinkSchemeFollowsHost() throws {
        let frag = "h1." + String(repeating: "a", count: 32) + "." + String(repeating: "b", count: 32) + ".abcd-abcd-abcd"
        let cgnat = try HubPairLink.parse("orch://hub-pair/100.71.14.98:8101#" + frag, devMode: false)
        #expect(cgnat.api == "http://100.71.14.98:8101")
        let pub = try HubPairLink.parse("orch://hub-pair/hub.example.org#" + frag, devMode: false)
        #expect(pub.api == "https://hub.example.org")
        #expect(throws: Refusal.self) { _ = try HubPairLink.parse("orch://hub-pair/127.0.0.1:8101#" + frag, devMode: false) }
        #expect(try HubPairLink.parse("orch://hub-pair/127.0.0.1:8101#" + frag, devMode: true).api == "http://127.0.0.1:8101")
    }
}
