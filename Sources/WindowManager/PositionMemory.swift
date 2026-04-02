import Core
import CoreGraphics
import Foundation

// MARK: - Data Types

public struct PositionKey: Hashable, Codable {
    public let bundleID: String
    public let windowTitle: String?
    public let displayID: UInt32  // CGDirectDisplayID
    public let spaceFingerprint: Set<UInt32>

    public init(
        bundleID: String, windowTitle: String?, displayID: UInt32, spaceFingerprint: Set<UInt32>
    ) {
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

    public init(
        columnIndex: Int, neighborBefore: String?, neighborAfter: String?,
        width: ColumnWidth, presetIndex: Int?, isFullWidth: Bool, lastSeen: Date
    ) {
        self.columnIndex = columnIndex
        self.neighborBefore = neighborBefore
        self.neighborAfter = neighborAfter
        self.width = width
        self.presetIndex = presetIndex
        self.isFullWidth = isFullWidth
        self.lastSeen = lastSeen
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

// MARK: - PositionMemory Service

public class PositionMemory {
    private var entries: [PositionKey: SavedPosition] = [:]
    private var windowIDIndex: [CGWindowID: PositionKey] = [:]  // fast-path: same session
    private var capacity: Int
    private var matchingRules: [String: String] = [:]  // bundleID -> "title" or "order"
    private let filePath: URL
    private var isDirty: Bool = false

    public init(capacity: Int, filePath: URL, matchingRules: [String: String] = [:]) {
        self.capacity = capacity
        self.filePath = filePath
        self.matchingRules = matchingRules
    }

    // MARK: - Save

    public func save(
        bundleID: String, windowTitle: String?,
        displayID: UInt32, spaceFingerprint: Set<UInt32>,
        windowID: CGWindowID,
        position: SavedPosition
    ) {
        let key = PositionKey(
            bundleID: bundleID, windowTitle: windowTitle,
            displayID: displayID, spaceFingerprint: spaceFingerprint)
        entries[key] = position
        windowIDIndex[windowID] = key
        isDirty = true
        evictIfNeeded()
    }

    // MARK: - Lookup

    /// Looks up a saved position using a 4-step fallback chain.
    /// Returns the matching key and position, or nil.
    /// For order-based matching (steps 3-4), returns the entry with lowest columnIndex.
    public func lookup(
        bundleID: String, windowTitle: String?,
        displayID: UInt32, spaceFingerprint: Set<UInt32>,
        windowID: CGWindowID
    ) -> (key: PositionKey, position: SavedPosition)? {
        let isOrderBased = matchingRules[bundleID] == "order"
        #if DEBUG
            print(
                "[PositionMemory] lookup wid=\(windowID) bundleID=\(bundleID) title=\(windowTitle ?? "nil") displayID=\(displayID) space=\(spaceFingerprint) orderBased=\(isOrderBased)"
            )
            fflush(stdout)
        #endif

        // Step 0: Fast-path — CGWindowID match (same session, exact window)
        if let key = windowIDIndex[windowID], let pos = entries[key] {
            #if DEBUG
                print("[PositionMemory] hit step=0 (windowID) col=\(pos.columnIndex)")
                fflush(stdout)
            #endif
            return (key, pos)
        }

        // Step 1: Exact match (bundleID, title, displayID, spaceFingerprint)
        if !isOrderBased, let title = windowTitle {
            let key = PositionKey(
                bundleID: bundleID, windowTitle: title,
                displayID: displayID, spaceFingerprint: spaceFingerprint)
            if let pos = entries[key] {
                #if DEBUG
                    print("[PositionMemory] hit step=1 (exact) col=\(pos.columnIndex)")
                    fflush(stdout)
                #endif
                return (key, pos)
            }
        }

        // Step 2: Match ignoring space (bundleID, title, displayID)
        if !isOrderBased, let title = windowTitle {
            if let match = entries.first(where: {
                $0.key.bundleID == bundleID && $0.key.windowTitle == title
                    && $0.key.displayID == displayID
            }) {
                #if DEBUG
                    print("[PositionMemory] hit step=2 (ignore space) col=\(match.value.columnIndex)")
                    fflush(stdout)
                #endif
                return (match.key, match.value)
            }
        }

        // Step 3: Match ignoring title (bundleID, displayID, spaceFingerprint) — lowest columnIndex
        let step3Matches = entries.filter {
            $0.key.bundleID == bundleID && $0.key.displayID == displayID
                && $0.key.spaceFingerprint == spaceFingerprint
        }
        if let best = step3Matches.min(by: { $0.value.columnIndex < $1.value.columnIndex }) {
            #if DEBUG
                print("[PositionMemory] hit step=3 (ignore title) col=\(best.value.columnIndex)")
                fflush(stdout)
            #endif
            return (best.key, best.value)
        }

        // Step 4: Match ignoring title and space (bundleID, displayID) — lowest columnIndex
        let step4Matches = entries.filter {
            $0.key.bundleID == bundleID && $0.key.displayID == displayID
        }
        if let best = step4Matches.min(by: { $0.value.columnIndex < $1.value.columnIndex }) {
            #if DEBUG
                print("[PositionMemory] hit step=4 (bundleID only) col=\(best.value.columnIndex)")
                fflush(stdout)
            #endif
            return (best.key, best.value)
        }

        #if DEBUG
            print("[PositionMemory] miss")
            fflush(stdout)
        #endif
        return nil
    }

    // MARK: - Consume

    public func consume(key: PositionKey) {
        entries.removeValue(forKey: key)
        windowIDIndex = windowIDIndex.filter { $0.value != key }
        isDirty = true
    }

    // MARK: - Clear

    public func clearAll() {
        entries.removeAll()
        windowIDIndex.removeAll()
        isDirty = true
    }

    public func clear(bundleID: String) {
        let removed = entries.filter { $0.key.bundleID == bundleID }
        entries = entries.filter { $0.key.bundleID != bundleID }
        let removedKeys = Set(removed.map(\.key))
        windowIDIndex = windowIDIndex.filter { !removedKeys.contains($0.value) }
        isDirty = true
    }

    // MARK: - Config

    public func applyConfig(capacity: Int, matchingRules: [String: String]) {
        self.capacity = capacity
        self.matchingRules = matchingRules
        evictIfNeeded()
    }

    // MARK: - LRU Eviction

    private func evictIfNeeded() {
        while entries.count > capacity {
            if let oldest = entries.min(by: { $0.value.lastSeen < $1.value.lastSeen }) {
                entries.removeValue(forKey: oldest.key)
                windowIDIndex = windowIDIndex.filter { $0.value != oldest.key }
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
            #if DEBUG
                print("[PositionMemory] Failed to persist: \(error)")
                fflush(stdout)
            #endif
        }
    }

    public func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: filePath.path) else { return }

        do {
            let data = try Data(contentsOf: filePath)
            let file = try JSONDecoder().decode(PositionFile.self, from: data)
            guard file.version == 1 else {
                #if DEBUG
                    print("[PositionMemory] Unknown file version \(file.version), starting fresh")
                    fflush(stdout)
                #endif
                return
            }
            entries.removeAll()
            for entry in file.entries {
                // Normalize stale space fingerprints to empty set on load
                let normalizedKey = PositionKey(
                    bundleID: entry.key.bundleID,
                    windowTitle: entry.key.windowTitle,
                    displayID: entry.key.displayID,
                    spaceFingerprint: []
                )
                entries[normalizedKey] = entry.position
            }
            isDirty = true  // Normalized fingerprints need persisting
            evictIfNeeded()
            #if DEBUG
                print("[PositionMemory] Loaded \(entries.count) entries from disk")
                fflush(stdout)
            #endif
        } catch {
            #if DEBUG
                print("[PositionMemory] Failed to load (starting fresh): \(error)")
                fflush(stdout)
            #endif
        }
    }

    // MARK: - Debug

    public func allEntries() -> [(key: PositionKey, position: SavedPosition)] {
        entries.map { (key: $0.key, position: $0.value) }
            .sorted { $0.position.lastSeen > $1.position.lastSeen }
    }

    public var count: Int { entries.count }
}
