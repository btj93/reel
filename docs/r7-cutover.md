## Feature inventory

Inventoried trunk before deletion at 76af894. Every item is kept, changed or dropped. A changed schema is not a loss of its underlying action unless the row says so.

| Trunk surface | Status | New behavior or reason |
| --- | --- | --- |
| Horizontal strip, animated focus, widths, bounce | Kept | Pure Core behind Engine; gap default changes from 16 to 8. Fresh columns use observed width, clamped to the physical display; the configured default is the fallback when no frame is available |
| Visibility-zone AX write deferral, keyboard snap-milestone stepping | Changed | R3 sends changed targets each tick and computes only moving strips. Keyboard focus steps one column and recenters |
| Floating-window focus indicator and left-edge resize anchoring | Dropped | R3 retains indicators for engine-owned tiled frames; native resize only updates width, not a left-edge scroll anchor |
| Dock-autohide visibleFrame polling | Dropped | R3/R5 use screen-parameter notifications rather than the old 1.5-second poll |
| Focus left/right/up/down, move-column left/right, cycle width, full width, floating and close | Kept | All ten default Option bindings and menu actions remain; `[keys]` replaces `[keybindings]` |
| `focus-left/right/up/down`, `move-column-left/right`, `cycle-width-preset`, `toggle-full-width`, `toggle-floating`, `close-window` | Kept | Same command names, canonical reducer commands |
| `list-windows`, `get-layout`, `get-layouts` | Changed | Names retained; new world-derived JSON. `get-layouts` shows expected placement and fresh AX reads on app threads, bounded at 500 ms, with `unreadable` on failure. Window-server on-screen IDs determine `isOnScreen`; fresh AX geometry determines `slivered`. Hidden windows are included |
| `list-positions`, `clear-positions`, `clear-positions-app <bundle-id>` | Kept | SnapshotStore listing/clearing. App-scoped clear filters live, disk and hidden snapshots by bundle ID, preserves other apps and persists; tested |
| `recover`, `quit` | Kept | Recover rewrites frames; quit awaits release before NSApplication exits |
| `pause`, `resume`, `get-status`, `reload-config` | Kept | Same names; status reports paths/PID sandbox/config error/topology |
| CLI socket and bundled `reel-msg` | Kept | Same Unix socket default and bundled CLI path; signature seals CLI before verification |
| Menu Reload Config, pause/resume, Quit, Open Config, Recover Windows, Clear Saved Positions | Kept | Menu dispatches into the canonical Runtime/Engine handlers; bundle version label and Pause `p` shortcut remain |
| Separate-Spaces warning and Mission Control deep link | Kept | Shared strips still require separate Spaces off |
| Start at Login menu | Kept | SMAppService state is the source of truth; requires the bundle; approval opens Login Items |
| Accessibility onboarding menu | Kept | A waiting status item, Settings link and Quit are available before the grant |
| Menu icon and per-action shortcut labels | Changed | Text status (`Reel`, paused/error state); actions remain without shortcut labels |
| `layout.gap`, `layout.snap` | Kept | Same objectives; strict schema rejects unknowns |
| `layout.default_width.proportion`, `layout.default_width.fixed`, `layout.width_presets` | Changed | `layout.default_width` is a proportion scalar; presets remain proportions. Old table/fixed-width forms are not imported |
| `layout.struts.left/right/top/bottom` | Kept | Per-display CG working insets before topology; clamped to a positive working area. Startup applies them before observer discovery without committing an empty census; reloads retain full topology handling |
| `layout.animation_enabled`, `animation.scroll_stiffness`, `animation.scroll_damping_ratio`, `animation.bounce_distance`, `animation.bounce_damping_ratio` | Changed | `animation.enabled`, `stiffness`, `damping_ratio`; bounce names remain |
| `gesture.modifier` | Changed | `fn`, `ctrl`/`control`, `alt`/`opt`/`option`, `cmd`/`command` accepted. `none` and empty no longer accepted: R6 passes unmodified scrolls to apps |
| `gesture.snap` | Kept | Deterministic session ownership and configured snap behavior |
| `focus_indicator.style/color/width/corner_radius/raise_height` | Kept | `[indicator]` new section; styles none/ring/raise/flash remain; style payload moved to Platform before Config deletion |
| `rules.app_id/app_id_regex/title_regex/floating` | Kept | `bundle_id`, `bundle_id_regex`, `title_regex`, `floating`; multiple fields AND, first match wins, as on trunk. The first nonempty title is captured; a late first title completes provisional classification. It survives metadata updates and Space restore; no continuous title-rule reevaluation |
| `layout.position_memory` | Dropped | Persistence always on; matching belongs to the snapshot book, not user tuning. Root-approved R7 decision |
| Old state/config migration | Changed | Existing config is read unchanged at the same path; first unknown key shown and startup defaults used. Old snapshot format is not imported or deleted |
| `start_at_login` config key | Dropped | Menu/system state only, root-approved R7 decision |
| `cursor.long_press_delay_ms`, `cursor.drag_threshold_px`, `cursor.title_bar_corner_inset_px` | Dropped | R6 constants; native corner resizing remains |
| 3-finger focus swipe, `cursor.swipe_threshold_px` | Dropped | R6 decision. Three fingers pan rather than focus-switch |
| Click-to-recenter an already AX-focused window | Dropped | R6 decision. Explicit focus commands still recenter |
| Animated reorder band | Dropped | R6 drop behavior; root accepted no band animation |
| `reorder_overlay.thumbnail_height` | Dropped | R6 uses fixed overlay sizing rather than a user-configured thumbnail height |
| `reorder_overlay.thumbnail_style` | Dropped | One ScreenCaptureKit screenshot style with placeholder fallback. The old icon-only choice avoided Screen Recording, so new screenshot permission is an open upgrade risk |
| Flick and native momentum | Changed | Projected-velocity landing is operator-approved. Scroll during a press is ignored, Space-change drops refused, pause returns a live tail to macOS |
| Space persistence, exact sid with fingerprint fallback, census guards | Kept | One snapshot book and epoch-guarded reducer; fresh identity is separate from census safety |
| Display merge/split/hot-plug and independent vertical strips | Kept | Topology revisions; focus across independent strips uses geometry |
| Stage Manager support | Dropped | Unsupported per R4; status now says unsupported unconditionally instead of reading a private preference-domain flag |
| Bundle ID, executable name, signing, Info.plist, icon resource | Kept | `dev.reel.Reel`, `Reel`, existing ad-hoc signing flow, screen-capture usage description; no installer or launch in bundler |
| Logs and 1 MB rotation | Kept | Bundle log path and one `.1` backup; bare stdout. Added `REEL_LOG_PATH` for sandbox bundle lanes, with launch and in-session rotation checks |
| Release title-log hashing | Changed | The new runtime does not log titles in normal events, so no hash shim is needed. Read-only IPC intentionally returns titles |

The config inventory was re-audited against `git show 76af894:Sources/Config/Config.swift`, including nested width/strut keys, all ten `[keybindings]` actions and every rule field. `cursor.title_bar_height`, `reorder_overlay.ghost_settle_ms`, `layout.saved_position_limit` and position-memory `match_by` were not parsed trunk keys and are not counted as removed settings.

## Config migration

Replace old contents with `Sources/Engine/config.default.toml`, then Reload Config. Map `[keybindings]` to `[keys]`, `[focus_indicator]` to `[indicator]`, `app_id` to `bundle_id`, `app_id_regex` to `bundle_id_regex`, and old animation names to the names above. Convert fixed/table widths to proportions. Keep struts, snap, gesture modifier and supported indicator options. Remove every dropped key listed above; do not leave them as active TOML entries. The shipped legacy fixture's first unknown key is `animation.scroll_damping_ratio`. New first-run config creation never overwrites an existing file. A failed reload keeps the last valid config; invalid startup uses defaults.

## Upgrade story

The shipped Reel is now the new runtime, not a second app. Existing config at `~/.config/reel/config.toml` is read with the new schema. An old file produces a visible schema error and defaults at startup, with working default bindings. Users must edit the config. Old layout state is left in place but not imported. New persistence is `next-spaces.json`.

Accessibility and login identity remain `Reel` and `dev.reel.Reel`, at the same installed bundle path. The code does not reset TCC or unregister an existing login item. There is no deliberate re-grant step. A fixed identifier alone does not preserve the cdhash of an ad-hoc build, so a particular upgrade may still require re-approval; the root must verify grant retention on a lane host. A fresh install must grant Accessibility. Reorder screenshots may additionally request Screen Recording; placeholders preserve reorder when capture fails.

## Tests removed or ported

Deleted the simulation runners and their SimHarness, L1FocusGateTests, L1StoreTests, legacy AppActivationCarryover/FocusEventGate checks, old config validation/default and rule-parser blocks, and old display-reconciliation map checks. Removed DisplayManager alignment/group-area helpers and their L1TopologyTests/L1GroupAreaTests/main alignment blocks per the R5 handover; ported epsilon and Y-overlap boundaries to Engine Topology tests. They exercised the removed orchestration/config layer. Engine historical replays, snapshot/clear/title tests, R6 pointer checks and seeded fuzz cover their runtime objectives. Retained pure Core geometry, SpaceKey, snapshot matching, spring/swipe and classification backfills. Added R7 checks for bundled defaults, insets, regex validation/adoption-title stability across Space restore, SnapshotStore pending/list/clear persistence, bounded frame probes, fresh diagnostic JSON/non-primary expected coordinates temp-directory log rotation, and a real isolated Unix-socket check of asynchronous parameter forwarding.

## Review passes

Deslop removed accidentally copied legacy key-label helpers, stale single-display/ReelNext narration and an unused legacy focus helper. No-comments removed legacy class-name comments and inaccurate signing/grant promises; raw-adapter comments now explain event ownership rather than the deleted state machine. Inline interrogate found and fixed the old-template symlink fixture, trunk/head basename sample collisions, missing live SMOKE_TAG and command helper names, wrong diagnostic local/global coordinates, lane 9's possible no-op focus, and title-rule reevaluation on metadata/Space restore. The pass also fixed a menu clear that bypassed the reducer refusal, moved frame-probe deadlines into common run-loop modes, and found/retained the previously unsupported app-scoped clear CLI route. The final pass also removed unused synchronous IPC handlers instead of preserving a second routing API. No independent model review was launched because this child owns inline review only. Root fanout remains pending.

## Root-owned live and performance checks

Build distinct trunk and head artifacts first. On clean isolated lane accounts only, set `REEL_E2E_CONFIRM=1`; dry-run additionally sets `SMOKE_DRY_RUN=1`.

- `TRUNK_ROOT=/path/to/trunk bash Tests/Smoke/cutover-lanes.sh 1` runs each checkout's own smoke harness and compares sections. Keep `smoke-summary.png`.
- On macOS 27, `bash Tests/Smoke/cutover-lanes.sh 2`; on macOS 15, `... 3`. Fresh grant and five-second tiling are manually timed. Keep `first-run.png` and `first-run-15.png`.
- `... 4` prepares login/reboot. Reboot the isolated account, then `R7_LOGIN_AFTER_REBOOT=1 ... 4`. Keep `login.png`.
- `... 5 6 7 8 9 10` covers Space return, physical unplug, signed-bundle reorder, a 30-minute RSS soak, quit mid-animation and old-schema startup. Lane 6 and on-screen quit observations are manual. Screenshots and logs go to `LANE_OUT` or the printed temp evidence directory.
- `BIN_TRUNK=/path/to/trunk/Reel BIN_HEAD=/path/to/head/Reel.app/Contents/MacOS/Reel bash Tests/Smoke/cutover-perf.sh` performs 20 interleaved samples per latency side and five idle minutes per side. Baseline is recorded first. Both p95 latencies must be at most trunk * 1.1; head idle CPU must be at most one second in five minutes. Prepare two adjacent Spaces, current with host windows and right empty, and Ctrl-arrow shortcuts.
- R6 `pointer-perf.sh` posts a two-second swipe, not lane 1's flick. Point `PERF_BINS` at distinct trunk and head binaries. Its default baseline is `/tmp/reel-trunk/.build/debug/Reel`, not the now-cut-over local Reel. Pointer lane 1 is head-only; trunk comparison belongs to the R7 regression lane.
- `REEL_LANE_BUNDLE=/same/installed/Reel.app ... cutover-lanes.sh 11` verifies an already-granted trunk bundle, then asks the root to install signed head at the same path. Keep `upgrade.png` and `upgrade.txt` with prompted/no-prompt and five-second tiling observations. No grant reset occurs.
- Copy first-run, Space-roundtrip and old-config screenshots to the R7 review media paths; record the plan's 30-60 second first-launch/tiling/Space/reorder video and post it for operator review.

Nothing live or performance-measured ran on the daily machine. Dry-run results validate scripts and fixture parsers only. The program cannot be called fully verified until root supplies live/perf/media evidence and reviews the exact head.

## Audit fix round B

Foreign settled moves across independent display groups migrate the window; merged-strip seams and frame echoes do not. Re-tiling a float uses its current frame. Pause and quit release current windows and other Spaces' live snapshots in one deduplicated pass; disk-only identities never receive writes. Hidden releases clamp to surviving displays.

Failed frame writes retry after 0.1, 0.5 and 2 seconds, then log one `frame give-up` and stop until the target changes or Recover Windows resets them. Unconfirmed sizes retain the focus-ring target. Settled app width refusals update the logical column width, bounded by its display; a minimum width larger than the display cannot cause an immediate write loop.

The reorder row scales to keep end destinations visible. Menu recovery uses the same all-group size-cache reset as IPC. Provisional classification retries on focus, move/resize and health checks, with scope/activation guards. Unmatched disk snapshots retain at most 64 entries in loaded order (not an LRU).

Engine/Runtime probes and dry lanes cover these changes; real AX behavior on other Spaces, the ring and ScreenCaptureKit rendering still require approved lane-host checks.
