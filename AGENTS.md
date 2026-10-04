# Reel

Reel is a macOS 15+ scrollable tiling window manager in Swift 6. Windows live on a horizontal strip per display group. Accessibility permission is required. SIP can stay enabled.

## Build and checks

```sh
swift build
swift run RunTests
swift run RunEngineTests
SWIFT_DETERMINISTIC_HASHING=1 ENGINE_FUZZ_SEEDS=11,22,33,44,55 swift run RunEngineTests
ENGINE_BENCH=1 swift run -c release RunEngineTests
make smoke-check
make bundle-check
```

The runners are standalone executables, not XCTest. `RunTests` covers Core, Platform geometry and Runtime frame writing against fake AX windows. `RunEngineTests` covers reducer replays, config parsing, timers, echo tracking, persistence, IPC views and seeded 10,000-event fuzz streams. `ENGINE_ONLY` selects a section. The release reducer budget is median CPU below 50 ms.

`make smoke-check` and `make bundle-check` do not launch an app. The latter builds and inspects an ad-hoc signed bundle. `scripts/bundle.sh` writes `.build/bundled/Reel.app`, or `REEL_BUNDLE_DIR` when set. It seals the bundled `reel-msg` before signature verification. It never installs or launches.

## Daily-machine safety

Reel may be the user's live window manager. Do not run live smoke, launch or signal Reel, post input, switch Spaces, rearrange displays, capture screenshots or reset TCC without explicit approval for a lane host. Never use the user's real config or state directory for tests. Dry runs use `REEL_E2E_CONFIRM=1 SMOKE_DRY_RUN=1`.

## Architecture

```text
Reel -> Runtime -> Engine -> Core, TOMLKit
               -> Platform -> Core
               -> IPC -> Core
```

**Engine** owns decisions. `reduce(&world, event, now:) -> [Effect]` is the only `World` mutator. `World` holds display topology, per-group strips, Space books, frame revisions, focus decisions and an optional `PointerSession`. Time, AX facts, Space identity and topology revisions arrive as data. Effects carry frame writes, focus, timers, census reads, persistence and pointer feedback. The config parser is pure and rejects unknown keys. `config.default.toml` ships as an Engine resource.

**Runtime** owns side effects. One `@MainActor Loop` stamps events and calls the reducer. `Observer` tracks applications through per-app workers. `Executor` writes AX frames and focus on each app's AX thread. `EchoLedger` classifies echoes against frame revisions we wrote, not elapsed time. `Scheduler` owns scoped cancellable timer tokens. `SpaceObserver`, `DisplayObserver` and `PointerObserver` turn OS observations into events. `SnapshotStore` is the only state-file reader/writer and uses atomic writes. `IPCBridge` maps CLI commands to events and diagnostic views. Cross-Space frame diagnostics issue fresh per-app AX reads with a 500 ms aggregate deadline; missing reads are explicit, never cached substitutes.

**Platform** wraps macOS APIs without deciding layout. `AXApp` owns a Thread and CFRunLoop per app. `AXWindow` uses bounded AX messaging and the size-position-size workaround. `FrameLoop` drives animation ticks and pauses when idle. `GestureCapture` and `TitleBarInteraction` expose raw events and apply runtime consume/pass/replay verdicts. They contain no pointer state machine. Overlays, `FocusIndicator`, screen capture, display conversion and hotkey parsing live here.

**Core** contains pure layout and motion. Column positions derive from widths and gaps. `ViewOffset` evaluates at a supplied timestamp. `computeTargetFrames` produces layout targets and visibility zones. Springs preserve velocity when retargeted. `SwipeTracker` estimates flick velocity. `GroupWorkingArea` represents per-display regions in a shared strip.

**Reel** owns NSApplication lifecycle, the status menu, Accessibility onboarding, signals, log redirection and the SMAppService login toggle. Quitting awaits release of managed windows before exiting. The executable name and bundle identifier remain `Reel` and `dev.reel.Reel`.

## Boundaries and coordinates

Engine and Core never call AX or AppKit. Do not move decisions into callbacks. Put time and identity into events and effects. A stale event must not mutate a newer topology revision, Space epoch or pointer token.

SkyLight queries are feature-detected read-only private APIs. Do not add Space mutations or anything requiring SIP changes. AX window identifiers use `_AXUIElementGetWindow`.

Strip coordinates are display-group local. AX and CG coordinates are global top-left. AppKit screen coordinates are global bottom-left. Convert AppKit-global input through `NSWindow.convertPoint(fromScreen:)` before view-local conversion. Group origin must be added to exported AX target frames.

Space identity and census trust are different. Exact SkyLight identity does not make a mixed/empty census safe. Keep the permanent census guards. Disk identity matching is internal to the snapshot codec; the old snapshot format is not migrated.

Horizontally touching displays merge only when separate Spaces are off. Other displays get independent strips. Working insets are applied per physical display before building topology. Hot-plug events carry a new revision. Pointer sessions bind their starting target and are cancelled by Space/topology changes.

## Files and diagnostics

Config is `~/.config/reel/config.toml`. A missing file is created from the new template. Existing files are never overwritten. An invalid startup file runs defaults and shows its first schema error in the menu. A failed reload leaves the last valid configuration active. Reload is manual.

State is `~/.local/state/reel/next-spaces.json`. Bundle logs use `~/Library/Logs/Reel/reel.log`, rotating to one `.1` backup above 1 MB at launch. Bare binaries log to their terminal. Sandbox overrides are `REEL_CONFIG_DIR`, `REEL_STATE_DIR`, `REEL_SOCKET_PATH`, `REEL_MANAGE_ONLY_PIDS` and `REEL_LOG_PATH`. Unset/empty overrides use normal defaults. Manage-only PIDs are positive comma-separated integers; an empty/unparsable list is inert.

IPC uses the per-user Reel Unix socket. Commands include focus and move actions, width/full-width/floating/close, `list-windows`, `get-layout`, `get-layouts`, `list-positions`, `clear-positions`, `clear-positions-app <bundle-id>`, `recover`, `pause`, `resume`, `reload-config`, `get-status` and `quit`. JSON diagnostic shapes are documented by the smoke fixtures and Engine tests, not a compatibility promise.

## Lane scripts

`Tests/Smoke/smoke.sh` stops/restores a live instance, so it is lane-host-only. `pointer-lanes.sh` covers raw input and reorder sessions. The R7 lane entrypoint is `cutover-lanes.sh`, with lane numbers as arguments. First-run lanes need separate macOS 27 and 15 hosts. Login uses an isolated lane account and a reboot checkpoint. `cutover-perf.sh` measures interleaved focus/Space latency and five idle minutes per side. `BIN_TRUNK` must point to a distinct trunk build. The committed old-schema fixture is for trunk comparison and schema-error checks only. The config writers emit only the new schema.

Read `docs/r7-cutover.md` for feature changes, config migration and the operator's remaining live checks. Never claim a live or performance pass from a dry run.
