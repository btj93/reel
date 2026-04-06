// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Reel",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Reel", targets: ["Reel"]),
        .executable(name: "reel-msg", targets: ["ReelCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        // Main app
        .executableTarget(
            name: "Reel",
            dependencies: ["Core", "Platform", "WindowManager", "Config", "IPC"],
            path: "Sources/Reel"
        ),

        // CLI client
        .executableTarget(
            name: "ReelCLI",
            dependencies: ["IPC"],
            path: "Sources/ReelCLI"
        ),

        // Core: pure layout logic (Foundation only, no AppKit)
        .target(
            name: "Core",
            path: "Sources/Core"
        ),

        // Platform: macOS API wrappers
        .target(
            name: "Platform",
            dependencies: ["Core", "Config"],
            path: "Sources/Platform"
        ),

        // WindowManager: orchestration
        .target(
            name: "WindowManager",
            dependencies: ["Core", "Platform", "Config", "IPC"],
            path: "Sources/WindowManager"
        ),

        // Config: TOML configuration
        .target(
            name: "Config",
            dependencies: ["Core", "TOMLKit"],
            path: "Sources/Config",
            resources: [.copy("config.default.toml")]
        ),

        // IPC: shared command definitions + socket client/server
        .target(
            name: "IPC",
            dependencies: ["Core"],
            path: "Sources/IPC"
        ),

        // Tests (executable — no Xcode required)
        .executableTarget(
            name: "RunTests",
            dependencies: ["Core", "Config", "WindowManager"],
            path: "Tests/CoreTests"
        ),
    ]
)
