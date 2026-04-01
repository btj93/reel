# Cycle Width Enhancement: Animation + Configurable Presets

**Date:** 2026-04-01
**Status:** Approved

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
- Parsed in `Config.parse()` inside the `[layout]` block.
- Default stays `[0.33, 0.5, 0.67]` (current hardcoded value).
- Validation: skip values <= 0 or > 1, warn to stdout. If result is empty, keep the default.
- Add commented-out example to `config.default.toml`.

### Core: Animated `cycleWidthPreset`

`Strip.cycleWidthPreset()` becomes `cycleWidthPreset(at time: Double)` with spring parameters:

1. Resolve the **new** preset width in pixels.
2. Read the **current** effective width from `columnData[i].currentWidth` (respects in-flight animation).
3. Create a `SpringAnimation(from: oldWidth, to: newWidth, at: time)` using scroll stiffness/damping.
4. Set `columnData[i].widthAnimation = spring` and `columnData[i].cachedWidth = newWidth`.
5. Update `columns[i].width` and `presetIndex` as before.

Setting `cachedWidth` to the target immediately means when the animation finishes and `currentWidth` falls through to `cachedWidth`, it's already correct. No finalization step needed.

Spring parameters (stiffness, damping ratio) need to be passed into this method — either as arguments or stored on Strip. Prefer arguments to keep Strip a pure data model.

### StripController + Frame Loop: Concurrent Animations

`StripController.cycleWidthPreset()`:
- Call `strip.cycleWidthPreset(at: time, stiffness:, dampingRatio:)` (now animated).
- Call `recenterActiveColumnAnimated(at: time)` — scroll spring runs concurrently.
- Compute the scroll recenter target using `cachedWidth` (the target width), not `currentWidth`, so the scroll aims at the correct final position from the start.
- Resume frame loop.

`handleFrameTick` settlement check:
- Currently only checks `strip.viewOffset.isSettled(at: time)`.
- Add: are any `columnData[i].widthAnimation` still in-flight?
- Frame loop pauses only when **both** scroll offset and all width animations are settled.
- When a width animation is done, nil it out (`columnData[i].widthAnimation = nil`).

### Tests

Core tests (`Tests/CoreTests/main.swift`):

**Animated cycle test:**
- Create a strip with known `widthPresets`, `workingArea`, stiffness/damping.
- Call `cycleWidthPreset(at: 0, ...)`.
- Assert `columnData[i].widthAnimation` is non-nil.
- Assert `currentWidth` at t=0 equals the old width.
- Advance time until spring settles, assert `currentWidth` converges to the new preset width.
- Cycle again — assert it wraps to next preset.

**Config parsing test:**
- Parse TOML with `width_presets = [0.25, 0.5, 0.75, 1.0]`.
- Assert `config.widthPresets == [.proportion(0.25), .proportion(0.5), .proportion(0.75), .proportion(1.0)]`.

## Files to Modify

| File | Change |
|------|--------|
| `Sources/Core/Strip.swift` | `cycleWidthPreset(at:stiffness:dampingRatio:)` — add animation |
| `Sources/WindowManager/StripController.swift` | Wire up animated cycle, update `handleFrameTick` settlement |
| `Sources/Config/Config.swift` | Parse `width_presets` from `[layout]` |
| `config.default.toml` | Add commented-out `width_presets` example |
| `Tests/CoreTests/main.swift` | Animated cycle + config parsing tests |

## Out of Scope

- Fixed pixel or auto width presets.
- Separate spring parameters for resize animation.
- Reverse cycling (cycle_width_backward).
