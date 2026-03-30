# Start at Login

## Summary

Add a `start_at_login` config key that registers ScrollWM as a macOS login item via `SMAppService`. Config file is the single source of truth — no menu toggle, no IPC command.

## Config

Top-level key in `~/.config/scrollwm/config.toml`:

```toml
start_at_login = false
```

- Defaults to `false` when absent
- Applied on startup and config reload

## Implementation

### Config module (`Sources/Config/Config.swift`)

Add field to `ScrollWMConfig`:

```swift
public var startAtLogin: Bool = false
```

Parse in `parse()`:

```swift
if let v = readBool(table["start_at_login"]) { config.startAtLogin = v }
```

Add commented entry to `createDefaultConfig()` template:

```toml
# Start ScrollWM automatically when you log in (requires .app bundle)
# start_at_login = false
```

### App entry point (`Sources/ScrollWM/AppDelegate.swift`)

Add `import ServiceManagement` at the top.

New private method:

```swift
private func applyLoginItem(enabled: Bool) {
    guard Bundle.main.bundleIdentifier != nil else {
        if enabled {
            print("[ScrollWM] start_at_login requires running as .app bundle — ignoring")
        }
        return
    }
    let service = SMAppService.mainApp
    do {
        if enabled && service.status != .enabled {
            try service.register()
            print("[ScrollWM] Registered as login item")
        } else if !enabled && service.status == .enabled {
            try service.unregister()
            print("[ScrollWM] Unregistered login item")
        }
    } catch {
        print("[ScrollWM] Login item error: \(error)")
    }
}
```

Called from two places:

1. **Startup** — in `startWindowManager()`, after `WindowManager` is created:
   ```swift
   applyLoginItem(enabled: windowManager!.config.startAtLogin)
   ```

2. **Config reload** — in `reloadConfig()`, after `windowManager?.reloadConfig()`:
   ```swift
   applyLoginItem(enabled: windowManager!.config.startAtLogin)
   ```

### Bundle guard

`Bundle.main.bundleIdentifier != nil` detects whether the app is running as a `.app` bundle or a bare executable from `.build/debug/`. When running outside a bundle with `start_at_login = true`, log a warning and skip. No error, no crash.

### Status check before register/unregister

`SMAppService.mainApp.register()` and `.unregister()` throw if already in the target state. Guard with status checks:

- Only `register()` when `service.status != .enabled`
- Only `unregister()` when `service.status == .enabled`

### No unregister on quit

Login items persist across app restarts — that's the point. Only unregister when the config value changes to `false`.

## Files changed

| File | Change |
|------|--------|
| `Sources/Config/Config.swift` | Add `startAtLogin` field, parse from TOML, add to default template |
| `Sources/ScrollWM/AppDelegate.swift` | `import ServiceManagement`, add `applyLoginItem()`, call on startup and reload |

## Testing

- `swift run RunTests` — existing tests pass (no Core logic changed)
- Manual: set `start_at_login = true` in config, run bundled app, check System Settings > General > Login Items
- Manual: change to `false`, reload config via menu, verify removed from Login Items
- Manual: run from `.build/debug/ScrollWM` with `start_at_login = true`, verify warning logged and no crash

## Out of scope

- Menu bar toggle for login item
- IPC command for login item
- Launch agent plist fallback for non-bundled builds
