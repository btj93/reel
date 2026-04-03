# Always On Top (Pin Window) Design

Pin any window above all others via hotkey toggle or per-app `[[rules]]` config. Uses private `CGSSetWindowLevel` API (no SIP required, same pattern as `CGSSetWindowAlpha`). Independent of floating, opacity, and zen mode.

## Config

### `WindowRuleConfig` / `WindowRule`

Add `alwaysOnTop: Bool? = nil` to both structs. Parsed from `[[rules]]` as `always_on_top`.

### Keybinding

Default: `toggle_always_on_top = "alt-t"`. Added to `ScrollWMConfig.keybindings` default dict, `HotkeyAction` enum, `HotkeyManager.actionMap`, `ScrollWMCommand` enum, and `AppDelegate` menu (tag 9).

## CGS API

```swift
@_silgen_name("CGSSetWindowLevel")
@discardableResult
private func CGSSetWindowLevel(_ cid: CGSConnectionID, _ wid: CGWindowID, _ level: Int32) -> CGError
```

Static helper on ZenDimmer:
```swift
public static func setWindowLevel(_ wid: CGWindowID, _ level: Int32) {
    let cid = CGSDefaultConnectionForThread()
    CGSSetWindowLevel(cid, wid, level)
}
```

Level values: `CGWindowLevelForKey(.floatingWindow)` for pinned, `CGWindowLevelForKey(.normalWindow)` for normal.

## State (WindowManager)

```swift
private var pinnedWindows: Set<CGWindowID> = []
private var userToggledPinned: Set<CGWindowID> = []
```

Helper: `resolveAlwaysOnTop(for:)` — matches rules with `alwaysOnTop != nil`, guards against nil bundleID/title false positives (same as `resolveRuleOpacity`).

Helper: `applyPinState(windowID:pinned:)` — calls `ZenDimmer.setWindowLevel`, updates `pinnedWindows`.

## Lifecycle

- **windowAdded**: Resolve rule, apply pin if matched (both .tile and .float)
- **windowRemoved**: Clean `pinnedWindows` + `userToggledPinned`, best-effort restore level
- **windowMinimized**: No change to pin state (preserved in sets, level irrelevant while in Dock)
- **windowDeminimized**: Re-apply pin if in `pinnedWindows` or rule matches
- **toggleAlwaysOnTop hotkey/IPC**: Toggle on focused window, update `userToggledPinned`
- **Space switch (both paths)**: Evaluate rules for newly-adopted windows, re-apply levels for ALL `pinnedWindows` (tiled + floating)
- **Space switch gone-windows** (line 836): Explicit `pinnedWindows.remove` + `userToggledPinned.remove`
- **Config reload**: Rebuild `pinnedWindows` = `userToggledPinned` ∪ {rule matches}. Restore dropped. Re-apply all.
- **adoptUnmanagedWindows**: Resolve rule, apply pin if matched
- **Health check Pass 1**: Explicit inline cleanup (bypasses event handler)
- **Pause/Resume**: Levels survive pause. Defensively re-apply on resume.
- **Shutdown**: Restore all to normal level, clear sets
