# Gesture Snap Config Design

## Problem

Trackpad gesture navigation always snaps windows to the center (or default snap point) after a flick. Some users want the strip to rest wherever momentum carries it, without column alignment.

Additionally, when snapping is enabled, the snap target should be the nearest configured snap point to where the column lands — not always the default.

Finally, the active column after a gesture should be determined by which column is under the cursor, not by viewport-center proximity.

## Config

New boolean key under `[gesture]`:

```toml
[gesture]
snap = true  # default: true. Set to false to disable snapping after trackpad gestures.
```

- Stored as `ScrollWMConfig.gestureSnap: Bool = true`
- Parsed in `Config.swift` from the `[gesture]` table (alongside `modifier`)
- Propagated via `WindowManager.applyConfig()` to each `StripController`
- `StripController` stores it as a property

## Behavior

### `[gesture] snap = false` (free scroll)

**`handleGestureEnd` with velocity > 50 px/s:**
1. Project momentum endpoint via `SwipeTracker.projectedEndPosition()`
2. Determine active column by cursor position (see Focus section below) — must happen before creating the spring so the focus ring tracks the correct column during animation
3. Animate a spring from current offset to projected offset (no column alignment)
4. Do NOT call `snapToNearestColumnEdge`

**`handleGestureEnd` with velocity <= 50 px/s:**
- Unchanged — freezes at current position (`.static`)

### `[gesture] snap = true` (default, current behavior with fixes)

**`handleGestureEnd` with velocity > 50 px/s:**
1. Project momentum endpoint via `SwipeTracker.projectedEndPosition()`
2. Determine active column by cursor position (see Focus section below)
3. For the target column, evaluate ALL configured snap points via `computeSnapOffset()` and pick the one whose offset is closest to the projected momentum offset
4. Set `snapIndices[targetColumn]` to that snap point's index
5. Animate a spring from current offset to the chosen snap offset

This replaces the current `snapToNearestColumnEdge` logic which always resets to `defaultSnapIndex`.

**`handleGestureEnd` with velocity <= 50 px/s:**
- Unchanged — freezes at current position (`.static`)

## Focus: Cursor-Based Active Column

At gesture end, determine which column is under the cursor:

1. Read cursor position via `NSEvent.mouseLocation` (screen coordinates, bottom-left origin)
2. Convert screen X to strip-space X. From `LayoutEngine.swift`: `screenX = stripX - viewPos + wa.minX`, where `viewPos = columnX(activeColumnIndex) + viewOffset`. Inverting: `cursorStripX = (cursorScreenX - workingArea.minX) + columnX(activeColumnIndex) + state.currentOffset` (where `state` is the unpacked `GestureState` — use the live gesture accumulator at lift-off, NOT the projected endpoint from step 1)
3. Find which column contains `cursorStripX` (account for gaps — if cursor is in a gap, pick the nearest column)
4. Set `strip.activeColumnIndex` to that column

This applies to both `gesture_snap = true` and `gesture_snap = false` paths, replacing the current viewport-center proximity logic.

No `focusActiveWindow()` call is made — consistent with current gesture behavior where AX focus only changes on keyboard navigation.

## Files to Modify

| File | Change |
|------|--------|
| `Sources/Config/Config.swift` | Add `gestureSnap` property, parse `snap` from `[gesture]` table |
| `Sources/WindowManager/StripController.swift` | Add `gestureSnap` property. Refactor `handleGestureEnd` to branch on it. Replace `snapToNearestColumnEdge` with new logic: cursor-based active column + nearest snap point selection. Add `columnUnderCursor()` helper. |
| `Sources/WindowManager/WindowManager.swift` | Propagate `gestureSnap` to StripControllers in `applyConfig()` |
| `config.default.toml` | Add `snap = true` under `[gesture]` with comment |
| `Tests/CoreTests/main.swift` | Test nearest-snap-point selection logic and coordinate conversion |

## Coordinate Conversion Notes

- `NSEvent.mouseLocation` returns screen coordinates with bottom-left origin
- `DisplayManager` already converts between AppKit (bottom-left) and CG (top-left) coordinates
- For this feature we only need the X coordinate, which is the same in both coordinate systems
- `workingArea` is in CG screen coordinates (from `DisplayManager`)

## Edge Cases

- **Cursor outside any column (in a gap):** Pick the column whose edge is closest to cursor X
- **Cursor outside the strip entirely:** Fall back to nearest column to viewport center (current behavior)
- **Single column:** Always that column, regardless of cursor position
- **Config reload:** `gestureSnap` updates take effect on next gesture (no mid-gesture change needed)
- **Keyboard after free-scroll:** When `snap = false`, the first keyboard press after a free-scroll will jump to the default snap position of the cursor-selected column. This is intentional — keyboard navigation always snaps.
