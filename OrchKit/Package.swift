// swift-tools-version: 6.0
import PackageDescription

// unsafeFlags is deliberate: this is a local root package only, never a remote dependency.
let package = Package(
    name: "OrchKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "OrchProtocol", targets: ["OrchProtocol"]),
        .library(name: "OrchCustody", targets: ["OrchCustody"]),
        .library(name: "OrchCoordination", targets: ["OrchCoordination"]),
        .library(name: "OrchStore", targets: ["OrchStore"]),
        .library(name: "OrchShareStaging", targets: ["OrchShareStaging"]),
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
        // Foundation only: tombstone coordination files, atomic writes, flock. The only non-protocol module an extension needs to honour removal.
        .target(name: "OrchCoordination", dependencies: [],
                swiftSettings: [.unsafeFlags(["-application-extension", "-strict-concurrency=complete"])]),
        .testTarget(name: "OrchCoordinationTests", dependencies: ["OrchCoordination"]),
        .target(name: "OrchStore", dependencies: ["OrchProtocol", "OrchCoordination"],
                swiftSettings: [.unsafeFlags(["-application-extension", "-strict-concurrency=complete"])]),
        .testTarget(name: "OrchStoreTests", dependencies: ["OrchStore"]),
        // Extension-safe share staging (Foundation only): with OrchUI and OrchCoordination, all the share extension links.
        .target(name: "OrchShareStaging", dependencies: ["OrchCoordination"],
                swiftSettings: [.unsafeFlags(["-application-extension", "-strict-concurrency=complete"])]),
        .testTarget(name: "OrchShareStagingTests", dependencies: ["OrchShareStaging", "OrchCoordination", "OrchStore"]),
        .target(name: "OrchPush", dependencies: ["OrchProtocol", "OrchCoordination"],
                swiftSettings: [.unsafeFlags(["-application-extension", "-strict-concurrency=complete"])]),
        .testTarget(name: "OrchPushTests", dependencies: ["OrchPush", "OrchProtocol", "OrchStore", "OrchCoordination", "OrchCustody", "OrchTestVectors", "OrchPushFixtures"]),
        // Test-only: seals push fixtures from test keys. Not a product; the script and the UI tests compile this one file.
        .target(name: "OrchPushFixtures", dependencies: ["OrchProtocol"], path: "Tests/OrchPushFixtures"),
        .target(name: "OrchClient", dependencies: ["OrchProtocol", "OrchCustody", "OrchStore"],
                swiftSettings: [.unsafeFlags(["-application-extension", "-strict-concurrency=complete"])]),
        .testTarget(name: "OrchClientTests", dependencies: ["OrchClient", "OrchProtocol", "OrchCustody", "OrchStore"]),
        .target(name: "OrchFakeHost", dependencies: ["OrchProtocol", "OrchCustody", "OrchStore", "OrchClient"],
                swiftSettings: [.unsafeFlags(["-application-extension", "-strict-concurrency=complete"])]),
        .testTarget(name: "OrchFakeHostTests",
                    dependencies: ["OrchFakeHost", "OrchClient", "OrchProtocol", "OrchCustody", "OrchStore", "OrchTestVectors"]),
        // Public API only (host-api section 7): ordinary imports, no @testable, no package-level signers, no vector keys.
        .testTarget(name: "OrchC1PublicAPITests", dependencies: ["OrchFakeHost", "OrchClient", "OrchProtocol", "OrchCustody", "OrchStore"]),
        .target(name: "OrchUI", dependencies: [],
                swiftSettings: [.unsafeFlags(["-application-extension", "-strict-concurrency=complete"])]),
        .testTarget(name: "OrchUITests", dependencies: ["OrchUI"]),
    ],
    swiftLanguageModes: [.v6]
)
