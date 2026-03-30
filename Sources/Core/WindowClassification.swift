import Foundation

/// How a window should be managed by the window manager.
public enum WindowClassification: Sendable {
    /// Window should be tiled on the horizontal strip.
    case tile
    /// Window should float above the strip (dialogs, panels, etc.).
    case float
    /// Window should be ignored entirely (menus, tooltips, system UI).
    case ignore
}

/// Raw window properties used for classification.
/// This struct is populated from AX queries and CGWindowList info.
public struct WindowProperties: Sendable {
    public var role: String?           // kAXRoleAttribute
    public var subrole: String?        // kAXSubroleAttribute
    public var isResizable: Bool
    public var hasCloseButton: Bool
    public var hasMinimizeButton: Bool
    public var hasZoomButton: Bool
    public var isMinimized: Bool
    public var isFullscreen: Bool
    public var windowLayer: Int        // CGWindowList kCGWindowLayer (0 = normal)
    public var bundleIdentifier: String?
    public var title: String?

    public init(
        role: String? = nil,
        subrole: String? = nil,
        isResizable: Bool = true,
        hasCloseButton: Bool = true,
        hasMinimizeButton: Bool = true,
        hasZoomButton: Bool = true,
        isMinimized: Bool = false,
        isFullscreen: Bool = false,
        windowLayer: Int = 0,
        bundleIdentifier: String? = nil,
        title: String? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.isResizable = isResizable
        self.hasCloseButton = hasCloseButton
        self.hasMinimizeButton = hasMinimizeButton
        self.hasZoomButton = hasZoomButton
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.windowLayer = windowLayer
        self.bundleIdentifier = bundleIdentifier
        self.title = title
    }
}

/// Classify a window based on its properties.
public func classifyWindow(_ props: WindowProperties) -> WindowClassification {
    // Non-zero window layer = overlay/system UI → ignore
    if props.windowLayer != 0 {
        return .ignore
    }

    // Fullscreen windows are not managed (they live in their own Space)
    if props.isFullscreen {
        return .ignore
    }

    // Minimized windows should still be tiled (we track them and re-tile on deminimize)
    // Don't ignore them — classify normally but callers can check isMinimized

    // Check role/subrole
    let role = props.role ?? ""
    let subrole = props.subrole ?? ""

    // Menus, popovers, tooltips → ignore
    if role == "AXMenu" || role == "AXPopover" || subrole == "AXToolTip" {
        return .ignore
    }

    // Sheets and system dialogs → float
    if role == "AXSheet" || subrole == "AXSystemDialog" {
        return .float
    }

    // AXDialog with close button and resizable = likely a real app window (TablePlus, OrbStack, etc.)
    // AXDialog without close button = actual dialog → float
    if subrole == "AXDialog" {
        if props.hasCloseButton && props.isResizable {
            return .tile
        }
        return .float
    }

    // Floating/utility windows → float
    if subrole == "AXFloatingWindow" || subrole == "AXUtilityWindow" {
        return .float
    }

    // Standard windows that are resizable with a close button → tile
    if subrole == "AXStandardWindow" && props.isResizable && props.hasCloseButton {
        return .tile
    }

    // Windows with a close button but not resizable → float (e.g., About windows, preferences)
    if props.hasCloseButton && !props.isResizable {
        return .float
    }

    // Windows with no close button → ignore (likely system UI)
    if !props.hasCloseButton {
        return .ignore
    }

    // Default: tile if it looks like a real window
    if role == "AXWindow" {
        return .tile
    }

    return .ignore
}
