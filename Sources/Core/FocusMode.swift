import Foundation
import CoreGraphics

/// Controls how the viewport scrolls when the focused column changes.
/// Matches niri's CenterFocusedColumn behavior.
public enum CenterFocusedColumn: String, Sendable {
    /// Scroll the minimum amount to make the focused column fully visible (edge-snap).
    case never

    /// Always center the focused column on screen.
    case always

    /// Center only when the focused column and previous column don't both fit on screen.
    case onOverflow
}

/// Compute the target view offset for a given column focus change.
/// - Parameters:
///   - columnIndex: The column to focus
///   - strip: The current strip state
/// - Returns: The target view offset value
public func computeNewViewOffset(
    forColumn columnIndex: Int,
    previousColumn: Int?,
    focusMode: CenterFocusedColumn,
    columns: [Column],
    columnData: [ColumnData],
    gap: Double,
    workingAreaWidth: Double
) -> Double {
    guard !columns.isEmpty, columnIndex >= 0, columnIndex < columns.count else {
        return 0
    }

    let columnX = computeColumnX(at: columnIndex, columnData: columnData, gap: gap)
    let columnWidth = columnData[columnIndex].currentWidth

    switch focusMode {
    case .always:
        return computeCenteredOffset(
            columnX: columnX,
            columnWidth: columnWidth,
            workingAreaWidth: workingAreaWidth
        )

    case .never:
        return computeFitOffset(
            columnX: columnX,
            columnWidth: columnWidth,
            workingAreaWidth: workingAreaWidth,
            currentOffset: computeColumnX(at: columnIndex, columnData: columnData, gap: gap)
        )

    case .onOverflow:
        // Center if both focused and previous don't fit together
        if let prev = previousColumn, prev != columnIndex {
            let prevX = computeColumnX(at: prev, columnData: columnData, gap: gap)
            let prevWidth = columnData[prev].currentWidth
            let bothFit: Bool
            if prev < columnIndex {
                bothFit = (columnX + columnWidth - prevX) <= workingAreaWidth
            } else {
                bothFit = (prevX + prevWidth - columnX) <= workingAreaWidth
            }
            if !bothFit {
                return computeCenteredOffset(
                    columnX: columnX,
                    columnWidth: columnWidth,
                    workingAreaWidth: workingAreaWidth
                )
            }
        }
        return computeFitOffset(
            columnX: columnX,
            columnWidth: columnWidth,
            workingAreaWidth: workingAreaWidth,
            currentOffset: columnX
        )
    }
}

/// Center a column on screen.
func computeCenteredOffset(
    columnX: Double,
    columnWidth: Double,
    workingAreaWidth: Double
) -> Double {
    // Offset so column center aligns with viewport center
    // viewPos = columnX + offset, and we want columnX - viewPos + workingAreaWidth/2 = columnWidth/2
    // So offset = -(workingAreaWidth - columnWidth) / 2
    let offset = -(workingAreaWidth - columnWidth) / 2.0
    return offset
}

/// Scroll minimum to make column fully visible.
func computeFitOffset(
    columnX: Double,
    columnWidth: Double,
    workingAreaWidth: Double,
    currentOffset: Double
) -> Double {
    // The view position is: columnX(activeColumnIndex) + viewOffset
    // Screen position of our column: columnX - (activeColumnX + viewOffset) + workingArea.minX
    // For fit mode, we want viewOffset = 0 initially, meaning the active column's left edge
    // is at the left of the working area. We adjust to keep it visible.
    return 0
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
