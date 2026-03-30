import Foundation

/// Commands that can be sent from the CLI to the running ScrollWM instance.
public enum ScrollWMCommand: String, Codable, CaseIterable, Sendable {
    case focusLeft = "focus-left"
    case focusRight = "focus-right"
    case moveColumnLeft = "move-column-left"
    case moveColumnRight = "move-column-right"
    case cycleWidthPreset = "cycle-width-preset"
    case toggleFullWidth = "toggle-full-width"
    case toggleFloating = "toggle-floating"
    case closeWindow = "close-window"
    case listWindows = "list-windows"
    case getLayout = "get-layout"
    case recover = "recover"
    case quit = "quit"
}

/// Response from the ScrollWM daemon.
public struct ScrollWMResponse: Codable, Sendable {
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
public func scrollWMSocketPath() -> String {
    let uid = getuid()
    return "/tmp/scrollwm_\(uid).sock"
}
