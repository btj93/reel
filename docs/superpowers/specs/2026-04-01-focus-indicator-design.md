# Focus Indicator Enhancement: Configurable Styles, Animated Transitions, Mission Control Fix

**Date:** 2026-04-01
**Status:** Draft

## Problem

1. **No config** — focus ring color, thickness, and style are hardcoded. Users cannot customize or disable the indicator.
2. **Mission Control bleed** — the overlay window uses `.canJoinAllSpaces, .stationary`, so it renders on top of Mission Control, Cmd-Tab, Spotlight, etc.
3. **Space-switch flash** — the `.stationary` overlay persists across desktops. When switching to a space with a differently-sized focused window, the ring appears at the old size/position for a split second before snapping to the correct frame.
4. **No animated transitions** — focus changes snap the ring instantly to the new frame. Feels jarring compared to the smooth scroll animations elsewhere.

## Decisions

- **Single class, not protocol** — `FocusIndicator` handles all styles internally via a `style` enum. The behaviors are simple enough that a protocol-per-style would be over-abstraction.
- **Rename** — `FocusRing` → `FocusIndicator` throughout. File renamed to `FocusIndicator.swift`.
- **Frontmost-app tracking** — reuse the existing `WindowEvent.appActivated(pid:)` event (already observed in `WindowTracker`). Classify managed vs unmanaged in `WindowManager.handleWindowEvent`. No new event case needed.
- **Spring-animated frame transitions** — reuse the existing `SpringAnimation` from Core for ring mode. Fluid, velocity-preserving retargeting on rapid focus changes.
- **Snap on large jumps** — when the frame delta exceeds screen width (space switch), snap instantly instead of spring-animating across an absurd distance.
- **`"auto"` color default** — uses `NSColor.controlAccentColor` (adapts to macOS system accent). Hex overrides when specified.

## Design

### Config: `[focus_indicator]` in TOML

```toml
[focus_indicator]
style = "ring"           # "none" | "ring" | "raise" | "flash"
color = "auto"           # "auto" (system accent) or hex "#RRGGBB" / "#RGB"
width = 3                # border width in points (ring mode only)
corner_radius = 10       # corner radius in points (ring mode only)
```

Add a `FocusIndicatorConfig` struct in `Config.swift`:

```swift
public struct FocusIndicatorConfig: Sendable {
    public enum Style: String, Sendable {
        case none, ring, raise, flash
    }
    public var style: Style = .ring
    public var color: String = "auto"    // "auto" or hex
    public var width: Double = 3
    public var cornerRadius: Double = 10
}
```

Parsing follows the existing pattern: read `[focus_indicator]` table, extract each key with `readString`/`readDouble`, fall back to defaults. Add commented-out section to `config.default.toml` showing all options with defaults.

**Config reload:** `FocusIndicator` exposes a `reloadConfig(_ config: FocusIndicatorConfig)` method. Called from `WindowManager.applyConfig()` (not just `reloadConfig`) via `sc.focusIndicator.reloadConfig(config.focusIndicator)`. This follows the existing pattern — all other per-StripController config fields (gap, snapPoints, widthSpringParams, etc.) are propagated in `applyConfig`, which runs on both startup and hot-reload.

### FocusIndicator class

Rename `FocusRing` → `FocusIndicator`. Same Platform module, file renamed.

**Properties:**
- `style: FocusIndicatorConfig.Style` — current mode
- `color: NSColor` — resolved from config (auto → `controlAccentColor`, hex → parsed)
- `width: CGFloat`, `cornerRadius: CGFloat` — from config
- `overlayWindow: NSWindow?` — the transparent overlay (used by ring and flash modes)
- `currentFrame: CGRect?` — the animated frame, updated each tick. `nil` when hidden or never shown (see bootstrap guard below).
- `targetFrame: CGRect` — the target frame of the focused window
- `springX, springY, springW, springH: SpringAnimation?` — per-axis springs for frame animation (ring mode)
- `flashEasing: EasingAnimation?` — opacity easing for flash mode fade-out
- `fadeOutEasing: EasingAnimation?` — opacity easing for `fadeOut()` (used by ring and flash modes when an unmanaged app becomes frontmost). Animates overlay `alphaValue` from 1→0 over ~0.15s. On convergence (`isDone`), nil out, `orderOut` overlay, set `currentFrame = nil`.

**Collection behavior change:** Replace `[.canJoinAllSpaces, .stationary]` with `[.transient]` alone. `.transient` keeps the window on the current space and hides it from Mission Control/Exposé. Removing `.canJoinAllSpaces` is essential — it would otherwise make the overlay visible on *all* spaces simultaneously, which is exactly the cross-space persistence bug we're fixing. With `[.transient]` alone, the overlay lives on the active space, disappears during space transitions, and is hidden by Mission Control.

### Style behaviors

**`none`:**
- All `show`/`hide`/`update` calls are no-ops.
- Overlay window is never created. If switching from another style, existing overlay is destroyed.

**`ring`:**
- Current rounded-rectangle border behavior.
- Frame transitions are spring-animated (see Animated Transitions section).
- Color, width, corner radius read from config.

**`raise`:**
- No overlay window. On focus change, calls `AXWindow.raise()` (which performs `kAXRaiseAction`) on the focused window to float it above siblings. This method already exists in `AXWindow.swift`.
- On focus-away (different window gains focus), the raise is a no-op — the newly focused window naturally comes to front.
- Smooth: the window visually pops forward, which is its own feedback. No additional overlay animation needed.
- Requires passing the focused `AXWindow` to the indicator — add `show(around:window:)` overload, or have StripController call `raise()` directly when style is `.raise`.

**`flash`:**
- On focus change: overlay appears at full target frame, filled with semi-transparent accent color (20% opacity).
- Smooth fade-out over ~0.2s using `EasingAnimation` from Core (e.g. `easeOutCubic`). This type already exists in `Animation.swift` with `isDone(at:)` for convergence checks.
- Driven by FrameLoop ticks (same `isAnimating` pattern as ring mode — see FrameLoop Integration below). Each tick evaluates the easing and updates overlay opacity.
- **Nil-on-convergence invariant:** In `tick()`, when `flashEasing.isDone(at: time)` returns true, nil out `flashEasing` and `orderOut` the overlay. Similarly for `fadeOutEasing`. `isAnimating` is implemented as `springX != nil || flashEasing != nil || fadeOutEasing != nil` — springs for ring mode frame animation, `flashEasing` for flash mode, `fadeOutEasing` for the opacity fade when hiding. This ensures the FrameLoop pauses once all animations converge. Same invariant as springs: any done animation must be niled, not left as a non-nil converged value.
- After the easing completes and is niled, the overlay is hidden. No per-frame work between focus changes.
- On rapid focus changes: restart the flash at the new frame (cancel any in-progress fade, begin fresh).

### Animated transitions (ring mode)

**Spring-animated frame changes:**
- `FocusIndicator` maintains 4 `SpringAnimation` instances — one each for x, y, width, height of the overlay frame.
- Springs use the same stiffness/damping as the scroll animation config (reuse `ScrollWMConfig.scrollStiffness` and `ScrollWMConfig.scrollDampingRatio`, or the `widthSpringParams` computed property which wraps them into a `SpringParams`).

**Public API — `StripController` always calls these, never `show()` directly:**
- `snapTo(frame:)` — sets `currentFrame` instantly, nils all springs, positions overlay. Used on first show (bootstrap guard), large jumps, and `applyLayout()` path.
- `animateTo(frame:at:)` — if springs exist and haven't converged: `retargeted(to:at:)` on each, preserving velocity. If no springs: creates new springs from `currentFrame` to `frame`. Returns `true` if an animation was started/retargeted (caller uses this to resume FrameLoop).
- Each display-link tick: evaluate all 4 springs at current time, update `currentFrame`, reposition the overlay.
- When all 4 springs converge (within tolerance): nil out springs (`isAnimating` becomes false).

**Large-jump detection (space switch):**
- The snap-vs-animate decision lives in `StripController`, not in `FocusIndicator`. `StripController` already has `strip.workingArea.width` and manages space-switch logic (`lastSpaceSwitchTime`).
- `FocusIndicator` exposes two methods: `snapTo(frame:)` (instant, no springs) and `animateTo(frame:at:)` (spring-based).
- **Bootstrap guard:** If `currentFrame` is nil (first show after init or after `hide()`), always call `snapTo` regardless of distance. This prevents spring-animating from (0,0).
- `StripController.updateFocusIndicator()` checks: if `currentFrame` is nil, or `abs(newFrame.midX - currentFrame.midX) > workingArea.width`, call `snapTo`. Otherwise call `animateTo`.

### Frontmost-app tracking (Mission Control / Cmd-Tab fix)

**No new observer needed.** `WindowTracker` already observes `NSWorkspace.didActivateApplicationNotification` and emits `WindowEvent.appActivated(pid:)`. `WindowManager.handleWindowEvent` already handles this for Cmd-Tab scrolling.

**Extension:** In the existing `.appActivated(pid:)` handler in `WindowManager`, after the current Cmd-Tab scroll logic, add managed/unmanaged classification:
- Check if `pid` matches any managed window's owner PID (using `tracker.windows`).
- **Important:** This check must iterate *all* `stripControllers`, not just `stripController` (the active-display computed property). On multi-display setups, the activated app's windows may live on a non-active display.
- If unmanaged → call `sc.fadeOutIndicator()` on *all* strip controllers. This is a `StripController` wrapper method that calls `focusIndicator.fadeOut()` and resumes `frameLoop` if it returns `true`. `WindowManager` must not call `focusIndicator` methods directly — all FrameLoop resume decisions route through `StripController`.
- If managed → call `sc.showIndicator()` on the relevant strip controller(s). This is a `StripController` wrapper that calls `updateFocusIndicator` (which routes through the bootstrap guard and snap-vs-animate heuristic). If the overlay was fully hidden (`currentFrame == nil`), this triggers a `snapTo` — the overlay appears at full opacity immediately (no fade-in for ring mode; flash mode uses its own flash animation on the next focus change).
- **Echo suppression bypass:** The top-level echo suppression early-return in `handleWindowEvent` currently lists `.appActivated` among the suppressed event cases — this drops the *entire* event before any per-case handler runs. Remove `.appActivated` from that early-return list. `.appActivated` is not an AX echo from our `setFrame` calls and never should have been gated by echo suppression. Similarly, the 300ms post-space-switch suppression also gates `.appActivated` — remove `.appActivated` from that gate as well. (Do *not* try to move indicator logic before the gate — the indicator calls `updateFocusIndicator` which interacts with strip state that may be inconsistent during space-switch suppression.)

**Why this covers Mission Control:** Mission Control activates the Dock process (not a managed app), so the unmanaged branch fires and the indicator fades out. When the user selects a window and Mission Control dismisses, the managed app becomes frontmost and the indicator springs back.

### Integration with StripController

- Replace `focusRing: FocusRing` property with `focusIndicator: FocusIndicator`.
- `updateFocusRing()` → rename to `updateFocusIndicator()`.
- Pass `FocusIndicatorConfig` from config on init and on hot-reload.
- For `raise` style: StripController calls `AXWindow.raise()` directly when the style is `.raise` — no need to route through the indicator. StripController already has access to `AXWindow` instances. **Important:** `updateFocusIndicator` is called every tick during active animations. To avoid sending `kAXRaiseAction` at display refresh rate, track `lastRaisedTileID: TileID?` in StripController and only call `raise()` when the active tile changes. Clear `lastRaisedTileID` in `hide()` and on style changes.

### FrameLoop integration

`FocusIndicator` exposes an `isAnimating: Bool` property — `springX != nil || flashEasing != nil || fadeOutEasing != nil`. True when any spring or easing is in flight (ring mode frame springs, flash mode easing, or fadeOut opacity easing).

**`focusIndicator.tick()` must run unconditionally at the top of `handleFrameTick`**, before the settled check. This is critical: on the settle frame, the scroll/width may be settled but indicator springs may still be in flight. If `tick()` only runs in the non-settled path, springs never converge on the final frame and `isAnimating` stays true forever, preventing the loop from pausing.

**Settle latch:** The scroll/width settled branch does one-shot work (gesture re-anchor, `viewOffset = .static` freeze, final `applyLayout()`). When the indicator is still animating after scroll/width settle, this one-shot work must run exactly once — not every tick at 120Hz. Add a `scrollWidthSettled: Bool` latch on `StripController`:
- Set to `true` on the tick where `scrollSettled && widthSettled` first becomes true. Execute the one-shot work (gesture re-anchor, offset freeze, `applyLayout()`) on this tick only.
- On subsequent ticks where the latch is already `true`: skip the one-shot work, just compute target frames and call `updateFocusIndicator` to let indicator springs continue.
- Reset to `false` when a new scroll or width animation starts.

**Tick order:**
1. `focusIndicator.tick(time: time)` — unconditionally, before anything else
2. Check `scrollSettled && widthSettled`:
   - If true and latch not yet set: run one-shot settle work, set latch, call `applyLayout()` (which routes to `updateFocusIndicator` with `animateTo` if indicator is still running)
   - If true and latch already set: compute target frames, call `updateFocusIndicator` only (indicator still animating, scroll/width are done)
   - If false: normal animated tick path (compute frames, update positions, update indicator)
3. `updateFocusIndicator(frames: frames)` — position overlay. **Universal rule regardless of caller** (whether from `applyLayout()`, `handleFrameTick`, or the settle-latch path): uses `snapTo` only when `currentFrame == nil` (bootstrap) or large jump detected. Otherwise uses `animateTo`. This means `applyLayout()` does not force-kill indicator springs — it lets them continue to convergence.

**Settled check — move pause to WindowManager:** The per-strip `frameLoop?.pause()` call is a pre-existing race: the first strip to settle pauses the shared loop, cutting off still-animating strips on other displays. Adding a third animation source makes this race probable in normal use. Fix it now:

1. `StripController` no longer calls `frameLoop?.pause()` itself. Instead, expose `isFullySettled: Bool` (scroll settled AND width settled AND `!focusIndicator.isAnimating`).
2. The `FrameLoop.onTick` closure in `WindowManager` (around line 264) checks all strips after ticking:

First, promote the local `frameLoop` variable in `WindowManager.start()` to a stored property `private var frameLoop: FrameLoop?` on `WindowManager`, so the `onTick` closure and other methods can access it.

```swift
frameLoop.onTick = { [weak self] time in
    guard let self else { return }
    for (_, sc) in self.stripControllers {
        sc.handleFrameTick(time: time)
    }
    if self.stripControllers.values.allSatisfy({ $0.isFullySettled }) {
        self.frameLoop?.pause()
    }
}
```

This ensures the loop stays alive as long as *any* strip has an active animation.

**Pause calls to remove from `StripController`:**
- `handleFrameTick`'s `if scrollSettled && widthSettled` branch (the main settled path)
- `handleGestureEnd`'s low-velocity branch (which calls `frameLoop?.pause()` after snapping to a static offset)
- `handleGestureCancel` (which calls `frameLoop?.pause()`)

All three bypass the `allSatisfy` check and can race with other strips on multi-display setups. Remove all of them — the `onTick` closure is the sole authority for pausing.

**Resume:** `frameLoop?.resume()` must be called when an indicator animation starts. `FocusIndicator` does not hold a `FrameLoop` reference (and shouldn't — it's a Platform type, FrameLoop ownership is in WindowManager). Instead, `StripController` checks after every call to `animateTo`, `fadeOut`, or flash trigger methods: if `focusIndicator.isAnimating` became true, call `frameLoop?.resume()`. Concretely, `animateTo` and `fadeOut` return a `Bool` indicating whether an animation was started; `StripController` resumes the loop when the return is `true`.

### `hide()` semantics per style

`hide()` is called from `rebuildStrip()`, `switchSpace()` (both new-space and restored-space branches), `shutdown()`, and `togglePause()`. **Important:** The restored-space branch of `switchSpace` currently calls `applyLayout()` without `hide()` first — add `focusIndicator.hide()` before `applyLayout()` in the restore path so `currentFrame` is reset and the bootstrap guard forces a `snapTo` on the restored space. Without this, a stale `currentFrame` from the previous display of the space causes the snap-vs-animate heuristic to fail (delta is small, so it animates from a stale position instead of snapping).

`hide()` must clean up all animation state to prevent `isAnimating` from staying true after the indicator is hidden:

| Style | `hide()` behavior |
|-------|-------------------|
| `ring` | Nil all 4 springs, nil `fadeOutEasing`, `orderOut` overlay, set `currentFrame = nil` |
| `flash` | Nil `flashEasing`, nil `fadeOutEasing`, `orderOut` overlay, set `currentFrame = nil` |
| `raise` | No-op (raise has no persistent visual state) |
| `none` | No-op |

The `currentFrame = nil` reset ensures the bootstrap guard triggers a `snapTo` on the next `show`.

### Style-transition teardown on config reload

When `reloadConfig` changes the `style`, all in-flight animation state from the old style must be torn down atomically. This follows the same invariant as width animations: any state change that invalidates a spring must nil it out.

| From → To | Teardown |
|-----------|----------|
| `ring` → any | Nil all 4 springs, nil `fadeOutEasing`, `orderOut` + nil overlay window, `currentFrame = nil` |
| `flash` → any | Nil `flashEasing`, nil `fadeOutEasing`, `orderOut` + nil overlay window, `currentFrame = nil` |
| `raise` → any | No AX "un-raise" exists; the previously-raised window keeps its z-order until another window naturally comes to front. Documented as known limitation. |
| `none` → any | No cleanup needed |
| any → `ring` | Overlay will be created on next `show` call; no eager creation |
| any → `flash` | Same — overlay created on demand |
| any → `raise` | Destroy overlay if it exists |
| any → `none` | Destroy overlay if it exists |

### Coordinate system

No changes. The indicator continues to receive CG-coordinate frames and convert to AppKit coordinates internally for `NSWindow.setFrame`. The existing flip logic in `updateFocusRing` (now `updateFocusIndicator`) stays.

### Color parsing

Add a helper `NSColor.from(configString:)`:
- `"auto"` → `NSColor.controlAccentColor`
- `"#RGB"` (3 chars) → expand to `#RRGGBB`, parse
- `"#RRGGBB"` (6 chars) → parse hex to r/g/b components, create `NSColor`
- Invalid string → log warning, fall back to `controlAccentColor`

### Files changed

| File | Change |
|------|--------|
| `Sources/Platform/FocusRing.swift` | Rename to `FocusIndicator.swift`, rewrite class |
| `Sources/Config/Config.swift` | Add `FocusIndicatorConfig: Sendable` struct and parsing |
| `config.default.toml` | Add `[focus_indicator]` section |
| `Sources/WindowManager/StripController.swift` | Replace `focusRing` → `focusIndicator`, rename `updateFocusRing` → `updateFocusIndicator`, add `snapTo`/`animateTo` decision with bootstrap guard, call `tick(time:)` unconditionally at top of `handleFrameTick`, expose `isFullySettled: Bool`, remove all `frameLoop?.pause()` calls (settled branch, gesture end, gesture cancel), add `scrollWidthSettled` latch for one-shot settle work, resume FrameLoop when indicator methods return true, add `hide()` in `switchSpace` restore path, add `fadeOutIndicator()`/`showIndicator()` wrappers, add `lastRaisedTileID` tracking for raise style |
| `Sources/WindowManager/WindowManager.swift` | Promote local `frameLoop` to stored property; remove `.appActivated` from echo suppression and space-switch suppression early-return gates; extend `.appActivated` handler to call `sc.fadeOutIndicator()`/`sc.showIndicator()` on all strip controllers; update `shutdown()` and `togglePause()` (`focusRing.hide()` → `focusIndicator.hide()`); add `focusIndicator.reloadConfig()` call in `applyConfig()`; move `frameLoop.pause()` decision into `onTick` closure with `allSatisfy({ $0.isFullySettled })` |

**No changes needed** to `WindowTracker.swift` or `WindowEvent.swift` — the existing `didActivateApplicationNotification` observer and `appActivated(pid:)` event are reused as-is.

### Known limitations

- **Multi-display Y-flip:** The existing `updateFocusRing` uses `NSScreen.main` for the Y-coordinate flip. On multi-monitor setups where the focused window is on a non-primary display, the flip may use the wrong screen height. This is a pre-existing bug, not introduced by this enhancement. Can be fixed as a follow-up by using the per-display screen height from `DisplayManager` instead.
- **Raise z-order persistence:** When switching away from `raise` style (via config reload), the previously-raised window keeps its z-order. There is no AX "un-raise" action. The window will naturally lose its raised position when another window comes to front.
- **Pre-existing FrameLoop pause race:** Before this enhancement, per-strip `pause()` calls could race on multi-display setups. This spec fixes the race by centralizing the pause decision in `WindowManager.onTick`.

### Testing

- **Core tests (pure logic):** Spring animation convergence and retargeting are already tested. No new Core changes.
- **Manual testing:**
  - Switch between `none`/`ring`/`raise`/`flash` via config reload — verify each style activates correctly.
  - Config reload mid-animation: switch style while ring is spring-animating — verify clean teardown, no stale overlay.
  - Ring mode: rapid focus-left/right — verify spring velocity compounds smoothly.
  - Ring mode during scroll: verify the ring follows the focused window smoothly while scrolling, no abrupt hide/show flicker.
  - Space switch: verify ring snaps to correct frame on new desktop with no flash.
  - Mission Control: activate and verify indicator fades out; pick a window, verify it fades back.
  - Cmd-Tab to Finder/Safari/etc: verify indicator hides; Cmd-Tab back, verify it returns.
  - Hot-reload config with changed color/width — verify update takes effect.
  - Hex color parsing: test `"#F00"`, `"#FF6600"`, `"auto"`, invalid string.
  - Flash mode: verify smooth ease-out fade, not abrupt. Rapid focus changes restart cleanly.
  - Raise mode: verify window visually pops to front on focus change.
