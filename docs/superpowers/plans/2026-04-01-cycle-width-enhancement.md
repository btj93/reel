# Cycle Width Enhancement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Animate `cycle_width` transitions using existing spring infrastructure and let users configure width presets via TOML.

**Architecture:** Fix the broken `ColumnData.currentWidth` to be time-aware, then wire `widthAnimation` into `cycleWidthPreset`. Add `width_presets` TOML parsing. Both width and scroll springs run concurrently during a cycle.

**Tech Stack:** Swift, CoreGraphics, TOMLKit, SpringAnimation

---

### Task 1: Fix `ColumnData.currentWidth` to accept `time:`

**Files:**
- Modify: `Sources/Core/Column.swift:50-55`

- [ ] **Step 1: Write the failing test**

Add to `Tests/CoreTests/main.swift` before the final summary block (before line 731):

```swift
// MARK: - Width Animation Tests
print()
print("Width Animation Tests")

section("currentWidth(at:) returns animated value")
do {
    let params = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)
    let anim = SpringAnimation(from: 360, to: 720, startTime: 0, params: params)
    var data = ColumnData(cachedWidth: 720, widthAnimation: anim)
    // At t=0, should return the start value (360), not the target
    let val0 = data.currentWidth(at: 0)
    assertClose(val0, 360, tolerance: 1.0, "currentWidth at t=0 should be start value")
    // At t=2.0, spring should be settled, should return cachedWidth
    let valEnd = data.currentWidth(at: 2.0)
    assertClose(valEnd, 720, tolerance: 1.0, "currentWidth at t=2.0 should be target")
    // With no animation, returns cachedWidth
    data.widthAnimation = nil
    let valStatic = data.currentWidth(at: 0)
    assertClose(valStatic, 720, tolerance: 0.01, "no animation returns cachedWidth")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run RunTests 2>&1 | tail -20`
Expected: Compile error — `currentWidth` has no `at:` parameter yet.

- [ ] **Step 3: Convert `currentWidth` from computed property to method**

In `Sources/Core/Column.swift`, replace lines 49-55:

```swift
    /// Current effective width (reads animation if active).
    public var currentWidth: Double {
        if let anim = widthAnimation, !anim.isDone {
            return anim.currentValue
        }
        return cachedWidth
    }
```

With:

```swift
    /// Current effective width at a given time (reads animation if active).
    public func currentWidth(at time: Double) -> Double {
        if let anim = widthAnimation {
            if anim.isDone(at: time) { return cachedWidth }
            return anim.evaluate(at: time).value
        }
        return cachedWidth
    }
```

- [ ] **Step 4: Run test — expect compile errors from call sites**

Run: `swift build 2>&1 | grep "currentWidth"`
Expected: Multiple compile errors in Strip.swift, LayoutEngine.swift, FocusMode.swift. This is expected — Task 2 fixes them.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Column.swift Tests/CoreTests/main.swift
git commit -m "feat: convert currentWidth to time-aware method

The computed property always returned the target value due to
SpringAnimation.currentValue being a placeholder. Now uses
evaluate(at:) for correct interpolation during animation."
```

---

### Task 2: Update all `currentWidth` call sites

**Files:**
- Modify: `Sources/Core/Strip.swift` (lines 75, 122, 132, 163, 177, 189, 283, 298, 322, 337, 365, 379, 401, 415)
- Modify: `Sources/Core/LayoutEngine.swift` (lines 64, 88)
- Modify: `Sources/Core/FocusMode.swift` (lines 126, 149)
- Modify: `Sources/WindowManager/StripController.swift` (lines 422, 594, 681)

All these call sites already have `time` available in scope (either as a parameter or computable). This is a mechanical find-and-replace.

- [ ] **Step 1: Update `Strip.swift`**

In `Sources/Core/Strip.swift`:

**`totalWidth` (line 71)** — add `time` parameter:
```swift
    public func totalWidth(at time: Double) -> Double {
        guard !columnData.isEmpty else { return 0 }
        var w: Double = 0
        for data in columnData {
            w += data.currentWidth(at: time)
        }
        w += Double(max(0, columnData.count - 1)) * gap
        return w
    }
```

**`insertColumn` (line 122)** — use `currentWidth(at: time)`:
```swift
            columnWidth: columnData[activeColumnIndex].currentWidth(at: time),
```

**`removeColumn` (line 132)** — use `currentWidth(at: time)`:
```swift
        let removedWidth = columnData[index].currentWidth(at: time) + gap
```

**`removeColumn` (line 163)** — use `currentWidth(at: time)`:
```swift
            columnWidth: columnData[activeColumnIndex].currentWidth(at: time),
```

**`recenterActiveColumn` (line 177)** — use `currentWidth(at: time)`:
```swift
            columnWidth: columnData[activeColumnIndex].currentWidth(at: time),
```

**`recenterActiveColumnAnimated` (line 189)** — use `currentWidth(at: time)`:
```swift
            columnWidth: columnData[activeColumnIndex].currentWidth(at: time),
```

**`navigateRight` (line 283)** — use `currentWidth(at: time)`:
```swift
            let colWidth = columnData[activeColumnIndex].currentWidth(at: time)
```

**`navigateRight` (line 298)** — use `currentWidth(at: time)`:
```swift
            let newColWidth = columnData[activeColumnIndex].currentWidth(at: time)
```

**`navigateLeft` (line 322)** — use `currentWidth(at: time)`:
```swift
            let colWidth = columnData[activeColumnIndex].currentWidth(at: time)
```

**`navigateLeft` (line 337)** — use `currentWidth(at: time)`:
```swift
            let newColWidth = columnData[activeColumnIndex].currentWidth(at: time)
```

**`navigateRightInstant` (line 365)** — use `currentWidth(at: time)`:
```swift
            let newColWidth = columnData[activeColumnIndex].currentWidth(at: time)
```

**`navigateRightInstant` (line 379)** — use `currentWidth(at: time)`:
```swift
        let colWidth = columnData[activeColumnIndex].currentWidth(at: time)
```

**`navigateLeftInstant` (line 401)** — use `currentWidth(at: time)`:
```swift
            let newColWidth = columnData[activeColumnIndex].currentWidth(at: time)
```

**`navigateLeftInstant` (line 415)** — use `currentWidth(at: time)`:
```swift
        let colWidth = columnData[activeColumnIndex].currentWidth(at: time)
```

- [ ] **Step 2: Update `FocusMode.swift`**

In `Sources/Core/FocusMode.swift`:

**`computeColumnX` (line 149)** — add `time` parameter:
```swift
public func computeColumnX(
    at index: Int,
    columnData: [ColumnData],
    gap: Double,
    time: Double
) -> Double {
    var x: Double = 0
    for i in 0..<index {
        x += columnData[i].currentWidth(at: time) + gap
    }
    return x
}
```

**`columnIndexAtStripX` ColumnData overload (line 126)** — add `time` parameter:
```swift
public func columnIndexAtStripX(
    _ stripX: Double,
    columnData: [ColumnData],
    gap: Double,
    time: Double
) -> Int {
    guard !columnData.isEmpty else { return 0 }

    var x: Double = 0
    for i in 0..<columnData.count {
        let colEnd = x + columnData[i].currentWidth(at: time)
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
```

- [ ] **Step 3: Update `LayoutEngine.swift`**

In `Sources/Core/LayoutEngine.swift`, update lines 64 and 88 to pass `time`:
```swift
        let colWidth = strip.columnData[i].currentWidth(at: time)
```
(Both occurrences — the `time` parameter is already available from the function signature.)

- [ ] **Step 4: Update `Strip.columnX` to pass time**

`Strip.columnX(at:)` calls `computeColumnX` which now needs `time`. Add a `time` parameter:

In `Sources/Core/Strip.swift`, replace line 88-90:
```swift
    public func columnX(at index: Int) -> Double {
        computeColumnX(at: index, columnData: columnData, gap: gap)
    }
```
With:
```swift
    public func columnX(at index: Int, time: Double = 0) -> Double {
        computeColumnX(at: index, columnData: columnData, gap: gap, time: time)
    }
```

Then update all `columnX` call sites in Strip.swift that have `time` available:
- `viewPos(at:)` line 94: `columnX(at: activeColumnIndex, time: time)`
- `navigateRight` line 294, 296: `columnX(at: ..., time: time)`
- `navigateLeft` line 333, 335: `columnX(at: ..., time: time)`
- `navigateRightInstant` line 361, 363: `columnX(at: ..., time: time)`
- `navigateLeftInstant` line 397, 399: `columnX(at: ..., time: time)`

And in `StripController.swift`:
- `handleFrameTick` line 509, 512: `strip.columnX(at: ..., time: time)`
- `handleGestureEnd` line 638, 641: `strip.columnX(at: ..., time: time)`
- `handleGestureCancel` line 653 (use `currentTime()`)
- `columnUnderCursor` line 678: `strip.columnX(at: ..., time: currentTime())`
- `scrollToWindow` line 422: pass `time` (capture `currentTime()` at top)

- [ ] **Step 5: Build and run tests**

Run: `swift run RunTests 2>&1 | tail -20`
Expected: All existing tests pass. The new `currentWidth(at:)` test from Task 1 also passes.

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/Strip.swift Sources/Core/LayoutEngine.swift Sources/Core/FocusMode.swift Sources/WindowManager/StripController.swift
git commit -m "refactor: update all currentWidth call sites to pass time

Mechanical change: every read of columnData[i].currentWidth now
passes the time parameter, enabling width animations in the next step."
```

---

### Task 3: Animate `cycleWidthPreset` in Strip

**Files:**
- Modify: `Sources/Core/Strip.swift:446-456`

- [ ] **Step 1: Write the failing test**

Add to `Tests/CoreTests/main.swift` in the "Width Animation Tests" section:

```swift
section("cycleWidthPreset animated — creates width spring")
do {
    var strip = makeStrip(columnCount: 1)
    strip.widthPresets = [.proportion(0.25), .proportion(0.5), .proportion(0.75)]
    // Column starts at 0.5 width (720px on 1440 screen)
    let oldWidth = strip.columnData[0].cachedWidth
    assertClose(oldWidth, 720, tolerance: 1.0, "starts at 720")

    let params = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)
    strip.cycleWidthPreset(at: 0, params: params)

    // presetIndex should be 0 (first preset: 0.25)
    assertEq(strip.columns[0].presetIndex, 0)
    // cachedWidth should be the target (0.25 * 1440 = 360)
    assertClose(strip.columnData[0].cachedWidth, 360, tolerance: 1.0, "cachedWidth is target")
    // widthAnimation should be non-nil
    check(strip.columnData[0].widthAnimation != nil, "widthAnimation should be set")
    // currentWidth at t=0 should be the OLD width (720)
    assertClose(strip.columnData[0].currentWidth(at: 0), 720, tolerance: 1.0, "animated from old")
    // currentWidth at t=2.0 should converge to target (360)
    assertClose(strip.columnData[0].currentWidth(at: 2.0), 360, tolerance: 1.0, "converges to target")
}

section("cycleWidthPreset animated — rapid retarget preserves velocity")
do {
    var strip = makeStrip(columnCount: 1)
    strip.widthPresets = [.proportion(0.25), .proportion(0.5), .proportion(0.75)]
    let params = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)

    // First cycle at t=0
    strip.cycleWidthPreset(at: 0, params: params)
    // Second cycle at t=0.05 (mid-animation)
    strip.cycleWidthPreset(at: 0.05, params: params)

    assertEq(strip.columns[0].presetIndex, 1, "second preset")
    let anim = strip.columnData[0].widthAnimation!
    check(anim.initialVelocity != 0, "velocity should be preserved from first spring")
}

section("cycleWidthPreset non-animated — no widthAnimation")
do {
    var strip = makeStrip(columnCount: 1)
    strip.widthPresets = [.proportion(0.25), .proportion(0.5), .proportion(0.75)]
    strip.cycleWidthPreset(at: 0, params: nil)
    assertEq(strip.columns[0].presetIndex, 0)
    assertClose(strip.columnData[0].cachedWidth, 360, tolerance: 1.0)
    check(strip.columnData[0].widthAnimation == nil, "no animation when params is nil")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run RunTests 2>&1 | tail -20`
Expected: Compile error — `cycleWidthPreset` doesn't accept `at:params:` yet.

- [ ] **Step 3: Replace `cycleWidthPreset` with animated version**

In `Sources/Core/Strip.swift`, replace lines 446-456:

```swift
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
```

With:

```swift
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
```

- [ ] **Step 4: Update the existing test to use new signature**

In `Tests/CoreTests/main.swift`, update the existing "Cycle width preset" test (around line 146) to use the new signature:

```swift
section("Cycle width preset")
do {
    var strip = makeStrip(columnCount: 1)
    strip.widthPresets = [.proportion(0.33), .proportion(0.5), .proportion(0.67)]
    strip.cycleWidthPreset(at: 0, params: nil)
    assertEq(strip.columns[0].presetIndex, 0)
    strip.cycleWidthPreset(at: 0, params: nil)
    assertEq(strip.columns[0].presetIndex, 1)
    strip.cycleWidthPreset(at: 0, params: nil)
    assertEq(strip.columns[0].presetIndex, 2)
    strip.cycleWidthPreset(at: 0, params: nil)
    assertEq(strip.columns[0].presetIndex, 0, "should wrap")
}
```

- [ ] **Step 5: Run tests**

Run: `swift run RunTests 2>&1 | tail -20`
Expected: All tests pass including the new animation tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/Strip.swift Tests/CoreTests/main.swift
git commit -m "feat: animate cycleWidthPreset with spring transition

Uses widthAnimation on ColumnData for smooth width changes.
Supports retargeting for rapid cycling (velocity preservation).
Pass params=nil for instant mode (non-animated path)."
```

---

### Task 4: Add `recenterActiveColumnAnimated` width override

**Files:**
- Modify: `Sources/Core/Strip.swift:184-193`

- [ ] **Step 1: Add `columnWidth` override parameter**

In `Sources/Core/Strip.swift`, replace `recenterActiveColumnAnimated`:

```swift
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
```

No test needed — existing behavior unchanged with default nil. The override is tested indirectly via StripController in Task 5.

- [ ] **Step 2: Build to verify no regressions**

Run: `swift run RunTests 2>&1 | tail -5`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/Core/Strip.swift
git commit -m "feat: add columnWidth override to recenterActiveColumnAnimated

Allows StripController to pass the target width so the scroll
animation aims at the correct final position during width cycles."
```

---

### Task 5: Wire up `StripController.cycleWidthPreset` and `handleFrameTick`

**Files:**
- Modify: `Sources/WindowManager/StripController.swift:260-272` (cycleWidthPreset)
- Modify: `Sources/WindowManager/StripController.swift:499-524` (handleFrameTick)

- [ ] **Step 1: Add width animation settlement helper to Strip**

In `Sources/Core/Strip.swift`, add after `recalculateWidths()` (line 484):

```swift
    /// Whether any column has an active width animation.
    public func hasActiveWidthAnimations(at time: Double) -> Bool {
        for data in columnData {
            if let anim = data.widthAnimation, !anim.isDone(at: time) {
                return true
            }
        }
        return false
    }

    /// Finalize all completed width animations (nil out done springs).
    public mutating func settleWidthAnimations(at time: Double) {
        for i in 0..<columnData.count {
            if let anim = columnData[i].widthAnimation, anim.isDone(at: time) {
                columnData[i].widthAnimation = nil
            }
        }
    }
```

- [ ] **Step 2: Update `StripController.cycleWidthPreset`**

Replace `StripController.cycleWidthPreset()` (lines 260-272):

```swift
    public func cycleWidthPreset() {
        let time = currentTime()
        if animationEnabled {
            let params = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)
            strip.cycleWidthPreset(at: time, params: params)
            let targetWidth = strip.columnData[strip.activeColumnIndex].cachedWidth
            if let _ = strip.recenterActiveColumnAnimated(at: time, columnWidth: targetWidth) {
                frameLoop?.resume()
            } else {
                // Scroll didn't need animation, but width does
                frameLoop?.resume()
            }
        } else {
            strip.cycleWidthPreset(at: time, params: nil)
            strip.recenterActiveColumn(at: time)
            applyLayout()
        }
    }
```

- [ ] **Step 3: Update `handleFrameTick` settlement check**

Replace the settlement block in `handleFrameTick` (lines 499-524):

```swift
    public func handleFrameTick(time: Double) {
        // Settle any completed width animations
        strip.settleWidthAnimations(at: time)

        let scrollSettled = strip.viewOffset.isSettled(at: time)
        let widthSettled = !strip.hasActiveWidthAnimations(at: time)

        // Check if all animations have settled
        if scrollSettled && widthSettled {
            let finalOffset = strip.viewOffset.current(at: time)

            // After gesture momentum settles, re-anchor focus to the cursor column.
            if gestureAnimating {
                gestureAnimating = false
                let viewPos = strip.columnX(at: strip.activeColumnIndex, time: time) + finalOffset
                let newActive = columnUnderCursor(gestureOffset: finalOffset)
                strip.activeColumnIndex = newActive
                let adjustedOffset = viewPos - strip.columnX(at: newActive, time: time)
                strip.viewOffset = .static(adjustedOffset)
            } else {
                strip.viewOffset = .static(finalOffset)
            }

            frameLoop?.pause()

            // One final layout with exact positions + full setFrame
            clearCommittedFrames()
            applyLayout()
            return
        }
```

The rest of `handleFrameTick` (lines 526-562, the per-frame dispatch) stays unchanged — `computeTargetFrames` already reads `currentWidth(at: time)` which includes the animating width.

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Strip.swift Sources/WindowManager/StripController.swift
git commit -m "feat: wire animated cycle_width in StripController

Width and scroll springs run concurrently. Frame loop waits for
both to settle before pausing. Non-animated path unchanged."
```

---

### Task 6: Clear `widthAnimation` in `toggleFullWidth` and `handleUserResize`

**Files:**
- Modify: `Sources/Core/Strip.swift:458-471` (toggleFullWidth)
- Modify: `Sources/WindowManager/StripController.swift:385-387` (handleUserResize)

- [ ] **Step 1: Clear in `toggleFullWidth`**

In `Sources/Core/Strip.swift`, add `widthAnimation = nil` in `toggleFullWidth()`. Replace:

```swift
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
```

With:

```swift
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
```

- [ ] **Step 2: Clear in `handleUserResize`**

In `Sources/WindowManager/StripController.swift`, after line 386 (`strip.columns[colIndex].presetIndex = nil`), add:

```swift
        strip.columnData[colIndex].widthAnimation = nil
```

- [ ] **Step 3: Build and run tests**

Run: `swift run RunTests 2>&1 | tail -5`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/Core/Strip.swift Sources/WindowManager/StripController.swift
git commit -m "fix: clear widthAnimation on toggleFullWidth and user resize

Any direct write to cachedWidth must cancel in-flight width
animations to prevent stale springs from overriding the new value."
```

---

### Task 7: Clear `widthAnimation` on space save

**Files:**
- Modify: `Sources/WindowManager/StripController.swift:745-757` (saveCurrentSpace)

- [ ] **Step 1: Clear width animations before saving**

Replace `saveCurrentSpace()`:

```swift
    public func saveCurrentSpace() {
        guard !currentSpaceFingerprint.isEmpty else { return }
        // Clear any in-flight width animations — stale springs with old startTimes
        // would evaluate incorrectly when restored later.
        for i in 0..<strip.columnData.count {
            strip.columnData[i].widthAnimation = nil
        }
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

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/WindowManager/StripController.swift
git commit -m "fix: clear widthAnimation before saving space state

Prevents stale springs with old startTimes from being replayed
incorrectly when the user returns to a Space later."
```

---

### Task 8: Parse `width_presets` from TOML config

**Files:**
- Modify: `Sources/Config/Config.swift:182-221` (parse layout section)
- Modify: `config.default.toml`

- [ ] **Step 1: Write the test**

Add to `Tests/CoreTests/main.swift` in the "Width Animation Tests" section:

```swift
section("Config — parse width_presets from TOML")
do {
    // We can't test Config.parse directly (it depends on TOMLKit),
    // but we verify that the ColumnWidth proportions resolve correctly.
    let presets: [ColumnWidth] = [.proportion(0.25), .proportion(0.5), .proportion(0.75), .proportion(1.0)]
    let resolved = presets.map { $0.resolve(workingAreaWidth: 1440, gap: 16) }
    assertClose(resolved[0], 360, tolerance: 0.01, "0.25 preset")
    assertClose(resolved[1], 720, tolerance: 0.01, "0.5 preset")
    assertClose(resolved[2], 1080, tolerance: 0.01, "0.75 preset")
    assertClose(resolved[3], 1440, tolerance: 0.01, "1.0 preset")
}
```

- [ ] **Step 2: Add parsing in `Config.parse`**

In `Sources/Config/Config.swift`, inside the `if let layout = readTable(table["layout"])` block (after the struts parsing, around line 218), add:

```swift
            if let presetsArray = readArray(layout["width_presets"]) {
                var presets: [ColumnWidth] = []
                for item in presetsArray {
                    if let v = readDouble(item), v > 0, v <= 1 {
                        presets.append(.proportion(v))
                    } else {
                        print("[Config] Warning: skipping invalid width_preset value")
                        fflush(stdout)
                    }
                }
                if !presets.isEmpty {
                    config.widthPresets = presets
                }
            }
```

- [ ] **Step 3: Add commented example to `config.default.toml`**

In `config.default.toml`, after the `animation_enabled` line (line 10), add:

```toml
# width_presets = [0.33, 0.5, 0.67]  # proportions of screen width for cycle_width
```

- [ ] **Step 4: Build and run tests**

Run: `swift run RunTests 2>&1 | tail -5`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Config/Config.swift config.default.toml Tests/CoreTests/main.swift
git commit -m "feat: parse width_presets from TOML config

Users can now set width_presets = [0.25, 0.5, 0.75, 1.0] in
[layout] to customize the cycle_width proportions. Values must
be > 0 and <= 1. Falls back to default if all values are invalid."
```

---

### Task 9: Clamp `presetIndex` on config reload

**Files:**
- Modify: `Sources/WindowManager/WindowManager.swift:93-103`

- [ ] **Step 1: Add `presetIndex` clamping after `widthPresets` update**

In `Sources/WindowManager/WindowManager.swift`, in the `applyConfig` method, after `sc.strip.widthPresets = config.widthPresets` (line 96), add:

```swift
            // Nil out preset indices that are out of range for the new presets
            for i in 0..<sc.strip.columns.count {
                if let idx = sc.strip.columns[i].presetIndex, idx >= config.widthPresets.count {
                    sc.strip.columns[i].presetIndex = nil
                }
            }
```

Do the same in the second `applyConfig` block (around line 391) — there are two places where `widthPresets` is set.

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/WindowManager/WindowManager.swift
git commit -m "fix: clamp presetIndex when width_presets shrinks on reload

Prevents index-out-of-bounds if the user reduces the number of
width presets while columns have higher preset indices."
```

---

### Task 10: Final integration test

- [ ] **Step 1: Run all tests**

Run: `swift run RunTests 2>&1`
Expected: All tests pass.

- [ ] **Step 2: Build the full project**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds with no warnings related to our changes.

- [ ] **Step 3: Commit (if any fixups needed)**

Only if there were fixups from the integration test.
