# ScrollWM

A scrollable tiling window manager for macOS, inspired by [niri](https://github.com/YaLTeR/niri).

Windows live on an infinite horizontal strip. New windows appear to the right without resizing existing ones. Scroll left and right to navigate. No SIP disable required.

## How It Works

Instead of cramming every window into visible screen space, ScrollWM arranges them on a strip that extends beyond the screen edges. The focused window (and its neighbors) stay visible; everything else is parked off-screen. Navigate with keyboard shortcuts or trackpad gestures.

- **Infinite strip** — windows tile horizontally, one per column. Open as many as you want.
- **Spring animations** — scrolling uses a damped harmonic oscillator for physics-based motion. Rapid keypresses compound velocity naturally.
- **Trackpad gestures** — hold a modifier (default: `fn`) and swipe to scroll the strip.
- **Per-display strips** — each monitor gets its own independent strip.
- **Space-aware** — switching macOS Spaces saves and restores strip state automatically.
- **Position memory** — windows reopen in their previous strip position.
- **Zen mode** — dims unfocused windows to highlight what you're working on.
- **Focus indicator** — ring, raise, or flash style highlight for the active window.
- **Floating windows** — toggle any window out of the strip. Rules can auto-float by app.
- **IPC** — control ScrollWM from scripts via a Unix socket CLI.

## Requirements

- macOS 14 (Sonoma) or later
- Accessibility permission (prompted on first launch)
- Swift 5.10+ toolchain

## Install

### From Source

```bash
git clone https://github.com/user/scrollwm.git
cd scrollwm
swift build
```

#### Run During Development

```bash
swift build && .build/debug/ScrollWM &
```

Accessibility permission is granted to `.build/debug/ScrollWM` and persists across rebuilds.

#### Create .app Bundle

```bash
bash scripts/bundle.sh
open .build/bundled/ScrollWM.app
```

The bundle script ad-hoc signs with a stable identifier so macOS doesn't revoke Accessibility permission on each rebuild. Use the bundle for distribution or if you need an .app — for daily development, run the binary directly.

### First Launch

1. Build and run ScrollWM
2. macOS will prompt for Accessibility permission — grant it
3. A menu bar icon appears (ScrollWM runs as a menu bar app, no Dock icon)
4. Open some windows — they tile automatically

## Default Keybindings

| Action | Default | Description |
|--------|---------|-------------|
| Focus left | `Alt-H` | Scroll to the window on the left |
| Focus right | `Alt-L` | Scroll to the window on the right |
| Move left | `Alt-Shift-H` | Move the focused column left |
| Move right | `Alt-Shift-L` | Move the focused column right |
| Cycle width | `Alt-R` | Cycle through width presets (33% / 50% / 67%) |
| Full width | `Alt-F` | Toggle focused window to full screen width |
| Toggle floating | `Alt-Space` | Float/unfloat the focused window |
| Close window | `Alt-W` | Close the focused window |

**Note:** `Alt` (Option) key bindings consume special character input (e.g., `Alt-H` produces `˙`). Rebind if this conflicts with your workflow.

Trackpad: hold `fn` + swipe horizontally to scroll the strip.

## Configuration

ScrollWM reads `~/.config/scrollwm/config.toml`, created on first launch with defaults. Changes apply on save — reload via the menu bar "Reload Config" button.

### Layout

```toml
[layout]
gap = 16                           # Gap between columns in points
snap = ["middle"]                  # Column snap positions: "left", "middle", "right"
animation_enabled = true
# width_presets = [0.33, 0.5, 0.67]  # Proportions for cycle_width
# default_width = { proportion = 0.5 }
# position_memory = true

# Insets for external status bars (e.g., SketchyBar)
# [layout.struts]
# left = 0
# right = 0
# top = 0
# bottom = 0
```

### Animation

```toml
[animation]
scroll_stiffness = 800          # Higher = snappier scrolling
scroll_damping_ratio = 1.0      # 1.0 = critically damped (no overshoot)
bounce_distance = 40            # Rubber-band distance at strip edges
bounce_damping_ratio = 0.6      # < 1.0 = underdamped bounce
```

### Keybindings

```toml
[keybindings]
focus_left = "alt-h"
focus_right = "alt-l"
move_left = "alt-shift-h"
move_right = "alt-shift-l"
cycle_width = "alt-r"
toggle_full_width = "alt-f"
toggle_floating = "alt-space"
close_window = "alt-w"
```

Modifier names: `ctrl`, `shift`, `cmd`, `alt`/`opt`, `fn`, `hyper` (ctrl+shift+cmd+alt).

### Gestures

```toml
[gesture]
modifier = "fn"     # Hold this key + trackpad scroll to pan the strip
snap = true         # Snap to columns after gesture ends
```

### Focus Indicator

```toml
[focus_indicator]
style = "ring"          # "none", "ring", "raise", or "flash"
color = "auto"          # "auto" (system accent) or hex "#RRGGBB"
width = 3               # Border width in points (ring mode)
corner_radius = 10      # Corner radius in points (ring mode)
```

### Zen Mode

```toml
[zen_mode]
enabled = false
dim_alpha = 0.3       # Opacity of unfocused windows (0.0 = invisible, 1.0 = no dim)
fade_duration = 0.15  # Fade animation duration in seconds
```

### Window Rules

Float specific apps or match by regex:

```toml
[[rules]]
app_id = "us.zoom.xos"
floating = true

[[rules]]
app_id_regex = "com\\.apple\\.systempreferences"
floating = true
```

### Position Memory Rules

Control how windows are matched for position restore:

```toml
[[position_memory_rules]]
app_id = "com.apple.finder"
match_by = "order"    # "title" (default) or "order"
```

## CLI

`scrollwm-msg` sends commands to the running ScrollWM instance over a Unix socket.

```bash
# Build the CLI
swift build

# Example commands
.build/debug/scrollwm-msg list-windows
.build/debug/scrollwm-msg focus-left
.build/debug/scrollwm-msg get-layout
.build/debug/scrollwm-msg toggle-floating
```

Available commands: `focus-left`, `focus-right`, `move-column-left`, `move-column-right`, `cycle-width-preset`, `toggle-full-width`, `toggle-floating`, `close-window`, `list-windows`, `get-layout`, `list-positions`, `clear-positions`, `recover`, `quit`.

## Architecture

Five Swift modules with strict layering:

```
ScrollWM (app entry) ──→ WindowManager ──→ Platform ──→ Core
                              │                         ↑
                              ├──→ Config (TOMLKit) ────┘
                              └──→ IPC ─────────────────┘
```

- **Core** — Pure layout logic. Foundation + CoreGraphics only. No AppKit, no Accessibility calls. Fully unit-testable. Contains the strip model, spring animation solver, and `computeTargetFrames` (the core pure function that maps strip state to screen positions).
- **Platform** — macOS API wrappers: Accessibility (per-app background threads), CGEventTap hotkeys, CADisplayLink frame loop, display management, focus indicator, zen dimmer, gesture capture.
- **WindowManager** — Orchestration layer. One `StripController` per display. Handles window tracking, space switching, position memory, and bridges Core layout to real window positioning.
- **Config** — TOML configuration via TOMLKit.
- **IPC** — Unix socket server + CLI client.

## License

Apache License 2.0 — see [LICENSE](LICENSE) for details.
