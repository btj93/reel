import Foundation
import CoreGraphics
import Core

// Backfill for Core branches with no existing coverage in main.swift.
//
// WindowClassification: main.swift already covers standard-window title/frame
// gating, plain AXDialog→float, AXMenu→ignore, and non-zero layer→ignore. The
// branches below (fullscreen, popover, tooltip, sheet, system dialog, the
// resizable-dialog→tile path, floating/utility, non-resizable-with-close,
// no-close-button, minimized) were untested. SnapshotMatching adds the
// no-match / empty-input edges the existing suite didn't assert.

func runL1CoreBackfillTests() {
    print()
    print("Window Classification Backfill Tests")

    // `resolve` clamps a fixed width to the working area; `resolveBlended` returned
    // the literal. Strip caches the clamped value while LayoutEngine positions
    // later columns from the unbounded one → cumulative X drift and overlap.
    section("resolveBlended clamps .fixed to the region, matching resolve")
    do {
        let region = DisplayRegion(
            displayID: 1, rect: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let w = ColumnWidth.fixed(3000)
        let direct = w.resolve(workingAreaWidth: 1440, gap: 16)
        let blended = w.resolveBlended(overlaps: [(region, 1.0)], gap: 16)
        assertClose(blended, direct, tolerance: 0.5,
            "blended .fixed must clamp exactly like resolve (got \(blended) vs \(direct))")
        assertClose(blended, 1440, tolerance: 0.5, "clamped to the region width")
    }

    section("resolveBlended leaves a fitting .fixed width alone")
    do {
        let region = DisplayRegion(
            displayID: 1, rect: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let blended = ColumnWidth.fixed(600).resolveBlended(overlaps: [(region, 1.0)], gap: 16)
        assertClose(blended, 600, tolerance: 0.5, "a width that fits is unchanged")
    }

    section("Fullscreen window → ignore")
    do {
        let props = WindowProperties(role: "AXWindow", subrole: "AXStandardWindow",
                                     isResizable: true, hasCloseButton: true,
                                     isFullscreen: true, title: "Full")
        assertEq(classifyWindow(props), .ignore)
    }

    section("AXPopover → ignore")
    do {
        let props = WindowProperties(role: "AXPopover", subrole: nil,
                                     isResizable: false, hasCloseButton: false)
        assertEq(classifyWindow(props), .ignore)
    }

    section("AXToolTip subrole → ignore")
    do {
        let props = WindowProperties(role: "AXWindow", subrole: "AXToolTip",
                                     isResizable: false, hasCloseButton: false)
        assertEq(classifyWindow(props), .ignore)
    }

    section("AXSheet → float")
    do {
        let props = WindowProperties(role: "AXSheet", subrole: nil,
                                     isResizable: true, hasCloseButton: true, title: "Sheet")
        assertEq(classifyWindow(props), .float)
    }

    section("AXSystemDialog subrole → float")
    do {
        let props = WindowProperties(role: "AXWindow", subrole: "AXSystemDialog",
                                     isResizable: true, hasCloseButton: true)
        assertEq(classifyWindow(props), .float)
    }

    section("AXDialog resizable + close button → tile (TablePlus/OrbStack)")
    do {
        let props = WindowProperties(role: "AXWindow", subrole: "AXDialog",
                                     isResizable: true, hasCloseButton: true, title: "DB")
        assertEq(classifyWindow(props), .tile)
    }

    section("AXFloatingWindow → float")
    do {
        let props = WindowProperties(role: "AXWindow", subrole: "AXFloatingWindow",
                                     isResizable: true, hasCloseButton: true)
        assertEq(classifyWindow(props), .float)
    }

    section("AXUtilityWindow → float")
    do {
        let props = WindowProperties(role: "AXWindow", subrole: "AXUtilityWindow",
                                     isResizable: true, hasCloseButton: true)
        assertEq(classifyWindow(props), .float)
    }

    section("Close button but not resizable → float (About/prefs)")
    do {
        let props = WindowProperties(role: "AXWindow", subrole: "AXStandardWindow",
                                     isResizable: false, hasCloseButton: true, title: "About")
        assertEq(classifyWindow(props), .float)
    }

    section("No close button → ignore (system UI)")
    do {
        let props = WindowProperties(role: "AXWindow", subrole: "AXStandardWindow",
                                     isResizable: true, hasCloseButton: false, title: "Bar")
        assertEq(classifyWindow(props), .ignore)
    }

    section("Minimized standard window → still tile")
    do {
        // Minimized windows are tracked and re-tiled on deminimize, not ignored.
        let props = WindowProperties(role: "AXWindow", subrole: "AXStandardWindow",
                                     isResizable: true, hasCloseButton: true,
                                     isMinimized: true, title: "Doc",
                                     frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        assertEq(classifyWindow(props), .tile)
    }

    print()
    print("Snapshot Matching Backfill Tests")

    section("matchWindowToSlot — no bundleID match → nil")
    do {
        let snapshot = StripSnapshot(slots: [
            makeSlot(bundleID: "com.app.A"),
            makeSlot(bundleID: "com.app.B"),
        ], lastUpdated: Date())
        let result = matchWindowToSlot(windowID: 42, bundleID: "com.app.Z", title: nil,
                                       snapshot: snapshot, filledSlots: [], now: Date())
        check(result == nil, "no slot with that bundleID → nil")
    }

    section("matchWindowToSlot — all matching slots already filled → nil")
    do {
        let snapshot = StripSnapshot(slots: [
            makeSlot(bundleID: "com.app.A"),
        ], lastUpdated: Date())
        let result = matchWindowToSlot(windowID: 42, bundleID: "com.app.A", title: nil,
                                       snapshot: snapshot, filledSlots: [0], now: Date())
        check(result == nil, "only candidate is filled → nil")
    }

    section("computeFilledSlots — no windows → empty")
    do {
        let slots = [makeSlot(bundleID: "com.app.A"), makeSlot(bundleID: "com.app.B")]
        let filled = computeFilledSlots(slots: slots, stripWindows: [])
        check(filled.isEmpty, "nothing to fill with")
    }

    section("matchSlotsToWindows — empty candidates → empty")
    do {
        let slots = [makeSlot(bundleID: "com.app.A")]
        let pairs = matchSlotsToWindows(slots: slots, candidates: [])
        check(pairs.isEmpty, "no candidates → no pairs")
    }
    // CGWindowListCopyWindowInfo read at activeSpaceDidChange time is not reliable:
    // observed returning nothing mid-transition, and twice a 14-window union
    // spanning four Spaces. A window lives on exactly one Space, so a read that
    // straddles two mutually disjoint known fingerprints cannot describe one.
    section("spansMultipleSpaces — rejects a cross-Space union, accepts real reads")
    do {
        let spaceA: Set<UInt32> = [64, 228, 9343, 128844]
        let spaceB: Set<UInt32> = [86, 90, 95]
        let spaceC: Set<UInt32> = [14808, 105792]

        check(!spansMultipleSpaces(onScreenIDs: spaceA, knownFingerprints: [spaceA, spaceB, spaceC]),
              "a real Space's own fingerprint is not suspect")
        check(!spansMultipleSpaces(onScreenIDs: [64, 228], knownFingerprints: [spaceA, spaceB]),
              "a subset of one Space (windows closed while away) is not suspect")
        check(!spansMultipleSpaces(onScreenIDs: [64, 228, 777], knownFingerprints: [spaceA, spaceB]),
              "one Space plus a brand-new window is not suspect")

        // The observed failure: windows from three Spaces at once.
        let union = spaceA.union(spaceB).union(spaceC)
        check(spansMultipleSpaces(onScreenIDs: union, knownFingerprints: [spaceA, spaceB, spaceC]),
              "a union across disjoint Spaces is rejected")
        check(spansMultipleSpaces(onScreenIDs: [64, 86], knownFingerprints: [spaceA, spaceB]),
              "even one window from each of two disjoint Spaces is enough")

        // Overlapping fingerprints are normal (fuzzy re-keying, windows moved
        // between Spaces) and must not be treated as evidence.
        let overlapping: Set<UInt32> = [228, 9343, 55555]
        check(!spansMultipleSpaces(onScreenIDs: spaceA, knownFingerprints: [spaceA, overlapping]),
              "overlapping fingerprints are not disjoint, so they prove nothing")

        // Degenerate inputs.
        check(!spansMultipleSpaces(onScreenIDs: [], knownFingerprints: [spaceA, spaceB]),
              "empty read is handled by the empty-read path, not this one")
        check(!spansMultipleSpaces(onScreenIDs: [64], knownFingerprints: [spaceA, spaceB]),
              "a single window can never span Spaces")
        check(!spansMultipleSpaces(onScreenIDs: union, knownFingerprints: [[], []]),
              "empty fingerprints carry no information")
        check(!spansMultipleSpaces(onScreenIDs: union, knownFingerprints: []),
              "no known Spaces yet (first switch after launch) — nothing to compare")
    }

}
