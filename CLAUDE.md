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
- `SpaceIdentity`: dlsym'd SkyLight Space *queries* — the real Space id and its persistent UUID. Feature-detected; returns nil when unavailable so callers fall back to the legacy fingerprint. Read-only by design; see **Private API** below.
- `FrameLoop`: CADisplayLink, pauses when idle, resumes on animation start.
- `DisplayManager`: converts NSScreen (AppKit bottom-left coords) to CG (top-left coords) via `primaryScreenHeight - visibleFrame.maxY`.
- `HotkeyManager`: CGEventTap + key string parser (`"hyper-h"` → modifiers + keyCode).
- `FocusIndicator`: visual highlight for active window (ring/raise/flash styles).
- `GestureCapture`: CGEventTap for trackpad scroll gestures (separate from HotkeyManager). Modifier-gated (default: fn). Suppresses macOS momentum — we handle our own via `SwipeTracker`.
- `TitleBarInteraction`: fn+click/drag state machine (idle→armed→dragging/menu). Corner inset (`titleBarCornerInsetPx`) preserves macOS native resize at window corners.

**WindowManager** — Orchestration, main thread.
- `WindowManager`: holds `stripControllers: [CGDirectDisplayID: StripController]` — one per monitor. `stripController` (computed) returns the active display's strip.
- `StripController`: two modes — `applyLayout()` (instant) and `handleFrameTick(time:)` (animated). `animationEnabled` toggles between them.
- `WindowTracker`: AX observers + NSWorkspace notifications. Periodic 500ms health check catches missed `kAXUIElementDestroyedNotification`.
- `StripSnapshotStore` (in `PositionMemory.swift`): replaces the old position memory. Stores ordered strip snapshots keyed by `(displayID, spaceFingerprint)`. Live snapshots use exact keys; disk-loaded entries use fuzzy Jaccard matching (>0.5) on fingerprints.
- `ReorderOverlayController` + `ReorderOverlayWindow`: drag-to-reorder UI. Background screenshot capture → overlay shows column thumbnails → cursor tracking computes insertion index → ghost-settle animation on drop. `isReady` flag + buffered cursor positions handle the race between async capture and early cursor events.

**Config** — `~/.config/reel/config.toml` via TOMLKit. Reload via menu bar button.

**IPC** — Unix socket at `/tmp/reel_{uid}.sock`. `SocketServer` + `ReelCLI`. Available commands: `focus-left`, `focus-right`, `focus-up`, `focus-down`, `move-column-left`, `move-column-right`, `cycle-width-preset`, `toggle-full-width`, `toggle-floating`, `close-window`, `list-windows`, `get-layout`, `get-layouts`, `list-positions`, `clear-positions`, `recover`, `quit`. `focus-up`/`focus-down` jump focus to the nearest strip above/below on multi-monitor setups with independent strips. `get-layouts` is a cross-Space diagnostic probe: for every known Space (current + in-session stash + persisted snapshots), queries each window's current AX frame and flags `isOnScreen` / `slivered` — use it to find windows stuck off-screen from a prior Space switch.

## Key Patterns

**Echo suppression**: Our AX setFrame calls trigger move/resize notifications back. `lastLayoutTime` + 150ms window in `handleWindowEvent` ignores these echoes.

**Animation flow**: hotkey → `strip.focusRightAnimated(at:)` → `viewOffset = .animation(spring)` → `frameLoop.resume()` → tick calls `computeTargetFrames(time:)` → dispatches `setPosition` to per-app background threads → spring converges → `viewOffset = .static(final)` → `frameLoop.pause()`.

**Focus dispatch (`ScrollMode`)**: `StripController.scrollToWindow(tileID:mode:)` has two modes. Keyboard/IPC focus and pure space-restore use `.center` (default) — resets `snapIndices[col]` to `defaultSnapIndex` and re-centers. External focus events (`.windowFocused` from `kAXFocusedWindowChanged`, `.appActivated` from dock / Cmd+Tab, dock-driven space restore) use `.incrementalSnap` — no-op if the column is already fully visible; otherwise slides to the first unreached snap milestone in the travel direction via `Strip.focusColumnIncremental`. When adding a new external focus trigger, pick `.center` for "I want a clean recenter" and `.incrementalSnap` for "honor where the user is already looking."

**Dock click across Spaces**: `.appActivated` stores the pid in `recentAppActivation` (500ms TTL). `handleSpaceChange` reads it to override `savedFocusTile` with the activated app's AX-focused window on the destination strip. The field is one-shot — consumed on same-space resolution, on space-change consumption, and at the end of the new-space discovery path.

The TTL alone is NOT sufficient evidence of a dock click: an app that merely activates on its own shortly before a Space change looks identical. The override is therefore rejected unless the activated app had **no window on the departing Space** — crossing Spaces to reach an app is only meaningful if it had nothing where you already were. Skipping this made the view jump to whichever app happened to activate (in practice ChatGPT, whose helper windows churn app focus). `restoreFocus source=…` logs which input won on every restore; four theories about this bug were wrong before that line was added.

**Off-screen windows**: 1px sliver at screen edge — the only technique production actually applies. A corner-hide at (-10000,-10000) is *recognized* by the `get-layouts` diagnostics but nothing ever writes that position; an app whose sliver write fails just stays in the `dirtyTileIDs` retry loop (known gap, pinned by the `TODO(prod-finding)` test in `SimFocusTests`). If a real fallback is implemented, put it behind the sliver-failure path in `StripController` and flip that test.

**Space switching**: strip state is keyed by `Core.SpaceKey` — `.skylight(sid)` when `SpaceIdentity` can read the window server's real Space id, `.fingerprint(Set<CGWindowID>)` otherwise. Authoritative keys match EXACTLY; fingerprints keep Jaccard > 0.5 tolerance. A fingerprint can still recover a `.skylight` stash (matching is done against the fingerprint stored *inside* each `SavedStripState`, not the dictionary key) and re-keys the winner, so one degraded episode cannot orphan a Space's layout.

Identity and census are separate problems, and conflating them is a trap. The sid fixes *which Space this is*. It says nothing about whether `onScreenIDs` is trustworthy — and that list drives `goneIDs → removeWindow`, which cascades through `pruneSavedSpaces` into every other Space's stash. So the empty-read deferral and `spansMultipleSpaces` are **permanent census guards**, and the same-sid check sits AHEAD of them, never instead of them.

**Space-change storms**: macOS has been measured firing 678 notifications in 180s (~4/s) with the sid genuinely cycling. Notifications closer than 300ms are coalesced and acted on once, 250ms after the churn stops. Normal switching pays no latency. The settle delay is deliberately shorter than the storm threshold, so the re-entry backdates `lastSpaceChangeTime` past the threshold — without that it sees its own settle as more churn and defers forever.

**Rubber-band bounce**: at strip edges, creates underdamped spring (ratio=0.6) with kick velocity that overshoots then bounces back.

**Private API**: Two private surfaces, both read-only, neither requiring SIP disabled or a Dock scripting addition:

1. `_AXUIElementGetWindow` (AXUIElement→CGWindowID). Validated stable across macOS 10.12–15 by AeroSpace/Amethyst.
2. **SkyLight Space queries** (`Sources/Platform/SpaceIdentity.swift`) — `SLSMainConnectionID`, `SLSGetActiveSpace`, `SLSManagedDisplayGetCurrentSpace`, `SLSSpaceCopyName`, `SLSSpaceGetType`. Resolved by `dlsym`, never linked, so a macOS release that removes them degrades to `isAvailable == false` and the legacy fingerprint path resumes.

Every SkyLight call is a QUERY. The SkyLight functions that require SIP disabled are all *mutations* (create/destroy/focus Space, move window to Space, set opacity/level/sticky) and none are used — that boundary is deliberate and must be preserved. Verified on macOS 26.6.1 (25G76) from an unsigned binary with SIP enabled and no Accessibility grant. Caveat: `SLSSetWindowAlpha`/`SLSSetWindowLevel` in this same framework became no-ops on macOS 26, which is why the fallback exists.

Why it was worth it: Reel previously identified a Space by fingerprinting the on-screen CGWindowID set and matching by Jaccard similarity. That read is unreliable by construction — observed returning an empty set mid-transition, and a 14-window set spanning four Spaces. yabai and Amethyst both read Space identity from this same SkyLight/CGS family; AeroSpace instead refuses Spaces entirely rather than use a private API.

**Visibility zones**: `computeTargetFrames` tags each tile with a `VisibilityZone` (.visible / .nearBuffer / .far). Visible tiles update every frame; near-buffer at low priority; far tiles only on settle. This keeps AX call volume proportional to what the user can see.

**Gesture momentum**: `SwipeTracker` uses weighted-sample velocity (macOS `NSScrollView` weights: 0.15/0.65/0.20) to compute flick velocity at lift-off. StripController then converts to a retargeted spring animation. `gestureSnap` snaps to the nearest column boundary on release.

**Logging**: `logTitle()` in WindowManager uses raw window titles in DEBUG, SHA-256 hash prefix (8 hex) in release — keeps logs useful without leaking window content.

**Threading**: AX calls are dispatched to per-app background threads via `AXApp`. Layout computation and `computeTargetFrames` run on main thread during frame ticks.

**Multi-monitor strip grouping**: Horizontally-aligned displays (edges touch within 0.5 px AND any Y-overlap) merge into one shared `StripController`; columns flow across the seam, and width presets / full-width resolve against the display a column currently centers on. Stacked or offset displays get independent strips, one `StripController` per `CGDirectDisplayID`. **Merging requires macOS's "Displays have separate Spaces" setting to be OFF** — when it's ON, Reel falls back to per-display strips and surfaces a menu-bar warning that deep-links to the Mission Control pane. Hot-plug and rearrangement merge/split groups live; columns migrate by position.

**AppKit coordinate systems** — three different coord spaces often collide in overlay code:
- **CG** (top-left origin, used by `CGEvent.location`, AX frames, per-display local coords).
- **AppKit global** (bottom-left origin anchored at the primary display's bottom-left; spans all screens).
- **Window-local** (per-window bottom-left origin = the window's AppKit-global origin).

`NSView.convert(_:from: nil)` converts from the view's **window** coordinate system, **not** AppKit-global. Those only coincide when the window sits at `(0, 0)` — i.e. the primary display. Any fullscreen overlay panel (`OverlayWindow`, reorder overlay) created with `contentRect: screen.frame` on a non-primary display has a non-zero origin, so feeding AppKit-global coords into `convert(_:from: nil)` silently miscomputes by `screen.frame.origin`. Route AppKit-global inputs through `NSWindow.convertFromScreen(_:)` / `convertPoint(fromScreen:)` first.

**Logs**: Running the `.app` bundle writes to `~/Library/Logs/Reel/reel.log` (rotated at 1 MB, one backup `reel.log.1`). The bare `.build/debug/Reel` binary logs to the terminal.

## Testing

`Tests/CoreTests/main.swift` — standalone executable. Uses `check()`, `assertEq()`, `assertClose()`. Add tests as `section("name") do { ... }` blocks. Run: `swift run RunTests`.

**Smoke suite (Layer 3, opt-in)**: `Tests/Smoke/smoke.sh` (+ `lib.sh`) drives a REAL `.build/debug/Reel` against `TestWindowHost` NSWindows over `reel-msg`/`jq`. It STOPS your live Reel and opens real windows, so it is gated behind `REEL_E2E_CONFIRM=1` and never runs in `swift run RunTests`.
- `make smoke` — build + run the suite (requires `REEL_E2E_CONFIRM=1` in the env; the developer command is `REEL_E2E_CONFIRM=1 make smoke`).
- `make smoke-check` — `bash -n` + shellcheck (if installed) + a `SMOKE_DRY_RUN=1` walk (validates every jq filter against embedded get-layout/get-status/report fixtures) + a clean build. Launches nothing, touches no window — safe to run anytime.
- Preflight captures the live Reel's exact command (`ps -o command=`), quits it gracefully, and a `trap` relaunches it + polls its socket on exit (even on failure).

**Test env overrides** (production reads them; unset/empty ⇒ normal behavior — the smoke harness sets all four to sandbox itself):
- `REEL_SOCKET_PATH` — IPC socket path (default `NSTemporaryDirectory()/reel_<uid>.sock`). `reelSocketPath()` in `IPC/Commands.swift`; used by both `SocketServer` and `reel-msg`.
- `REEL_CONFIG_DIR` — config dir (default `~/.config/reel`). `ReelConfig.configDir`.
- `REEL_STATE_DIR` — state/snapshot dir (default `~/.local/state/reel`). `ReelConfig.stateDir`.
- `REEL_MANAGE_ONLY_PIDS` — comma-separated pid allowlist; Reel manages ONLY these pids (garbage/empty ⇒ inert = manage all). `WindowTracker.registerApp` guard. The smoke harness pins this to the TestWindowHost pids so the test instance is structurally unable to rearrange real windows.

IPC commands supporting the harness: `pause`/`resume` (route through `togglePause()`), `get-status` (returns `isPaused`/`version`/`socketPath`/`configDir`/`stateDir`/`managedPids` — the split-brain guard), `reload-config` (same reload as the menu-bar button).

## Config

Location: `~/.config/reel/config.toml` (created on first launch). Reload via menu bar "Reload Config" button.

Key sections: `[layout]` (gap, struts), `[animation]` (stiffness, damping), `[keybindings]` (action = "modifier-key"), `[[rules]]` (app_id/floating), `[focus_indicator]` (style/color/width).
