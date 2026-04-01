import Foundation
import CoreGraphics

/// Compute the target view offset for a snap point.
/// The offset positions the active column so that:
/// - `.left`: column left edge = screen left edge
/// - `.middle`: column center = screen center
/// - `.right`: column right edge = screen right edge
public func computeSnapOffset(
    snapPoint: SnapPoint,
    columnWidth: Double,
    workingAreaWidth: Double
) -> Double {
    let slack = max(0, workingAreaWidth - columnWidth)
    switch snapPoint {
    case .left:   return 0
    case .middle: return -slack / 2
    case .right:  return -slack
    }
}

/// Find the snap point whose offset is closest to a projected view offset.
/// Returns (index into snapPoints, computed offset for that snap point).
public func nearestSnapPoint(
    projectedOffset: Double,
    snapPoints: [SnapPoint],
    columnWidth: Double,
    workingAreaWidth: Double
) -> (index: Int, offset: Double) {
    var bestIndex = 0
    var bestOffset = computeSnapOffset(snapPoint: snapPoints[0], columnWidth: columnWidth, workingAreaWidth: workingAreaWidth)
    var bestDist = abs(projectedOffset - bestOffset)

    for i in 1..<snapPoints.count {
        let candidate = computeSnapOffset(snapPoint: snapPoints[i], columnWidth: columnWidth, workingAreaWidth: workingAreaWidth)
        let dist = abs(projectedOffset - candidate)
        if dist < bestDist {
            bestDist = dist
            bestIndex = i
            bestOffset = candidate
        }
    }
    return (bestIndex, bestOffset)
}

/// Find the next snap milestone the window hasn't reached, moving rightward on screen.
/// Used by navigateLeft: window slides right → snap to first unreached milestone going right.
/// Snap offsets go: left=0, middle=-slack/2, right=-slack (more negative = further right).
/// Returns (index, offset) of the target snap point.
public func nextSnapMilestoneRight(
    currentOffset: Double,
    snapPoints: [SnapPoint],
    columnWidth: Double,
    workingAreaWidth: Double
) -> (index: Int, offset: Double) {
    // Iterate left→right (index 0→n). First snap whose offset < currentOffset is unreached.
    for i in 0..<snapPoints.count {
        let offset = computeSnapOffset(snapPoint: snapPoints[i], columnWidth: columnWidth, workingAreaWidth: workingAreaWidth)
        if currentOffset > offset {
            return (i, offset)
        }
    }
    // All milestones reached — use the rightmost
    let last = snapPoints.count - 1
    return (last, computeSnapOffset(snapPoint: snapPoints[last], columnWidth: columnWidth, workingAreaWidth: workingAreaWidth))
}

/// Find the next snap milestone the window hasn't reached, moving leftward on screen.
/// Used by navigateRight: window slides left → snap to first unreached milestone going left.
/// Returns (index, offset) of the target snap point.
public func nextSnapMilestoneLeft(
    currentOffset: Double,
    snapPoints: [SnapPoint],
    columnWidth: Double,
    workingAreaWidth: Double
) -> (index: Int, offset: Double) {
    // Iterate right→left (index n→0). First snap whose offset > currentOffset is unreached.
    for i in (0..<snapPoints.count).reversed() {
        let offset = computeSnapOffset(snapPoint: snapPoints[i], columnWidth: columnWidth, workingAreaWidth: workingAreaWidth)
        if currentOffset < offset {
            return (i, offset)
        }
    }
    // All milestones reached — use the leftmost
    return (0, computeSnapOffset(snapPoint: snapPoints[0], columnWidth: columnWidth, workingAreaWidth: workingAreaWidth))
}

/// Find the column index at a given strip-space X coordinate.
/// If X falls in a gap, returns the nearest column. Clamps to valid range.
public func columnIndexAtStripX(
    _ stripX: Double,
    columnWidths: [Double],
    gap: Double
) -> Int {
    guard !columnWidths.isEmpty else { return 0 }

    var x: Double = 0
    for i in 0..<columnWidths.count {
        let colEnd = x + columnWidths[i]
        if stripX < colEnd {
            return i  // inside this column
        }
        let gapEnd = colEnd + gap
        if stripX < gapEnd {
            // In the gap — pick the closer column
            let distLeft = stripX - colEnd
            let distRight = gapEnd - stripX
            return distLeft < distRight ? i : min(i + 1, columnWidths.count - 1)
        }
        x = gapEnd
    }
    // Past the end
    return columnWidths.count - 1
}

/// Overload that reads widths directly from ColumnData to avoid allocating a temporary array.
public func columnIndexAtStripX(
    _ stripX: Double,
    columnData: [ColumnData],
    gap: Double
) -> Int {
    guard !columnData.isEmpty else { return 0 }

    var x: Double = 0
    for i in 0..<columnData.count {
        let colEnd = x + columnData[i].currentWidth
        if stripX < colEnd {
            return i
        }
        let gapEnd = colEnd + gap
        if stripX < gapEnd {
            let distLeft = stripX - colEnd
            let distRight = gapEnd - stripX
            return distLeft < distRight ? i : min(i + 1, columnData.count - 1)
        }
        x = gapEnd
    }
    return columnData.count - 1
}

/// Compute the X position of a column in strip-space.
public func computeColumnX(
    at index: Int,
    columnData: [ColumnData],
    gap: Double
) -> Double {
    var x: Double = 0
    for i in 0..<index {
        x += columnData[i].currentWidth + gap
    }
    return x
}
