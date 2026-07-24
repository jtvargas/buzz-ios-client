// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NostrCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NostrCore", targets: ["NostrCore"]),
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
        .testTarget(
            name: "NostrCoreTests",
            dependencies: [
                "NostrCore",
                .product(name: "P256K", package: "swift-secp256k1"),
            ]
        ),
    ]
)
