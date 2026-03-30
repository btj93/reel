import CoreGraphics
import Foundation
import Core

/// Action triggered by a hotkey press.
public enum HotkeyAction: Sendable {
    case focusLeft
    case focusRight
    case moveColumnLeft
    case moveColumnRight
    case cycleWidthPreset
    case toggleFullWidth
    case toggleFloating
    case closeWindow
    case workspace(Int)
    case spawnTerminal
}

/// A registered hotkey binding.
public struct HotkeyBinding: Sendable {
    public let modifiers: CGEventFlags
    public let keyCode: CGKeyCode
    public let action: HotkeyAction

    public init(modifiers: CGEventFlags, keyCode: CGKeyCode, action: HotkeyAction) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.action = action
    }
}

/// Manages global hotkeys via CGEventTap.
/// Includes tap health monitoring (re-enable if macOS disables it).
public final class HotkeyManager: @unchecked Sendable {
    var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var bindings: [HotkeyBinding] = []
    private var healthTimer: Timer?

    /// Callback invoked on the main thread when a hotkey is triggered.
    public var onAction: ((HotkeyAction) -> Void)?

    public init() {}

    deinit {
        stop()
    }

    // MARK: - Configuration

    /// Register default hotkey bindings.
    /// Uses Hyper key (Ctrl+Shift+Cmd+Opt) to avoid conflicts.
    public func registerDefaults() {
        let hyper: CGEventFlags = [.maskControl, .maskShift, .maskCommand, .maskAlternate]

        // Hyper = Ctrl+Shift+Cmd+Opt
        // Navigation:  Hyper+H (focus left), Hyper+L (focus right)
        // Reorder:     Hyper+J (move column left), Hyper+K (move column right)
        // Width:       Hyper+R (cycle preset), Hyper+F (toggle full width)
        // Other:       Hyper+Space (toggle float), Hyper+W (close), Hyper+T (terminal)
        bindings = [
            HotkeyBinding(modifiers: hyper, keyCode: 0x04, action: .focusLeft),        // H
            HotkeyBinding(modifiers: hyper, keyCode: 0x25, action: .focusRight),       // L
            HotkeyBinding(modifiers: hyper, keyCode: 0x26, action: .moveColumnLeft),   // J
            HotkeyBinding(modifiers: hyper, keyCode: 0x28, action: .moveColumnRight),  // K
            HotkeyBinding(modifiers: hyper, keyCode: 0x0F, action: .cycleWidthPreset), // R
            HotkeyBinding(modifiers: hyper, keyCode: 0x03, action: .toggleFullWidth),  // F
            HotkeyBinding(modifiers: hyper, keyCode: 0x31, action: .toggleFloating),   // Space
            HotkeyBinding(modifiers: hyper, keyCode: 0x0D, action: .closeWindow),      // W
            HotkeyBinding(modifiers: hyper, keyCode: 0x11, action: .spawnTerminal),    // T
        ]

        // Workspace bindings (Hyper+1 through Hyper+9)
        let numberKeyCodes: [CGKeyCode] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]
        for (i, keyCode) in numberKeyCodes.enumerated() {
            bindings.append(HotkeyBinding(modifiers: hyper, keyCode: keyCode, action: .workspace(i + 1)))
        }
    }

    // MARK: - Lifecycle

    /// Start intercepting keyboard events.
    public func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[ScrollWM] Failed to create CGEventTap — check Accessibility permission")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Start health monitoring — poll every 2 seconds
        startHealthMonitor()

        print("[ScrollWM] Hotkey manager started")
        return true
    }

    /// Stop intercepting and clean up.
    public func stop() {
        healthTimer?.invalidate()
        healthTimer = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Health Monitoring

    /// Poll CGEventTapIsEnabled and re-enable if macOS disabled it.
    /// This happens when: secure input mode, slow callback, permission revoked.
    private func startHealthMonitor() {
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                print("[ScrollWM] Event tap was disabled — re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
    }

    // MARK: - Event Matching

    fileprivate func matchEvent(_ event: CGEvent) -> HotkeyAction? {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        for binding in bindings {
            if binding.keyCode == keyCode && flags.contains(binding.modifiers) {
                return binding.action
            }
        }
        return nil
    }
}

// MARK: - CGEventTap C Callback

private func hotkeyCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Handle tap disabled notification
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            if let tap = manager.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passRetained(event)
    }

    guard type == .keyDown, let userInfo = userInfo else {
        return Unmanaged.passRetained(event)
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()

    if let action = manager.matchEvent(event) {
        // Dispatch action to main thread
        DispatchQueue.main.async {
            manager.onAction?(action)
        }
        // Consume the event (don't pass to apps)
        return nil
    }

    // Not our hotkey — pass through
    return Unmanaged.passRetained(event)
}
