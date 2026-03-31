# Position Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remember window strip positions across close/reopen so apps restore to their previous location.

**Architecture:** A `PositionMemory` service owned by `WindowManager` stores `(bundleID, title, display, space) → position` mappings. A pre-removal callback on `StripController` captures column metadata before deletion. On `addWindow`, a lookup decides placement. State persists to `~/.local/state/scrollwm/window-positions.json`.

**Tech Stack:** Swift, Foundation (JSONEncoder/Decoder), CoreGraphics (CGDirectDisplayID), TOMLKit (config parsing)

**Spec:** `docs/superpowers/specs/2026-03-30-position-memory-design.md`

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `Sources/WindowManager/PositionMemory.swift` | PositionMemory service: save, lookup, consume, LRU eviction, disk persistence |
| Modify | `Sources/Core/ColumnWidth.swift` | Add `Codable` conformance |
| Modify | `Sources/Core/Strip.swift:89-112` | New `insertColumn(_:at:atIndex:)` overload for specific index insertion |
| Modify | `Sources/WindowManager/StripController.swift:29,63-97,178-185` | Expose `currentSpaceFingerprint`, add `onBeforeRemoveWindow` callback, `suppressPositionSave` flag, `addWindow` overload with `restoredPosition` |
| Modify | `Sources/WindowManager/WindowManager.swift` | Wire up PositionMemory: save callback, lookup at all addWindow call sites, persist timer, config reload |
| Modify | `Sources/Config/Config.swift:6-58,144-165,190-201,221-283` | New config fields + parsing + default template |
| Modify | `Sources/IPC/Commands.swift` | Add `clearPositions`, `listPositions` cases; add `IPCMessage` struct for JSON protocol |
| Modify | `Sources/IPC/SocketServer.swift:111-118` | Parse JSON payloads with raw-string fallback |
| Modify | `Sources/ScrollWMCLI/ScrollWMCLI.swift` | Handle new commands + JSON payload for `clear-positions-app` |
| Modify | `Sources/ScrollWM/AppDelegate.swift:61-96` | Add "Clear Saved Positions" menu item |
| Modify | `Tests/CoreTests/main.swift` | Tests for ColumnWidth Codable, PositionMemory save/lookup/eviction |

---

### Task 1: ColumnWidth Codable Conformance

**Files:**
- Modify: `Sources/Core/ColumnWidth.swift`
- Test: `Tests/CoreTests/main.swift`

- [ ] **Step 1: Write failing test for ColumnWidth Codable**

Add to `Tests/CoreTests/main.swift` before the final summary print:

```swift
// ═══════════════════════════════════════
// ColumnWidth Codable
// ═══════════════════════════════════════
print("═ ColumnWidth Codable")

section("Encode/decode proportion")
do {
    let width = ColumnWidth.proportion(0.5)
    let data = try! JSONEncoder().encode(width)
    let json = String(data: data, encoding: .utf8)!
    check(json.contains("proportion"), "should contain 'proportion' key: \(json)")
    let decoded = try! JSONDecoder().decode(ColumnWidth.self, from: data)
    assertEq(decoded, width, "round-trip proportion")
}

section("Encode/decode fixed")
do {
    let width = ColumnWidth.fixed(800.0)
    let data = try! JSONEncoder().encode(width)
    let json = String(data: data, encoding: .utf8)!
    check(json.contains("fixed"), "should contain 'fixed' key: \(json)")
    let decoded = try! JSONDecoder().decode(ColumnWidth.self, from: data)
    assertEq(decoded, width, "round-trip fixed")
}

section("Encode/decode auto")
do {
    let width = ColumnWidth.auto
    let data = try! JSONEncoder().encode(width)
    let json = String(data: data, encoding: .utf8)!
    check(json.contains("auto"), "should contain 'auto' key: \(json)")
    let decoded = try! JSONDecoder().decode(ColumnWidth.self, from: data)
    assertEq(decoded, width, "round-trip auto")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run RunTests 2>&1 | tail -20`
Expected: Compilation error — `ColumnWidth` does not conform to `Codable`

- [ ] **Step 3: Implement ColumnWidth Codable**

Add to `Sources/Core/ColumnWidth.swift` after the closing `}` of the enum:

```swift
extension ColumnWidth: Codable {
    private enum CodingKeys: String, CodingKey {
        case proportion, fixed, auto
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(Double.self, forKey: .proportion) {
            self = .proportion(value)
        } else if let value = try container.decodeIfPresent(Double.self, forKey: .fixed) {
            self = .fixed(value)
        } else if (try container.decodeIfPresent(Bool.self, forKey: .auto)) == true {
            self = .auto
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown ColumnWidth"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .proportion(let value):
            try container.encode(value, forKey: .proportion)
        case .fixed(let value):
            try container.encode(value, forKey: .fixed)
        case .auto:
            try container.encode(true, forKey: .auto)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift run RunTests 2>&1 | tail -20`
Expected: All ColumnWidth Codable tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/ColumnWidth.swift Tests/CoreTests/main.swift
git commit -m "feat: add Codable conformance to ColumnWidth

Encodes as {\"proportion\": 0.5}, {\"fixed\": 800.0}, or {\"auto\": true}.
Foundation for position memory disk persistence."
```

---

### Task 2: Strip.insertColumn at Specific Index

**Files:**
- Modify: `Sources/Core/Strip.swift:89-112`
- Test: `Tests/CoreTests/main.swift`

- [ ] **Step 1: Write failing test for insertColumn at specific index**

Add to `Tests/CoreTests/main.swift` after the ColumnWidth Codable tests:

```swift
// ═══════════════════════════════════════
// Strip insertColumn at index
// ═══════════════════════════════════════
print("═ Strip insertColumn at index")

section("Insert at specific index 0")
do {
    var strip = makeStrip(columnCount: 3)
    let newCol = Column(tiles: [TileID(99)], width: .proportion(0.5))
    strip.insertColumn(newCol, at: 0, atIndex: 0)
    assertEq(strip.columns.count, 4, "should have 4 columns")
    assertEq(strip.columns[0].tiles.first, TileID(99), "new column at index 0")
}

section("Insert at specific index end")
do {
    var strip = makeStrip(columnCount: 3)
    let newCol = Column(tiles: [TileID(99)], width: .proportion(0.5))
    strip.insertColumn(newCol, at: 0, atIndex: 3)
    assertEq(strip.columns.count, 4, "should have 4 columns")
    assertEq(strip.columns[3].tiles.first, TileID(99), "new column at end")
}

section("Insert at clamped index")
do {
    var strip = makeStrip(columnCount: 2)
    let newCol = Column(tiles: [TileID(99)], width: .proportion(0.5))
    strip.insertColumn(newCol, at: 0, atIndex: 10)
    assertEq(strip.columns.count, 3, "should have 3 columns")
    assertEq(strip.columns[2].tiles.first, TileID(99), "clamped to end")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run RunTests 2>&1 | tail -20`
Expected: Compilation error — no `insertColumn` overload with `atIndex` parameter

- [ ] **Step 3: Implement insertColumn with specific index**

Add to `Sources/Core/Strip.swift` after the existing `insertColumn` method (after line 112):

```swift
/// Insert a column at a specific index (clamped to valid range).
/// Used by position memory to restore windows to saved positions.
public mutating func insertColumn(_ column: Column, at time: Double, atIndex requestedIndex: Int) {
    let insertIndex = max(0, min(requestedIndex, columns.count))
    let resolvedWidth = column.isFullWidth
        ? workingArea.width
        : column.width.resolve(workingAreaWidth: workingArea.width, gap: gap)

    columns.insert(column, at: insertIndex)
    columnData.insert(ColumnData(cachedWidth: resolvedWidth), at: insertIndex)

    activeColumnIndex = insertIndex

    let newOffset = computeNewViewOffset(
        forColumn: activeColumnIndex,
        previousColumn: max(0, insertIndex - 1),
        focusMode: focusMode,
        columns: columns,
        columnData: columnData,
        gap: gap,
        workingAreaWidth: workingArea.width
    )
    viewOffset = .static(newOffset)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift run RunTests 2>&1 | tail -20`
Expected: All insertColumn at index tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Strip.swift Tests/CoreTests/main.swift
git commit -m "feat: add Strip.insertColumn with explicit index parameter

Supports clamped insertion at a specific position for position memory restore."
```

---

### Task 3: PositionMemory Data Types

**Files:**
- Create: `Sources/WindowManager/PositionMemory.swift`
- Test: `Tests/CoreTests/main.swift`

Note: `PositionMemory` lives in `WindowManager` module which depends on `Core`, `Platform`, `Config`, and `IPC`. But the data types (`PositionKey`, `SavedPosition`, `PositionStore`) only use `Foundation` and `CoreGraphics` types. We put them in `WindowManager` since `CGDirectDisplayID` is a platform concern. Tests import `Core` only — we test the data types via JSON round-trip by duplicating just the struct definitions in the test file since `RunTests` only depends on `Core`.

Actually, since `CGDirectDisplayID` is just `UInt32` (from CoreGraphics, available in Foundation on macOS), and `RunTests` depends only on `Core`, we need a different approach for testing. We'll test `PositionMemory` logic via an integration-style test that runs the actual binary. Instead, for unit tests we focus on what `RunTests` can reach: `ColumnWidth` Codable (Task 1) and `Strip.insertColumn` (Task 2). The `PositionMemory` tests will be manual/integration tests described in Task 10.

- [ ] **Step 1: Create PositionMemory.swift with data types**

Create `Sources/WindowManager/PositionMemory.swift`:

```swift
import Foundation
import CoreGraphics
import Core

// MARK: - Data Types

public struct PositionKey: Hashable, Codable {
    public let bundleID: String
    public let windowTitle: String?
    public let displayID: UInt32  // CGDirectDisplayID
    public let spaceFingerprint: Set<UInt32>

    public init(bundleID: String, windowTitle: String?, displayID: UInt32, spaceFingerprint: Set<UInt32>) {
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.displayID = displayID
        self.spaceFingerprint = spaceFingerprint
    }
}

public struct SavedPosition: Codable {
    public let columnIndex: Int
    public let neighborBefore: String?
    public let neighborAfter: String?
    public let width: ColumnWidth
    public let presetIndex: Int?
    public let isFullWidth: Bool
    public let lastSeen: Date

    public init(columnIndex: Int, neighborBefore: String?, neighborAfter: String?,
                width: ColumnWidth, presetIndex: Int?, isFullWidth: Bool, lastSeen: Date) {
        self.columnIndex = columnIndex
        self.neighborBefore = neighborBefore
        self.neighborAfter = neighborAfter
        self.width = width
        self.presetIndex = presetIndex
        self.isFullWidth = isFullWidth
        self.lastSeen = lastSeen
    }
}

public struct PositionMemoryRuleConfig: Sendable {
    public let appID: String
    public let matchBy: MatchStrategy

    public enum MatchStrategy: String, Sendable {
        case title
        case order
    }

    public init(appID: String, matchBy: MatchStrategy) {
        self.appID = appID
        self.matchBy = matchBy
    }
}

// MARK: - Persistence Format

struct PositionFile: Codable {
    let version: Int
    var entries: [PositionFileEntry]
}

struct PositionFileEntry: Codable {
    let key: PositionKey
    let position: SavedPosition
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add Sources/WindowManager/PositionMemory.swift
git commit -m "feat: add PositionMemory data types

PositionKey, SavedPosition, PositionMemoryRuleConfig, and disk format types."
```

---

### Task 4: PositionMemory Service — Core Logic

**Files:**
- Modify: `Sources/WindowManager/PositionMemory.swift`

- [ ] **Step 1: Implement PositionMemory class**

Add to `Sources/WindowManager/PositionMemory.swift` after the data types:

```swift
// MARK: - PositionMemory Service

public class PositionMemory {
    private var entries: [PositionKey: SavedPosition] = [:]
    private var capacity: Int
    private var matchingRules: [PositionMemoryRuleConfig]
    private let filePath: URL
    private var isDirty: Bool = false

    public init(capacity: Int, filePath: URL, matchingRules: [PositionMemoryRuleConfig] = []) {
        self.capacity = capacity
        self.filePath = filePath
        self.matchingRules = matchingRules
    }

    // MARK: - Save

    public func save(bundleID: String, windowTitle: String?,
                     displayID: UInt32, spaceFingerprint: Set<UInt32>,
                     position: SavedPosition) {
        let key = PositionKey(bundleID: bundleID, windowTitle: windowTitle,
                              displayID: displayID, spaceFingerprint: spaceFingerprint)
        entries[key] = position
        isDirty = true
        evictIfNeeded()
    }

    // MARK: - Lookup

    public func lookup(bundleID: String, windowTitle: String?,
                       displayID: UInt32, spaceFingerprint: Set<UInt32>) -> (key: PositionKey, position: SavedPosition)? {
        let isOrderBased = matchingRules.contains { $0.appID == bundleID && $0.matchBy == .order }

        // Step 1: Exact match (bundleID, title, displayID, spaceFingerprint)
        if !isOrderBased, let title = windowTitle {
            let key = PositionKey(bundleID: bundleID, windowTitle: title,
                                  displayID: displayID, spaceFingerprint: spaceFingerprint)
            if let pos = entries[key] {
                return (key, pos)
            }
        }

        // Step 2: Match ignoring space (bundleID, title, displayID)
        if !isOrderBased, let title = windowTitle {
            if let match = entries.first(where: {
                $0.key.bundleID == bundleID && $0.key.windowTitle == title && $0.key.displayID == displayID
            }) {
                return (match.key, match.value)
            }
        }

        // Step 3: Match ignoring title (bundleID, displayID, spaceFingerprint) — lowest columnIndex
        let step3Matches = entries.filter {
            $0.key.bundleID == bundleID && $0.key.displayID == displayID && $0.key.spaceFingerprint == spaceFingerprint
        }
        if let best = step3Matches.min(by: { $0.value.columnIndex < $1.value.columnIndex }) {
            return (best.key, best.value)
        }

        // Step 4: Match ignoring title and space (bundleID, displayID) — lowest columnIndex
        let step4Matches = entries.filter {
            $0.key.bundleID == bundleID && $0.key.displayID == displayID
        }
        if let best = step4Matches.min(by: { $0.value.columnIndex < $1.value.columnIndex }) {
            return (best.key, best.value)
        }

        return nil
    }

    // MARK: - Consume

    public func consume(key: PositionKey) {
        entries.removeValue(forKey: key)
        isDirty = true
    }

    // MARK: - Clear

    public func clearAll() {
        entries.removeAll()
        isDirty = true
    }

    public func clear(bundleID: String) {
        entries = entries.filter { $0.key.bundleID != bundleID }
        isDirty = true
    }

    // MARK: - Config

    public func applyConfig(capacity: Int, matchingRules: [PositionMemoryRuleConfig]) {
        self.capacity = capacity
        self.matchingRules = matchingRules
        evictIfNeeded()
    }

    // MARK: - LRU Eviction

    private func evictIfNeeded() {
        while entries.count > capacity {
            if let oldest = entries.min(by: { $0.value.lastSeen < $1.value.lastSeen }) {
                entries.removeValue(forKey: oldest.key)
            } else {
                break
            }
        }
    }

    // MARK: - Disk Persistence

    public func persistToDisk() {
        guard isDirty else { return }
        let fileEntries = entries.map { PositionFileEntry(key: $0.key, position: $0.value) }
        let file = PositionFile(version: 1, entries: fileEntries)

        do {
            let dir = filePath.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(file)
            try data.write(to: filePath, options: .atomic)
            isDirty = false
        } catch {
            print("[PositionMemory] Failed to persist: \(error)")
            fflush(stdout)
        }
    }

    public func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: filePath.path) else { return }

        do {
            let data = try Data(contentsOf: filePath)
            let file = try JSONDecoder().decode(PositionFile.self, from: data)
            guard file.version == 1 else {
                print("[PositionMemory] Unknown file version \(file.version), starting fresh")
                fflush(stdout)
                return
            }
            entries.removeAll()
            for entry in file.entries {
                // Normalize stale space fingerprints to empty set
                let normalizedKey = PositionKey(
                    bundleID: entry.key.bundleID,
                    windowTitle: entry.key.windowTitle,
                    displayID: entry.key.displayID,
                    spaceFingerprint: []
                )
                entries[normalizedKey] = entry.position
            }
            print("[PositionMemory] Loaded \(entries.count) entries from disk")
            fflush(stdout)
        } catch {
            print("[PositionMemory] Failed to load (starting fresh): \(error)")
            fflush(stdout)
        }
    }

    // MARK: - Debug

    public func allEntries() -> [(key: PositionKey, position: SavedPosition)] {
        entries.map { (key: $0.key, position: $0.value) }
            .sorted { $0.position.lastSeen > $1.position.lastSeen }
    }

    public var count: Int { entries.count }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add Sources/WindowManager/PositionMemory.swift
git commit -m "feat: implement PositionMemory service

Save, lookup (4-step fallback), consume, LRU eviction, and JSON disk
persistence with stale fingerprint normalization on load."
```

---

### Task 5: StripController — Removal Callback and addWindow Overload

**Files:**
- Modify: `Sources/WindowManager/StripController.swift`

- [ ] **Step 1: Expose currentSpaceFingerprint**

In `Sources/WindowManager/StripController.swift`, change line 29 from:

```swift
private var currentSpaceFingerprint: Set<UInt32> = []
```

to:

```swift
public internal(set) var currentSpaceFingerprint: Set<UInt32> = []
```

- [ ] **Step 2: Add onBeforeRemoveWindow callback and suppressPositionSave flag**

Add after the `currentSpaceFingerprint` property (around line 30):

```swift
/// Called before a column is removed. Provides column metadata for position memory.
/// Parameters: tileID, column, columnData, columnIndex, neighborBefore bundleID, neighborAfter bundleID
public var onBeforeRemoveWindow: ((_ tileID: TileID, _ column: Column, _ columnData: ColumnData,
                                    _ columnIndex: Int, _ neighborBefore: String?,
                                    _ neighborAfter: String?) -> Void)?

/// Set to true to suppress position save during removeWindow (e.g., toggleFloating)
public var suppressPositionSave: Bool = false
```

- [ ] **Step 3: Modify removeWindow to fire callback**

Replace the `removeWindow(tileID:)` method (lines 87–97) with:

```swift
public func removeWindow(tileID: TileID) {
    if let colIndex = strip.columns.firstIndex(where: { $0.tiles.contains(tileID) }) {
        // Fire callback before removal so strip state is intact
        if !suppressPositionSave, let callback = onBeforeRemoveWindow {
            let column = strip.columns[colIndex]
            let colData = strip.columnData[colIndex]

            let neighborBefore: String? = if colIndex > 0,
                let tile = strip.columns[colIndex - 1].activeTile,
                let win = windowMap[tile],
                let app = apps[win.pid] { app.bundleIdentifier } else { nil }

            let neighborAfter: String? = if colIndex < strip.columns.count - 1,
                let tile = strip.columns[colIndex + 1].activeTile,
                let win = windowMap[tile],
                let app = apps[win.pid] { app.bundleIdentifier } else { nil }

            callback(tileID, column, colData, colIndex, neighborBefore, neighborAfter)
        }

        strip.removeColumn(at: colIndex, at: currentTime())
    }
    windowMap.removeValue(forKey: tileID)
    lastCommittedFrames.removeValue(forKey: tileID)
    applyLayout()
}
```

- [ ] **Step 4: Modify toggleFloating to suppress saves**

Replace the `toggleFloating()` method (lines 178–185) with:

```swift
public func toggleFloating() -> AXWindow? {
    guard let activeTile = strip.activeColumn?.activeTile,
          let window = windowMap[activeTile] else { return nil }

    suppressPositionSave = true
    removeWindow(tileID: activeTile)
    suppressPositionSave = false
    return window
}
```

- [ ] **Step 5: Add addWindow overload with restoredPosition**

Add after the existing `addWindow(_:app:)` method (after line 84):

```swift
/// Add a window with an optional restored position from position memory.
/// When restoredPosition is non-nil, inserts at the saved position with saved width.
/// When nil, falls back to default behavior (insert at activeColumnIndex + 1).
public func addWindow(_ window: AXWindow, app: AXApp, restoredPosition: SavedPosition?) {
    guard let saved = restoredPosition else {
        addWindow(window, app: app)
        return
    }

    print("[Strip] addWindow (restored): tileID=\(window.tileID.rawValue) pid=\(window.pid) at index=\(saved.columnIndex)")
    windowMap[window.tileID] = window
    apps[window.pid] = app

    // Determine insertion index using priority: neighbor → columnIndex → default
    let insertIndex = resolveInsertIndex(saved: saved)

    // Normalize width: never restore .auto
    let width: ColumnWidth
    switch saved.width {
    case .auto:
        width = .fixed(saved.width.resolve(workingAreaWidth: strip.workingArea.width, gap: strip.gap))
    default:
        width = saved.width
    }

    let column = Column(tiles: [window.tileID], width: width,
                        presetIndex: saved.presetIndex, isFullWidth: saved.isFullWidth)
    strip.insertColumn(column, at: currentTime(), atIndex: insertIndex)

    if !isBatching {
        applyLayout()
    }
}

/// Resolve the best insertion index from saved position data.
private func resolveInsertIndex(saved: SavedPosition) -> Int {
    // Priority 1: Insert right of neighborBefore
    if let beforeID = saved.neighborBefore {
        for (i, col) in strip.columns.enumerated() {
            if let tile = col.activeTile, let win = windowMap[tile],
               let app = apps[win.pid], app.bundleIdentifier == beforeID {
                return i + 1
            }
        }
    }

    // Priority 2: Insert left of neighborAfter
    if let afterID = saved.neighborAfter {
        for (i, col) in strip.columns.enumerated() {
            if let tile = col.activeTile, let win = windowMap[tile],
               let app = apps[win.pid], app.bundleIdentifier == afterID {
                return i
            }
        }
    }

    // Priority 3: Clamped columnIndex
    return max(0, min(saved.columnIndex, strip.columns.count))
}
```

- [ ] **Step 6: Verify it compiles**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 7: Commit**

```bash
git add Sources/WindowManager/StripController.swift
git commit -m "feat: add position memory hooks to StripController

- onBeforeRemoveWindow callback fires before column removal
- suppressPositionSave flag for toggleFloating
- addWindow overload with restoredPosition and neighbor-based insertion
- Expose currentSpaceFingerprint as public"
```

---

### Task 6: Config — Position Memory Settings

**Files:**
- Modify: `Sources/Config/Config.swift`

- [ ] **Step 1: Add config properties to ScrollWMConfig**

In `Sources/Config/Config.swift`, add after the `startAtLogin` property (around line 52):

```swift
    // MARK: - Position Memory
    public var positionMemory: Bool = true
    public var savedPositionLimit: Int = 50
    public var positionMemoryRules: [PositionMemoryRuleConfig] = []
```

This requires importing `WindowManager` — but `Config` doesn't depend on `WindowManager`. Instead, define a lightweight config struct in Config itself.

Add after `WindowRuleConfig` (after line 73):

```swift
public struct PositionMemoryRuleConfig: Sendable {
    public var appID: String
    public var matchBy: String = "title"  // "title" or "order"

    public init(appID: String, matchBy: String = "title") {
        self.appID = appID
        self.matchBy = matchBy
    }
}
```

Wait — there's a name collision with the `PositionMemoryRuleConfig` already defined in `PositionMemory.swift`. We should define it only in `Config` module (which `WindowManager` depends on) and remove it from `PositionMemory.swift`.

Actually, looking at the module graph: `WindowManager` depends on `Config`. So the config struct should live in `Config/Config.swift` and `PositionMemory` imports it via the `Config` module. Let's define it in Config only.

In `Sources/Config/Config.swift`, add after `WindowRuleConfig`:

```swift
public struct PositionMemoryRuleConfig: Sendable {
    public var appID: String
    public var matchBy: String = "title"  // "title" or "order"

    public init(appID: String, matchBy: String = "title") {
        self.appID = appID
        self.matchBy = matchBy
    }
}
```

And add the properties to `ScrollWMConfig` (after `startAtLogin`):

```swift
    // MARK: - Position Memory
    public var positionMemory: Bool = true
    public var savedPositionLimit: Int = 50
    public var positionMemoryRules: [PositionMemoryRuleConfig] = []
```

- [ ] **Step 2: Add parsing for position memory config**

In the `parse(table:)` method, add after the `[layout]` parsing block (after line 165):

```swift
        if let v = readBool(layout["position_memory"]) { config.positionMemory = v }
        if let v = readDouble(layout["saved_position_limit"]) { config.savedPositionLimit = Int(v) }
```

Add after the `[[rules]]` parsing block (after line 201):

```swift
        if let pmRules = table["position_memory_rules"] as? TOMLArray {
            for item in pmRules {
                if let rule = item as? TOMLTable {
                    var rc = PositionMemoryRuleConfig(appID: "")
                    if let v = readString(rule["app_id"]) { rc.appID = v }
                    if let v = readString(rule["match_by"]) { rc.matchBy = v }
                    if !rc.appID.isEmpty {
                        config.positionMemoryRules.append(rc)
                    }
                }
            }
        }
```

- [ ] **Step 3: Add to default config template**

In `createDefaultConfig()`, add before the `[terminal]` section:

```swift
    # Position memory: remember window positions across close/reopen
    # [layout]
    # position_memory = true
    # saved_position_limit = 50

    # Per-app matching strategy for position memory
    # [[position_memory_rules]]
    # app_id = "com.apple.finder"
    # match_by = "order"  # "title" (default) or "order"

```

- [ ] **Step 4: Remove duplicate PositionMemoryRuleConfig from PositionMemory.swift**

In `Sources/WindowManager/PositionMemory.swift`, remove the `PositionMemoryRuleConfig` struct and its `MatchStrategy` enum. Update `PositionMemory` to import `Config` and use the Config version. Change the matching rule check in `lookup()` from:

```swift
let isOrderBased = matchingRules.contains { $0.appID == bundleID && $0.matchBy == .order }
```

to:

```swift
let isOrderBased = matchingRules.contains { $0.appID == bundleID && $0.matchBy == "order" }
```

Update `PositionMemory`'s stored property and init:

```swift
    private var matchingRules: [PositionMemoryRuleConfig]
```

And in `applyConfig`:

```swift
    public func applyConfig(capacity: Int, matchingRules: [PositionMemoryRuleConfig]) {
```

Add `import Config` at the top of `PositionMemory.swift`.

- [ ] **Step 5: Verify it compiles**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 6: Commit**

```bash
git add Sources/Config/Config.swift Sources/WindowManager/PositionMemory.swift
git commit -m "feat: add position memory config fields

position_memory, saved_position_limit, and [[position_memory_rules]]
parsed from config.toml with defaults."
```

---

### Task 7: IPC — New Commands and JSON Protocol Extension

**Files:**
- Modify: `Sources/IPC/Commands.swift`
- Modify: `Sources/IPC/SocketServer.swift:111-118`
- Modify: `Sources/ScrollWMCLI/ScrollWMCLI.swift`

- [ ] **Step 1: Add new commands to ScrollWMCommand**

In `Sources/IPC/Commands.swift`, add cases to `ScrollWMCommand`:

```swift
    case listPositions = "list-positions"
    case clearPositions = "clear-positions"
```

Add `IPCMessage` struct for JSON protocol after `scrollWMSocketPath()`:

```swift
public struct IPCMessage: Codable, Sendable {
    public let command: String
    public var appID: String?

    public init(command: String, appID: String? = nil) {
        self.command = command
        self.appID = appID
    }
}
```

- [ ] **Step 2: Update SocketServer to parse JSON with raw-string fallback**

In `Sources/IPC/SocketServer.swift`, replace the command parsing section (lines 111-118) with:

```swift
            let response: ScrollWMResponse
            if let rawStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                // Try JSON protocol first
                if let jsonData = rawStr.data(using: .utf8),
                   let message = try? JSONDecoder().decode(IPCMessage.self, from: jsonData) {
                    response = onMessage?(message) ?? onCommand.flatMap { handler in
                        ScrollWMCommand(rawValue: message.command).map { handler($0) }
                    } ?? ScrollWMResponse(success: false, message: "No handler")
                }
                // Fall back to raw string for backward compatibility
                else if let command = ScrollWMCommand(rawValue: rawStr) {
                    response = onCommand?(command) ?? ScrollWMResponse(success: false, message: "No handler")
                } else {
                    response = ScrollWMResponse(success: false, message: "Unknown command: \(rawStr)")
                }
            } else {
                response = ScrollWMResponse(success: false, message: "Invalid data")
            }
```

Add the `onMessage` property to `SocketServer` alongside `onCommand`:

```swift
public var onMessage: ((IPCMessage) -> ScrollWMResponse)?
```

- [ ] **Step 3: Update ScrollWMCLI to handle new commands**

In `Sources/ScrollWMCLI/ScrollWMCLI.swift`, replace the command parsing and sending section with:

```swift
        let args = Array(CommandLine.arguments.dropFirst())

        guard let commandStr = args.first else {
            printUsage()
            Foundation.exit(1)
        }

        // Check if this is a command that needs JSON protocol
        let payload: String
        if commandStr == "clear-positions-app" {
            guard args.count >= 2 else {
                print("Usage: scrollwm-msg clear-positions-app <bundle-id>")
                Foundation.exit(1)
            }
            let message = IPCMessage(command: commandStr, appID: args[1])
            let data = try! JSONEncoder().encode(message)
            payload = String(data: data, encoding: .utf8)!
        } else {
            guard ScrollWMCommand(rawValue: commandStr) != nil else {
                printUsage()
                Foundation.exit(1)
            }
            payload = commandStr
        }
```

Replace the send line `let cmdStr = command.rawValue + "\n"` with:

```swift
        let cmdStr = payload + "\n"
```

Add a `printUsage` function:

```swift
    static func printUsage() {
        let commands = ScrollWMCommand.allCases.map(\.rawValue) + ["clear-positions-app <bundle-id>"]
        print("Usage: scrollwm-msg <command>")
        print("Commands: \(commands.joined(separator: ", "))")
    }
```

- [ ] **Step 4: Verify it compiles**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add Sources/IPC/Commands.swift Sources/IPC/SocketServer.swift Sources/ScrollWMCLI/ScrollWMCLI.swift
git commit -m "feat: add position memory IPC commands

list-positions, clear-positions as enum cases.
clear-positions-app uses new JSON protocol with raw-string fallback."
```

---

### Task 8: WindowManager — Wire Up PositionMemory

**Files:**
- Modify: `Sources/WindowManager/WindowManager.swift`

This is the main integration task. WindowManager creates PositionMemory, wires the save callback, and adds lookup to all addWindow call sites.

- [ ] **Step 1: Add positionMemory property and initialization**

In `Sources/WindowManager/WindowManager.swift`, add a property near the top of the class (after `stripControllers`):

```swift
    public var positionMemory: PositionMemory?
```

In the `start()` method, before `tracker.startObserving()`, initialize PositionMemory:

```swift
        if config.positionMemory {
            let stateDir = NSHomeDirectory() + "/.local/state/scrollwm"
            let filePath = URL(fileURLWithPath: stateDir + "/window-positions.json")
            let rules = config.positionMemoryRules
            positionMemory = PositionMemory(capacity: config.savedPositionLimit, filePath: filePath, matchingRules: rules)
            positionMemory?.loadFromDisk()
        }
```

- [ ] **Step 2: Wire the save callback on each StripController**

After creating strip controllers (wherever `StripController` instances are initialized), wire the callback. Find where strip controllers are set up and add:

```swift
        for (displayID, sc) in stripControllers {
            sc.onBeforeRemoveWindow = { [weak self] tileID, column, columnData, colIndex, neighborBefore, neighborAfter in
                guard let self, let positionMemory = self.positionMemory, self.config.positionMemory else { return }

                let window = sc.windowMap[tileID]
                let bundleID = window.flatMap { self.tracker.apps[$0.pid]?.bundleIdentifier }
                guard let bundleID else { return }

                let windowTitle = window?.getTitle()
                let spaceFingerprint = sc.currentSpaceFingerprint

                // Normalize .auto width to .fixed
                let width: ColumnWidth
                switch column.width {
                case .auto:
                    width = .fixed(columnData.cachedWidth)
                default:
                    width = column.width
                }

                let position = SavedPosition(
                    columnIndex: colIndex,
                    neighborBefore: neighborBefore,
                    neighborAfter: neighborAfter,
                    width: width,
                    presetIndex: column.presetIndex,
                    isFullWidth: column.isFullWidth,
                    lastSeen: Date()
                )

                positionMemory.save(bundleID: bundleID, windowTitle: windowTitle,
                                    displayID: UInt32(displayID), spaceFingerprint: spaceFingerprint,
                                    position: position)
            }
        }
```

- [ ] **Step 3: Add lookup helper method**

Add a helper method to WindowManager:

```swift
    private func lookupSavedPosition(for window: AXWindow, on sc: StripController, displayID: CGDirectDisplayID) -> SavedPosition? {
        guard config.positionMemory, let positionMemory else { return nil }

        let bundleID = tracker.apps[window.pid]?.bundleIdentifier
        guard let bundleID else { return nil }

        let title = window.getTitle()
        let fingerprint = sc.currentSpaceFingerprint

        guard let result = positionMemory.lookup(bundleID: bundleID, windowTitle: title,
                                                  displayID: UInt32(displayID),
                                                  spaceFingerprint: fingerprint) else {
            return nil
        }

        positionMemory.consume(key: result.key)
        return result.position
    }
```

- [ ] **Step 4: Add lookup to handleWindowEvent .windowAdded**

Replace the `.windowAdded` case (lines 387-392) with:

```swift
        case .windowAdded(let window, let classification):
            guard classification == .tile else { return }
            if let app = tracker.apps[window.pid] {
                let (displayID, sc) = stripControllerEntryForWindow(window)
                let saved = lookupSavedPosition(for: window, on: sc, displayID: displayID)
                sc.addWindow(window, app: app, restoredPosition: saved)
            }
```

This requires a helper `stripControllerEntryForWindow` that returns both the displayID and the StripController:

```swift
    private func stripControllerEntryForWindow(_ window: AXWindow) -> (CGDirectDisplayID, StripController) {
        // Try to find the display the window is on
        if let frame = try? window.getFrame().get() {
            for (displayID, sc) in stripControllers {
                if sc.strip.workingArea.intersects(frame) {
                    return (displayID, sc)
                }
            }
        }
        // Fallback to primary display
        let primary = stripControllers.first!
        return (primary.key, primary.value)
    }
```

- [ ] **Step 5: Add lookup to windowDeminimized**

Replace the `.windowDeminimized` case (lines 424-428) with:

```swift
        case .windowDeminimized(let windowID):
            if let window = tracker.windows[windowID],
               let app = tracker.apps[window.pid] {
                let (displayID, sc) = stripControllerEntryForWindow(window)
                let saved = lookupSavedPosition(for: window, on: sc, displayID: displayID)
                sc.addWindow(window, app: app, restoredPosition: saved)
            }
```

- [ ] **Step 6: Add lookup to adoptUnmanagedWindows**

In `adoptUnmanagedWindows()`, replace the `stripController.addWindow(window, app: app)` line (around line 623) with:

```swift
                let (displayID, sc) = stripControllerEntryForWindow(window)
                let saved = lookupSavedPosition(for: window, on: sc, displayID: displayID)
                sc.addWindow(window, app: app, restoredPosition: saved)
```

- [ ] **Step 7: Add lookup to handleSpaceChange new window discovery**

In `handleSpaceChange()`, wherever `stripController.addWindow(window, app: app)` is called for newly discovered windows (two locations — the restored path around line 479 and the new-space path around line 510), replace with:

```swift
                    let (displayID, sc) = stripControllerEntryForWindow(window)
                    let saved = lookupSavedPosition(for: window, on: sc, displayID: displayID)
                    sc.addWindow(window, app: app, restoredPosition: saved)
```

- [ ] **Step 8: Add persistToDisk to timer and shutdown**

In the `stateWriteTimer` callback (line 198-200), add:

```swift
            self?.positionMemory?.persistToDisk()
```

In `shutdown()` (around line 270), add before `ipcServer?.stop()`:

```swift
        positionMemory?.persistToDisk()
```

- [ ] **Step 9: Add positionMemory to reloadConfig**

In `reloadConfig()` (lines 300-337), add after the existing config application:

```swift
        if config.positionMemory {
            if positionMemory == nil {
                let stateDir = NSHomeDirectory() + "/.local/state/scrollwm"
                let filePath = URL(fileURLWithPath: stateDir + "/window-positions.json")
                positionMemory = PositionMemory(capacity: config.savedPositionLimit, filePath: filePath, matchingRules: config.positionMemoryRules)
                positionMemory?.loadFromDisk()
            } else {
                positionMemory?.applyConfig(capacity: config.savedPositionLimit, matchingRules: config.positionMemoryRules)
            }
        }
```

- [ ] **Step 10: Verify it compiles**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 11: Commit**

```bash
git add Sources/WindowManager/WindowManager.swift
git commit -m "feat: wire PositionMemory into WindowManager

- Save callback on StripController.onBeforeRemoveWindow
- Lookup at all addWindow call sites (event, deminimize, adopt, space switch)
- Persist on 5s timer and shutdown
- Config reload support"
```

---

### Task 9: IPC Command Handlers and Menu Bar

**Files:**
- Modify: `Sources/WindowManager/WindowManager.swift`
- Modify: `Sources/ScrollWM/AppDelegate.swift`

- [ ] **Step 1: Add IPC command handlers in WindowManager**

Find where `handleIPCCommand` or `onCommand` is set up in WindowManager (where `SocketServer.onCommand` is assigned). Add handling for the new commands:

```swift
        case .listPositions:
            if let pm = positionMemory {
                let entries = pm.allEntries().map { entry -> [String: Any] in
                    [
                        "bundleID": entry.key.bundleID,
                        "windowTitle": entry.key.windowTitle ?? "nil",
                        "displayID": entry.key.displayID,
                        "columnIndex": entry.position.columnIndex,
                        "width": "\(entry.position.width)",
                        "lastSeen": ISO8601DateFormatter().string(from: entry.position.lastSeen),
                    ]
                }
                if let data = try? JSONSerialization.data(withJSONObject: entries),
                   let json = String(data: data, encoding: .utf8) {
                    return ScrollWMResponse(success: true, data: json)
                }
            }
            return ScrollWMResponse(success: true, data: "[]")

        case .clearPositions:
            positionMemory?.clearAll()
            positionMemory?.persistToDisk()
            return ScrollWMResponse(success: true, message: "Cleared all saved positions")
```

Add `onMessage` handler on `SocketServer` for the JSON protocol:

```swift
        ipcServer?.onMessage = { [weak self] message in
            guard let self else { return ScrollWMResponse(success: false, message: "No handler") }
            switch message.command {
            case "clear-positions-app":
                guard let appID = message.appID else {
                    return ScrollWMResponse(success: false, message: "Missing appID")
                }
                self.positionMemory?.clear(bundleID: appID)
                self.positionMemory?.persistToDisk()
                return ScrollWMResponse(success: true, message: "Cleared positions for \(appID)")
            default:
                if let cmd = ScrollWMCommand(rawValue: message.command) {
                    return self.ipcServer?.onCommand?(cmd) ?? ScrollWMResponse(success: false, message: "No handler")
                }
                return ScrollWMResponse(success: false, message: "Unknown command: \(message.command)")
            }
        }
```

- [ ] **Step 2: Add "Clear Saved Positions" to menu bar**

In `Sources/ScrollWM/AppDelegate.swift`, in `setupMenuBar()`, add before the "Quit" item (around line 90):

```swift
        menu.addItem(NSMenuItem(title: "Clear Saved Positions", action: #selector(clearPositions), keyEquivalent: ""))
```

Add the handler method:

```swift
    @objc private func clearPositions() {
        windowManager?.positionMemory?.clearAll()
        windowManager?.positionMemory?.persistToDisk()
        print("[ScrollWM] Cleared all saved positions")
        fflush(stdout)
    }
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add Sources/WindowManager/WindowManager.swift Sources/ScrollWM/AppDelegate.swift
git commit -m "feat: add position memory IPC handlers and menu bar item

list-positions, clear-positions, clear-positions-app commands.
Menu bar 'Clear Saved Positions' button."
```

---

### Task 10: Integration Testing

**Files:**
- Test manually via running ScrollWM

- [ ] **Step 1: Build and run**

```bash
swift build 2>&1 | tail -5
```

Expected: Build succeeds with no errors

- [ ] **Step 2: Run unit tests**

```bash
swift run RunTests 2>&1
```

Expected: All tests pass including ColumnWidth Codable and Strip insertColumn tests

- [ ] **Step 3: Manual integration test — basic position memory**

1. Start ScrollWM: `.build/debug/ScrollWM &`
2. Open Terminal — note its strip position (e.g., column 1)
3. Open Safari — note its strip position (e.g., column 2)
4. Close Terminal (Cmd+Q)
5. Reopen Terminal
6. Verify Terminal reappears at its previous strip position (column 1), not at the end

- [ ] **Step 4: Manual integration test — IPC commands**

```bash
.build/debug/scrollwm-msg list-positions
```

Expected: JSON array of saved position entries

```bash
.build/debug/scrollwm-msg clear-positions
.build/debug/scrollwm-msg list-positions
```

Expected: Empty array after clear

- [ ] **Step 5: Manual integration test — persistence across restart**

1. Open several apps, arrange them on the strip
2. Close one app
3. Quit ScrollWM
4. Start ScrollWM again
5. Reopen the closed app
6. Verify it restores to its saved position

Check the state file exists:

```bash
cat ~/.local/state/scrollwm/window-positions.json | python3 -m json.tool
```

- [ ] **Step 6: Manual integration test — toggle floating**

1. Focus a tiled window
2. Toggle it to floating (hotkey)
3. Check `scrollwm-msg list-positions` — should NOT have an entry for that window
4. Toggle it back to tiled — should use default placement, not a saved position

- [ ] **Step 7: Commit test results log (optional)**

If all tests pass, no additional commit needed. If fixes were required, they should have been committed in the relevant task.

---

### Task 11: Final Cleanup

**Files:**
- All modified files

- [ ] **Step 1: Run full build**

```bash
swift build 2>&1
```

Expected: Clean build, no warnings

- [ ] **Step 2: Run all tests**

```bash
swift run RunTests 2>&1
```

Expected: All tests pass

- [ ] **Step 3: Verify state file location**

```bash
ls -la ~/.local/state/scrollwm/window-positions.json
```

Expected: File exists after running ScrollWM with position memory enabled

- [ ] **Step 4: Final commit if any cleanup was needed**

```bash
git add -A
git commit -m "chore: position memory cleanup and polish"
```
