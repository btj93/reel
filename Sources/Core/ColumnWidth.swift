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

extension ColumnWidth: Codable {
    private enum CodingKeys: String, CodingKey {
        case proportion, fixed, auto
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(Double.self, forKey: .proportion) {
            self = .proportion(value)
        } else if let value = try container.decodeIfPresent(Double.self, forKey: .fixed) {
            self = .fixed(value)
        } else if try container.decodeIfPresent(Bool.self, forKey: .auto) != nil {
            self = .auto
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown ColumnWidth"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .proportion(let value):
            try container.encode(value, forKey: .proportion)
        case .fixed(let value):
            try container.encode(value, forKey: .fixed)
        case .auto:
            try container.encode(true, forKey: .auto)
        }
    }
}

extension ColumnWidth {
    /// Resolve a column's width when it straddles multiple display regions.
    /// Returns an area-weighted blend of `(p × region.width)` across overlaps.
    /// `.fixed` ignores the blend and returns the literal. `.auto` is treated as
    /// `.proportion(0.5)`. Empty overlaps → 0.
    public func resolveBlended(
        overlaps: [(region: DisplayRegion, area: Double)],
        gap: Double
    ) -> Double {
        switch self {
        case .fixed(let f):
            // Clamp exactly as `resolve` does. Returning the literal made Strip
            // cache a clamped width while LayoutEngine positioned subsequent
            // columns from the unbounded one — cumulative X drift, bad snap math
            // and overlapping columns for a wide adopted window.
            // `blend(p: 1.0, …)` is the area-weighted region width, i.e. the same
            // bound `resolve` clamps against. Empty overlaps → 0, so fall back to
            // the literal rather than collapsing the column to zero width.
            let span = Self.blend(p: 1.0, overlaps: overlaps)
            return span > 0 ? min(f, span) : f
        case .proportion(let p):
            return Self.blend(p: p, overlaps: overlaps)
        case .auto:
            return Self.blend(p: 0.5, overlaps: overlaps)
        }
    }

    private static func blend(
        p: Double,
        overlaps: [(region: DisplayRegion, area: Double)]
    ) -> Double {
        let totalArea = overlaps.reduce(0.0) { $0 + $1.area }
        guard totalArea > 0 else { return 0 }
        var acc = 0.0
        for (region, area) in overlaps {
            let weight = area / totalArea
            acc += weight * (p * Double(region.rect.width))
        }
        return acc
    }
}
