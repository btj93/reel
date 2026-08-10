import Foundation
import CoreGraphics
import Core
import WindowManager

// MARK: - Disk-format mirrors (for constructing on-disk fixtures)
//
// StripSnapshotStore's legacy/v2 Codable structs are file-private in
// PositionMemory.swift, so we can't build them directly. These mirrors carry
// the *same property names* and reuse the real public `ColumnWidth` /
// `StripSnapshot` types, so `JSONEncoder` produces byte-identical JSON that the
// store's decoder accepts. No production code is touched.

private struct TestLegacyFile: Codable {
    let version: Int
    var entries: [TestLegacyEntry]
}

private struct TestLegacyEntry: Codable {
    let key: TestLegacyKey
    let position: TestLegacyPosition
}

private struct TestLegacyKey: Codable {
    let bundleID: String
    let windowTitle: String?
    let displayID: UInt32
    let spaceFingerprint: Set<UInt32>
}

private struct TestLegacyPosition: Codable {
    let columnIndex: Int
    let neighborBefore: String?
    let neighborAfter: String?
    let width: ColumnWidth
    let presetIndex: Int?
    let isFullWidth: Bool
    let lastSeen: Date
}

private struct TestV2File: Codable {
    let version: Int
    var snapshots: [TestV2Entry]
}

private struct TestV2Entry: Codable {
    let displayID: UInt32
    let spaceSignature: [String]
    let snapshot: StripSnapshot
}

// MARK: - Temp-dir sandbox helper

/// Runs `body` with a fresh unique directory under the system temp dir and the
/// primary snapshot file path inside it. The directory (and every file the store
/// writes, including the sibling legacy file) is removed afterwards. Deterministic:
/// no sleeps, no wall-clock dependence beyond `Date()` values we pin ourselves.
private func withTempStore(_ body: (_ dir: URL, _ filePath: URL) -> Void) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("reel-l1store-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let filePath = dir.appendingPathComponent("strip-snapshots.json")
    body(dir, filePath)
}

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

func runL1StoreTests() {
    print()
    print("StripSnapshotStore Tests")

    section("save + snapshot(for:) exact live hit")
    do {
        withTempStore { _, filePath in
            let store = StripSnapshotStore(filePath: filePath)
            let key = SnapshotKey(groupID: [1], spaceFingerprint: [10, 20])
            let snap = StripSnapshot(slots: [
                makeSlot(bundleID: "com.a", title: "A"),
                makeSlot(bundleID: "com.b", title: "B"),
            ], lastUpdated: fixedDate)
            store.save(snap, for: key)

            let got = store.snapshot(for: key)
            check(got != nil, "exact key returns a snapshot")
            assertEq(got?.slots.count ?? -1, 2, "two slots restored")
            assertEq(got?.slots.first?.bundleID ?? "", "com.a", "first slot bundleID")
            assertEq(store.count, 1, "one live snapshot counted")
        }
    }

    // A debounced capture that fires after a clear re-creates the snapshot from the
    // live strip and persists it, so `reel-msg clear-positions` silently undid
    // itself ~1s later. Asserted via introspection rather than sleeping out the real
    // debounce, so the check stays deterministic.
    // The capture-time lookup must stay lenient about LIVE fingerprint drift (one
    // window closing shifts the fingerprint) while refusing the reader's sole-entry
    // disk bypass, which would import a foreign Space's slots as ghosts.
    section("strict capture lookup — survives live fingerprint drift")
    do {
        withTempStore { _, filePath in
            let store = StripSnapshotStore(filePath: filePath)
            let key = SnapshotKey(groupID: [1], spaceFingerprint: [10, 11, 12])
            store.save(StripSnapshot(slots: [
                makeSlot(bundleID: "com.a", title: "A"),
            ], lastUpdated: fixedDate), for: key)

            // One window closed: 2/3 Jaccard > 0.5, so the live snapshot must hit.
            let drifted = store.snapshotStrictByBundleIDs(
                groupID: [1], fingerprint: [10, 11], currentBundleIDs: ["com.a"])
            check(drifted != nil, "live snapshot survives fingerprint drift")
        }
    }

    section("strict capture lookup — refuses a foreign sole disk entry")
    do {
        withTempStore { _, filePath in
            let store = StripSnapshotStore(filePath: filePath)
            store.save(StripSnapshot(slots: [
                makeSlot(bundleID: "com.a", title: "A"),
            ], lastUpdated: fixedDate), for: SnapshotKey(groupID: [1], spaceFingerprint: [10, 11]))
            store.persistToDisk()

            let reloaded = StripSnapshotStore(filePath: filePath)
            reloaded.loadFromDisk()
            // Disjoint fingerprint AND disjoint bundle set: the lenient reader would
            // still take this as the group's only disk entry.
            let foreign = reloaded.snapshotStrictByBundleIDs(
                groupID: [1], fingerprint: [90, 91], currentBundleIDs: ["com.zzz"])
            check(foreign == nil, "strict lookup refuses a non-matching sole disk entry")
            // The lenient reader deliberately still accepts it — unchanged behavior.
            let lenient = reloaded.snapshotFuzzyByBundleIDs(
                groupID: [1], fingerprint: [90, 91], currentBundleIDs: ["com.zzz"])
            check(lenient != nil, "reader's sole-entry bypass is left intact")
        }
    }

    section("clearAll cancels pending debounced captures")
    do {
        withTempStore { _, filePath in
            let store = StripSnapshotStore(filePath: filePath)
            let key = SnapshotKey(groupID: [1], spaceFingerprint: [10, 20])
            store.scheduleSnapshotSave(key: key) {
                StripSnapshot(slots: [makeSlot(bundleID: "com.a", title: "A")], lastUpdated: fixedDate)
            }
            assertEq(store.debugPendingDebounceCount, 1, "a capture is pending")
            store.clearAll()
            assertEq(store.debugPendingDebounceCount, 0, "clearAll cancelled the pending capture")
            assertEq(store.count, 0, "nothing live after clear")
        }
    }

    section("clear(bundleID:) cancels pending debounced captures")
    do {
        withTempStore { _, filePath in
            let store = StripSnapshotStore(filePath: filePath)
            let key = SnapshotKey(groupID: [1], spaceFingerprint: [10, 20])
            store.scheduleSnapshotSave(key: key) {
                StripSnapshot(slots: [makeSlot(bundleID: "com.a", title: "A")], lastUpdated: fixedDate)
            }
            assertEq(store.debugPendingDebounceCount, 1, "a capture is pending")
            store.clear(bundleID: "com.a")
            assertEq(store.debugPendingDebounceCount, 0, "clear(bundleID:) cancelled the pending capture")
        }
    }

    section("SnapshotKey normalizes groupID ordering (unsorted key still hits)")
    do {
        withTempStore { _, filePath in
            let store = StripSnapshotStore(filePath: filePath)
            let saveKey = SnapshotKey(groupID: [3, 1, 2], spaceFingerprint: [7])
            store.save(StripSnapshot(slots: [makeSlot(bundleID: "com.a")], lastUpdated: fixedDate), for: saveKey)
            // Query with a differently-ordered groupID + identical fingerprint.
            let queryKey = SnapshotKey(groupID: [1, 2, 3], spaceFingerprint: [7])
            check(store.snapshot(for: queryKey) != nil, "groupID sorted in init → keys equal")
        }
    }

    section("fuzzy live match — Jaccard > 0.5")
    do {
        withTempStore { _, filePath in
            let store = StripSnapshotStore(filePath: filePath)
            let key = SnapshotKey(groupID: [1], spaceFingerprint: [1, 2, 3])
            store.save(StripSnapshot(slots: [makeSlot(bundleID: "com.a")], lastUpdated: fixedDate), for: key)
            // {1,2,3} vs {1,2,3,4} → 3/4 = 0.75 > 0.5.
            let query = SnapshotKey(groupID: [1], spaceFingerprint: [1, 2, 3, 4])
            check(store.snapshot(for: query) != nil, "0.75 Jaccard is a fuzzy hit")
        }
    }

    section("fuzzy live rejection — Jaccard < 0.5")
    do {
        withTempStore { _, filePath in
            let store = StripSnapshotStore(filePath: filePath)
            let key = SnapshotKey(groupID: [1], spaceFingerprint: [1, 2, 3, 4])
            store.save(StripSnapshot(slots: [makeSlot(bundleID: "com.a")], lastUpdated: fixedDate), for: key)
            // {1,2,3,4} vs {1,7,8,9} → 1/7 ≈ 0.14 < 0.5, and no disk entries.
            let query = SnapshotKey(groupID: [1], spaceFingerprint: [1, 7, 8, 9])
            check(store.snapshot(for: query) == nil, "0.14 Jaccard is rejected")
        }
    }

    section("fuzzy live rejection — Jaccard exactly 0.5 (strict >)")
    do {
        withTempStore { _, filePath in
            let store = StripSnapshotStore(filePath: filePath)
            let key = SnapshotKey(groupID: [1], spaceFingerprint: [1, 2])
            store.save(StripSnapshot(slots: [makeSlot(bundleID: "com.a")], lastUpdated: fixedDate), for: key)
            // {1,2} vs {1,2,3,4} → 2/4 = 0.5, NOT > 0.5 → rejected.
            let query = SnapshotKey(groupID: [1], spaceFingerprint: [1, 2, 3, 4])
            check(store.snapshot(for: query) == nil, "exactly 0.5 is rejected (threshold is strict)")
        }
    }

    section("fuzzy live rejection — different groupID never matches")
    do {
        withTempStore { _, filePath in
            let store = StripSnapshotStore(filePath: filePath)
            store.save(StripSnapshot(slots: [makeSlot(bundleID: "com.a")], lastUpdated: fixedDate),
                       for: SnapshotKey(groupID: [1], spaceFingerprint: [1, 2, 3]))
            // Identical fingerprint but different group → no match.
            let query = SnapshotKey(groupID: [2], spaceFingerprint: [1, 2, 3])
            check(store.snapshot(for: query) == nil, "group mismatch blocks fuzzy")
        }
    }

    section("roundtrip persistToDisk → loadFromDisk (windowIDs nil'd)")
    do {
        withTempStore { _, filePath in
            let store1 = StripSnapshotStore(filePath: filePath)
            let key = SnapshotKey(groupID: [1], spaceFingerprint: [10, 20])
            store1.save(StripSnapshot(slots: [
                makeSlot(windowID: 555, bundleID: "com.a", title: "A"),
                makeSlot(windowID: 666, bundleID: "com.b", title: "B"),
            ], lastUpdated: fixedDate), for: key)
            store1.persistToDisk()
            check(FileManager.default.fileExists(atPath: filePath.path), "file written")

            let store2 = StripSnapshotStore(filePath: filePath)
            store2.loadFromDisk()
            assertEq(store2.diskEntryCount(), 1, "one disk entry loaded")
            // Single disk entry for this group → snapshot(for:) returns it via disk scan.
            let got = store2.snapshot(for: SnapshotKey(groupID: [1], spaceFingerprint: []))
            check(got != nil, "loaded entry retrievable")
            assertEq(got?.slots.count ?? -1, 2, "both slots survived roundtrip")
            check(got?.slots.allSatisfy { $0.windowID == nil } ?? false, "windowIDs nil'd on persist")
            assertEq(got?.slots.first?.bundleID ?? "", "com.a", "slot order preserved")
        }
    }

    section("persistToDisk is a no-op when not dirty")
    do {
        withTempStore { _, filePath in
            let store = StripSnapshotStore(filePath: filePath)
            store.persistToDisk()  // nothing saved → isDirty false → early return
            check(!FileManager.default.fileExists(atPath: filePath.path), "no file when clean")
            store.save(StripSnapshot(slots: [makeSlot(bundleID: "com.a")], lastUpdated: fixedDate),
                       for: SnapshotKey(groupID: [1], spaceFingerprint: [1]))
            store.persistToDisk()
            check(FileManager.default.fileExists(atPath: filePath.path), "file appears once dirty")
        }
    }

    section("disk-entry scan — snapshotFuzzyByBundleIDs picks best bundle match")
    do {
        withTempStore { _, filePath in
            let store1 = StripSnapshotStore(filePath: filePath)
            store1.save(StripSnapshot(slots: [makeSlot(bundleID: "com.a"), makeSlot(bundleID: "com.b")],
                                      lastUpdated: fixedDate),
                        for: SnapshotKey(groupID: [1], spaceFingerprint: [1, 2]))
            store1.save(StripSnapshot(slots: [makeSlot(bundleID: "com.c"), makeSlot(bundleID: "com.d")],
                                      lastUpdated: fixedDate),
                        for: SnapshotKey(groupID: [1], spaceFingerprint: [3, 4]))
            store1.persistToDisk()

            let store2 = StripSnapshotStore(filePath: filePath)
            store2.loadFromDisk()
            assertEq(store2.diskEntryCount(), 2, "two disk entries for group [1]")

            let got = store2.snapshotFuzzyByBundleIDs(
                groupID: [1], fingerprint: [99], currentBundleIDs: ["com.a", "com.b"])
            check(got != nil, "bundle-signature match found")
            check(got?.slots.contains { $0.bundleID == "com.a" } ?? false, "matched the com.a/com.b entry")
            check(!(got?.slots.contains { $0.bundleID == "com.c" } ?? true), "not the com.c/com.d entry")

            // Below-threshold, multi-entry group → no match.
            let miss = store2.snapshotFuzzyByBundleIDs(
                groupID: [1], fingerprint: [99], currentBundleIDs: ["com.zzz"])
            check(miss == nil, "disjoint bundleIDs (multi-entry group) → no match")
        }
    }

    section("disk-entry scan — single entry matches regardless of score")
    do {
        withTempStore { _, filePath in
            let store1 = StripSnapshotStore(filePath: filePath)
            store1.save(StripSnapshot(slots: [makeSlot(bundleID: "com.a")], lastUpdated: fixedDate),
                        for: SnapshotKey(groupID: [7], spaceFingerprint: [1]))
            store1.persistToDisk()

            let store2 = StripSnapshotStore(filePath: filePath)
            store2.loadFromDisk()
            // currentBundleIDs share nothing with the entry, but it's the only one for group [7].
            let got = store2.snapshotFuzzyByBundleIDs(
                groupID: [7], fingerprint: [], currentBundleIDs: ["com.unrelated"])
            check(got != nil, "sole disk entry for the group is used regardless of Jaccard")
        }
    }

    section("consumeDiskEntry removes the matching entry (Jaccard > 0.5)")
    do {
        withTempStore { _, filePath in
            let store1 = StripSnapshotStore(filePath: filePath)
            store1.save(StripSnapshot(slots: [makeSlot(bundleID: "com.a"), makeSlot(bundleID: "com.b")],
                                      lastUpdated: fixedDate),
                        for: SnapshotKey(groupID: [1], spaceFingerprint: [1, 2]))
            store1.save(StripSnapshot(slots: [makeSlot(bundleID: "com.c"), makeSlot(bundleID: "com.d")],
                                      lastUpdated: fixedDate),
                        for: SnapshotKey(groupID: [1], spaceFingerprint: [3, 4]))
            store1.persistToDisk()

            let store2 = StripSnapshotStore(filePath: filePath)
            store2.loadFromDisk()
            assertEq(store2.diskEntryCount(), 2, "start with two")

            // Non-matching bundleIDs remove nothing.
            store2.consumeDiskEntry(groupID: [1], bundleIDs: ["com.nope"])
            assertEq(store2.diskEntryCount(), 2, "below-threshold consume is a no-op")

            // Matching bundleIDs remove exactly one.
            store2.consumeDiskEntry(groupID: [1], bundleIDs: ["com.a", "com.b"])
            assertEq(store2.diskEntryCount(), 1, "matching entry consumed")

            // The survivor is the com.c/com.d entry, now the sole entry → returned unconditionally.
            let survivor = store2.snapshotFuzzyByBundleIDs(
                groupID: [1], fingerprint: [], currentBundleIDs: ["com.c", "com.d"])
            check(survivor?.slots.contains { $0.bundleID == "com.c" } ?? false, "com.c/com.d survived")
        }
    }

    section("clear(bundleID:) drops matching slots from live snapshots")
    do {
        withTempStore { _, filePath in
            let store = StripSnapshotStore(filePath: filePath)
            let key = SnapshotKey(groupID: [1], spaceFingerprint: [1, 2])
            store.save(StripSnapshot(slots: [
                makeSlot(bundleID: "com.a"),
                makeSlot(bundleID: "com.b"),
            ], lastUpdated: fixedDate), for: key)
            store.clear(bundleID: "com.a")
            let got = store.snapshot(for: key)
            assertEq(got?.slots.count ?? -1, 1, "one slot left")
            assertEq(got?.slots.first?.bundleID ?? "", "com.b", "com.a removed, com.b kept")
        }
    }

    section("clearAll empties live + disk")
    do {
        withTempStore { _, filePath in
            let store1 = StripSnapshotStore(filePath: filePath)
            store1.save(StripSnapshot(slots: [makeSlot(bundleID: "com.a")], lastUpdated: fixedDate),
                        for: SnapshotKey(groupID: [1], spaceFingerprint: [1]))
            store1.persistToDisk()

            let store2 = StripSnapshotStore(filePath: filePath)
            store2.loadFromDisk()  // 1 disk entry
            store2.save(StripSnapshot(slots: [makeSlot(bundleID: "com.b")], lastUpdated: fixedDate),
                        for: SnapshotKey(groupID: [2], spaceFingerprint: [2]))  // 1 live entry
            assertEq(store2.count, 2, "one live + one disk")
            store2.clearAll()
            assertEq(store2.count, 0, "count zero after clearAll")
            assertEq(store2.diskEntryCount(), 0, "disk entries gone")
            check(store2.allSnapshots().isEmpty, "live snapshots gone")
        }
    }

    section("saveImmediate stores now")
    do {
        withTempStore { _, filePath in
            let store = StripSnapshotStore(filePath: filePath)
            let key = SnapshotKey(groupID: [1], spaceFingerprint: [1])
            store.saveImmediate(StripSnapshot(slots: [makeSlot(bundleID: "com.a")], lastUpdated: fixedDate),
                                for: key)
            check(store.snapshot(for: key) != nil, "immediately retrievable")
            assertEq(store.count, 1, "counted")
        }
    }

    section("legacy migration — window-positions.json → v3 snapshots")
    do {
        withTempStore { dir, filePath in
            // Two legacy entries in the same (display, space) → one grouped snapshot.
            let legacyFile = TestLegacyFile(version: 1, entries: [
                TestLegacyEntry(
                    key: TestLegacyKey(bundleID: "com.x", windowTitle: "X",
                                       displayID: 1, spaceFingerprint: [10, 20]),
                    position: TestLegacyPosition(columnIndex: 0, neighborBefore: nil, neighborAfter: nil,
                                                 width: .proportion(0.5), presetIndex: nil,
                                                 isFullWidth: false, lastSeen: fixedDate)),
                TestLegacyEntry(
                    key: TestLegacyKey(bundleID: "com.y", windowTitle: "Y",
                                       displayID: 1, spaceFingerprint: [10, 20]),
                    position: TestLegacyPosition(columnIndex: 1, neighborBefore: nil, neighborAfter: nil,
                                                 width: .fixed(800), presetIndex: 2,
                                                 isFullWidth: false, lastSeen: fixedDate)),
            ])
            let legacyPath = dir.appendingPathComponent("window-positions.json")
            try! JSONEncoder().encode(legacyFile).write(to: legacyPath)
            check(!FileManager.default.fileExists(atPath: filePath.path), "new file absent before load")

            let store = StripSnapshotStore(filePath: filePath)
            store.loadFromDisk()  // new file absent → legacy migration path

            assertEq(store.diskEntryCount(), 1, "two legacy entries → one grouped snapshot")
            check(!FileManager.default.fileExists(atPath: legacyPath.path), "legacy file deleted after migration")
            check(FileManager.default.fileExists(atPath: filePath.path), "v3 file written")

            let got = store.snapshot(for: SnapshotKey(groupID: [1], spaceFingerprint: [10, 20]))
            assertEq(got?.slots.count ?? -1, 2, "both windows migrated")
            // Slots reconstructed in columnIndex order.
            assertEq(got?.slots.first?.bundleID ?? "", "com.x", "column 0 first")
            assertEq(got?.slots.last?.bundleID ?? "", "com.y", "column 1 last")
        }
    }

    section("v2 → v3 migration rewrites the on-disk header")
    do {
        withTempStore { _, filePath in
            let v2 = TestV2File(version: 2, snapshots: [
                TestV2Entry(displayID: 5, spaceSignature: ["com.a"],
                            snapshot: StripSnapshot(slots: [makeSlot(bundleID: "com.a")],
                                                    lastUpdated: fixedDate)),
            ])
            try! JSONEncoder().encode(v2).write(to: filePath)

            let store = StripSnapshotStore(filePath: filePath)
            store.loadFromDisk()  // v2 header → migrate → persist as v3
            assertEq(store.diskEntryCount(), 1, "v2 entry loaded")
            // displayID 5 becomes groupID [5].
            let got = store.snapshot(for: SnapshotKey(groupID: [5], spaceFingerprint: []))
            assertEq(got?.slots.count ?? -1, 1, "v2 snapshot preserved")

            // The file on disk is now v3.
            struct Header: Codable { let version: Int }
            let data = try! Data(contentsOf: filePath)
            let header = try! JSONDecoder().decode(Header.self, from: data)
            assertEq(header.version, 3, "on-disk header rewritten to v3")
        }
    }
}
