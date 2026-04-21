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
    case listPositions = "list-positions"
    case clearPositions = "clear-positions"
    case recover = "recover"
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
public func reelSocketPath() -> String {
    let uid = getuid()
    return "/tmp/reel_\(uid).sock"
}

public struct IPCMessage: Codable, Sendable {
    public let command: String
    public var appID: String?

    public init(command: String, appID: String? = nil) {
        self.command = command
        self.appID = appID
    }
}
