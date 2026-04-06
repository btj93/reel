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
    nearBufferColumns: Int = 2,
    mode: LayoutMode = .normal
) -> [TargetFrame] {
    guard !strip.columns.isEmpty else { return [] }

    if case .minimap(let draggedIndex, let insertionIndex, let cursorPosition) = mode {
        return computeMinimapFrames(
            strip: strip, time: time,
            draggedIndex: draggedIndex, insertionIndex: insertionIndex,
            cursorPosition: cursorPosition
        )
    }

    let viewPos = strip.viewPos(at: time)
    let wa = strip.workingArea

    let colCount = strip.columns.count

    // First pass: cache widths/positions, determine visible column range
    var colWidths = [Double]()
    colWidths.reserveCapacity(colCount)
    var colXPositions = [Double]()
    colXPositions.reserveCapacity(colCount)

    var visibleFirst: Int?
    var visibleLast: Int?

    var x: Double = 0
    for i in 0..<colCount {
        let colWidth = strip.columnData[i].currentWidth(at: time)
        colWidths.append(colWidth)
        colXPositions.append(x)

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
    let nearRight = min(colCount - 1, vLast + nearBufferColumns)

    // Second pass: compute target frames using cached widths
    var results: [TargetFrame] = []
    results.reserveCapacity(colCount)

    for i in 0..<colCount {
        let column = strip.columns[i]
        let colWidth = colWidths[i]
        let screenX = colXPositions[i] - viewPos + wa.minX

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
        computeTileFrames(
            into: &results,
            column: column,
            screenX: screenX,
            colWidth: colWidth,
            workingArea: wa,
            gap: strip.gap,
            isVisible: isVisible,
            isPartiallyVisible: isPartiallyVisible,
            zone: zone,
            sliverWidth: sliverWidth
        )
    }

    return results
}

/// Compute frames for tiles within a single column (vertical stacking).
/// Appends TargetFrames directly into the results array, applying sliver
/// positioning for off-screen columns.
func computeTileFrames(
    into results: inout [TargetFrame],
    column: Column,
    screenX: Double,
    colWidth: Double,
    workingArea: CGRect,
    gap: Double,
    isVisible: Bool,
    isPartiallyVisible: Bool,
    zone: VisibilityZone,
    sliverWidth: Double
) {
    guard !column.tiles.isEmpty else { return }

    // Clamp column width to working area
    let clampedWidth = min(colWidth, workingArea.width)

    let tileCount = column.tiles.count
    let totalGaps = Double(max(0, tileCount - 1)) * gap
    let availableHeight = workingArea.height - totalGaps
    let tileHeight = max(1, availableHeight / Double(tileCount))

    var y = workingArea.minY

    for tile in column.tiles {
        let tileFrame = CGRect(
            x: screenX,
            y: y,
            width: clampedWidth,
            height: tileHeight
        )

        var finalFrame = tileFrame
        var offScreen = false

        if !isPartiallyVisible {
            finalFrame = sliverFrame(
                originalFrame: tileFrame,
                workingArea: workingArea,
                side: screenX < workingArea.minX ? .left : .right,
                sliverWidth: sliverWidth
            )
            offScreen = true
        }

        results.append(TargetFrame(
            tileID: tile,
            frame: finalFrame,
            isVisible: isVisible || isPartiallyVisible,
            isOffScreen: offScreen,
            visibilityZone: zone
        ))

        y += tileHeight + gap
    }
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

func computeMinimapFrames(
    strip: Strip,
    time: Double,
    draggedIndex: Int,
    insertionIndex: Int,
    cursorPosition: CGPoint
) -> [TargetFrame] {
    let wa = strip.workingArea
    let colCount = strip.columns.count

    var thumbnailWidths: [(index: Int, width: Double)] = []
    for i in 0..<colCount where i != draggedIndex {
        let w = strip.columnData[i].currentWidth(at: time)
        thumbnailWidths.append((i, w))
    }

    let totalWidth = thumbnailWidths.reduce(0.0) { $0 + $1.width }
        + Double(max(0, thumbnailWidths.count - 1)) * strip.gap
    let startX = wa.minX + (wa.width - totalWidth) / 2

    let thumbnailHeight = wa.height * 0.4
    let thumbnailY = wa.minY + (wa.height - thumbnailHeight) / 2

    var results: [TargetFrame] = []
    var x = startX

    for (colIndex, colWidth) in thumbnailWidths {
        let column = strip.columns[colIndex]
        let tileCount = column.tiles.count
        let tileHeight = max(1, thumbnailHeight / Double(tileCount))

        var y = thumbnailY
        for tile in column.tiles {
            results.append(TargetFrame(
                tileID: tile,
                frame: CGRect(x: x, y: y, width: colWidth, height: tileHeight),
                isVisible: true,
                isOffScreen: false,
                visibilityZone: .visible
            ))
            y += tileHeight
        }
        x += colWidth + strip.gap
    }

    let draggedColumn = strip.columns[draggedIndex]
    let draggedWidth = strip.columnData[draggedIndex].currentWidth(at: time)
    let dragTileCount = draggedColumn.tiles.count
    let dragTileHeight = max(1, thumbnailHeight / Double(dragTileCount))
    var dy = cursorPosition.y
    for tile in draggedColumn.tiles {
        results.append(TargetFrame(
            tileID: tile,
            frame: CGRect(x: cursorPosition.x, y: dy, width: draggedWidth, height: dragTileHeight),
            isVisible: true,
            isOffScreen: false,
            visibilityZone: .visible
        ))
        dy += dragTileHeight
    }

    return results
}
