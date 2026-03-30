import Foundation

/// Unique identifier for a managed window tile.
/// Wraps a CGWindowID (UInt32) for type safety.
public struct TileID: Hashable, Codable, Sendable {
    public let rawValue: UInt32

    public init(_ rawValue: UInt32) {
        self.rawValue = rawValue
    }
}
