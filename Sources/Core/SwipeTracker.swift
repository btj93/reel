import Foundation

/// Tracks gesture velocity using a time-windowed history of samples.
/// Uses a 150ms window (matching niri/GNOME) to filter stale samples
/// so a "flick then pause then release" doesn't carry old momentum.
public struct SwipeTracker: Sendable {
    /// Ring buffer of recent gesture events.
    private var history: [GestureEvent] = []

    /// Cumulative position.
    public private(set) var position: Double = 0

    /// Time window for velocity calculation (150ms).
    public static let historyWindow: Double = 0.150

    /// Deceleration rates for momentum scrolling (per-millisecond velocity retain).
    /// 0.9988 ≈ velocity halves every ~580ms — close to iOS normal deceleration.
    public static let decelerationTouchpad: Double = 0.9988
    public static let decelerationMouse: Double = 0.992

    public struct GestureEvent: Sendable {
        public let timestamp: Double
        public let delta: Double
    }

    public init() {}

    /// Add a gesture sample.
    public mutating func push(delta: Double, timestamp: Double) {
        position += delta
        history.append(GestureEvent(timestamp: timestamp, delta: delta))
        trimHistory(before: timestamp - Self.historyWindow)
    }

    /// Compute average velocity over the history window (pixels/second).
    public func velocity() -> Double {
        guard history.count >= 2,
              let first = history.first,
              let last = history.last else {
            return 0
        }
        let dt = last.timestamp - first.timestamp
        guard dt > 0.001 else { return 0 }
        let totalDelta = history.reduce(0.0) { $0 + $1.delta }
        return totalDelta / dt
    }

    /// Project where momentum would carry the offset, given deceleration.
    public func projectedEndPosition(isTouchpad: Bool) -> Double {
        let vel = velocity()
        let decel = isTouchpad ? Self.decelerationTouchpad : Self.decelerationMouse
        // From exponential decay: pos_final = position - vel / (1000 * ln(decel))
        let logDecel = log(decel)
        guard abs(logDecel) > 1e-10 else { return position }
        return position - vel / (1000.0 * logDecel)
    }

    /// Reset the tracker.
    public mutating func reset() {
        history.removeAll()
        position = 0
    }

    private mutating func trimHistory(before cutoff: Double) {
        history.removeAll { $0.timestamp < cutoff }
    }
}
