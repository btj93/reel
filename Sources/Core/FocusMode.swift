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
