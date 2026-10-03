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

public struct FocusIntent: Sendable {
    public let tile: TileID?
    public let pid: Int32?
    public let source: FocusSource
    public let observedSpace: SpaceKey?

    public init(tile: TileID?, pid: Int32? = nil, source: FocusSource, observedSpace: SpaceKey? = nil) {
        self.tile = tile
        self.pid = pid
        self.source = source
        self.observedSpace = observedSpace
    }
}

public struct FocusDecision: Sendable {
    public let tile: TileID
    public let source: FocusSource
    public let time: Double
}

public enum FocusState: Sendable {
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
