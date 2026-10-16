// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WCleanerCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WCleanerCore", targets: ["WCleanerCore"]),
    ],
    targets: [
        .target(
            name: "WCleanerCore",
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "WCleanerCoreTests",
            dependencies: ["WCleanerCore"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
    ]
)
