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
