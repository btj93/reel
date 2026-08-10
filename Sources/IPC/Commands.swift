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

/// Build a `sockaddr_un` for `path`, or nil when it would overflow `sun_path`.
///
/// `sun_path` is a fixed 104-byte array and the last member of the struct, so
/// copying an unchecked path past its end corrupts adjacent stack memory. The CLI
/// did exactly that while the server guarded correctly — this is the shared guard
/// both now use.
public func makeUnixSockaddr(path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = path.utf8CString
    guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        let bound = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
        for (i, b) in bytes.enumerated() { bound[i] = b }
    }
    return addr
}

/// Exit status for a CLI invocation.
///
/// Nonzero for a daemon-reported failure and for a response that could not be read
/// or decoded — automation must not read truncated or malformed transport as
/// success. Safe to be strict about empty responses only because `quit` no longer
/// races its own reply (termination is triggered after the write is flushed).
public func reelExitCode(for response: ReelResponse?) -> Int32 {
    guard let response else { return 1 }
    return response.success ? 0 : 1
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
