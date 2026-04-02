import CoreGraphics
import Core
import Foundation

/// Captures trackpad scroll gestures via CGEventTap for strip scrolling.
/// Separate from HotkeyManager (which handles keyboard events).
///
/// Only activates when the configured modifier key is held (default: fn).
/// Suppresses macOS momentum events — we handle our own momentum.
public final class GestureCapture: @unchecked Sendable {

    /// Callbacks for gesture lifecycle.
    public var onGestureBegin: ((Double) -> Void)?      // timestamp
    public var onGestureUpdate: ((Double, Double) -> Void)?  // deltaX, timestamp
    public var onGestureEnd: ((Double) -> Void)?         // timestamp
    public var onGestureCancel: (() -> Void)?

    /// Modifier that must be held for gesture capture (default: fn key).
    public var requiredModifier: CGEventFlags = .maskSecondaryFn

    var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Whether a gesture is currently active.
    private var isGesturing: Bool = false

    public init() {}

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Start capturing scroll events.
    public func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.scrollWheel.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: scrollCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            #if DEBUG
            print("[GestureCapture] Failed to create CGEventTap")
            fflush(stdout)
            #endif
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        #if DEBUG
        print("[GestureCapture] Started (modifier: fn)")
        fflush(stdout)
        #endif
        return true
    }

    /// Stop capturing.
    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isGesturing = false
    }

    // MARK: - Event Handling

    fileprivate func handleScrollEvent(_ event: CGEvent) -> Bool {
        // Check if our modifier is held
        let flags = event.flags
        guard flags.contains(requiredModifier) else {
            // If we were gesturing and modifier was released, end the gesture
            if isGesturing {
                endGesture(event)
            }
            return false  // pass event through
        }

        // Get scroll phase info
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)

        // Suppress macOS momentum events — we handle our own
        if momentumPhase != 0 {
            return true  // consume
        }

        // Only handle continuous (trackpad) events
        guard isContinuous else {
            // Discrete mouse wheel with modifier: treat as focus left/right
            return false
        }

        let timestamp = TimeUtil.now()

        // Horizontal delta (positive = scroll right in strip, negative = scroll left)
        let deltaX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)

        switch phase {
        case 1:  // kCGScrollPhaseBegan
            isGesturing = true
            onGestureBegin?(timestamp)

        case 2:  // kCGScrollPhaseChanged
            if isGesturing {
                // Negate delta: trackpad scroll right = content moves left = negative offset change
                onGestureUpdate?(-deltaX, timestamp)
            }

        case 4:  // kCGScrollPhaseEnded
            endGesture(event)

        case 8:  // kCGScrollPhaseCancelled
            isGesturing = false
            onGestureCancel?()

        default:
            break
        }

        return true  // consume the event
    }

    private func endGesture(_ event: CGEvent) {
        guard isGesturing else { return }
        isGesturing = false
        let timestamp = TimeUtil.now()
        onGestureEnd?(timestamp)
    }

}

// MARK: - CGEventTap C Callback

private func scrollCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Handle tap disabled
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            let capture = Unmanaged<GestureCapture>.fromOpaque(userInfo).takeUnretainedValue()
            if let tap = capture.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passRetained(event)
    }

    guard type == .scrollWheel, let userInfo = userInfo else {
        return Unmanaged.passRetained(event)
    }

    let capture = Unmanaged<GestureCapture>.fromOpaque(userInfo).takeUnretainedValue()
    let consumed = capture.handleScrollEvent(event)

    if consumed {
        return nil  // don't pass to apps
    }
    return Unmanaged.passRetained(event)
}
