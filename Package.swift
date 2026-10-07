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
        .target(name: "Engine", dependencies: ["Core", "TOMLKit"], resources: [.copy("config.default.toml")]),
        .executableTarget(name: "RunEngineTests", dependencies: ["Engine", "Core", "Runtime", "Platform"], path: "Tests/EngineTests"),
        .target(name: "Runtime", dependencies: ["Engine", "Core", "Platform", "IPC"]),
        .executableTarget(name: "Reel", dependencies: ["Runtime"]),

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
            dependencies: ["Core"],
            path: "Sources/Platform"
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
            dependencies: ["Core", "IPC", "Platform", "Engine", "Runtime"],
            path: "Tests/CoreTests"
        ),

        // E2E smoke helper: hosts plain NSWindows driven over stdin/stdout (no product —
        // test-only, mirrors RunTests). Needs no Accessibility permission.
        .executableTarget(
            name: "TestWindowHost",
            path: "Tests/E2E/TestWindowHost"
        ),

        // Lane-only: posts scroll phases and mouse events from a JSON script; refuses without REEL_E2E_CONFIRM=1.
        .executableTarget(
            name: "InputPoster",
            path: "Tests/E2E/InputPoster"
        ),
    ],
    swiftLanguageModes: [.v6]
)
