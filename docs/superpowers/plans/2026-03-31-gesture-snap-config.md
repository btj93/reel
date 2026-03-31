# Gesture Snap Config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `[gesture] snap` config option that controls whether trackpad gestures snap to columns, and improve gesture-end behavior to use cursor-based column selection and nearest-snap-point targeting.

**Architecture:** New boolean `gestureSnap` on `ScrollWMConfig`, propagated to `StripController`. `handleGestureEnd` branches on it: when true, snaps to the nearest configured snap point for the column under the cursor; when false, animates to the momentum-projected offset with no column alignment. Two new pure helper functions (`nearestSnapPoint` and `columnIndexAtStripX`) are added to `Core/FocusMode.swift` for testability.

**Tech Stack:** Swift, Core (pure logic), Config (TOMLKit), WindowManager (orchestration)

---

### Task 1: Add pure helper — `nearestSnapPoint`

**Files:**
- Modify: `Sources/Core/FocusMode.swift`
- Modify: `Tests/CoreTests/main.swift`

- [ ] **Step 1: Write failing tests for `nearestSnapPoint`**

Add this section at the end of the test file, before the final summary block (before line 582 `// ============================================================`):

```swift
// MARK: - Gesture Snap Helper Tests
print()
print("Gesture Snap Helper Tests")

section("nearestSnapPoint — single snap point")
do {
    let (idx, offset) = nearestSnapPoint(
        projectedOffset: -200,
        snapPoints: [.middle],
        columnWidth: 720,
        workingAreaWidth: 1440
    )
    assertEq(idx, 0, "only one option")
    assertClose(offset, -360, tolerance: 0.01, "middle offset")
}

section("nearestSnapPoint — picks closest of three")
do {
    // left=0, middle=-360, right=-720. Projected=-100 → closest is left (0).
    let (idx, _) = nearestSnapPoint(
        projectedOffset: -100,
        snapPoints: [.left, .middle, .right],
        columnWidth: 720,
        workingAreaWidth: 1440
    )
    assertEq(idx, 0, "closest to left")
}

section("nearestSnapPoint — picks right when projected far negative")
do {
    // left=0, middle=-360, right=-720. Projected=-600 → closest is right (-720).
    let (idx, _) = nearestSnapPoint(
        projectedOffset: -600,
        snapPoints: [.left, .middle, .right],
        columnWidth: 720,
        workingAreaWidth: 1440
    )
    assertEq(idx, 2, "closest to right")
}

section("nearestSnapPoint — picks middle when equidistant favors first")
do {
    // left=0, middle=-360, right=-720. Projected=-180 → equidistant between left(0) and middle(-360).
    // Should pick first match (left at index 0) since we use < not <=.
    let (idx, _) = nearestSnapPoint(
        projectedOffset: -180,
        snapPoints: [.left, .middle, .right],
        columnWidth: 720,
        workingAreaWidth: 1440
    )
    assertEq(idx, 0, "equidistant picks first (left)")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run RunTests 2>&1`
Expected: compilation error — `nearestSnapPoint` is not defined

- [ ] **Step 3: Implement `nearestSnapPoint` in FocusMode.swift**

Add at the end of `Sources/Core/FocusMode.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run RunTests 2>&1`
Expected: all tests pass including the new `nearestSnapPoint` tests

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/FocusMode.swift Tests/CoreTests/main.swift
git commit -m "feat: add nearestSnapPoint pure helper for gesture snap targeting"
```

---

### Task 2: Add pure helper — `columnIndexAtStripX`

**Files:**
- Modify: `Sources/Core/FocusMode.swift`
- Modify: `Tests/CoreTests/main.swift`

- [ ] **Step 1: Write failing tests for `columnIndexAtStripX`**

Add after the `nearestSnapPoint` tests (still before the final summary block):

```swift
section("columnIndexAtStripX — hits first column")
do {
    // 3 columns of width 720, gap 16. Col 0: [0, 720), Col 1: [736, 1456), Col 2: [1472, 2192)
    let columnWidths: [Double] = [720, 720, 720]
    let idx = columnIndexAtStripX(100, columnWidths: columnWidths, gap: 16)
    assertEq(idx, 0, "inside first column")
}

section("columnIndexAtStripX — hits second column")
do {
    let columnWidths: [Double] = [720, 720, 720]
    let idx = columnIndexAtStripX(800, columnWidths: columnWidths, gap: 16)
    assertEq(idx, 1, "inside second column")
}

section("columnIndexAtStripX — in gap picks nearest column")
do {
    // Gap between col 0 and col 1 is [720, 736). Midpoint = 728.
    let columnWidths: [Double] = [720, 720, 720]
    let idxLeft = columnIndexAtStripX(724, columnWidths: columnWidths, gap: 16)
    assertEq(idxLeft, 0, "in gap, closer to left column")
    let idxRight = columnIndexAtStripX(732, columnWidths: columnWidths, gap: 16)
    assertEq(idxRight, 1, "in gap, closer to right column")
}

section("columnIndexAtStripX — before strip")
do {
    let columnWidths: [Double] = [720, 720]
    let idx = columnIndexAtStripX(-100, columnWidths: columnWidths, gap: 16)
    assertEq(idx, 0, "clamp to first")
}

section("columnIndexAtStripX — past end of strip")
do {
    let columnWidths: [Double] = [720, 720]
    let idx = columnIndexAtStripX(5000, columnWidths: columnWidths, gap: 16)
    assertEq(idx, 1, "clamp to last")
}

section("columnIndexAtStripX — single column")
do {
    let idx = columnIndexAtStripX(999, columnWidths: [720], gap: 16)
    assertEq(idx, 0, "only column")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run RunTests 2>&1`
Expected: compilation error — `columnIndexAtStripX` is not defined

- [ ] **Step 3: Implement `columnIndexAtStripX` in FocusMode.swift**

Add at the end of `Sources/Core/FocusMode.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run RunTests 2>&1`
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/FocusMode.swift Tests/CoreTests/main.swift
git commit -m "feat: add columnIndexAtStripX pure helper for cursor-based column selection"
```

---

### Task 3: Add coordinate conversion test

**Files:**
- Modify: `Tests/CoreTests/main.swift`

- [ ] **Step 1: Write the coordinate conversion test**

This validates the formula `cursorStripX = (cursorScreenX - wa.minX) + columnX(activeColumnIndex) + state.currentOffset`. Add after the `columnIndexAtStripX` tests:

```swift
section("Cursor-to-strip coordinate conversion")
do {
    // Setup: 3 columns, 720px each, gap 16, screen at x=0 width 1440
    // Active column = 1 (at stripX = 736), viewOffset = -360 (centered)
    // viewPos = 736 + (-360) = 376
    // Screen shows strip from x=376 to x=1816
    // Cursor at screen center (720) should map to stripX = 720 - 0 + 736 + (-360) = 1096
    // That's inside column 1 [736, 1456) ✓
    let wa = CGRect(x: 0, y: 25, width: 1440, height: 875)
    let cursorScreenX: Double = 720
    let activeColX: Double = 736  // columnX(at: 1) = 720 + 16
    let viewOffset: Double = -360
    let cursorStripX = (cursorScreenX - wa.minX) + activeColX + viewOffset
    assertClose(cursorStripX, 1096, tolerance: 0.01, "cursor at screen center maps into column 1")

    let idx = columnIndexAtStripX(cursorStripX, columnWidths: [720, 720, 720], gap: 16)
    assertEq(idx, 1, "column under cursor is column 1")
}

section("Cursor-to-strip — secondary display offset")
do {
    // Screen at x=1440 (secondary display), width 1440
    // Active column = 0 (stripX = 0), viewOffset = -360 (centered)
    // Cursor at screen midpoint = 1440 + 720 = 2160
    // cursorStripX = (2160 - 1440) + 0 + (-360) = 360
    // That's inside column 0 [0, 720) ✓
    let wa = CGRect(x: 1440, y: 25, width: 1440, height: 875)
    let cursorScreenX: Double = 2160
    let activeColX: Double = 0
    let viewOffset: Double = -360
    let cursorStripX = (cursorScreenX - wa.minX) + activeColX + viewOffset
    assertClose(cursorStripX, 360, tolerance: 0.01, "secondary display cursor maps correctly")

    let idx = columnIndexAtStripX(cursorStripX, columnWidths: [720, 720], gap: 16)
    assertEq(idx, 0, "column under cursor is column 0")
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `swift run RunTests 2>&1`
Expected: all tests pass (this is a formula validation test, not TDD — the formula is pure math)

- [ ] **Step 3: Commit**

```bash
git add Tests/CoreTests/main.swift
git commit -m "test: add cursor-to-strip coordinate conversion tests"
```

---

### Task 4: Add `gestureSnap` config property and parsing

**Files:**
- Modify: `Sources/Config/Config.swift:39` (add property)
- Modify: `Sources/Config/Config.swift:230-232` (add parsing in `[gesture]` block)
- Modify: `config.default.toml:43` (add default value)

- [ ] **Step 1: Add `gestureSnap` property to `ScrollWMConfig`**

In `Sources/Config/Config.swift`, after line 39 (`public var gestureModifier: String = "fn"`), add:

```swift
    public var gestureSnap: Bool = true
```

- [ ] **Step 2: Parse `snap` from `[gesture]` table**

In `Sources/Config/Config.swift`, in the `[gesture]` parsing block (line 231), add the parsing line so the block becomes:

```swift
        // [gesture]
        if let gesture = table["gesture"] as? TOMLTable {
            if let v = readString(gesture["modifier"]) { config.gestureModifier = v }
            if let v = readBool(gesture["snap"]) { config.gestureSnap = v }
        }
```

- [ ] **Step 3: Add default to `config.default.toml`**

In `config.default.toml`, after line 43 (`modifier = "fn"  # Hold this key + trackpad scroll to pan the strip`), add:

```toml
snap = true  # Set to false to let gestures move freely without snapping to columns
```

- [ ] **Step 4: Build to verify no compilation errors**

Run: `swift build 2>&1`
Expected: build succeeds

- [ ] **Step 5: Commit**

```bash
git add Sources/Config/Config.swift config.default.toml
git commit -m "feat: add gesture snap config option ([gesture] snap = true)"
```

---

### Task 5: Propagate `gestureSnap` to `StripController`

**Files:**
- Modify: `Sources/WindowManager/StripController.swift:22` (add property)
- Modify: `Sources/WindowManager/WindowManager.swift:93-103` (propagate in `applyConfig`)

- [ ] **Step 1: Add property to `StripController`**

In `Sources/WindowManager/StripController.swift`, after line 22 (`public var animationEnabled: Bool = false`), add:

```swift
    /// Whether trackpad gestures snap to columns after flick.
    public var gestureSnap: Bool = true
```

- [ ] **Step 2: Propagate in `WindowManager.applyConfig`**

In `Sources/WindowManager/WindowManager.swift`, after line 102 (`sc.animationEnabled = config.animationEnabled`), add:

```swift
            sc.gestureSnap = config.gestureSnap
```

- [ ] **Step 3: Update the config log line**

In `Sources/WindowManager/WindowManager.swift`, update the print statement at line 131:

Change:
```swift
        print("[WM] Config applied (gap=\(config.gap), snap=\(config.snapPoints), animation=\(config.animationEnabled))")
```

To:
```swift
        print("[WM] Config applied (gap=\(config.gap), snap=\(config.snapPoints), gestureSnap=\(config.gestureSnap), animation=\(config.animationEnabled))")
```

- [ ] **Step 4: Build to verify**

Run: `swift build 2>&1`
Expected: build succeeds

- [ ] **Step 5: Commit**

```bash
git add Sources/WindowManager/StripController.swift Sources/WindowManager/WindowManager.swift
git commit -m "feat: propagate gestureSnap config to StripController"
```

---

### Task 6: Refactor `handleGestureEnd` with cursor-based column selection and snap branching

**Files:**
- Modify: `Sources/WindowManager/StripController.swift:541-602`

- [ ] **Step 1: Add `columnUnderCursor` helper method**

Add this new method in `StripController`, after the `handleGestureCancel()` method (after line 575):

```swift
    /// Determine which column is under the cursor, using the current gesture offset.
    /// Falls back to the current activeColumnIndex if the cursor is outside the working area.
    private func columnUnderCursor(gestureOffset: Double) -> Int {
        guard !strip.columns.isEmpty else { return strip.activeColumnIndex }

        let cursorScreenX = NSEvent.mouseLocation.x
        let wa = strip.workingArea

        // If cursor is outside the working area X range, keep current active column
        guard cursorScreenX >= wa.minX && cursorScreenX <= wa.maxX else {
            return strip.activeColumnIndex
        }

        // Convert screen X to strip-space X:
        // From LayoutEngine: screenX = stripX - viewPos + wa.minX
        // viewPos = columnX(activeColumnIndex) + viewOffset
        // So: stripX = (screenX - wa.minX) + columnX(activeColumnIndex) + viewOffset
        let cursorStripX = (cursorScreenX - wa.minX)
            + strip.columnX(at: strip.activeColumnIndex)
            + gestureOffset

        let columnWidths = strip.columnData.map(\.currentWidth)
        return columnIndexAtStripX(cursorStripX, columnWidths: columnWidths, gap: strip.gap)
    }
```

- [ ] **Step 2: Replace `handleGestureEnd` and `snapToNearestColumnEdge`**

Replace the entire `handleGestureEnd` method (lines 540-565) and `snapToNearestColumnEdge` method (lines 577-602) with:

```swift
    /// End a gesture — start momentum animation or stop.
    public func handleGestureEnd(time: Double) {
        guard case .gesture(let state) = strip.viewOffset else { return }
        let velocity = state.tracker.velocity()

        if abs(velocity) > 50 {
            let projected = state.tracker.projectedEndPosition(isTouchpad: state.isTouchpad)

            // Determine active column by cursor position (before creating spring)
            strip.activeColumnIndex = columnUnderCursor(gestureOffset: state.currentOffset)

            if gestureSnap {
                // Snap to nearest configured snap point for the target column
                let (snapIdx, snapOffset) = nearestSnapPoint(
                    projectedOffset: projected,
                    snapPoints: strip.snapPoints,
                    columnWidth: strip.columnData[strip.activeColumnIndex].currentWidth,
                    workingAreaWidth: strip.workingArea.width
                )
                strip.snapIndices[strip.activeColumnIndex] = snapIdx

                let anim = SpringAnimation(
                    from: state.currentOffset,
                    to: snapOffset,
                    initialVelocity: velocity,
                    startTime: time,
                    params: .horizontalScroll
                )
                strip.viewOffset = .animation(anim)
            } else {
                // Free scroll — animate to projected position, no column alignment
                let anim = SpringAnimation(
                    from: state.currentOffset,
                    to: projected,
                    initialVelocity: velocity,
                    startTime: time,
                    params: .horizontalScroll
                )
                strip.viewOffset = .animation(anim)
            }
            // Frame loop continues to tick
        } else {
            // No significant velocity — just stop
            strip.viewOffset = .static(state.currentOffset)
            frameLoop?.pause()
            clearCommittedFrames()
            applyLayout()
        }
    }
```

- [ ] **Step 3: Remove the old `snapToNearestColumnEdge` method**

Delete the `snapToNearestColumnEdge` method entirely (the block from `/// Snap a scroll offset to the nearest column edge for the active column.` through the closing `}`). It is fully replaced by the new logic in `handleGestureEnd`.

- [ ] **Step 4: Build to verify**

Run: `swift build 2>&1`
Expected: build succeeds

- [ ] **Step 5: Run existing tests to verify no regressions**

Run: `swift run RunTests 2>&1`
Expected: all tests pass

- [ ] **Step 6: Commit**

```bash
git add Sources/WindowManager/StripController.swift
git commit -m "feat: refactor handleGestureEnd with cursor-based column selection and snap branching"
```

---

### Task 7: Manual smoke test

**Files:** None (manual testing)

- [ ] **Step 1: Build and run**

Run: `swift build && .build/debug/ScrollWM &`

- [ ] **Step 2: Test `snap = true` (default)**

Open 3+ windows. Hold Fn + trackpad flick. Verify:
- Windows snap to a column position after the flick
- The column under the cursor becomes active (check focus ring)
- If `layout.snap = ["left", "middle", "right"]`, the snap point is the nearest to where momentum would have landed

- [ ] **Step 3: Test `snap = false`**

Edit `~/.config/scrollwm/config.toml`, set `snap = false` under `[gesture]`. Save (auto-reloads). Hold Fn + trackpad flick. Verify:
- Windows animate to wherever momentum carries them — no column alignment
- Focus ring shows on the column that was under the cursor at release

- [ ] **Step 4: Test low-velocity gesture**

For both `snap = true` and `snap = false`: slowly drag with Fn held and release gently. Verify the strip freezes in place (no snap animation).

- [ ] **Step 5: Test keyboard after free-scroll**

With `snap = false`, do a free-scroll flick. Then press Hyper-L. Verify keyboard navigation snaps to the default snap position of the active column — this is expected and correct.
