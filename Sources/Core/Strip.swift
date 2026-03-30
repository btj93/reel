import Foundation
import CoreGraphics

/// The horizontal strip: the central data model for ScrollWM.
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

    /// How the viewport scrolls on focus change.
    public var focusMode: CenterFocusedColumn

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
        focusMode: CenterFocusedColumn = .always,
        gap: Double = 16,
        workingArea: CGRect = .zero,
        widthPresets: [ColumnWidth] = [.proportion(0.33), .proportion(0.5), .proportion(0.67)],
        defaultWidth: ColumnWidth = .proportion(0.5)
    ) {
        self.columns = columns
        self.columnData = columnData
        self.activeColumnIndex = activeColumnIndex
        self.viewOffset = viewOffset
        self.focusMode = focusMode
        self.gap = gap
        self.workingArea = workingArea
        self.widthPresets = widthPresets
        self.defaultWidth = defaultWidth
    }

    // MARK: - Computed Properties

    /// Total width of the strip (all columns + gaps).
    public var totalWidth: Double {
        guard !columnData.isEmpty else { return 0 }
        var w: Double = 0
        for data in columnData {
            w += data.currentWidth
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
    public func columnX(at index: Int) -> Double {
        computeColumnX(at: index, columnData: columnData, gap: gap)
    }

    /// The view position (left edge of the viewport in strip-space).
    public func viewPos(at time: Double) -> Double {
        columnX(at: activeColumnIndex) + viewOffset.current(at: time)
    }

    // MARK: - Column Mutations

    /// Add a new column to the right of the active column.
    public mutating func insertColumn(_ column: Column, at time: Double) {
        let insertIndex = min(activeColumnIndex + 1, columns.count)
        let resolvedWidth = column.isFullWidth
            ? workingArea.width
            : column.width.resolve(workingAreaWidth: workingArea.width, gap: gap)

        columns.insert(column, at: insertIndex)
        columnData.insert(ColumnData(cachedWidth: resolvedWidth), at: insertIndex)

        // Focus the new column
        activeColumnIndex = insertIndex

        // Recompute view offset for the new active column
        let newOffset = computeNewViewOffset(
            forColumn: activeColumnIndex,
            previousColumn: max(0, insertIndex - 1),
            focusMode: focusMode,
            columns: columns,
            columnData: columnData,
            gap: gap,
            workingAreaWidth: workingArea.width
        )
        viewOffset = .static(newOffset)
    }

    /// Remove a column at the given index.
    public mutating func removeColumn(at index: Int, at time: Double) {
        guard index >= 0, index < columns.count else { return }

        let removedWidth = columnData[index].currentWidth + gap

        columns.remove(at: index)
        columnData.remove(at: index)

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
        let newOffset = computeNewViewOffset(
            forColumn: activeColumnIndex,
            previousColumn: nil,
            focusMode: focusMode,
            columns: columns,
            columnData: columnData,
            gap: gap,
            workingAreaWidth: workingArea.width
        )
        viewOffset = .static(newOffset)
    }

    // MARK: - Focus Navigation

    /// Focus the column to the left.
    public mutating func focusLeft(at time: Double) {
        guard activeColumnIndex > 0 else { return }
        let previous = activeColumnIndex
        activeColumnIndex -= 1

        let newOffset = computeNewViewOffset(
            forColumn: activeColumnIndex,
            previousColumn: previous,
            focusMode: focusMode,
            columns: columns,
            columnData: columnData,
            gap: gap,
            workingAreaWidth: workingArea.width
        )

        // In instant mode, just set static. In animated mode, caller creates animation.
        viewOffset = .static(newOffset)
    }

    /// Focus the column to the right.
    public mutating func focusRight(at time: Double) {
        guard activeColumnIndex < columns.count - 1 else { return }
        let previous = activeColumnIndex
        activeColumnIndex += 1

        let newOffset = computeNewViewOffset(
            forColumn: activeColumnIndex,
            previousColumn: previous,
            focusMode: focusMode,
            columns: columns,
            columnData: columnData,
            gap: gap,
            workingAreaWidth: workingArea.width
        )

        viewOffset = .static(newOffset)
    }

    /// Move the active column left (swap with neighbor).
    public mutating func moveColumnLeft(at time: Double) {
        guard activeColumnIndex > 0 else { return }
        let i = activeColumnIndex
        columns.swapAt(i, i - 1)
        columnData.swapAt(i, i - 1)
        activeColumnIndex -= 1
    }

    /// Move the active column right (swap with neighbor).
    public mutating func moveColumnRight(at time: Double) {
        guard activeColumnIndex < columns.count - 1 else { return }
        let i = activeColumnIndex
        columns.swapAt(i, i + 1)
        columnData.swapAt(i, i + 1)
        activeColumnIndex += 1
    }

    // MARK: - Width Management

    /// Cycle the active column's width through presets.
    public mutating func cycleWidthPreset() {
        guard !columns.isEmpty, !widthPresets.isEmpty else { return }
        let col = columns[activeColumnIndex]
        let nextPresetIndex = ((col.presetIndex ?? -1) + 1) % widthPresets.count
        columns[activeColumnIndex].width = widthPresets[nextPresetIndex]
        columns[activeColumnIndex].presetIndex = nextPresetIndex
        columns[activeColumnIndex].isFullWidth = false
        columnData[activeColumnIndex].cachedWidth = widthPresets[nextPresetIndex]
            .resolve(workingAreaWidth: workingArea.width, gap: gap)
    }

    /// Toggle the active column to/from full-width mode.
    public mutating func toggleFullWidth() {
        guard !columns.isEmpty else { return }
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
            if columns[i].isFullWidth {
                columnData[i].cachedWidth = workingArea.width
            } else {
                columnData[i].cachedWidth = columns[i].width.resolve(
                    workingAreaWidth: workingArea.width, gap: gap
                )
            }
        }
    }
}
