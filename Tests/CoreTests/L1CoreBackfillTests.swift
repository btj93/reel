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
}
