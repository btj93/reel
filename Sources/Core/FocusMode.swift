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
