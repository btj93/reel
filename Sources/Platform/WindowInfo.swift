import ApplicationServices
import CoreGraphics
import Foundation
import Core

// MARK: - Private API Bridge

/// Bridge to the private _AXUIElementGetWindow function.
/// Maps an AXUIElement to a CGWindowID.
/// This is the only private API used by ScrollWM — no SIP required.
///
/// Validated stable across macOS 10.12–15 by AeroSpace, Amethyst, Hammerspoon.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Get the CGWindowID for an AXUIElement.
public func windowID(for element: AXUIElement) -> CGWindowID? {
    var wid: CGWindowID = 0
    let err = _AXUIElementGetWindow(element, &wid)
    return err == .success ? wid : nil
}

// MARK: - CGWindowList Queries

/// Information about a window from CGWindowListCopyWindowInfo.
public struct CGWindowInfo: Sendable {
    public let windowID: CGWindowID
    public let ownerPID: pid_t
    public let ownerName: String?
    public let bounds: CGRect
    public let layer: Int
    public let alpha: Double
    public let title: String?
    public let isOnScreen: Bool
}

/// Get info about all on-screen windows.
public func getAllWindowInfo() -> [CGWindowInfo] {
    guard let windowList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        return []
    }

    return windowList.compactMap { dict -> CGWindowInfo? in
        guard let wid = dict[kCGWindowNumber as String] as? CGWindowID,
              let pid = dict[kCGWindowOwnerPID as String] as? pid_t else {
            return nil
        }

        let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat]
        let bounds: CGRect
        if let bd = boundsDict {
            bounds = CGRect(
                x: bd["X"] ?? 0,
                y: bd["Y"] ?? 0,
                width: bd["Width"] ?? 0,
                height: bd["Height"] ?? 0
            )
        } else {
            bounds = .zero
        }

        return CGWindowInfo(
            windowID: wid,
            ownerPID: pid,
            ownerName: dict[kCGWindowOwnerName as String] as? String,
            bounds: bounds,
            layer: dict[kCGWindowLayer as String] as? Int ?? 0,
            alpha: dict[kCGWindowAlpha as String] as? Double ?? 1.0,
            title: dict[kCGWindowName as String] as? String,
            isOnScreen: dict[kCGWindowIsOnscreen as String] as? Bool ?? true
        )
    }
}

/// Get the window layer for a given CGWindowID (0 = normal).
public func windowLayer(for windowID: CGWindowID) -> Int {
    guard let windowList = CGWindowListCopyWindowInfo(
        [.optionIncludingWindow],
        windowID
    ) as? [[String: Any]],
          let first = windowList.first else {
        return 0
    }
    return first[kCGWindowLayer as String] as? Int ?? 0
}

// MARK: - Application Window Discovery

/// Get all AXUIElement windows for a given application PID.
public func getAppWindows(pid: pid_t) -> [AXUIElement] {
    let appElement = AXUIElementCreateApplication(pid)

    var value: AnyObject?
    let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
    guard err == .success, let windows = value as? [AXUIElement] else {
        return []
    }

    return windows
}

/// Create AXWindow instances for all windows of an application.
public func discoverWindows(pid: pid_t) -> [AXWindow] {
    let elements = getAppWindows(pid: pid)

    return elements.compactMap { element -> AXWindow? in
        guard let wid = windowID(for: element) else { return nil }
        return AXWindow(element: element, windowID: wid, pid: pid)
    }
}
