import AppKit
import CoreGraphics

/// One left-button event or an Escape press, in CG coordinates. A press carries the modifier flags held with it.
public enum MouseEvent: Sendable {
    case down(CGPoint, flags: CGEventFlags)
    case dragged(CGPoint)
    case up(CGPoint)
    case escape
}

/// What the tap does with a `MouseEvent`: deliver it, swallow it, or deliver a press at the point before this release.
public enum MouseVerdict: Equatable, Sendable {
    case pass
    case swallow
    case replay(CGPoint)
}

@MainActor
public final class TitleBarInteraction {
    static let reelSentinel: Int64 = 0x5245454C

    public var onMouse: ((MouseEvent) -> MouseVerdict)?

    // Event taps
    var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    var escapeEventTap: CFMachPort?
    private var escapeRunLoopSource: CFRunLoopSource?

    public init() {}

    // MARK: - Start / Stop

    @discardableResult
    public func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: titleBarCallback,
            userInfo: userInfo
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        return true
    }

    public func stop() {
        teardownEscapeTap()
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

    // MARK: - Escape Key Tap

    private func setupEscapeTap() {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: escapeCallback,
            userInfo: userInfo
        ) else { return }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.escapeEventTap = tap
        self.escapeRunLoopSource = source
    }

    private func teardownEscapeTap() {
        if let tap = escapeEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = escapeRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        escapeEventTap = nil
        escapeRunLoopSource = nil
    }

    // MARK: - Event Handling

    func handleMouseEvent(_ event: CGEvent, type: CGEventType) -> CGEvent? {
        if event.getIntegerValueField(.eventSourceUserData) == Self.reelSentinel {
            return event
        }

        let location = event.location

        if let onMouse {
            let verdict: MouseVerdict = switch type {
            case .leftMouseDown: onMouse(.down(location, flags: event.flags))
            case .leftMouseDragged: onMouse(.dragged(location))
            case .leftMouseUp: onMouse(.up(location))
            default: .pass
            }
            switch verdict {
            case .pass: return event
            case .swallow: return nil
            case .replay(let point): return replay(event, pressAt: point)
            }
        }

        return event
    }

    private func replay(_ up: CGEvent, pressAt point: CGPoint) -> CGEvent {
        guard let syntheticDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point,
                                          mouseButton: .left) else { return up }
        syntheticDown.setIntegerValueField(.eventSourceUserData, value: Self.reelSentinel)
        up.post(tap: .cghidEventTap)
        return syntheticDown
    }

    public nonisolated static func titleBarContains(_ point: CGPoint, frame: CGRect, height: Double, cornerInset: Double) -> Bool {
        let inset = min(cornerInset, frame.width / 2)
        return CGRect(x: frame.minX + inset, y: frame.minY, width: max(0, frame.width - inset * 2), height: height).contains(point)
    }

    public func setEscapeTap(_ capture: Bool) {
        if capture && escapeEventTap == nil { setupEscapeTap() }
        else if !capture { teardownEscapeTap() }
    }
}

// MARK: - C Callbacks

// CGEvent taps run synchronously on the main run loop; the callback verifies that executor.
private struct EventCallbackInput: @unchecked Sendable {
    let event: CGEvent
    let userInfo: UnsafeMutableRawPointer?
}

// Unmanaged preserves the C callback's pass-through ownership across assumeIsolated.
private struct EventCallbackOutput: @unchecked Sendable {
    let event: Unmanaged<CGEvent>?
}

private func titleBarCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let input = EventCallbackInput(event: event, userInfo: userInfo)
    return MainActor.assumeIsolated {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let userInfo = input.userInfo {
                let handler = Unmanaged<TitleBarInteraction>.fromOpaque(userInfo).takeUnretainedValue()
                if let tap = handler.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            // The incoming event is +0, so pass it through unretained. Retaining it would
            // leak a reference the framework never balances (#21).
            return EventCallbackOutput(event: .passUnretained(input.event))
        }
        guard let userInfo = input.userInfo else {
            return EventCallbackOutput(event: .passUnretained(input.event))
        }
        let handler = Unmanaged<TitleBarInteraction>.fromOpaque(userInfo).takeUnretainedValue()
        guard let result = handler.handleMouseEvent(input.event, type: type) else {
            return EventCallbackOutput(event: nil)
        }
        // The same input event is +0; a synthetic mouseDown is +1 and must be retained.
        // Compare identity to return each with the ownership the event tap expects.
        let output = result === input.event ? Unmanaged.passUnretained(input.event) : .passRetained(result)
        return EventCallbackOutput(event: output)
    }.event
}

private func escapeCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let input = EventCallbackInput(event: event, userInfo: userInfo)
    return MainActor.assumeIsolated {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let userInfo = input.userInfo {
                let handler = Unmanaged<TitleBarInteraction>.fromOpaque(userInfo).takeUnretainedValue()
                if let tap = handler.escapeEventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            return EventCallbackOutput(event: .passUnretained(input.event))
        }
        guard let userInfo = input.userInfo else {
            return EventCallbackOutput(event: .passUnretained(input.event))
        }
        let handler = Unmanaged<TitleBarInteraction>.fromOpaque(userInfo).takeUnretainedValue()
        if input.event.getIntegerValueField(.keyboardEventKeycode) == 0x35 {
            if let onMouse = handler.onMouse {
                return EventCallbackOutput(event: onMouse(.escape) == .pass ? .passUnretained(input.event) : nil)
            }
            return EventCallbackOutput(event: .passUnretained(input.event))
        }
        return EventCallbackOutput(event: .passUnretained(input.event))
    }.event
}
