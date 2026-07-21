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

    /// Called for discrete mouse scroll events (deltaX in points, timestamp).
    public var onDiscreteScroll: ((Double, Double) -> Void)?

    /// Gesture mode: locked at gesture begin based on finger count.
    enum GestureMode {
        case pan
        case focusSwitch
    }

    private var gestureMode: GestureMode?
    private var focusSwipeTracker = SwipeTracker()
    private var focusCumulativeDelta: Double = 0

    /// Called on 3-finger gesture end with velocity.
    public var onFocusSwipe: ((Double) -> Void)?

    /// Minimum swipe distance to trigger focus switch.
    public var swipeThresholdPx: Double = 50

    /// Modifier that must be held for gesture capture (default: fn key).
    public var requiredModifier: CGEventFlags = .maskSecondaryFn

    var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Whether a gesture is currently active.
    private var isGesturing: Bool = false

    /// Set when a captured gesture ends, so we keep swallowing its momentum
    /// tail. macOS emits momentumPhase events only *after* the gesture-ended
    /// phase (by which point `isGesturing` is already false), and it may keep
    /// emitting them after the modifier is released — so momentum ownership
    /// can't be inferred from `isGesturing`/the modifier at momentum time.
    /// Cleared on the momentum-ended phase or when a fresh gesture begins.
    private var suppressMomentum: Bool = false

    /// Set when the swipe direction was decided as not-horizontal.
    /// Stays true until the gesture ends so we don't re-evaluate mid-swipe.
    private var gestureRejected: Bool = false

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
            print("[GestureCapture] Failed to create CGEventTap")
            fflush(stdout)
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        print("[GestureCapture] Started (modifier: fn)")
        fflush(stdout)
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
        suppressMomentum = false
    }

    // MARK: - Event Handling

    fileprivate func handleScrollEvent(_ event: CGEvent) -> Bool {
        let flags = event.flags
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)

        #if DEBUG
        let dbgAxis1 = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let dbgAxis2 = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let dbgIntAxis1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let dbgIntAxis2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let dbgPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let hasFn = flags.contains(.maskSecondaryFn)
        let hasShift = flags.contains(.maskShift)
        // print("[ScrollEvt] cont=\(isContinuous) mom=\(momentumPhase) phase=\(dbgPhase) fn=\(hasFn) shift=\(hasShift) ptY=\(dbgAxis1) ptX=\(dbgAxis2) intY=\(dbgIntAxis1) intX=\(dbgIntAxis2)")
        fflush(stdout)
        #endif

        // Momentum tail of a gesture we captured: keep consuming it until the
        // momentum-ended phase, regardless of `isGesturing` (already cleared)
        // or whether the modifier is still held (the user may have released fn
        // during the flick). Checked before the modifier guard below so the
        // native momentum stream can't leak to the app under the cursor —
        // we run our own momentum via SwipeTracker. (momentumPhase: 1=begin,
        // 2=continue, 3=ended.)
        if suppressMomentum {
            if momentumPhase != 0 {
                if momentumPhase == 3 { suppressMomentum = false }
                return true  // swallow our gesture's momentum
            }
            // A non-momentum event means the tail is over (or a new gesture is
            // starting); stop suppressing and fall through to normal handling.
            suppressMomentum = false
        }

        // All scroll handling requires the configured modifier (fn by default).
        // Shift+scroll wheel: macOS converts vertical→horizontal and marks as
        // continuous with phase=0. Detect this so fn+shift+scroll works.
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let isShiftConverted = flags.contains(.maskShift) && isContinuous && phase == 0 && momentumPhase == 0

        guard flags.contains(requiredModifier) else {
            if isGesturing {
                endGesture(event)
            }
            return false
        }

        // Discrete mouse scroll or shift-converted discrete: pan the strip.
        // Only horizontal — vertical scroll (without shift) passes through to apps.
        if !isContinuous || isShiftConverted {
            if momentumPhase != 0 { return true }
            let deltaX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            let deltaY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            // Shift-converted events always have the delta on axis2; for native
            // horizontal scroll wheels, axis2 dominates. Pass through vertical-only.
            if !isShiftConverted && abs(deltaY) > abs(deltaX) {
                return false
            }
            let delta = abs(deltaX) >= abs(deltaY) ? deltaX : deltaY
            if abs(delta) > 0 {
                let timestamp = TimeUtil.now()
                onDiscreteScroll?(delta * 1.0, timestamp)
            }
            return true
        }



        // Suppress macOS momentum events only if we captured the gesture.
        // Vertical swipes we didn't capture should keep their native momentum.
        if momentumPhase != 0 {
            if !isGesturing { return false }  // pass through
            return true  // consume our gesture's momentum
        }

        let timestamp = TimeUtil.now()

        let rawDeltaX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let rawDeltaY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        // Only use horizontal axis for strip motion
        let delta = rawDeltaX * 2.0

        // Once we've rejected this gesture as non-horizontal, stay rejected
        // until the gesture ends. Prevents mid-swipe direction changes from
        // accidentally triggering strip scrolling.
        if gestureRejected {
            // Let end/cancel through to reset the flag
            if phase == 4 || phase == 8 { gestureRejected = false }
            return false
        }

        switch phase {
        case 1:  // kCGScrollPhaseBegan
            // Pass through — direction not known yet. We'll decide on phase=2.
            return false

        case 2:  // kCGScrollPhaseChanged
            if !isGesturing {
                // First real movement — only capture if clearly horizontal (2:1 ratio)
                if abs(rawDeltaX) < abs(rawDeltaY) * 2.0 {
                    gestureRejected = true
                    return false  // not clearly horizontal, pass through
                }
                // Horizontal swipe — start the gesture
                isGesturing = true
                let fingerCount = event.getIntegerValueField(CGEventField(rawValue: 111)!)
                if fingerCount >= 3 {
                    gestureMode = .focusSwitch
                    focusSwipeTracker.reset()
                    focusCumulativeDelta = 0
                } else {
                    gestureMode = .pan
                    onGestureBegin?(timestamp)
                }
            }
            if isGesturing {
                if gestureMode == .focusSwitch {
                    focusCumulativeDelta += delta
                    focusSwipeTracker.push(delta: delta, timestamp: timestamp)
                } else {
                    onGestureUpdate?(-delta, timestamp)
                }
                return true
            }
            return false

        case 4:  // kCGScrollPhaseEnded
            gestureRejected = false
            if !isGesturing {
                return false  // was a vertical swipe we never captured
            }
            if gestureMode == .focusSwitch {
                if abs(focusCumulativeDelta) > swipeThresholdPx {
                    onFocusSwipe?(focusSwipeTracker.velocity())
                }
                isGesturing = false
                suppressMomentum = true  // swallow the flick's momentum tail
                gestureMode = nil
                focusCumulativeDelta = 0
            } else {
                endGesture(event)
                gestureMode = nil
            }
            return true

        case 8:  // kCGScrollPhaseCancelled
            gestureRejected = false
            if !isGesturing { return false }
            let wasFocusSwitch = gestureMode == .focusSwitch
            isGesturing = false
            gestureMode = nil
            focusCumulativeDelta = 0
            if !wasFocusSwitch {
                onGestureCancel?()
            }
            return true

        default:
            return false
        }
    }

    private func endGesture(_ event: CGEvent) {
        guard isGesturing else { return }
        isGesturing = false
        // The flick's native momentum tail arrives after this point; keep
        // swallowing it (finding: momentum leaking to the app under the cursor).
        suppressMomentum = true
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
        // Pass the original event through at +0. The tap runtime owns and
        // releases it; passRetained here would leak one CGEvent per event.
        return Unmanaged.passUnretained(event)
    }

    guard type == .scrollWheel, let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let capture = Unmanaged<GestureCapture>.fromOpaque(userInfo).takeUnretainedValue()
    let consumed = capture.handleScrollEvent(event)

    if consumed {
        return nil  // don't pass to apps
    }
    // Pass the original event through at +0 (see above) — ~120 scroll ticks/sec
    // during a flick, so a +1 leak here accumulates fast.
    return Unmanaged.passUnretained(event)
}
