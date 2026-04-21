import Core
import CoreGraphics
import Foundation

// MARK: - Snapshot Key

public struct SnapshotKey: Hashable, Codable {
    /// Sorted-ascending member display IDs of the group this snapshot belongs to.
    public let groupID: [UInt32]
    public let spaceFingerprint: Set<UInt32>

    public init(groupID: [UInt32], spaceFingerprint: Set<UInt32>) {
        self.groupID = groupID.sorted()
        self.spaceFingerprint = spaceFingerprint
    }
}

// MARK: - Restored Slot (returned to callers)

public struct RestoredSlot {
    public let slotIndex: Int
    public let width: ColumnWidth
    public let presetIndex: Int?
    public let isFullWidth: Bool

    public init(slotIndex: Int, width: ColumnWidth, presetIndex: Int?, isFullWidth: Bool) {
        self.slotIndex = slotIndex
        self.width = width
        self.presetIndex = presetIndex
        self.isFullWidth = isFullWidth
    }
}

// MARK: - Recent Removal (for tab-switch detection)

public struct RecentRemoval {
    public let columnIndex: Int
    public let width: ColumnWidth
    public let presetIndex: Int?
    public let isFullWidth: Bool
    public let date: Date

    public init(columnIndex: Int, width: ColumnWidth, presetIndex: Int?, isFullWidth: Bool, date: Date) {
        self.columnIndex = columnIndex
        self.width = width
        self.presetIndex = presetIndex
        self.isFullWidth = isFullWidth
        self.date = date
    }
}

// MARK: - Disk Format

struct SnapshotFile: Codable {
    let version: Int  // 3
    var snapshots: [SnapshotFileEntry]
}

struct SnapshotFileEntry: Codable {
    /// Sorted-ascending member display IDs.
    let groupID: [UInt32]
    let spaceSignature: [String]  // sorted bundleIDs — stable across restarts
    let snapshot: StripSnapshot   // slots with windowID nil'd out
}

/// V2 on-disk shape, kept only for migration in `loadNewFormat`.
private struct SnapshotFileV2: Codable {
    let version: Int
    var snapshots: [SnapshotFileEntryV2]
}

private struct SnapshotFileEntryV2: Codable {
    let displayID: UInt32
    let spaceSignature: [String]
    let snapshot: StripSnapshot
}

// MARK: - Legacy Disk Format (for migration)

private struct LegacyPositionFile: Codable {
    let version: Int
    var entries: [LegacyPositionFileEntry]
}

private struct LegacyPositionFileEntry: Codable {
    let key: LegacyPositionKey
    let position: LegacyPosition
}

private struct LegacyPositionKey: Codable {
    let bundleID: String
    let windowTitle: String?
    let displayID: UInt32
    let spaceFingerprint: Set<UInt32>
}

private struct LegacyPosition: Codable {
    let columnIndex: Int
    let neighborBefore: String?
    let neighborAfter: String?
    let width: ColumnWidth
    let presetIndex: Int?
    let isFullWidth: Bool
    let lastSeen: Date
}

// MARK: - StripSnapshotStore

/// Replaces PositionMemory. Stores ordered strip snapshots per (display, space).
/// All access is on the main thread — no locking needed.
public class StripSnapshotStore {
    /// Live session snapshots with real fingerprints.
    private var liveSnapshots: [SnapshotKey: StripSnapshot] = [:]
    /// Disk-loaded entries kept as a flat array (avoids key collision on empty fingerprints).
    private var diskEntries: [SnapshotFileEntry] = []
    /// Tracks which diskEntry was consumed by which live key, for cleanup.

    private let filePath: URL
    private let legacyFilePath: URL
    private var isDirty: Bool = false

    private var pendingDebounces: [SnapshotKey: DispatchWorkItem] = [:]

    public init(filePath: URL) {
        self.filePath = filePath
        // Legacy file is in the same directory
        self.legacyFilePath = filePath.deletingLastPathComponent()
            .appendingPathComponent("window-positions.json")
    }

    // MARK: - Snapshot Lookup

    /// Non-consuming lookup. Returns the best snapshot for this display+space.
    public func snapshot(for key: SnapshotKey) -> StripSnapshot? {
        // Try exact match in live snapshots
        if let snap = liveSnapshots[key] {
            return snap
        }
        // Try fuzzy match
        return snapshotFuzzy(groupID: key.groupID, fingerprint: key.spaceFingerprint)
    }

    /// Fuzzy lookup: Jaccard >0.5 on live fingerprints, then scan diskEntries by spaceSignature.
    private func snapshotFuzzy(groupID: [UInt32], fingerprint: Set<UInt32>) -> StripSnapshot? {
        // 1. Check live snapshots with Jaccard similarity
        var bestLive: (key: SnapshotKey, snapshot: StripSnapshot, score: Double)?
        for (key, snap) in liveSnapshots {
            guard key.groupID == groupID else { continue }
            let score = jaccardSimilarity(key.spaceFingerprint, fingerprint)
            if score > 0.5, score > (bestLive?.score ?? 0) {
                bestLive = (key, snap, score)
            }
        }
        if let best = bestLive {
            return best.snapshot
        }

        // 2. Scan disk entries for this group (most recent wins, since we can't
        // compare windowID-based fingerprints against bundleID-based signatures)
        let displayDiskEntries = diskEntries.filter { $0.groupID == groupID }
        if displayDiskEntries.count == 1 {
            return displayDiskEntries[0].snapshot
        }
        if let best = displayDiskEntries.max(by: { $0.snapshot.lastUpdated < $1.snapshot.lastUpdated }) {
            return best.snapshot
        }

        return nil
    }

    /// Fuzzy lookup using bundleID set (for cross-session matching against disk entries).
    public func snapshotFuzzyByBundleIDs(groupID: [UInt32], fingerprint: Set<UInt32>, currentBundleIDs: Set<String>) -> StripSnapshot? {
        // 1. Check live snapshots with Jaccard similarity on fingerprints
        var bestLive: (key: SnapshotKey, snapshot: StripSnapshot, score: Double)?
        for (key, snap) in liveSnapshots {
            guard key.groupID == groupID else { continue }
            let score = jaccardSimilarity(key.spaceFingerprint, fingerprint)
            if score > 0.5, score > (bestLive?.score ?? 0) {
                bestLive = (key, snap, score)
            }
        }
        if let best = bestLive {
            return best.snapshot
        }

        // 2. Scan disk entries by spaceSignature Jaccard against currentBundleIDs
        var bestDisk: (index: Int, snapshot: StripSnapshot, score: Double)?
        for (i, entry) in diskEntries.enumerated() {
            guard entry.groupID == groupID else { continue }
            let sigSet = Set(entry.spaceSignature)
            let score = jaccardSimilarityStrings(sigSet, currentBundleIDs)
            // Special case: if only one disk entry for this group, use it regardless of score
            let sameCount = diskEntries.count(where: { $0.groupID == groupID })
            if sameCount == 1 || score > 0.5 {
                let effectiveScore = sameCount == 1 ? 1.0 : score
                if effectiveScore > (bestDisk?.score ?? 0) {
                    bestDisk = (i, entry.snapshot, effectiveScore)
                }
            }
        }
        if let best = bestDisk {
            return best.snapshot
        }

        return nil
    }

    /// Remove the disk entry that was consumed by a live save (matched by groupID + spaceSignature).
    public func consumeDiskEntry(groupID: [UInt32], bundleIDs: Set<String>) {
        // Find the best-matching disk entry and remove it (requires Jaccard > 0.5)
        var bestIndex: Int?
        var bestScore: Double = 0.5  // minimum threshold to prevent cross-space consumption
        for (i, entry) in diskEntries.enumerated() {
            guard entry.groupID == groupID else { continue }
            let sigSet = Set(entry.spaceSignature)
            let score = jaccardSimilarityStrings(sigSet, bundleIDs)
            if score > bestScore {
                bestScore = score
                bestIndex = i
            }
        }
        if let idx = bestIndex {
            diskEntries.remove(at: idx)
        }
    }

    // MARK: - Save

    /// Store a snapshot for the given key. Replaces any existing entry.
    public func save(_ snapshot: StripSnapshot, for key: SnapshotKey) {
        liveSnapshots[key] = snapshot
        isDirty = true
    }

    /// Schedule a debounced save (1s) for the given key. Cancels only the pending save for the same key.
    public func scheduleSnapshotSave(key: SnapshotKey, capture: @escaping () -> StripSnapshot?) {
        pendingDebounces[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let snapshot = capture() else { return }
            self.pendingDebounces.removeValue(forKey: key)
            self.save(snapshot, for: key)
        }
        pendingDebounces[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Immediate save — cancels any pending debounce for the same key, saves the snapshot now.
    public func saveImmediate(_ snapshot: StripSnapshot, for key: SnapshotKey) {
        pendingDebounces[key]?.cancel()
        pendingDebounces.removeValue(forKey: key)
        save(snapshot, for: key)
    }

    // MARK: - Clear

    public func clearAll() {
        liveSnapshots.removeAll()
        diskEntries.removeAll()
        isDirty = true
    }

    public func clear(bundleID: String) {
        for key in liveSnapshots.keys {
            liveSnapshots[key]?.slots.removeAll { $0.bundleID == bundleID }
        }
        for i in diskEntries.indices {
            diskEntries[i] = SnapshotFileEntry(
                groupID: diskEntries[i].groupID,
                spaceSignature: diskEntries[i].spaceSignature.filter { $0 != bundleID },
                snapshot: StripSnapshot(
                    slots: diskEntries[i].snapshot.slots.filter { $0.bundleID != bundleID },
                    lastUpdated: diskEntries[i].snapshot.lastUpdated))
        }
        isDirty = true
    }

    // MARK: - Disk Persistence

    public func persistToDisk() {
        guard isDirty else { return }

        var fileEntries: [SnapshotFileEntry] = []

        // Write all live snapshots
        for (key, snapshot) in liveSnapshots {
            var diskSlots = snapshot.slots
            // Nil out windowIDs (ephemeral)
            for i in diskSlots.indices {
                diskSlots[i].windowID = nil
            }
            let bundleIDs = Set(snapshot.slots.map(\.bundleID))
            let signature = bundleIDs.sorted()
            fileEntries.append(SnapshotFileEntry(
                groupID: key.groupID,
                spaceSignature: signature,
                snapshot: StripSnapshot(slots: diskSlots, lastUpdated: snapshot.lastUpdated)))
        }

        // Also write unconsumed disk entries (spaces not visited this session)
        for entry in diskEntries {
            // Skip if we already have a live entry for this display+signature
            let entrySig = Set(entry.spaceSignature)
            let alreadyCovered = fileEntries.contains {
                $0.groupID == entry.groupID
                    && jaccardSimilarityStrings(Set($0.spaceSignature), entrySig) > 0.8
            }
            if !alreadyCovered {
                fileEntries.append(entry)
            }
        }

        let file = SnapshotFile(version: 3, snapshots: fileEntries)

        do {
            let dir = filePath.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(file)
            try data.write(to: filePath, options: .atomic)
            isDirty = false
        } catch {
            print("[SnapshotStore] Failed to persist: \(error)")
            fflush(stdout)
        }
    }

    public func loadFromDisk() {
        // Try new format first
        if FileManager.default.fileExists(atPath: filePath.path) {
            loadNewFormat()
            return
        }

        // Try legacy migration
        if FileManager.default.fileExists(atPath: legacyFilePath.path) {
            migrateLegacyPositions()
        }
    }

    private func loadNewFormat() {
        do {
            let data = try Data(contentsOf: filePath)
            struct VersionHeader: Codable { let version: Int }
            let header = try JSONDecoder().decode(VersionHeader.self, from: data)

            if header.version == 3 {
                let file = try JSONDecoder().decode(SnapshotFile.self, from: data)
                diskEntries = file.snapshots
                print("[SnapshotStore] Loaded \(diskEntries.count) v3 snapshot entries")
                fflush(stdout)
            } else if header.version == 2 {
                let v2 = try JSONDecoder().decode(SnapshotFileV2.self, from: data)
                diskEntries = v2.snapshots.map { entry in
                    SnapshotFileEntry(
                        groupID: [entry.displayID],
                        spaceSignature: entry.spaceSignature,
                        snapshot: entry.snapshot
                    )
                }
                isDirty = true
                persistToDisk()
                print("[SnapshotStore] Migrated \(diskEntries.count) entries v2 → v3")
                fflush(stdout)
            } else {
                print("[SnapshotStore] Unknown file version \(header.version), starting fresh")
                fflush(stdout)
            }
        } catch {
            print("[SnapshotStore] Failed to load (starting fresh): \(error)")
            fflush(stdout)
        }
    }

    private func migrateLegacyPositions() {
        do {
            let data = try Data(contentsOf: legacyFilePath)
            let file = try JSONDecoder().decode(LegacyPositionFile.self, from: data)
            guard file.version == 1 else { return }

            // Group by (displayID, spaceFingerprint) to preserve multi-space layouts.
            // Use sorted fingerprint array as a hashable key since Set<UInt32> can't be a dict key.
            struct SpaceKey: Hashable {
                let displayID: UInt32
                let fingerprint: [UInt32]  // sorted for stable hashing
            }
            var bySpace: [SpaceKey: [(key: LegacyPositionKey, position: LegacyPosition)]] = [:]
            for entry in file.entries {
                let spaceKey = SpaceKey(
                    displayID: entry.key.displayID,
                    fingerprint: entry.key.spaceFingerprint.sorted())
                bySpace[spaceKey, default: []].append((entry.key, entry.position))
            }

            for (spaceKey, entries) in bySpace {
                // Sort by column index to reconstruct strip order
                let sorted = entries.sorted { $0.position.columnIndex < $1.position.columnIndex }
                let slots = sorted.map { entry in
                    SlotDescriptor(
                        windowID: nil,
                        bundleID: entry.key.bundleID,
                        windowTitle: entry.key.windowTitle,
                        width: entry.position.width,
                        presetIndex: entry.position.presetIndex,
                        isFullWidth: entry.position.isFullWidth)
                }
                let bundleIDs = Set(slots.map(\.bundleID)).sorted()
                diskEntries.append(SnapshotFileEntry(
                    groupID: [spaceKey.displayID],
                    spaceSignature: bundleIDs,
                    snapshot: StripSnapshot(
                        slots: slots,
                        lastUpdated: sorted.last?.position.lastSeen ?? Date())))
            }

            // Write new format and delete legacy file
            isDirty = true
            persistToDisk()
            try? FileManager.default.removeItem(at: legacyFilePath)

            print("[SnapshotStore] Migrated \(file.entries.count) legacy entries → \(diskEntries.count) snapshots")
            fflush(stdout)
        } catch {
            print("[SnapshotStore] Legacy migration failed: \(error)")
            fflush(stdout)
        }
    }

    // MARK: - Debug

    public func allSnapshots() -> [(key: SnapshotKey, snapshot: StripSnapshot)] {
        liveSnapshots.map { (key: $0.key, snapshot: $0.value) }
    }

    public func diskEntryCount() -> Int {
        diskEntries.count
    }

    public var count: Int { liveSnapshots.count + diskEntries.count }

    // MARK: - Helpers

    private func jaccardSimilarity(_ a: Set<UInt32>, _ b: Set<UInt32>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        return Double(intersection) / Double(union)
    }

    private func jaccardSimilarityStrings(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        return Double(intersection) / Double(union)
    }
}
