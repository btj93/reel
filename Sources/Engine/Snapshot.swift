import Core
import Foundation

public enum SnapshotWidth: Codable, Equatable, Sendable {
    case proportion(Double), fixed(Double), auto

    public init(_ width: ColumnWidth) {
        switch width {
        case .proportion(let value): self = .proportion(value)
        case .fixed(let value): self = .fixed(value)
        case .auto: self = .auto
        }
    }

    public var width: ColumnWidth {
        switch self {
        case .proportion(let value): .proportion(value)
        case .fixed(let value): .fixed(value)
        case .auto: .auto
        }
    }

    var isValid: Bool {
        switch self {
        case .auto: true
        case .fixed(let value), .proportion(let value): value.isFinite && value > 0
        }
    }
}

public struct SnapshotColumn: Codable, Sendable {
    public let windows: [ObservedWindow]
    public let width: SnapshotWidth
    public let activeTileIndex: Int
    public let snapIndex: Int
    public let presetIndex: Int?
    public let isFullWidth: Bool

    public init(windows: [ObservedWindow], width: SnapshotWidth, activeTileIndex: Int = 0,
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
    private let spaceIdentity: SnapshotSpace
    public var space: SpaceKey { spaceIdentity.key }
    public let columns: [SnapshotColumn]
    public let floating: [ObservedWindow]
    public let activeColumnIndex: Int
    public let offset: Double
    public let focusedTile: TileID?

    public init(group: UInt32, space: SpaceKey, columns: [SnapshotColumn], floating: [ObservedWindow] = [],
                activeColumnIndex: Int = 0, offset: Double = 0, focusedTile: TileID? = nil) {
        self.group = group
        self.spaceIdentity = SnapshotSpace(space)
        self.columns = columns
        self.floating = floating
        self.activeColumnIndex = activeColumnIndex
        self.offset = offset
        self.focusedTile = focusedTile
    }

    public var windows: [ObservedWindow] { columns.flatMap(\.windows) + floating }
    public var fingerprint: Set<UInt32> { Set(windows.map { $0.id.rawValue }) }

    public static func encode(_ snapshots: [Snapshot]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshots)
    }

    public static func decode(_ data: Data) throws -> [Snapshot] {
        let snapshots = try JSONDecoder().decode([Snapshot].self, from: data)
        guard snapshots.allSatisfy(\.isValid) else { throw SnapshotError.invalidState }
        return snapshots
    }

    var isValid: Bool {
        offset.isFinite && Set(windows.map(\.id)).count == windows.count
            && (focusedTile.map { tile in windows.contains { $0.id == tile } } ?? true)
            && (columns.isEmpty ? activeColumnIndex == 0 : columns.indices.contains(activeColumnIndex))
            && columns.allSatisfy {
                !$0.windows.isEmpty && $0.width.isValid
                    && $0.windows.indices.contains($0.activeTileIndex) && $0.snapIndex >= 0
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

public enum SnapshotError: Error { case invalidState }

func snapshot(_ group: GroupState, id: UInt32, time: Double) -> Snapshot? {
    guard let space = group.space else { return nil }
    return Snapshot(group: id, space: space,
        columns: group.strip.columns.enumerated().map { index, column in
            SnapshotColumn(windows: column.tiles.compactMap { group.windows[$0] },
                width: SnapshotWidth(column.width), activeTileIndex: column.activeTileIndex,
                snapIndex: group.strip.snapIndices[index], presetIndex: column.presetIndex,
                isFullWidth: column.isFullWidth)
        }, floating: group.floating.sorted(by: { $0.rawValue < $1.rawValue }).compactMap { group.windows[$0] },
        activeColumnIndex: group.strip.activeColumnIndex, offset: group.strip.viewOffset.current(at: time),
        focusedTile: group.focus.decision?.tile ?? group.strip.activeColumn?.activeTile)
}
