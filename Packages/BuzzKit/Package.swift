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
    ],
    targets: [
        .target(name: "BuzzKit", dependencies: ["NostrCore"]),
        .testTarget(name: "BuzzKitTests", dependencies: ["BuzzKit"]),
    ]
)
