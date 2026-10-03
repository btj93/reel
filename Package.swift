// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Reel",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Reel", targets: ["Reel"]),
        .executable(name: "reel-msg", targets: ["ReelCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .target(name: "Engine", dependencies: ["Core", "TOMLKit"]),
        .executableTarget(name: "RunEngineTests", dependencies: ["Engine", "Core", "Runtime", "Platform"], path: "Tests/EngineTests"),
        // The new runtime: turns macOS observations into Engine events and executes its effects.
        .target(name: "Runtime", dependencies: ["Engine", "Core", "Platform", "IPC", "Config"]),
        .executableTarget(name: "ReelNext", dependencies: ["Runtime"]),
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
            dependencies: ["Core", "Config", "IPC", "WindowManager", "Platform", "Engine", "Runtime"],
            path: "Tests/CoreTests"
        ),

        // E2E smoke helper: hosts plain NSWindows driven over stdin/stdout (no product —
        // test-only, mirrors RunTests). Needs no Accessibility permission.
        .executableTarget(
            name: "TestWindowHost",
            path: "Tests/E2E/TestWindowHost"
        ),
    ],
    swiftLanguageModes: [.v6]
)
