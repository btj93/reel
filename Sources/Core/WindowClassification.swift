import CoreGraphics
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
    /// Current AX-reported frame (nil if unknown). Used to reject popups that
    /// otherwise look like a tileable standard window (e.g., autocomplete
    /// dropdowns that mis-report as AXStandardWindow + resizable + closeBtn).
    public var frame: CGRect?

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
        title: String? = nil,
        frame: CGRect? = nil
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
        self.frame = frame
    }
}

/// Minimum width an AXStandardWindow must report to be considered a tileable
/// document window. Anything narrower is almost certainly a popup (autocomplete
/// dropdown, command palette, branch picker) — these can mis-report subrole as
/// AXStandardWindow with resizable=true and a close button.
public let minTileableWidth: CGFloat = 350
public let minTileableHeight: CGFloat = 250

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

    // Standard windows that are resizable with a close button → tile.
    // Exceptions (both indicate a transient popup misreporting as
    // AXStandardWindow — autocomplete menus, branch pickers, command palettes):
    //   1. Empty / nil title.
    //   2. Frame smaller than the minimum tileable size in either dimension.
    // Float those so they don't get inserted as strip columns.
    if subrole == "AXStandardWindow" && props.isResizable && props.hasCloseButton {
        let hasUsableTitle = !(props.title?.isEmpty ?? true)
        if !hasUsableTitle {
            return .float
        }
        if let f = props.frame,
           (f.width < minTileableWidth || f.height < minTileableHeight) {
            return .float
        }
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
