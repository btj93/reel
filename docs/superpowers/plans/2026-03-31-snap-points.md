# Snap Points Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add configurable snap points (left/middle/right) so keyboard navigation cycles window positions before changing focus, replacing the existing `focus_mode` config.

**Architecture:** New `SnapPoint` enum in Core. Strip gains `snapPoints` and `snapIndices` arrays. Navigation methods `navigateLeft`/`navigateRight` replace `focusLeft`/`focusRight` with snap-then-focus logic. Config parses `snap = [...]` array with backward-compat `focus_mode` mapping.

**Tech Stack:** Swift, Core module (pure layout logic), Config module (TOMLKit), WindowManager module (orchestration)

**Spec:** `docs/superpowers/specs/2026-03-31-snap-points-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `Sources/Core/SnapPoint.swift` | Create | `SnapPoint` enum with Comparable |
| `Sources/Core/FocusMode.swift` | Rewrite | Remove old types, add `computeSnapOffset` |
| `Sources/Core/Strip.swift` | Modify | Replace `focusMode` with `snapPoints`+`snapIndices`, new navigation methods |
| `Sources/Config/Config.swift` | Modify | Parse `snap` array, deprecate `focus_mode`, update default config |
| `Sources/WindowManager/StripController.swift` | Modify | Wire new navigation, update gesture/resize/space handlers |
| `Sources/WindowManager/WindowManager.swift` | Modify | `applyConfig` iterates all stripControllers |
| `Tests/CoreTests/main.swift` | Modify | Update helpers, add snap test sections |

---

### Task 1: Create SnapPoint enum and computeSnapOffset

**Files:**
- Create: `Sources/Core/SnapPoint.swift`
- Modify: `Sources/Core/FocusMode.swift`
- Test: `Tests/CoreTests/main.swift`

- [ ] **Step 1: Write failing tests for computeSnapOffset**

Add at the end of `Tests/CoreTests/main.swift`, before the summary block (before line 410):

```swift
// MARK: - Snap Point Tests
print()
print("Snap Point Tests")

section("SnapPoint ordering")
do {
    check(SnapPoint.left < SnapPoint.middle, "left < middle")
    check(SnapPoint.middle < SnapPoint.right, "middle < right")
    let unsorted: [SnapPoint] = [.right, .left, .middle]
    let sorted = unsorted.sorted()
    assertEq(sorted, [.left, .middle, .right], "spatial sort")
}

section("computeSnapOffset — middle matches old centering")
do {
    let offset = computeSnapOffset(snapPoint: .middle, columnWidth: 720, workingAreaWidth: 1440)
    assertClose(offset, -360, tolerance: 0.01, "middle centers column")
}

section("computeSnapOffset — left")
do {
    let offset = computeSnapOffset(snapPoint: .left, columnWidth: 720, workingAreaWidth: 1440)
    assertClose(offset, 0, tolerance: 0.01, "left aligns to left edge")
}

section("computeSnapOffset — right")
do {
    let offset = computeSnapOffset(snapPoint: .right, columnWidth: 720, workingAreaWidth: 1440)
    assertClose(offset, -720, tolerance: 0.01, "right aligns to right edge")
}

section("computeSnapOffset — full-width column collapses to 0")
do {
    for snap in [SnapPoint.left, .middle, .right] {
        let offset = computeSnapOffset(snapPoint: snap, columnWidth: 1440, workingAreaWidth: 1440)
        assertClose(offset, 0, tolerance: 0.01, "\(snap) full-width")
    }
}

section("computeSnapOffset — column wider than screen clamps to 0")
do {
    let offset = computeSnapOffset(snapPoint: .right, columnWidth: 2000, workingAreaWidth: 1440)
    assertClose(offset, 0, tolerance: 0.01, "wider than screen clamps")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run RunTests 2>&1 | tail -5`
Expected: Compilation error — `SnapPoint` and `computeSnapOffset` don't exist yet.

- [ ] **Step 3: Create SnapPoint.swift**

Create `Sources/Core/SnapPoint.swift`:

```swift
import Foundation

/// A discrete viewport snap position for the focused column.
public enum SnapPoint: String, Sendable, Comparable, Hashable {
    case left, middle, right

    private var sortOrder: Int {
        switch self {
        case .left: return 0
        case .middle: return 1
        case .right: return 2
        }
    }

    public static func < (lhs: SnapPoint, rhs: SnapPoint) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}
```

- [ ] **Step 4: Rewrite FocusMode.swift with computeSnapOffset**

Replace the contents of `Sources/Core/FocusMode.swift` with:

```swift
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
```

Note: `CenterFocusedColumn`, `computeNewViewOffset`, `computeCenteredOffset`, and `computeFitOffset` are all removed. `computeColumnX` is kept unchanged.

- [ ] **Step 5: Run tests to verify the snap tests pass**

Run: `swift run RunTests 2>&1 | tail -5`
Expected: Compilation errors in Strip.swift (references to removed `CenterFocusedColumn` and `computeNewViewOffset`). The snap tests themselves would pass if the code compiled. We'll fix Strip.swift in the next task.

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/SnapPoint.swift Sources/Core/FocusMode.swift Tests/CoreTests/main.swift
git commit -m "feat(core): add SnapPoint enum and computeSnapOffset

Replaces CenterFocusedColumn, computeNewViewOffset, computeCenteredOffset,
and computeFitOffset with a simpler snap-point-based offset computation."
```

---

### Task 2: Update Strip — replace focusMode with snapPoints/snapIndices

**Files:**
- Modify: `Sources/Core/Strip.swift`
- Test: `Tests/CoreTests/main.swift`

- [ ] **Step 1: Write failing tests for Strip snap state management**

Add after the snap offset tests in `Tests/CoreTests/main.swift`:

```swift
section("Strip — default snap index is middle")
do {
    let wa = CGRect(x: 0, y: 25, width: 1440, height: 875)
    var strip = Strip(snapPoints: [.left, .middle, .right], gap: 16, workingArea: wa)
    let col = Column(tiles: [TileID(1)], width: .proportion(0.5))
    strip.insertColumn(col, at: 0)
    assertEq(strip.snapIndices.count, 1, "one snap index")
    assertEq(strip.snapIndices[0], 1, "default is middle (index 1)")
}

section("Strip — default snap index without middle")
do {
    let wa = CGRect(x: 0, y: 25, width: 1440, height: 875)
    var strip = Strip(snapPoints: [.left, .right], gap: 16, workingArea: wa)
    let col = Column(tiles: [TileID(1)], width: .proportion(0.5))
    strip.insertColumn(col, at: 0)
    assertEq(strip.snapIndices[0], 0, "default is (count-1)/2 = 0 for [left, right]")
}

section("Strip — removeColumn removes snap index")
do {
    let wa = CGRect(x: 0, y: 25, width: 1440, height: 875)
    var strip = Strip(snapPoints: [.left, .middle, .right], gap: 16, workingArea: wa)
    for i in 0..<3 {
        strip.insertColumn(Column(tiles: [TileID(UInt32(i + 1))], width: .proportion(0.5)), at: 0)
    }
    assertEq(strip.snapIndices.count, 3)
    strip.removeColumn(at: 1, at: 0)
    assertEq(strip.snapIndices.count, 2, "snap index removed with column")
}

section("Strip — moveColumnRight swaps snap indices")
do {
    let wa = CGRect(x: 0, y: 25, width: 1440, height: 875)
    var strip = Strip(snapPoints: [.left, .middle, .right], gap: 16, workingArea: wa)
    for i in 0..<3 {
        strip.insertColumn(Column(tiles: [TileID(UInt32(i + 1))], width: .proportion(0.5)), at: 0)
    }
    // Manually set snap index 0 to something different
    strip.snapIndices[0] = 2  // rightmost
    strip.activeColumnIndex = 0
    strip.moveColumnRight(at: 0)
    assertEq(strip.snapIndices[1], 2, "snap index followed the column")
    assertEq(strip.snapIndices[0], 1, "neighbor's snap index is default")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run RunTests 2>&1 | tail -5`
Expected: Compilation error — `Strip` init doesn't accept `snapPoints` yet.

- [ ] **Step 3: Update Strip.swift — replace focusMode with snapPoints and snapIndices**

In `Sources/Core/Strip.swift`, make these changes:

Replace the `focusMode` property (line 20-21):
```swift
    /// How the viewport scrolls on focus change.
    public var focusMode: CenterFocusedColumn
```
with:
```swift
    /// Configured snap points, sorted spatially (default: [.middle]).
    public var snapPoints: [SnapPoint]

    /// Per-column snap index into `snapPoints`. Parallel to `columns`.
    public var snapIndices: [Int]
```

Update the `init` — replace `focusMode: CenterFocusedColumn = .always` parameter with `snapPoints: [SnapPoint] = [.middle]` and add `snapIndices: [Int] = []`:

```swift
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
```

Add a computed property for the default snap index:

```swift
    /// The default snap index for new columns — `.middle` or closest to center.
    public var defaultSnapIndex: Int {
        if let idx = snapPoints.firstIndex(of: .middle) { return idx }
        return (snapPoints.count - 1) / 2
    }
```

Update `insertColumn(_:at:)` (the one-param time variant, line 89-92) — add snap index insertion:
```swift
    public mutating func insertColumn(_ column: Column, at time: Double) {
        let insertIndex = min(activeColumnIndex + 1, columns.count)
        insertColumn(column, at: time, atIndex: insertIndex)
    }
```
(No change needed here — it delegates to the atIndex variant.)

Update `insertColumn(_:at:atIndex:)` (line 96-117) — insert snap index and use `computeSnapOffset`:
```swift
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
            columnWidth: columnData[activeColumnIndex].currentWidth,
            workingAreaWidth: workingArea.width
        )
        viewOffset = .static(newOffset)
    }
```

Update `removeColumn(at:at:)` (line 120-160) — remove snap index:
```swift
    public mutating func removeColumn(at index: Int, at time: Double) {
        guard index >= 0, index < columns.count else { return }

        let removedWidth = columnData[index].currentWidth + gap

        columns.remove(at: index)
        columnData.remove(at: index)
        snapIndices.remove(at: index)

        guard !columns.isEmpty else {
            activeColumnIndex = 0
            viewOffset = .static(0)
            return
        }

        if index < activeColumnIndex {
            activeColumnIndex -= 1
            viewOffset.shiftBy(-removedWidth)
        } else if index == activeColumnIndex {
            if index < columns.count {
                activeColumnIndex = index
            } else {
                activeColumnIndex = columns.count - 1
            }
        }

        let snapPoint = snapPoints[snapIndices[activeColumnIndex]]
        let newOffset = computeSnapOffset(
            snapPoint: snapPoint,
            columnWidth: columnData[activeColumnIndex].currentWidth,
            workingAreaWidth: workingArea.width
        )
        viewOffset = .static(newOffset)
    }
```

Update `recenterActiveColumn(at:)` (line 165-176):
```swift
    public mutating func recenterActiveColumn(at time: Double) {
        guard !columns.isEmpty else { return }
        let snapPoint = snapPoints[snapIndices[activeColumnIndex]]
        let targetOffset = computeSnapOffset(
            snapPoint: snapPoint,
            columnWidth: columnData[activeColumnIndex].currentWidth,
            workingAreaWidth: workingArea.width
        )
        viewOffset = .static(targetOffset)
    }
```

Update `recenterActiveColumnAnimated(at:)` (line 179-190):
```swift
    public mutating func recenterActiveColumnAnimated(at time: Double) -> SpringAnimation? {
        guard !columns.isEmpty else { return nil }
        let snapPoint = snapPoints[snapIndices[activeColumnIndex]]
        let targetOffset = computeSnapOffset(
            snapPoint: snapPoint,
            columnWidth: columnData[activeColumnIndex].currentWidth,
            workingAreaWidth: workingArea.width
        )
        return createScrollAnimation(to: targetOffset, at: time)
    }
```

Update `moveColumnLeft(at:)` (line 349-355) — swap snap indices:
```swift
    public mutating func moveColumnLeft(at time: Double) {
        guard activeColumnIndex > 0 else { return }
        let i = activeColumnIndex
        columns.swapAt(i, i - 1)
        columnData.swapAt(i, i - 1)
        snapIndices.swapAt(i, i - 1)
        activeColumnIndex -= 1
    }
```

Update `moveColumnRight(at:)` (line 358-364) — swap snap indices:
```swift
    public mutating func moveColumnRight(at time: Double) {
        guard activeColumnIndex < columns.count - 1 else { return }
        let i = activeColumnIndex
        columns.swapAt(i, i + 1)
        columnData.swapAt(i, i + 1)
        snapIndices.swapAt(i, i + 1)
        activeColumnIndex += 1
    }
```

- [ ] **Step 4: Update test helpers in Tests/CoreTests/main.swift**

Replace `makeStrip` (line 34-43):
```swift
func makeStrip(columnCount: Int, width: Double = 0.5, gap: Double = 16, screenWidth: Double = 1440, screenHeight: Double = 900, snapPoints: [SnapPoint] = [.middle]) -> Strip {
    let wa = CGRect(x: 0, y: 25, width: screenWidth, height: screenHeight - 25)
    var columns: [Column] = []
    var columnData: [ColumnData] = []
    for i in 0..<columnCount {
        columns.append(Column(tiles: [TileID(UInt32(i + 1))], width: .proportion(width)))
        columnData.append(ColumnData(cachedWidth: wa.width * width))
    }
    let defaultIdx = snapPoints.firstIndex(of: .middle) ?? (snapPoints.count - 1) / 2
    let snapIndices = Array(repeating: defaultIdx, count: columnCount)
    return Strip(columns: columns, columnData: columnData, activeColumnIndex: 0, viewOffset: .static(0), snapPoints: snapPoints, snapIndices: snapIndices, gap: gap, workingArea: wa)
}
```

`makeLayoutStrip` (line 45-54) doesn't pass `focusMode`, so it just needs to not pass it — the default `snapPoints: [.middle]` will apply. No change needed.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift run RunTests 2>&1 | tail -10`
Expected: Compilation may still fail due to remaining references to `focusMode` in `Strip.swift`'s old `focusLeft`/`focusRight` methods and in other modules. But the Core tests for snap state management should be logically correct. We'll replace the navigation methods in the next task.

- [ ] **Step 6: Remove old focusLeft/focusRight/focusLeftAnimated/focusRightAnimated from Strip.swift**

Delete the entire Focus Navigation section (lines 194-289 in the original file — the `focusLeft`, `focusRight`, `focusLeftAnimated`, `focusRightAnimated` methods). These will be replaced by `navigateLeft`/`navigateRight` in Task 3.

- [ ] **Step 7: Commit**

```bash
git add Sources/Core/Strip.swift Tests/CoreTests/main.swift
git commit -m "feat(core): replace focusMode with snapPoints/snapIndices on Strip

Strip now tracks per-column snap indices parallel to columns array.
insertColumn, removeColumn, moveColumn, recenter all use computeSnapOffset.
Old focusLeft/focusRight methods removed (replaced in next commit)."
```

---

### Task 3: Implement navigateLeft/navigateRight on Strip

**Files:**
- Modify: `Sources/Core/Strip.swift`
- Test: `Tests/CoreTests/main.swift`

- [ ] **Step 1: Write failing tests for navigation**

Add after the previous snap tests in `Tests/CoreTests/main.swift`:

```swift
section("navigateRight — cycles snap points before changing focus")
do {
    var strip = makeStrip(columnCount: 3, snapPoints: [.left, .middle, .right])
    strip.activeColumnIndex = 1
    strip.snapIndices[1] = 0  // start at left

    // First press: left → middle (same column)
    let _ = strip.navigateRight(at: 0)
    assertEq(strip.activeColumnIndex, 1, "still on column 1")
    assertEq(strip.snapIndices[1], 1, "snap advanced to middle")

    // Second press: middle → right (same column)
    let _ = strip.navigateRight(at: 0)
    assertEq(strip.activeColumnIndex, 1, "still on column 1")
    assertEq(strip.snapIndices[1], 2, "snap advanced to right")

    // Third press: exhausted — move focus right
    let _ = strip.navigateRight(at: 0)
    assertEq(strip.activeColumnIndex, 2, "moved to column 2")
}

section("navigateLeft — cycles snap points before changing focus")
do {
    var strip = makeStrip(columnCount: 3, snapPoints: [.left, .middle, .right])
    strip.activeColumnIndex = 1
    strip.snapIndices[1] = 2  // start at right

    // First press: right → middle
    let _ = strip.navigateLeft(at: 0)
    assertEq(strip.activeColumnIndex, 1, "still on column 1")
    assertEq(strip.snapIndices[1], 1, "snap decremented to middle")

    // Second press: middle → left
    let _ = strip.navigateLeft(at: 0)
    assertEq(strip.activeColumnIndex, 1, "still on column 1")
    assertEq(strip.snapIndices[1], 0, "snap decremented to left")

    // Third press: exhausted — move focus left
    let _ = strip.navigateLeft(at: 0)
    assertEq(strip.activeColumnIndex, 0, "moved to column 0")
}

section("navigateRight — focus change doesn't advance new column's snap")
do {
    var strip = makeStrip(columnCount: 2, snapPoints: [.left, .middle, .right])
    strip.snapIndices[0] = 2  // col 0 at rightmost
    strip.snapIndices[1] = 1  // col 1 at middle

    let _ = strip.navigateRight(at: 0)
    assertEq(strip.activeColumnIndex, 1, "moved to column 1")
    assertEq(strip.snapIndices[1], 1, "col 1 snap unchanged (still middle)")
}

section("snap=[middle] — immediate focus change (backward compat)")
do {
    var strip = makeStrip(columnCount: 3, snapPoints: [.middle])

    let _ = strip.navigateRight(at: 0)
    assertEq(strip.activeColumnIndex, 1, "immediate focus change")

    let _ = strip.navigateRight(at: 0)
    assertEq(strip.activeColumnIndex, 2, "immediate focus change")
}

section("snap=[left] — single snap, immediate focus change, left-aligned")
do {
    var strip = makeStrip(columnCount: 2, snapPoints: [.left])
    let _ = strip.navigateRight(at: 0)
    assertEq(strip.activeColumnIndex, 1, "immediate focus change")
    let offset = strip.viewOffset.current(at: 0)
    assertClose(offset, 0, tolerance: 0.01, "left-aligned")
}

section("navigateRight — rubber-band at boundary")
do {
    var strip = makeStrip(columnCount: 1, snapPoints: [.left, .middle, .right])
    strip.snapIndices[0] = 2  // at rightmost
    let anim = strip.navigateRight(at: 0)
    check(anim != nil, "should produce rubber-band animation")
    assertEq(strip.activeColumnIndex, 0, "still on column 0")
    assertEq(strip.snapIndices[0], 2, "snap unchanged")
}

section("navigateLeft — rubber-band at boundary")
do {
    var strip = makeStrip(columnCount: 1, snapPoints: [.left, .middle, .right])
    strip.snapIndices[0] = 0  // at leftmost
    let anim = strip.navigateLeft(at: 0)
    check(anim != nil, "should produce rubber-band animation")
    assertEq(strip.activeColumnIndex, 0, "still on column 0")
    assertEq(strip.snapIndices[0], 0, "snap unchanged")
}

section("snap=[left,right] — two snap points, default index is 0 (left)")
do {
    var strip = makeStrip(columnCount: 2, snapPoints: [.left, .right])
    assertEq(strip.snapIndices[0], 0, "default snap index for [left, right]")
    let _ = strip.navigateRight(at: 0)
    assertEq(strip.activeColumnIndex, 0, "first press advances snap, stays on col 0")
    assertEq(strip.snapIndices[0], 1, "advanced to right")
    let _ = strip.navigateRight(at: 0)
    assertEq(strip.activeColumnIndex, 1, "second press moves focus")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run RunTests 2>&1 | tail -5`
Expected: Compilation error — `navigateLeft`/`navigateRight` don't exist yet.

- [ ] **Step 3: Implement navigateLeft and navigateRight on Strip**

Add to `Sources/Core/Strip.swift` in the Focus Navigation section:

```swift
    // MARK: - Snap Navigation

    /// Navigate right: advance snap point on current column, or move focus right if exhausted.
    /// Returns a SpringAnimation if animated, nil if no movement needed.
    @discardableResult
    public mutating func navigateRight(at time: Double) -> SpringAnimation? {
        guard !columns.isEmpty else { return nil }
        let currentSnap = snapIndices[activeColumnIndex]

        if currentSnap < snapPoints.count - 1 {
            // Advance snap point on current column
            snapIndices[activeColumnIndex] += 1
            let colWidth = columnData[activeColumnIndex].currentWidth
            let targetOffset = computeSnapOffset(
                snapPoint: snapPoints[snapIndices[activeColumnIndex]],
                columnWidth: colWidth,
                workingAreaWidth: workingArea.width
            )
            return createScrollAnimation(to: targetOffset, at: time)
        } else if activeColumnIndex < columns.count - 1 {
            // Exhausted snap points — move focus to next column
            activeColumnIndex += 1
            let newColWidth = columnData[activeColumnIndex].currentWidth
            let targetOffset = computeSnapOffset(
                snapPoint: snapPoints[snapIndices[activeColumnIndex]],
                columnWidth: newColWidth,
                workingAreaWidth: workingArea.width
            )
            return createScrollAnimation(to: targetOffset, at: time)
        } else {
            // At rightmost column + rightmost snap — rubber-band bounce
            return createRubberBandAnimation(direction: 1, at: time)
        }
    }

    /// Navigate left: decrement snap point on current column, or move focus left if exhausted.
    @discardableResult
    public mutating func navigateLeft(at time: Double) -> SpringAnimation? {
        guard !columns.isEmpty else { return nil }
        let currentSnap = snapIndices[activeColumnIndex]

        if currentSnap > 0 {
            // Decrement snap point on current column
            snapIndices[activeColumnIndex] -= 1
            let colWidth = columnData[activeColumnIndex].currentWidth
            let targetOffset = computeSnapOffset(
                snapPoint: snapPoints[snapIndices[activeColumnIndex]],
                columnWidth: colWidth,
                workingAreaWidth: workingArea.width
            )
            return createScrollAnimation(to: targetOffset, at: time)
        } else if activeColumnIndex > 0 {
            // Exhausted snap points — move focus to previous column
            activeColumnIndex -= 1
            let newColWidth = columnData[activeColumnIndex].currentWidth
            let targetOffset = computeSnapOffset(
                snapPoint: snapPoints[snapIndices[activeColumnIndex]],
                columnWidth: newColWidth,
                workingAreaWidth: workingArea.width
            )
            return createScrollAnimation(to: targetOffset, at: time)
        } else {
            // At leftmost column + leftmost snap — rubber-band bounce
            return createRubberBandAnimation(direction: -1, at: time)
        }
    }

    /// Navigate right without animation (instant mode).
    public mutating func navigateRightInstant(at time: Double) {
        guard !columns.isEmpty else { return }
        let currentSnap = snapIndices[activeColumnIndex]

        if currentSnap < snapPoints.count - 1 {
            snapIndices[activeColumnIndex] += 1
        } else if activeColumnIndex < columns.count - 1 {
            activeColumnIndex += 1
        } else {
            return
        }

        let colWidth = columnData[activeColumnIndex].currentWidth
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

        if currentSnap > 0 {
            snapIndices[activeColumnIndex] -= 1
        } else if activeColumnIndex > 0 {
            activeColumnIndex -= 1
        } else {
            return
        }

        let colWidth = columnData[activeColumnIndex].currentWidth
        let targetOffset = computeSnapOffset(
            snapPoint: snapPoints[snapIndices[activeColumnIndex]],
            columnWidth: colWidth,
            workingAreaWidth: workingArea.width
        )
        viewOffset = .static(targetOffset)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run RunTests 2>&1 | tail -10`
Expected: Core tests pass. Other modules may still have compile errors (references to old `focusMode`, `focusLeft`, `focusRight`).

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Strip.swift Tests/CoreTests/main.swift
git commit -m "feat(core): implement navigateLeft/navigateRight with snap cycling

Keyboard navigation now cycles through snap points before changing focus.
Animated variants preserve velocity for rapid keypress compounding.
Instant variants set viewOffset directly."
```

---

### Task 4: Update Config — parse snap array, deprecate focus_mode

**Files:**
- Modify: `Sources/Config/Config.swift`

- [ ] **Step 1: Replace focusMode with snapPoints in ScrollWMConfig struct**

In `Sources/Config/Config.swift`, replace line 13:
```swift
    public var focusMode: CenterFocusedColumn = .always
```
with:
```swift
    public var snapPoints: [SnapPoint] = [.middle]
```

- [ ] **Step 2: Update parse() to handle snap array and deprecated focus_mode**

In the `parse(table:)` method, replace the `focus_mode` parsing block (lines 164-171):
```swift
            if let fm = readString(layout["focus_mode"]) {
                switch fm {
                case "never": config.focusMode = .never
                case "always": config.focusMode = .always
                case "on-overflow", "on_overflow", "onOverflow": config.focusMode = .onOverflow
                default: break
                }
            }
```
with:
```swift
            // Parse snap array (new)
            var snapExplicitlySet = false
            if let snapArray = layout["snap"] as? TOMLArray {
                var points: [SnapPoint] = []
                for item in snapArray {
                    if let str = readString(item) {
                        switch str {
                        case "left": points.append(.left)
                        case "middle": points.append(.middle)
                        case "right": points.append(.right)
                        default: print("[Config] Unknown snap point: \(str)")
                        }
                    }
                }
                let deduped = Array(Set(points)).sorted()
                if !deduped.isEmpty {
                    config.snapPoints = deduped
                    snapExplicitlySet = true
                }
            }

            // Backward compat: focus_mode → snap (only if snap not explicitly set)
            if !snapExplicitlySet, let fm = readString(layout["focus_mode"]) {
                switch fm {
                case "never": config.snapPoints = [.left]
                case "always": config.snapPoints = [.middle]
                case "on-overflow", "on_overflow", "onOverflow": config.snapPoints = [.middle]
                default: break
                }
                print("[Config] Warning: focus_mode is deprecated, use snap instead")
            }

            // Validation
            if config.snapPoints.isEmpty {
                print("[Config] Warning: snap is empty, defaulting to [middle]")
                config.snapPoints = [.middle]
            }
```

- [ ] **Step 3: Update createDefaultConfig() — emit snap instead of focus_mode**

In `createDefaultConfig()`, replace line 264:
```swift
        focus_mode = "always"  # "never", "always", "on-overflow"
```
with:
```swift
        snap = ["middle"]  # any combination of: "left", "middle", "right"
```

- [ ] **Step 4: Build to check for errors**

Run: `swift build 2>&1 | grep error | head -10`
Expected: Errors in `WindowManager.swift` and `StripController.swift` referencing `focusMode`. Those are fixed in the next task.

- [ ] **Step 5: Commit**

```bash
git add Sources/Config/Config.swift
git commit -m "feat(config): parse snap array, deprecate focus_mode

Config now accepts snap = ['left', 'middle', 'right'] in [layout].
Old focus_mode is parsed for backward compat with deprecation warning.
Default config emits snap instead of focus_mode."
```

---

### Task 5: Update StripController — wire navigation and snap resets

**Files:**
- Modify: `Sources/WindowManager/StripController.swift`

- [ ] **Step 1: Update focusLeft/focusRight to use navigateLeft/navigateRight**

Replace `focusLeft()` (lines 214-225):
```swift
    public func focusLeft() {
        let time = currentTime()
        if animationEnabled {
            if let _ = strip.navigateLeft(at: time) {
                frameLoop?.resume()
            }
        } else {
            strip.navigateLeftInstant(at: time)
            applyLayout()
        }
        focusActiveWindow()
    }
```

Replace `focusRight()` (lines 227-238):
```swift
    public func focusRight() {
        let time = currentTime()
        if animationEnabled {
            if let _ = strip.navigateRight(at: time) {
                frameLoop?.resume()
            }
        } else {
            strip.navigateRightInstant(at: time)
            applyLayout()
        }
        focusActiveWindow()
    }
```

- [ ] **Step 2: Update scrollToWindow — reset snap index to default**

In `scrollToWindow(tileID:)` (lines 385-403), after setting `strip.activeColumnIndex = colIndex`, add the snap reset and replace the offset computation:

```swift
    public func scrollToWindow(tileID: TileID) {
        guard let colIndex = strip.columns.firstIndex(where: { $0.tiles.contains(tileID) }) else { return }

        strip.activeColumnIndex = colIndex
        strip.snapIndices[colIndex] = strip.defaultSnapIndex

        let snapPoint = strip.snapPoints[strip.snapIndices[colIndex]]
        let newOffset = computeSnapOffset(
            snapPoint: snapPoint,
            columnWidth: strip.columnData[colIndex].currentWidth,
            workingAreaWidth: strip.workingArea.width
        )
        strip.viewOffset = .static(newOffset)

        applyLayout()
    }
```

- [ ] **Step 3: Update snapToNearestColumnEdge — reset snap index to default**

In `snapToNearestColumnEdge(offset:)` (lines 580-609), after `strip.activeColumnIndex = bestIndex`, add snap reset and replace the offset computation:

```swift
    private func snapToNearestColumnEdge(offset: Double) -> Double {
        let viewPos = strip.columnX(at: strip.activeColumnIndex) + offset
        let viewCenter = viewPos + strip.workingArea.width / 2
        var bestIndex = strip.activeColumnIndex
        var bestDist = Double.infinity

        for i in 0..<strip.columns.count {
            let colCenter = strip.columnX(at: i) + strip.columnData[i].currentWidth / 2
            let dist = abs(colCenter - viewCenter)
            if dist < bestDist {
                bestDist = dist
                bestIndex = i
            }
        }

        strip.activeColumnIndex = bestIndex
        strip.snapIndices[bestIndex] = strip.defaultSnapIndex

        let snapPoint = strip.snapPoints[strip.snapIndices[bestIndex]]
        return computeSnapOffset(
            snapPoint: snapPoint,
            columnWidth: strip.columnData[bestIndex].currentWidth,
            workingAreaWidth: strip.workingArea.width
        )
    }
```

- [ ] **Step 4: Update rebuildStrip — clear snapIndices**

In `rebuildStrip()` (lines 200-210), add `strip.snapIndices.removeAll()`:

```swift
    public func rebuildStrip() {
        strip.columns.removeAll()
        strip.columnData.removeAll()
        strip.snapIndices.removeAll()
        strip.activeColumnIndex = 0
        strip.viewOffset = .static(0)
        windowMap.removeAll()
        apps.removeAll()
        lastCommittedFrames.removeAll()
        focusRing.hide()
    }
```

- [ ] **Step 5: Update SavedStripState and switchSpace — save/restore snapIndices**

Add `snapIndices` to `SavedStripState` (line 730-738):
```swift
struct SavedStripState {
    let columns: [Column]
    let columnData: [ColumnData]
    let snapIndices: [Int]
    let activeColumnIndex: Int
    let viewOffset: ViewOffset
    let windowMap: [TileID: AXWindow]
    let apps: [pid_t: AXApp]
    let lastCommittedFrames: [TileID: CGRect]
}
```

Update `saveCurrentSpace()` (lines 672-683) — pass snapIndices:
```swift
    public func saveCurrentSpace() {
        guard !currentSpaceFingerprint.isEmpty else { return }
        savedSpaces[currentSpaceFingerprint] = SavedStripState(
            columns: strip.columns,
            columnData: strip.columnData,
            snapIndices: strip.snapIndices,
            activeColumnIndex: strip.activeColumnIndex,
            viewOffset: strip.viewOffset,
            windowMap: windowMap,
            apps: apps,
            lastCommittedFrames: lastCommittedFrames
        )
    }
```

Update `switchSpace(onScreenWindowIDs:)` — restore snapIndices (in the `if let saved` block, ~line 699):
```swift
            // Restore saved state
            strip.columns = saved.columns
            strip.columnData = saved.columnData
            strip.activeColumnIndex = saved.activeColumnIndex
            strip.viewOffset = saved.viewOffset
            // Restore snap indices with migration fallback
            if saved.snapIndices.count == saved.columns.count {
                strip.snapIndices = saved.snapIndices
            } else {
                strip.snapIndices = Array(repeating: strip.defaultSnapIndex, count: saved.columns.count)
            }
            windowMap = saved.windowMap
            apps = saved.apps
            lastCommittedFrames.removeAll()
```

In the "new space" branch (~line 712), add:
```swift
        strip.snapIndices.removeAll()
```

- [ ] **Step 6: Build to check for remaining errors**

Run: `swift build 2>&1 | grep error | head -10`
Expected: Errors in `WindowManager.swift` referencing `focusMode`. Fixed in next task.

- [ ] **Step 7: Commit**

```bash
git add Sources/WindowManager/StripController.swift
git commit -m "feat(wm): wire snap navigation in StripController

focusLeft/Right use navigateLeft/Right. scrollToWindow and gesture settle
reset snap to default. rebuildStrip and switchSpace manage snapIndices.
SavedStripState includes snapIndices with migration fallback."
```

---

### Task 6: Update WindowManager — applyConfig for all displays

**Files:**
- Modify: `Sources/WindowManager/WindowManager.swift`

- [ ] **Step 1: Update applyConfig to iterate all stripControllers and use snapPoints**

Replace lines 93-97 in `applyConfig`:
```swift
        stripController.strip.gap = config.gap
        stripController.strip.defaultWidth = config.defaultWidth
        stripController.strip.widthPresets = config.widthPresets
        stripController.strip.focusMode = config.focusMode
        stripController.animationEnabled = config.animationEnabled
```
with:
```swift
        for (_, sc) in stripControllers {
            sc.strip.gap = config.gap
            sc.strip.defaultWidth = config.defaultWidth
            sc.strip.widthPresets = config.widthPresets
            sc.strip.snapPoints = config.snapPoints
            sc.animationEnabled = config.animationEnabled
        }
```

- [ ] **Step 2: Update the config reload handler (~line 379-384)**

Replace:
```swift
        stripController.strip.gap = config.gap
        stripController.strip.defaultWidth = config.defaultWidth
        stripController.strip.widthPresets = config.widthPresets
        stripController.strip.focusMode = config.focusMode
        stripController.animationEnabled = config.animationEnabled
```
with:
```swift
        for (_, sc) in stripControllers {
            sc.strip.gap = config.gap
            sc.strip.defaultWidth = config.defaultWidth
            sc.strip.widthPresets = config.widthPresets
            sc.strip.snapPoints = config.snapPoints
            sc.animationEnabled = config.animationEnabled
        }
```

- [ ] **Step 3: Update the log line (~line 125)**

Replace:
```swift
        print("[WM] Config applied (gap=\(config.gap), focus=\(config.focusMode), animation=\(config.animationEnabled))")
```
with:
```swift
        print("[WM] Config applied (gap=\(config.gap), snap=\(config.snapPoints), animation=\(config.animationEnabled))")
```

- [ ] **Step 4: Remove any remaining references to focusMode**

Search for any remaining `focusMode` references and replace:

Run: `grep -rn "focusMode\|CenterFocusedColumn" Sources/`

Fix any remaining hits. Common ones:
- Any `strip.focusMode` → `strip.snapPoints`
- Any `CenterFocusedColumn` type references → remove

- [ ] **Step 5: Build and run tests**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

Run: `swift run RunTests 2>&1 | tail -5`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/WindowManager/WindowManager.swift
git commit -m "feat(wm): applyConfig iterates all stripControllers

Sets snapPoints on all displays instead of just the active one.
Also fixes pre-existing bug where focusMode was only set on active display."
```

---

### Task 7: Final integration test — build, run tests, verify

**Files:**
- None (verification only)

- [ ] **Step 1: Full build**

Run: `swift build 2>&1`
Expected: Build succeeds with no errors.

- [ ] **Step 2: Run all tests**

Run: `swift run RunTests`
Expected: All tests pass, including the new snap point tests.

- [ ] **Step 3: Grep for any remaining references to removed types**

Run: `grep -rn "CenterFocusedColumn\|computeNewViewOffset\|computeCenteredOffset\|computeFitOffset\|focusMode\|\.focusLeft\|\.focusRight\b" Sources/ Tests/`

Expected: No hits (or only comments). Fix any remaining references.

- [ ] **Step 4: Commit any final fixups**

If any cleanup was needed:
```bash
git add -A
git commit -m "chore: clean up remaining references to old focus_mode types"
```
