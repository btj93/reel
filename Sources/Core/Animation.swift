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

    /// Evaluate and check convergence in a single solve() call.
    public func evaluateWithStatus(at time: Double) -> (value: Double, isDone: Bool) {
        let t = max(0, time - startTime)
        let x0 = from - to
        let v0 = initialVelocity
        let (displacement, velocity) = params.solve(x0: x0, v0: v0, t: t)
        let done = abs(displacement) < params.epsilon && abs(velocity) < params.epsilon
        return (to + displacement, done)
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

    /// Precomputed constants — internal implementation details.
    let beta: Double               // damping / (2 * mass)
    let omega0: Double             // sqrt(stiffness / mass)
    let regime: DampingRegime

    enum DampingRegime: Sendable {
        case critical
        case underdamped(omegaD: Double)
        case overdamped(omegaBar: Double)
    }

    /// Create spring params from a damping ratio.
    /// - ratio = 1.0: critical damping (no overshoot)
    /// - ratio < 1.0: underdamped (bouncy)
    /// - ratio > 1.0: overdamped (slow return)
    public init(dampingRatio: Double = 1.0, stiffness: Double = 800, mass: Double = 1.0, epsilon: Double = 0.0001) {
        precondition(mass > 0 && stiffness > 0, "SpringParams requires mass > 0 and stiffness > 0")
        self.stiffness = stiffness
        self.mass = mass
        self.epsilon = epsilon
        let criticalDamping = 2.0 * sqrt(stiffness * mass)
        self.damping = dampingRatio * criticalDamping

        let beta = self.damping / (2.0 * mass)
        let omega0 = sqrt(stiffness / mass)
        self.beta = beta
        self.omega0 = omega0

        if abs(beta * beta - omega0 * omega0) < 1e-10 {
            self.regime = .critical
        } else if beta < omega0 {
            self.regime = .underdamped(omegaD: sqrt(omega0 * omega0 - beta * beta))
        } else {
            self.regime = .overdamped(omegaBar: sqrt(beta * beta - omega0 * omega0))
        }
    }

    /// Horizontal scroll animation (snap-to-column).
    /// Epsilon raised from niri's 0.0001 to 0.5 because each AX call costs 0.5-5ms.
    /// Sub-pixel precision wastes hundreds of frames nobody can see.
    public static let horizontalScroll = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)

    /// Free-scroll momentum — lower stiffness for a gradual, iOS-like coast.
    public static let freeScrollMomentum = SpringParams(dampingRatio: 1.0, stiffness: 200, epsilon: 0.5)

    /// Window movement animation.
    public static let windowMovement = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)

    /// Solve the damped harmonic oscillator: m*x'' + b*x' + k*x = 0
    /// Returns (displacement, velocity) at time t.
    public func solve(x0: Double, v0: Double, t: Double) -> (Double, Double) {
        let displacement: Double
        let velocity: Double

        switch regime {
        case .critical:
            let expTerm = exp(-beta * t)
            displacement = expTerm * (x0 + (beta * x0 + v0) * t)
            velocity = expTerm * ((v0 + beta * x0) - beta * (x0 + (beta * x0 + v0) * t))

        case .underdamped(let omegaD):
            let expTerm = exp(-beta * t)
            let cosT = cos(omegaD * t)
            let sinT = sin(omegaD * t)
            displacement = expTerm * (x0 * cosT + ((beta * x0 + v0) / omegaD) * sinT)
            velocity = expTerm * (
                -beta * (x0 * cosT + ((beta * x0 + v0) / omegaD) * sinT)
                + (-x0 * omegaD * sinT + (beta * x0 + v0) * cosT)
            )

        case .overdamped(let omegaBar):
            // Two-exponential form. The previous exp(-beta*t) * cosh(omegaBar*t)
            // underflows one factor to 0 while the other overflows to +inf, giving
            // NaN — which poisons viewOffset so the animation never settles. Both
            // exponents here are <= 0 when overdamped (beta > omegaBar), so each
            // term decays independently and neither can overflow.
            let r1 = -(beta - omegaBar)
            let r2 = -(beta + omegaBar)
            let e1 = exp(r1 * t)
            let e2 = exp(r2 * t)
            let c1 = (v0 - r2 * x0) / (r1 - r2)
            let c2 = x0 - c1
            displacement = c1 * e1 + c2 * e2
            velocity = c1 * r1 * e1 + c2 * r2 * e2
        }

        // Single non-finite backstop for every regime. Reporting "settled at the
        // target" here is what lets `evaluate`, `evaluateWithStatus` and `isDone`
        // agree: ColumnData.currentWidth then falls back to cachedWidth, the
        // settle helpers nil the spring, and FocusIndicator releases its springs.
        // Patching only isDone/evaluateWithStatus would miss ViewOffset.current,
        // which goes through `evaluate`.
        guard displacement.isFinite, velocity.isFinite else { return (0, 0) }
        return (displacement, velocity)
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
