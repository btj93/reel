# Reel

A scrollable tiling window manager for macOS, inspired by [niri](https://github.com/YaLTeR/niri). Windows live on an infinite horizontal strip. Focus left or right to scroll it.

Requires macOS 15 or later and Accessibility permission. No SIP changes or Dock scripting addition are needed.

## Install and run

Download a release from [GitHub Releases](https://github.com/btj93/reel/releases), place `Reel.app` in Applications and launch it. Grant Accessibility in System Settings when prompted. The menu remains available while permission is pending.

For development:

```sh
swift build
swift run Reel
```

Grant Accessibility to `.build/debug/Reel` once. Rebuild and reuse that path. Do not alternate it with a bundle when debugging permission problems.

```sh
bash scripts/bundle.sh
```

This builds an ad-hoc signed `.build/bundled/Reel.app` without installing or launching it. `make run` bundles and launches the app, after stopping a running Reel. Run it only when you intend to replace your window manager. Start at Login is controlled by the menu and macOS login-item approval.

## Use

| Default binding | Action |
| --- | --- |
| Option-H / Option-L | Focus left / right |
| Option-K / Option-J | Focus the nearest strip above / below |
| Option-Shift-H / Option-Shift-L | Move the active column left / right |
| Option-R | Cycle width presets |
| Option-F | Toggle full width |
| Option-Space | Toggle floating |
| Option-W | Close the focused window |

Hold Fn and swipe horizontally to pan. Flick release projects velocity to a snap target and bounces at the strip edges. Hold Fn on a window title bar and drag to reorder, or hold still to open the width/full-width/floating/close menu. Escape cancels a pointer session. Native title-bar corner resizing remains available.

Horizontally touching displays share a strip when macOS's “Displays have separate Spaces” is off. Otherwise each display has its own strip. The status menu explains the setting and opens System Settings. Space round trips preserve order and focus. Pause hands control back to macOS. Quit returns managed windows on-screen.

Dock clicks, Cmd-Tab and new windows scroll the strip to the window macOS focused; Reel does not re-activate it. Apps with native tabs (Finder, Fork, TablePlus) switch tabs in place: the new tab keeps the column and the focus. If Accessibility is switched off while Reel runs, Reel quits at once so keyboard and mouse input are never held up.

Reorder thumbnails use ScreenCaptureKit. Screen Recording permission may be needed for screenshots. If capture fails, the overlay uses placeholders and reorder still works.

## Config

Reel reads `~/.config/reel/config.toml` and creates it on first launch if absent. Edit it, then choose Reload Config. See [the commented template](config.default.toml).

```toml
[layout]
gap = 8
default_width = 0.5
width_presets = [0.33, 0.5, 0.67]
snap = ["middle"]

[layout.struts]
top = 0

[keys]
focus_left = "alt-h"
focus_right = "alt-l"

[gesture]
modifier = "fn"
snap = true

[indicator]
style = "ring" # none, ring, raise or flash
color = "auto"

[[rules]]
bundle_id = "us.zoom.xos"
floating = true

[[rules]]
title_regex = "^Preferences"
floating = true
```

`bundle_id_regex` is also supported. Multiple match fields in a rule must all match. Rules apply when a window is added, or when a window that appeared untitled gets its first title; later title changes do not re-apply them. Unknown keys and invalid regexes are errors.

## Upgrading from the old runtime

The executable is still `Reel`, the bundle ID is still `dev.reel.Reel`, and the CLI and login-item identity are unchanged. No TCC reset is built into this update, but an ad-hoc signed build changes its code hash, so expect to grant Accessibility again: if Reel keeps showing a `?` in the menu bar, remove it from the Accessibility list with − and add `/Applications/Reel.app` back.

The config schema is new. Your existing file is read at the same path and is never overwritten. An old-schema file produces a menu-bar error naming the first unknown key, and startup continues on defaults. Replace its contents using the new template ([config.default.toml](config.default.toml)). Renamed: `[keybindings]` → `[keys]`, `[focus_indicator]` → `[indicator]`, `app_id` → `bundle_id`, `app_id_regex` → `bundle_id_regex`, `animation_enabled` / `scroll_stiffness` / `scroll_damping_ratio` → `[animation]` `enabled` / `stiffness` / `damping_ratio`. `default_width` takes a proportion only. Removed: `start_at_login` (use the menu), `position_memory`, `saved_position_limit`, `[[position_memory_rules]]`, `cursor.*` and the reorder thumbnail keys.

Old saved layouts are not imported. The new runtime writes `~/.local/state/reel/next-spaces.json`; it does not delete the old state files. Persistence is always on. Clear Saved Positions removes the new saved book.

## CLI and logs

```sh
.build/debug/reel-msg focus-right
.build/debug/reel-msg list-windows
.build/debug/reel-msg get-layout
.build/debug/reel-msg get-layouts
.build/debug/reel-msg list-positions
.build/debug/reel-msg recover
```

`get-layouts` covers every known Space. Each window has expected placement and a fresh bounded AX frame read. `unreadable` means the read failed or missed the deadline. `isOnScreen` and `slivered` describe the fresh frame. A stuck window cannot be hidden by a cached layout result.

Also available are width/move/floating/close commands, `clear-positions`, `clear-positions-app <bundle-id>`, `pause`, `resume`, `reload-config`, `get-status` and `quit`. The bundled CLI is `Reel.app/Contents/MacOS/reel-msg`.

Bundle logs are `~/Library/Logs/Reel/reel.log`, with one `reel.log.1` backup, rotated above 1 MB at launch and during a session. The development binary logs to its terminal. Log lines name windows by ID, not title; `list-windows`, `get-layout` and `get-layouts` do return titles, so avoid publishing their output.

## Architecture and tests

The app uses one pure Engine reducer, a Runtime side-effect shell, macOS wrappers in Platform and pure layout in Core. [AGENTS.md](AGENTS.md) describes ownership and coordinate systems.

```sh
swift run RunTests
swift run RunEngineTests
ENGINE_BENCH=1 swift run -c release RunEngineTests
make smoke-check
make bundle-check
```

The runners do not require XCTest. Live smoke and input/display/Space lanes are opt-in and must run on isolated lane hosts. They can stop a window manager and move real windows. Safe dry runs require both `REEL_E2E_CONFIRM=1` and `SMOKE_DRY_RUN=1`.

## License

[Apache License 2.0](LICENSE)
