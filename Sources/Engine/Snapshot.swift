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
    public let windows: [ObservedWindow]
    public let fingerprint: Set<UInt32>
    let identities: Set<WindowIdentity>
    let bundles: Set<String>

    public init(group: UInt32, space: SpaceKey, columns: [SnapshotColumn], floating: [ObservedWindow] = [],
                activeColumnIndex: Int = 0, offset: Double = 0, focusedTile: TileID? = nil) {
        self.group = group
        self.space = space
        self.columns = columns
        self.floating = floating
        self.activeColumnIndex = activeColumnIndex
        self.offset = offset
        self.focusedTile = focusedTile
        windows = columns.flatMap(\.windows) + floating
        fingerprint = Set(windows.map { $0.id.rawValue })
        identities = Set(windows.map(WindowIdentity.init))
        bundles = Set(identities.map(\.bundleID))
    }

    private enum CodingKeys: String, CodingKey {
        case group, space, columns, floating, activeColumnIndex, offset, focusedTile
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(group: try container.decode(UInt32.self, forKey: .group),
                  space: try container.decode(SnapshotSpace.self, forKey: .space).key,
                  columns: try container.decode([SnapshotColumn].self, forKey: .columns),
                  floating: try container.decode([ObservedWindow].self, forKey: .floating),
                  activeColumnIndex: try container.decode(Int.self, forKey: .activeColumnIndex),
                  offset: try container.decode(Double.self, forKey: .offset),
                  focusedTile: try container.decodeIfPresent(TileID.self, forKey: .focusedTile))
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
    }

    public static func encode(_ snapshots: [Snapshot]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshots)
    }

    public static func decode(_ data: Data) throws -> [Snapshot] {
        try JSONDecoder().decode([Snapshot].self, from: data).filter(\.isValid)
    }

    var isValid: Bool {
        offset.isFinite && fingerprint.count == windows.count
            && windows.allSatisfy(\.isValid)
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
        focusedTile: group.focus.decision?.tile ?? group.strip.activeColumn?.activeTile)
}

func removing(_ tile: TileID, from saved: Snapshot) -> Snapshot {
    let columns = saved.columns.compactMap { column -> SnapshotColumn? in
        let windows = column.windows.filter { $0.id != tile }
        guard !windows.isEmpty else { return nil }
        return SnapshotColumn(windows: windows, width: column.width, activeTileIndex: min(column.activeTileIndex, windows.count - 1),
                              snapIndex: column.snapIndex, presetIndex: column.presetIndex, isFullWidth: column.isFullWidth)
    }
    return Snapshot(group: saved.group, space: saved.space, columns: columns, floating: saved.floating.filter { $0.id != tile },
                    activeColumnIndex: min(saved.activeColumnIndex, max(0, columns.count - 1)), offset: saved.offset,
                    focusedTile: saved.focusedTile == tile ? nil : saved.focusedTile)
}

func restoredGroup(display: DisplayGroup, config: EngineConfig, key: SpaceKey, epoch: UInt64, windows: [ObservedWindow],
                   saved: Snapshot?, time: Double) -> GroupState {
    var group = GroupState(display: display, config: config)
    group.phase = .settled(key)
    group.epoch = epoch
    group.windows = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
    var unused = windows.sorted { $0.id.rawValue < $1.id.rawValue }
    var mappedIDs: [TileID: TileID] = [:]
    let tiers: [(_ saved: ObservedWindow, _ live: ObservedWindow) -> Bool] = [
        { $0.id == $1.id && $0.bundleID == $1.bundleID },
        { WindowIdentity($0) == WindowIdentity($1) },
        { $0.bundleID == $1.bundleID },
    ]
    for matches in tiers {
        for old in saved?.windows ?? [] where mappedIDs[old.id] == nil {
            guard let index = unused.firstIndex(where: { matches(old, $0) }) else { continue }
            mappedIDs[old.id] = unused.remove(at: index).id
        }
    }
    if let saved {
        for column in saved.columns {
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
        for window in saved.floating { if let match = mappedIDs[window.id] { group.floating.insert(match) } }
    }
    for window in visualOrder(unused) {
        if shouldFloat(window, config: config) { group.floating.insert(window.id) }
        else { group.strip.insertColumn(Column(tiles: [window.id], width: group.strip.defaultWidth), at: time, atIndex: group.strip.columns.count) }
    }
    group.strip.activeColumnIndex = min(saved?.activeColumnIndex ?? 0, max(0, group.strip.columns.count - 1))
    group.strip.viewOffset = .static(saved?.offset ?? 0)
    if let oldFocus = saved?.focusedTile, let focused = mappedIDs[oldFocus] {
        group.focus = .resolved(FocusDecision(tile: focused, source: .restore, time: time))
    }
    group.strip.recalculateWidths(at: time)
    return group
}
