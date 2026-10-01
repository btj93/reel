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
