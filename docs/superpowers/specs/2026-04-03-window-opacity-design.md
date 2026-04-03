# Window Opacity Design

Per-window opacity via `[[rules]]` config, plus automatic opacity for user-toggled floating windows. Rule opacity overrides all other opacity systems (zen mode, floating).

## Scope

- `opacity` field in `[[rules]]` — applies to any matched window (tiled or floating), overrides zen mode dimming
- `floating_opacity` in `[layout]` — applied to user-toggled floating windows (alt-space), not auto-classified floats
- Priority: rule opacity > floating opacity > zen dim > 1.0
- No animation for rule/floating opacity — instant application
- Space switch, config reload, and shutdown all handle opacity correctly

## Config

### `ScrollWMConfig` (Config.swift)

Add `public var floatingOpacity: Double = 1.0` in the layout section. Default 1.0 means no visible effect unless configured.

### `WindowRuleConfig` (Config.swift)

Add `public var opacity: Double? = nil` field. Update init:
```swift
public init(appID: String? = nil, appIDRegex: String? = nil, titleRegex: String? = nil, floating: Bool = false, opacity: Double? = nil) {
    self.appID = appID
    self.appIDRegex = appIDRegex
    self.titleRegex = titleRegex
    self.floating = floating
    self.opacity = opacity
}
```

### `WindowRule` (WindowTracker.swift)

Add `public var opacity: Double? = nil` field. Update init:
```swift
public init(appID: String? = nil, appIDRegex: String? = nil, titleRegex: String? = nil, classification: WindowClassification, opacity: Double? = nil) {
    self.appID = appID
    self.appIDRegex = appIDRegex
    self.titleRegex = titleRegex
    self.classification = classification
    self.opacity = opacity
}
```

### Parsing (Config.swift `parse(table:base:)`)

**`[layout]` block** (after existing `saved_position_limit` parse, around line 284):
```swift
if let v = readDouble(layout["floating_opacity"]) { config.floatingOpacity = max(0.0, min(1.0, v)) }
```

**`[[rules]]` block** (after existing `floating` parse, around line 318):
```swift
if let v = readDouble(rule["opacity"]) { rc.opacity = max(0.0, min(1.0, v)) }
```

### `applyConfig` (WindowManager.swift line 143)

Forward `opacity` when mapping `WindowRuleConfig` to `WindowRule`:
```swift
tracker.rules = config.rules.map { rule in
    WindowRule(
        appID: rule.appID,
        appIDRegex: rule.appIDRegex,
        titleRegex: rule.titleRegex,
        classification: rule.floating ? .float : .tile,
        opacity: rule.opacity
    )
}
```

### Config default (config.default.toml)

Add to `[layout]` section (commented):
```toml
# floating_opacity = 1.0  # opacity for user-toggled floating windows (0.0–1.0)
```

Add to `[[rules]]` examples (commented):
```toml
# [[rules]]
# app_id = "com.example.app"
# opacity = 0.9
```

## ZenDimmer Changes (Sources/Platform/ZenDimmer.swift)

ZenDimmer gains awareness of rule-based opacity so it can coexist with zen dimming without conflicts.

### New state

```swift
/// Per-window rule-based opacity overrides. These take priority over zen dimming.
private var ruleOpacities: [CGWindowID: Double] = [:]
```

### New public methods

**`setRuleOpacity(for wid: CGWindowID, opacity: Double)`** — Registers a rule opacity for a window. Immediately calls `CGSSetWindowAlpha(cid, wid, Float(opacity))`. Also cancels any in-flight zen fade for this wid by removing it from `fadeAnimations`, and sets `currentAlphas[wid] = opacity` so future zen animations don't start from a stale value. **Invariant: callers MUST NOT pass `opacity >= 1.0`** — use `clearRuleOpacity` instead. A 1.0 entry in `ruleOpacities` would suppress zen dimming for that window permanently.

**`clearRuleOpacity(for wid: CGWindowID)`** — Removes the wid from `ruleOpacities` and explicitly restores the window to 1.0 via `CGSSetWindowAlpha`. If zen mode is enabled, the next `setFocusedWindow` call will animate this window to the appropriate alpha (dim or full). The explicit restore to 1.0 ensures no stale rule alpha persists between clearing and the next zen pass — especially important when zen is disabled (no future `setFocusedWindow` call to fix it).

**`reapplyRuleOpacities()`** — Iterates `ruleOpacities` and calls `CGSSetWindowAlpha` for each entry. Used after space switches when macOS resets compositing alpha.

### Modified methods

**`setFocusedWindow(_:allTileIDs:at:force:)`** — Line 82 changes:
```swift
// Before:
let targetAlpha = (wid == newFocusedWID) ? 1.0 : dimAlpha

// After:
if ruleOpacities[wid] != nil { continue }  // Rule opacity windows skip zen dimming entirely
let targetAlpha = (wid == newFocusedWID) ? 1.0 : dimAlpha
```

Windows with rule opacity are skipped entirely — no zen fade animation is created for them. Their alpha is managed exclusively via `setRuleOpacity`.

**`tick(time:)`** — No changes needed. `fadeAnimations` will never contain rule-opacity windows because `setFocusedWindow` skips them and `setRuleOpacity` removes any stale entries.

**`restoreAll(preserveRuleOpacities: Bool = false)`** — Adds a parameter to control behavior:
- `preserveRuleOpacities: false` (default, used by shutdown/rebuild): Restores all windows to 1.0, clears `ruleOpacities`, `fadeAnimations`, `currentAlphas`, `focusedWindowID`. This is the existing behavior.
- `preserveRuleOpacities: true` (used by zen-disable): Restores non-rule windows to 1.0. Rule-opacity windows are restored to their rule value. Clears `fadeAnimations` and `focusedWindowID`. `currentAlphas` is updated (non-rule entries removed, rule entries set to rule value). `ruleOpacities` is preserved.

```swift
public func restoreAll(preserveRuleOpacities: Bool = false) {
    let cid = CGSDefaultConnectionForThread()
    // Pass 1: restore windows in currentAlphas
    for wid in currentAlphas.keys {
        let restoreAlpha: Float
        if preserveRuleOpacities, let ruleAlpha = ruleOpacities[wid] {
            restoreAlpha = Float(ruleAlpha)
        } else {
            restoreAlpha = 1.0
        }
        CGSSetWindowAlpha(cid, wid, restoreAlpha)
    }
    // Pass 2: ensure rule-opacity windows get their value applied even if not in currentAlphas
    // (can happen if setRuleOpacity was called but zen never animated the window)
    if preserveRuleOpacities {
        for (wid, ruleAlpha) in ruleOpacities where currentAlphas[wid] == nil {
            CGSSetWindowAlpha(cid, wid, Float(ruleAlpha))
        }
    }
    fadeAnimations.removeAll()
    if preserveRuleOpacities {
        // Keep ruleOpacities; update currentAlphas to rule values only
        currentAlphas = ruleOpacities
    } else {
        currentAlphas.removeAll()
        ruleOpacities.removeAll()
    }
    focusedWindowID = nil
}
```

**`reloadConfig(_:)`** — Changes `restoreAll()` call to `restoreAll(preserveRuleOpacities: true)`:
```swift
if wasEnabled && !enabled {
    restoreAll(preserveRuleOpacities: true)
}
```

**`restoreWindow(_:)`** — Always restores to 1.0 (existing behavior), but also clears rule opacity state:
```swift
// Existing CGSSetWindowAlpha(cid, wid, 1.0) remains unchanged.
// Add after:
ruleOpacities.removeValue(forKey: wid)
```

Rationale: `restoreWindow` is called when a window leaves the strip (minimize, close, toggle-float). The window must go to 1.0 — not its rule alpha — because minimized windows show a Dock thumbnail at compositing alpha, and a dimmed thumbnail is wrong. If the window returns (unfloat, deminimize), rule opacity will be re-applied by the caller.

## WindowManager Changes (Sources/WindowManager/WindowManager.swift)

### New state

```swift
/// Opacity applied to floating windows, keyed by CGWindowID.
/// Used to reapply after space switches. Includes both rule opacity and floating_opacity values.
private var floatingWindowOpacities: [CGWindowID: Double] = [:]

/// Windows that were user-toggled to floating (via alt-space / toggle-floating).
/// Distinguished from auto-classified floats for config.floatingOpacity — only user-toggled
/// windows receive floating_opacity. Auto-classified floats only get rule opacity.
private var userToggledFloats: Set<CGWindowID> = []
```

### Helper: resolveRuleOpacity

```swift
/// Find the opacity rule that matches a window, if any.
private func resolveRuleOpacity(for window: AXWindow) -> Double? {
    let bundleID = tracker.apps[window.pid]?.bundleIdentifier
    let title = window.getTitle()
    var props = WindowProperties()
    props.bundleIdentifier = bundleID
    props.title = title
    return tracker.rules.first(where: {
        $0.opacity != nil
        && $0.matches(props)
        // Guard against false positives from WindowRule.matches: regex branches
        // are skipped when the matched property is nil, causing silent match-all.
        && ($0.appIDRegex == nil || bundleID != nil)
        && ($0.titleRegex == nil || title != nil)
    })?.opacity
}
```

Note: This creates a minimal `WindowProperties` with just `bundleIdentifier` and `title` for rule matching. The extra guards prevent false-positive matches: `WindowRule.matches` has a pre-existing behavior where `appIDRegex`/`titleRegex` branches are skipped entirely when the matched property is nil (the `if let` pattern falls through to `return true`). Without these guards, a `titleRegex`-only rule would match all windows when `getTitle()` returns nil (transient AX failure at window-add time).

### Helper: applyFloatingOpacity

Note: `CGSDefaultConnectionForThread` and `CGSSetWindowAlpha` are currently private to ZenDimmer.swift. Add a public static helper on ZenDimmer so WindowManager can set window alpha without re-declaring private CGS functions:

```swift
/// Set a window's compositing alpha directly. Main-thread only.
public static func setWindowAlpha(_ wid: CGWindowID, _ alpha: Float) {
    let cid = CGSDefaultConnectionForThread()
    CGSSetWindowAlpha(cid, wid, alpha)
}
```

All WindowManager call sites use `ZenDimmer.setWindowAlpha(windowID, Float(alpha))`.

```swift
/// Apply opacity to a user-toggled floating window and track it for space-switch reapplication.
/// For user-toggled floats: uses rule opacity if matched, else config.floatingOpacity.
private func applyFloatingOpacity(windowID: CGWindowID, window: AXWindow) {
    let ruleOpacity = resolveRuleOpacity(for: window)
    let alpha = ruleOpacity ?? config.floatingOpacity
    if alpha < 1.0 {
        floatingWindowOpacities[windowID] = alpha
        ZenDimmer.setWindowAlpha(windowID, Float(alpha))
    } else {
        // Explicitly restore — window may have had a prior opacity applied
        floatingWindowOpacities.removeValue(forKey: windowID)
        ZenDimmer.setWindowAlpha(windowID, 1.0)
    }
}
```

### Helper: restoreFloatingOpacity

```swift
/// Restore a floating window to full opacity and remove from tracking.
private func restoreFloatingOpacity(windowID: CGWindowID) {
    floatingWindowOpacities.removeValue(forKey: windowID)
    ZenDimmer.setWindowAlpha(windowID, 1.0)
}
```

### Toggle floating — hotkey path (line 883)

```swift
case .toggleFloating:
    // Unfloat path
    if let focusedWID = getFocusedWindowID(),
       tracker.floatingWindows.contains(focusedWID),
       let window = tracker.windows[focusedWID],
       let app = tracker.apps[window.pid]
    {
        tracker.unmarkFloating(focusedWID)
        userToggledFloats.remove(focusedWID)
        // Restore to 1.0 before unfloating — prevents visual jump
        // when ZenDimmer assumes currentAlpha is 1.0
        restoreFloatingOpacity(windowID: focusedWID)
        stripController.unfloatWindow(window, app: app)
        // Re-apply rule opacity if matched (now as a tiled window)
        if let ruleAlpha = resolveRuleOpacity(for: window), ruleAlpha < 1.0 {
            stripController.zenDimmer.setRuleOpacity(for: focusedWID, opacity: ruleAlpha)
        }
    }
    // Float path
    else if let window = stripController.toggleFloating() {
        tracker.markFloating(window.windowID)
        userToggledFloats.insert(window.windowID)
        applyFloatingOpacity(windowID: window.windowID, window: window)
    }
```

### Toggle floating — IPC path (line 1123)

Same logic as the hotkey path.

### Window added — handleWindowEvent (line 611)

Change from:
```swift
case .windowAdded(let window, let classification):
    guard classification == .tile else { return }
    ...
    sc.addWindow(window, app: app, restoredPosition: saved)
```

To:
```swift
case .windowAdded(let window, let classification):
    switch classification {
    case .tile:
        if let app = tracker.apps[window.pid] {
            let (displayID, sc) = stripControllerEntryForWindow(window)
            let saved = lookupSavedPosition(for: window, on: sc, displayID: displayID)
            sc.addWindow(window, app: app, restoredPosition: saved)
            // Apply rule opacity for tiled windows
            if let ruleAlpha = resolveRuleOpacity(for: window), ruleAlpha < 1.0 {
                sc.zenDimmer.setRuleOpacity(for: window.windowID, opacity: ruleAlpha)
            }
        }
    case .float:
        // Apply rule opacity to auto-classified floating windows (NOT config.floatingOpacity,
        // which is for user-toggled floats only). Track in floatingWindowOpacities for
        // space-switch reapplication.
        if let ruleAlpha = resolveRuleOpacity(for: window), ruleAlpha < 1.0 {
            floatingWindowOpacities[window.windowID] = ruleAlpha
            ZenDimmer.setWindowAlpha(window.windowID, Float(ruleAlpha))
        }
    case .ignore:
        break
    }
```

### Window removed — handleWindowEvent (line 624)

Add floating opacity cleanup:
```swift
case .windowRemoved(let windowID, let tileID):
    // Clean up floating opacity tracking
    if floatingWindowOpacities.removeValue(forKey: windowID) != nil {
        ZenDimmer.setWindowAlpha(windowID, 1.0)
    }
    // Remove from whichever strip has it (existing logic)
    for (_, sc) in stripControllers {
        if sc.windowMap[tileID] != nil {
            sc.removeWindow(tileID: tileID)
            break
        }
    }
```

### Startup/adoption paths

**`adoptUnmanagedWindows` (line 972):** After `targetSC.addWindow(window, app: app, restoredPosition: saved)` on line 1012, apply rule opacity:
```swift
if let ruleAlpha = resolveRuleOpacity(for: window), ruleAlpha < 1.0 {
    targetSC.zenDimmer.setRuleOpacity(for: window.windowID, opacity: ruleAlpha)
}
```

**`handleSpaceChange` — restored space path (line 759):** `ruleOpacities` in ZenDimmer is not persisted in `SavedStripState`. Re-derive from current rules after the space restore is fully complete (including new-window adoption).

Important: `StripController.switchSpace` returns at line 1040. Then `handleSpaceChange` in WindowManager processes gone-window removal (lines 764–768) and new-window adoption (lines 773–795). The rule opacity re-derivation loop must be placed AFTER new-window adoption completes (after line 795), not inside `switchSpace`, so that all windows in the restored `windowMap` — including newly adopted ones — get their rule opacities applied:

```swift
// After new-window adoption block (after line 795) in restored-space path of handleSpaceChange:
// Re-apply rule opacities for all tiled windows — macOS resets compositing alpha on space switch
// and ruleOpacities is not persisted in SavedStripState
for (_, window) in stripController.windowMap {
    if let ruleAlpha = resolveRuleOpacity(for: window), ruleAlpha < 1.0 {
        stripController.zenDimmer.setRuleOpacity(for: window.windowID, opacity: ruleAlpha)
    }
}
```

Note: Rules may have changed while the space was away, so re-deriving from current rules is correct (vs. persisting stale ruleOpacities in SavedStripState).

**`handleSpaceChange` — new space path (line 831):** No special handling needed. `stripController.switchSpace` calls `zenDimmer.restoreAll()` which clears `ruleOpacities`. New windows are discovered via `addWindow` → `handleWindowEvent(.windowAdded)` → rule opacity applied there. Floating window opacity reapplication runs in the common epilogue (see below).

**Floating windows on space switch:** The restored-space path returns early at line 828. Floating opacity reapplication must be placed inside BOTH branches, not after them. Add to the restored-space path (before the `return` at line 828) AND to the new-space path (after `finishBatch`):
```swift
// Reapply floating window opacities — macOS may reset compositing alpha on space switch
for (wid, alpha) in floatingWindowOpacities {
    ZenDimmer.setWindowAlpha(wid, Float(alpha))
}
```

### Config reload — reloadConfig (line 496)

After `applyConfig(newConfig)`:

1. Re-evaluate rule opacities for all tiled windows:
```swift
for (_, sc) in stripControllers {
    for (_, window) in sc.windowMap {
        let ruleAlpha = resolveRuleOpacity(for: window)
        if let alpha = ruleAlpha, alpha < 1.0 {
            sc.zenDimmer.setRuleOpacity(for: window.windowID, opacity: alpha)
        } else {
            // clearRuleOpacity restores to 1.0 internally.
            // If zen is enabled, the next setFocusedWindow will animate to dim/undim.
            sc.zenDimmer.clearRuleOpacity(for: window.windowID)
        }
    }
}
```

2. Re-apply floating opacity. Only user-toggled floating windows get `config.floatingOpacity`; auto-classified floats only get rule opacity. Use `userToggledFloats` to distinguish the two sets:

```swift
// Re-evaluate opacity for all tracked floating windows
var updatedFloatingOpacities: [CGWindowID: Double] = [:]
for wid in tracker.floatingWindows {
    guard let window = tracker.windows[wid] else { continue }
    let ruleAlpha = resolveRuleOpacity(for: window)
    if let ruleAlpha, ruleAlpha < 1.0 {
        // Rule opacity applies to any floating window (user-toggled or auto-classified)
        updatedFloatingOpacities[wid] = ruleAlpha
        ZenDimmer.setWindowAlpha(wid, Float(ruleAlpha))
    } else if userToggledFloats.contains(wid) {
        // User-toggled float without rule opacity — apply config.floatingOpacity
        let alpha = config.floatingOpacity
        if alpha < 1.0 {
            updatedFloatingOpacities[wid] = alpha
            ZenDimmer.setWindowAlpha(wid, Float(alpha))
        } else {
            ZenDimmer.setWindowAlpha(wid, 1.0)
        }
    } else if floatingWindowOpacities[wid] != nil {
        // Auto-classified float that lost its rule — restore to 1.0
        ZenDimmer.setWindowAlpha(wid, 1.0)
    }
    // Auto-classified floats without prior opacity: already at 1.0, no action needed
}
floatingWindowOpacities = updatedFloatingOpacities
```

### Shutdown (line 437)

Existing `restoreAll()` calls use the default `preserveRuleOpacities: false`, which restores everything to 1.0. Additionally, restore floating windows:
```swift
// After existing zenDimmer.restoreAll() calls:
for (wid, _) in floatingWindowOpacities {
    ZenDimmer.setWindowAlpha(wid, 1.0)
}
floatingWindowOpacities.removeAll()
```

## WindowEvent Changes (WindowTracker.swift)

No changes to `WindowEvent` enum. Rule opacity is resolved in `WindowManager` by re-matching the window against `tracker.rules`. This avoids threading opacity through the event system and keeps the tracker simple. The minor cost is a rule re-match at window-add time, but the rules list is typically very short (<10 entries).

## StripController Changes

### `switchSpace` — restored path (line 1031)

No changes in StripController itself. WindowManager handles re-deriving rule opacities after the restore (see above).

### `switchSpace` — new space path (line 1043)

`zenDimmer.restoreAll()` at line 1053 uses default `preserveRuleOpacities: false`, which is correct — new space starts with a clean slate.

## Threading

All `CGSSetWindowAlpha` calls (both in ZenDimmer and the new WindowManager calls via `ZenDimmer.setWindowAlpha`) happen on the main thread. This is already guaranteed:
- ZenDimmer's `tick()` runs in the FrameLoop callback (main thread)
- WindowManager's event handlers run on `DispatchQueue.main`
- Hotkey handlers run on main thread
- Config reload triggers from ConfigWatcher on main thread

### Window deminimized — handleWindowEvent (line 712)

The `windowDeminimized` handler calls `sc.addWindow` directly — it does NOT fire a `.windowAdded` event through the tracker. Rule opacity must be explicitly reapplied:

```swift
case .windowDeminimized(let windowID):
    if let window = tracker.windows[windowID],
        let app = tracker.apps[window.pid]
    {
        let (displayID, sc) = stripControllerEntryForWindow(window)
        let saved = lookupSavedPosition(for: window, on: sc, displayID: displayID)
        sc.addWindow(window, app: app, restoredPosition: saved)
        // Re-apply rule opacity — restoreWindow cleared it on minimize
        if let ruleAlpha = resolveRuleOpacity(for: window), ruleAlpha < 1.0 {
            sc.zenDimmer.setRuleOpacity(for: window.windowID, opacity: ruleAlpha)
        }
    }
```

## Edge Cases

- **Rule with `floating = true` and `opacity = 0.8`**: Window is auto-classified as floating by the rule. At `handleWindowEvent(.windowAdded)` with `.float` classification, rule opacity is resolved and applied. Works correctly.
- **Window minimized with rule opacity**: `removeWindow` calls `zenDimmer.restoreWindow` which restores to 1.0 and clears `ruleOpacities` for this wid. On deminimize, `addWindow` is called and rule opacity is explicitly re-applied by the `windowDeminimized` handler.
- **Rapid focus changes with rule-opacity windows**: ZenDimmer skips rule-opacity windows in `setFocusedWindow`, so no zen animations are created for them. No interaction.
- **Zen mode enabled then disabled with rule-opacity windows**: `reloadConfig` calls `restoreAll(preserveRuleOpacities: true)`. Rule-opacity windows keep their rule alpha. Non-rule windows return to 1.0.
- **Config reload changes a rule's opacity**: The reload path iterates all tiled windows, calling `setRuleOpacity` or `clearRuleOpacity`. Floating windows are also re-evaluated.
- **Config reload removes a rule**: `clearRuleOpacity` is called. If zen mode is active, the next `updateZenDimmer` will create a fade animation for the newly-unoverridden window.
- **Space switch**: macOS resets compositing alpha. WindowManager re-derives and reapplies rule opacities for tiled windows after the restore. Floating window opacities are reapplied from `floatingWindowOpacities` dict.
- **Shutdown**: `restoreAll(preserveRuleOpacities: false)` restores all tiled windows to 1.0. Floating window opacities are restored explicitly.
- **Unfloat visual jump**: `restoreFloatingOpacity` sets window to 1.0 before `unfloatWindow` adds it back to the strip. ZenDimmer's `currentAlphas` won't have a stale entry, so zen fade (if enabled) starts cleanly from 1.0.

## Config Default (config.default.toml)

```toml
# floating_opacity = 1.0  # opacity for user-toggled floating windows (0.0–1.0)

# [[rules]]
# app_id = "com.example.app"
# opacity = 0.9            # override zen mode and floating opacity for this app
```
