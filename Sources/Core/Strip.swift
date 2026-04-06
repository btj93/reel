import Foundation
import CoreGraphics

/// The horizontal strip: the central data model for Reel.
/// Contains an ordered array of columns on an infinite horizontal strip,
/// with a scroll state machine controlling the viewport.
public struct Strip: Sendable {
    /// Ordered columns, left to right.
    public var columns: [Column]

    /// Parallel cached layout data (kept in sync with `columns`).
    public var columnData: [ColumnData]

    /// Index of the focused column.
    public var activeColumnIndex: Int

    /// Scroll position state machine.
    public var viewOffset: ViewOffset

    /// Configured snap points, sorted spatially (default: [.middle]).
    public var snapPoints: [SnapPoint]

    /// Per-column snap index into `snapPoints`. Parallel to `columns`.
    public var snapIndices: [Int]

    /// Gap between columns in logical points.
    public var gap: Double

    /// Usable screen area (excluding menu bar, dock, struts).
    public var workingArea: CGRect

    /// Column width presets for cycling.
    public var widthPresets: [ColumnWidth]

    /// Default width for new columns.
    public var defaultWidth: ColumnWidth

    public init(
        columns: [Column] = [],
        columnData: [ColumnData] = [],
        activeColumnIndex: Int = 0,
        viewOffset: ViewOffset = .static(0),
        snapPoints: [SnapPoint] = [.middle],
        snapIndices: [Int] = [],
        gap: Double = 16,
        workingArea: CGRect = .zero,
        widthPresets: [ColumnWidth] = [.proportion(0.33), .proportion(0.5), .proportion(0.67)],
        defaultWidth: ColumnWidth = .proportion(0.5)
    ) {
        self.columns = columns
        self.columnData = columnData
        self.activeColumnIndex = activeColumnIndex
        self.viewOffset = viewOffset
        self.snapPoints = snapPoints
        self.snapIndices = snapIndices
        self.gap = gap
        self.workingArea = workingArea
        self.widthPresets = widthPresets
        self.defaultWidth = defaultWidth
    }

    // MARK: - Computed Properties

    /// The default snap index for new columns — `.middle` or closest to center.
    public var defaultSnapIndex: Int {
        if let idx = snapPoints.firstIndex(of: .middle) { return idx }
        return (snapPoints.count - 1) / 2
    }

    /// Total width of the strip (all columns + gaps).
    public func totalWidth(at time: Double) -> Double {
        guard !columnData.isEmpty else { return 0 }
        var w: Double = 0
        for data in columnData {
            w += data.currentWidth(at: time)
        }
        w += Double(max(0, columnData.count - 1)) * gap
        return w
    }

    /// The currently focused column, if any.
    public var activeColumn: Column? {
        guard activeColumnIndex >= 0, activeColumnIndex < columns.count else { return nil }
        return columns[activeColumnIndex]
    }

    /// The X position of a column in strip-space.
    public func columnX(at index: Int, time: Double = 0) -> Double {
        computeColumnX(at: index, columnData: columnData, gap: gap, time: time)
    }

    /// The view position (left edge of the viewport in strip-space).
    public func viewPos(at time: Double) -> Double {
        columnX(at: activeColumnIndex, time: time) + viewOffset.current(at: time)
    }

    // MARK: - Column Mutations

    /// Add a new column to the right of the active column.
    public mutating func insertColumn(_ column: Column, at time: Double) {
        let insertIndex = min(activeColumnIndex + 1, columns.count)
        insertColumn(column, at: time, atIndex: insertIndex)
    }

    /// Insert a column at a specific index (clamped to valid range).
    /// Used by position memory to restore windows to saved positions.
    public mutating func insertColumn(_ column: Column, at time: Double, atIndex requestedIndex: Int) {
        let insertIndex = max(0, min(requestedIndex, columns.count))
        let resolvedWidth = column.isFullWidth
            ? workingArea.width
            : column.width.resolve(workingAreaWidth: workingArea.width, gap: gap)

        columns.insert(column, at: insertIndex)
        columnData.insert(ColumnData(cachedWidth: resolvedWidth), at: insertIndex)
        snapIndices.insert(defaultSnapIndex, at: insertIndex)

        activeColumnIndex = insertIndex

        let snapPoint = snapPoints[snapIndices[activeColumnIndex]]
        let newOffset = computeSnapOffset(
            snapPoint: snapPoint,
            columnWidth: columnData[activeColumnIndex].currentWidth(at: time),
            workingAreaWidth: workingArea.width
        )
        viewOffset = .static(newOffset)
    }

    /// Remove a column at the given index.
    public mutating func removeColumn(at index: Int, at time: Double) {
        guard index >= 0, index < columns.count else { return }

        let removedWidth = columnData[index].currentWidth(at: time) + gap

        columns.remove(at: index)
        columnData.remove(at: index)
        snapIndices.remove(at: index)

        guard !columns.isEmpty else {
            activeColumnIndex = 0
            viewOffset = .static(0)
            return
        }

        // Adjust active column index
        if index < activeColumnIndex {
            activeColumnIndex -= 1
            // Compensate view offset for the removed width
            viewOffset.shiftBy(-removedWidth)
        } else if index == activeColumnIndex {
            if index < columns.count {
                // Prefer the right neighbor (now at same index after removal)
                activeColumnIndex = index
            } else {
                // No right neighbor; use left neighbor
                activeColumnIndex = columns.count - 1
            }
        }

        // Recompute view offset
        let snapPoint = snapPoints[snapIndices[activeColumnIndex]]
        let newOffset = computeSnapOffset(
            snapPoint: snapPoint,
            columnWidth: columnData[activeColumnIndex].currentWidth(at: time),
            workingAreaWidth: workingArea.width
        )
        viewOffset = .static(newOffset)
    }

    // MARK: - Recenter

    /// Recenter the viewport on the active column (e.g., after a resize changes column widths).
    public mutating func recenterActiveColumn(at time: Double) {
        guard !columns.isEmpty else { return }
        let snapPoint = snapPoints[snapIndices[activeColumnIndex]]
        let targetOffset = computeSnapOffset(
            snapPoint: snapPoint,
            columnWidth: columnData[activeColumnIndex].currentWidth(at: time),
            workingAreaWidth: workingArea.width
        )
        viewOffset = .static(targetOffset)
    }

    /// Recenter the viewport on the active column with spring animation.
    /// Pass `columnWidth` to override the current width (e.g., target width during animation).
    public mutating func recenterActiveColumnAnimated(at time: Double, columnWidth: Double? = nil) -> SpringAnimation? {
        guard !columns.isEmpty else { return nil }
        let snapPoint = snapPoints[snapIndices[activeColumnIndex]]
        let width = columnWidth ?? columnData[activeColumnIndex].currentWidth(at: time)
        let targetOffset = computeSnapOffset(
            snapPoint: snapPoint,
            columnWidth: width,
            workingAreaWidth: workingArea.width
        )
        return createScrollAnimation(to: targetOffset, at: time)
    }

    /// Create a rubber-band bounce at the strip edge.
    /// Overshoots by ~40px in the given direction, then springs back to current position.
    /// direction: -1 for left edge, +1 for right edge.
    private mutating func createRubberBandAnimation(direction: Double, at time: Double) -> SpringAnimation {
        let currentPos = viewOffset.current(at: time)
        let overshoot = 40.0 * direction  // how far to stretch past the edge

        // Use underdamped spring (ratio < 1) for a visible bounce-back
        let bounceParams = SpringParams(dampingRatio: 0.6, stiffness: 600, epsilon: 0.5)

        // Animate: current → overshoot position, but target is current (so it bounces back)
        // We achieve this by starting with an initial velocity that carries past the target
        let anim = SpringAnimation(
            from: currentPos,
            to: currentPos,                     // return to same position
            initialVelocity: overshoot * 15,    // kick velocity to overshoot
            startTime: time,
            params: bounceParams
        )

        viewOffset = .animation(anim)
        return anim
    }

    /// Create a spring animation from the current view offset state to a target,
    /// preserving velocity if already animating (for rapid keypress compounding).
    /// Returns nil if already at the target (no animation needed).
    private mutating func createScrollAnimation(to targetOffset: Double, at time: Double) -> SpringAnimation? {
        let currentPos = viewOffset.current(at: time)

        // Skip if already at target (prevents spring-back at boundaries)
        if abs(currentPos - targetOffset) < 1.0 {
            viewOffset = .static(targetOffset)
            return nil
        }

        // Preserve velocity from in-flight animation (rapid keypresses compound)
        let currentVel: Double
        if case .animation(let existing) = viewOffset {
            currentVel = existing.evaluate(at: time).velocity
        } else {
            currentVel = 0
        }

        let anim = SpringAnimation(
            from: currentPos,
            to: targetOffset,
            initialVelocity: currentVel,
            startTime: time,
            params: .horizontalScroll
        )

        viewOffset = .animation(anim)
        return anim
    }

    /// Create a scroll animation from an explicit start position (used after focus changes
    /// where activeColumnIndex has shifted, making viewOffset.current stale).
    private mutating func createFocusChangeAnimation(from startOffset: Double, to targetOffset: Double, at time: Double) -> SpringAnimation? {
        if abs(startOffset - targetOffset) < 1.0 {
            viewOffset = .static(targetOffset)
            return nil
        }

        let anim = SpringAnimation(
            from: startOffset,
            to: targetOffset,
            initialVelocity: 0,
            startTime: time,
            params: .horizontalScroll
        )

        viewOffset = .animation(anim)
        return anim
    }

    // MARK: - Snap Navigation

    /// Navigate right: advance snap point on current column, or move focus right if exhausted.
    /// Returns a SpringAnimation if animated, nil if no movement needed.
    @discardableResult
    public mutating func navigateRight(at time: Double) -> SpringAnimation? {
        guard !columns.isEmpty else { return nil }
        let currentSnap = snapIndices[activeColumnIndex]

        if currentSnap > 0 {
            // Decrement snap point (window slides left on screen, revealing right)
            snapIndices[activeColumnIndex] -= 1
            let colWidth = columnData[activeColumnIndex].currentWidth(at: time)
            let targetOffset = computeSnapOffset(
                snapPoint: snapPoints[snapIndices[activeColumnIndex]],
                columnWidth: colWidth,
                workingAreaWidth: workingArea.width
            )
            return createScrollAnimation(to: targetOffset, at: time)
        } else if activeColumnIndex < columns.count - 1 {
            // Exhausted snap points — move focus to next column
            // navigateRight → window slides left → next leftward milestone
            let currentOffset = viewOffset.current(at: time)
            let oldColX = columnX(at: activeColumnIndex, time: time)
            activeColumnIndex += 1
            let newColX = columnX(at: activeColumnIndex, time: time)
            let adjustedOffset = currentOffset + oldColX - newColX
            let newColWidth = columnData[activeColumnIndex].currentWidth(at: time)
            let (snapIdx, targetOffset) = nextSnapMilestoneLeft(
                currentOffset: adjustedOffset,
                snapPoints: snapPoints,
                columnWidth: newColWidth,
                workingAreaWidth: workingArea.width
            )
            snapIndices[activeColumnIndex] = snapIdx
            return createFocusChangeAnimation(from: adjustedOffset, to: targetOffset, at: time)
        } else {
            // At rightmost column + leftmost snap — rubber-band bounce
            return createRubberBandAnimation(direction: 1, at: time)
        }
    }

    /// Navigate left: increment snap point on current column (window slides right), or move focus left if exhausted.
    @discardableResult
    public mutating func navigateLeft(at time: Double) -> SpringAnimation? {
        guard !columns.isEmpty else { return nil }
        let currentSnap = snapIndices[activeColumnIndex]

        if currentSnap < snapPoints.count - 1 {
            // Increment snap point (window slides right on screen, revealing left)
            snapIndices[activeColumnIndex] += 1
            let colWidth = columnData[activeColumnIndex].currentWidth(at: time)
            let targetOffset = computeSnapOffset(
                snapPoint: snapPoints[snapIndices[activeColumnIndex]],
                columnWidth: colWidth,
                workingAreaWidth: workingArea.width
            )
            return createScrollAnimation(to: targetOffset, at: time)
        } else if activeColumnIndex > 0 {
            // Exhausted snap points — move focus to previous column
            // navigateLeft → window slides right → next rightward milestone
            let currentOffset = viewOffset.current(at: time)
            let oldColX = columnX(at: activeColumnIndex, time: time)
            activeColumnIndex -= 1
            let newColX = columnX(at: activeColumnIndex, time: time)
            let adjustedOffset = currentOffset + oldColX - newColX
            let newColWidth = columnData[activeColumnIndex].currentWidth(at: time)
            let (snapIdx, targetOffset) = nextSnapMilestoneRight(
                currentOffset: adjustedOffset,
                snapPoints: snapPoints,
                columnWidth: newColWidth,
                workingAreaWidth: workingArea.width
            )
            snapIndices[activeColumnIndex] = snapIdx
            return createFocusChangeAnimation(from: adjustedOffset, to: targetOffset, at: time)
        } else {
            // At leftmost column + rightmost snap — rubber-band bounce
            return createRubberBandAnimation(direction: -1, at: time)
        }
    }

    /// Navigate right without animation (instant mode).
    public mutating func navigateRightInstant(at time: Double) {
        guard !columns.isEmpty else { return }
        let currentSnap = snapIndices[activeColumnIndex]

        if currentSnap > 0 {
            snapIndices[activeColumnIndex] -= 1
        } else if activeColumnIndex < columns.count - 1 {
            let currentOffset = viewOffset.current(at: time)
            let oldColX = columnX(at: activeColumnIndex, time: time)
            activeColumnIndex += 1
            let newColX = columnX(at: activeColumnIndex, time: time)
            let adjustedOffset = currentOffset + oldColX - newColX
            let newColWidth = columnData[activeColumnIndex].currentWidth(at: time)
            let (snapIdx, offset) = nextSnapMilestoneLeft(
                currentOffset: adjustedOffset,
                snapPoints: snapPoints,
                columnWidth: newColWidth,
                workingAreaWidth: workingArea.width
            )
            snapIndices[activeColumnIndex] = snapIdx
            viewOffset = .static(offset)
            return
        } else {
            return
        }

        let colWidth = columnData[activeColumnIndex].currentWidth(at: time)
        let targetOffset = computeSnapOffset(
            snapPoint: snapPoints[snapIndices[activeColumnIndex]],
            columnWidth: colWidth,
            workingAreaWidth: workingArea.width
        )
        viewOffset = .static(targetOffset)
    }

    /// Navigate left without animation (instant mode).
    public mutating func navigateLeftInstant(at time: Double) {
        guard !columns.isEmpty else { return }
        let currentSnap = snapIndices[activeColumnIndex]

        if currentSnap < snapPoints.count - 1 {
            snapIndices[activeColumnIndex] += 1
        } else if activeColumnIndex > 0 {
            let currentOffset = viewOffset.current(at: time)
            let oldColX = columnX(at: activeColumnIndex, time: time)
            activeColumnIndex -= 1
            let newColX = columnX(at: activeColumnIndex, time: time)
            let adjustedOffset = currentOffset + oldColX - newColX
            let newColWidth = columnData[activeColumnIndex].currentWidth(at: time)
            let (snapIdx, offset) = nextSnapMilestoneRight(
                currentOffset: adjustedOffset,
                snapPoints: snapPoints,
                columnWidth: newColWidth,
                workingAreaWidth: workingArea.width
            )
            snapIndices[activeColumnIndex] = snapIdx
            viewOffset = .static(offset)
            return
        } else {
            return
        }

        let colWidth = columnData[activeColumnIndex].currentWidth(at: time)
        let targetOffset = computeSnapOffset(
            snapPoint: snapPoints[snapIndices[activeColumnIndex]],
            columnWidth: colWidth,
            workingAreaWidth: workingArea.width
        )
        viewOffset = .static(targetOffset)
    }

    /// Move the active column left (swap with neighbor).
    public mutating func moveColumnLeft(at time: Double) {
        guard activeColumnIndex > 0 else { return }
        let i = activeColumnIndex
        columns.swapAt(i, i - 1)
        columnData.swapAt(i, i - 1)
        snapIndices.swapAt(i, i - 1)
        activeColumnIndex -= 1
    }

    /// Move the active column right (swap with neighbor).
    public mutating func moveColumnRight(at time: Double) {
        guard activeColumnIndex < columns.count - 1 else { return }
        let i = activeColumnIndex
        columns.swapAt(i, i + 1)
        columnData.swapAt(i, i + 1)
        snapIndices.swapAt(i, i + 1)
        activeColumnIndex += 1
    }

    /// Move a column from one index to another (for drag-to-reorder).
    /// Uses remove/insert to handle arbitrary distances.
    /// Updates activeColumnIndex to track the moved column.
    /// Caller must call recenterActiveColumnAnimated(at:) after to fix viewOffset.
    public mutating func moveColumn(from sourceIndex: Int, to destIndex: Int, at time: Double) {
        guard sourceIndex != destIndex,
              sourceIndex >= 0, sourceIndex < columns.count,
              destIndex >= 0, destIndex < columns.count else { return }

        let col = columns.remove(at: sourceIndex)
        let data = columnData.remove(at: sourceIndex)
        let snap = snapIndices.remove(at: sourceIndex)

        columns.insert(col, at: destIndex)
        columnData.insert(data, at: destIndex)
        snapIndices.insert(snap, at: destIndex)

        if activeColumnIndex == sourceIndex {
            activeColumnIndex = destIndex
        } else if sourceIndex < destIndex {
            if activeColumnIndex > sourceIndex && activeColumnIndex <= destIndex {
                activeColumnIndex -= 1
            }
        } else {
            if activeColumnIndex >= destIndex && activeColumnIndex < sourceIndex {
                activeColumnIndex += 1
            }
        }
    }

    // MARK: - Width Management

    /// Cycle the active column's width through presets.
    /// Pass `params` for animated transition, or `nil` for instant.
    public mutating func cycleWidthPreset(at time: Double, params: SpringParams?) {
        guard !columns.isEmpty, !widthPresets.isEmpty else { return }
        let i = activeColumnIndex
        let nextPresetIndex = ((columns[i].presetIndex ?? -1) + 1) % widthPresets.count
        let newWidth = widthPresets[nextPresetIndex]
            .resolve(workingAreaWidth: workingArea.width, gap: gap)

        columns[i].width = widthPresets[nextPresetIndex]
        columns[i].presetIndex = nextPresetIndex
        columns[i].isFullWidth = false

        if let params = params {
            let oldWidth = columnData[i].currentWidth(at: time)
            if let existing = columnData[i].widthAnimation, !existing.isDone(at: time) {
                // Rapid cycling — retarget preserving velocity
                columnData[i].widthAnimation = existing.retargeted(to: newWidth, at: time)
            } else {
                columnData[i].widthAnimation = SpringAnimation(
                    from: oldWidth, to: newWidth, startTime: time, params: params
                )
            }
        } else {
            columnData[i].widthAnimation = nil
        }
        columnData[i].cachedWidth = newWidth
    }

    /// Toggle the active column to/from full-width mode.
    public mutating func toggleFullWidth() {
        guard !columns.isEmpty else { return }
        columnData[activeColumnIndex].widthAnimation = nil
        let isCurrentlyFull = columns[activeColumnIndex].isFullWidth
        columns[activeColumnIndex].isFullWidth = !isCurrentlyFull
        if !isCurrentlyFull {
            columnData[activeColumnIndex].cachedWidth = workingArea.width
        } else {
            let width = columns[activeColumnIndex].width
            columnData[activeColumnIndex].cachedWidth = width.resolve(
                workingAreaWidth: workingArea.width, gap: gap
            )
        }
    }

    /// Recalculate all column widths (e.g., after working area changes).
    public mutating func recalculateWidths() {
        for i in 0..<columns.count {
            columnData[i].widthAnimation = nil
            if columns[i].isFullWidth {
                columnData[i].cachedWidth = workingArea.width
            } else {
                columnData[i].cachedWidth = columns[i].width.resolve(
                    workingAreaWidth: workingArea.width, gap: gap
                )
            }
        }
    }

    /// Finalize completed width animations and return whether any active animations remain.
    @discardableResult
    public mutating func settleWidthAnimations(at time: Double) -> Bool {
        var anyActive = false
        for i in 0..<columnData.count {
            if let anim = columnData[i].widthAnimation {
                if anim.isDone(at: time) {
                    columnData[i].widthAnimation = nil
                } else {
                    anyActive = true
                }
            }
        }
        return anyActive
    }
}
