import AppKit
import CoreGraphics
import Foundation

/// Represents a connected display/monitor.
public struct DisplayInfo: Sendable {
    public let displayID: CGDirectDisplayID
    public let frame: CGRect          // Full display frame (AppKit coords)
    public let visibleFrame: CGRect   // Minus menu bar, dock (AppKit coords)
    public let isMain: Bool
    public let refreshRate: Double    // Hz (e.g., 60, 120)

    /// Working area for AX window placement, in CG coordinates (top-left origin).
    /// NSScreen.visibleFrame is in AppKit coords (bottom-left origin).
    /// AXUIElement positioning uses CG coords (top-left origin).
    /// We must convert: CG_y = primaryScreenHeight - AppKit_y - height
    public func workingArea(primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: visibleFrame.minX, y: primaryScreenHeight - visibleFrame.maxY,
               width: visibleFrame.width, height: visibleFrame.height)
    }

    /// The full display frame in CG coordinates (top-left origin), the space AX frames and cursor points live in.
    public func cgFrame(primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryScreenHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    public init(
        displayID: CGDirectDisplayID,
        frame: CGRect,
        visibleFrame: CGRect,
        isMain: Bool,
        refreshRate: Double
    ) {
        self.displayID = displayID
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isMain = isMain
        self.refreshRate = refreshRate
    }
}

/// Reads NSScreen facts. Runtime owns topology observation.
@MainActor
public final class DisplayManager {
    /// Current displays, keyed by displayID.
    public private(set) var displays: [CGDirectDisplayID: DisplayInfo] = [:]

    /// Height of the primary screen in points (for AppKit→CG coordinate conversion).
    public private(set) var primaryScreenHeight: CGFloat = 0

    public init() {}

    // MARK: - Enumeration

    /// Refresh the display list from NSScreen.
    public func refresh() {
        // Primary screen height anchors AppKit→CG coordinate conversion.
        // Use CGMainDisplayID(), not screens[0], which is not guaranteed to be primary.
        // Preserve the last valid value if the lookup chain returns nil (transient
        // during hot-plug reconfigure): a 0 height would silently corrupt every
        // subsequent Y conversion.
        let mainID = CGMainDisplayID()
        let primary: NSScreen? = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == mainID
        }) ?? NSScreen.main ?? NSScreen.screens.first

        if let h = primary?.frame.height {
            primaryScreenHeight = h
        }
        #if DEBUG
        if primary == nil {
            print("[DisplayManager] refresh(): no primary screen resolved; keeping primaryScreenHeight=\(primaryScreenHeight)")
            fflush(stdout)
        }
        #endif
        var newDisplays: [CGDirectDisplayID: DisplayInfo] = [:]

        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                continue
            }

            let refreshRate: Double
            if let mode = CGDisplayCopyDisplayMode(displayID) {
                refreshRate = mode.refreshRate > 0 ? mode.refreshRate : 60
            } else {
                refreshRate = 60
            }

            newDisplays[displayID] = DisplayInfo(
                displayID: displayID,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                isMain: screen == NSScreen.main,
                refreshRate: refreshRate
            )
        }

        displays = newDisplays
    }

}
