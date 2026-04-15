import Foundation

/// A column on the horizontal strip, containing one or more vertically stacked windows.
public struct Column: Sendable {
    /// Windows stacked vertically in this column.
    public var tiles: [TileID]

    /// Index of the active (focused) tile within this column.
    public var activeTileIndex: Int

    /// Desired width specification.
    public var width: ColumnWidth

    /// Which preset index is currently active (for cycling through presets). Nil if manually sized.
    public var presetIndex: Int?

    /// Whether this column is in full-width mode (fills the working area).
    public var isFullWidth: Bool

    public init(
        tiles: [TileID],
        activeTileIndex: Int = 0,
        width: ColumnWidth = .proportion(0.5),
        presetIndex: Int? = nil,
        isFullWidth: Bool = false
    ) {
        self.tiles = tiles
        self.activeTileIndex = activeTileIndex
        self.width = width
        self.presetIndex = presetIndex
        self.isFullWidth = isFullWidth
    }

    /// The currently focused tile, if any.
    public var activeTile: TileID? {
        guard activeTileIndex >= 0, activeTileIndex < tiles.count else { return nil }
        return tiles[activeTileIndex]
    }
}

/// Cached layout data for a column, kept in sync with the Column array.
public struct ColumnData: Sendable {
    /// Resolved pixel width (from ColumnWidth + working area).
    public var cachedWidth: Double

    /// Non-nil when the width is animating (e.g., during resize).
    public var widthAnimation: SpringAnimation?

    /// Non-nil when the raise Y-offset is animating (focus change in raise mode).
    public var raiseAnimation: SpringAnimation?

    /// Target raise offset: 0 for active column (ceiling), raiseHeight for non-active (bottom).
    /// Set when starting a raise animation; read on convergence.
    public var cachedRaiseTarget: Double = 0

    /// Current effective width at a given time (reads animation if active).
    public func currentWidth(at time: Double) -> Double {
        if let anim = widthAnimation {
            let (value, done) = anim.evaluateWithStatus(at: time)
            return done ? cachedWidth : value
        }
        return cachedWidth
    }

    /// Current raise Y-offset at a given time.
    /// Returns the animated offset if a spring is in flight, otherwise cachedRaiseTarget.
    public func currentRaiseOffset(at time: Double) -> Double {
        if let anim = raiseAnimation {
            let (value, done) = anim.evaluateWithStatus(at: time)
            return done ? cachedRaiseTarget : value
        }
        return cachedRaiseTarget
    }

    public init(cachedWidth: Double, widthAnimation: SpringAnimation? = nil, raiseAnimation: SpringAnimation? = nil) {
        self.cachedWidth = cachedWidth
        self.widthAnimation = widthAnimation
        self.raiseAnimation = raiseAnimation
    }
}
