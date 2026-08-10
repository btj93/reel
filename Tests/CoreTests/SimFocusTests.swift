import AppKit
import CoreGraphics
import Foundation
import Core
import Platform
import WindowManager

// ============================================================
// MARK: - W4a — Layer-2 layout & mutation (instant mode)
//
// Real StripController + fakes, single-threaded virtual clock, inline dispatch.
// Asserts activeColumnIndex + the *fake window's* committed frame, so both the
// model and the applied-to-window side are checked.
// ============================================================

func runSimFocus() {
    print()
    print("StripController Simulation — focus / mutation (W4a)")

    // Core guards `!columns.isEmpty` and returns, but the controller then indexes
    // columnData[activeColumnIndex] regardless — a trap on an empty strip, which
    // the cycle-width hotkey and `reel-msg cycle-width-preset` both reach.
    section("width preset actions on an empty strip do not crash")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC(animationEnabled: true)
        assertEq(sc.strip.columns.count, 0, "strip starts empty")
        sc.cycleWidthPreset()
        sc.setWidthPreset(index: 0)
        sc.toggleFullWidth()
        assertEq(sc.strip.columns.count, 0, "still empty, no trap")
        _ = clock
    }

    // The pill menu builds its items for the fn-clicked column but applied them to
    // the ACTIVE column, so clicking a non-active column mutated the wrong window.
    section("width preset applies to the targeted column, not the active one")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        addFakeWindows(sc, count: 3, width: 700)
        sc.strip.activeColumnIndex = 0
        sc.setWidthPreset(index: 2, column: 2)
        assertEq(sc.strip.columns[2].presetIndex, 2, "targeted column got the preset")
        assertEq(sc.strip.columns[0].presetIndex, nil, "active column untouched")
        assertEq(sc.strip.activeColumnIndex, 0, "a query-then-mutate menu must not steal focus")
        _ = clock
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    section("toggleFullWidth applies to the targeted column, not the active one")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        addFakeWindows(sc, count: 3, width: 700)
        sc.strip.activeColumnIndex = 0
        sc.toggleFullWidth(column: 2)
        check(sc.strip.columns[2].isFullWidth, "targeted column went full-width")
        check(!sc.strip.columns[0].isFullWidth, "active column untouched")
        assertEq(sc.strip.activeColumnIndex, 0, "focus unchanged")
        _ = clock
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // Column X is derived from cumulative widths, so resizing a column LEFT of the
    // active one shifts the active column's strip-space X. Without a re-pin the
    // focused window visibly slides even though nothing about it changed.
    section("resizing a column left of the active one keeps the active column pinned")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        let (_, wins) = addFakeWindows(sc, count: 3, width: 700)
        sc.strip.activeColumnIndex = 2
        sc.strip.viewOffset = .static(sc.strip.snapTargetForActive(at: clock.t))
        sc.applyLayout()
        let activeBefore = wins[2].currentFrame

        sc.setWidthPreset(index: 0, column: 0)   // shrink a column to the LEFT

        assertClose(Double(wins[2].currentFrame.minX), Double(activeBefore.minX), tolerance: 2,
            "active column stays put when a left-side column resizes")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- focus left / right ----
    section("focus left/right — activeColumnIndex + centered fake frame")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        let (_, ws) = addFakeWindows(sc, count: 2, width: 700)
        // Two adds → col1 (w2) is active. Focus left onto col0.
        sc.focusLeft()
        assertEq(sc.strip.activeColumnIndex, 0, "focusLeft → col 0")
        assertClose(Double(ws[0].currentFrame.midX), 720, tolerance: 2, "col 0 centered on 1440 wa")
        check(ws[0].focusCount >= 1, "focusActiveWindow raised keyboard focus")
        sc.focusRight()
        assertEq(sc.strip.activeColumnIndex, 1, "focusRight → col 1")
        assertClose(Double(ws[1].currentFrame.midX), 720, tolerance: 2, "col 1 centered")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- move column ----
    section("moveColumnLeft — order swap + derived X")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        let (_, _) = addFakeWindows(sc, count: 3, width: 700)
        // active is col2 (last inserted)
        let before = sc.strip.columns.map { $0.tiles[0] }
        sc.moveColumnLeft()
        assertEq(sc.strip.activeColumnIndex, 1, "moved column now at index 1")
        let after = sc.strip.columns.map { $0.tiles[0] }
        assertEq(after[1], before[2], "moved tile landed at index 1")
        assertEq(after[2], before[1], "displaced neighbor at index 2")
        assertClose(sc.strip.columnX(at: 1), 716, tolerance: 0.5, "derived X = width+gap")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- width preset ----
    section("setWidthPreset — cachedWidth + fake width reflect preset")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        let (_, ws) = addFakeWindows(sc, count: 1, width: 700)
        sc.setWidthPreset(index: 0)  // default presets: [.33, .5, .67] → 0.33 * 1440
        let target = 0.33 * 1440.0
        assertClose(sc.strip.columnData[0].cachedWidth, target, tolerance: 1, "cachedWidth = preset")
        assertClose(Double(ws[0].currentFrame.width), target, tolerance: 1.5, "fake width = preset")
        assertEq(sc.strip.columns[0].presetIndex ?? -1, 0, "presetIndex recorded")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    section("toggleFullWidth — fake fills working area, then reverts")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        let (_, ws) = addFakeWindows(sc, count: 1, width: 700)
        sc.toggleFullWidth()
        check(sc.strip.columns[0].isFullWidth, "isFullWidth on")
        assertClose(sc.strip.columnData[0].cachedWidth, 1440, tolerance: 1, "cachedWidth = wa width")
        assertClose(Double(ws[0].currentFrame.width), 1440, tolerance: 1.5, "fake fills width")
        sc.toggleFullWidth()
        check(!sc.strip.columns[0].isFullWidth, "isFullWidth off")
        assertClose(Double(ws[0].currentFrame.width), 700, tolerance: 1.5, "fake reverts to fixed width")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- floating roundtrip ----
    section("toggleFloating / unfloatWindow roundtrip")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        let (app, ws) = addFakeWindows(sc, count: 2, width: 700)
        let w1 = ws[1]  // active col 1
        let toggled = sc.toggleFloating()
        check(toggled === w1, "returns the floated window")
        assertEq(sc.strip.columns.count, 1, "strip compacts after float")
        check(sc.windowMap[w1.tileID] == nil, "floated window untracked")
        sc.unfloatWindow(w1, app: app)
        assertEq(sc.strip.columns.count, 2, "unfloat restores column")
        check(sc.windowMap[w1.tileID] != nil, "tracked again after unfloat")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- close-window path ----
    section("close-window — AX close, then removeWindow compacts + neighbor active")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        let (_, ws) = addFakeWindows(sc, count: 3, width: 700)
        sc.strip.activeColumnIndex = 1
        let w1 = ws[1]
        sc.closeActiveWindow()
        check(w1.closed, "AX close button pressed")
        assertEq(sc.strip.columns.count, 3, "closeActiveWindow leaves removal to observer")
        // Simulate the destroyed-notification / health-check removal.
        sc.removeWindow(tileID: w1.tileID)
        assertEq(sc.strip.columns.count, 2, "removeWindow compacts strip")
        check(sc.windowMap[w1.tileID] == nil, "removed window untracked")
        assertEq(sc.strip.activeColumnIndex, 1, "right neighbor becomes active")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- off-screen sliver ----
    section("off-screen column slivered at right edge")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        let (_, ws) = addFakeWindows(sc, count: 3, width: 720)
        sc.strip.activeColumnIndex = 0
        sc.strip.viewOffset = .static(0)
        sc.clearCommittedFrames()
        sc.applyLayout()
        // 3×720 cols, gap 16, offset 0: col2 stripX 1472 → fully off right → 1px sliver.
        assertClose(Double(ws[2].currentFrame.minX), 1439, tolerance: 1.5, "sliver 1px at right edge")
        assertEq(sc.debugDirtyCount, 0, "cooperative sliver write succeeds")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    section("off-screen resistant app — write stays dirty (NO corner-hide fallback)")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        let (_, ws) = addFakeWindows(sc, count: 3, width: 720)
        ws[2].resistsOffscreen = true
        sc.strip.activeColumnIndex = 0
        sc.strip.viewOffset = .static(0)
        sc.clearCommittedFrames()
        sc.applyLayout()
        // The off-screen (position-only) sliver write for col2 fails → tile dirty.
        assertEq(sc.debugDirtyCount, 1, "resistant off-screen write fails → dirty")
        // TODO(prod-finding): CLAUDE.md documents a corner-hide (-10000,-10000)
        // fallback for resistant apps, but StripController has NO such fallback.
        // The write simply re-dispatches the same sliver each layout and keeps
        // failing. Asserting the CURRENT behavior; reported to the caller.
        sc.applyLayout()
        assertEq(sc.debugDirtyCount, 1, "still dirty on retry — no corner-hide fallback exists")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- transient failure → dirty retry ----
    section("failNextSet → dirtyTileIDs retry re-applies on next layout")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        let (_, ws) = addFakeWindows(sc, count: 2, width: 700)
        let w0 = ws[0]
        sc.strip.activeColumnIndex = 0
        sc.strip.viewOffset = .static(-50)  // col0 → screenX 50
        sc.clearCommittedFrames()
        let priorFrame = w0.currentFrame
        w0.failNextSet = true
        sc.applyLayout()
        assertEq(sc.debugDirtyCount, 1, "failed set marks exactly the one tile dirty")
        assertEq(w0.currentFrame, priorFrame, "failed set left the fake untouched")
        // Retry: dirty bypass re-dispatches even though target == last committed.
        sc.applyLayout()
        assertEq(sc.debugDirtyCount, 0, "retry cleared dirty")
        assertClose(Double(w0.currentFrame.minX), 50, tolerance: 1.5, "retry applied the frame")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- coalescing / supersede ----
    section("coalesced writes — one drain in flight, latest frame wins")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        let (_, ws) = addFakeWindows(sc, count: 1, width: 700)
        let w = ws[0]
        // Capturing executor: enqueue but DON'T run the drain block.
        let cap = Capture()
        sc.frameDispatch = { _, work in cap.blocks.append(work) }
        sc.mainHop = { $0() }
        // Three superseding frames for the same tile without draining.
        sc.strip.activeColumnIndex = 0
        sc.strip.viewOffset = .static(-100); sc.applyLayout()  // screenX 100
        sc.strip.viewOffset = .static(-200); sc.applyLayout()  // screenX 200
        sc.strip.viewOffset = .static(-300); sc.applyLayout()  // screenX 300
        assertEq(cap.blocks.count, 1, "only ONE drain block in flight for the tile")
        let logBefore = w.frameLog.count
        cap.run(0)
        assertEq(w.frameLog.count - logBefore, 1, "drain applies exactly one frame")
        assertClose(Double(w.currentFrame.minX), 300, tolerance: 1.5, "only the LATEST frame landed")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    runHotkeyTableTests()
}

// ============================================================
// MARK: - HotkeyManager table tests (parseKeyString + matchBinding)
// ============================================================

func runHotkeyTableTests() {
    print()
    print("HotkeyManager — parseKeyString / matchBinding table")

    let hk = HotkeyManager()

    section("parseKeyString — modifier tokens")
    do {
        // "alt-h" → alt + h(0x04)
        if let (m, k) = hk.parseKeyString("alt-h") {
            check(m == .maskAlternate, "alt only")
            assertEq(k, 0x04, "h keycode")
        } else { check(false, "alt-h should parse") }

        // "alt-shift-h" → alt+shift
        if let (m, k) = hk.parseKeyString("alt-shift-h") {
            check(m == [.maskAlternate, .maskShift], "alt+shift")
            assertEq(k, 0x04, "h keycode")
        } else { check(false, "alt-shift-h should parse") }

        // "hyper-h" → all four modifiers
        if let (m, _) = hk.parseKeyString("hyper-h") {
            check(m == [.maskControl, .maskShift, .maskCommand, .maskAlternate], "hyper = 4 mods")
        } else { check(false, "hyper-h should parse") }

        // "super-h" and "mod-h" → command (niri names)
        if let (m, _) = hk.parseKeyString("super-h") {
            check(m == .maskCommand, "super = cmd")
        } else { check(false, "super-h should parse") }
        if let (m, _) = hk.parseKeyString("mod-h") {
            check(m == .maskCommand, "mod = cmd")
        } else { check(false, "mod-h should parse") }

        // typo "atl-h" → nil (unknown modifier invalidates)
        check(hk.parseKeyString("atl-h") == nil, "unknown modifier → nil (no bare-key grab)")

        // bare "h" → nil (needs at least one modifier)
        check(hk.parseKeyString("h") == nil, "bare key → nil")

        // "alt--" → alt + minus(0x1B)
        if let (m, k) = hk.parseKeyString("alt--") {
            check(m == .maskAlternate, "alt + '-' modifier")
            assertEq(k, 0x1B, "minus keycode")
        } else { check(false, "alt-- should parse the '-' key") }
    }

    section("matchBinding — exact-equality precedence")
    do {
        let mgr = HotkeyManager()
        mgr.registerFromConfig(["focus_left": "alt-h", "move_left": "alt-shift-h"])

        // [.alt] fires the focus binding
        if case .focusLeft? = mgr.matchBinding(keyCode: 0x04, flags: .maskAlternate) {
            check(true, "alt-h → focusLeft")
        } else { check(false, "alt fires focusLeft") }

        // [.alt,.shift] fires the shift binding, not the alt one
        if case .moveColumnLeft? = mgr.matchBinding(keyCode: 0x04, flags: [.maskAlternate, .maskShift]) {
            check(true, "alt-shift-h → moveColumnLeft")
        } else { check(false, "alt+shift fires the shift binding (not focusLeft)") }

        // [.cmd,.alt] matches nothing (superset never steals plain alt binding)
        check(mgr.matchBinding(keyCode: 0x04, flags: [.maskCommand, .maskAlternate]) == nil,
              "cmd+alt matches no binding")

        // caps-lock flag (alphaShift) is outside relevantModifiers → doesn't break the match
        if case .focusLeft? = mgr.matchBinding(keyCode: 0x04, flags: [.maskAlternate, .maskAlphaShift]) {
            check(true, "caps-lock flag ignored → alt still fires focusLeft")
        } else { check(false, "caps-lock must not break an alt binding") }
    }
}
