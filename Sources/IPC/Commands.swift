import Foundation

/// Commands that can be sent from the CLI to the running Reel instance.
public enum ReelCommand: String, Codable, CaseIterable, Sendable {
    case focusLeft = "focus-left"
    case focusRight = "focus-right"
    case focusUp = "focus-up"
    case focusDown = "focus-down"
    case moveColumnLeft = "move-column-left"
    case moveColumnRight = "move-column-right"
    case cycleWidthPreset = "cycle-width-preset"
    case toggleFullWidth = "toggle-full-width"
    case toggleFloating = "toggle-floating"
    case closeWindow = "close-window"
    case listWindows = "list-windows"
    case getLayout = "get-layout"
    case getLayouts = "get-layouts"
    case listPositions = "list-positions"
    case clearPositions = "clear-positions"
    case recover = "recover"
    case pause = "pause"
    case resume = "resume"
    case getStatus = "get-status"
    case reloadConfig = "reload-config"
    case quit = "quit"
}

/// Response from the Reel daemon.
public struct ReelResponse: Codable, Sendable {
    public let success: Bool
    public let message: String?
    public let data: String?  // JSON payload for queries

    public init(success: Bool, message: String? = nil, data: String? = nil) {
        self.success = success
        self.message = message
        self.data = data
    }
}

/// Socket path for IPC.
///
/// Resolution order:
///   1. `REEL_SOCKET_PATH` environment override — used by the test harness to
///      give each run a hermetic, namespaced socket that never collides with a
///      live instance.
///   2. Production default: `reel_<uid>.sock` inside the per-user temporary
///      directory (`NSTemporaryDirectory()`, e.g. `/var/folders/.../T/`). macOS
///      creates that directory mode 0700 owned by the current user, so — unlike
///      the old sticky-bit `/tmp/reel_<uid>.sock` — no other local user can
///      squat the path or bind an impostor socket there.
///
/// Both `SocketServer` and `reel-msg` call this single function, so the server
/// and CLI always agree on the location.
public func reelSocketPath() -> String {
    if let override = ProcessInfo.processInfo.environment["REEL_SOCKET_PATH"], !override.isEmpty {
        return override
    }
    let uid = getuid()
    return (NSTemporaryDirectory() as NSString).appendingPathComponent("reel_\(uid).sock")
}

public struct IPCMessage: Codable, Sendable {
    public let command: String
    public var appID: String?

    public init(command: String, appID: String? = nil) {
        self.command = command
        self.appID = appID
    }
}
