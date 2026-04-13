import CoreGraphics

/// Compute the insertion index in original column-index space from cursor X position.
/// - `cursorX`: cursor X position relative to the thumbnail row
/// - `thumbnailMidpoints`: ascending X dividers, one per non-dragged thumbnail, used to
///   assign the cursor to one of N+1 gap positions. With N thumbnails we need N dividers
///   (typically the thumbnail centers) so every gap — including between adjacent
///   thumbnails — is reachable.
/// - `nonDraggedOriginalIndices`: the original column indices of the non-dragged thumbnails, in order
/// - `draggedIndex`: the original index of the dragged column
/// - `columnCount`: total number of columns
/// Returns a value in [0, columnCount].
public func computeReorderInsertionIndex(
    cursorX: Double,
    thumbnailMidpoints: [Double],
    nonDraggedOriginalIndices: [Int],
    draggedIndex: Int,
    columnCount: Int
) -> Int {
    // Find position among non-dragged thumbnails
    var thumbnailIndex = nonDraggedOriginalIndices.count
    for (i, midX) in thumbnailMidpoints.enumerated() {
        if cursorX < midX {
            thumbnailIndex = i
            break
        }
    }

    // Map back to original column index space
    var originalIndex = 0
    var nonDraggedSeen = 0
    for i in 0...columnCount {
        if nonDraggedSeen == thumbnailIndex {
            originalIndex = i
            break
        }
        if i < columnCount && i != draggedIndex {
            nonDraggedSeen += 1
        }
    }

    return min(max(originalIndex, 0), columnCount)
}
