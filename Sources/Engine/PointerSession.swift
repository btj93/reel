import Core
import Foundation

public struct PointerToken: Hashable, Sendable {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
}

/// A modifier press on a title bar: the tile it hit and where the cursor went down.
public struct TitlePress: Equatable, Sendable {
    public let tile: TileID
    public let origin: AXPoint
}

/// A swipe once its direction is known: snap targets in the start basis, and the edge the last delta pushed past.
public struct Swipe: Sendable {
    public let snapTargets: [Double]
    public var edge: Double = 0
}

/// The one pointer state machine. A session exists only between a begin and its end; idle is `World.pointer == nil`.
public struct PointerSession: Sendable {
    public enum Phase: Sendable {
        /// Nil until the first moving sample decides the direction.
        case gestureTracking(Swipe?)
        /// The released swipe's spring and the trackpad's own momentum tail. `tail` is the last tail sample's time.
        case momentum(settledAt: Double?, tail: Double?)
        case titleArmed(TitlePress)
        /// Past the drag threshold; the overlay was asked for and is not ready yet.
        case titleDragging(TitlePress, display: UInt32, released: Bool)
        case menuOpen(TitlePress)
        /// The overlay is showing; only a released drag takes a drop.
        case reorderDragging(TitlePress, display: UInt32, released: Bool)
    }

    public let token: PointerToken
    /// The group the session began on, under the epoch and topology it began in.
    public let scope: EventScope
    /// The view offset when tracking began.
    public internal(set) var startOffset: Double
    public internal(set) var phase: Phase
    /// The session's one pending deadline: a long press, or a released drag waiting for its drop.
    public internal(set) var timer: (token: TimerToken, deadline: Double)?

    public var press: TitlePress? {
        switch phase {
        case .gestureTracking, .momentum: nil
        case .titleArmed(let press), .menuOpen(let press), .titleDragging(let press, _, _), .reorderDragging(let press, _, _): press
        }
    }

    public var tile: TileID? { press?.tile }

    public var isSwiping: Bool {
        switch phase {
        case .gestureTracking, .momentum: true
        default: false
        }
    }

    public var swipe: Swipe? {
        if case .gestureTracking(let swipe) = phase { swipe } else { nil }
    }

    /// What the runtime shows for this session.
    public var overlay: Overlay {
        switch phase {
        case .menuOpen(let press): .menu(MenuRequest(session: token, scope: scope, press: press))
        case .titleDragging(let press, let display, let released), .reorderDragging(let press, let display, let released):
            .reorder(ReorderRequest(session: token, scope: scope, tile: press.tile, display: display, released: released))
        default: .hidden
        }
    }
}

public enum ScrollPhase: Equatable, Sendable {
    case began, changed, ended, cancelled
    /// The trackpad's own momentum after a lift, and its last sample.
    case momentum, momentumEnded
    /// A mouse wheel notch, or a shift-converted one.
    case discrete
}

/// One scroll sample in strip points: positive `dx` moves the view right.
public struct ScrollInput: Equatable, Sendable {
    public let phase: ScrollPhase
    public let dx: Double
    public let dy: Double
    public let modifier: Bool
    public let at: AXPoint

    public init(phase: ScrollPhase, dx: Double = 0, dy: Double = 0, modifier: Bool, at: AXPoint) {
        self.phase = phase
        self.dx = dx
        self.dy = dy
        self.modifier = modifier
        self.at = at
    }

    var isHorizontal: Bool { abs(dx) >= abs(dy) * 2 && dx != 0 }
}

extension Optional where Wrapped == PointerSession {
    func isSwiping(group: UInt32) -> Bool { self?.isSwiping == true && self?.scope.group == group }
}

extension World {
    /// The one session's own rules; a second session cannot exist, since `pointer` holds at most one.
    var pointerErrors: [String] {
        var errors: [String] = []
        let swiping = pointer?.swipe != nil ? pointer?.scope.group : nil
        for (id, group) in groups {
            let gestureView = if case .gesture = group.strip.viewOffset { true } else { false }
            if gestureView != (swiping == id) { errors.append("group \(id): gesture view and swipe disagree") }
        }
        guard let session = pointer else { return errors }
        let id = session.scope.group
        if scope(for: id) != session.scope { errors.append("stale pointer") }
        if let tile = session.tile, groups[id]?.strip.columnIndex(of: tile) == nil { errors.append("pointer tile off its strip") }
        let waits = switch session.phase {
        case .titleArmed: true
        case .titleDragging(_, _, let released), .reorderDragging(_, _, let released): released
        default: false
        }
        if (session.timer != nil) != waits { errors.append("pointer timer does not match its phase") }
        if let timer = session.timer, timers[timer.token] != nil { errors.append("pointer timer shared with the scheduler table") }
        if case .reorder(let overlay) = session.overlay, !topology.displays.contains(where: { $0.id == overlay.display }) {
            errors.append("reorder overlay on a missing display")
        }
        return errors
    }
}
