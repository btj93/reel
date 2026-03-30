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

    /// Register hotkey bindings from a config dictionary.
    /// Keys are action names, values are key strings like "hyper-h", "ctrl-shift-l".
    public func registerFromConfig(_ keybindingMap: [String: String]) {
        bindings = []

        let actionMap: [String: HotkeyAction] = [
            "focus_left": .focusLeft,
            "focus_right": .focusRight,
            "move_left": .moveColumnLeft,
            "move_right": .moveColumnRight,
            "cycle_width": .cycleWidthPreset,
            "toggle_full_width": .toggleFullWidth,
            "toggle_floating": .toggleFloating,
            "close_window": .closeWindow,
            "spawn_terminal": .spawnTerminal,
        ]

        for (actionName, keyString) in keybindingMap {
            guard let action = actionMap[actionName] else { continue }
            guard let (modifiers, keyCode) = parseKeyString(keyString) else {
                print("[Hotkey] Cannot parse '\(keyString)' for \(actionName)")
                fflush(stdout)
                continue
            }
            bindings.append(HotkeyBinding(modifiers: modifiers, keyCode: keyCode, action: action))
        }

        print("[Hotkey] Registered \(bindings.count) bindings from config")
        fflush(stdout)
    }

    /// Register hardcoded defaults (fallback if no config).
    public func registerDefaults() {
        registerFromConfig([
            "focus_left": "hyper-h",
            "focus_right": "hyper-l",
            "move_left": "hyper-j",
            "move_right": "hyper-k",
            "cycle_width": "hyper-r",
            "toggle_full_width": "hyper-f",
            "toggle_floating": "hyper-space",
            "close_window": "hyper-w",
            "spawn_terminal": "hyper-t",
        ])
    }

    /// Parse a key string like "hyper-h", "ctrl-shift-l", "cmd-space" into modifiers + keyCode.
    private func parseKeyString(_ str: String) -> (CGEventFlags, CGKeyCode)? {
        let parts = str.lowercased().split(separator: "-").map(String.init)
        guard parts.count >= 2 else { return nil }

        var modifiers: CGEventFlags = []
        let keyName = parts.last!

        for part in parts.dropLast() {
            switch part {
            case "hyper":
                modifiers.insert(.maskControl)
                modifiers.insert(.maskShift)
                modifiers.insert(.maskCommand)
                modifiers.insert(.maskAlternate)
            case "ctrl", "control": modifiers.insert(.maskControl)
            case "shift": modifiers.insert(.maskShift)
            case "cmd", "command": modifiers.insert(.maskCommand)
            case "alt", "opt", "option": modifiers.insert(.maskAlternate)
            case "fn": modifiers.insert(.maskSecondaryFn)
            default: break
            }
        }

        guard let keyCode = keyNameToCode(keyName) else { return nil }
        return (modifiers, keyCode)
    }

    /// Map key names to macOS virtual key codes.
    private func keyNameToCode(_ name: String) -> CGKeyCode? {
        let map: [String: CGKeyCode] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
            "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
            "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12,
            "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19,
            "7": 0x1A, "8": 0x1C, "0": 0x1D, "o": 0x1F, "u": 0x20, "i": 0x22,
            "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E,
            "space": 0x31, "return": 0x24, "tab": 0x30, "escape": 0x35,
            "delete": 0x33, "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
            "=": 0x18, "-": 0x1B, "[": 0x21, "]": 0x1E, ";": 0x29, "'": 0x27,
            ",": 0x2B, ".": 0x2F, "/": 0x2C, "`": 0x32, "\\": 0x2A,
        ]
        return map[name]
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
