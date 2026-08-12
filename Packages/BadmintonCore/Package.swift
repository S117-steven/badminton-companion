// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BadmintonCore",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14),
    ],
    products: [
        .library(name: "BadmintonCore", targets: ["BadmintonCore"]),
    ],
    targets: [
        .target(name: "BadmintonCore"),
        .testTarget(
            name: "BadmintonCoreTests",
            dependencies: ["BadmintonCore"]
        ),
    ]
)
