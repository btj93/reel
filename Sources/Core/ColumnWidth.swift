import Foundation

/// How a column's width is specified.
public enum ColumnWidth: Equatable, Sendable {
    /// Fraction of working area width (e.g., 0.5 = half screen).
    case proportion(Double)

    /// Fixed logical pixel width.
    case fixed(Double)

    /// Let the window decide its own width (use its current size).
    case auto

    /// Resolve to actual pixel width given the working area. Always clamped to screen width.
    public func resolve(workingAreaWidth: Double, gap: Double) -> Double {
        let raw: Double
        switch self {
        case .proportion(let p):
            raw = workingAreaWidth * p
        case .fixed(let f):
            raw = f
        case .auto:
            raw = workingAreaWidth * 0.5
        }
        return min(raw, workingAreaWidth)
    }
}
