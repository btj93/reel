# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

ScrollWM — a macOS scrollable tiling window manager inspired by niri. Windows live on an infinite horizontal strip per display; you scroll left/right to navigate. Swift, Accessibility API, no SIP required.

## Build & Run

```bash
swift build                              # Build all targets
swift run RunTests                       # Run tests (custom runner, not XCTest — no Xcode needed)
swift build && .build/debug/ScrollWM &   # Build and run (grant AX permission once to this path)
.build/debug/scrollwm-msg list-windows   # CLI: send IPC command to running instance
bash scripts/bundle.sh                   # Create .app bundle (for distribution only, not dev)
make run-debug                           # Kill existing, bundle, run with stderr visible
make run                                 # Kill existing, bundle, open .app
```

**macOS 14+ (Sonoma)** minimum — required for `CADisplayLink` on macOS.

**Accessibility permission** persists at `.build/debug/ScrollWM` across rebuilds. Don't use the .app bundle during development — it re-prompts every time.

## Architecture

Five library modules with strict layering:

```
ScrollWM (app entry) ──→ WindowManager ──→ Platform ──→ Core
                              │                         ↑
                              ├──→ Config (TOMLKit) ────┘
                              └──→ IPC ─────────────────┘
```

**Core** — Pure layout logic. Foundation + CoreGraphics only. No AppKit, no AX calls. Fully testable.
- `Strip` + `Column` + `ColumnData`: horizontal strip model. Column X-positions are **derived** from cumulative widths + gaps, never stored.
- `ViewOffset`: scroll state machine — `.static(Double)` / `.animation(SpringAnimation)` / `.gesture(GestureState)`. Everything evaluates via `viewOffset.current(at: time)`.
- `computeTargetFrames(strip:, time:)`: the core pure function. Takes Strip + timestamp, returns `[TargetFrame]` with screen positions, visibility, and off-screen handling. Already animation-aware.
- `SpringAnimation`: analytical damped harmonic oscillator (3 regimes). `retargeted(to:at:)` preserves velocity for rapid keypress compounding.

**Platform** — macOS API wrappers.
- `AXApp`: **one Thread + CFRunLoop per app** for AX observers. Prevents hung apps from blocking main thread.
- `AXWindow`: setFrame uses `size→position→size` workaround. 100ms messaging timeout via `AXUIElementSetMessagingTimeout`. Uses private `_AXUIElementGetWindow` to get CGWindowID (no SIP required).
- `FrameLoop`: CADisplayLink, pauses when idle, resumes on animation start.
- `DisplayManager`: converts NSScreen (AppKit bottom-left coords) to CG (top-left coords) via `primaryScreenHeight - visibleFrame.maxY`.
- `HotkeyManager`: CGEventTap + key string parser (`"hyper-h"` → modifiers + keyCode).
- `ZenDimmer`: dims unfocused windows via private `CGSSetWindowAlpha`. **Main-thread only** — `CGSDefaultConnectionForThread()` returns per-thread connection.
- `FocusIndicator`: visual highlight for active window (ring/raise/flash styles).

**WindowManager** — Orchestration, main thread.
- `WindowManager`: holds `stripControllers: [CGDirectDisplayID: StripController]` — one per monitor. `stripController` (computed) returns the active display's strip.
- `StripController`: two modes — `applyLayout()` (instant) and `handleFrameTick(time:)` (animated). `animationEnabled` toggles between them.
- `WindowTracker`: AX observers + NSWorkspace notifications. Periodic 1s health check catches missed `kAXUIElementDestroyedNotification`.

**Config** — `~/.config/scrollwm/config.toml` via TOMLKit. Reload via menu bar button.

**IPC** — Unix socket at `/tmp/scrollwm_{uid}.sock`. `SocketServer` + `ScrollWMCLI`. Available commands: `focus-left`, `focus-right`, `move-column-left`, `move-column-right`, `cycle-width-preset`, `toggle-full-width`, `toggle-floating`, `toggle-always-on-top`, `close-window`, `list-windows`, `get-layout`, `list-positions`, `clear-positions`, `recover`, `quit`.

## Key Patterns

**Echo suppression**: Our AX setFrame calls trigger move/resize notifications back. `lastLayoutTime` + 150ms window in `handleWindowEvent` ignores these echoes.

**Animation flow**: hotkey → `strip.focusRightAnimated(at:)` → `viewOffset = .animation(spring)` → `frameLoop.resume()` → tick calls `computeTargetFrames(time:)` → dispatches `setPosition` to per-app background threads → spring converges → `viewOffset = .static(final)` → `frameLoop.pause()`.

**Off-screen windows**: 1px sliver at screen edge (primary), corner-hiding at (-10000,-10000) (fallback for resistant apps).

**Space switching**: saves strip state keyed by on-screen window ID fingerprint. Restores on return, discovers new windows, removes closed ones.

**Rubber-band bounce**: at strip edges, creates underdamped spring (ratio=0.6) with kick velocity that overshoots then bounces back.

**Private APIs**: Three private APIs are used (none require SIP disable): `_AXUIElementGetWindow` (AXUIElement→CGWindowID mapping), `CGSSetWindowAlpha` (per-window opacity for zen mode), and `CGSSetWindowLevel` (per-window level for always-on-top). All are validated by AeroSpace/Amethyst across macOS 10.12–15.

**Threading**: CGS calls (`CGSSetWindowAlpha`) must run on main thread. AX calls are dispatched to per-app background threads via `AXApp`. Layout computation and `computeTargetFrames` run on main thread during frame ticks.

## Testing

`Tests/CoreTests/main.swift` — standalone executable. Uses `check()`, `assertEq()`, `assertClose()`. Add tests as `section("name") do { ... }` blocks. Run: `swift run RunTests`.

## Config

Location: `~/.config/scrollwm/config.toml` (created on first launch). Reload via menu bar "Reload Config" button.

Key sections: `[layout]` (gap, focus_mode, struts, floating_opacity), `[animation]` (stiffness, damping), `[keybindings]` (action = "modifier-key"), `[[rules]]` (app_id/floating/opacity/always_on_top), `[terminal]` (app path).

**Window opacity**: Per-window opacity via `[[rules]]` with `opacity = 0.0–1.0`. Rule opacity overrides zen mode dimming. `floating_opacity` in `[layout]` applies to user-toggled floating windows (alt-space). Priority: rule opacity > floating opacity > zen dim > 1.0.

**Always on top**: Pin any window above all others via `alt-t` hotkey or `[[rules]]` with `always_on_top = true`. Uses private `CGSSetWindowLevel` API (no SIP required). Independent of floating/opacity/zen mode.
