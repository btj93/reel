import Foundation

/// The scroll position state machine for a horizontal strip.
///
/// Three states:
/// - `.static`: No animation, fixed scroll offset
/// - `.animation`: Animating toward a target (focus change, momentum settle)
/// - `.gesture`: User actively scrolling via trackpad
public enum ViewOffset: Sendable {
    case `static`(Double)
    case animation(SpringAnimation)
    case gesture(GestureState)

    /// The current interpolated scroll offset.
    public func current(at time: Double) -> Double {
        switch self {
        case .static(let offset):
            return offset
        case .animation(let anim):
            return anim.evaluate(at: time).value
        case .gesture(let state):
            return state.currentOffset
        }
    }

    /// The target scroll offset (where we're heading).
    public var target: Double {
        switch self {
        case .static(let offset):
            return offset
        case .animation(let anim):
            return anim.to
        case .gesture(let state):
            return state.currentOffset
        }
    }

    /// Whether the offset is settled (static or animation done).
    public func isSettled(at time: Double) -> Bool {
        switch self {
        case .static:
            return true
        case .animation(let anim):
            return anim.isDone(at: time)
        case .gesture:
            return false
        }
    }

    /// Shift the offset by a delta (used when columns are inserted/removed to the left).
    public mutating func shiftBy(_ delta: Double) {
        switch self {
        case .static(let offset):
            self = .static(offset + delta)
        case .animation(let anim):
            self = .animation(SpringAnimation(
                from: anim.from + delta,
                to: anim.to + delta,
                initialVelocity: anim.initialVelocity,
                startTime: anim.startTime,
                params: anim.params
            ))
        case .gesture(var state):
            state.currentOffset += delta
            self = .gesture(state)
        }
    }
}

/// State during an active trackpad gesture.
public struct GestureState: Sendable {
    /// Accumulated scroll offset from gesture deltas.
    public var currentOffset: Double

    /// Velocity tracker using time-windowed samples.
    public var tracker: SwipeTracker

    /// Whether this is a continuous trackpad (vs discrete mouse wheel).
    public var isTouchpad: Bool

    public init(currentOffset: Double, isTouchpad: Bool) {
        self.currentOffset = currentOffset
        self.tracker = SwipeTracker()
        self.isTouchpad = isTouchpad
    }
}
