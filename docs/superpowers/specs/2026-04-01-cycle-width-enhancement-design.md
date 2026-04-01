# Cycle Width Enhancement: Animation + Configurable Presets

**Date:** 2026-04-01
**Status:** Approved (revised after review)

## Problem

1. `cycle_width` changes column width instantly — no animation, jarring compared to smooth scroll animations elsewhere.
2. Width presets are hardcoded to `[0.33, 0.5, 0.67]`. Users cannot configure them.

## Decisions

- **Proportions only** — `width_presets` is a flat array of floats (no fixed/auto support).
- **Reuse scroll spring** — width animation uses the same `scrollStiffness` / `scrollDampingRatio` as scroll animations. No new config knobs.
- **Animate both** — width spring and scroll recenter spring run concurrently.

## Design

### Config: `width_presets` in TOML

```toml
[layout]
width_presets = [0.25, 0.5, 0.75, 1.0]
```

- Flat array of floats, each interpreted as `ColumnWidth.proportion(value)`.
- Parsed in `Config.parse()` inside the `[layout]` block, following the same pattern as `snap` array parsing.
- Default stays `[0.33, 0.5, 0.67]` (current hardcoded value).
- Validation: skip values <= 0 or > 1, warn to stdout. If result is empty, keep the default.
- Add commented-out example to `config.default.toml`.

**Config reload — `presetIndex` clamping:**
`WindowManager.applyConfig` already clamps `snapIndices` when snap points shrink. Add the same for `presetIndex`: after updating `strip.widthPresets`, iterate columns and nil out any `presetIndex` that is >= the new presets count. Nil (rather than clamp) because the column's current width may not match any new preset — next cycle will start fresh from index 0.

### Prerequisite: Fix `ColumnData.currentWidth` to accept `time:`

The existing `currentWidth` computed property is non-functional for animation:
- It calls `anim.isDone` (no-arg property, always returns `false`) and `anim.currentValue` (no-arg property, always returns `to` — the target, not the interpolated value).
- This means `currentWidth` currently returns `to` immediately when an animation is set, never the intermediate value.

**Fix:** Replace the computed property with a method:

```swift
public func currentWidth(at time: Double) -> Double {
    if let anim = widthAnimation {
        if anim.isDone(at: time) { return cachedWidth }
        return anim.evaluate(at: time).value
    }
    return cachedWidth
}
```

All existing call sites that read `columnData[i].currentWidth` must be updated to pass `time:`. These are in:
- `Strip.totalWidth` — needs `at time: Double` parameter
- `Strip.recenterActiveColumn` / `recenterActiveColumnAnimated` — already have `time:`
- `Strip.removeColumn` — already has `time:`
- `Strip.navigateLeft` / `navigateRight` — already have `time:`
- `Strip.columnX(at:)` — needs `time:` parameter
- `LayoutEngine.computeTargetFrames` — already has `time:`
- `FocusMode` functions — already have `time:` available

This is a pervasive but mechanical change. Every call site already has `time` in scope.

**Performance note:** `evaluate(at:)` is a pure math call (exp, sin/cos) — negligible cost. The epsilon for width animation should use `0.5` (sub-pixel, same as `SpringParams.horizontalScroll`) to avoid wasting frames on imperceptible changes.

### Core: Animated `cycleWidthPreset`

`Strip.cycleWidthPreset()` becomes `cycleWidthPreset(at time: Double, params: SpringParams)`:

1. Resolve the **new** preset width in pixels.
2. Read the **current** effective width from `columnData[i].currentWidth(at: time)`.
3. If a width animation is already in-flight (rapid cycling), use `retargeted(to: newWidth, at: time)` to preserve velocity — same pattern as `createScrollAnimation`. Otherwise, create `SpringAnimation(from: oldWidth, to: newWidth, startTime: time, params: params)`.
4. Set `columnData[i].widthAnimation = spring` and `columnData[i].cachedWidth = newWidth`.
5. Update `columns[i].width` and `presetIndex` as before.

Setting `cachedWidth` to the target immediately means when the animation finishes and `currentWidth(at:)` falls through to `cachedWidth`, it's already correct.

**Non-animated path:** When `animationEnabled = false`, don't set `widthAnimation` at all — just set `cachedWidth` directly as today. Achieve this by having `StripController` call with `params: nil` (make the parameter optional), or keep the old non-animated method. Simplest: add `animated: Bool` parameter that skips the spring creation.

### Scroll recenter: use `cachedWidth` for target

`Strip.recenterActiveColumnAnimated` currently reads `columnData[activeColumnIndex].currentWidth(at: time)` to compute the scroll target. After a width cycle, this returns the **old** width (animation just started), producing a wrong scroll target.

**Fix:** Add an optional `columnWidth: Double?` override parameter to `recenterActiveColumnAnimated`. When provided, use it instead of `currentWidth(at:)`. `StripController.cycleWidthPreset()` passes `cachedWidth` (the target width) so the scroll aims at the correct final position.

### StripController + Frame Loop: Concurrent Animations

`StripController.cycleWidthPreset()`:
- Animated path: call `strip.cycleWidthPreset(at: time, params: springParams)`, then `strip.recenterActiveColumnAnimated(at: time, columnWidth: strip.columnData[i].cachedWidth)`. Resume frame loop.
- Non-animated path: call `strip.cycleWidthPreset(at: time, params: nil)` (no spring), then `strip.recenterActiveColumn(at: time)`, then `applyLayout()`. Identical to today's behavior.

**`handleFrameTick` settlement:**
- Add a helper on Strip: `func hasActiveWidthAnimations(at time: Double) -> Bool` — iterates `columnData`, returns true if any `widthAnimation?.isDone(at: time) == false`.
- Restructure the settlement block: the frame loop pauses only when `viewOffset.isSettled(at: time) && !hasActiveWidthAnimations(at: time)`.
- When a width animation is done (`isDone(at: time) == true`), nil it out during the tick. Only check the active column — other columns shouldn't have width animations, but guard defensively.
- **Performance:** Only check the active column's `widthAnimation` in practice, since only the active column gets width-cycled. Full iteration is unnecessary.
- The existing `applyLayout()` call within the tick continues to work — it calls `computeTargetFrames(time:)` which reads `currentWidth(at:)`, producing correct intermediate frames.

### Interaction with other width-changing operations

**`toggleFullWidth`:** Currently writes `cachedWidth` directly. Must also clear `widthAnimation = nil` to cancel any in-flight width animation. Same for the restore-from-full path.

**`handleUserResize`:** Writes `cachedWidth` directly. Must also clear `widthAnimation = nil`.

**Space save/restore:** `SavedStripState` stores `columnData` including `widthAnimation`. A restored spring has a stale `startTime` and will evaluate incorrectly. **Fix:** When saving state, nil out `widthAnimation` on each `ColumnData` before storing (animation in-flight during a space switch should just snap to target — the user won't notice). Alternatively, nil them out on restore.

### Tests

Core tests (`Tests/CoreTests/main.swift`):

**`currentWidth(at:)` fix test:**
- Create a `ColumnData` with a `widthAnimation` spring.
- Assert `currentWidth(at: startTime)` returns the `from` value.
- Assert `currentWidth(at: startTime + largeT)` returns `cachedWidth`.

**Animated cycle test:**
- Create a strip with known `widthPresets`, `workingArea`, and `SpringParams`.
- Call `cycleWidthPreset(at: 0, params: params)`.
- Assert `columnData[i].widthAnimation` is non-nil.
- Assert `currentWidth(at: 0)` equals the old width.
- Advance time until spring settles, assert `currentWidth(at: largeT)` converges to the new preset width.
- Cycle again — assert it wraps to next preset.

**Rapid cycling (retarget) test:**
- Cycle once at t=0, cycle again at t=0.05 (mid-animation).
- Assert the second spring's `from` is the intermediate value, not the old cachedWidth.
- Assert velocity is preserved (non-zero `initialVelocity`).

**Config parsing test:**
- Parse TOML with `width_presets = [0.25, 0.5, 0.75, 1.0]`.
- Assert `config.widthPresets == [.proportion(0.25), .proportion(0.5), .proportion(0.75), .proportion(1.0)]`.

**Config validation test:**
- Parse TOML with out-of-range values `width_presets = [-0.1, 0.5, 1.5]`.
- Assert only `[.proportion(0.5)]` survives.

## Files to Modify

| File | Change |
|------|--------|
| `Sources/Core/Column.swift` | `currentWidth` → `currentWidth(at:)` method |
| `Sources/Core/Strip.swift` | Update all `currentWidth` call sites; `cycleWidthPreset(at:params:)` with animation + retarget; `recenterActiveColumnAnimated` width override param; `toggleFullWidth` clears `widthAnimation`; `hasActiveWidthAnimations(at:)` helper |
| `Sources/Core/LayoutEngine.swift` | Pass `time:` to `currentWidth(at:)` |
| `Sources/Core/FocusMode.swift` | Pass `time:` to `currentWidth(at:)` |
| `Sources/WindowManager/StripController.swift` | Wire up animated/non-animated cycle; restructure `handleFrameTick` settlement; `handleUserResize` clears `widthAnimation`; space save clears `widthAnimation` |
| `Sources/WindowManager/WindowManager.swift` | `applyConfig` clamps `presetIndex` on width_presets change |
| `Sources/Config/Config.swift` | Parse `width_presets` from `[layout]` |
| `config.default.toml` | Add commented-out `width_presets` example |
| `Tests/CoreTests/main.swift` | All tests listed above |

## Out of Scope

- Fixed pixel or auto width presets.
- Separate spring parameters for resize animation.
- Reverse cycling (cycle_width_backward).
