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
