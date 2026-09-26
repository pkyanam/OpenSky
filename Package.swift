// swift-tools-version: 6.4
// OpenSky — clean-room macOS computer-use framework (Apple Silicon).
// Interface modeled on the ChatGPT.app Computer Use API surface (spec-only);
// implementation is entirely on public macOS frameworks. MIT licensed.

import PackageDescription

let package = Package(
    name: "OpenSky",
    platforms: [.macOS(.v14)],
    products: [
        // Reusable framework exposing the client API.
        .library(name: "OpenSkyKit", targets: ["OpenSkyKit"]),
        // Human/agent CLI (`opensky ...`), with --help and --skill for agents.
        .executable(name: "opensky", targets: ["OpenSkyCLI"]),
    ],
    targets: [
        .target(
            name: "OpenSkyKit",
            path: "Sources/OpenSkyKit",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .executableTarget(
            name: "OpenSkyCLI",
            dependencies: ["OpenSkyKit"],
            path: "Sources/OpenSkyCLI",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .testTarget(
            name: "OpenSkyKitTests",
            dependencies: ["OpenSkyKit"],
            path: "Tests/OpenSkyKitTests"
        ),
    ]
)
