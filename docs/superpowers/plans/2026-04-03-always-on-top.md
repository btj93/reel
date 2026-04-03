# Always On Top (Pin Window) — Implementation Plan

## Context

The user wants to pin windows so they stay above all other windows. This mirrors the recently-implemented window opacity feature: per-app rules via `[[rules]]` config with `always_on_top = true`, plus a hotkey toggle (`alt-t`). Uses private `CGSSetWindowLevel` API (no SIP required, same pattern as `CGSSetWindowAlpha`).

## Approach

Follow the exact opacity feature pattern: CGS API helper in ZenDimmer, config fields in `WindowRuleConfig`/`WindowRule`, state tracking + lifecycle integration in WindowManager, hotkey/IPC action, menu bar item.

Simpler than opacity: boolean (pinned or not), no animation, no zen mode interaction, independent of floating/opacity.

## Files to Modify

| File | Changes |
|------|---------|
| `Sources/Platform/ZenDimmer.swift` | Add `CGSSetWindowLevel` declaration, `setWindowLevel` static, level constants |
| `Sources/Config/Config.swift` | Add `alwaysOnTop: Bool?` to `WindowRuleConfig`, parse from TOML, add `"toggle_always_on_top": "alt-t"` to `ScrollWMConfig.keybindings` default dict (line 32) |
| `Sources/WindowManager/WindowTracker.swift` | Add `alwaysOnTop: Bool? = nil` to `WindowRule` (with default, so existing callsites compile) |
| `Sources/IPC/Commands.swift` | Add `toggleAlwaysOnTop` to `ScrollWMCommand` |
| `Sources/Platform/HotkeyManager.swift` | Add `toggleAlwaysOnTop` to `HotkeyAction`, add to `actionMap` in `registerFromConfig` |
| `Sources/WindowManager/WindowManager.swift` | State (`pinnedWindows`, `userToggledPinned`), helpers, all lifecycle events, hotkey/IPC handlers, forward `alwaysOnTop: rule.alwaysOnTop` in `applyConfig`'s `WindowRule(...)` constructor (line ~149) |
| `Sources/ScrollWM/AppDelegate.swift` | Add menu item (tag 9) in `actions` array AND add `9: .toggleAlwaysOnTop` to `handleMenuAction`'s inner `actionMap` (line 177) |
| `config.default.toml` | Add keybinding + rule example |
| `Tests/CoreTests/main.swift` | Config parsing tests |
| `README.md`, `CLAUDE.md` | Doc updates |

## Key Design Decisions

- **CGS API**: `@_silgen_name("CGSSetWindowLevel") @discardableResult private func CGSSetWindowLevel(_ cid: CGSConnectionID, _ wid: CGWindowID, _ level: Int32) -> CGError` — mirrors `CGSSetWindowAlpha` pattern exactly. Use `CGWindowLevelForKey(.floatingWindow)` (public API, evaluates to 3 on current macOS) and `CGWindowLevelForKey(.normalWindow)` (0) for robustness instead of hardcoded constants.
- **State**: `pinnedWindows: Set<CGWindowID>` (all currently pinned) + `userToggledPinned: Set<CGWindowID>` (user-toggled subset)
- **Hotkey**: Works on macOS-focused window (via `getFocusedWindowID()`), so it works for both tiled AND floating windows, and even untracked windows
- **Independence**: Always-on-top is orthogonal to floating, opacity, and zen mode — a window can be all of these simultaneously
- **Space switch**: Re-apply levels by iterating `pinnedWindows` directly (covers both tiled AND floating pinned windows)
- **Config reload**: Rebuild `pinnedWindows` explicitly (see lifecycle table below for full algorithm)
- **Minimize**: Do NOT remove from `pinnedWindows` on minimize (window leaves strip but pin state is preserved; level is irrelevant while in Dock). Re-apply level on deminimize.
- **Default keybinding**: `alt-t` (not taken)

## Lifecycle Events (exhaustive)

| Event | Action |
|-------|--------|
| **windowAdded** (.tile and .float) | Resolve rule, apply pin if matched |
| **windowRemoved** | Clean up `pinnedWindows` + `userToggledPinned`, best-effort restore level |
| **windowMinimized** | No change to `pinnedWindows`/`userToggledPinned` (pin state preserved). Window IS removed from strip by existing code, but level is irrelevant while minimized. Pin level re-applied on deminimize. |
| **windowDeminimized** | After `addWindow`, re-apply pin level if wid is in `pinnedWindows` OR rule matches. Known limitation: CGWindowID may change on deminimize (macOS behavior), causing the `pinnedWindows` lookup to miss. This matches the existing opacity pattern and is an accepted limitation. |
| **toggleAlwaysOnTop** hotkey/IPC | Toggle pin state on focused window, update `userToggledPinned` |
| **Space switch (restored)** | 1) Evaluate rules for newly-adopted windows (direct `addWindow` bypasses `handleWindowEvent`). 2) Iterate ALL `pinnedWindows` and re-apply levels (covers tiled + floating). |
| **Space switch (new)** | 1) After `finishBatch()`, evaluate rules for new-space windows. 2) Iterate ALL `pinnedWindows` and re-apply levels. |
| **Space switch gone-windows** (line 836) | `stripController.removeWindow` is called directly for windows closed while away — bypasses `handleWindowEvent`. Must explicitly clean `pinnedWindows.remove(goneID)` + `userToggledPinned.remove(goneID)` in the gone-window loop. No level restore needed (window is dead). Note: only covers tiled windows (from `windowMap`); floating pinned windows closed while away are not in this loop — cleanup relies on `windowRemoved` event or health check on return. |
| **Config reload** | Full rebuild algorithm: 1) Save `oldPinned = pinnedWindows`. 2) Start with `newPinned = userToggledPinned` (preserve user intent). 3) Iterate all `stripControllers`' `windowMap` + `tracker.floatingWindows`, evaluate rules, add matches to `newPinned`. 4) Compute `dropped = oldPinned - newPinned`, restore level to normal for each. 5) Set `pinnedWindows = newPinned`. 6) Re-apply `setWindowLevel` for ALL entries in `pinnedWindows` (user-toggled + rule-matched), not just rule-matched — mirrors opacity pattern of always re-applying CGS state on reload. |
| **adoptUnmanagedWindows** | Resolve rule, apply pin if matched |
| **Health check Pass 1** | Bypasses `handleWindowEvent(.windowRemoved)` — must explicitly `pinnedWindows.remove(wid)` + `userToggledPinned.remove(wid)` inline. Note: Pass 1 only iterates `stripController.windowMap` (tiled), so dead floating pinned windows are not caught here (same pre-existing gap as opacity's `floatingWindowOpacities`). |
| **Pause/Resume** | Pause: `restoreAllWindows()` only moves window positions, does NOT touch levels — pin levels survive. Resume: defensively re-apply levels for all `pinnedWindows` after `adoptUnmanagedWindows`. |
| **Shutdown** | Restore all pinned windows to normal level, clear both sets |

## Verification

1. `swift build` — must compile cleanly
2. `swift run RunTests` — all tests must pass
3. Manual test:
   - Add `[[rules]]` with `app_id = "com.apple.calculator"` and `always_on_top = true`
   - Open Calculator — verify it stays above all other windows
   - Press `alt-t` on any other window — verify it pins/unpins
   - Switch spaces and back — verify pin state persists
   - Reload config removing the rule — verify Calculator returns to normal level
   - Minimize a pinned window, deminimize — verify it's still pinned
   - Shutdown ScrollWM — verify all windows return to normal level
