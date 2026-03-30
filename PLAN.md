# ScrollWM: A Scrollable Tiling Window Manager for macOS

## Context

Build a macOS window manager replicating **niri's signature feature**: windows on an infinite horizontal strip, scroll to navigate. New windows appear to the right without resizing existing ones.

**Prior art**: Paneru (Rust+Bevy), OmniWM (Swift), ChainYourMac (Rust+SwiftUI), PaperWM.spoon (Lua/Hammerspoon).

**Key macOS constraints**: No compositor access; Accessibility API to puppet windows; macOS forces off-screen windows back; no public Spaces API.

---

## Language & Build System

**Swift** — 80% of code is Apple API interop. First-class bridging for AXUIElement, CGEventTap, CADisplayLink. AeroSpace validates this at scale.

**Build**: `swift-bundler` (no Xcode IDE needed)

```bash
brew install stackotter/tap/swift-bundler
swift bundler build --product ScrollWM
open .build/bundled/ScrollWM.app
```

`swift-bundler` wraps SPM and produces `.app` bundles with `Info.plist` (`LSUIElement=true` for menu-bar-only) and code signing. All development stays in the terminal.

**macOS 14+ (Sonoma)** minimum — required for `CADisplayLink` on macOS.

---

## SIP Policy: Not Required

Single private API: `_AXUIElementGetWindow` (AXUIElement→CGWindowID). No SIP needed. Validated by AeroSpace, Amethyst, Hammerspoon across macOS 10.12–15.

---

## Architecture

```
ScrollWM/
├── Package.swift
├── Bundler.toml                   # swift-bundler config (Info.plist, entitlements)
├── Sources/
│   ├── ScrollWM/                  # Menu bar app (main target)
│   │   └── AppDelegate.swift      # @main, NSStatusItem, permission checks
│   ├── Core/                      # Pure logic (imports Foundation only, not AppKit)
│   │   ├── Strip.swift            # Horizontal strip model
│   │   ├── Column.swift           # Column + ColumnData cache
│   │   ├── ColumnWidth.swift      # Proportion / Fixed / Auto
│   │   ├── ViewOffset.swift       # Scroll state machine
│   │   ├── LayoutEngine.swift     # Strip → target frames (pure function)
│   │   ├── FocusMode.swift        # CenterFocusedColumn: never/always/onOverflow
│   │   ├── WindowFilter.swift     # Window type classification (tile/float/ignore)
│   │   ├── Animation.swift        # Spring/easing/deceleration configs
│   │   ├── SpringSolver.swift     # Damped harmonic oscillator
│   │   └── SwipeTracker.swift     # Velocity estimation (150ms window)
│   ├── Platform/                  # macOS API wrappers
│   │   ├── AXWindow.swift         # AXUIElement wrapper (setFrame, getFrame, observe)
│   │   ├── AXApp.swift            # Per-app thread + AXObserver + CFRunLoop
│   │   ├── AXErrors.swift         # AXError → typed Result mapping
│   │   ├── WindowInfo.swift       # CGWindowListCopyWindowInfo + _AXUIElementGetWindow
│   │   ├── HotkeyManager.swift    # CGEventTap keyboard (with tap-health monitor)
│   │   ├── GestureCapture.swift   # CGEventTap scroll wheel interception
│   │   ├── DisplayManager.swift   # Per-monitor tracking + hot-plug handling
│   │   └── FrameLoop.swift        # Per-monitor CADisplayLink (idle-suspendable)
│   ├── WindowManager/             # Orchestration (runs on @MainActor)
│   │   ├── WindowManager.swift    # Central coordinator + serial event queue
│   │   ├── WindowTracker.swift    # Discover/track/classify windows by AX role+subrole
│   │   ├── StripController.swift  # Layout → AX calls (instant mode OR animated mode)
│   │   ├── SliverManager.swift    # Off-screen window positioning
│   │   ├── WorkspaceManager.swift # Virtual workspace switching
│   │   ├── CrashRecovery.swift    # State persistence + signal handlers + restore
│   │   └── SystemIntegration.swift# Cmd+Tab relayout, fullscreen lifecycle, Mission Ctrl
│   ├── Config/
│   │   └── Config.swift           # TOML parsing + validation + hot-reload
│   ├── IPC/
│   │   ├── SocketServer.swift     # Unix domain socket
│   │   └── Commands.swift         # Shared command enum (used by app + CLI)
│   └── ScrollWMCLI/              # CLI client (imports only IPC/, not Platform/)
│       └── main.swift
└── Tests/
    ├── CoreTests/                 # Unit tests for layout, animation, state machine
    ├── WindowManagerTests/        # Integration tests with mock WindowPositioning protocol
    └── TestWindowHelper/          # Helper app that creates test windows for E2E tests
```

### Key Architecture Decisions

**Thread-per-app (mandatory)**: Each observed app gets a dedicated `Thread` with its own `CFRunLoop` for AX observers. AX calls (`setPosition`, `setSize`) are dispatched to per-app threads to prevent hung apps from stalling the frame loop. The main thread owns all state and the frame loop.

**Serial event queue**: All external events (window created/destroyed/moved, app launched/terminated, display changed) feed into a single serial queue processed once per frame. Prevents race conditions from concurrent AX observer callbacks.

**Instant/Animated mode separation**: `StripController` has two code paths — `applyInstant()` (Phase 1) and `applyAnimated()` (Phase 2). Config toggle `animation_enabled` selects which runs. This is the rollback safety net — if animation is too janky, we fall back to instant with zero code risk.

---

## The Horizontal Strip Model

### Data Model

```
Strip {
  columns: [Column]            -- ordered left to right
  columnData: [ColumnData]     -- parallel cache (widths, animation state)
  activeColumnIndex: Int       -- focused column
  viewOffset: ViewOffset       -- scroll state machine
  focusMode: CenterFocusedColumn  -- never / always / onOverflow
  gap: CGFloat
  workingArea: CGRect
}

Column {
  tiles: [TileID]              -- windows stacked vertically
  activeTileIndex: Int
  width: ColumnWidth           -- proportion(0.5) / fixed(800) / auto
  presetIndex: Int?            -- which preset is active (for cycling)
  isFullWidth: Bool
}

ColumnData {
  cachedWidth: CGFloat         -- resolved pixel width
  widthAnimation: Animation?   -- non-nil during resize animation
}
```

Column X-positions are **derived** from cumulative `columnData.currentWidth + gap`. Never stored.

### Focus Modes (from niri — critical for UX)

```
enum CenterFocusedColumn {
  case never      -- scroll minimum to make focused column visible (edge-snap)
  case always     -- focused column always centered on screen
  case onOverflow -- center only when focused + previous don't both fit
}
```

This controls `computeNewViewOffset(forColumn:)` — the core function that determines where the viewport scrolls to on focus change. All three modes must be implemented in Phase 1.

### ViewOffset State Machine

```
enum ViewOffset {
  case static(Double)           -- no animation
  case animation(Animation)     -- animating toward target
  case gesture(GestureState)    -- active trackpad scroll
}
```

Uses `Double` internally (not `CGFloat`) for animation math precision. Convert to `CGFloat` at AX boundary.

### Window Type Classification

Windows are classified by AX `role` + `subrole` + heuristics:

| Classification | Criteria | Behavior |
|---|---|---|
| **Tile** | `kAXStandardWindowSubrole`, resizable, has close button | Add to strip |
| **Float** | `kAXDialogSubrole`, `kAXFloatingWindowSubrole`, `kAXSystemDialogSubrole`, sheets | Float above strip |
| **Ignore** | Menus, popovers, tooltips, status items, Spotlight, Notification Center | Don't manage |

Additional heuristics: `CGWindowList.kCGWindowLayer != 0` → ignore. Non-resizable → float. App-specific overrides via config rules.

---

## Scrolling & Animation

### Spring Parameters (matching niri defaults)

| Animation | Stiffness | Damping Ratio | Epsilon |
|---|---|---|---|
| Horizontal scroll (focus change) | **800** | 1.0 | 0.0001 |
| Window movement | **800** | 1.0 | 0.0001 |
| Window resize | **800** | 1.0 | 0.0001 |
| Window open | Easing (ease-out-expo, 150ms) | — | — |
| Window close | Easing (ease-out-quad, 150ms) | — | — |

Global `animations.off` config option + respect macOS "Reduce motion" accessibility setting.

### Trackpad Gesture Scrolling

- Modifier: **`fn`** (not `ctrl` — avoids conflict with macOS Accessibility Zoom)
- 1:1 delta tracking during gesture, 150ms velocity window
- Momentum → deceleration → snap to column boundary via spring
- Rubber-band at strip edges

### Frame Loop

- **Per-monitor** `CADisplayLink` (via `NSScreen.displayLink(target:selector:)`)
- Set `preferredFrameRateRange(minimum: 30, maximum: 120, preferred: 120)` for ProMotion
- **Idle suspension**: `displayLink.isPaused = true` when `ViewOffset == .static` — saves battery
- Resume on any input event (hotkey, gesture, window change)

### AX Call Strategy

**Mandatory setup per AXUIElement**: `AXUIElementSetMessagingTimeout(element, 0.1)` — 100ms cap prevents hung apps from blocking for the default 6 seconds.

**Per-app threads dispatch**: Main thread computes target frames → posts `(windowRef, targetFrame)` tuples to per-app threads → per-app threads apply AX calls independently. Main thread never blocks on AX.

**Priority**: focused (P0) → visible (P1) → near-buffer (P2) → far (P3). Position-only during animation; set size once on settle.

---

## Off-Screen Window Handling

### Primary: Sliver (1px visible at screen edge)

~90% reliable for well-behaved Cocoa apps.

### Fallback: Corner Hiding

For apps that fight sliver positioning. Move to `(-10000, -10000)`.

### Re-park handler

On `NSApplicationDidChangeScreenParametersNotification` (monitor plug/unplug, resolution change): immediately cancel animations, re-enumerate displays, rebuild strip from current window positions.

### Mission Control consideration

Sliver-parked windows look broken in Mission Control. **Mitigation**: On Mission Control enter (detected via AX observer on Dock.app), temporarily move slivers to corner-hiding. Restore on Mission Control exit.

---

## Crash Recovery (Critical — new section from reviews)

### State Persistence

Write `~/.local/state/scrollwm/window-state.json` containing `[{cgWindowID, appBundleID, lastKnownFrame}]`.

**Write triggers**: scroll settle, window add/remove, every 5 seconds (coalesced timer). NOT every frame.

### Signal Handlers

`SIGTERM`, `SIGINT` → restore all windows to `lastKnownFrame`, then exit.

### On Launch

Check for stale state file. If windows exist at sliver/corner positions matching state entries, restore to `lastKnownFrame`.

### CLI Recovery Command

`scrollwm recover` — reads state file, moves all windows back on-screen. Works even if main app is dead.

### App Nap Prevention

`ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Window management")` — prevents macOS from throttling ScrollWM when it has no visible windows.

---

## System Integration (new section from reviews)

### Cmd+Tab Re-layout

Observe `kAXApplicationActivatedNotification`. When an app is activated (e.g., via Cmd+Tab), find its window in the strip and scroll to make it visible.

### Fullscreen Lifecycle

- Window enters macOS fullscreen → detect via `kAXFullScreenAttribute` change → remove from strip, save `viewOffsetToRestore`
- Window exits fullscreen → re-add to strip at saved position, restore view offset
- Config option to block native fullscreen and substitute full-width-column

### Stage Manager Detection

On launch, check `defaults read com.apple.WindowManager GloballyEnabled`. Warn user if Stage Manager is active (it fights the WM).

### Secure Input Mode

When a password field is focused, macOS disables all CGEventTaps. Hotkeys stop working. This is unfixable — document it. Poll `CGEventTapIsEnabled()` every 2 seconds, re-enable if disabled.

### CGEventTap Health Monitor

If tap is disabled by macOS (slow callback, permission revoked), detect and re-enable. Show notification if re-enable fails 3 times.

---

## Configuration (TOML)

```toml
[general]
gaps = 16
struts = { left = 0, right = 0, top = 0, bottom = 0 }
animation_enabled = true
animation_speed = 1.0
center_focused_column = "always"  # never / always / on-overflow

[columns]
default_width = { proportion = 0.5 }
presets = [
  { proportion = 0.33 },
  { proportion = 0.5 },
  { proportion = 0.67 },
  { fixed = 800 },
]

[keybindings]
focus_left = "hyper-h"        # Hyper = ctrl+shift+cmd+opt
focus_right = "hyper-l"
move_left = "hyper-shift-h"
move_right = "hyper-shift-l"
resize_wider = "hyper-="
resize_narrower = "hyper--"
cycle_width_preset = "hyper-r"
toggle_full_width = "hyper-f"
toggle_floating = "hyper-space"
close_window = "hyper-w"
workspace_1 = "hyper-1"
workspace_2 = "hyper-2"
spawn_terminal = "hyper-t"

[scroll]
gesture_modifier = "fn"
deceleration_rate = 0.997
spring_damping = 1.0

[[rules]]
match = { app_id = "com.apple.finder" }
open_floating = true

[[rules]]
match = { app_id = "us.zoom.xos" }
open_floating = true

[[rules]]
match = { app_id_regex = "com\\.googlecode\\.iterm2" }
default_column_width = { proportion = 0.67 }
```

**Default modifier**: `Hyper` (Ctrl+Shift+Cmd+Opt) — avoids conflicts with macOS special characters, terminal keybindings, and accessibility zoom. Users can change to `alt`, `ctrl`, etc.

**Config location**: `~/.config/scrollwm/config.toml`

**Validation**: Invalid config → show macOS notification with error message, fall back to defaults. App does not crash.

---

## Implementation Phases

### Phase 1: MVP — Static Tiling + Focus Indicator

**Goal**: Windows tile on strip, keyboard nav works, focus is visible, dialogs float.

| # | File(s) | Task |
|---|---|---|
| 1 | `AppDelegate.swift`, `Bundler.toml` | Menu bar app shell, permission request flow (Accessibility + Input Monitoring), poll for permission grant |
| 2 | `Platform/AXWindow.swift`, `AXErrors.swift` | AXUIElement wrapper: `getFrame()`, `setFrame()` (size→pos→size), `AXEnhancedUserInterface` toggle, `AXUIElementSetMessagingTimeout(0.1)`, typed error handling |
| 3 | `Platform/AXApp.swift` | Per-app thread with dedicated CFRunLoop, AXObserver for window events, `AsyncStream` bridge to main thread |
| 4 | `Platform/WindowInfo.swift` | `_AXUIElementGetWindow` bridge, `CGWindowListCopyWindowInfo` queries |
| 5 | `Core/WindowFilter.swift` | Classify windows by AX role+subrole+heuristics → tile/float/ignore |
| 6 | `Core/Strip.swift`, `Column.swift`, `ColumnWidth.swift` | Strip model with `ColumnData` cache, derived positions |
| 7 | `Core/FocusMode.swift` | `CenterFocusedColumn` — implement `computeNewViewOffset` for all 3 modes |
| 8 | `Core/LayoutEngine.swift` | Pure function: `computeTargetFrames(strip:) → [TileID: CGRect]` |
| 9 | `WindowManager/WindowTracker.swift` | Discover windows, classify, track lifecycle, serial event queue |
| 10 | `WindowManager/StripController.swift` | `applyInstant()` — compute frames, dispatch to per-app threads |
| 11 | `WindowManager/SliverManager.swift` | Off-screen positioning (sliver + corner fallback) |
| 12 | `WindowManager/CrashRecovery.swift` | State file persistence, signal handlers, `scrollwm recover` CLI |
| 13 | `WindowManager/SystemIntegration.swift` | Cmd+Tab relayout, fullscreen lifecycle, Mission Control pause |
| 14 | `Platform/HotkeyManager.swift` | CGEventTap + tap health monitor. Commands: focus-left/right, move-left/right, cycle-width, toggle-full-width, toggle-floating, close-window |
| 15 | `Platform/DisplayManager.swift` | Monitor enumeration, `workingArea` from `NSScreen.visibleFrame`, hot-plug handler |
| 16 | **Focus indicator** | Draw a colored border around the focused window using a transparent overlay `NSWindow` (CoreGraphics path stroke). Required for usability. |

**Deliverable**: Launch → windows tile on strip → Alt-H/Alt-L navigates with visible focus border → new windows auto-add → dialogs/sheets float → closing reflows → Cmd+Tab scrolls to app → crash recovery works.

### Phase 2: Smooth Scrolling

**Goal**: Animated focus, trackpad gestures, 60-120fps.

| # | File(s) | Task |
|---|---|---|
| 1 | `Core/SpringSolver.swift` | Damped harmonic oscillator (3 regimes: under/over/critical damping) |
| 2 | `Core/Animation.swift` | Spring, easing, deceleration configs + retargeting with velocity preservation |
| 3 | `Core/ViewOffset.swift` | Full state machine with all 6 transitions |
| 4 | `Core/SwipeTracker.swift` | 150ms time-windowed velocity estimation |
| 5 | `Platform/FrameLoop.swift` | Per-monitor CADisplayLink, idle suspension, `preferredFrameRateRange` |
| 6 | `Platform/GestureCapture.swift` | CGEventTap scroll events, phase detection (began/changed/ended), momentum suppression |
| 7 | `StripController.swift` | `applyAnimated()` — frame budget management via per-app thread dispatch, priority ordering |
| 8 | Config | `animation_enabled = false` kills switch to instant mode (Phase 1 rollback) |

**Deliverable**: Focus changes animate with spring physics → rapid keypresses compound velocity → trackpad scroll with momentum + snap → rubber-band at edges → `animation_enabled = false` reverts to Phase 1 behavior.

### Phase 3: Config, IPC, Multi-monitor

| # | Task |
|---|---|
| 1 | TOML config parsing (TOMLKit), validation, hot-reload via file watcher |
| 2 | Window rules: regex `app_id`/`title` matching, `open_floating`, `default_column_width` |
| 3 | Unix socket IPC server + `scrollwm msg` CLI |
| 4 | Multi-monitor: independent strip per monitor, move-window-to-monitor |
| 5 | Struts config (for SketchyBar etc.) |
| 6 | `scrollwm recover` CLI command |
| 7 | Pause/resume toggle in menu bar |

### Phase 4: Nice-to-Haves

- Overview mode (zoom-out of all columns)
- Vertical stacking / tabbed columns within a column
- Interactive mouse resize of columns
- Consume/expel window between columns
- Animated workspace switching (vertical slide)
- Mouse-follows-focus / focus-follows-mouse
- Status bar integration protocol (workspace indicators)

---

## Key macOS Workarounds

| Issue | Workaround | Source |
|---|---|---|
| Off-screen windows yanked back | 1px sliver + corner-hiding fallback | Paneru, AeroSpace |
| AX calls block for hung apps | Thread-per-app + 100ms messaging timeout | AeroSpace |
| Apps animate when AX-moved | Toggle `AXEnhancedUserInterface` off during moves (check `isSettable` first) | yabai, AeroSpace |
| `setPosition` changes size | size → position → size ordering | AeroSpace |
| Secure Input disables CGEventTap | Poll `CGEventTapIsEnabled()`, re-enable, document limitation | — |
| Mission Control shows slivers | Temporarily corner-hide on MC enter | — |
| App Nap throttles ScrollWM | `beginActivity(.userInitiated)` | — |
| Display hot-plug invalidates layout | Cancel animations, re-enumerate, rebuild from AX state | — |
| macOS Accessibility Zoom on Ctrl+scroll | Default gesture modifier is `fn`, not `ctrl` | User review |
| Permission revoked while running | Poll `AXIsProcessTrusted()` every 2s, show notification | Swift review |

---

## Dependencies

```swift
// Package.swift
platforms: [.macOS(.v14)]
dependencies: [
  .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.0"),  // Phase 3
]
```

All other functionality: `ApplicationServices`, `CoreGraphics`, `AppKit`, `QuartzCore`, `Foundation`.

---

## Testing Strategy

| Layer | Method | What |
|---|---|---|
| **Core (unit)** | XCTest | Strip layout, viewport computation, focus modes, spring convergence, state machine transitions (including invalid transitions), edge cases (0 columns, proportion=0, degenerate rects) |
| **WindowManager (integration)** | XCTest + mock `WindowPositioning` protocol | StripController issues correct setFrame calls, event queue ordering, crash recovery file write/read |
| **E2E (automated)** | `TestWindowHelper` app | Helper creates `NSWindow` instances, ScrollWM tiles them, helper verifies own window positions. Can run in CI. |
| **Performance** | Instrumented frame loop | Log p50/p95/p99 frame time, AX call latency per app (EMA), frame drop rate. Assert p95 < 16.6ms in CI. |
| **App compat** | Manual matrix | Tier 1 (Terminal, Safari, Finder, VS Code, iTerm2), Tier 2 (Slack, Chrome, IntelliJ), Tier 3 (Zoom, Adobe — must not crash) |

---

## Verification (Phase 1)

```bash
# Build
swift bundler build --product ScrollWM

# Run
open .build/bundled/ScrollWM.app

# Verify
# 1. Menu bar icon appears, Accessibility permission requested
# 2. Open 5 Terminal windows → arranged on horizontal strip with gaps
# 3. Hyper-H / Hyper-L → focus scrolls left/right with visible focus border
# 4. Open new window → appears right of focused column, others don't resize
# 5. Close window → strip reflows
# 6. Open Save dialog → floats, does not become a column
# 7. Cmd+Tab to a hidden app → strip scrolls to show it
# 8. kill -9 <pid>, relaunch → windows restored from state file
# 9. `scrollwm recover` → all windows moved back on-screen
```

---

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| AX latency too high for smooth 120Hz | Choppy animation | Per-app threads; position-only during scroll; adaptive 30-60Hz for slow apps; `animation_enabled=false` rollback |
| macOS update breaks `_AXUIElementGetWindow` | Cannot map AX→CGWindowID | Fallback: PID+frame matching via CGWindowList |
| Apps fight positioning (Electron, Java) | Windows jump | Per-app rules, corner-hiding, EMA-based slow-app detection + deprioritize |
| Sliver fails during display reconfig | Lost windows | Re-park handler on screen-change notification; crash recovery state file |
| Secure Input disables hotkeys | No control during password entry | Document limitation; poll + re-enable tap |
| Phase 2 animation too janky | Poor UX | `animation_enabled` kill switch → instant Phase 1 fallback |
