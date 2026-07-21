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

    /// The group's working area — per-region geometry + coordinate anchor.
    /// For solo-display groups this is a singleton region; multi-region groups
    /// back the shared-strip feature for aligned displays.
    public var groupArea: GroupWorkingArea

    /// Backward-compatible read-only alias: the bounding rect of all regions.
    /// GET-ONLY. Writes must go through `groupArea = …` or, in `StripController`,
    /// through `updateGroupArea(_:)`. A setter here would silently collapse
    /// multi-region groups to a singleton on every write, which is unsafe.
    public var workingArea: CGRect { groupArea.totalSpan }

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
        self.groupArea = GroupWorkingArea(
            regions: [DisplayRegion(displayID: 0, rect: workingArea)],
            referenceMidX: workingArea.midX
        )
        self.widthPresets = widthPresets
        self.defaultWidth = defaultWidth
    }

    /// Primary init for shared-strip callers.
    public init(
        columns: [Column] = [],
        columnData: [ColumnData] = [],
        activeColumnIndex: Int = 0,
        viewOffset: ViewOffset = .static(0),
        snapPoints: [SnapPoint] = [.middle],
        snapIndices: [Int] = [],
        gap: Double = 16,
        groupArea: GroupWorkingArea,
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
        self.groupArea = groupArea
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

    /// Valid viewOffset range that keeps edge columns fully visible:
    /// - Left bound: first column's right edge aligns with viewport's right edge
    /// - Right bound: last column's left edge aligns with viewport's left edge
    public func viewOffsetBounds(at time: Double) -> ClosedRange<Double> {
        guard !columnData.isEmpty else { return 0...0 }
        let activeX = columnX(at: activeColumnIndex, time: time)
        let screenWidth = workingArea.width
        let firstColWidth = columnData[0].currentWidth(at: time)
        let lastColX = columnX(at: columnData.count - 1, time: time)

        let minOffset = (firstColWidth - screenWidth) - activeX
        let maxBound = lastColX - activeX
        let maxOffset = max(minOffset, maxBound)
        return minOffset...maxOffset
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

        // Determine owning region for the insertion point.
        var cumX: Double = 0
        for j in 0..<insertIndex {
            cumX += columnData[j].cachedWidth + gap
        }
        let trialWidth: Double
        if column.isFullWidth {
            trialWidth = Double(groupArea.firstRegionRect.width)
        } else {
            trialWidth = column.width.resolve(
                workingAreaWidth: Double(groupArea.firstRegionRect.width),
                gap: gap
            )
        }
        let trialMidXInStrip = cumX + trialWidth / 2
        let viewPosNow = viewPos(at: time)
        let trialMidXOnScreen = trialMidXInStrip - viewPosNow + Double(groupArea.totalSpan.minX)
        let owningRegion = groupArea.regions.first(where: {
            trialMidXOnScreen >= Double($0.rect.minX) && trialMidXOnScreen <= Double($0.rect.maxX)
        }) ?? groupArea.regions[0]

        let resolvedWidth = column.isFullWidth
            ? Double(owningRegion.rect.width)
            : column.width.resolve(workingAreaWidth: Double(owningRegion.rect.width), gap: gap)

        columns.insert(column, at: insertIndex)
        columnData.insert(ColumnData(cachedWidth: resolvedWidth), at: insertIndex)
        snapIndices.insert(defaultSnapIndex, at: insertIndex)

        activeColumnIndex = insertIndex

        viewOffset = .static(snapTargetForActive(at: time))
    }

    /// Remove a column at the given index.
    public mutating func removeColumn(at index: Int, at time: Double) {
        guard index >= 0, index < columns.count else { return }

        columns.remove(at: index)
        columnData.remove(at: index)
        snapIndices.remove(at: index)

        guard !columns.isEmpty else {
            activeColumnIndex = 0
            viewOffset = .static(0)
            return
        }

        // Adjust active column index and view offset based on removal position
        if index < activeColumnIndex {
            // viewPos = columnX(active) + viewOffset, and columnX(active) is
            // recomputed from the (now shorter) columnData — it has already
            // shifted left by removedWidth. Leaving viewOffset alone preserves
            // the visual position of the active column on screen.
            activeColumnIndex -= 1
        } else if index == activeColumnIndex {
            if index < columns.count {
                // Prefer the right neighbor (now at same index after removal)
                activeColumnIndex = index
            } else {
                // No right neighbor; use left neighbor
                activeColumnIndex = columns.count - 1
            }
            // Recenter on the new active column
            viewOffset = .static(snapTargetForActive(at: time))
        }
        // index > activeColumnIndex: active column unchanged, no viewOffset adjustment needed
    }

    // MARK: - Recenter

    /// Recenter the viewport on the active column (e.g., after a resize changes column widths).
    public mutating func recenterActiveColumn(at time: Double) {
        guard !columns.isEmpty else { return }
        viewOffset = .static(snapTargetForActive(at: time))
    }

    /// Recenter the viewport on the active column with spring animation.
    /// Pass `columnWidth` to override the current width (e.g., target width during animation).
    public mutating func recenterActiveColumnAnimated(at time: Double, columnWidth: Double? = nil) -> SpringAnimation? {
        guard !columns.isEmpty else { return nil }
        let targetOffset = snapTarget(
            forColumn: activeColumnIndex,
            columnWidthOverride: columnWidth,
            at: time
        )
        return createScrollAnimation(to: targetOffset, at: time)
    }

    /// Create a rubber-band bounce at the strip edge.
    /// Overshoots by ~40px in the given direction, then springs back to current position.
    /// direction: -1 for left edge, +1 for right edge.
    @discardableResult
    public mutating func createRubberBandAnimation(direction: Double, kickVelocity: Double? = nil, at time: Double) -> SpringAnimation {
        let currentPos = viewOffset.current(at: time)
        let overshoot = 40.0 * direction  // how far to stretch past the edge

        // Use underdamped spring (ratio < 1) for a visible bounce-back
        let bounceParams = SpringParams(dampingRatio: 0.6, stiffness: 600, epsilon: 0.5)

        // Animate: current → overshoot position, but target is the canonical snap (so it
        // bounces back to the right place even if currentPos has drifted off the snap from
        // an earlier interrupted animation — rapid keypresses at the boundary used to lock
        // in the mid-bounce value because `to` was just `currentPos`).
        let velocity = kickVelocity ?? overshoot * 15
        let anim = SpringAnimation(
            from: currentPos,
            to: snapTargetForActive(at: time),
            initialVelocity: velocity,          // kick velocity to overshoot
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

    /// Create a spring animation with explicit velocity (trackpad path).
    /// Does NOT compound with in-flight animation velocity.
    private mutating func createVelocityAnimation(
        from startOffset: Double? = nil,
        to targetOffset: Double,
        velocity: Double,
        at time: Double
    ) -> SpringAnimation? {
        let fromPos = startOffset ?? viewOffset.current(at: time)
        if abs(fromPos - targetOffset) < 1.0 {
            viewOffset = .static(targetOffset)
            return nil
        }

        let anim = SpringAnimation(
            from: fromPos,
            to: targetOffset,
            initialVelocity: velocity,
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

    // MARK: - Mouse-Driven Focus (Incremental Snap)

    /// Result of `focusColumnIncremental`.
    public enum IncrementalFocusResult: Equatable, Sendable {
        /// Invalid column index — no mutation performed.
        case noChange
        /// Clicked column is already fully visible; viewOffset re-anchored to it (no scroll).
        case anchorOnly
        /// Instant scroll applied; `to` is the new static viewOffset.
        case scrolledInstant(to: Double)
        /// Animated scroll started; spring goes `from` → `to`.
        case scrolledAnimated(from: Double, to: Double)
    }

    /// Change `activeColumnIndex` to `colIndex` and scroll only if the column isn't
    /// fully visible. Direction of travel decides which snap milestone we land on
    /// (first unreached snap in that direction, same helpers as keyboard nav).
    /// - Parameter animated: If true, sets `viewOffset = .animation(...)`; else `.static(...)`.
    @discardableResult
    public mutating func focusColumnIncremental(
        colIndex: Int,
        at time: Double,
        animated: Bool
    ) -> IncrementalFocusResult {
        guard colIndex >= 0, colIndex < columns.count else { return .noChange }

        let oldActive = activeColumnIndex
        let oldColX = columnX(at: oldActive, time: time)
        let newColX = columnX(at: colIndex, time: time)
        let currentOffset = viewOffset.current(at: time)
        let newColWidth = columnData[colIndex].currentWidth(at: time)

        // Current on-screen position of the clicked column's left edge.
        // viewPos = oldColX + currentOffset gives viewport left edge in strip-space.
        let viewportLeft = oldColX + currentOffset
        let colLeftOnScreen = newColX - viewportLeft
        let colRightOnScreen = colLeftOnScreen + newColWidth

        // Re-anchor viewOffset to the new active column (preserves visual position).
        let adjustedOffset = currentOffset + oldColX - newColX
        activeColumnIndex = colIndex

        // Fully visible? Column must fit entirely within at least one region.
        let eps: Double = 0.5
        let screenLeft = colLeftOnScreen + Double(workingArea.minX)
        let screenRight = colRightOnScreen + Double(workingArea.minX)
        var fullyContained = false
        for r in groupArea.regions {
            if screenLeft >= Double(r.rect.minX) - eps && screenRight <= Double(r.rect.maxX) + eps {
                fullyContained = true
                break
            }
        }
        if fullyContained {
            viewOffset = .static(adjustedOffset)
            return .anchorOnly
        }

        // Determine the owning region for the target column at the adjusted offset.
        // Cached-width basis (see `regionForColumn(_:at:)`): the passed `viewPos`
        // must match the cached-width `midXInStrip` walk inside the private overload,
        // otherwise an in-flight width animation left of `colIndex` selects the wrong
        // region. `newColX` (animated) would reintroduce the mixed-basis defect.
        let viewPosAtAdjusted = cachedColumnX(at: colIndex) + adjustedOffset
        let colRegion = regionForColumn(colIndex, viewPos: viewPosAtAdjusted)
        let colRegionWidth = Double(colRegion.rect.width)

        // Pick direction of travel & find first unreached milestone.
        let (snapIdx, targetOffset): (Int, Double)
        if colRightOnScreen + Double(workingArea.minX) > Double(colRegion.rect.maxX) {
            // Column extends past the right edge of its region → slide leftward on screen.
            (snapIdx, targetOffset) = nextSnapMilestoneLeft(
                currentOffset: adjustedOffset,
                snapPoints: snapPoints,
                columnWidth: newColWidth,
                workingAreaWidth: colRegionWidth
            )
        } else {
            // Column extends past the left edge of its region → slide rightward on screen.
            (snapIdx, targetOffset) = nextSnapMilestoneRight(
                currentOffset: adjustedOffset,
                snapPoints: snapPoints,
                columnWidth: newColWidth,
                workingAreaWidth: colRegionWidth
            )
        }
        snapIndices[colIndex] = snapIdx

        // If target is the same as adjusted (already on a snap line somehow), just static.
        if abs(adjustedOffset - targetOffset) < 1.0 {
            viewOffset = .static(targetOffset)
            return .scrolledInstant(to: targetOffset)
        }

        if animated {
            let anim = SpringAnimation(
                from: adjustedOffset,
                to: targetOffset,
                initialVelocity: 0,
                startTime: time,
                params: .horizontalScroll
            )
            viewOffset = .animation(anim)
            return .scrolledAnimated(from: adjustedOffset, to: targetOffset)
        } else {
            viewOffset = .static(targetOffset)
            return .scrolledInstant(to: targetOffset)
        }
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
            return createScrollAnimation(to: snapTargetForActive(at: time), at: time)
        } else if activeColumnIndex < columns.count - 1 {
            // Exhausted snap points — move focus to next column
            // navigateRight → window slides left → next leftward milestone
            let currentOffset = viewOffset.current(at: time)
            let oldColX = columnX(at: activeColumnIndex, time: time)
            activeColumnIndex += 1
            let newColX = columnX(at: activeColumnIndex, time: time)
            let adjustedOffset = currentOffset + oldColX - newColX
            let newColWidth = columnData[activeColumnIndex].currentWidth(at: time)
            let regionWidth = Double(regionForColumn(activeColumnIndex, viewPos: cachedColumnX(at: activeColumnIndex) + adjustedOffset).rect.width)
            let (snapIdx, targetOffset) = nextSnapMilestoneLeft(
                currentOffset: adjustedOffset,
                snapPoints: snapPoints,
                columnWidth: newColWidth,
                workingAreaWidth: regionWidth
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
            return createScrollAnimation(to: snapTargetForActive(at: time), at: time)
        } else if activeColumnIndex > 0 {
            // Exhausted snap points — move focus to previous column
            // navigateLeft → window slides right → next rightward milestone
            let currentOffset = viewOffset.current(at: time)
            let oldColX = columnX(at: activeColumnIndex, time: time)
            activeColumnIndex -= 1
            let newColX = columnX(at: activeColumnIndex, time: time)
            let adjustedOffset = currentOffset + oldColX - newColX
            let newColWidth = columnData[activeColumnIndex].currentWidth(at: time)
            let regionWidth = Double(regionForColumn(activeColumnIndex, viewPos: cachedColumnX(at: activeColumnIndex) + adjustedOffset).rect.width)
            let (snapIdx, targetOffset) = nextSnapMilestoneRight(
                currentOffset: adjustedOffset,
                snapPoints: snapPoints,
                columnWidth: newColWidth,
                workingAreaWidth: regionWidth
            )
            snapIndices[activeColumnIndex] = snapIdx
            return createFocusChangeAnimation(from: adjustedOffset, to: targetOffset, at: time)
        } else {
            // At leftmost column + rightmost snap — rubber-band bounce
            return createRubberBandAnimation(direction: -1, at: time)
        }
    }

    // MARK: - Velocity-Seeded Navigation (Trackpad)

    /// Navigate right with trackpad-supplied velocity.
    @discardableResult
    public mutating func navigateRight(at time: Double, velocity: Double) -> SpringAnimation? {
        guard !columns.isEmpty else { return nil }
        let currentSnap = snapIndices[activeColumnIndex]

        if currentSnap > 0 {
            snapIndices[activeColumnIndex] -= 1
            return createVelocityAnimation(to: snapTargetForActive(at: time), velocity: velocity, at: time)
        } else if activeColumnIndex < columns.count - 1 {
            let currentOffset = viewOffset.current(at: time)
            let oldColX = columnX(at: activeColumnIndex, time: time)
            activeColumnIndex += 1
            let newColX = columnX(at: activeColumnIndex, time: time)
            let adjustedOffset = currentOffset + oldColX - newColX
            let newColWidth = columnData[activeColumnIndex].currentWidth(at: time)
            let regionWidth = Double(regionForColumn(activeColumnIndex, viewPos: cachedColumnX(at: activeColumnIndex) + adjustedOffset).rect.width)
            let (snapIdx, targetOffset) = nextSnapMilestoneLeft(
                currentOffset: adjustedOffset,
                snapPoints: snapPoints,
                columnWidth: newColWidth,
                workingAreaWidth: regionWidth
            )
            snapIndices[activeColumnIndex] = snapIdx
            return createVelocityAnimation(from: adjustedOffset, to: targetOffset, velocity: velocity, at: time)
        } else {
            return createRubberBandAnimation(direction: 1, kickVelocity: abs(velocity), at: time)
        }
    }

    /// Navigate left with trackpad-supplied velocity.
    @discardableResult
    public mutating func navigateLeft(at time: Double, velocity: Double) -> SpringAnimation? {
        guard !columns.isEmpty else { return nil }
        let currentSnap = snapIndices[activeColumnIndex]

        if currentSnap < snapPoints.count - 1 {
            snapIndices[activeColumnIndex] += 1
            return createVelocityAnimation(to: snapTargetForActive(at: time), velocity: velocity, at: time)
        } else if activeColumnIndex > 0 {
            let currentOffset = viewOffset.current(at: time)
            let oldColX = columnX(at: activeColumnIndex, time: time)
            activeColumnIndex -= 1
            let newColX = columnX(at: activeColumnIndex, time: time)
            let adjustedOffset = currentOffset + oldColX - newColX
            let newColWidth = columnData[activeColumnIndex].currentWidth(at: time)
            let regionWidth = Double(regionForColumn(activeColumnIndex, viewPos: cachedColumnX(at: activeColumnIndex) + adjustedOffset).rect.width)
            let (snapIdx, targetOffset) = nextSnapMilestoneRight(
                currentOffset: adjustedOffset,
                snapPoints: snapPoints,
                columnWidth: newColWidth,
                workingAreaWidth: regionWidth
            )
            snapIndices[activeColumnIndex] = snapIdx
            return createVelocityAnimation(from: adjustedOffset, to: targetOffset, velocity: velocity, at: time)
        } else {
            return createRubberBandAnimation(direction: -1, kickVelocity: -abs(velocity), at: time)
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
            let regionWidth = Double(regionForColumn(activeColumnIndex, viewPos: cachedColumnX(at: activeColumnIndex) + adjustedOffset).rect.width)
            let (snapIdx, offset) = nextSnapMilestoneLeft(
                currentOffset: adjustedOffset,
                snapPoints: snapPoints,
                columnWidth: newColWidth,
                workingAreaWidth: regionWidth
            )
            snapIndices[activeColumnIndex] = snapIdx
            viewOffset = .static(offset)
            return
        } else {
            return
        }

        viewOffset = .static(snapTargetForActive(at: time))
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
            let regionWidth = Double(regionForColumn(activeColumnIndex, viewPos: cachedColumnX(at: activeColumnIndex) + adjustedOffset).rect.width)
            let (snapIdx, offset) = nextSnapMilestoneRight(
                currentOffset: adjustedOffset,
                snapPoints: snapPoints,
                columnWidth: newColWidth,
                workingAreaWidth: regionWidth
            )
            snapIndices[activeColumnIndex] = snapIdx
            viewOffset = .static(offset)
            return
        } else {
            return
        }

        viewOffset = .static(snapTargetForActive(at: time))
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
        let region = regionForColumn(i, at: time)
        let newWidth = widthPresets[nextPresetIndex]
            .resolve(workingAreaWidth: Double(region.rect.width), gap: gap)

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

    /// Set the active column's width to a specific preset index.
    /// Follows the same pattern as cycleWidthPreset: nils widthAnimation, sets cachedWidth.
    public mutating func setWidthPreset(index presetIndex: Int, at time: Double, params: SpringParams?) {
        guard !columns.isEmpty, presetIndex >= 0, presetIndex < widthPresets.count else { return }
        let i = activeColumnIndex
        let region = regionForColumn(i, at: time)
        let newWidth = widthPresets[presetIndex]
            .resolve(workingAreaWidth: Double(region.rect.width), gap: gap)

        columns[i].width = widthPresets[presetIndex]
        columns[i].presetIndex = presetIndex
        columns[i].isFullWidth = false

        if let params = params {
            let oldWidth = columnData[i].currentWidth(at: time)
            columnData[i].widthAnimation = SpringAnimation(
                from: oldWidth, to: newWidth, startTime: time, params: params
            )
        } else {
            columnData[i].widthAnimation = nil
        }
        columnData[i].cachedWidth = newWidth
    }

    /// Toggle the active column to/from full-width mode.
    public mutating func toggleFullWidth(at time: Double) {
        guard !columns.isEmpty else { return }
        columnData[activeColumnIndex].widthAnimation = nil
        columnData[activeColumnIndex].raiseAnimation = nil
        let isCurrentlyFull = columns[activeColumnIndex].isFullWidth
        columns[activeColumnIndex].isFullWidth = !isCurrentlyFull
        let region = regionForColumn(activeColumnIndex, at: time)
        if !isCurrentlyFull {
            columnData[activeColumnIndex].cachedWidth = Double(region.rect.width)
        } else {
            let width = columns[activeColumnIndex].width
            columnData[activeColumnIndex].cachedWidth = width.resolve(
                workingAreaWidth: Double(region.rect.width), gap: gap
            )
        }
    }

    /// Recalculate all column widths (e.g., after working area changes).
    public mutating func recalculateWidths(at time: Double) {
        for i in 0..<columns.count {
            columnData[i].widthAnimation = nil
            columnData[i].raiseAnimation = nil
            let region = regionForColumn(i, at: time)
            let regionWidth = Double(region.rect.width)
            if columns[i].isFullWidth {
                columnData[i].cachedWidth = regionWidth
            } else {
                columnData[i].cachedWidth = columns[i].width.resolve(
                    workingAreaWidth: regionWidth, gap: gap
                )
            }
        }
    }

    // MARK: - Per-Display Snap Helpers

    /// Cumulative strip-space X of column `index` computed from SETTLED (cached)
    /// widths only — never the animated `currentWidth`. Region assignment must
    /// stay stable during an in-flight width animation, so the viewport-left used
    /// for region lookup shares the same cached-width basis as `midXInStrip`.
    private func cachedColumnX(at index: Int) -> Double {
        var x: Double = 0
        for i in 0..<max(0, min(index, columnData.count)) {
            x += columnData[i].cachedWidth + gap
        }
        return x
    }

    /// Region whose CG-X range owns a column's rendered midX. Uses `cachedWidth`
    /// for the cumulative-X walk so that snap targets are stable — they do NOT
    /// drift with in-flight A2-interpolated widths during a scroll animation.
    /// For solo groups returns the single region. For multi-region groups,
    /// returns the region containing the column's midpoint X, or the nearest
    /// region if the midpoint lands in an inter-display gap.
    public func regionForColumn(_ idx: Int, at time: Double) -> DisplayRegion {
        guard !columns.isEmpty, idx >= 0, idx < columns.count else {
            return groupArea.regions[0]
        }
        var cumX: Double = 0
        for i in 0..<idx {
            cumX += columnData[i].cachedWidth + gap
        }
        let colW = columnData[idx].cachedWidth
        let midXInStrip = cumX + colW / 2
        // Both operands must share ONE width basis. `viewPos(at:)` derives the
        // viewport-left through `columnX` → `currentWidth` (the ANIMATED width);
        // subtracting it from a `cachedWidth`-derived `midXInStrip` mixes bases, so
        // during an in-flight width animation on a column left of the active one the
        // ~hundreds-of-px width delta would shift `midXOnScreen` into the neighbouring
        // display's rect and select the wrong region. Use a cached-width viewport-left:
        // the region follows only the live scroll offset, never the animated widths.
        let viewPos = cachedColumnX(at: activeColumnIndex) + viewOffset.current(at: time)
        let midXOnScreen = midXInStrip - viewPos + Double(groupArea.totalSpan.minX)

        var best = groupArea.regions[0]
        var bestDist = Double.infinity
        for r in groupArea.regions {
            if midXOnScreen >= Double(r.rect.minX) && midXOnScreen <= Double(r.rect.maxX) {
                return r
            }
            let d = min(
                abs(midXOnScreen - Double(r.rect.minX)),
                abs(midXOnScreen - Double(r.rect.maxX))
            )
            if d < bestDist {
                bestDist = d
                best = r
            }
        }
        return best
    }

    /// Convenience shorthand for the active column's region.
    public func regionForActive(at time: Double) -> DisplayRegion {
        regionForColumn(activeColumnIndex, at: time)
    }

    /// Region lookup with an explicit viewport-left-edge value (strip-space).
    /// Used by navigation helpers that have updated `activeColumnIndex` but not yet
    /// written the new `viewOffset` — the caller computes `adjustedOffset` manually
    /// and passes it here so the midX-on-screen calculation is correct.
    private func regionForColumn(_ idx: Int, viewPos: Double) -> DisplayRegion {
        guard !columns.isEmpty, idx >= 0, idx < columns.count else {
            return groupArea.regions[0]
        }
        var cumX: Double = 0
        for i in 0..<idx {
            cumX += columnData[i].cachedWidth + gap
        }
        let colW = columnData[idx].cachedWidth
        let midXInStrip = cumX + colW / 2
        let midXOnScreen = midXInStrip - viewPos + Double(groupArea.totalSpan.minX)

        var best = groupArea.regions[0]
        var bestDist = Double.infinity
        for r in groupArea.regions {
            if midXOnScreen >= Double(r.rect.minX) && midXOnScreen <= Double(r.rect.maxX) {
                return r
            }
            let d = min(
                abs(midXOnScreen - Double(r.rect.minX)),
                abs(midXOnScreen - Double(r.rect.maxX))
            )
            if d < bestDist {
                bestDist = d
                best = r
            }
        }
        return best
    }

    /// Snap-target `viewOffset` that lands column `idx` at its current snap
    /// milestone within its owning region. Multi-region-aware: uses the owning
    /// region's X range and width, so the column centers (or `.left`/`.right`
    /// flushes) within that region, not across the combined strip.
    ///
    /// `columnWidthOverride` allows callers (e.g. `cycleWidthPreset`) to compute
    /// the snap target for a width that hasn't been written into `cachedWidth`
    /// yet — the animation target value.
    public func snapTarget(
        forColumn idx: Int,
        columnWidthOverride: Double? = nil,
        at time: Double
    ) -> Double {
        guard !columns.isEmpty, idx >= 0, idx < columns.count else { return 0 }
        let snapPoint = snapPoints[snapIndices[idx]]
        let colWidth = columnWidthOverride ?? columnData[idx].currentWidth(at: time)
        let region = regionForColumn(idx, at: time)
        let regionOffset = Double(region.rect.minX - groupArea.totalSpan.minX)
        let localSnap = computeSnapOffset(
            snapPoint: snapPoint,
            columnWidth: colWidth,
            workingAreaWidth: Double(region.rect.width)
        )
        return localSnap - regionOffset
    }

    /// Shorthand for the active column's snap target.
    public func snapTargetForActive(at time: Double) -> Double {
        snapTarget(forColumn: activeColumnIndex, at: time)
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

    /// Settle completed raise animations. Returns true if any are still in flight.
    public mutating func settleRaiseAnimations(at time: Double) -> Bool {
        var anyActive = false
        for i in 0..<columnData.count {
            if let anim = columnData[i].raiseAnimation {
                if anim.isDone(at: time) {
                    columnData[i].raiseAnimation = nil
                } else {
                    anyActive = true
                }
            }
        }
        return anyActive
    }
}
