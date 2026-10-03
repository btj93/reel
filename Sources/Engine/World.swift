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
    /// A settled mixed fingerprint read commits once it repeats, or on this many settled reads after the last Space
    /// notification.
    public static let censusReads = 4
    public static let gestureQuiet = 0.3
    public static let flickVelocity = 50.0
    public static let defaultGap = 8.0
    public static let defaultColumnWidth = 0.5
    public static let defaultWidthPresets = [0.33, 0.5, 0.67]
    public static let defaultSnapPoints: [SnapPoint] = [.middle]
    public static let defaultStiffness = 800.0
    public static let defaultDampingRatio = 1.0
    public static let defaultBounceDistance = 40.0
    public static let defaultBounceDampingRatio = 0.6
    /// A user resize within this many points of the column width is the app rounding, not a new width.
    public static let userResizeSlop = 2.0

    public let gap: Double
    public let defaultWidth: Double
    public let animate: Bool
    public let gestureSnap: Bool
    public let rules: [Rule]
    public let widthPresets: [Double]
    public let snapPoints: [SnapPoint]
    public let scroll: SpringParams
    public let dampingRatio: Double
    public let bounceDistance: Double
    public let bounceDampingRatio: Double
    /// Raise-style focus indicator: unfocused columns sit this many points lower. Zero turns raise off.
    public let raiseHeight: Double

    public init(gap: Double = defaultGap, defaultWidth: Double = defaultColumnWidth, animate: Bool = true,
                gestureSnap: Bool = true, rules: [Rule] = [], widthPresets: [Double] = defaultWidthPresets,
                snapPoints: [SnapPoint] = defaultSnapPoints, stiffness: Double = defaultStiffness,
                dampingRatio: Double = defaultDampingRatio, bounceDistance: Double = defaultBounceDistance,
                bounceDampingRatio: Double = defaultBounceDampingRatio, raiseHeight: Double = 0) {
        func valid(_ value: Double, _ fallback: Double) -> Double { value.isFinite && value > 0 ? value : fallback }
        self.gap = gap.isFinite && gap >= 0 ? gap : Self.defaultGap
        self.defaultWidth = valid(defaultWidth, Self.defaultColumnWidth)
        self.animate = animate
        self.gestureSnap = gestureSnap
        self.rules = rules
        let presets = widthPresets.filter { $0.isFinite && $0 > 0 && $0 <= 1 }
        self.widthPresets = presets.isEmpty ? Self.defaultWidthPresets : presets
        self.snapPoints = snapPoints.isEmpty ? Self.defaultSnapPoints : Array(Set(snapPoints)).sorted()
        self.dampingRatio = valid(dampingRatio, Self.defaultDampingRatio)
        scroll = SpringParams(dampingRatio: self.dampingRatio, stiffness: valid(stiffness, Self.defaultStiffness), epsilon: 0.5)
        self.bounceDistance = bounceDistance.isFinite && bounceDistance >= 0 ? bounceDistance : Self.defaultBounceDistance
        self.bounceDampingRatio = valid(bounceDampingRatio, Self.defaultBounceDampingRatio)
        self.raiseHeight = raiseHeight.isFinite && raiseHeight > 0 ? raiseHeight : 0
    }

    func configure(_ strip: inout Strip) {
        strip.gap = gap
        strip.defaultWidth = .proportion(defaultWidth)
        strip.widthPresets = widthPresets.map(ColumnWidth.proportion)
        strip.scrollSpringParams = scroll
        strip.bounceDistance = bounceDistance
        strip.bounceDampingRatio = bounceDampingRatio
        if strip.snapPoints != snapPoints {
            strip.snapPoints = snapPoints
            strip.snapIndices = strip.snapIndices.map { _ in strip.defaultSnapIndex }
        }
        for index in strip.columns.indices where strip.columns[index].presetIndex.map({ !widthPresets.indices.contains($0) }) == true {
            strip.columns[index].presetIndex = nil
        }
    }
}

public struct DeferredCensus: Equatable, Sendable {
    public let key: SpaceKey
    public let since: Double
    /// Set only when a same-Space read deferred a group that had not been torn down.
    public var holds = false
    /// Reads deferred a full settle after the last Space notification, and the last of them.
    public var settledReads = 0
    public var lastSettled: SpaceKey?

    /// A fingerprint is built from the read, so every fingerprint read answers the one pending change; a Space id
    /// answers only its own.
    func covers(_ read: SpaceKey) -> Bool {
        key == read || !(key.isAuthoritative || read.isAuthoritative)
    }
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

    /// A same-Space re-read is pending and the group was never torn down, so focus there is still real.
    var isSameSpaceHold: Bool {
        if case .changing(_, let deferred?) = self { return deferred.holds }
        return false
    }

    var acceptsFocus: Bool { !isChanging || isSameSpaceHold }

    /// A real Space change starting from here still has to cancel the pointer, timers and frames.
    var awaitsTeardown: Bool {
        if case .settled = self { return true }
        return isSameSpaceHold
    }

    init(space: SpaceKey?, deferred: DeferredCensus?) {
        switch (space, deferred) {
        case (nil, _): self = .unknown(deferred: deferred)
        case (let space?, nil): self = .settled(space)
        case (let space?, let deferred?): self = .changing(from: space, deferred: deferred)
        }
    }

    public var deferred: DeferredCensus? {
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
    /// When the user or the OS last focused a window here. It only moves forward: a close, a hide or an empty Space
    /// clears the decision, not this.
    public internal(set) var focusedAt = -Double.infinity
    /// Windows whose app hid, or that minimized, with the place they left. A Space change stashes them with the strip;
    /// a close forgets them.
    public internal(set) var hidden: [TileID: HiddenTile] = [:]
    public var space: SpaceKey? { phase.key }

    init(display: DisplayGroup, config: EngineConfig) {
        strip = Strip(gap: config.gap, groupArea: Self.area(for: display), defaultWidth: .proportion(config.defaultWidth))
        config.configure(&strip)
    }

    /// The place `window` left when it hid, if it is the same app's window coming back.
    func returning(_ window: ObservedWindow) -> HiddenTile? {
        hidden[window.id].flatMap { $0.window.hasSameOwner(as: window) ? $0 : nil }
    }

    /// A hidden window comes back to the place it left: its own column, or floating. One that floated only for its
    /// facts tiles once they say it tiles.
    mutating func putBack(_ window: ObservedWindow, from returning: HiddenTile, config: EngineConfig, at time: Double) {
        hidden.removeValue(forKey: window.id)
        windows[window.id] = window
        if let column = returning.column { strip.restoreColumn(column, at: placeInStrip(returning.place), time: time) }
        else if joinsStrip(was: returning.window, now: window, config: config) { strip.insertTile(window.id, at: time) }
        else { floating.insert(window.id) }
    }

    /// A strip index as a place among the visible and hidden columns.
    func placeAmongHidden(_ index: Int) -> Int {
        hiddenPlaces.reduce(index) { place, hidden in hidden <= place ? place + 1 : place }
    }

    /// A place among the visible and hidden columns as a strip index.
    func placeInStrip(_ place: Int) -> Int {
        place - hiddenPlaces.filter { $0 < place }.count
    }

    private var hiddenPlaces: [Int] { hidden.values.filter { $0.column != nil }.map(\.place).sorted() }

    /// One region per display, in the group's viewport coordinates, so widths resolve against the display a column
    /// centers on.
    static func area(for display: DisplayGroup) -> GroupWorkingArea {
        let origin = display.frame.origin
        let regions = display.displays.map { DisplayRegion(displayID: $0.id, rect: $0.area.offsetBy(dx: -origin.x, dy: -origin.y)) }
        return GroupWorkingArea(regions: regions, referenceMidX: regions[0].rect.midX)
    }

    var isAnimating: Bool {
        if case .static = strip.viewOffset {
            return strip.columnData.contains { $0.widthAnimation != nil || $0.raiseAnimation != nil }
        }
        return true
    }
}

/// A hidden window comes back as its own column, or floating when `width` is nil. `place` counts the other hidden
/// columns too, so windows hidden one app at a time come back in their own order, whichever returns first. `frame` is
/// the release frame computed when it hid (the write itself is dropped if Reel was paused); release writes it again.
public struct HiddenTile: Codable, Sendable {
    public let window: ObservedWindow
    public let width: ColumnWidth?
    public let presetIndex: Int?
    public let isFullWidth: Bool
    public let place: Int
    public let frame: AXRect?

    init(window: ObservedWindow, column: Column?, place: Int, frame: AXRect?) {
        self.window = window
        width = column?.width
        presetIndex = column?.presetIndex
        isFullWidth = column?.isFullWidth ?? false
        self.place = place
        self.frame = frame
    }

    func placed(at place: Int) -> HiddenTile {
        HiddenTile(window: window, column: column, place: place, frame: frame)
    }

    var column: Column? {
        width.map { Column(tiles: [window.id], width: $0, presetIndex: presetIndex, isFullWidth: isFullWidth) }
    }

    var isValid: Bool {
        window.isValid && place >= 0 && (width?.isValid ?? true) && (presetIndex ?? 0) >= 0 && (frame?.rect.isFinite ?? true)
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

public struct Stamp: Equatable, Sendable {
    public let revision: UInt64
    public let epochs: [UInt32: UInt64]

    public init(revision: UInt64, epochs: [UInt32: UInt64]) {
        self.revision = revision
        self.epochs = epochs
    }

    /// The stamp of work done for one group, such as a frame write: it is stale once that group's scope moves on.
    public init(_ scope: EventScope) {
        self.init(revision: scope.topologyRevision, epochs: [scope.group: scope.spaceEpoch])
    }
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

    public init(topology: Topology = Topology(revision: 0, displays: [], separateSpaces: true, primaryScreenHeight: 0),
                config: EngineConfig = EngineConfig()) {
        let topology = topology.isValid ? topology : Topology(revision: topology.revision, displays: [], separateSpaces: true, primaryScreenHeight: 0)
        self.topology = topology
        self.config = config
        groups = Dictionary(uniqueKeysWithValues: topology.groups.map { ($0.id, GroupState(display: $0, config: config)) })
    }

    public func scope(for group: UInt32) -> EventScope? {
        groups[group].map { EventScope(topologyRevision: topology.revision, group: group, spaceEpoch: $0.epoch) }
    }

    /// The strip on screen in `group`, as it would be stashed now.
    public func currentSnapshot(group: UInt32) -> Snapshot? {
        groups[group].flatMap { Engine.snapshot($0, id: group, time: time) }
    }

    /// Windows kept off the current strips, hidden or on a saved strip, so the Observer still hears them close.
    public var trackedElsewhere: Set<UInt32> {
        Set(groups.values.flatMap(\.hidden.keys).map(\.rawValue)
            + spaces.live.values.flatMap { $0.fingerprint.union($0.hidden.map(\.window.id.rawValue)) })
    }

    /// What an observation is stamped with: the revision and every group's epoch, so the event takes the scope of the
    /// group it routes to as that group stood when it was observed.
    public var stamp: Stamp { Stamp(revision: topology.revision, epochs: groups.mapValues(\.epoch)) }

    public func scope(for group: UInt32, stamp: Stamp) -> EventScope {
        EventScope(topologyRevision: stamp.revision, group: group, spaceEpoch: stamp.epochs[group] ?? .max)
    }

    /// The group commands act on: the one focused last, else the leftmost.
    public var activeGroup: UInt32? {
        let focused = groups.filter { $0.value.focusedAt > -.infinity }
        return focused.max { $0.value.focusedAt != $1.value.focusedAt ? $0.value.focusedAt < $1.value.focusedAt : $0.key > $1.key }?.key
            ?? topology.groups.first?.id
    }

    public func owner(of tile: TileID) -> UInt32? { groups.first { $0.value.windows[tile] != nil }?.key }

    /// The group an event goes to: the group holding the window it names, else the active group. A new window goes to
    /// the group its frame is nearest, an activation that names no window to a group holding one of the app's.
    public func route(_ kind: Event.Kind) -> UInt32? {
        let tile: TileID?
        switch kind {
        case .windowAdded(let window): return owner(of: window.id) ?? home(window) ?? activeGroup
        case .windowRemoved(let id), .windowMoved(let id, _), .frameCompleted(let id, _, _): tile = id
        case .focus(let intent) where intent.tile == nil:
            return groups.keys.sorted().first { id in groups[id]!.windows.values.contains { $0.pid == intent.pid } } ?? activeGroup
        case .focus(let intent): tile = intent.tile
        case .command(let command, _), .ipc(_, let command): tile = command.tile
        case .pointer(let input, _): return input.tile.flatMap(owner) ?? pointer.scope?.group ?? activeGroup
        default: tile = nil
        }
        return tile.flatMap { tile in owner(of: tile) ?? groups.first { $0.value.hidden[tile] != nil }?.key } ?? activeGroup
    }

    /// The windows of a census that `group` takes: its own, and each one no group holds whose frame is nearest it or
    /// that has no frame.
    public func routed(_ windows: [ObservedWindow], to group: UInt32) -> [ObservedWindow] {
        guard topology.groups.count > 1 else { return windows }
        return windows.filter { (owner(of: $0.id) ?? home($0) ?? group) == group }
    }

    private func home(_ window: ObservedWindow) -> UInt32? {
        window.initialFrame.flatMap { topology.nearestGroup(to: CGPoint(x: $0.rect.midX, y: $0.rect.midY))?.id }
    }

    /// The groups a Space notification concerns: each whose display now shows another Space than the one it settled
    /// on, or that has not settled. `reads` holds what each display shows; a display missing from it (SkyLight cannot
    /// tell) concerns its group.
    public func groupsOnAnotherSpace(_ reads: [UInt32: SpaceKey]) -> [UInt32] {
        groups.keys.sorted().filter { id in
            guard case .settled(let key) = groups[id]!.phase, key.isAuthoritative, let read = reads[id] else { return true }
            return read != key
        }
    }

    /// The frame loop runs while any strip still animates.
    public var needsTicks: Bool { groups.values.contains(where: \.isAnimating) }

    public func check() -> [String] {
        var errors: [String] = []
        var allTiles = Set<TileID>()
        errors += topology.groupingErrors
        if Set(groups.keys) != Set(topology.groups.map(\.id)) { errors.append("groups differ from the topology") }
        for display in topology.groups where groups[display.id].map({ $0.strip.groupArea != GroupState.area(for: display) }) == true {
            errors.append("group \(display.id): area differs from its displays")
        }
        let hidden = groups.values.flatMap(\.hidden.keys)
        if Set(hidden).count != hidden.count { errors.append("window hidden in two groups") }
        if !topology.groups.isEmpty, spaces.live.keys.contains(where: { groups[$0.group] == nil }) { errors.append("stash of a group that is gone") }
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
            if let decision = group.focus.decision, decision.time > group.focusedAt { errors.append("group \(id): focus decision newer than focusedAt") }
            if group.space == nil, !group.windows.isEmpty { errors.append("windows without a Space") }
            if group.hidden.keys.contains(where: { tile in groups.values.contains { $0.windows[tile] != nil } }) { errors.append("hidden window managed") }
            if let deferred = group.phase.deferred, !deferred.key.isAuthoritative, deferred.settledReads >= EngineConfig.censusReads {
                errors.append("group \(id): fingerprint census deferred past \(EngineConfig.censusReads) settled reads")
            }
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
