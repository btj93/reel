# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Reel — a macOS scrollable tiling window manager inspired by niri. Windows live on an infinite horizontal strip per display; you scroll left/right to navigate. Swift, Accessibility API, no SIP required.

## Build & Run

```bash
swift build                              # Build all targets
swift run RunTests                       # Run tests (custom runner, not XCTest — no Xcode needed)
swift build && .build/debug/Reel &       # Build and run (grant AX permission once to this path)
.build/debug/reel-msg list-windows       # CLI: send IPC command to running instance
bash scripts/bundle.sh                   # Create .app bundle (for distribution only, not dev)
make run-debug                           # Kill existing, bundle, run with stderr visible
make run                                 # Kill existing, bundle, open .app
```

**macOS 14+ (Sonoma)** minimum — required for `CADisplayLink` on macOS.

**Accessibility permission** persists at `.build/debug/Reel` across rebuilds. Don't use the .app bundle during development — it re-prompts every time.

## Architecture

Five library modules with strict layering:

```
Reel (app entry) ──→ WindowManager ──→ Platform ──→ Core
                              │                         ↑
                              ├──→ Config (TOMLKit) ────┘
                              └──→ IPC ─────────────────┘
```

**Core** — Pure layout logic. Foundation + CoreGraphics only. No AppKit, no AX calls. Fully testable.
- `Strip` + `Column` + `ColumnData`: horizontal strip model. Column X-positions are **derived** from cumulative widths + gaps, never stored.
- `ViewOffset`: scroll state machine — `.static(Double)` / `.animation(SpringAnimation)` / `.gesture(GestureState)`. Everything evaluates via `viewOffset.current(at: time)`.
- `computeTargetFrames(strip:, time:)`: the core pure function. Takes Strip + timestamp, returns `[TargetFrame]` with screen positions, visibility, and off-screen handling. Already animation-aware.
- `SpringAnimation`: analytical damped harmonic oscillator (3 regimes). `retargeted(to:at:)` preserves velocity for rapid keypress compounding.
- `SwipeTracker`: weighted-sample velocity tracker (macOS-style). Used for trackpad gesture momentum.
- `SnapPoint`: `.left` / `.middle` / `.right` — configurable per-column snap alignment targets. `snapIndices` (parallel to columns) tracks the current snap milestone per column for incremental scroll.

**Platform** — macOS API wrappers.
- `AXApp`: **one Thread + CFRunLoop per app** for AX observers. Prevents hung apps from blocking main thread.
- `AXWindow`: setFrame uses `size→position→size` workaround. 100ms messaging timeout via `AXUIElementSetMessagingTimeout`. Uses private `_AXUIElementGetWindow` to get CGWindowID (no SIP required).
- `FrameLoop`: CADisplayLink, pauses when idle, resumes on animation start.
- `DisplayManager`: converts NSScreen (AppKit bottom-left coords) to CG (top-left coords) via `primaryScreenHeight - visibleFrame.maxY`.
- `HotkeyManager`: CGEventTap + key string parser (`"hyper-h"` → modifiers + keyCode).
- `FocusIndicator`: visual highlight for active window (ring/raise/flash styles).
- `GestureCapture`: CGEventTap for trackpad scroll gestures (separate from HotkeyManager). Modifier-gated (default: fn). Suppresses macOS momentum — we handle our own via `SwipeTracker`.
- `TitleBarInteraction`: fn+click/drag state machine (idle→armed→dragging/menu). Corner inset (`titleBarCornerInsetPx`) preserves macOS native resize at window corners.

**WindowManager** — Orchestration, main thread.
- `WindowManager`: holds `stripControllers: [CGDirectDisplayID: StripController]` — one per monitor. `stripController` (computed) returns the active display's strip.
- `StripController`: two modes — `applyLayout()` (instant) and `handleFrameTick(time:)` (animated). `animationEnabled` toggles between them.
- `WindowTracker`: AX observers + NSWorkspace notifications. Periodic 1s health check catches missed `kAXUIElementDestroyedNotification`.
- `StripSnapshotStore` (in `PositionMemory.swift`): replaces the old position memory. Stores ordered strip snapshots keyed by `(displayID, spaceFingerprint)`. Live snapshots use exact keys; disk-loaded entries use fuzzy Jaccard matching (>0.5) on fingerprints.
- `ReorderOverlayController` + `ReorderOverlayWindow`: drag-to-reorder UI. Background screenshot capture → overlay shows column thumbnails → cursor tracking computes insertion index → ghost-settle animation on drop. `isReady` flag + buffered cursor positions handle the race between async capture and early cursor events.

**Config** — `~/.config/reel/config.toml` via TOMLKit. Reload via menu bar button.

**IPC** — Unix socket at `/tmp/reel_{uid}.sock`. `SocketServer` + `ReelCLI`. Available commands: `focus-left`, `focus-right`, `move-column-left`, `move-column-right`, `cycle-width-preset`, `toggle-full-width`, `toggle-floating`, `close-window`, `list-windows`, `get-layout`, `list-positions`, `clear-positions`, `recover`, `quit`.

## Key Patterns

**Echo suppression**: Our AX setFrame calls trigger move/resize notifications back. `lastLayoutTime` + 150ms window in `handleWindowEvent` ignores these echoes.

**Animation flow**: hotkey → `strip.focusRightAnimated(at:)` → `viewOffset = .animation(spring)` → `frameLoop.resume()` → tick calls `computeTargetFrames(time:)` → dispatches `setPosition` to per-app background threads → spring converges → `viewOffset = .static(final)` → `frameLoop.pause()`.

**Focus dispatch (`ScrollMode`)**: `StripController.scrollToWindow(tileID:mode:)` has two modes. Keyboard/IPC focus and pure space-restore use `.center` (default) — resets `snapIndices[col]` to `defaultSnapIndex` and re-centers. External focus events (`.windowFocused` from `kAXFocusedWindowChanged`, `.appActivated` from dock / Cmd+Tab, dock-driven space restore) use `.incrementalSnap` — no-op if the column is already fully visible; otherwise slides to the first unreached snap milestone in the travel direction via `Strip.focusColumnIncremental`. When adding a new external focus trigger, pick `.center` for "I want a clean recenter" and `.incrementalSnap` for "honor where the user is already looking."

**Dock click across Spaces**: `.appActivated` stores the pid in `recentAppActivation` (500ms TTL). `handleSpaceChange` reads it to override `savedFocusTile` with the activated app's AX-focused window on the destination strip. The field is one-shot — consumed on same-space resolution, on space-change consumption, and at the end of the new-space discovery path.

**Off-screen windows**: 1px sliver at screen edge (primary), corner-hiding at (-10000,-10000) (fallback for resistant apps).

**Space switching**: saves strip state keyed by on-screen window ID fingerprint. Restores on return, discovers new windows, removes closed ones.

**Rubber-band bounce**: at strip edges, creates underdamped spring (ratio=0.6) with kick velocity that overshoots then bounces back.

**Private API**: One private API is used (no SIP required): `_AXUIElementGetWindow` (AXUIElement→CGWindowID mapping). Validated stable across macOS 10.12–15 by AeroSpace/Amethyst.

**Visibility zones**: `computeTargetFrames` tags each tile with a `VisibilityZone` (.visible / .nearBuffer / .far). Visible tiles update every frame; near-buffer at low priority; far tiles only on settle. This keeps AX call volume proportional to what the user can see.

**Gesture momentum**: `SwipeTracker` uses weighted-sample velocity (macOS `NSScrollView` weights: 0.15/0.65/0.20) to compute flick velocity at lift-off. StripController then converts to a retargeted spring animation. `gestureSnap` snaps to the nearest column boundary on release.

**Logging**: `logTitle()` in WindowManager uses raw window titles in DEBUG, SHA-256 hash prefix (8 hex) in release — keeps logs useful without leaking window content.

**Threading**: AX calls are dispatched to per-app background threads via `AXApp`. Layout computation and `computeTargetFrames` run on main thread during frame ticks.

## Testing

`Tests/CoreTests/main.swift` — standalone executable. Uses `check()`, `assertEq()`, `assertClose()`. Add tests as `section("name") do { ... }` blocks. Run: `swift run RunTests`.

## Config

Location: `~/.config/reel/config.toml` (created on first launch). Reload via menu bar "Reload Config" button.

Key sections: `[layout]` (gap, struts), `[animation]` (stiffness, damping), `[keybindings]` (action = "modifier-key"), `[[rules]]` (app_id/floating), `[focus_indicator]` (style/color/width).
