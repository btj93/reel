import Core
import Foundation

public struct Rule: Equatable, Sendable {
    public let bundleID: String
    public let floating: Bool

    public init(bundleID: String, floating: Bool) {
        self.bundleID = bundleID
        self.floating = floating
    }
}

public struct EngineConfig: Sendable {
    public static let focusDebounce = 0.15
    public static let crossingTTL = 0.5
    public static let frameRetryDelay = 0.1
    public static let censusSettle = 0.5
    public static let gestureQuiet = 0.3
    public static let flickVelocity = 50.0
    public static let defaultGap = 8.0
    public static let defaultColumnWidth = 0.5

    public let gap: Double
    public let defaultWidth: Double
    public let animate: Bool
    public let gestureSnap: Bool
    public let rules: [Rule]

    public init(gap: Double = defaultGap, defaultWidth: Double = defaultColumnWidth, animate: Bool = true,
                gestureSnap: Bool = true, rules: [Rule] = []) {
        self.gap = gap.isFinite && gap >= 0 ? gap : Self.defaultGap
        self.defaultWidth = defaultWidth.isFinite && defaultWidth > 0 ? defaultWidth : Self.defaultColumnWidth
        self.animate = animate
        self.gestureSnap = gestureSnap
        self.rules = rules
    }
}

public struct DeferredCensus: Equatable, Sendable {
    public let key: SpaceKey
    public let since: Double
}

public enum SpacePhase: Equatable, Sendable {
    case unknown(deferred: DeferredCensus?)
    case settled(SpaceKey)
    case changing(from: SpaceKey, deferred: DeferredCensus?)

    public var key: SpaceKey? {
        switch self {
        case .unknown: nil
        case .settled(let key), .changing(let key, _): key
        }
    }

    public var isChanging: Bool {
        if case .changing = self { return true }
        return false
    }

    var deferred: DeferredCensus? {
        switch self {
        case .unknown(let deferred), .changing(_, let deferred): deferred
        case .settled: nil
        }
    }
}

public struct GroupState: Sendable {
    public internal(set) var strip: Strip
    public internal(set) var windows: [TileID: ObservedWindow] = [:]
    public internal(set) var floating: Set<TileID> = []
    public internal(set) var phase: SpacePhase = .unknown(deferred: nil)
    public internal(set) var epoch: UInt64 = 0
    public internal(set) var focus: FocusState = .none
    public var space: SpaceKey? { phase.key }

    init(display: DisplayGroup, config: EngineConfig) {
        strip = Strip(gap: config.gap, groupArea: Self.area(for: display), defaultWidth: .proportion(config.defaultWidth))
    }

    static func area(for display: DisplayGroup) -> GroupWorkingArea {
        let rect = CGRect(origin: .zero, size: display.frame.size)
        return GroupWorkingArea(regions: [DisplayRegion(displayID: 0, rect: rect)], referenceMidX: rect.midX)
    }
}

public enum ScheduledAction: Sendable {
    case retryFrames
    case focus(FocusIntent)
}

public struct ScheduledWork: Sendable {
    public let scope: EventScope
    public let deadline: Double
    public let action: ScheduledAction
}

public struct World: Sendable {
    public internal(set) var topology: Topology
    public internal(set) var groups: [UInt32: GroupState]
    public internal(set) var spaces = SpaceBook()
    public internal(set) var pointer: PointerState = .idle
    public internal(set) var frames: [TileID: FrameRequest] = [:]
    public internal(set) var appliedFrames: [TileID: FrameRequest] = [:]
    public internal(set) var timers: [TimerToken: ScheduledWork] = [:]
    public internal(set) var config: EngineConfig
    public internal(set) var time: Double = 0
    var serial: UInt64 = 0

    public init(topology: Topology = Topology(revision: 0, groups: [], primaryScreenHeight: 0), config: EngineConfig = EngineConfig()) {
        let topology = topology.isValid ? topology : Topology(revision: topology.revision, groups: [], primaryScreenHeight: 0)
        self.topology = topology
        self.config = config
        groups = Dictionary(uniqueKeysWithValues: topology.groups.map { ($0.id, GroupState(display: $0, config: config)) })
    }

    public func scope(for group: UInt32) -> EventScope? {
        groups[group].map { EventScope(topologyRevision: topology.revision, group: group, spaceEpoch: $0.epoch) }
    }

    public func check() -> [String] {
        var errors: [String] = []
        var allTiles = Set<TileID>()
        for (id, group) in groups {
            let strip = group.strip
            if strip.columns.count != strip.columnData.count || strip.columns.count != strip.snapIndices.count {
                errors.append("group \(id): parallel column arrays")
            }
            if !(strip.columns.isEmpty ? strip.activeColumnIndex == 0 : strip.columns.indices.contains(strip.activeColumnIndex)) {
                errors.append("group \(id): active column")
            }
            for column in strip.columns {
                if column.tiles.isEmpty || !column.tiles.indices.contains(column.activeTileIndex) {
                    errors.append("group \(id): active tile")
                }
                for tile in column.tiles {
                    if !allTiles.insert(tile).inserted { errors.append("duplicate tile \(tile.rawValue)") }
                    if group.windows[tile] == nil || group.floating.contains(tile) { errors.append("unmanaged tiled window") }
                }
            }
            for tile in group.floating {
                if !allTiles.insert(tile).inserted || group.windows[tile] == nil { errors.append("invalid floating window") }
            }
            if Set(group.windows.keys) != Set(strip.columns.flatMap(\.tiles)).union(group.floating) { errors.append("window membership") }
            if !strip.viewOffset.current(at: time).isFinite { errors.append("nonfinite offset") }
            if strip.columnData.contains(where: { !$0.cachedWidth.isFinite || $0.cachedWidth <= 0 }) { errors.append("invalid width") }
            if strip.snapIndices.contains(where: { !strip.snapPoints.indices.contains($0) }) { errors.append("invalid snap index") }
            if let focused = group.focus.decision?.tile, group.windows[focused] == nil { errors.append("stale focus") }
            if group.space == nil, !group.windows.isEmpty { errors.append("windows without a Space") }
        }
        if let owner = pointer.scope,
           scope(for: owner.group) != owner || pointer.tile.map({ groups[owner.group]?.windows[$0] == nil }) == true {
            errors.append("stale pointer")
        }
        for frame in frames.values {
            guard let group = groups[frame.scope.group], scope(for: frame.scope.group) == frame.scope,
                  group.windows[frame.tile] != nil, !group.floating.contains(frame.tile) else {
                errors.append("stale frame"); continue
            }
            if !frame.frame.rect.isFinite { errors.append("nonfinite frame") }
        }
        for work in timers.values where scope(for: work.scope.group) != work.scope { errors.append("stale timer") }
        if spaces.live.keys.contains(where: { $0.space.isEmpty }) { errors.append("stash under an empty key") }
        if spaces.live.values.contains(where: { !$0.isValid }) || spaces.disk.contains(where: { !$0.isValid }) { errors.append("invalid snapshot") }
        return errors
    }
}

extension CGRect {
    var isFinite: Bool { [minX, minY, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
}

extension Topology {
    var isValid: Bool {
        primaryScreenHeight.isFinite && primaryScreenHeight >= 0
            && Set(groups.map(\.id)).count == groups.count && groups.allSatisfy { $0.frame.isFinite && !$0.displays.isEmpty }
            && Set(groups.flatMap(\.displays)).count == groups.flatMap(\.displays).count
    }
}
