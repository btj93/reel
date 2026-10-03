import Core
import Foundation

/// One physical display. `frame` is its full bounds and `area` its working area, both in AX coordinates.
public struct Display: Equatable, Sendable {
    public let id: UInt32
    public let frame: CGRect
    public let area: CGRect

    public init(id: UInt32, frame: CGRect, area: CGRect) {
        self.id = id
        self.frame = frame
        self.area = area
    }
}

/// Displays that share one strip.
public struct DisplayGroup: Equatable, Sendable {
    /// The smallest member display id: the same whatever the arrangement, and a display whose Space can be read.
    public let id: UInt32
    /// Left to right.
    public let displays: [Display]
    /// The union of the members' working areas.
    public let frame: CGRect

    init(_ displays: [Display]) {
        self.displays = displays.sorted { ($0.frame.minX, $0.id) < ($1.frame.minX, $1.id) }
        id = displays.map(\.id).min()!
        frame = displays.dropFirst().reduce(displays[0].area) { $0.union($1.area) }
    }
}

/// The displays and how they group. Horizontally touching displays (edges within `touchSlop`, any vertical overlap)
/// share one strip only when every display shows the same Space; with separate Spaces each display has its own.
public struct Topology: Sendable {
    public static let touchSlop = 0.5

    public let revision: UInt64
    public let displays: [Display]
    public let separateSpaces: Bool
    public let primaryScreenHeight: Double
    /// Left to right by their leftmost display.
    public let groups: [DisplayGroup]

    public init(revision: UInt64, displays: [Display], separateSpaces: Bool, primaryScreenHeight: Double) {
        self.revision = revision
        self.displays = displays
        self.separateSpaces = separateSpaces
        self.primaryScreenHeight = primaryScreenHeight
        var rest = displays
        var groups: [DisplayGroup] = []
        while let first = rest.popLast() {
            var members = [first]
            var index = 0
            while !separateSpaces, index < members.count {
                let member = members[index]
                members += rest.filter { Self.touch(member.frame, $0.frame) }
                rest.removeAll { Self.touch(member.frame, $0.frame) }
                index += 1
            }
            groups.append(DisplayGroup(members))
        }
        self.groups = groups.sorted { ($0.displays[0].frame.minX, $0.id) < ($1.displays[0].frame.minX, $1.id) }
    }

    static func touch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        (abs(lhs.maxX - rhs.minX) <= touchSlop || abs(rhs.maxX - lhs.minX) <= touchSlop)
            && max(lhs.minY, rhs.minY) < min(lhs.maxY, rhs.maxY)
    }

    public func group(id: UInt32) -> DisplayGroup? { groups.first { $0.id == id } }

    public func group(of display: UInt32) -> DisplayGroup? { groups.first { $0.displays.contains { $0.id == display } } }

    /// The group whose displays come nearest `point`; a point on a display is on its group.
    public func nearestGroup(to point: CGPoint) -> DisplayGroup? {
        func distance(_ group: DisplayGroup) -> Double {
            group.displays.map { display in
                hypot(max(display.frame.minX - point.x, 0, point.x - display.frame.maxX),
                      max(display.frame.minY - point.y, 0, point.y - display.frame.maxY))
            }.min()!
        }
        return groups.min { distance($0) < distance($1) }
    }

    /// Each group is one touching run of displays, or a single display under separate Spaces, and no two groups touch.
    var groupingErrors: [String] {
        var errors: [String] = []
        let grouped = groups.flatMap(\.displays).map(\.id)
        if grouped.count != displays.count || Set(grouped) != Set(displays.map(\.id)) { errors.append("display not in exactly one group") }
        for group in groups {
            if group.id != group.displays.map(\.id).min() { errors.append("group \(group.id): id is not its smallest display") }
            if separateSpaces, group.displays.count > 1 { errors.append("group \(group.id): merged under separate Spaces") }
            var reached = [group.displays[0]]
            var index = 0
            while index < reached.count {
                let display = reached[index]
                reached += group.displays.filter { other in !reached.contains(other) && Self.touch(display.frame, other.frame) }
                index += 1
            }
            if reached.count != group.displays.count { errors.append("group \(group.id): displays not contiguous") }
        }
        for lhs in groups where !separateSpaces {
            for rhs in groups where lhs.id < rhs.id
                && lhs.displays.contains(where: { display in rhs.displays.contains { Self.touch(display.frame, $0.frame) } }) {
                errors.append("groups \(lhs.id) and \(rhs.id) touch")
            }
        }
        return errors
    }

    var isValid: Bool {
        primaryScreenHeight.isFinite && primaryScreenHeight >= 0
            && Set(displays.map(\.id)).count == displays.count
            && displays.allSatisfy { $0.id != 0 && $0.frame.isFinite && $0.area.isFinite }
    }
}

extension World {
    /// Content follows its display: to the group now holding it, else to the nearest group. A column goes by the display
    /// it centers on; hidden and floating windows and saved strips by their group's own display. A group that gains or
    /// loses a column is rebuilt from its arrivals in left-to-right order of where they came from; one that keeps exactly
    /// its own columns only takes the new area. With no display left, every strip is saved until one returns.
    mutating func onTopology(_ next: Topology, _ pass: inout Pass) {
        guard next.revision > topology.revision, next.isValid else { return }
        cancelPointer(&pass)
        for id in groups.keys.sorted() { cancelTimers(group: id, &pass) }
        for tile in frames.keys.ordered() { invalidate(tile, &pass) }
        let previous = groups, before = topology
        topology = next
        func destination(_ display: UInt32) -> UInt32? {
            if let group = next.group(of: display) { return group.id }
            let frame = before.displays.first { $0.id == display }?.frame ?? .zero
            return next.nearestGroup(to: CGPoint(x: frame.midX, y: frame.midY))?.id
        }
        var arrivals: [UInt32: [Arrival]] = [:]
        for old in before.groups {
            guard let state = previous[old.id] else { continue }
            guard let home = destination(old.id) else {
                stash(state, id: old.id, time: pass.now)
                continue
            }
            // Its strip on screen moves with its windows, so its own saved copy would list them twice.
            if next.group(id: old.id) == nil, let space = state.space { spaces.live[GroupSpace(group: old.id, space: space)] = nil }
            var routed: [UInt32: [Column]] = [home: []]
            for index in state.strip.columns.indices {
                routed[destination(state.strip.regionForColumn(index, at: pass.now).displayID) ?? home, default: []]
                    .append(state.strip.columns[index])
            }
            for (id, columns) in routed {
                arrivals[id, default: []].append(Arrival(from: old.id, source: state, columns: columns, home: id == home))
            }
        }
        groups = [:]
        for display in next.groups {
            let incoming = arrivals[display.id] ?? []
            var group: GroupState
            if let kept = previous[display.id], incoming.count == 1, incoming[0].from == display.id, incoming[0].home,
               incoming[0].columns.count == kept.strip.columns.count {
                group = kept
                group.strip.groupArea = GroupState.area(for: display)
                group.strip.recalculateWidths(at: pass.now)
            } else {
                group = rebuilt(display, kept: previous[display.id], from: incoming, at: pass.now)
            }
            if case .changing(let from, _) = group.phase { group.phase = .settled(from) }
            // As a window added to an empty Space does, arrivals name an empty fingerprint Space, so it can be saved.
            if group.space?.isEmpty == true, !(group.windows.isEmpty && group.hidden.isEmpty) {
                group.phase = .settled(.fingerprint(Set(group.windows.keys.map(\.rawValue) + group.hidden.keys.map(\.rawValue))))
            }
            group.focus = group.focus.decision.flatMap { group.windows[$0.tile] == nil ? nil : FocusState.resolved($0) } ?? .none
            groups[display.id] = group
            pass.layout.insert(display.id)
        }
        // A group that took its Space from an arrival keeps what it saved there itself.
        for id in groups.keys.sorted() where groups[id]!.space != previous[id]?.space {
            if let space = groups[id]!.space, let saved = spaces.live.removeValue(forKey: GroupSpace(group: id, space: space)) {
                join(saved, into: id, at: pass.now)
            }
        }
        if let fallback = next.groups.first?.id {
            for key in spaces.live.keys.sorted(by: { SpaceOrder($0.group, $0.space) < SpaceOrder($1.group, $1.space) })
            where groups[key.group] == nil {
                let saved = spaces.live.removeValue(forKey: key)!
                let target = GroupSpace(group: destination(key.group) ?? fallback, space: key.space)
                if groups[target.group]!.space == key.space { join(saved, into: target.group, at: pass.now) }
                else { spaces.live[target] = saved.moved(to: target.group, after: spaces.live[target]) }
            }
        }
        pass.persist = true
    }

    /// A saved strip of the Space its new group shows now joins the strip on screen, after its columns, as a vanished
    /// group's strip on screen does. A window some group already holds stays there.
    private mutating func join(_ saved: Snapshot, into id: UInt32, at time: Double) {
        let held = Set(groups.values.flatMap { Array($0.windows.keys) + Array($0.hidden.keys) })
        var group = groups[id]!
        let base = group.placeAmongHidden(group.strip.columns.count)
        for column in saved.columns {
            let windows = column.windows.filter { !held.contains($0.id) }
            guard !windows.isEmpty else { continue }
            var restored = Column(tiles: windows.map(\.id), width: column.width, presetIndex: column.presetIndex, isFullWidth: column.isFullWidth)
            restored.activeTileIndex = min(column.activeTileIndex, windows.count - 1)
            group.strip.restoreColumn(restored, at: group.strip.columns.count, time: time)
            for window in windows { group.windows[window.id] = window }
        }
        for window in saved.floating where !held.contains(window.id) {
            group.windows[window.id] = window
            group.floating.insert(window.id)
        }
        for hidden in saved.hidden where !held.contains(hidden.window.id) { group.hidden[hidden.window.id] = hidden.placed(at: hidden.place + base) }
        groups[id] = group
    }

    private func rebuilt(_ display: DisplayGroup, kept: GroupState?, from arrivals: [Arrival], at time: Double) -> GroupState {
        var group = kept ?? GroupState(display: display, config: config)
        if group.space == nil, let donor = arrivals.first(where: { $0.source.space != nil })?.source {
            group.phase = donor.phase
            group.epoch = donor.epoch
            if kept == nil { group.focus = donor.focus }
        }
        let active = (kept ?? arrivals.first?.source)?.strip.activeColumn?.activeTile
        group.strip = GroupState(display: display, config: config).strip
        group.windows = [:]
        group.floating = []
        group.hidden = [:]
        for arrival in arrivals {
            let base = group.placeAmongHidden(group.strip.columns.count)
            for column in arrival.columns {
                group.strip.insertColumn(column, at: time, atIndex: group.strip.columns.count)
                for tile in column.tiles { group.windows[tile] = arrival.source.windows[tile] }
            }
            guard arrival.home else { continue }
            for tile in arrival.source.floating {
                group.windows[tile] = arrival.source.windows[tile]
                group.floating.insert(tile)
            }
            for (tile, hidden) in arrival.source.hidden { group.hidden[tile] = hidden.placed(at: hidden.place + base) }
        }
        guard !group.strip.columns.isEmpty else { return group }
        if let index = [active, group.focus.decision?.tile].compactMap({ $0.flatMap(group.strip.columnIndex) }).first {
            group.strip.activeColumnIndex = index
        }
        group.strip.recenter(animated: false, at: time)
        group.strip.recalculateWidths(at: time)
        group.strip.recenter(animated: false, at: time)
        return group
    }
}

/// What one old group hands a new one when the topology changes: some of its columns, and with `home` its hidden and
/// floating windows too.
struct Arrival {
    let from: UInt32
    let source: GroupState
    let columns: [Column]
    let home: Bool
}
