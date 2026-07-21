import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Core

/// Wraps an AXUIElement representing a single macOS window.
/// Handles all AX quirks: double-resize, AXEnhancedUserInterface toggle,
/// messaging timeout, and typed error handling.
///
/// `open` for testing only — the test target subclasses this to inject fake AX
/// behavior without touching real windows. Do NOT subclass in `Sources/`.
open class AXWindow: @unchecked Sendable {
    /// The underlying AX element reference.
    public let element: AXUIElement

    /// The CGWindowID for this window.
    public let windowID: CGWindowID

    /// The owning application's PID.
    public let pid: pid_t

    /// The TileID used in the Strip model.
    public let tileID: TileID

    /// Whether AXEnhancedUserInterface is settable on this window. Resolved once
    /// in `init` so the value is immutable thereafter — the lazy `Bool?` it
    /// replaced was a shared mutable field written from the several threads that
    /// call `setFrame` (main + the AX write queue), a data race (finding #8).
    private let enhancedUISettable: Bool

    public init(element: AXUIElement, windowID: CGWindowID, pid: pid_t) {
        self.element = element
        self.windowID = windowID
        self.pid = pid
        self.tileID = TileID(windowID)

        // Set aggressive messaging timeout (100ms) to prevent hung apps
        // from blocking for the default 6 seconds.
        AXUIElementSetMessagingTimeout(element, 0.1)

        // Resolve AXEnhancedUserInterface settability up front (bounded by the
        // 100ms timeout above) so `toggleEnhancedUI` never lazily mutates shared
        // state from concurrent setFrame calls (finding #8).
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, "AXEnhancedUserInterface" as CFString, &settable)
        self.enhancedUISettable = settable.boolValue
    }

    // MARK: - Frame Operations

    /// Get the current window frame.
    open func getFrame() -> AXResult<CGRect> {
        let position = getPosition()
        let size = getSize()

        switch (position, size) {
        case (.success(let pos), .success(let sz)):
            return .success(CGRect(origin: pos, size: sz))
        case (.failure(let err), _):
            return .failure(err)
        case (_, .failure(let err)):
            return .failure(err)
        }
    }

    /// Set the window frame using the size→position→size workaround.
    /// This handles macOS constraints where setting position changes size.
    open func setFrame(_ frame: CGRect) -> AXResult<Void> {
        // Temporarily disable AXEnhancedUserInterface to prevent app animations
        let wasEnhanced = toggleEnhancedUI(false)

        // The canonical sequence (from AeroSpace):
        // 1. Set size (triggers macOS constraint calculation)
        // 2. Set position (moves the window)
        // 3. Set size again (corrects any constraint-induced size changes)
        let r1 = setSize(frame.size)
        let r2 = setPosition(frame.origin)
        let r3 = setSize(frame.size)

        // Restore AXEnhancedUserInterface
        if wasEnhanced {
            toggleEnhancedUI(true)
        }

        // Return the first error encountered, if any
        if case .failure(let err) = r1 { return .failure(err) }
        if case .failure(let err) = r2 { return .failure(err) }
        if case .failure(let err) = r3 { return .failure(err) }
        return .success(())
    }

    /// Set position only (cheaper than full setFrame during animation).
    open func setPosition(_ point: CGPoint) -> AXResult<Void> {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else {
            return .failure(.transientFailure(.failure))
        }
        let err = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        if err == .success { return .success(()) }
        return .failure(.from(err))
    }

    /// Set size only.
    open func setSize(_ size: CGSize) -> AXResult<Void> {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else {
            return .failure(.transientFailure(.failure))
        }
        let err = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        if err == .success { return .success(()) }
        return .failure(.from(err))
    }

    // MARK: - Window Properties

    /// Get the current position.
    open func getPosition() -> AXResult<CGPoint> {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value)
        guard err == .success else { return .failure(.from(err)) }

        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else {
            return .failure(.transientFailure(.failure))
        }
        return .success(point)
    }

    /// Get the current size.
    open func getSize() -> AXResult<CGSize> {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)
        guard err == .success else { return .failure(.from(err)) }

        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else {
            return .failure(.transientFailure(.failure))
        }
        return .success(size)
    }

    /// Get the window title.
    open func getTitle() -> String? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        guard err == .success else { return nil }
        return value as? String
    }

    /// Get the AX role (e.g., "AXWindow").
    open func getRole() -> String? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        guard err == .success else { return nil }
        return value as? String
    }

    /// Get the AX subrole (e.g., "AXStandardWindow", "AXDialog").
    open func getSubrole() -> String? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value)
        guard err == .success else { return nil }
        return value as? String
    }

    /// Check if the window is minimized.
    open func isMinimized() -> Bool {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value)
        guard err == .success else { return false }
        return (value as? Bool) ?? false
    }

    /// Check if the window is in native fullscreen.
    open func isFullscreen() -> Bool {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &value)
        guard err == .success else { return false }
        return (value as? Bool) ?? false
    }

    /// Check if the window is resizable.
    open func isResizable() -> Bool {
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable)
        return err == .success && settable.boolValue
    }

    /// Check if the window has a close button.
    open func hasCloseButton() -> Bool {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &value)
        return err == .success && value != nil
    }

    /// Check if the window has a minimize button.
    open func hasMinimizeButton() -> Bool {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXMinimizeButtonAttribute as CFString, &value)
        return err == .success && value != nil
    }

    /// Check if the window has a zoom (maximize/fullscreen) button.
    open func hasZoomButton() -> Bool {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXZoomButtonAttribute as CFString, &value)
        return err == .success && value != nil
    }

    /// Build WindowProperties for classification.
    open func getProperties() -> WindowProperties {
        WindowProperties(
            role: getRole(),
            subrole: getSubrole(),
            isResizable: isResizable(),
            hasCloseButton: hasCloseButton(),
            hasMinimizeButton: hasMinimizeButton(),
            hasZoomButton: hasZoomButton(),
            isMinimized: isMinimized(),
            isFullscreen: isFullscreen(),
            windowLayer: 0,  // Will be set from CGWindowList data
            bundleIdentifier: nil,  // Set by WindowTracker
            title: getTitle(),
            frame: try? getFrame().get()
        )
    }

    /// Fast classification-only properties. Skips hasMinimizeButton and
    /// hasZoomButton which are not consulted by `classifyWindow`.
    open func getPropertiesFast() -> WindowProperties {
        WindowProperties(
            role: getRole(),
            subrole: getSubrole(),
            isResizable: isResizable(),
            hasCloseButton: hasCloseButton(),
            hasMinimizeButton: false,
            hasZoomButton: false,
            isMinimized: isMinimized(),
            isFullscreen: isFullscreen(),
            windowLayer: 0,
            bundleIdentifier: nil,
            title: getTitle(),
            frame: try? getFrame().get()
        )
    }

    // MARK: - Focus

    /// Raise the window to the front.
    open func raise() -> AXResult<Void> {
        let err = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        if err == .success { return .success(()) }
        return .failure(.from(err))
    }

    /// Close the window by pressing its close button via AX.
    open func close() -> AXResult<Void> {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &value)
        guard err == .success, let closeButton = value else {
            return .failure(.from(err == .success ? .failure : err))
        }
        let pressErr = AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
        if pressErr == .success { return .success(()) }
        return .failure(.from(pressErr))
    }

    /// Give this window keyboard focus: activate the owning app, set it as the
    /// focused window, and raise it.
    open func focus() {
        // Activate the owning application
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: .activateIgnoringOtherApps)
        }

        // Set this window as the app's focused/main window
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, element)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)

        // Raise to front
        let _ = raise()
    }

    // MARK: - Enhanced UI Toggle

    /// Toggle AXEnhancedUserInterface. Returns the previous value.
    @discardableResult
    private func toggleEnhancedUI(_ enabled: Bool) -> Bool {
        guard enhancedUISettable else { return false }

        var currentValue: AnyObject?
        let getErr = AXUIElementCopyAttributeValue(
            element, "AXEnhancedUserInterface" as CFString, &currentValue
        )
        let wasEnabled = getErr == .success && (currentValue as? Bool) == true

        AXUIElementSetAttributeValue(
            element, "AXEnhancedUserInterface" as CFString, enabled as CFBoolean
        )

        return wasEnabled
    }
}
