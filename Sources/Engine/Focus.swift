import Core

public enum FocusSource: String, Codable, Sendable {
    case keybinding, ipc, axNotification, appActivation, spaceRestore, pointer, adoption

    public var protectsFocus: Bool { self != .axNotification }

    public var centers: Bool {
        switch self {
        case .keybinding, .ipc, .spaceRestore, .adoption: true
        case .axNotification, .appActivation, .pointer: false
        }
    }
}

public struct FocusIntent: Sendable {
    public let tile: TileID?
    public let appID: Int32?
    public let source: FocusSource
    public let observedSpace: SpaceKey?

    public init(tile: TileID?, appID: Int32? = nil, source: FocusSource, observedSpace: SpaceKey? = nil) {
        self.tile = tile
        self.appID = appID
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
