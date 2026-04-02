# Zen Mode Design

Dims unfocused tiled windows so the focused window stands out. Uses private CoreGraphics API (`CGSSetWindowAlpha`) to set per-window alpha. Animated fade transitions on focus change. Off by default.

## Scope

- Only managed tiled windows on the current strip are affected
- Floating windows and unmanaged apps are not dimmed
- Toggle via config file only (no hotkey, no IPC toggle — deliberate deferral; IPC `zen-mode-status` query is future work)

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

**Validation**: Clamp `dim_alpha` to `0.0...1.0` and `fade_duration` to a minimum of `0.05` in the parser. Values outside these ranges would cause undefined `CGSSetWindowAlpha` behavior or divide-by-zero in `EasingAnimation`.

**Parser block** (added to `Config.parse(table:base:)` following the `[focus_indicator]` block):

```swift
if let zm = readTable(table["zen_mode"]) {
    if let v = readBool(zm["enabled"]) { config.zenMode.enabled = v }
    if let v = readDouble(zm["dim_alpha"]) { config.zenMode.dimAlpha = max(0.0, min(1.0, v)) }
    if let v = readDouble(zm["fade_duration"]) { config.zenMode.fadeDuration = max(0.05, v) }
}
```

## Platform: ZenDimmer

New file: `Sources/Platform/ZenDimmer.swift`

**Threading contract**: `ZenDimmer` must only be called from the main thread. `CGSDefaultConnectionForThread()` returns a per-thread connection — calling it on one thread and using the connection on another is undefined. All call sites (`setFocusedWindow`, `tick`, `restoreAll`) are main-thread operations in StripController/WindowManager.

### Private CG declarations

```swift
typealias CGSConnectionID = Int32

@_silgen_name("CGSDefaultConnectionForThread")
func CGSDefaultConnectionForThread() -> CGSConnectionID

@_silgen_name("CGSSetWindowAlpha")
func CGSSetWindowAlpha(_ cid: CGSConnectionID, _ wid: CGWindowID, _ alpha: Float) -> CGError
```

Note: `CGSConnectionID` is `Int32` (signed), matching the canonical `CGSInternal` headers where it is `typedef int CGSConnectionID`.

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

    // Animation query (matches FocusIndicator.isAnimating pattern)
    public var isAnimating: Bool { !fadeAnimations.isEmpty }
}
```

### Public API

- **`reloadConfig(_ config: ZenModeConfig)`** — Updates config values. If transitioning enabled->disabled, calls `restoreAll()`. No action on the disabled→enabled transition — the caller (StripController) is responsible for detecting this transition and calling `setFocusedWindow` itself after `reloadConfig` returns.

- **`setFocusedWindow(_ focusedID: TileID, allTileIDs: [TileID], at time: Double, force: Bool = false)`** — Accepts `TileID` values (the strip model's key type); internally converts to `CGWindowID` via `.rawValue` when calling `CGSSetWindowAlpha`. Compares against previous `focusedWindowID`. For each newly-unfocused tile, reads current alpha from `currentAlphas[wid]` (or evaluates in-flight easing if one exists), then creates a new `EasingAnimation(from: currentAlpha, to: dimAlpha, ...)`. For the newly-focused tile, creates a new easing from current alpha -> 1.0. No-ops if zen mode is disabled or (focus hasn't changed and `force` is false). Returns `true` (`@discardableResult`) if any new easings were created, `false` otherwise — caller uses this to resume `FrameLoop`.

- **`tick(time: Double)`** — Evaluates all in-flight `EasingAnimation`s. For each, calls `CGSSetWindowAlpha(cid, wid, Float(alpha))` (explicit `Double→Float` narrowing cast). Updates `currentAlphas` on every tick (both in-flight and completing). Removes completed animations from `fadeAnimations`. Entries in `currentAlphas` persist after completion — they serve as the "current alpha" seed for future retargeted easings and are only removed by `restoreWindow`/`restoreAll`.

- **`restoreAll()`** — Sets alpha to `Float(1.0)` for all tracked windows via `CGSSetWindowAlpha`. Clears `fadeAnimations`, `currentAlphas`, and `focusedWindowID`.

- **`restoreWindow(_ tileID: TileID)`** — Removes `tileID.rawValue` from `fadeAnimations` and `currentAlphas`. If `tileID.rawValue == focusedWindowID`, nils out `focusedWindowID` to prevent stale comparisons on the next `setFocusedWindow` call. Best-effort `CGSSetWindowAlpha` to 1.0 — the primary purpose is state cleanup to prevent stale entries if the CGWindowID is recycled. The CG call may be vacuous if the window's compositing layer is already torn down.

### Animation details

Uses `EasingAnimation` (already in Core) with `.easeOutCubic` curve. Duration from config (`fade_duration`).

**Retargeting on rapid focus changes**: When replacing an in-flight easing (e.g., a window is mid-fade and focus changes again), the implementation must:
1. Call `existingEasing.evaluate(at: now)` to read the current interpolated alpha
2. Create a new `EasingAnimation(from: currentAlpha, to: targetAlpha, startTime: now, duration: fadeDuration, curve: .easeOutCubic)`
3. Replace the entry in `fadeAnimations`

This prevents visual jumps. `EasingAnimation` has no `retargeted(to:at:)` method (unlike `SpringAnimation`), so explicit read-then-replace is required.

## StripController Integration

- Holds `public let zenDimmer: ZenDimmer` (initialized in `init` alongside `focusIndicator` — `ZenDimmer()` takes no arguments, same as `FocusIndicator()`)
- **Focus change**: When `strip.focusedIndex` changes (in focus_left/right, focus-follows-pointer, etc.), calls `zenDimmer.setFocusedWindow(...)` and if it returns `true`, calls `frameLoop.resume()`. This matches the existing pattern where `focusIndicator.animateTo(frame:at:)` returns `Bool` and the caller conditionally resumes the frame loop.
- **Frame tick**: `handleFrameTick` calls `zenDimmer.tick(time:)`.
- **`isFullySettled`**: Extended to: `return scrollSettled && widthSettled && !focusIndicator.isAnimating && !zenDimmer.isAnimating`. Note: the existing `scrollWidthSettled` latch is a separate mechanism used inside `handleFrameTick` for one-shot work (re-anchoring focus after scroll settles) — it does not gate `isFullySettled` and needs no changes.
- **Window removal**: Calls `zenDimmer.restoreWindow(tileID)` before removing a tile from the strip
- **Window addition**: Re-calls `setFocusedWindow` with the current focused tile ID and the updated full tile list. This naturally includes the new tile in the unfocused set and starts a fade easing for it. The fade is applied via `tick()` on the next frame, not inline at add time — this avoids calling `CGSSetWindowAlpha` before the window's compositing layer is fully established (which can silently fail on some apps, particularly Electron). If `setFocusedWindow` returns `true`, resumes `FrameLoop`.
- **Config reload**: StripController detects the disabled→enabled transition by comparing the previous `zenMode.enabled` to the new value before calling `zenDimmer.reloadConfig(config.zenMode)`. If zen mode was just enabled, immediately calls `setFocusedWindow(currentFocusedTileID, allTileIDs: allManagedTileIDs, at: now)` to apply dimming to already-unfocused windows, and resumes `FrameLoop` if it returns `true`.
- **Space switch**: Calls `setFocusedWindow(..., force: true)` to bypass the no-op guard. macOS may reset compositing state on space switch, so dimming must be reapplied even if the focused window is the same as before.

## WindowManager Integration

- Propagates `config.zenMode` to all strip controllers on config reload
- On app quit / `teardown()`, calls `zenDimmer.restoreAll()` on each strip controller

## Edge Cases

- **Space switch**: Calls `setFocusedWindow(..., force: true)` to re-apply dimming regardless of whether the focused window changed. See StripController integration.
- **App quit cleanup**: `restoreAll()` in teardown prevents permanently dimmed windows.
- **Config disable**: Transitioning `enabled` from true->false calls `restoreAll()` to undim everything.
- **Config enable**: Transitioning `enabled` from false->true triggers `setFocusedWindow` call from StripController to dim already-unfocused windows.
- **Rapid focus changes**: Easings start from current interpolated alpha (via explicit evaluate-then-replace), so rapid key-presses produce smooth transitions without jumps.
- **Window close while dimmed**: `restoreWindow()` cleans up state (`fadeAnimations`, `currentAlphas`, and `focusedWindowID` if it matches) to prevent stale entries from persisting if the CGWindowID is recycled. The `CGSSetWindowAlpha` call is best-effort.
- **Minimized windows**: StripController omits minimized tiles from the `allTileIDs` argument when calling `setFocusedWindow` — `ZenDimmer` has no access to `AXWindow` and cannot check minimized state itself. StripController calls `restoreWindow` when a window is minimized (to reset its alpha and clear state) and re-includes it in `allTileIDs` when unminimized.

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

Add tests in `CoreTests` for `ZenModeConfig` parsing, including:
- Valid config round-trip
- Out-of-range `dim_alpha` clamped to `0.0...1.0`
- Zero/negative `fade_duration` clamped to minimum `0.05`

The `ZenDimmer` itself depends on private CG APIs so it's tested manually — verify:
1. Focus change dims/undims with animation
2. Config reload disable restores all alphas
3. Config reload enable applies dimming to already-unfocused windows
4. Window removal restores alpha
5. Rapid focus switching doesn't produce visual jumps
6. Minimized window is skipped, unminimized window re-enters dimming
7. Space switch re-applies dimming even when focused window hasn't changed
