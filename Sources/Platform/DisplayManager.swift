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
    public func workingArea(struts: Struts = .zero, primaryScreenHeight: CGFloat) -> CGRect {
        // Convert visibleFrame from AppKit (bottom-left) to CG (top-left) coordinates
        let cgY = primaryScreenHeight - visibleFrame.maxY

        return CGRect(
            x: visibleFrame.minX + struts.left,
            y: cgY + struts.top,
            width: visibleFrame.width - struts.left - struts.right,
            height: visibleFrame.height - struts.top - struts.bottom
        )
    }
}

/// Configurable insets that shrink the working area (for external bars like SketchyBar).
public struct Struts: Sendable {
    public var left: CGFloat
    public var right: CGFloat
    public var top: CGFloat
    public var bottom: CGFloat

    public static let zero = Struts(left: 0, right: 0, top: 0, bottom: 0)

    public init(left: CGFloat = 0, right: CGFloat = 0, top: CGFloat = 0, bottom: CGFloat = 0) {
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
    }
}

/// Manages display enumeration and hot-plug detection.
public final class DisplayManager: @unchecked Sendable {
    /// Current displays, keyed by displayID.
    public private(set) var displays: [CGDirectDisplayID: DisplayInfo] = [:]

    /// Height of the primary screen in points (for AppKit→CG coordinate conversion).
    public private(set) var primaryScreenHeight: CGFloat = 0

    /// Callback when display configuration changes (including Dock show/hide).
    public var onDisplayChange: (([CGDirectDisplayID: DisplayInfo]) -> Void)?

    private var notificationObserver: NSObjectProtocol?
    private var dockObserver: NSObjectProtocol?
    private var dockPollTimer: Timer?

    public init() {}

    deinit {
        stopObserving()
    }

    // MARK: - Enumeration

    /// Refresh the display list from NSScreen.
    public func refresh() {
        // Primary screen height is needed for AppKit→CG coordinate conversion
        if let primary = NSScreen.screens.first {
            primaryScreenHeight = primary.frame.height
        }
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

    /// Get the main display info.
    public var mainDisplay: DisplayInfo? {
        displays.values.first { $0.isMain } ?? displays.values.first
    }

    // MARK: - Observation

    /// Start observing display configuration changes.
    public func startObserving() {
        refresh()

        // Screen parameter changes (monitor plug/unplug, resolution change)
        notificationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleDisplayChange()
        }

        // Poll for Dock show/hide changes every 1.5 seconds.
        // There's no direct notification for Dock auto-hide state changes,
        // so we poll NSScreen.visibleFrame which changes when the Dock appears/hides.
        var lastVisibleFrame: CGRect = NSScreen.main?.visibleFrame ?? .zero
        dockPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let currentFrame = NSScreen.main?.visibleFrame else { return }
            if currentFrame != lastVisibleFrame {
                lastVisibleFrame = currentFrame
                self?.handleDisplayChange()
            }
        }
    }

    /// Stop observing.
    public func stopObserving() {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
            notificationObserver = nil
        }
        if let observer = dockObserver {
            NotificationCenter.default.removeObserver(observer)
            dockObserver = nil
        }
        dockPollTimer?.invalidate()
        dockPollTimer = nil
    }

    private func handleDisplayChange() {
        let oldDisplays = displays
        refresh()

        // Log changes
        let added = Set(displays.keys).subtracting(oldDisplays.keys)
        let removed = Set(oldDisplays.keys).subtracting(displays.keys)
        #if DEBUG
        if !added.isEmpty { print("[ScrollWM] Displays added: \(added)") }
        if !removed.isEmpty { print("[ScrollWM] Displays removed: \(removed)") }
        #endif

        onDisplayChange?(displays)
    }
}
