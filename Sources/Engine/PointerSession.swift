import Core

public struct PointerToken: Hashable, Sendable {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
}

public struct GestureSession: Sendable {
    public let token: PointerToken
    public let scope: EventScope
    public let tile: TileID
    public let startOffset: Double
    public let snapTargets: [Double]
}

public struct TargetSession: Sendable {
    public let token: PointerToken
    public let scope: EventScope
    public let tile: TileID
}

public enum PointerState: Sendable {
    case idle
    case gesture(GestureSession)
    case momentum(EventScope, settledAt: Double?)
    case menu(TargetSession)
    case reorder(TargetSession)

    public var token: PointerToken? {
        switch self {
        case .idle, .momentum: nil
        case .gesture(let session): session.token
        case .menu(let session), .reorder(let session): session.token
        }
    }

    public var tile: TileID? {
        switch self {
        case .idle, .momentum: nil
        case .gesture(let session): session.tile
        case .menu(let session), .reorder(let session): session.tile
        }
    }

    public var scope: EventScope? {
        switch self {
        case .idle: nil
        case .momentum(let scope, _): scope
        case .gesture(let session): session.scope
        case .menu(let session), .reorder(let session): session.scope
        }
    }

    func isSwiping(group: UInt32) -> Bool {
        switch self {
        case .gesture(let session): session.scope.group == group
        case .momentum(let scope, _): scope.group == group
        case .idle, .menu, .reorder: false
        }
    }
}
