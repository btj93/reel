# Window Opacity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-window opacity via `[[rules]]` config and automatic opacity for user-toggled floating windows, with rule opacity overriding zen mode.

**Architecture:** Extends ZenDimmer with a `ruleOpacities` dict that takes priority over zen dimming. WindowManager gains `floatingWindowOpacities` and `userToggledFloats` tracking dicts. A new `ZenDimmer.setWindowAlpha` static helper exposes CGS calls to WindowManager. Config adds `floating_opacity` to `[layout]` and `opacity` to `[[rules]]`.

**Tech Stack:** Swift, private CoreGraphics API (`CGSSetWindowAlpha`), TOMLKit (Config), custom test runner (no XCTest)

**Spec:** `docs/superpowers/specs/2026-04-03-window-opacity-design.md`

---

### Task 1: Config — Add `opacity` to rules and `floatingOpacity` to layout

**Files:**
- Modify: `Sources/Config/Config.swift`
- Modify: `Sources/WindowManager/WindowTracker.swift`
- Modify: `config.default.toml`
- Modify: `Tests/CoreTests/main.swift`

- [ ] **Step 1: Add `opacity` field to `WindowRuleConfig`**

In `Sources/Config/Config.swift`, add `opacity` to `WindowRuleConfig`:

```swift
public struct WindowRuleConfig: Sendable {
    public var appID: String?
    public var appIDRegex: String?
    public var titleRegex: String?
    public var floating: Bool = false
    public var opacity: Double? = nil

    public init(appID: String? = nil, appIDRegex: String? = nil, titleRegex: String? = nil, floating: Bool = false, opacity: Double? = nil) {
        self.appID = appID
        self.appIDRegex = appIDRegex
        self.titleRegex = titleRegex
        self.floating = floating
        self.opacity = opacity
    }
}
```

- [ ] **Step 2: Add `floatingOpacity` field to `ScrollWMConfig`**

In `Sources/Config/Config.swift`, add in the layout section (after `public var animationEnabled: Bool = true`):

```swift
public var floatingOpacity: Double = 1.0
```

- [ ] **Step 3: Parse `opacity` in `[[rules]]` block**

In `Sources/Config/Config.swift` `parse(table:base:)`, after the `if let v = readBool(rule["floating"]) { rc.floating = v }` line (around line 318), add:

```swift
if let v = readDouble(rule["opacity"]) { rc.opacity = max(0.0, min(1.0, v)) }
```

- [ ] **Step 4: Parse `floating_opacity` in `[layout]` block**

In `Sources/Config/Config.swift` `parse(table:base:)`, after the `if let v = readDouble(layout["saved_position_limit"])` line (around line 284), add:

```swift
if let v = readDouble(layout["floating_opacity"]) { config.floatingOpacity = max(0.0, min(1.0, v)) }
```

- [ ] **Step 5: Add `opacity` field to `WindowRule`**

In `Sources/WindowManager/WindowTracker.swift`, update `WindowRule`:

```swift
public struct WindowRule: Sendable {
    public var appID: String?
    public var appIDRegex: String?
    public var titleRegex: String?
    public var classification: WindowClassification
    public var opacity: Double? = nil

    public init(appID: String? = nil, appIDRegex: String? = nil, titleRegex: String? = nil, classification: WindowClassification, opacity: Double? = nil) {
        self.appID = appID
        self.appIDRegex = appIDRegex
        self.titleRegex = titleRegex
        self.classification = classification
        self.opacity = opacity
    }

    public func matches(_ props: WindowProperties) -> Bool {
        if let id = appID, props.bundleIdentifier != id { return false }

        if let regex = appIDRegex, let bundleID = props.bundleIdentifier {
            guard bundleID.range(of: regex, options: .regularExpression) != nil else { return false }
        }

        if let regex = titleRegex, let title = props.title {
            guard title.range(of: regex, options: .regularExpression) != nil else { return false }
        }

        return true
    }
}
```

- [ ] **Step 6: Update config.default.toml**

In `config.default.toml`, after the zen_mode block (around line 59), add to the existing rules section:

```toml
# [[rules]]
# app_id = "com.example.app"
# opacity = 0.9            # override zen mode and floating opacity for this app
```

And in the `[layout]` section add (commented):

```toml
# floating_opacity = 1.0  # opacity for user-toggled floating windows (0.0–1.0)
```

- [ ] **Step 7: Write config parsing tests**

In `Tests/CoreTests/main.swift`, before the final summary block (before `// ============================================================` around line 1079), add:

```swift
// ═══════════════════════════════════════
print()
print("▶ Window Opacity Config Parsing")

section("default floatingOpacity is 1.0")
do {
    let config = ScrollWMConfig()
    assertClose(config.floatingOpacity, 1.0, tolerance: 0.001, "default floatingOpacity")
}

section("default rule opacity is nil")
do {
    let rule = WindowRuleConfig()
    check(rule.opacity == nil, "default opacity should be nil")
}

section("parse floating_opacity from TOML")
do {
    let (config, _) = ScrollWMConfig.load()
    // Default config has no floating_opacity set, so it should be 1.0
    assertClose(config.floatingOpacity, 1.0, tolerance: 0.001, "loaded default floatingOpacity")
}

section("opacity clamped to 0..1")
do {
    var rc = WindowRuleConfig()
    // Simulate what the parser does
    rc.opacity = max(0.0, min(1.0, -0.5))
    assertClose(rc.opacity!, 0.0, tolerance: 0.001, "negative clamped to 0")
    rc.opacity = max(0.0, min(1.0, 1.5))
    assertClose(rc.opacity!, 1.0, tolerance: 0.001, "over 1 clamped to 1")
}

section("WindowRule carries opacity")
do {
    let rule = WindowRule(appID: "com.test", classification: .tile, opacity: 0.7)
    assertClose(rule.opacity!, 0.7, tolerance: 0.001, "opacity preserved")
}
```

- [ ] **Step 8: Run tests**

Run: `swift run RunTests`
Expected: All tests pass, including new opacity config tests.

- [ ] **Step 9: Commit**

```bash
git add Sources/Config/Config.swift Sources/WindowManager/WindowTracker.swift config.default.toml Tests/CoreTests/main.swift
git commit -m "feat(config): add opacity to rules and floating_opacity to layout"
```

---

### Task 2: ZenDimmer — Add rule opacity support

**Files:**
- Modify: `Sources/Platform/ZenDimmer.swift`

- [ ] **Step 1: Add `ruleOpacities` state**

In `Sources/Platform/ZenDimmer.swift`, after the `private var focusedWindowID: CGWindowID?` line (line 40), add:

```swift
/// Per-window rule-based opacity overrides. These take priority over zen dimming.
private var ruleOpacities: [CGWindowID: Double] = [:]
```

- [ ] **Step 2: Add `setWindowAlpha` static helper**

In `Sources/Platform/ZenDimmer.swift`, after the `public init() {}` line (line 45), add:

```swift
/// Set a window's compositing alpha directly. Main-thread only.
public static func setWindowAlpha(_ wid: CGWindowID, _ alpha: Float) {
    let cid = CGSDefaultConnectionForThread()
    CGSSetWindowAlpha(cid, wid, alpha)
}
```

- [ ] **Step 3: Add `setRuleOpacity` method**

In `Sources/Platform/ZenDimmer.swift`, after the `setWindowAlpha` static method, add:

```swift
/// Register a rule-based opacity for a window. Immediately applies via CGS.
/// Invariant: callers MUST NOT pass opacity >= 1.0 — use clearRuleOpacity instead.
public func setRuleOpacity(for wid: CGWindowID, opacity: Double) {
    ruleOpacities[wid] = opacity
    fadeAnimations.removeValue(forKey: wid)
    currentAlphas[wid] = opacity
    let cid = CGSDefaultConnectionForThread()
    CGSSetWindowAlpha(cid, wid, Float(opacity))
}
```

- [ ] **Step 4: Add `clearRuleOpacity` method**

After `setRuleOpacity`, add:

```swift
/// Remove a rule opacity override and restore the window to 1.0.
public func clearRuleOpacity(for wid: CGWindowID) {
    ruleOpacities.removeValue(forKey: wid)
    let cid = CGSDefaultConnectionForThread()
    CGSSetWindowAlpha(cid, wid, 1.0)
}
```

- [ ] **Step 5: Add `reapplyRuleOpacities` method**

After `clearRuleOpacity`, add:

```swift
/// Reapply all rule opacities via CGS. Used after space switches.
public func reapplyRuleOpacities() {
    let cid = CGSDefaultConnectionForThread()
    for (wid, alpha) in ruleOpacities {
        CGSSetWindowAlpha(cid, wid, Float(alpha))
    }
}
```

- [ ] **Step 6: Modify `setFocusedWindow` to skip rule-opacity windows**

In `Sources/Platform/ZenDimmer.swift`, in `setFocusedWindow`, change the loop body. Before the existing `let targetAlpha = ...` line (line 82), add:

```swift
if ruleOpacities[wid] != nil { continue }
```

So the loop becomes:
```swift
for tileID in allTileIDs {
    let wid = tileID.rawValue
    if ruleOpacities[wid] != nil { continue }  // Rule opacity windows skip zen dimming
    let targetAlpha = (wid == newFocusedWID) ? 1.0 : dimAlpha
    // ... rest unchanged
}
```

- [ ] **Step 7: Modify `restoreAll` to accept `preserveRuleOpacities` parameter**

Replace the existing `restoreAll()` method with:

```swift
/// Restore all tracked windows. Clears all state.
/// When preserveRuleOpacities is true (zen-disable), rule-opacity windows keep their rule value.
/// When false (shutdown/rebuild), everything goes to 1.0.
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
    if preserveRuleOpacities {
        for (wid, ruleAlpha) in ruleOpacities where currentAlphas[wid] == nil {
            CGSSetWindowAlpha(cid, wid, Float(ruleAlpha))
        }
    }
    fadeAnimations.removeAll()
    if preserveRuleOpacities {
        currentAlphas = ruleOpacities
    } else {
        currentAlphas.removeAll()
        ruleOpacities.removeAll()
    }
    focusedWindowID = nil
}
```

- [ ] **Step 8: Modify `reloadConfig` to preserve rule opacities on zen-disable**

In `reloadConfig(_:)`, change:
```swift
if wasEnabled && !enabled {
    restoreAll()
}
```
To:
```swift
if wasEnabled && !enabled {
    restoreAll(preserveRuleOpacities: true)
}
```

- [ ] **Step 9: Modify `restoreWindow` to clear rule opacity state**

In `restoreWindow(_:)`, after the existing `CGSSetWindowAlpha(cid, wid, 1.0)` line, add:

```swift
ruleOpacities.removeValue(forKey: wid)
```

- [ ] **Step 10: Build and verify**

Run: `swift build`
Expected: Build succeeds with no errors.

- [ ] **Step 11: Commit**

```bash
git add Sources/Platform/ZenDimmer.swift
git commit -m "feat(platform): extend ZenDimmer with rule opacity support"
```

---

### Task 3: WindowManager — Forward rule opacity in `applyConfig`

**Files:**
- Modify: `Sources/WindowManager/WindowManager.swift`

- [ ] **Step 1: Forward `opacity` in rule mapping**

In `Sources/WindowManager/WindowManager.swift`, in `applyConfig(_:)` (around line 143), change:

```swift
tracker.rules = config.rules.map { rule in
    WindowRule(
        appID: rule.appID,
        appIDRegex: rule.appIDRegex,
        titleRegex: rule.titleRegex,
        classification: rule.floating ? .float : .tile
    )
}
```

To:

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

- [ ] **Step 2: Build and verify**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/WindowManager/WindowManager.swift
git commit -m "feat(wm): forward rule opacity in applyConfig"
```

---

### Task 4: WindowManager — Add opacity state, helpers, and window-add/remove integration

**Files:**
- Modify: `Sources/WindowManager/WindowManager.swift`

- [ ] **Step 1: Add new state properties**

In `Sources/WindowManager/WindowManager.swift`, after the `private var pendingFocusScroll: DispatchWorkItem?` declaration (around line 52), add:

```swift
/// Opacity applied to floating windows, keyed by CGWindowID.
private var floatingWindowOpacities: [CGWindowID: Double] = [:]

/// Windows that were user-toggled to floating (via alt-space / toggle-floating).
private var userToggledFloats: Set<CGWindowID> = []
```

- [ ] **Step 2: Add `resolveRuleOpacity` helper**

In `Sources/WindowManager/WindowManager.swift`, after the `getFocusedWindowID()` method (around line 922), add:

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
        && ($0.appIDRegex == nil || bundleID != nil)
        && ($0.titleRegex == nil || title != nil)
    })?.opacity
}
```

- [ ] **Step 3: Add `applyFloatingOpacity` helper**

After `resolveRuleOpacity`, add:

```swift
/// Apply opacity to a user-toggled floating window and track it.
private func applyFloatingOpacity(windowID: CGWindowID, window: AXWindow) {
    let ruleOpacity = resolveRuleOpacity(for: window)
    let alpha = ruleOpacity ?? config.floatingOpacity
    if alpha < 1.0 {
        floatingWindowOpacities[windowID] = alpha
        ZenDimmer.setWindowAlpha(windowID, Float(alpha))
    } else {
        floatingWindowOpacities.removeValue(forKey: windowID)
        ZenDimmer.setWindowAlpha(windowID, 1.0)
    }
}
```

- [ ] **Step 4: Add `restoreFloatingOpacity` helper**

After `applyFloatingOpacity`, add:

```swift
/// Restore a floating window to full opacity and remove from tracking.
private func restoreFloatingOpacity(windowID: CGWindowID) {
    floatingWindowOpacities.removeValue(forKey: windowID)
    ZenDimmer.setWindowAlpha(windowID, 1.0)
}
```

- [ ] **Step 5: Modify `handleWindowEvent` — windowAdded case**

In `handleWindowEvent(_:)`, replace the existing `.windowAdded` case (around line 611-622):

```swift
case .windowAdded(let window, let classification):
    guard classification == .tile else { return }
    if let app = tracker.apps[window.pid] {
        let (displayID, sc) = stripControllerEntryForWindow(window)
        let saved = lookupSavedPosition(for: window, on: sc, displayID: displayID)
        #if DEBUG
            print("[WM] windowAdded wid=\(window.windowID) pid=\(window.pid) restored=\(saved != nil)")
            fflush(stdout)
        #endif
        sc.addWindow(window, app: app, restoredPosition: saved)
    }
```

With:

```swift
case .windowAdded(let window, let classification):
    switch classification {
    case .tile:
        if let app = tracker.apps[window.pid] {
            let (displayID, sc) = stripControllerEntryForWindow(window)
            let saved = lookupSavedPosition(for: window, on: sc, displayID: displayID)
            #if DEBUG
                print("[WM] windowAdded wid=\(window.windowID) pid=\(window.pid) restored=\(saved != nil)")
                fflush(stdout)
            #endif
            sc.addWindow(window, app: app, restoredPosition: saved)
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

- [ ] **Step 6: Modify `handleWindowEvent` — windowRemoved case**

In the `.windowRemoved` case (around line 624), add floating opacity cleanup before the existing strip removal logic:

```swift
case .windowRemoved(let windowID, let tileID):
    #if DEBUG
        print("[WM] windowRemoved tileID=\(tileID.rawValue)")
        fflush(stdout)
    #endif
    if floatingWindowOpacities.removeValue(forKey: windowID) != nil {
        ZenDimmer.setWindowAlpha(windowID, 1.0)
    }
    for (_, sc) in stripControllers {
        if sc.windowMap[tileID] != nil {
            sc.removeWindow(tileID: tileID)
            break
        }
    }
```

- [ ] **Step 7: Modify `handleWindowEvent` — windowDeminimized case**

In the `.windowDeminimized` case (around line 712), add rule opacity reapplication after `addWindow`:

```swift
case .windowDeminimized(let windowID):
    #if DEBUG
        print("[WM] windowDeminimized wid=\(windowID)")
        fflush(stdout)
    #endif
    if let window = tracker.windows[windowID],
        let app = tracker.apps[window.pid]
    {
        let (displayID, sc) = stripControllerEntryForWindow(window)
        let saved = lookupSavedPosition(for: window, on: sc, displayID: displayID)
        sc.addWindow(window, app: app, restoredPosition: saved)
        if let ruleAlpha = resolveRuleOpacity(for: window), ruleAlpha < 1.0 {
            sc.zenDimmer.setRuleOpacity(for: window.windowID, opacity: ruleAlpha)
        }
    }
```

- [ ] **Step 8: Build and verify**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 9: Commit**

```bash
git add Sources/WindowManager/WindowManager.swift
git commit -m "feat(wm): add opacity helpers and window add/remove integration"
```

---

### Task 5: WindowManager — Toggle floating opacity and IPC path

**Files:**
- Modify: `Sources/WindowManager/WindowManager.swift`

- [ ] **Step 1: Modify toggleFloating hotkey path**

In `handleHotkeyAction(_:)`, replace the `.toggleFloating` case (around line 883-903):

```swift
case .toggleFloating:
    if let focusedWID = getFocusedWindowID(),
       tracker.floatingWindows.contains(focusedWID),
       let window = tracker.windows[focusedWID],
       let app = tracker.apps[window.pid]
    {
        tracker.unmarkFloating(focusedWID)
        stripController.unfloatWindow(window, app: app)
        #if DEBUG
            print("[WM] Window \(focusedWID) is now tiled (unfloated)")
            fflush(stdout)
        #endif
    } else if let window = stripController.toggleFloating() {
        tracker.markFloating(window.windowID)
        #if DEBUG
            print("[WM] Window \(window.tileID.rawValue) is now floating")
            fflush(stdout)
        #endif
    }
```

With:

```swift
case .toggleFloating:
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
        if let ruleAlpha = resolveRuleOpacity(for: window), ruleAlpha < 1.0 {
            stripController.zenDimmer.setRuleOpacity(for: focusedWID, opacity: ruleAlpha)
        }
        #if DEBUG
            print("[WM] Window \(focusedWID) is now tiled (unfloated)")
            fflush(stdout)
        #endif
    } else if let window = stripController.toggleFloating() {
        tracker.markFloating(window.windowID)
        userToggledFloats.insert(window.windowID)
        applyFloatingOpacity(windowID: window.windowID, window: window)
        #if DEBUG
            print("[WM] Window \(window.tileID.rawValue) is now floating")
            fflush(stdout)
        #endif
    }
```

- [ ] **Step 2: Modify toggleFloating IPC path**

In `handleIPCCommand(_:)`, replace the `.toggleFloating` case (around line 1123-1133):

```swift
case .toggleFloating:
    if let focusedWID = getFocusedWindowID(),
       tracker.floatingWindows.contains(focusedWID),
       let window = tracker.windows[focusedWID],
       let app = tracker.apps[window.pid]
    {
        tracker.unmarkFloating(focusedWID)
        stripController.unfloatWindow(window, app: app)
    } else if let window = stripController.toggleFloating() {
        tracker.markFloating(window.windowID)
    }
    return ScrollWMResponse(success: true)
```

With:

```swift
case .toggleFloating:
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
        if let ruleAlpha = resolveRuleOpacity(for: window), ruleAlpha < 1.0 {
            stripController.zenDimmer.setRuleOpacity(for: focusedWID, opacity: ruleAlpha)
        }
    } else if let window = stripController.toggleFloating() {
        tracker.markFloating(window.windowID)
        userToggledFloats.insert(window.windowID)
        applyFloatingOpacity(windowID: window.windowID, window: window)
    }
    return ScrollWMResponse(success: true)
```

- [ ] **Step 3: Build and verify**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/WindowManager/WindowManager.swift
git commit -m "feat(wm): add opacity to toggle-floating hotkey and IPC paths"
```

---

### Task 6: WindowManager — Space switch, adoption, config reload, and shutdown

**Files:**
- Modify: `Sources/WindowManager/WindowManager.swift`

- [ ] **Step 1: Modify `adoptUnmanagedWindows` to apply rule opacity**

In `adoptUnmanagedWindows(onScreenIDs:)`, after `targetSC.addWindow(window, app: app, restoredPosition: saved)` (around line 1012), add:

```swift
if let ruleAlpha = resolveRuleOpacity(for: window), ruleAlpha < 1.0 {
    targetSC.zenDimmer.setRuleOpacity(for: window.windowID, opacity: ruleAlpha)
}
```

- [ ] **Step 2: Modify `handleSpaceChange` — restored space path**

In `handleSpaceChange()`, in the restored-space branch, after the new-window adoption block (after the `#if DEBUG` block around line 795) and before the focus-restore block (before `if let focusTile = savedFocusTile`), add:

```swift
// Re-apply rule opacities for all tiled windows on restored space
for (_, window) in stripController.windowMap {
    if let ruleAlpha = resolveRuleOpacity(for: window), ruleAlpha < 1.0 {
        stripController.zenDimmer.setRuleOpacity(for: window.windowID, opacity: ruleAlpha)
    }
}
```

And before the `return` at the end of the restored-space branch (around line 828), add:

```swift
// Reapply floating window opacities — macOS may reset compositing alpha on space switch
for (wid, alpha) in floatingWindowOpacities {
    ZenDimmer.setWindowAlpha(wid, Float(alpha))
}
```

- [ ] **Step 3: Modify `handleSpaceChange` — new space path**

In `handleSpaceChange()`, after `stripController.finishBatch()` (around line 854), add:

```swift
// Reapply floating window opacities — macOS may reset compositing alpha on space switch
for (wid, alpha) in floatingWindowOpacities {
    ZenDimmer.setWindowAlpha(wid, Float(alpha))
}
```

- [ ] **Step 4: Modify `reloadConfig` to re-evaluate opacities**

In `reloadConfig()`, after `applyConfig(newConfig)` (around line 507) and before the position memory section, add:

```swift
// Re-evaluate rule opacities for all tiled windows
for (_, sc) in stripControllers {
    for (_, window) in sc.windowMap {
        let ruleAlpha = resolveRuleOpacity(for: window)
        if let alpha = ruleAlpha, alpha < 1.0 {
            sc.zenDimmer.setRuleOpacity(for: window.windowID, opacity: alpha)
        } else {
            sc.zenDimmer.clearRuleOpacity(for: window.windowID)
        }
    }
}

// Re-evaluate floating window opacities
var updatedFloatingOpacities: [CGWindowID: Double] = [:]
for wid in tracker.floatingWindows {
    guard let window = tracker.windows[wid] else { continue }
    let ruleAlpha = resolveRuleOpacity(for: window)
    if let ruleAlpha, ruleAlpha < 1.0 {
        updatedFloatingOpacities[wid] = ruleAlpha
        ZenDimmer.setWindowAlpha(wid, Float(ruleAlpha))
    } else if userToggledFloats.contains(wid) {
        let alpha = config.floatingOpacity
        if alpha < 1.0 {
            updatedFloatingOpacities[wid] = alpha
            ZenDimmer.setWindowAlpha(wid, Float(alpha))
        } else {
            ZenDimmer.setWindowAlpha(wid, 1.0)
        }
    } else if floatingWindowOpacities[wid] != nil {
        ZenDimmer.setWindowAlpha(wid, 1.0)
    }
}
floatingWindowOpacities = updatedFloatingOpacities
```

- [ ] **Step 5: Modify `shutdown` to restore floating opacities**

In `shutdown()`, after the existing `sc.zenDimmer.restoreAll()` loop (around line 450-452), add:

```swift
// Restore floating window opacities
for (wid, _) in floatingWindowOpacities {
    ZenDimmer.setWindowAlpha(wid, 1.0)
}
floatingWindowOpacities.removeAll()
```

- [ ] **Step 6: Build and verify**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 7: Run all tests**

Run: `swift run RunTests`
Expected: All tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/WindowManager/WindowManager.swift
git commit -m "feat(wm): add opacity for space switch, adoption, config reload, shutdown"
```

---

### Task 7: Manual integration test

This task verifies the feature works end-to-end with the running application.

- [ ] **Step 1: Configure a test rule**

Edit `~/.config/scrollwm/config.toml` and add:

```toml
[layout]
floating_opacity = 0.7

[[rules]]
app_id = "com.apple.finder"
opacity = 0.5
```

- [ ] **Step 2: Build and run**

Run: `swift build && .build/debug/ScrollWM &`

- [ ] **Step 3: Verify rule opacity**

Open Finder. Verify the Finder window appears at 50% opacity. Other tiled windows should be fully opaque (unless zen mode dims them).

- [ ] **Step 4: Verify floating opacity**

Focus any non-Finder window and press `alt-space` to toggle it floating. Verify it becomes 70% opaque. Press `alt-space` again to unfloat it. Verify it returns to full opacity.

- [ ] **Step 5: Verify zen mode interaction**

Enable zen mode in config:
```toml
[zen_mode]
enabled = true
dim_alpha = 0.3
```

Reload config (menu bar button). Verify unfocused windows dim to 0.3 alpha, but the Finder window stays at 0.5 (rule overrides zen).

- [ ] **Step 6: Verify config reload**

Change `opacity = 0.5` to `opacity = 0.8` in the rule. Reload config. Verify Finder window opacity updates to 0.8.

Remove the `opacity` line from the rule. Reload config. Verify Finder window returns to normal opacity (or zen dim if zen mode is on).

- [ ] **Step 7: Clean up test config**

Remove the test rules from `~/.config/scrollwm/config.toml`.
