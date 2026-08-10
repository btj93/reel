import Foundation
import CoreGraphics
import Core
import Platform

// DisplayManager.groupWorkingArea coverage (W10 — pure working-area math).
//
// Reuses `makeDisplayInfo(id:frame:)` from main.swift, which sets
// `visibleFrame == frame` and `isMain == (id == 1)`. Because visibleFrame ==
// frame, a display's struts-free working area (top-left CG coords) is:
//   x = frame.minX
//   y = primaryScreenHeight - frame.maxY   (bottom-left AppKit → top-left CG)
//   width = frame.width
//   height = frame.height
// All test frames below use `y == 0` at the primary height chosen per-case so
// the CG conversion stays easy to reason about.

func runL1GroupAreaTests() {
    print()
    print("DisplayManager.groupWorkingArea Tests")

    // A single primary display at (0,0,1440,900), primaryScreenHeight=900.
    // CG y = 900 - 900 = 0. Working area == frame.
    section("single display — one region, referenceMidX = its midX")
    do {
        let displays: [CGDirectDisplayID: DisplayInfo] = [
            1: makeDisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        ]
        let ga = DisplayManager.groupWorkingArea(
            members: [1], displays: displays, mainDisplayID: 1,
            struts: .zero, primaryScreenHeight: 900)
        assertEq(ga.regions.count, 1, "one region")
        assertEq(ga.regions[0].displayID, UInt32(1), "region carries display id")
        assertClose(Double(ga.regions[0].rect.minX), 0, tolerance: 0.01, "region x")
        assertClose(Double(ga.regions[0].rect.width), 1440, tolerance: 0.01, "region width")
        assertClose(Double(ga.referenceMidX), 720, tolerance: 0.01, "midX of the sole display")
    }

    // Two flush displays 1 (main, left) + 2 (right). Members passed OUT OF
    // ORDER to prove the function sorts regions by frame.minX.
    section("merged multi-display — regions sorted by X regardless of input order")
    do {
        let displays: [CGDirectDisplayID: DisplayInfo] = [
            1: makeDisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
            2: makeDisplayInfo(id: 2, frame: CGRect(x: 1440, y: 0, width: 2560, height: 900)),
        ]
        // Deliberately reversed input order.
        let ga = DisplayManager.groupWorkingArea(
            members: [2, 1], displays: displays, mainDisplayID: 1,
            struts: .zero, primaryScreenHeight: 900)
        assertEq(ga.regions.count, 2, "two regions")
        assertEq(ga.regions[0].displayID, UInt32(1), "leftmost region first (display 1)")
        assertEq(ga.regions[1].displayID, UInt32(2), "rightmost region second (display 2)")
        assertClose(Double(ga.regions[0].rect.minX), 0, tolerance: 0.01, "region 0 x")
        assertClose(Double(ga.regions[1].rect.minX), 1440, tolerance: 0.01, "region 1 x")
        // totalSpan spans both displays.
        assertClose(Double(ga.totalSpan.width), 1440 + 2560, tolerance: 0.01, "span covers both")
    }

    // referenceMidX = main display's midX when main is a member. Main (id 1) is
    // the RIGHT display here; leftmost is id 2. referenceMidX must still be the
    // main's midX, not the leftmost's.
    section("referenceMidX = main display midX when main is a member (even if not leftmost)")
    do {
        let displays: [CGDirectDisplayID: DisplayInfo] = [
            2: makeDisplayInfo(id: 2, frame: CGRect(x: 0, y: 0, width: 1000, height: 900)),
            1: makeDisplayInfo(id: 1, frame: CGRect(x: 1000, y: 0, width: 1440, height: 900)),
        ]
        let ga = DisplayManager.groupWorkingArea(
            members: [1, 2], displays: displays, mainDisplayID: 1,
            struts: .zero, primaryScreenHeight: 900)
        assertEq(ga.regions[0].displayID, UInt32(2), "leftmost is display 2")
        // main (1) working area: x=1000, width=1440 → midX = 1000 + 720 = 1720.
        assertClose(Double(ga.referenceMidX), 1720, tolerance: 0.01, "main's midX, not leftmost's")
    }

    // referenceMidX falls back to leftmost region's midX when main is NOT a
    // member of this group (e.g. a secondary strip on a non-main display group).
    section("referenceMidX falls back to leftmost region midX when main absent")
    do {
        let displays: [CGDirectDisplayID: DisplayInfo] = [
            3: makeDisplayInfo(id: 3, frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            4: makeDisplayInfo(id: 4, frame: CGRect(x: 800, y: 0, width: 1200, height: 600)),
        ]
        // Main display is id 1, which is not in this group.
        let ga = DisplayManager.groupWorkingArea(
            members: [4, 3], displays: displays, mainDisplayID: 1,
            struts: .zero, primaryScreenHeight: 600)
        assertEq(ga.regions[0].displayID, UInt32(3), "leftmost is display 3")
        // leftmost (3) working area: x=0, width=800 → midX = 400.
        assertClose(Double(ga.referenceMidX), 400, tolerance: 0.01, "leftmost region midX")
    }

    // nil mainDisplayID → same leftmost fallback (guards the optional-unwrap path).
    section("referenceMidX falls back to leftmost when mainDisplayID is nil")
    do {
        let displays: [CGDirectDisplayID: DisplayInfo] = [
            1: makeDisplayInfo(id: 1, frame: CGRect(x: 200, y: 0, width: 600, height: 900)),
        ]
        let ga = DisplayManager.groupWorkingArea(
            members: [1], displays: displays, mainDisplayID: nil,
            struts: .zero, primaryScreenHeight: 900)
        // x=200, width=600 → midX = 500.
        assertClose(Double(ga.referenceMidX), 500, tolerance: 0.01, "leftmost midX with nil main")
    }

    // Struts shrink the working area (SketchyBar-style insets). left/right shave
    // width and shift x; top/bottom shave height and shift y.
    section("struts shrink the working area and shift origin")
    do {
        let displays: [CGDirectDisplayID: DisplayInfo] = [
            1: makeDisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        ]
        let struts = Struts(left: 10, right: 20, top: 30, bottom: 40)
        let ga = DisplayManager.groupWorkingArea(
            members: [1], displays: displays, mainDisplayID: 1,
            struts: struts, primaryScreenHeight: 900)
        let r = ga.regions[0].rect
        // x = 0 + left(10) = 10
        assertClose(Double(r.minX), 10, tolerance: 0.01, "x += left strut")
        // width = 1440 - left(10) - right(20) = 1410
        assertClose(Double(r.width), 1410, tolerance: 0.01, "width -= left+right")
        // cgY = 900 - visibleFrame.maxY(900) = 0; y = 0 + top(30) = 30
        assertClose(Double(r.minY), 30, tolerance: 0.01, "y = cgY + top strut")
        // height = 900 - top(30) - bottom(40) = 830
        assertClose(Double(r.height), 830, tolerance: 0.01, "height -= top+bottom")
        // referenceMidX picks up struts too: 10 + 1410/2 = 715
        assertClose(Double(ga.referenceMidX), 715, tolerance: 0.01, "referenceMidX reflects struts")
    }

    // Struts are capped per-side at 512 by the config parser, but two opposing
    // 512s still exceed the usable height of a 1440x900 panel. Subtracting them
    // unclamped inverts the rect: negative height, and an origin past the display.
    section("oversized struts stay inside the display")
    do {
        let displays: [CGDirectDisplayID: DisplayInfo] = [
            1: makeDisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        ]
        let ga = DisplayManager.groupWorkingArea(
            members: [1], displays: displays, mainDisplayID: 1,
            struts: Struts(left: 0, right: 0, top: 512, bottom: 512),
            primaryScreenHeight: 900)
        let r = ga.regions[0].rect
        // Assert on `size`, NOT `.width`/`.height`: CGRect's accessors standardize,
        // so a rect built with size.height = -124 reports height == 124 and would
        // hide the inversion entirely.
        check(r.size.height >= 0, "height not inverted (got size.height=\(r.size.height))")
        check(r.size.width >= 0, "width not inverted (got size.width=\(r.size.width))")
        check(r.origin.y >= 0 && r.origin.y + r.size.height <= 900,
            "stays within display vertically (origin.y=\(r.origin.y) h=\(r.size.height))")
    }

    // Same inversion on the horizontal axis needs a narrow panel, since the 512
    // per-side cap cannot exceed a 1440-wide display on its own.
    section("oversized horizontal struts do not invert a narrow display")
    do {
        let displays: [CGDirectDisplayID: DisplayInfo] = [
            1: makeDisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        ]
        let ga = DisplayManager.groupWorkingArea(
            members: [1], displays: displays, mainDisplayID: 1,
            struts: Struts(left: 512, right: 512, top: 0, bottom: 0),
            primaryScreenHeight: 600)
        let r = ga.regions[0].rect
        check(r.size.width >= 0, "width not inverted (got size.width=\(r.size.width))")
        check(r.origin.x >= 0 && r.origin.x + r.size.width <= 800,
            "stays within display horizontally (origin.x=\(r.origin.x) w=\(r.size.width))")
    }

    // A three-display transitive chain, members shuffled, confirms full
    // left-to-right ordering (not just a swap of two).
    section("three-display chain — full ordering by X")
    do {
        let displays: [CGDirectDisplayID: DisplayInfo] = [
            1: makeDisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 900)),
            2: makeDisplayInfo(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 900)),
            3: makeDisplayInfo(id: 3, frame: CGRect(x: 2000, y: 0, width: 1000, height: 900)),
        ]
        let ga = DisplayManager.groupWorkingArea(
            members: [3, 1, 2], displays: displays, mainDisplayID: 1,
            struts: .zero, primaryScreenHeight: 900)
        assertEq(ga.regions.map { $0.displayID }, [UInt32(1), UInt32(2), UInt32(3)], "ordered L→R")
        assertClose(Double(ga.referenceMidX), 500, tolerance: 0.01, "main (1) midX")
    }
}
