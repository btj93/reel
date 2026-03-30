# Start at Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `start_at_login` config key that registers ScrollWM as a macOS login item via SMAppService.

**Architecture:** Top-level boolean in config.toml parsed by Config module. AppDelegate imports ServiceManagement and calls register/unregister on startup and config reload, guarded by a bundle-identifier check for dev builds.

**Tech Stack:** Swift, ServiceManagement framework (SMAppService), TOMLKit

**Spec:** `docs/superpowers/specs/2026-03-30-start-at-login-design.md`

---

### Task 1: Add `startAtLogin` to Config

**Files:**
- Modify: `Sources/Config/Config.swift:6-54` (struct fields)
- Modify: `Sources/Config/Config.swift:136-205` (parse function)
- Modify: `Sources/Config/Config.swift:214-273` (default config template)

- [ ] **Step 1: Add the field to ScrollWMConfig struct**

In `Sources/Config/Config.swift`, add a new MARK section and field after the Terminal section (after line 48):

```swift
// MARK: - Startup

public var startAtLogin: Bool = false
```

- [ ] **Step 2: Parse the key in `parse(table:)`**

In `Sources/Config/Config.swift`, add parsing after the `[terminal]` block (after line 202, before `return config`):

```swift
// start_at_login (top-level)
if let v = readBool(table["start_at_login"]) { config.startAtLogin = v }
```

- [ ] **Step 3: Add to default config template**

In `Sources/Config/Config.swift`, inside `createDefaultConfig()`, add a commented entry at the top of the template string, after the `# Edit this file...` comment and before `[layout]`:

```swift
# Start ScrollWM automatically when you log in (requires .app bundle)
# start_at_login = false

```

- [ ] **Step 4: Build to verify**

Run: `swift build`
Expected: Compiles with no errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/Config/Config.swift
git commit -m "config: add start_at_login boolean field"
```

---

### Task 2: Add SMAppService integration to AppDelegate

**Files:**
- Modify: `Sources/ScrollWM/AppDelegate.swift`

- [ ] **Step 1: Add ServiceManagement import**

In `Sources/ScrollWM/AppDelegate.swift`, add after the existing imports (after line 4):

```swift
import ServiceManagement
```

- [ ] **Step 2: Add `applyLoginItem` method**

In `Sources/ScrollWM/AppDelegate.swift`, add a new private method before the `@objc` methods (before line 104):

```swift
private func applyLoginItem(enabled: Bool) {
    guard Bundle.main.bundleIdentifier != nil else {
        if enabled {
            print("[ScrollWM] start_at_login requires running as .app bundle — ignoring")
            fflush(stdout)
        }
        return
    }
    let service = SMAppService.mainApp
    do {
        if enabled && service.status != .enabled {
            try service.register()
            print("[ScrollWM] Registered as login item")
            fflush(stdout)
        } else if !enabled && service.status == .enabled {
            try service.unregister()
            print("[ScrollWM] Unregistered login item")
            fflush(stdout)
        }
    } catch {
        print("[ScrollWM] Login item error: \(error)")
        fflush(stdout)
    }
}
```

- [ ] **Step 3: Call on startup**

In `Sources/ScrollWM/AppDelegate.swift`, in `startWindowManager()` (line 97-102), add the call after `windowManager = wm` and before the print:

```swift
private func startWindowManager() {
    let wm = WindowManager()
    wm.start()
    windowManager = wm
    applyLoginItem(enabled: wm.config.startAtLogin)
    print("[ScrollWM] Ready")
}
```

- [ ] **Step 4: Call on config reload**

In `Sources/ScrollWM/AppDelegate.swift`, in `reloadConfig()` (line 115-117), add the call after delegating to WindowManager:

```swift
@objc private func reloadConfig() {
    windowManager?.reloadConfig()
    if let config = windowManager?.config {
        applyLoginItem(enabled: config.startAtLogin)
    }
}
```

- [ ] **Step 5: Build to verify**

Run: `swift build`
Expected: Compiles with no errors.

- [ ] **Step 6: Commit**

```bash
git add Sources/ScrollWM/AppDelegate.swift
git commit -m "feat: register/unregister login item via SMAppService on startup and config reload"
```

---

### Task 3: Manual verification

- [ ] **Step 1: Run existing tests**

Run: `swift run RunTests`
Expected: All tests pass (no Core logic changed).

- [ ] **Step 2: Test bundle guard (dev build)**

Run from terminal:
```bash
swift build && .build/debug/ScrollWM &
```

With `start_at_login = true` in `~/.config/scrollwm/config.toml`, verify the log contains:
```
[ScrollWM] start_at_login requires running as .app bundle — ignoring
```

Then quit with `scrollwm-msg quit` or kill the process.

- [ ] **Step 3: Test with .app bundle**

```bash
bash scripts/bundle.sh
```

Run the bundled app. With `start_at_login = true`, verify the log shows:
```
[ScrollWM] Registered as login item
```

Open System Settings > General > Login Items — ScrollWM should appear.

- [ ] **Step 4: Test config reload**

While the bundled app is running, change `start_at_login = false` in config.toml, then click "Reload Config" in the menu bar. Verify the log shows:
```
[ScrollWM] Unregistered login item
```

And ScrollWM disappears from System Settings > Login Items.

- [ ] **Step 5: Test default (key absent)**

Remove `start_at_login` from config.toml entirely. Reload config. Verify no login item log messages (defaults to false, status already not-enabled, so the guard skips both branches silently).
