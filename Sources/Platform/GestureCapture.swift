import CoreGraphics
import Foundation

/// One scroll event as the tap saw it: the CGEvent scroll and momentum phases, the point deltas, the modifier flags and
/// the cursor in CG coordinates.
public struct ScrollEvent: Sendable {
    public let phase: Int64
    public let momentumPhase: Int64
    public let continuous: Bool
    public let dx: Double
    public let dy: Double
    public let flags: CGEventFlags
    public let location: CGPoint

    public init(phase: Int64, momentumPhase: Int64, continuous: Bool, dx: Double, dy: Double, flags: CGEventFlags, location: CGPoint) {
        self.phase = phase
        self.momentumPhase = momentumPhase
        self.continuous = continuous
        self.dx = dx
        self.dy = dy
        self.flags = flags
        self.location = location
    }

    init(_ event: CGEvent) {
        self.init(phase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
                  momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
                  continuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
                  dx: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
                  dy: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
                  flags: event.flags, location: event.location)
    }
}

/// Forwards raw scroll events to the runtime and applies its consume/pass verdict.
public final class GestureCapture: @unchecked Sendable {

    public var onScroll: ((ScrollEvent) -> Bool)?

    var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

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

        print("[GestureCapture] Started")
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
    }

    // MARK: - Event Handling

    fileprivate func handleScrollEvent(_ event: CGEvent) -> Bool {
        onScroll?(ScrollEvent(event)) ?? false
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
