// swift-tools-version: 6.4
// SkyCUA — clean-room macOS computer-use framework (Apple Silicon).
// Interface modeled on the ChatGPT.app Computer Use API surface (spec-only);
// implementation is entirely on public macOS frameworks.

import PackageDescription

let package = Package(
    name: "SkyCUA",
    products: [
        // Reusable framework exposing the client API.
        .library(name: "SkyCUALib", targets: ["SkyCUALib"]),
        // Demo CLI executable (`sky-cua ...`).
        .executable(name: "sky-cua", targets: ["SkyCUA"]),
    ],
    targets: [
        .target(
            name: "SkyCUALib",
            path: "Sources/SkyCUALib",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .executableTarget(
            name: "SkyCUA",
            dependencies: ["SkyCUALib"],
            path: "Sources/SkyCUA",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .testTarget(
            name: "SkyCUATests",
            dependencies: ["SkyCUALib"],
            path: "Tests/SkyCUATests",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
    ]
)
