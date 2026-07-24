// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BuzzKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BuzzKit", targets: ["BuzzKit"]),
    ],
    dependencies: [
        .package(path: "../NostrCore"),
        // Pinned exact so a dependency bump is a reviewed change, not a silent
        // resolve. GRDB 7 is the persistence layer (ADR-0003): value
        // observation, a WAL DatabasePool, and raw-SQL migrations without an ORM.
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "BuzzKit",
            dependencies: [
                "NostrCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "BuzzKitTests",
            dependencies: [
                "BuzzKit",
                // The scripted `FakeHTTPTransport` the window-client tests drive,
                // shared from NostrCore rather than duplicated here.
                .product(name: "NostrCoreTestSupport", package: "NostrCore"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [
                .copy("Fixtures/window-head-response.json"),
                // A real populated NIP-CW window captured from the Buzz Pi relay by the
                // step-7 live integration suite (see WindowPiFixtureTests).
                .copy("Fixtures/window-head-response-pi.json"),
            ]
        ),
    ]
)
