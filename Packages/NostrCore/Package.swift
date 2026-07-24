// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NostrCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NostrCore", targets: ["NostrCore"]),
    ],
    targets: [
        .target(name: "NostrCore"),
        .testTarget(name: "NostrCoreTests", dependencies: ["NostrCore"]),
    ]
)
