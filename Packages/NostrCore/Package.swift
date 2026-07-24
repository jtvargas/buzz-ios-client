// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NostrCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NostrCore", targets: ["NostrCore"]),
        // Test-only doubles (e.g. `FakeHTTPTransport`) shared across test targets.
        // A library product, not because anything ships it — it holds no
        // production code — but so BuzzKit's test target can link the same fakes
        // NostrCore's tests use, instead of a duplicated copy. Nothing in `App/`
        // or a production target depends on it.
        .library(name: "NostrCoreTestSupport", targets: ["NostrCoreTestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.23.2"),
    ],
    targets: [
        .target(
            name: "NostrCore",
            dependencies: [
                .product(name: "P256K", package: "swift-secp256k1"),
            ]
        ),
        // Shared test-support library: the scripted transport doubles, importable
        // by any test target. Depends only on NostrCore's public surface, ships no
        // production code, and is linked exclusively by test targets.
        .target(
            name: "NostrCoreTestSupport",
            dependencies: ["NostrCore"]
        ),
        .testTarget(
            name: "NostrCoreTests",
            dependencies: [
                "NostrCore",
                "NostrCoreTestSupport",
                .product(name: "P256K", package: "swift-secp256k1"),
            ],
            resources: [
                .copy("nip44.vectors.json"),
                .copy("bip340-test-vectors.csv"),
            ]
        ),
    ]
)
