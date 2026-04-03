# Overlay Dimmer Design (macOS 26 Fallback)

macOS 26 (Tahoe) broke `CGSSetWindowAlpha` and `CGSSetWindowLevel` — they return success but have no visible effect. This spec adds overlay-based fallbacks that activate at runtime on macOS 26+, while preserving the CGS path for macOS ≤15.

## Scope

- **Zen dimming fallback**: Full-screen overlay window per display, ordered below the focused window. Replaces per-window `CGSSetWindowAlpha` dimming on macOS 26+.
- **Always-on-top fallback**: Re-raise pinned windows via `AXRaise` on every focus change. Replaces `CGSSetWindowLevel` on macOS 26+.
- **Per-rule `opacity` and `floating_opacity`**: CGS-only, no overlay equivalent. These features are macOS ≤15 only.
- **Runtime detection**: `ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26` determines which path to use.

## Runtime Detection

Add to `ZenDimmer` (or a shared location):

```swift
/// True when CGS private APIs work (macOS ≤15). False on macOS 26+ (Tahoe).
public static let cgsAvailable: Bool = {
    ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26
}()
```

All CGS call sites check this flag. On macOS 26+, CGS calls are skipped entirely (they're no-ops anyway).

## OverlayDimmer (Sources/Platform/OverlayDimmer.swift)

New class, parallel to ZenDimmer. Manages one borderless overlay window per display.

### Overlay window properties

```swift
let overlay = NSWindow(contentRect: screenFrame, styleMask: .borderless, backing: .buffered, defer: false)
overlay.backgroundColor = NSColor.black.withAlphaComponent(dimAlpha)
overlay.ignoresMouseEvents = true
overlay.collectionBehavior = [.transient, .fullScreenNone]
overlay.level = .normal
overlay.hasShadow = false
overlay.isOpaque = false
```

- `.borderless` — no title bar, no chrome
- `.transient` — not visible in Mission Control / Expose
- `.fullScreenNone` — doesn't participate in full-screen spaces
- `.normal` level — same z-level as regular app windows
- `ignoresMouseEvents` — all clicks pass through to windows below
- `hasShadow = false` — no visual artifacts
- `isOpaque = false` — compositor treats it as transparent

### State

```swift
public final class OverlayDimmer {
    private var overlays: [CGDirectDisplayID: NSWindow] = [:]
    private var dimAlpha: Double = 0.3
    private var enabled: Bool = false
    private var focusedWindowNumber: Int = 0
}
```

### Public API (mirrors ZenDimmer's interface where applicable)

**`reloadConfig(_ config: ZenModeConfig)`** — Updates `enabled` and `dimAlpha`. If transitioning enabled→disabled, hides all overlays. If disabled→enabled, caller triggers `setFocusedWindow`.

**`setFocusedWindow(_ windowID: CGWindowID)`** — Looks up the window's `windowNumber` via `CGWindowListCopyWindowInfo`, then calls `overlay.order(.below, relativeTo: windowNumber)` on the appropriate display's overlay. Shows the overlay if hidden. Returns true if state changed (caller should note this).

**`hide()`** — Hides all overlay windows. Called on zen-disable, shutdown, pause.

**`updateDisplays(_ displays: [CGDirectDisplayID: DisplayInfo])`** — Recreates overlays when displays change. Each overlay is sized to the display's full frame.

### How `order(.below, relativeTo:)` works

`NSWindow.order(.below, relativeTo: windowNumber)` places our overlay window directly below the specified window in the z-order. This means:
- The focused window renders above the overlay (visible, fully opaque)
- All other windows render below the overlay (visually dimmed)
- The overlay's `backgroundColor` with alpha creates the dimming effect

### Getting the focused window's NSWindow number

`CGWindowListCopyWindowInfo` returns `kCGWindowNumber` for each window. We already have the focused window's `CGWindowID` — we can look up its window number:

```swift
private func windowNumber(for windowID: CGWindowID) -> Int? {
    guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
          let first = list.first,
          let num = first[kCGWindowNumber as String] as? Int else { return nil }
    return num
}
```

Note: `CGWindowID` and `kCGWindowNumber` are the same value in practice, but using the lookup is safer.

### Multi-display

One overlay per connected display, sized to the display's full visible frame. `updateDisplays` is called from `DisplayManager.onDisplayChange`. On display change, existing overlays are removed and new ones created.

### Overlay alpha updates

When `dimAlpha` changes (config reload), update all overlays:
```swift
overlay.backgroundColor = NSColor.black.withAlphaComponent(dimAlpha)
```

No animation — instant, matching the CGS behavior.

## ZenDimmer Changes

### Conditional CGS calls

All existing `CGSSetWindowAlpha` calls in ZenDimmer are wrapped:

```swift
// In instance methods (tick, setRuleOpacity, clearRuleOpacity, restoreAll, restoreWindow):
if Self.cgsAvailable {
    CGSSetWindowAlpha(cid, wid, alpha)
}
```

The static `setWindowAlpha` helper:
```swift
public static func setWindowAlpha(_ wid: CGWindowID, _ alpha: Float) {
    guard cgsAvailable else { return }
    let cid = CGSDefaultConnectionForThread()
    CGSSetWindowAlpha(cid, wid, alpha)
}
```

The static `setWindowLevel` helper:
```swift
public static func setWindowLevel(_ wid: CGWindowID, _ level: Int32) {
    guard cgsAvailable else { return }
    let cid = CGSDefaultConnectionForThread()
    CGSSetWindowLevel(cid, wid, level)
}
```

ZenDimmer's state tracking (`ruleOpacities`, `currentAlphas`, `fadeAnimations`) still runs on macOS 26+ — it just doesn't make CGS calls. This keeps the state consistent for when the overlay dimmer queries focus state.

### `isAnimating` on macOS 26+

ZenDimmer's fade animations are meaningless on macOS 26 (no CGS calls). On 26+, `isAnimating` always returns false since no fades are created. The `setFocusedWindow` method skips creating `EasingAnimation` entries when `!cgsAvailable`:

```swift
if Self.cgsAvailable {
    fadeAnimations[wid] = EasingAnimation(...)
}
```

## StripController Changes

StripController owns both `zenDimmer` and a new `overlayDimmer: OverlayDimmer`.

### `updateZenDimmer(at:)`

After the existing `zenDimmer.setFocusedWindow(...)` call, add:

```swift
if !ZenDimmer.cgsAvailable, zenDimmer.enabled, let activeTile = strip.activeColumn?.activeTile {
    overlayDimmer.setFocusedWindow(activeTile.rawValue)
}
```

### `isFullySettled`

On macOS 26+, zen fade animations don't run, so `zenDimmer.isAnimating` is always false. No change needed — the existing check works correctly.

### Lifecycle

- **Init**: Create `OverlayDimmer()` alongside `ZenDimmer()`.
- **Config reload**: Call `overlayDimmer.reloadConfig(config.zenMode)` alongside `zenDimmer.reloadConfig(...)`. If zen was just enabled on 26+, call `overlayDimmer.setFocusedWindow(...)`.
- **Space switch**: Call `overlayDimmer.hide()` before switch, then `overlayDimmer.setFocusedWindow(...)` after restore.
- **Shutdown/Pause**: Call `overlayDimmer.hide()`.
- **Resume**: Call `overlayDimmer.setFocusedWindow(...)` if zen enabled.

## Always-on-top Fallback (macOS 26+)

### AXRaise approach

When `CGSSetWindowLevel` is unavailable, pin behavior changes to "re-raise on every focus change":

In `WindowManager.applyPinState(windowID:pinned:)`:
```swift
private func applyPinState(windowID: CGWindowID, pinned: Bool) {
    if ZenDimmer.cgsAvailable {
        let level = pinned ? CGWindowLevelForKey(.floatingWindow) : CGWindowLevelForKey(.normalWindow)
        ZenDimmer.setWindowLevel(windowID, level)
    } else if pinned {
        // macOS 26+: raise the window immediately
        if let window = tracker.windows[windowID] {
            let _ = window.raise()
        }
    }
    if pinned {
        pinnedWindows.insert(windowID)
    } else {
        pinnedWindows.remove(windowID)
    }
}
```

### Re-raise on focus change

In `handleWindowEvent(.windowFocused)` and `handleWindowEvent(.appActivated)`, after existing logic:

```swift
if !ZenDimmer.cgsAvailable {
    for wid in pinnedWindows {
        if let window = tracker.windows[wid] {
            let _ = window.raise()
        }
    }
}
```

This runs after every focus change, ensuring pinned windows stay above the newly-focused window. It's not as clean as `CGSSetWindowLevel` (there's a brief flicker as windows reorder) but it's functional.

### Limitation

AXRaise brings the window to the front of its app, but if the pinned window's app is not frontmost, macOS may not render it above other apps' windows. This is an accepted limitation on macOS 26+ — `CGSSetWindowLevel` was the only reliable cross-app z-order control, and it's broken.

## Config Changes

No config changes. Same `[zen_mode]`, `[layout] floating_opacity`, `[[rules]] opacity`, `[[rules]] always_on_top` settings. The runtime detection is transparent to the user.

## What doesn't work on macOS 26+

- Per-window rule `opacity` — no effect (CGS-only)
- `floating_opacity` — no effect (CGS-only)  
- Always-on-top — degraded (AXRaise fallback, not as sticky as CGSSetWindowLevel)

Zen dimming works via overlay. Always-on-top works via AXRaise (with limitations).

## Edge Cases

- **Focus indicator + overlay**: The focus indicator (ring/raise/flash) uses its own NSWindow. On macOS 26+, the overlay must be ordered below the focused window but above the indicator's window number to avoid dimming the indicator. Actually — the focus indicator window is owned by ScrollWM at a specific level, so it should render above the overlay naturally. Verify during implementation.
- **Floating windows + overlay**: A floating window that is focused should not be dimmed. `setFocusedWindow` positions the overlay below the focused window regardless of whether it's tiled or floating.
- **Multiple displays**: One overlay per display. Focus change on display A repositions display A's overlay. Display B's overlay is unaffected.
- **Space switch**: Overlays are `.transient` so they don't follow spaces. `hide()` before switch, recreate after.
- **Mission Control**: `.transient` collection behavior means overlays are invisible in Mission Control.
