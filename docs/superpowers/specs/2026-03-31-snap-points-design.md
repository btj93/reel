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
- `"never"` → `["left"]`
- `"on-overflow"` → `["middle"]`

If both `snap` and `focus_mode` are present, `snap` wins with a log warning. If `snap` is empty or has no valid entries, falls back to `["middle"]` with a warning.

## Data Model (Core)

### New type: `SnapPoint`

```swift
public enum SnapPoint: String, Sendable, Comparable {
    case left, middle, right
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

**Default snap index for new columns:** Index of `.middle` in `snapPoints`. If `.middle` isn't configured, use `snapPoints.count / 2`.

### Offset computation: `computeSnapOffset`

Replaces `computeNewViewOffset` / `computeCenteredOffset` / `computeFitOffset`:

```swift
func computeSnapOffset(
    snapPoint: SnapPoint,
    columnWidth: Double,
    workingAreaWidth: Double
) -> Double {
    switch snapPoint {
    case .left:   return 0                                    // col left edge = screen left edge
    case .middle: return -(workingAreaWidth - columnWidth) / 2  // col center = screen center
    case .right:  return -(workingAreaWidth - columnWidth)      // col right edge = screen right edge
    }
}
```

The existing centering math (`-(workingAreaWidth - columnWidth) / 2`) is the `.middle` case.

## Navigation Logic

### `navigateRight` (animated variant, Hyper+L direction)

```
1. currentSnap = snapIndices[activeColumnIndex]
2. if currentSnap < snapPoints.count - 1:
     // Advance snap point on current column
     snapIndices[activeColumnIndex] += 1
     targetOffset = computeSnapOffset(snapPoints[newIndex], colWidth, screenWidth)
     animate to targetOffset
3. else:
     // Exhausted snap points — move focus to next column
     if activeColumnIndex < columns.count - 1:
       activeColumnIndex += 1
       // Advance new column's snap one step in travel direction (clamped)
       snapIndices[activeColumnIndex] = min(snapIndices[activeColumnIndex] + 1,
                                            snapPoints.count - 1)
       targetOffset = computeSnapOffset(snapPoints[newSnapIndex], colWidth, screenWidth)
       animate to targetOffset
     else:
       // Strip boundary — rubber-band bounce
       createRubberBandAnimation(direction: +1)
```

### `navigateLeft` (animated variant, Hyper+H direction)

Mirror of `navigateRight`:
- Decrement snap index if > 0
- Else move focus left, decrement new column's snap index (clamped to 0)
- Else rubber-band bounce at left boundary

### Non-animated variants

Same logic, `viewOffset = .static(offset)` instead of spring animation.

### Behavior with `snap = ["middle"]` (backward compat)

- `snapPoints.count == 1`, so step 2 never triggers (currentSnap is always at max)
- Always falls through to step 3: move focus, new column's snap stays at 0 (middle)
- Offset = `-(screenWidth - colWidth) / 2` — identical to old `focusMode = .always`

## Integration Points

### StripController

- `focusLeft()` / `focusRight()` → call `strip.navigateLeft()` / `strip.navigateRight()`
- `scrollToWindow(tileID:)` → set target column's snap index to default (middle)
- `handleGestureEnd` / `snapToNearestColumnEdge` → gestures ignore snap points; after settle, set focused column's snap index to default
- `handleUserResize` debounced recenter → use current snap index (not always middle)
- `SavedStripState` → include `snapIndices` for Space save/restore

### WindowManager

- `applyConfig` → set `strip.snapPoints` instead of `strip.focusMode`

### Callers of `computeNewViewOffset` (all replaced)

| Caller | New behavior |
|--------|-------------|
| `Strip.insertColumn` | Default snap index → `computeSnapOffset` |
| `Strip.removeColumn` | Surviving column keeps snap index → `computeSnapOffset` |
| `Strip.recenterActiveColumn` | Current snap index → `computeSnapOffset` |
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
    case "always":     config.snapPoints = [.middle]
    case "never":      config.snapPoints = [.left]
    case "on-overflow": config.snapPoints = [.middle]
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

## Files Modified

| File | Change |
|------|--------|
| `Sources/Core/SnapPoint.swift` | New file: `SnapPoint` enum |
| `Sources/Core/FocusMode.swift` | Replace with `computeSnapOffset`. Remove `CenterFocusedColumn`, `computeNewViewOffset`, `computeCenteredOffset`, `computeFitOffset`. |
| `Sources/Core/Strip.swift` | Replace `focusMode` with `snapPoints` + `snapIndices`. Replace `focusLeft/Right` with `navigateLeft/Right`. Update `insertColumn`, `removeColumn`, `moveColumnLeft/Right`, `recenterActiveColumn`. |
| `Sources/Config/Config.swift` | Replace `focusMode` with `snapPoints`. Parse `snap` array. Backward-compat `focus_mode` mapping. |
| `Sources/WindowManager/StripController.swift` | Update `focusLeft/Right` to call `navigateLeft/Right`. Update `scrollToWindow`, `snapToNearestColumnEdge`, `handleUserResize`. Add `snapIndices` to `SavedStripState`. |
| `Sources/WindowManager/WindowManager.swift` | `applyConfig`: set `snapPoints` instead of `focusMode`. |
| `Tests/CoreTests/main.swift` | Add snap point test sections. |
