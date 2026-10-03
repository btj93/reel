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

    func hasSameOwner(as other: ObservedWindow) -> Bool { pid == other.pid && knownBundleID == other.knownBundleID }
}

func appBundles(_ windows: [ObservedWindow]) -> Set<String> { Set(windows.compactMap(\.knownBundleID)) }

public enum Command: Sendable {
    case focusLeft, focusRight
    /// The active window of the nearest strip above or below, across independent groups.
    case focusUp, focusDown
    case focus(TileID)
    case moveLeft, moveRight
    case setWidth(TileID, Double)
    case cycleWidthPreset
    case toggleFullWidth(TileID)
    case toggleFloating(TileID)
    case close(TileID)
    /// Rewrite every frame of the group, whatever the engine last asked for.
    case recover
    /// Bring off-screen tiles back on screen before the runtime exits.
    case release
    /// Forget every saved strip, in this session and on disk.
    case clearPositions

    var tile: TileID? {
        switch self {
        case .focus(let tile), .setWidth(let tile, _), .toggleFullWidth(let tile), .toggleFloating(let tile), .close(let tile): tile
        default: nil
        }
    }
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

    var tile: TileID? {
        switch self {
        case .beginGesture(let tile), .openMenu(let tile), .beginReorder(let tile): tile
        default: nil
        }
    }
}

public enum FrameResult: Sendable {
    case applied
    case failed
    case timedOut
}

public struct Event: Sendable {
    public enum Kind: Sendable {
        case windowAdded(ObservedWindow)
        case windowChanged(ObservedWindow)
        case windowRemoved(TileID)
        /// The windows left the strip but live on: their app hid, or one minimized.
        case windowsHidden([TileID])
        /// The user moved or resized a window: the runtime already dropped the engine's own writes as echoes.
        case windowMoved(TileID, AXRect)
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
            case .topologyChanged, .configChanged, .loadSnapshots, .query, .windowChanged, .tick: true
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
