import Foundation

/// Tracks gesture velocity using Apple's macOS weighted-sample approach.
/// Uses the 3 most recent inter-sample velocities with weights 0.15/0.65/0.20,
/// matching macOS `NSScrollView` / Flutter's `MacOSScrollViewFlingVelocityTracker`.
/// The second-to-last sample gets the most weight because the final touch frame
/// often has a decelerating finger during lift-off.
public struct SwipeTracker: Sendable {
    /// Ring buffer of recent gesture events (position + time).
    private var samples: [(position: Double, timestamp: Double)] = []

    /// Maximum samples to retain.
    private static let maxSamples = 20

    /// macOS velocity weights: [third-most-recent, second-most-recent, most-recent].
    private static let weights: [Double] = [0.15, 0.65, 0.20]

    /// Cumulative position.
    public private(set) var position: Double = 0

    /// Deceleration rates for momentum scrolling (per-millisecond velocity retain).
    /// 0.9975 ≈ velocity halves every ~277ms — tighter than iOS, less coast.
    public static let decelerationTouchpad: Double = 0.9975
    public static let decelerationMouse: Double = 0.992

    public init() {}

    /// Add a gesture sample.
    public mutating func push(delta: Double, timestamp: Double) {
        position += delta
        samples.append((position: position, timestamp: timestamp))
        if samples.count > Self.maxSamples {
            samples.removeFirst(samples.count - Self.maxSamples)
        }
    }

    /// How long since the last sample before we consider the gesture "paused".
    /// If the user stops moving but keeps fingers down, macOS stops sending
    /// scroll events. On lift-off we shouldn't carry stale velocity.
    private static let stalenessThreshold: Double = 0.050  // 50ms

    /// Compute velocity using weighted average of the 3 most recent inter-sample
    /// velocities (pixels/second). Matches macOS scroll physics.
    /// Pass the current time so stale samples (finger paused before lift-off) return 0.
    public func velocity(at currentTime: Double? = nil) -> Double {
        // Need at least 2 samples to compute 1 inter-sample velocity
        guard samples.count >= 2 else { return 0 }

        // If the most recent sample is stale, the user paused before lifting — no momentum.
        if let now = currentTime, let last = samples.last {
            if now - last.timestamp > Self.stalenessThreshold { return 0 }
        }

        // Compute inter-sample velocities (most recent last)
        var velocities: [Double] = []
        let count = samples.count
        let pairsToUse = min(3, count - 1)
        for i in (count - pairsToUse)..<count {
            let dt = samples[i].timestamp - samples[i - 1].timestamp
            guard dt > 0.0001 else { continue }
            let dPos = samples[i].position - samples[i - 1].position
            velocities.append(dPos / dt)
        }

        guard !velocities.isEmpty else { return 0 }

        // Apply weights — align so the last velocity gets weight[2], second-to-last gets weight[1], etc.
        let weights = Self.weights
        var weightedSum = 0.0
        var totalWeight = 0.0
        for i in 0..<velocities.count {
            let wIdx = weights.count - velocities.count + i
            guard wIdx >= 0 else { continue }
            weightedSum += velocities[i] * weights[wIdx]
            totalWeight += weights[wIdx]
        }

        guard totalWeight > 0 else { return 0 }
        return (weightedSum / totalWeight) * 0.5
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
        samples.removeAll()
        position = 0
    }
}
