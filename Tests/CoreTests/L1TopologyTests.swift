import Foundation
import CoreGraphics
import Core
import Platform
import WindowManager

// Additional DisplayManager.alignmentGroups coverage.
//
// main.swift already covers: solo, flush merge (0.0 gap), partial Y-overlap
// merge, edge-touching zero-Y split, vertical stack split, 3-way transitive
// chain, 0.3px gap merge, 1.0px gap split, and member ordering by frame.minX.
// This file adds only genuinely-new cases: the tight ε boundary (0.4 / 0.5 / 0.6
// px), the empty-input edge, minimal (1px) Y-overlap merge, and multiple
// multi-member groups with group ordering. Reuses `makeDisplayInfo` from main.swift.

func runL1TopologyTests() {
    print()
    print("DisplayManager.alignmentGroups — boundary & multi-group Tests")

    section("empty display set — no groups")
    do {
        let groups = DisplayManager.alignmentGroups(from: [:])
        assertEq(groups.count, 0, "empty input → empty output")
    }

    section("X gap 0.4 px — merges (inside ε=0.5)")
    do {
        let displays: [CGDirectDisplayID: DisplayInfo] = [
            1: makeDisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
            2: makeDisplayInfo(id: 2, frame: CGRect(x: 1440.4, y: 0, width: 1920, height: 900)),
        ]
        let groups = DisplayManager.alignmentGroups(from: displays)
        assertEq(groups.count, 1, "0.4 px gap < ε tolerated")
        assertEq(groups[0].count, 2, "both merge")
    }

    section("X gap exactly 0.5 px — merges (ε boundary is inclusive)")
    do {
        let displays: [CGDirectDisplayID: DisplayInfo] = [
            1: makeDisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
            2: makeDisplayInfo(id: 2, frame: CGRect(x: 1440.5, y: 0, width: 1920, height: 900)),
        ]
        let groups = DisplayManager.alignmentGroups(from: displays)
        assertEq(groups.count, 1, "exactly ε=0.5 still merges (<=)")
    }

    section("X gap 0.6 px — splits (just past ε=0.5)")
    do {
        let displays: [CGDirectDisplayID: DisplayInfo] = [
            1: makeDisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
            2: makeDisplayInfo(id: 2, frame: CGRect(x: 1440.6, y: 0, width: 1920, height: 900)),
        ]
        let groups = DisplayManager.alignmentGroups(from: displays)
        assertEq(groups.count, 2, "0.6 px gap exceeds ε → independent strips")
    }

    section("minimal 1 px Y-overlap — merges (strict-< overlap boundary)")
    do {
        // A: y[0,900). B: y[899,1499). Overlap [899,900) = 1px → strict < holds → merge.
        let displays: [CGDirectDisplayID: DisplayInfo] = [
            1: makeDisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
            2: makeDisplayInfo(id: 2, frame: CGRect(x: 1440, y: 899, width: 1920, height: 600)),
        ]
        let groups = DisplayManager.alignmentGroups(from: displays)
        assertEq(groups.count, 1, "1px Y-overlap is enough to merge")
    }

    section("two independent multi-member groups — count, sizes, ordering")
    do {
        // Lower band (y=0): displays 1,2 flush → group. Upper band (y=1000, shifted
        // right in X so its leftmost differs): displays 3,4 flush → group. Bands don't
        // overlap in Y, so the two groups stay separate. Group order = leftmost minX.
        let displays: [CGDirectDisplayID: DisplayInfo] = [
            1: makeDisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
            2: makeDisplayInfo(id: 2, frame: CGRect(x: 1440, y: 0, width: 1440, height: 900)),
            3: makeDisplayInfo(id: 3, frame: CGRect(x: 200, y: 1000, width: 1440, height: 900)),
            4: makeDisplayInfo(id: 4, frame: CGRect(x: 1640, y: 1000, width: 1440, height: 900)),
        ]
        let groups = DisplayManager.alignmentGroups(from: displays)
        assertEq(groups.count, 2, "two separate bands → two groups")
        assertEq(groups[0], [1, 2], "lower band first (leftmost minX=0), members sorted")
        assertEq(groups[1], [3, 4], "upper band second (leftmost minX=200), members sorted")
    }

    // ── displayToGroup reconciliation ────────────────────────────────────────
    // The add step installs mappings for new groups; the remove step prunes dying
    // ones. Pruning unconditionally deletes the entries the add step just wrote,
    // so after any merge or split NO display resolves to its live controller.

    section("display map — merge keeps both displays routed to the merged group")
    do {
        let current: [CGDirectDisplayID: [CGDirectDisplayID]] = [1: [1], 2: [2]]
        let out = reconcileDisplayMap(current: current, added: [[1, 2]], removed: [[1], [2]])
        assertEq(out[1] ?? [], [1, 2], "display 1 routes to merged group")
        assertEq(out[2] ?? [], [1, 2], "display 2 routes to merged group")
    }

    section("display map — split routes each display to its own successor")
    do {
        let current: [CGDirectDisplayID: [CGDirectDisplayID]] = [1: [1, 2], 2: [1, 2]]
        let out = reconcileDisplayMap(current: current, added: [[1], [2]], removed: [[1, 2]])
        assertEq(out[1] ?? [], [1], "display 1 routes to its own group")
        assertEq(out[2] ?? [], [2], "display 2 routes to its own group")
    }

    section("display map — pure dissolve drops the unplugged display")
    do {
        let current: [CGDirectDisplayID: [CGDirectDisplayID]] = [1: [1], 2: [2]]
        let out = reconcileDisplayMap(current: current, added: [], removed: [[2]])
        assertEq(out[1] ?? [], [1], "surviving display keeps its group")
        check(out[2] == nil, "unplugged display is removed from the map")
    }
}
