import Core

public struct EventScope: Equatable, Sendable {
    public let topologyRevision: UInt64
    public let group: UInt32
    public let spaceEpoch: UInt64

    public init(topologyRevision: UInt64, group: UInt32, spaceEpoch: UInt64) {
        self.topologyRevision = topologyRevision
        self.group = group
        self.spaceEpoch = spaceEpoch
    }
}

public struct ObservedWindow: Equatable, Codable, Sendable {
    public let id: TileID
    public let pid: Int32
    public let bundleID: String?
    public let title: String
    public let floating: Bool
    public let initialFrame: AXRect?

    public init(id: TileID, pid: Int32, bundleID: String?, title: String = "", floating: Bool = false,
                initialFrame: AXRect? = nil) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.title = title
        self.floating = floating
        self.initialFrame = initialFrame
    }

    var isValid: Bool { id.rawValue != 0 && pid > 0 && (initialFrame?.rect.isFinite ?? true) }

    /// Bundle-less windows share no app identity, so they never match each other by app alone.
    var knownBundleID: String? { bundleID?.isEmpty == false ? bundleID : nil }
}

public enum Command: Sendable {
    case focusLeft, focusRight
    case focus(TileID)
    case moveLeft, moveRight
    case setWidth(TileID, Double)
    case cycleWidthPreset
    case toggleFullWidth(TileID)
    case toggleFloating(TileID)
    case close(TileID)
}

public enum PointerInput: Sendable {
    case beginGesture(TileID)
    case delta(Double)
    case endGesture
    case openMenu(TileID)
    case menu(Command)
    case beginReorder(TileID)
    case dropReorder(Int)
    case cancel
}

public enum FrameResult: Sendable {
    case applied
    case failed
    case timedOut
}

public struct Event: Sendable {
    public enum Kind: Sendable {
        case windowAdded(ObservedWindow)
        case windowRemoved(TileID)
        case focus(FocusIntent)
        case command(Command, FocusSource)
        case ipc(id: UInt64, command: Command)
        case query(id: UInt64)
        case pointer(PointerInput, session: PointerToken? = nil)
        case spaceWillChange
        case spaceChanged(key: SpaceKey, epoch: UInt64, windows: [ObservedWindow])
        case topologyChanged(Topology)
        case configChanged(EngineConfig)
        case frameCompleted(tile: TileID, revision: UInt64, result: FrameResult)
        case timer(TimerToken)
        case tick
        case loadSnapshots([Snapshot])

        var isGlobal: Bool {
            switch self {
            case .topologyChanged, .configChanged, .loadSnapshots, .query: true
            default: false
            }
        }
    }

    public let scope: EventScope
    public let kind: Kind

    public init(scope: EventScope, kind: Kind) {
        self.scope = scope
        self.kind = kind
    }
}
