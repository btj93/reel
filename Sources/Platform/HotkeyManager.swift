import CoreGraphics
import Foundation
import Core

/// Action triggered by a hotkey press.
public enum HotkeyAction: Sendable {
    case focusLeft
    case focusRight
    case focusUp
    case focusDown
    case moveColumnLeft
    case moveColumnRight
    case cycleWidthPreset
    case toggleFullWidth
    case toggleFloating
    case closeWindow
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
    public var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var bindings: [HotkeyBinding] = []
    private var healthTimer: Timer?

    /// When true, the health monitor won't re-enable a disabled tap.
    public var suspended: Bool = false

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
            "focus_up": .focusUp,
            "focus_down": .focusDown,
            "move_left": .moveColumnLeft,
            "move_right": .moveColumnRight,
            "cycle_width": .cycleWidthPreset,
            "toggle_full_width": .toggleFullWidth,
            "toggle_floating": .toggleFloating,
            "close_window": .closeWindow,
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
            "focus_left": "alt-h",
            "focus_right": "alt-l",
            "focus_up": "alt-k",
            "focus_down": "alt-j",
            "move_left": "alt-shift-h",
            "move_right": "alt-shift-l",
            "cycle_width": "alt-r",
            "toggle_full_width": "alt-f",
            "toggle_floating": "alt-space",
            "close_window": "alt-w",
        ])
    }

    /// Parse a key string like "hyper-h", "ctrl-shift-l", "cmd-space" into modifiers + keyCode.
    ///
    /// `package` (not `private`) so RunTests can table-test the parser directly.
    ///
    /// An unrecognized modifier token invalidates the whole binding: returning a
    /// binding with dropped modifiers would collapse to a bare-key global grab
    /// (every press of that key, in every app, consumed by the tap).
    package func parseKeyString(_ str: String) -> (CGEventFlags, CGKeyCode)? {
        // Keep empty subsequences so a binding for the '-' key (written as a
        // trailing separator, e.g. "alt--") survives instead of being dropped.
        var parts = str.lowercased()
            .split(separator: "-", omittingEmptySubsequences: false)
            .map(String.init)
        // A '-' key produces trailing empty token(s); fold them back into an
        // explicit "-" key name so punctuation keys are bindable.
        if parts.count >= 2, parts.last == "" {
            while parts.count > 1, parts.last == "" { parts.removeLast() }
            parts.append("-")
        }
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
            // "super"/"mod" are niri's names for the main modifier → Command on macOS.
            case "cmd", "command", "super", "mod": modifiers.insert(.maskCommand)
            case "alt", "opt", "option": modifiers.insert(.maskAlternate)
            case "fn": modifiers.insert(.maskSecondaryFn)
            default:
                // Unknown token (typo like "atl", or an unsupported modifier
                // name). Fail loudly and skip the binding rather than silently
                // dropping the token and registering a bare-key grab.
                print("[Hotkey] Unknown modifier '\(part)' in '\(str)' — skipping binding")
                fflush(stdout)
                return nil
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
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[Hotkey] Failed to create CGEventTap — check Accessibility permission")
            fflush(stdout)
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Start health monitoring — poll every 2 seconds
        startHealthMonitor()

        print("[Hotkey] Started")
        fflush(stdout)
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
            guard let self = self, !self.suspended, let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                print("[Hotkey] Event tap was disabled — re-enabling")
                fflush(stdout)
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
    }

    // MARK: - Event Matching

    /// Modifier flags that participate in hotkey matching. Flags outside this
    /// set (caps lock, numeric-keypad, non-coalesced, …) are ignored so they
    /// never accidentally break or trigger a binding.
    static let relevantModifiers: CGEventFlags =
        [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]

    fileprivate func matchEvent(_ event: CGEvent) -> HotkeyAction? {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        return matchBinding(keyCode: keyCode, flags: event.flags)
    }

    /// Resolve the action bound to a keyCode + modifier set.
    ///
    /// Matching precedence (deterministic — never depends on the order bindings
    /// were registered from the config dictionary):
    /// 1. Only the modifiers in `relevantModifiers` are considered; the event's
    ///    other flags are masked off.
    /// 2. A binding fires only when its modifier set **exactly equals** the
    ///    event's relevant modifiers. Exact equality is the most-specific match
    ///    possible, so `alt-shift-h` can never fall through to an `alt-h`
    ///    binding, and a superset chord like `cmd-alt-h` never steals a plain
    ///    `alt-h` binding (it simply passes through to the focused app).
    /// 3. For any valid config there is at most one binding per key+modifier
    ///    chord, so the match is unique. If a config binds the identical chord
    ///    to two actions, the first such binding encountered wins; the result
    ///    is still independent of which overlapping *chords* exist.
    ///
    /// `package` so RunTests can table-test matching without synthesizing a real
    /// `CGEvent`.
    package func matchBinding(keyCode: CGKeyCode, flags: CGEventFlags) -> HotkeyAction? {
        let eventModifiers = flags.intersection(Self.relevantModifiers)
        for binding in bindings where binding.keyCode == keyCode && binding.modifiers == eventModifiers {
            return binding.action
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
            if !manager.suspended, let tap = manager.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        // Pass the original event through. The tap runtime owns this event and
        // releases it; returning it +1 (passRetained) would leak one CGEvent
        // per passed-through keystroke. passUnretained hands it back at +0.
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown, let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
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

    // Not our hotkey — pass the original event through at +0 (see above).
    return Unmanaged.passUnretained(event)
}
