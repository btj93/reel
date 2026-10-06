import Core

public enum FocusSource: String, Codable, Sendable {
    case keyboard, ipc, axFocus, appActivation, click, restore, adoption

    public var protectsFocus: Bool { self != .axFocus }

    public var centers: Bool {
        switch self {
        case .keyboard, .ipc, .restore, .adoption: true
        case .axFocus, .appActivation, .click: false
        }
    }
}

public struct FocusIntent: Equatable, Sendable {
    public let tile: TileID?
    public let pid: Int32?
    public let source: FocusSource
    public let observedSpace: SpaceKey?
    public let requestsOSFocus: Bool

    public init(tile: TileID?, pid: Int32? = nil, source: FocusSource, observedSpace: SpaceKey? = nil, requestsOSFocus: Bool = true) {
        self.tile = tile
        self.pid = pid
        self.source = source
        self.observedSpace = observedSpace
        self.requestsOSFocus = requestsOSFocus
    }

    public func droppedLog(reason: String) -> String {
        "focus dropped source=\(source.rawValue) tile=\(tile.map { String($0.rawValue) } ?? "nil") pid=\(pid.map { String($0) } ?? "nil") reason=\(reason)"
    }
}

public struct FocusDecision: Equatable, Sendable {
    public let tile: TileID
    public let source: FocusSource
    public let time: Double
}

public enum FocusState: Equatable, Sendable {
    case none
    case resolved(FocusDecision)
    case crossing(intent: FocusIntent, time: Double, previous: FocusDecision?)

    public var decision: FocusDecision? {
        switch self {
        case .none: nil
        case .resolved(let decision): decision
        case .crossing(_, _, let previous): previous
        }
    }
}
