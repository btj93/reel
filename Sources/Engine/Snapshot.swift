import Core
import Foundation

extension ColumnWidth {
    var isValid: Bool {
        switch self {
        case .auto: true
        case .fixed(let value), .proportion(let value): value.isFinite && value > 0
        }
    }
}

public struct SnapshotColumn: Codable, Sendable {
    public let windows: [ObservedWindow]
    public let width: ColumnWidth
    public let activeTileIndex: Int
    public let snapIndex: Int
    public let presetIndex: Int?
    public let isFullWidth: Bool

    public init(windows: [ObservedWindow], width: ColumnWidth, activeTileIndex: Int = 0,
                snapIndex: Int = 0, presetIndex: Int? = nil, isFullWidth: Bool = false) {
        self.windows = windows
        self.width = width
        self.activeTileIndex = activeTileIndex
        self.snapIndex = snapIndex
        self.presetIndex = presetIndex
        self.isFullWidth = isFullWidth
    }
}

public struct Snapshot: Codable, Sendable {
    public let group: UInt32
    public let space: SpaceKey
    public let columns: [SnapshotColumn]
    public let floating: [ObservedWindow]
    public let activeColumnIndex: Int
    public let offset: Double
    public let focusedTile: TileID?
    /// Windows hidden from this strip, with the places they left. Not on screen, so not in `windows` or `fingerprint`.
    public let hidden: [HiddenTile]
    public let windows: [ObservedWindow]
    public let fingerprint: Set<UInt32>
    let identities: Set<WindowIdentity>
    let bundles: Set<String>

    public init(group: UInt32, space: SpaceKey, columns: [SnapshotColumn], floating: [ObservedWindow] = [],
                activeColumnIndex: Int = 0, offset: Double = 0, focusedTile: TileID? = nil, hidden: [HiddenTile] = []) {
        self.group = group
        self.space = space
        self.columns = columns
        self.floating = floating
        self.activeColumnIndex = activeColumnIndex
        self.offset = offset
        self.focusedTile = focusedTile
        self.hidden = hidden.sorted { $0.window.id.rawValue < $1.window.id.rawValue }
        windows = columns.flatMap(\.windows) + floating
        fingerprint = Set(windows.map { $0.id.rawValue })
        identities = Set(windows.map(WindowIdentity.init))
        bundles = appBundles(windows)
    }

    private enum CodingKeys: String, CodingKey {
        case group, space, columns, floating, activeColumnIndex, offset, focusedTile, hidden
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(group: try container.decode(UInt32.self, forKey: .group),
                  space: try container.decode(SnapshotSpace.self, forKey: .space).key,
                  columns: try container.decode([SnapshotColumn].self, forKey: .columns),
                  floating: try container.decode([ObservedWindow].self, forKey: .floating),
                  activeColumnIndex: try container.decode(Int.self, forKey: .activeColumnIndex),
                  offset: try container.decode(Double.self, forKey: .offset),
                  focusedTile: try container.decodeIfPresent(TileID.self, forKey: .focusedTile),
                  hidden: try container.decode([HiddenTile].self, forKey: .hidden))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(group, forKey: .group)
        try container.encode(SnapshotSpace(space), forKey: .space)
        try container.encode(columns, forKey: .columns)
        try container.encode(floating, forKey: .floating)
        try container.encode(activeColumnIndex, forKey: .activeColumnIndex)
        try container.encode(offset, forKey: .offset)
        try container.encodeIfPresent(focusedTile, forKey: .focusedTile)
        try container.encode(hidden, forKey: .hidden)
    }

    var isEmpty: Bool { windows.isEmpty && hidden.isEmpty }

    var isValid: Bool {
        offset.isFinite && fingerprint.count == windows.count
            && windows.allSatisfy(\.isValid)
            && hidden.allSatisfy(\.isValid) && Set(hidden.map(\.window.id.rawValue)).count == hidden.count
            && Set(hidden.map(\.window.id.rawValue)).isDisjoint(with: fingerprint)
            && (focusedTile.map { tile in windows.contains { $0.id == tile } } ?? true)
            && (columns.isEmpty ? activeColumnIndex == 0 : columns.indices.contains(activeColumnIndex))
            && columns.allSatisfy {
                !$0.windows.isEmpty && $0.width.isValid
                    && $0.windows.indices.contains($0.activeTileIndex) && $0.snapIndex >= 0 && ($0.presetIndex ?? 0) >= 0
            }
    }
}

private enum SnapshotSpace: Codable, Sendable {
    case skylight(UInt64), fingerprint([UInt32])

    init(_ key: SpaceKey) {
        switch key {
        case .skylight(let id): self = .skylight(id)
        case .fingerprint(let ids): self = .fingerprint(ids.sorted())
        }
    }

    var key: SpaceKey {
        switch self {
        case .skylight(let id): .skylight(id)
        case .fingerprint(let ids): .fingerprint(Set(ids))
        }
    }
}

func snapshot(_ group: GroupState, id: UInt32, time: Double) -> Snapshot? {
    guard let space = group.space else { return nil }
    return Snapshot(group: id, space: space,
        columns: group.strip.columns.enumerated().map { index, column in
            SnapshotColumn(windows: column.tiles.compactMap { group.windows[$0] },
                width: column.width, activeTileIndex: column.activeTileIndex,
                snapIndex: group.strip.snapIndices[index], presetIndex: column.presetIndex,
                isFullWidth: column.isFullWidth)
        }, floating: group.floating.ordered().compactMap { group.windows[$0] },
        activeColumnIndex: group.strip.activeColumnIndex, offset: group.strip.viewOffset.current(at: time),
        focusedTile: group.focus.decision?.tile ?? group.strip.activeColumn?.activeTile, hidden: Array(group.hidden.values))
}

func removing(_ ids: Set<UInt32>, from saved: Snapshot) -> Snapshot {
    let columns = saved.columns.compactMap { column -> SnapshotColumn? in
        let windows = column.windows.filter { !ids.contains($0.id.rawValue) }
        guard !windows.isEmpty else { return nil }
        return SnapshotColumn(windows: windows, width: column.width, activeTileIndex: min(column.activeTileIndex, windows.count - 1),
                              snapIndex: column.snapIndex, presetIndex: column.presetIndex, isFullWidth: column.isFullWidth)
    }
    return Snapshot(group: saved.group, space: saved.space, columns: columns, floating: saved.floating.filter { !ids.contains($0.id.rawValue) },
                    activeColumnIndex: min(saved.activeColumnIndex, max(0, columns.count - 1)), offset: saved.offset,
                    focusedTile: saved.focusedTile.flatMap { ids.contains($0.rawValue) ? nil : $0 },
                    hidden: saved.hidden.filter { !ids.contains($0.window.id.rawValue) })
}

extension Snapshot {
    /// This strip saved under `group`, after `existing`'s columns and hidden windows when that group saved this Space
    /// too. A window `existing` already lists stays where it is there.
    func moved(to group: UInt32, after existing: Snapshot?) -> Snapshot {
        let rest = existing.map { removing($0.fingerprint.union($0.hidden.map(\.window.id.rawValue)), from: self) } ?? self
        let base = existing.map { $0.columns.count + $0.hidden.filter { $0.width != nil }.count } ?? 0
        return Snapshot(group: group, space: space, columns: (existing?.columns ?? []) + rest.columns,
                        floating: (existing?.floating ?? []) + rest.floating,
                        activeColumnIndex: existing?.activeColumnIndex ?? rest.activeColumnIndex, offset: existing?.offset ?? rest.offset,
                        focusedTile: existing?.focusedTile ?? rest.focusedTile,
                        hidden: (existing?.hidden ?? []) + rest.hidden.map { $0.placed(at: $0.place + base) })
    }
}

func refreshing(_ window: ObservedWindow, in saved: Snapshot) -> Snapshot {
    func fresh(_ old: ObservedWindow) -> ObservedWindow { old.id == window.id ? window.adopting(old) : old }
    let columns = saved.columns.map {
        SnapshotColumn(windows: $0.windows.map(fresh), width: $0.width, activeTileIndex: $0.activeTileIndex,
                       snapIndex: $0.snapIndex, presetIndex: $0.presetIndex, isFullWidth: $0.isFullWidth)
    }
    return Snapshot(group: saved.group, space: saved.space, columns: columns, floating: saved.floating.map(fresh),
                    activeColumnIndex: saved.activeColumnIndex, offset: saved.offset, focusedTile: saved.focusedTile,
                    hidden: saved.hidden)
}

/// With `hidesMissing`, a saved window absent from the read keeps its place as hidden: an app hidden on another
/// Space hid here too. Only for a Space of this session; after a reboot an absent id is dead or another window's.
func restoredGroup(display: DisplayGroup, config: EngineConfig, key: SpaceKey, epoch: UInt64, windows: [ObservedWindow],
                   saved: Snapshot?, hidesMissing: Bool, time: Double) -> GroupState {
    var group = GroupState(display: display, config: config)
    group.phase = .settled(key)
    group.epoch = epoch
    group.windows = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.adoptingTitle($0.ruleTitle ?? $0.title)) })
    group.hidden = Dictionary(uniqueKeysWithValues: (saved?.hidden ?? []).map { ($0.window.id, $0) })
    // A window that hid on this Space and is back on screen returns to its own place, after the rest of the strip.
    let returning = windows.compactMap { window in group.returning(window).map { (window, $0) } }.sorted { $0.1.place < $1.1.place }
    let returned = Set(returning.map(\.0.id))
    var unused = windows.filter { !returned.contains($0.id) }.sorted { $0.id.rawValue < $1.id.rawValue }
    var mappedIDs: [TileID: TileID] = [:]
    let tiers: [(_ saved: ObservedWindow, _ live: ObservedWindow) -> Bool] = [
        { $0.id == $1.id && $0.knownBundleID == $1.knownBundleID },
        { WindowIdentity($0) == WindowIdentity($1) },
        { $0.knownBundleID != nil && $0.knownBundleID == $1.knownBundleID },
    ]
    for matches in tiers {
        for old in saved?.windows ?? [] where mappedIDs[old.id] == nil {
            guard let index = unused.firstIndex(where: { matches(old, $0) }) else { continue }
            let live = unused.remove(at: index)
            mappedIDs[old.id] = live.id
            if hidesMissing, old.id == live.id, old.hasSameOwner(as: live) {
                group.windows[live.id] = live.adopting(old)
            }
        }
    }
    var joined: [ObservedWindow] = []
    if let saved {
        for column in saved.columns {
            for old in column.windows where hidesMissing && mappedIDs[old.id] == nil {
                let own = Column(tiles: [old.id], width: column.width, presetIndex: column.presetIndex, isFullWidth: column.isFullWidth)
                group.hidden[old.id] = HiddenTile(window: old, column: own, place: group.placeAmongHidden(group.strip.columns.count), frame: nil)
            }
            let matched = column.windows.compactMap { mappedIDs[$0.id].flatMap { group.windows[$0] } }
            let tiled = matched.filter { !shouldFloat($0, config: config) }
            for window in matched where shouldFloat(window, config: config) { group.floating.insert(window.id) }
            guard !tiled.isEmpty else { continue }
            var restored = Column(tiles: tiled.map(\.id), width: column.width)
            let active = mappedIDs[column.windows[column.activeTileIndex].id]
            restored.activeTileIndex = tiled.firstIndex(where: { $0.id == active }) ?? min(column.activeTileIndex, tiled.count - 1)
            restored.presetIndex = column.presetIndex.flatMap { group.strip.widthPresets.indices.contains($0) ? $0 : nil }
            restored.isFullWidth = column.isFullWidth
            group.strip.insertColumn(restored, at: time, atIndex: group.strip.columns.count)
            group.strip.snapIndices[group.strip.columns.count - 1] = min(column.snapIndex, max(0, group.strip.snapPoints.count - 1))
        }
        for old in saved.floating {
            guard let live = mappedIDs[old.id].flatMap({ group.windows[$0] }) else {
                if hidesMissing { group.hidden[old.id] = HiddenTile(window: old, column: nil, place: 0, frame: nil) }
                continue
            }
            if joinsStrip(was: old, now: live, config: config) { joined.append(live) } else { group.floating.insert(live.id) }
        }
    }
    group.strip.activeColumnIndex = min(saved?.activeColumnIndex ?? 0, max(0, group.strip.columns.count - 1))
    group.strip.viewOffset = .static(saved?.offset ?? 0)
    for (window, hidden) in returning { group.putBack(window, from: hidden, config: config, width: display.adoptionWidth(window, defaultWidth: group.strip.defaultWidth), at: time) }
    group.hidden = group.hidden.filter { group.windows[$0.key] == nil }
    let active = group.strip.activeColumnIndex, offset = group.strip.viewOffset
    let fresh = visualOrder(unused)
    for window in fresh where shouldFloat(window, config: config) { group.floating.insert(window.id) }
    for window in joined + fresh where !group.floating.contains(window.id) {
        group.strip.insertColumn(Column(tiles: [window.id], width: display.adoptionWidth(window, defaultWidth: group.strip.defaultWidth)), at: time, atIndex: group.strip.columns.count)
    }
    group.strip.activeColumnIndex = min(active, max(0, group.strip.columns.count - 1))
    group.strip.viewOffset = offset
    if let oldFocus = saved?.focusedTile, let focused = mappedIDs[oldFocus] {
        group.focus = .resolved(FocusDecision(tile: focused, source: .restore, time: time))
    }
    group.strip.recalculateWidths(at: time)
    return group
}

extension Snapshot {
    public func excluding(bundleID: String) -> Snapshot {
        let ids = Set((windows + hidden.map(\.window)).filter { $0.bundleID == bundleID }.map { $0.id.rawValue })
        return removing(ids, from: self)
    }
}
