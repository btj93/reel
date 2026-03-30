import Foundation
import CoreGraphics

/// The result of laying out a single tile on screen.
public struct TargetFrame: Sendable {
    public let tileID: TileID
    public let frame: CGRect
    public let isVisible: Bool     // Overlaps the viewport
    public let isOffScreen: Bool   // Needs sliver/corner treatment
    public let visibilityZone: VisibilityZone

    public init(tileID: TileID, frame: CGRect, isVisible: Bool, isOffScreen: Bool, visibilityZone: VisibilityZone) {
        self.tileID = tileID
        self.frame = frame
        self.isVisible = isVisible
        self.isOffScreen = isOffScreen
        self.visibilityZone = visibilityZone
    }
}

/// Visibility zones for prioritizing AX call updates.
public enum VisibilityZone: Int, Comparable, Sendable {
    case visible = 0      // On screen — update every frame
    case nearBuffer = 1   // 1-2 columns beyond viewport — update at low priority
    case far = 2          // Everything else — update only on settle

    public static func < (lhs: VisibilityZone, rhs: VisibilityZone) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Pure function: compute target frames for all tiles in a strip.
///
/// This is the core layout computation. It takes the strip state and returns
/// where every window should be positioned on screen, including off-screen
/// sliver handling.
///
/// - Parameters:
///   - strip: The current strip state
///   - time: Current time (for evaluating animations)
///   - sliverWidth: Width of the visible sliver for off-screen windows (default 1px)
///   - nearBufferColumns: Number of columns beyond viewport to keep in near-buffer zone
/// - Returns: Array of target frames for all tiles
public func computeTargetFrames(
    strip: Strip,
    time: Double,
    sliverWidth: Double = 1,
    nearBufferColumns: Int = 2
) -> [TargetFrame] {
    guard !strip.columns.isEmpty else { return [] }

    let viewPos = strip.viewPos(at: time)
    let wa = strip.workingArea
    let viewLeft = viewPos
    let viewRight = viewPos + wa.width

    // First pass: determine visible column range
    var visibleFirst: Int?
    var visibleLast: Int?

    var columnPositions: [(index: Int, stripX: Double)] = []
    var x: Double = 0
    for i in 0..<strip.columns.count {
        let colWidth = strip.columnData[i].currentWidth
        columnPositions.append((i, x))

        let screenLeft = x - viewPos
        let screenRight = screenLeft + colWidth

        if screenRight > 0 && screenLeft < wa.width {
            if visibleFirst == nil { visibleFirst = i }
            visibleLast = i
        }

        x += colWidth + strip.gap
    }

    let vFirst = visibleFirst ?? 0
    let vLast = visibleLast ?? 0
    let nearLeft = max(0, vFirst - nearBufferColumns)
    let nearRight = min(strip.columns.count - 1, vLast + nearBufferColumns)

    // Second pass: compute target frames
    var results: [TargetFrame] = []

    for (i, stripX) in columnPositions {
        let column = strip.columns[i]
        let colWidth = strip.columnData[i].currentWidth
        let screenX = stripX - viewPos + wa.minX

        // Determine visibility zone
        let zone: VisibilityZone
        if i >= vFirst && i <= vLast {
            zone = .visible
        } else if i >= nearLeft && i <= nearRight {
            zone = .nearBuffer
        } else {
            zone = .far
        }

        let isVisible = zone == .visible
        let isPartiallyVisible = (screenX + colWidth > wa.minX) && (screenX < wa.maxX)

        // Compute tile frames within the column (vertical stacking)
        let tileFrames = computeTileFrames(
            column: column,
            screenX: screenX,
            colWidth: colWidth,
            workingArea: wa,
            gap: strip.gap
        )

        for (tileID, tileFrame) in tileFrames {
            var finalFrame = tileFrame
            var offScreen = false

            if !isPartiallyVisible {
                // Apply sliver positioning
                finalFrame = sliverFrame(
                    originalFrame: tileFrame,
                    workingArea: wa,
                    side: screenX < wa.minX ? .left : .right,
                    sliverWidth: sliverWidth
                )
                offScreen = true
            }

            results.append(TargetFrame(
                tileID: tileID,
                frame: finalFrame,
                isVisible: isVisible || isPartiallyVisible,
                isOffScreen: offScreen,
                visibilityZone: zone
            ))
        }
    }

    return results
}

/// Compute frames for tiles within a single column (vertical stacking).
func computeTileFrames(
    column: Column,
    screenX: Double,
    colWidth: Double,
    workingArea: CGRect,
    gap: Double
) -> [(TileID, CGRect)] {
    guard !column.tiles.isEmpty else { return [] }

    // Clamp column width to working area
    let clampedWidth = min(colWidth, workingArea.width)

    let tileCount = column.tiles.count
    let totalGaps = Double(max(0, tileCount - 1)) * gap
    let availableHeight = workingArea.height - totalGaps
    let tileHeight = max(1, availableHeight / Double(tileCount))

    var results: [(TileID, CGRect)] = []
    var y = workingArea.minY

    for tile in column.tiles {
        let frame = CGRect(
            x: screenX,
            y: y,
            width: clampedWidth,
            height: tileHeight
        )
        results.append((tile, frame))
        y += tileHeight + gap
    }

    return results
}

/// Side of the screen for sliver positioning.
enum SliverSide {
    case left, right
}

/// Compute a sliver frame for an off-screen window.
/// Keeps `sliverWidth` pixels visible at the screen edge.
func sliverFrame(
    originalFrame: CGRect,
    workingArea: CGRect,
    side: SliverSide,
    sliverWidth: Double
) -> CGRect {
    switch side {
    case .left:
        // Position so rightmost `sliverWidth` px is at left screen edge
        return CGRect(
            x: workingArea.minX - originalFrame.width + sliverWidth,
            y: originalFrame.minY,
            width: originalFrame.width,
            height: originalFrame.height
        )
    case .right:
        // Position so leftmost `sliverWidth` px is at right screen edge
        return CGRect(
            x: workingArea.maxX - sliverWidth,
            y: originalFrame.minY,
            width: originalFrame.width,
            height: originalFrame.height
        )
    }
}
