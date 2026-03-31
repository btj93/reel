# Position Memory — Remember App Positions Across Close/Reopen

## Overview

When a window is closed (or its app quits), ScrollWM saves the window's strip position, column width, and neighbor context. When the same app reopens a window, it is restored to its previous position rather than being inserted at the default location.

## Data Model

### PositionKey

Uniquely identifies a saved window slot. The LRU cap (default 50) applies per-entry — each individual window slot counts as one entry, not per-app.

```swift
struct PositionKey: Hashable, Codable {
    let bundleID: String
    let windowTitle: String?           // nil for order-based matching
    let displayID: CGDirectDisplayID
    let spaceFingerprint: Set<UInt32>  // same fingerprint scheme as space switching
}
```

### SavedPosition

What we remember about the column:

```swift
struct SavedPosition: Codable {
    let columnIndex: Int               // position in strip order
    let neighborBefore: String?        // bundleID of left neighbor (see Known Limitations)
    let neighborAfter: String?         // bundleID of right neighbor (see Known Limitations)
    let width: ColumnWidth             // .proportion or .fixed (never .auto — see normalization)
    let presetIndex: Int?
    let isFullWidth: Bool
    let lastSeen: Date                 // time of window removal, for LRU eviction
}
```

`lastSeen` records the time the window was removed (closed/quit). It is **not** updated on lookup. Eviction removes the entries with the oldest `lastSeen` values when the store exceeds capacity. This makes it a "least recently closed" cache — entries for windows that haven't been reopened yet. Consumed entries (successful lookups) are deleted from the store, so only unclaimed positions age.

### PositionStore

LRU container:

```swift
struct PositionStore: Codable {
    var entries: [PositionKey: SavedPosition]
    var capacity: Int  // default 50, from config
}
```

### ColumnWidth normalization

`ColumnWidth` has three cases: `.proportion(Double)`, `.fixed(Double)`, and `.auto`. At save time, `.auto` is normalized to `.fixed(resolvedPixelWidth)` using `columnData.cachedWidth`. This avoids restoring `.auto` semantics (which means "use the window's current size at add time") when the intent is to restore a specific width. Only `.proportion` and `.fixed` are ever persisted.

`Codable` conformance is added to `ColumnWidth` in `Sources/Core/ColumnWidth.swift`. Encoding: `{"proportion": 0.5}` or `{"fixed": 800.0}`.

### Space fingerprint caveat

`spaceFingerprint` uses `CGWindowID`s which are not stable across ScrollWM restarts. Per-space position scoping works within a session but resets on restart. This is acceptable — global-per-display positions are still useful after restart, and per-space scoping kicks in during a session.

On disk load after restart, all persisted entries will have stale `spaceFingerprint` values. On load, stale fingerprints are normalized to `[]` (empty set) so they cleanly fall into the no-fingerprint fallback paths (steps 2 and 4) without polluting keyed lookups.

## PositionMemory Service

**Location**: `Sources/WindowManager/PositionMemory.swift`

**Responsibilities**:
- Maintains the in-memory `PositionStore`
- Saves/loads from `~/.local/state/scrollwm/window-positions.json`
- Exposes `save(...)` and `lookup(...)` methods
- Handles LRU eviction when capacity is exceeded
- Handles title-first vs order-based matching per app (via config rules)

### API

```swift
class PositionMemory {
    init(capacity: Int, filePath: URL, matchingRules: [PositionMemoryRule])

    /// Called when a window is removed from the strip
    func save(bundleID: String, windowTitle: String?,
              displayID: CGDirectDisplayID, spaceFingerprint: Set<UInt32>,
              position: SavedPosition)

    /// Called when a window is about to be added to the strip.
    /// For order-based matching (steps 3-4), returns entries sorted by
    /// columnIndex ascending — first caller gets the leftmost saved slot.
    func lookup(bundleID: String, windowTitle: String?,
                displayID: CGDirectDisplayID, spaceFingerprint: Set<UInt32>) -> SavedPosition?

    /// Marks a lookup result as consumed so the same slot isn't reused
    func consume(key: PositionKey)

    func clearAll()
    func clear(bundleID: String)
    func persistToDisk()
    func loadFromDisk()

    /// Called on config reload to update capacity and matching rules.
    /// If capacity decreased, evicts excess entries by oldest lastSeen.
    func applyConfig(capacity: Int, matchingRules: [PositionMemoryRule])
}
```

### Matching strategy

`lookup()` tries in order:
1. Exact match on `(bundleID, title, displayID, spaceFingerprint)` — title-based
2. Exact match on `(bundleID, title, displayID)` ignoring space — cross-space fallback
3. Match on `(bundleID, displayID, spaceFingerprint)` with no title — order-based fallback
4. Match on `(bundleID, displayID)` ignoring both — last resort

For apps configured as order-based matching, steps 1-2 are skipped.

**Tie-breaking for steps 3 and 4**: When multiple entries match (e.g., 3 saved Terminal positions), return the one with the lowest `columnIndex`. This ensures the first window opened consumes the leftmost saved slot, second gets the next, etc.

### Consumption

When a `lookup()` result is used, `consume()` removes it from the store so the next window from the same app doesn't claim the same slot. This handles multi-window apps — each window consumes one saved slot.

If an app opens fewer windows than were saved, unconsumed entries remain and are eventually evicted by LRU. If an app opens more windows than were saved, surplus windows get no match and fall through to default placement.

### Persistence timing

`persistToDisk()` is called on the existing 5-second timer (alongside the crash recovery persist) and on `shutdown()`. Disk writes are **never** performed synchronously during save — only on the timer and at shutdown.

## Integration Points

### On window removal — callback from StripController

Window removals arrive through multiple paths that all converge on `StripController.removeWindow(tileID:)`:
- AX observer events (`kAXUIElementDestroyedNotification`) via `handleWindowEvent`
- Health check timer (`checkWindowHealth`) — calls `removeWindow` directly
- Minimize (`kAXWindowMiniaturizedNotification`) — calls `removeWindow` directly
- Toggle floating (`toggleFloating()`) — calls `removeWindow` directly

Because health check and minimize bypass `handleWindowEvent`, the save hook **must live inside `StripController.removeWindow()` itself**, not in `handleWindowEvent`. This is implemented as a callback closure on `StripController`:

```swift
/// Called before a column is removed. Provides the column metadata for position memory.
var onBeforeRemoveWindow: ((_ tileID: TileID, _ column: Column, _ columnData: ColumnData,
                             _ columnIndex: Int, _ neighborBefore: String?,
                             _ neighborAfter: String?) -> Void)?
```

`StripController` fires this callback **before** removing the column, so the strip state is still intact for reading column index, width, and neighbors.

**Suppressed saves**: The callback includes a `reason` parameter (or the caller sets a flag) to distinguish removal causes:
- **Window closed / app quit**: save position (default)
- **Minimize**: save position (window is gone from strip; restore on deminimize)
- **Toggle to floating**: do **not** save position — the window still exists, just changed management mode
- **Space switch cleanup**: save position (window still exists on another space; restore if it returns)

To suppress saves for `toggleFloating()`, `StripController` sets a `suppressPositionSave` flag before calling `removeWindow` from `toggleFloating()`, and clears it after. The callback checks this flag.

**Data capture**: The callback is wired up by `WindowManager`, which:
- Reads `bundleID` from `tracker.apps[window.pid]?.bundleIdentifier`
- Reads `windowTitle` from `window.getTitle()` — may return `nil` if the app has already exited (SIGKILL, crash). This degrades to order-based matching, which is acceptable.
- Reads `displayID` from the StripController that contains the window (the `sc` that matched in the iteration)
- Reads `spaceFingerprint` from `StripController.currentSpaceFingerprint` (must be made `internal` or `public` — currently `private`)
- Normalizes `ColumnWidth.auto` to `.fixed(columnData.cachedWidth)` before saving

### On window addition — all addWindow call sites

Position lookup must happen at **every** call site that adds windows to the strip, not just the event-driven path:

| Call site | Lookup? | Notes |
|---|---|---|
| `handleWindowEvent(.windowAdded)` | Yes | Primary path for new/reopened windows |
| `handleSpaceChange` (discover new windows) | Yes | Window appeared on this space for the first time |
| `adoptUnmanagedWindows` | Yes | Startup retries, health check discovers untracked window |
| `windowDeminimized` | Yes | Restore to where it was on the strip before minimize |

`StripController.addWindow` currently always inserts at `activeColumnIndex + 1` via `strip.insertColumn`. A new overload is needed:

```swift
/// Add a window at a specific position with saved column properties
func addWindow(_ window: AXWindow, app: AXApp, restoredPosition: SavedPosition?)
```

When `restoredPosition` is non-nil, insertion uses the restored column index (clamped) and restored width/preset instead of defaults. When nil, existing behavior is preserved.

**Insertion priority** when restoring:
1. Insert next to `neighborBefore` (right of it) — find by bundleID in current strip
2. Insert next to `neighborAfter` (left of it)
3. Insert at `columnIndex` (clamped to `0...strip.columns.count`)
4. Fall back to default placement (`activeColumnIndex + 1`)

### On space switch

`handleSpaceChange()` removes windows not on the current space — this triggers the save callback in `removeWindow`. Windows removed during space switch get their positions saved, which is correct: if the window returns to this space later, it should restore to its previous position. The space fingerprint captured at save time scopes the entry to the correct space.

When `handleSpaceChange()` discovers new windows on the current space, those go through the `addWindow` path with position lookup enabled.

### On config reload

`WindowManager.reloadConfig()` calls `positionMemory.applyConfig(capacity:matchingRules:)` with the new values. If `position_memory` is disabled, WindowManager stops calling save/lookup. If capacity decreased, `applyConfig` evicts excess entries by oldest `lastSeen`.

## Config

```toml
[layout]
position_memory = true              # toggle feature on/off (default: true)
saved_position_limit = 50           # LRU cap, per window slot (default: 50)

# Per-app matching strategy override (default is title-first)
[[position_memory_rules]]
app_id = "com.apple.finder"
match_by = "order"                  # "title" (default) or "order"
```

Parsed using the same manual TOML traversal pattern as existing `[[rules]]` — `table["position_memory_rules"] as? TOMLArray`, iterate, cast each as `TOMLTable`, read fields.

New fields added to `ScrollWMConfig`:
- `positionMemory: Bool = true`
- `savedPositionLimit: Int = 50`
- `positionMemoryRules: [PositionMemoryRuleConfig] = []`

Default config template (`createDefaultConfig()`) includes these keys commented out with defaults shown.

## IPC Commands

The current IPC protocol uses raw enum strings with no parameter passing (`ScrollWMCommand(rawValue: commandStr)`). This constrains the available commands:

- `scrollwm-msg clear-positions` — clears all saved positions. Implemented as `case clearPositions` on `ScrollWMCommand`. Compatible with current protocol.
- `scrollwm-msg list-positions` — shows current saved positions as JSON. Implemented as `case listPositions`. Compatible with current protocol.
- `scrollwm-msg clear-positions-app <bundleID>` — clears for a specific app. Requires extending the wire protocol to support a payload argument.

**Wire protocol extension**: Change `SocketServer` from single raw-string matching to JSON-encoded command payloads. The response is already JSON-encoded, so this aligns request format with response format:

```json
{"command": "clear-positions-app", "appID": "com.apple.Terminal"}
```

`ScrollWMCommand` becomes `Codable` with optional associated data. Backward compatibility: if the incoming line is not valid JSON, fall back to raw-string matching for existing commands.

## Menu Bar

- "Clear Saved Positions" item added to the existing menu bar dropdown

## Disk Format

Location: `~/.local/state/scrollwm/window-positions.json`

```json
{
  "version": 1,
  "entries": [
    {
      "key": {
        "bundleID": "com.apple.Terminal",
        "windowTitle": "~ — zsh",
        "displayID": 1,
        "spaceFingerprint": [1234, 5678]
      },
      "position": {
        "columnIndex": 2,
        "neighborBefore": "com.apple.Safari",
        "neighborAfter": "com.microsoft.VSCode",
        "width": {"proportion": 0.5},
        "presetIndex": null,
        "isFullWidth": false,
        "lastSeen": "2026-03-30T12:00:00Z"
      }
    }
  ]
}
```

A `version` field is included for future format migration. On load, `spaceFingerprint` values are normalized to `[]` since they are stale after restart.

## Edge Cases

**Clamping**: If saved `columnIndex` exceeds current strip length, insert at the end.

**Multi-window batch quit**: When an app with N windows quits, `handleAppTerminated` calls `unregisterWindow` for each window sequentially on the main thread. Each removal triggers the save callback. Because the strip shrinks with each removal, `neighborBefore`/`neighborAfter` for windows 2-N may reference columns being removed in the same pass. This produces stale neighbor data for those entries. On restore, stale neighbor lookups fail gracefully and fall through to `columnIndex`-based placement. This is an accepted limitation.

**Multi-window ordering**: Windows are matched title-first. For order-based apps, `lookup()` returns entries sorted by `columnIndex` ascending — the first window added consumes the leftmost saved slot, second gets the next, etc. Note: AX window discovery order during startup batch is not deterministic, so the exact mapping of windows to saved slots may not perfectly match the original order. This is an accepted limitation for order-based matching.

**Neighbor bundleID ambiguity**: `neighborBefore`/`neighborAfter` store bundleIDs, not window IDs. If two windows from the same app are adjacent, the neighbor lookup matches the first one found. This is an acceptable approximation — the window ends up near the right app, if not the exact window.

**Minimize/deminimize**: Minimizing a window triggers `removeWindow` and saves its position. Deminimizing triggers `addWindow` with a position lookup, restoring it to where it was. This is intentional — the window should return to its strip position.

**Toggle floating**: Toggling a tiled window to floating calls `removeWindow` but does **not** save a position (suppressed via flag). The window still exists, just changed management mode. Unfloating a window goes through `addWindow` and can consume a saved position if one exists from a prior close.

**Force-quit / SIGKILL**: macOS delivers `didTerminateApplicationNotification` for both graceful and forced termination, so the removal path fires normally. However, `getTitle()` makes an AX call to the now-dead process and will return `nil`. This degrades to order-based matching, which is acceptable.

**Floating windows**: Floating windows never enter `StripController.windowMap` and have no column in the strip. The save callback inside `removeWindow` never fires for them because `removeWindow` is never called. They are implicitly excluded from position memory.

**Rapid close-reopen**: Save happens synchronously (via callback) before column removal, so the 150ms echo suppression window is not a concern. Echo suppression only filters `.windowResized`/`.windowMoved`/`.windowFocused` events, not removal events.

**Feature disabled mid-session**: Stop saving new positions but don't delete existing persisted data. User can explicitly clear via IPC/menu.

**Corrupt/missing JSON file**: Start with an empty store and log a warning. Don't crash.

## Known Limitations

1. **Space-scoped positions don't survive ScrollWM restart** — space fingerprints use volatile CGWindowIDs. After restart, entries fall back to display-scoped matching.
2. **Batch quit neighbor data degrades** — for multi-window apps, later windows in a quit sequence may have stale neighbor references.
3. **Order-based startup matching is non-deterministic** — AX window discovery order during startup batch doesn't guarantee original strip ordering.
4. **Neighbor matching is bundleID-granular** — can't distinguish between two windows of the same app as neighbors.

## Approach

Approach B — Separate `PositionMemory` service owned by `WindowManager`. Clean separation of concerns, testable in isolation, doesn't bloat StripController. Save hook via callback closure on `StripController`.
