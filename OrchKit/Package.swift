// swift-tools-version: 6.0
import PackageDescription

// unsafeFlags is deliberate: this is a local root package only, never a remote dependency.
let package = Package(
    name: "OrchKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "OrchProtocol", targets: ["OrchProtocol"]),
        .library(name: "OrchCustody", targets: ["OrchCustody"]),
        .library(name: "OrchStore", targets: ["OrchStore"]),
        .library(name: "OrchPush", targets: ["OrchPush"]),
        .library(name: "OrchClient", targets: ["OrchClient"]),
        .library(name: "OrchFakeHost", targets: ["OrchFakeHost"]),
        .library(name: "OrchUI", targets: ["OrchUI"]),
    ],
    targets: [
        .target(name: "OrchProtocol", dependencies: [],
                swiftSettings: [.unsafeFlags(["-application-extension", "-strict-concurrency=complete"])]),
        // Test-only: the single copy of the protocol vectors. Not a product, never linked into the app.
        .target(name: "OrchTestVectors", path: "Tests/OrchTestVectors", exclude: ["PROVENANCE.md"],
                resources: [.copy("vectors_v2.json")]),
        .testTarget(name: "OrchProtocolTests", dependencies: ["OrchProtocol", "OrchTestVectors"]),
        .target(name: "OrchCustody", dependencies: ["OrchProtocol"],
                swiftSettings: [.unsafeFlags(["-application-extension", "-strict-concurrency=complete"])]),
        .testTarget(name: "OrchCustodyTests", dependencies: ["OrchCustody"]),
        .target(name: "OrchStore", dependencies: ["OrchProtocol"],
                swiftSettings: [.unsafeFlags(["-application-extension", "-strict-concurrency=complete"])]),
        .testTarget(name: "OrchStoreTests", dependencies: ["OrchStore"]),
        .target(name: "OrchPush", dependencies: ["OrchProtocol"],
                swiftSettings: [.unsafeFlags(["-application-extension", "-strict-concurrency=complete"])]),
        .testTarget(name: "OrchPushTests", dependencies: ["OrchPush", "OrchProtocol", "OrchTestVectors"]),
        .target(name: "OrchClient", dependencies: ["OrchProtocol", "OrchCustody", "OrchStore"],
                swiftSettings: [.unsafeFlags(["-application-extension", "-strict-concurrency=complete"])]),
        .testTarget(name: "OrchClientTests", dependencies: ["OrchClient"]),
        .target(name: "OrchFakeHost", dependencies: ["OrchProtocol", "OrchClient"],
                swiftSettings: [.unsafeFlags(["-application-extension", "-strict-concurrency=complete"])]),
        .testTarget(name: "OrchFakeHostTests", dependencies: ["OrchFakeHost"]),
        .target(name: "OrchUI", dependencies: [],
                swiftSettings: [.unsafeFlags(["-application-extension", "-strict-concurrency=complete"])]),
        .testTarget(name: "OrchUITests", dependencies: ["OrchUI"]),
    ],
    swiftLanguageModes: [.v6]
)
