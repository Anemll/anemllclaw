// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OpenClawGatewayCore",
    platforms: [
        .iOS(.v18),
        .tvOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "OpenClawGatewayCore",
            targets: ["OpenClawGatewayCore"]),
    ],
    targets: [
        .target(
            name: "OpenClawGatewayCore",
            path: "Sources/OpenClawGatewayCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]),
        .testTarget(
            name: "OpenClawGatewayCoreTests",
            dependencies: ["OpenClawGatewayCore"],
            path: "Tests/OpenClawGatewayCoreTests",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
    ])
