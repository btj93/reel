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
    /// The adoption title keeps rule matching stable while live metadata changes.
    public internal(set) var ruleTitle: String?
    public let floating: Bool
    public let classification: WindowClassification?
    public let initialFrame: AXRect?

    public init(id: TileID, pid: Int32, bundleID: String?, title: String = "", floating: Bool = false,
                classification: WindowClassification? = nil, initialFrame: AXRect? = nil) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.title = title
        self.floating = floating
        self.classification = classification
        self.initialFrame = initialFrame
    }

    func adoptingTitle(_ title: String) -> ObservedWindow {
        var copy = self
        copy.ruleTitle = title.isEmpty ? nil : title
        return copy
    }

    func adopting(_ previous: ObservedWindow) -> ObservedWindow {
        let window: ObservedWindow
        if classification == .provisionalTitle, previous.ruleTitle != nil {
            window = ObservedWindow(id: id, pid: pid, bundleID: bundleID, title: title, floating: previous.floating,
                                    classification: previous.classification, initialFrame: initialFrame)
        } else { window = self }
        return window.adoptingTitle(previous.ruleTitle ?? title)
    }

    func reframed(_ frame: AXRect) -> ObservedWindow {
        ObservedWindow(id: id, pid: pid, bundleID: bundleID, title: title, floating: floating, classification: classification, initialFrame: frame)
            .adoptingTitle(ruleTitle ?? title)
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
    case setWidthPreset(TileID, Int)
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
    case clearPositionsApp(String)

    public var tile: TileID? {
        switch self {
        case .focus(let tile), .setWidth(let tile, _), .setWidthPreset(let tile, _), .toggleFullWidth(let tile), .toggleFloating(let tile), .close(let tile): tile
        default: nil
        }
    }
}

public enum PointerInput: Sendable {
    case scroll(ScrollInput)
    /// A left press: `tile` when it hit a title bar with the modifier held, else nil, which only ends a live session.
    case press(TileID?, at: AXPoint)
    case drag(AXPoint)
    case release(AXPoint)
    case overlayReady
    /// A pill picked in the menu; the command acts on the tile the menu opened for, whatever tile it names.
    case choose(Command)
    /// The gap the released drag lands in, `0...columns.count`.
    case drop(Int)
    case cancel

    public var tile: TileID? {
        if case .press(let tile, _) = self { tile } else { nil }
    }

    /// Where a session that starts at this input begins: a press on its tile, a swipe or a wheel notch on the strip
    /// under the cursor.
    var beginsAt: AXPoint? {
        guard case .scroll(let scroll) = self, scroll.phase == .began || scroll.phase == .discrete else { return nil }
        return scroll.at
    }
}

public enum FrameResult: Sendable {
    case applied
    case sizeUnconfirmed
    case failed
    case timedOut
}

public struct Event: Sendable {
    public enum Kind: Sendable {
        case windowAdded(ObservedWindow, frontmost: Bool = false)
        case windowChanged(ObservedWindow, frontmost: Bool = false)
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
        case spaceChanged(key: SpaceKey, epoch: UInt64, windows: [ObservedWindow], frontmost: TileID? = nil)
        case topologyChanged(Topology)
        case configChanged(EngineConfig)
        case frameCompleted(tile: TileID, revision: UInt64, result: FrameResult, landed: AXRect? = nil)
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
