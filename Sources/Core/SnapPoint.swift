import Foundation

/// A discrete viewport snap position for the focused column.
public enum SnapPoint: String, Sendable, Comparable, Hashable {
    case left, middle, right

    private var sortOrder: Int {
        switch self {
        case .left: return 0
        case .middle: return 1
        case .right: return 2
        }
    }

    public static func < (lhs: SnapPoint, rhs: SnapPoint) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}
