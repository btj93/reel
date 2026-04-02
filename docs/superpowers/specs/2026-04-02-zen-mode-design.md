# Zen Mode Design

Dims unfocused tiled windows so the focused window stands out. Uses private CoreGraphics API (`CGSSetWindowAlpha`) to set per-window alpha. Animated fade transitions on focus change. Off by default.

## Scope

- Only managed tiled windows on the current strip are affected
- Floating windows and unmanaged apps are not dimmed
- Toggle via config file only (no hotkey)

## Config

New `[zen_mode]` section in `config.toml`:

```toml
[zen_mode]
enabled = false        # off by default
dim_alpha = 0.3        # alpha for unfocused tiled windows (0.0 = invisible, 1.0 = fully opaque)
fade_duration = 0.15   # seconds for fade in/out transition
```

Backed by `ZenModeConfig` struct in the Config module:

```swift
public struct ZenModeConfig: Sendable {
    public var enabled: Bool = false
    public var dimAlpha: Double = 0.3
    public var fadeDuration: Double = 0.15
    public init() {}
}
```

Added as `public var zenMode: ZenModeConfig = ZenModeConfig()` on `ScrollWMConfig`. Parsed in `Config.parse(table:base:)` following the same pattern as `[focus_indicator]`.

## Platform: ZenDimmer

New file: `Sources/Platform/ZenDimmer.swift`

### Private CG declarations

```swift
typealias CGSConnectionID = UInt32

@_silgen_name("CGSDefaultConnectionForThread")
func CGSDefaultConnectionForThread() -> CGSConnectionID

@_silgen_name("CGSSetWindowAlpha")
func CGSSetWindowAlpha(_ cid: CGSConnectionID, _ wid: CGWindowID, _ alpha: Float) -> CGError
```

### Class design

```swift
public final class ZenDimmer: @unchecked Sendable {
    // Config
    private var enabled: Bool = false
    private var dimAlpha: Double = 0.3
    private var fadeDuration: Double = 0.15

    // State
    private var fadeAnimations: [CGWindowID: EasingAnimation] = [:]
    private var currentAlphas: [CGWindowID: Double] = [:]
    private var focusedWindowID: CGWindowID?
}
```

### Public API

- **`reloadConfig(_ config: ZenModeConfig)`** — Updates config values. If transitioning enabled->disabled, calls `restoreAll()`.

- **`setFocusedWindow(_ windowID: CGWindowID, allTileIDs: [CGWindowID], at time: Double)`** — Compares against previous `focusedWindowID`. For each newly-unfocused tile, starts an `EasingAnimation` from current alpha -> `dimAlpha`. For the newly-focused tile, starts an easing from current alpha -> 1.0. No-ops if zen mode is disabled or focus hasn't changed.

- **`tick(time: Double) -> Bool`** — Evaluates all in-flight `EasingAnimation`s, calls `CGSSetWindowAlpha` for each. Removes completed animations. Returns `true` if any animation is still running.

- **`restoreAll()`** — Sets alpha to 1.0 for all tracked windows via `CGSSetWindowAlpha`. Clears all animation and alpha state.

- **`restoreWindow(_ windowID: CGWindowID)`** — Restores a single window to alpha 1.0 and removes it from tracking. Called before window removal.

### Animation details

Uses `EasingAnimation` (already in Core) with `.easeOutCubic` curve. Duration from config (`fade_duration`). Each window can have an independent in-flight easing — if focus changes rapidly, the easing is replaced starting from the window's current interpolated alpha to avoid jumps.

## StripController Integration

- Holds `public let zenDimmer: ZenDimmer` (initialized alongside `focusIndicator`)
- **Focus change**: When `strip.focusedIndex` changes (in focus_left/right, focus-follows-pointer, etc.), calls `zenDimmer.setFocusedWindow(focusedCGWindowID, allTileIDs: [...], at: time)` with the focused tile's raw `CGWindowID` and all other managed tile IDs
- **Frame tick**: `handleFrameTick` calls `zenDimmer.tick(time:)`. Its return value is OR'd into the "still animating" check that keeps FrameLoop alive.
- **Window removal**: Calls `zenDimmer.restoreWindow(tileID.rawValue)` before removing a tile from the strip
- **Window addition**: When a new window is added while zen mode is active, immediately dims it if it's not the focused window
- **Config reload**: Propagates `ZenModeConfig` via `zenDimmer.reloadConfig(config.zenMode)`
- **`isFullySettled`**: Extended to include `!zenDimmer` having in-flight animations

## WindowManager Integration

- Propagates `config.zenMode` to all strip controllers on config reload
- On app quit / `teardown()`, calls `zenDimmer.restoreAll()` on each strip controller

## Edge Cases

- **Space switch**: On space restore, re-calls `setFocusedWindow` to re-apply dimming to the restored strip's focus state.
- **App quit cleanup**: `restoreAll()` in teardown prevents permanently dimmed windows.
- **Config disable**: Transitioning `enabled` from true->false calls `restoreAll()` to undim everything.
- **Rapid focus changes**: Easings start from current interpolated alpha, not from a fixed value, so rapid key-presses produce smooth transitions without jumps.
- **Window close while dimmed**: `restoreWindow()` before removal ensures the window isn't left dimmed if it gets reused by the system.

## Config Default (config.default.toml)

```toml
# Zen mode: dim unfocused tiled windows to highlight the focused one
# [zen_mode]
# enabled = false
# dim_alpha = 0.3
# fade_duration = 0.15
```

Commented out by default (feature is off).

## Testing

Add tests in `CoreTests` for `ZenModeConfig` parsing. The `ZenDimmer` itself depends on private CG APIs so it's tested manually — verify:
1. Focus change dims/undims with animation
2. Config reload disable restores all alphas
3. Window removal restores alpha
4. Rapid focus switching doesn't produce visual jumps
