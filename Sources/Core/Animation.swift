import Foundation

/// A spring-based animation that smoothly interpolates between two values.
/// Uses the damped harmonic oscillator equation with three solution regimes.
public struct SpringAnimation: Sendable {
    public let from: Double
    public let to: Double
    public let initialVelocity: Double
    public let startTime: Double
    public let params: SpringParams

    /// Create a new spring animation.
    public init(from: Double, to: Double, initialVelocity: Double = 0, startTime: Double, params: SpringParams) {
        self.from = from
        self.to = to
        self.initialVelocity = initialVelocity
        self.startTime = startTime
        self.params = params
    }

    /// Evaluate the animation at a given time.
    public func evaluate(at time: Double) -> (value: Double, velocity: Double) {
        let t = max(0, time - startTime)
        let x0 = from - to  // displacement from target
        let v0 = initialVelocity

        let (displacement, velocity) = params.solve(x0: x0, v0: v0, t: t)
        return (to + displacement, velocity)
    }

    /// Current value (convenience, requires passing current time).
    public var currentValue: Double {
        // This is a placeholder — callers should use evaluate(at:) with actual time
        to
    }

    /// Whether the animation has converged.
    public func isDone(at time: Double) -> Bool {
        let t = max(0, time - startTime)
        let x0 = from - to
        let v0 = initialVelocity
        let (displacement, velocity) = params.solve(x0: x0, v0: v0, t: t)
        return abs(displacement) < params.epsilon && abs(velocity) < params.epsilon
    }

    /// Convenience accessor.
    public var isDone: Bool {
        // Callers should use isDone(at:) — this always returns false as a safe default
        false
    }

    /// Create a retargeted animation preserving current state.
    public func retargeted(to newTarget: Double, at time: Double) -> SpringAnimation {
        let (currentVal, currentVel) = evaluate(at: time)
        return SpringAnimation(
            from: currentVal,
            to: newTarget,
            initialVelocity: currentVel,
            startTime: time,
            params: params
        )
    }
}

/// Spring physics parameters.
public struct SpringParams: Sendable {
    public let stiffness: Double   // k
    public let damping: Double     // b (derived from dampingRatio)
    public let mass: Double        // m
    public let epsilon: Double     // convergence threshold

    /// Create spring params from a damping ratio.
    /// - ratio = 1.0: critical damping (no overshoot)
    /// - ratio < 1.0: underdamped (bouncy)
    /// - ratio > 1.0: overdamped (slow return)
    public init(dampingRatio: Double = 1.0, stiffness: Double = 800, mass: Double = 1.0, epsilon: Double = 0.0001) {
        self.stiffness = stiffness
        self.mass = mass
        self.epsilon = epsilon
        let criticalDamping = 2.0 * sqrt(stiffness * mass)
        self.damping = dampingRatio * criticalDamping
    }

    /// Niri defaults for horizontal view movement.
    public static let horizontalScroll = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.0001)

    /// Niri defaults for window movement.
    public static let windowMovement = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.0001)

    /// Niri defaults for workspace switching.
    public static let workspaceSwitch = SpringParams(dampingRatio: 1.0, stiffness: 1000, epsilon: 0.0001)

    /// Solve the damped harmonic oscillator: m*x'' + b*x' + k*x = 0
    /// Returns (displacement, velocity) at time t.
    public func solve(x0: Double, v0: Double, t: Double) -> (Double, Double) {
        let beta = damping / (2.0 * mass)
        let omega0 = sqrt(stiffness / mass)

        if abs(beta * beta - omega0 * omega0) < 1e-10 {
            // Critically damped
            let expTerm = exp(-beta * t)
            let displacement = expTerm * (x0 + (beta * x0 + v0) * t)
            let velocity = expTerm * (v0 - (beta * x0 + v0) * beta * t + (beta * x0 + v0))
                - beta * displacement
            // Simplified: d/dt[e^(-bt)(x0 + (bx0+v0)t)]
            let vel = expTerm * ((v0 + beta * x0) - beta * (x0 + (beta * x0 + v0) * t))
            return (displacement, vel)
        } else if beta < omega0 {
            // Underdamped
            let omega1 = sqrt(omega0 * omega0 - beta * beta)
            let expTerm = exp(-beta * t)
            let cosT = cos(omega1 * t)
            let sinT = sin(omega1 * t)
            let displacement = expTerm * (x0 * cosT + ((beta * x0 + v0) / omega1) * sinT)
            let velocity = expTerm * (
                -beta * (x0 * cosT + ((beta * x0 + v0) / omega1) * sinT)
                + (-x0 * omega1 * sinT + (beta * x0 + v0) * cosT)
            )
            return (displacement, velocity)
        } else {
            // Overdamped
            let omega2 = sqrt(beta * beta - omega0 * omega0)
            let expTerm = exp(-beta * t)
            let coshT = cosh(omega2 * t)
            let sinhT = sinh(omega2 * t)
            let displacement = expTerm * (x0 * coshT + ((beta * x0 + v0) / omega2) * sinhT)
            let velocity = expTerm * (
                -beta * (x0 * coshT + ((beta * x0 + v0) / omega2) * sinhT)
                + (x0 * omega2 * sinhT + (beta * x0 + v0) * coshT)
            )
            return (displacement, velocity)
        }
    }
}

/// Easing-based animation for window open/close.
public struct EasingAnimation: Sendable {
    public let from: Double
    public let to: Double
    public let startTime: Double
    public let duration: Double
    public let curve: EasingCurve

    public init(from: Double, to: Double, startTime: Double, duration: Double, curve: EasingCurve) {
        self.from = from
        self.to = to
        self.startTime = startTime
        self.duration = duration
        self.curve = curve
    }

    public func evaluate(at time: Double) -> Double {
        let t = min(1.0, max(0, (time - startTime) / duration))
        let eased = curve.apply(t)
        return from + (to - from) * eased
    }

    public func isDone(at time: Double) -> Bool {
        (time - startTime) >= duration
    }
}

/// Easing curves for non-spring animations.
public enum EasingCurve: Sendable {
    case linear
    case easeOutExpo
    case easeOutQuad
    case easeOutCubic

    public func apply(_ t: Double) -> Double {
        switch self {
        case .linear:
            return t
        case .easeOutExpo:
            return t >= 1.0 ? 1.0 : 1.0 - pow(2.0, -10.0 * t)
        case .easeOutQuad:
            return 1.0 - (1.0 - t) * (1.0 - t)
        case .easeOutCubic:
            let inv = 1.0 - t
            return 1.0 - inv * inv * inv
        }
    }
}
