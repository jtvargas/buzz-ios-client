// swift-tools-version: 6.0
import PackageDescription

/// What the app and its Notification Service Extension share for push: the App
/// Group that carries per-community snapshots from one to the other, the single
/// way either process opens an identity key, and — as the push tickets land —
/// the enrolment and resolution logic the extension runs on a wake.
///
/// Its own package, rather than files in `App/Sources`, because the extension is
/// a second binary with a 24 MB ceiling: it links this and NostrCore, and nothing
/// of the app's UI, GRDB or BuzzKit. macOS is listed beside iOS, as in the sibling
/// packages, so `swift test` runs the suite on the host without a simulator; the
/// file-protection option the snapshot store writes with has been in Foundation
/// on macOS since 11, so nothing here is iOS-only.
let package = Package(
    name: "HivePushKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HivePushKit", targets: ["HivePushKit"]),
    ],
    dependencies: [
        .package(path: "../NostrCore"),
    ],
    targets: [
        .target(
            name: "HivePushKit",
            dependencies: ["NostrCore"]
        ),
        .testTarget(
            name: "HivePushKitTests",
            dependencies: ["HivePushKit"]
        ),
    ]
)
