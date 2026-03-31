# Snap Points Design Spec

**Date:** 2026-03-31
**Status:** Draft

## Summary

Add configurable snap points to ScrollWM so keyboard navigation cycles a window through discrete screen positions (left, middle, right) before moving focus to the next window. This replaces the existing `focus_mode` config with a more flexible `snap` array.

## Motivation

Today, pressing Hyper+H/L always changes focus to the adjacent column and centers it on screen. Users want finer control over window positioning — for example, snapping the current window to the left edge of the screen to reveal what's behind it, before moving focus. The snap feature adds this flexibility while preserving the current default behavior with `snap = ["middle"]`.

## Config

```toml
[layout]
snap = ["middle"]  # default — equivalent to old focus_mode = "always"
# Accepts any combination of: "left", "middle", "right"
# Order doesn't matter — sorted spatially at load time
```

**Examples:**
- `snap = ["middle"]` — current behavior. Focus change centers the window.
- `snap = ["left", "middle", "right"]` — cycle through 3 positions before changing focus.
- `snap = ["left", "right"]` — two positions. Default snap is the closest to middle.

**Deprecation of `focus_mode`:** Parsed for backward compatibility and mapped to snap:
- `"always"` → `["middle"]`
- `"never"` → `["left"]` — **Note:** this is a lossy mapping. The old `"never"` meant "scroll minimum to keep the column visible" (edge-fit), not "always left-align." Users who relied on edge-fit behavior should migrate to `snap = ["left", "middle"]` or similar.
- `"on-overflow"` → `["middle"]`

If both `snap` and `focus_mode` are present, `snap` wins with a log warning. If `snap` is empty or has no valid entries, falls back to `["middle"]` with a warning.

## Data Model (Core)

### New type: `SnapPoint`

```swift
public enum SnapPoint: String, Sendable, Comparable {
    case left, middle, right

    // Swift doesn't auto-synthesize Comparable for String raw-value enums.
    // Explicit implementation ensures .sorted() produces spatial order.
    private var sortOrder: Int {
        switch self { case .left: 0; case .middle: 1; case .right: 2 }
    }
    public static func < (lhs: SnapPoint, rhs: SnapPoint) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}
```

`Comparable` with spatial ordering: `left < middle < right`.

### Strip changes

```swift
// Remove:
public var focusMode: CenterFocusedColumn

// Add:
public var snapPoints: [SnapPoint]  // sorted, from config (default: [.middle])
public var snapIndices: [Int]       // parallel to columns — current snap index per column
```

`snapIndices` is kept in sync with `columns`:
- Insert column → insert snap index at same position (set to default)
- Remove column → remove snap index at same position
- Swap columns (moveLeft/Right) → swap snap indices too

**Default snap index for new columns:** Index of `.middle` in `snapPoints`. If `.middle` isn't configured, use `(snapPoints.count - 1) / 2` (integer division — picks the left-of-center entry for even-length arrays, e.g., `["left", "right"]` → index 0 → `.left`).

### Offset computation: `computeSnapOffset`

Replaces `computeNewViewOffset` / `computeCenteredOffset` / `computeFitOffset`:

```swift
func computeSnapOffset(
    snapPoint: SnapPoint,
    columnWidth: Double,
    workingAreaWidth: Double
) -> Double {
    // Clamp so columns wider than working area don't produce positive offsets
    let slack = max(0, workingAreaWidth - columnWidth)
    switch snapPoint {
    case .left:   return 0              // col left edge = screen left edge
    case .middle: return -slack / 2     // col center = screen center
    case .right:  return -slack         // col right edge = screen right edge
    }
}
```

The existing centering math (`-(workingAreaWidth - columnWidth) / 2`) is the `.middle` case. For full-width columns, `slack = 0` and all three snap points collapse to offset 0 — this is correct and expected (the column fills the screen regardless of snap position).

## Navigation Logic

### `navigateRight` (animated variant, Hyper+L direction)

```
1. colWidth = columnData[activeColumnIndex].currentWidth
   currentSnap = snapIndices[activeColumnIndex]
2. if currentSnap < snapPoints.count - 1:
     // Advance snap point on current column
     snapIndices[activeColumnIndex] += 1
     targetOffset = computeSnapOffset(snapPoints[snapIndices[activeColumnIndex]],
                                      colWidth, screenWidth)
     animate to targetOffset
3. else:
     // Exhausted snap points — move focus to next column
     if activeColumnIndex < columns.count - 1:
       activeColumnIndex += 1
       newColWidth = columnData[activeColumnIndex].currentWidth  // use NEW column's width
       // DON'T advance the new column's snap — just snap to its current position.
       // The advance happens on the next same-direction keypress.
       targetOffset = computeSnapOffset(snapPoints[snapIndices[activeColumnIndex]],
                                        newColWidth, screenWidth)
       animate to targetOffset
     else:
       // Strip boundary — rubber-band bounce
       createRubberBandAnimation(direction: +1, at: time)
```

### `navigateLeft` (animated variant, Hyper+H direction)

Mirror of `navigateRight`:
- Decrement snap index if > 0, animate to new snap position
- Else (snap index already at 0) move focus left — snap to the new column's current snap index as-is (no decrement on arrival). The decrement happens on the next Hyper+H keypress.
- Else (leftmost column + snap index 0) rubber-band bounce: `createRubberBandAnimation(direction: -1, at: time)`

### Non-animated variants

Same logic, `viewOffset = .static(offset)` instead of spring animation.

### Behavior with `snap = ["middle"]` (backward compat)

- `snapPoints.count == 1`, so step 2 never triggers (currentSnap 0 is already at max index 0)
- Always falls through to step 3: move focus to next column
- New column's snap index is already 0 (default), and we don't advance it — stays at 0
- Offset = `computeSnapOffset(.middle, ...)` = `-(screenWidth - colWidth) / 2` — identical to old `focusMode = .always`

## Integration Points

### StripController

- `focusLeft()` / `focusRight()` → call `strip.navigateLeft()` / `strip.navigateRight()`
- `scrollToWindow(tileID:)` → set target column's snap index to default (middle)
- `handleGestureEnd` / `snapToNearestColumnEdge` → gestures ignore snap points. Inside `snapToNearestColumnEdge`, after setting `strip.activeColumnIndex = bestIndex`, also set `strip.snapIndices[bestIndex] = defaultSnapIndex`. This reset is intentional — after a free-scroll gesture, the snap index is treated as fresh regardless of where the column was before the gesture. The reset goes in `snapToNearestColumnEdge` (not at animation-settle time in `handleFrameTick`) because by settle time there's no clean way to distinguish gesture-settle from navigation-settle.
- `handleUserResize` debounced recenter → use current snap index (not always middle)
- `rebuildStrip()` → clear `strip.snapIndices` alongside `strip.columns` and `strip.columnData`
- `switchSpace()` → restore `snapIndices` from `SavedStripState`; if absent or wrong length (e.g., saved before this feature existed), initialize as `Array(repeating: defaultSnapIndex, count: columns.count)`
- `SavedStripState` → include `snapIndices` for Space save/restore

### WindowManager

- `applyConfig` → iterate **all** `stripControllers` (not just the active one) and set `strip.snapPoints` on each. This also fixes an existing bug where `focusMode` was only applied to the active display.

### Callers of `computeNewViewOffset` (all replaced)

| Caller | New behavior |
|--------|-------------|
| `Strip.insertColumn` | Default snap index → `computeSnapOffset` |
| `Strip.removeColumn` | Surviving column keeps snap index → `computeSnapOffset` |
| `Strip.recenterActiveColumn` | Current snap index → `computeSnapOffset` |
| `Strip.recenterActiveColumnAnimated` | Current snap index → `computeSnapOffset` (animated variant) |
| `Strip.navigateLeft/Right` | New snap index → `computeSnapOffset` |
| `StripController.scrollToWindow` | Default snap index → `computeSnapOffset` |
| `StripController.snapToNearestColumnEdge` | Default snap index → `computeSnapOffset` |

### Unchanged

- `ViewOffset`, `SpringAnimation`, `computeTargetFrames`, `LayoutEngine` — untouched
- Animation retargeting for rapid keypresses — works automatically
- Rubber-band bounce at strip edges — unchanged
- Off-screen sliver positioning — unchanged
- Trackpad gesture scrolling — unchanged (ignores snap points)

## Config Parsing

```swift
// In Config.swift, [layout] section:
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
    // Deduplicate, sort spatially
    config.snapPoints = Array(Set(points)).sorted()
}

// Backward compat: focus_mode → snap (only if snap not explicitly set)
if snapNotExplicitlySet {
    switch focusModeValue {
    case "always":      config.snapPoints = [.middle]
    case "never":       config.snapPoints = [.left]  // lossy — see deprecation note
    case "on-overflow": config.snapPoints = [.middle]
    }
    if snapNotExplicitlySet && focusModeValue != nil {
        print("[Config] Warning: focus_mode is deprecated, use snap instead")
    }
}

// Validation
if config.snapPoints.isEmpty {
    print("[Config] Warning: snap is empty, defaulting to [middle]")
    config.snapPoints = [.middle]
}
```

## Testing

All tests in `Tests/CoreTests/main.swift` using `section()` / `check()` / `assertEq()`.

1. **Snap offset math** — `computeSnapOffset` produces correct offsets for left/middle/right with various column/screen widths.

2. **navigateRight cycles snap points** — 3 snap points, 3 calls advance snap index left → middle → right without changing `activeColumnIndex`.

3. **navigateRight moves focus after exhausting snaps** — column at rightmost snap, next call changes `activeColumnIndex` and advances new column's snap.

4. **navigateLeft mirrors navigateRight** — same tests in opposite direction.

5. **New column gets default snap index** — insert column, verify snap index points to `.middle` (or nearest-to-middle).

6. **snap = [middle] matches old centering** — navigateRight behaves identically to old focusRight (immediate focus change, centered).

7. **Config order normalization** — `["right", "left", "middle"]` sorts to `[.left, .middle, .right]`.

8. **Single snap point** — `snap = ["left"]` means every navigate immediately changes focus, columns left-aligned.

9. **Two snap points** — `snap = ["left", "right"]` — cycling works, default snap index picks closest-to-middle.

10. **Rubber-band at strip boundary** — leftmost column + leftmost snap, navigateLeft produces bounce.

11. **moveColumnLeft/Right swaps snap indices** — column at snap index 2, swap with neighbor, verify snap index follows the column.

12. **Full-width column: all snaps collapse to 0** — toggle full width, verify `computeSnapOffset` returns 0 for all three snap points.

## Files Modified

| File | Change |
|------|--------|
| `Sources/Core/SnapPoint.swift` | New file: `SnapPoint` enum |
| `Sources/Core/FocusMode.swift` | Replace with `computeSnapOffset`. Remove `CenterFocusedColumn`, `computeNewViewOffset`, `computeCenteredOffset`, `computeFitOffset`. |
| `Sources/Core/Strip.swift` | Replace `focusMode` with `snapPoints` + `snapIndices`. Replace `focusLeft/Right` with `navigateLeft/Right`. Update `insertColumn`, `removeColumn`, `moveColumnLeft/Right`, `recenterActiveColumn`. |
| `Sources/Config/Config.swift` | Replace `focusMode` with `snapPoints`. Parse `snap` array. Backward-compat `focus_mode` mapping. Update `createDefaultConfig()` to emit `snap = ["middle"]` instead of `focus_mode = "always"`. |
| `Sources/WindowManager/StripController.swift` | Update `focusLeft/Right` to call `navigateLeft/Right`. Update `scrollToWindow`, `snapToNearestColumnEdge`, `handleUserResize`. Add `snapIndices` to `SavedStripState`. |
| `Sources/WindowManager/WindowManager.swift` | `applyConfig`: set `snapPoints` instead of `focusMode`. |
| `Tests/CoreTests/main.swift` | Update `makeStrip`/`makeLayoutStrip` helpers: replace `focusMode: .always` with `snapPoints: [.middle], snapIndices: [...]`. Add snap point test sections. |

## IPC

The `get-layout` IPC response currently serializes per-column data (`index`, `tiles`, `width`, `active`). Snap state is intentionally **not** added to IPC in this iteration — it's internal viewport state, not window metadata. Can be added later if tooling needs it.

## Multi-Monitor

Each display has its own `StripController` with its own `Strip`. The `snap` config is global and applied to all strips via `applyConfig` (which iterates all `stripControllers`). Per-display snap config is not supported in this iteration.
