import Foundation
import CoreGraphics
import Core

// L1 audit-gap backfill.
//
// Regression for finding #0 (Strip.regionForColumn mixed width bases) plus
// coverage gaps flagged by the audit: SwipeTracker.projectedEndPosition and the
// velocity(at:) staleness gate, the rubber-band bounce trajectory, ColumnWidth
// .resolve() .fixed clamp / .auto branch, and SpringAnimation.retargeted velocity
// preservation. Reuses the module-global helpers (check/assertEq/assertClose/
// section/makeStrip) defined in main.swift.

func runL1AuditGapTests() {
    print()
    print("L1 Audit-Gap Tests")

    // MARK: - #0 Strip.regionForColumn width-basis regression

    // On a merged two-monitor strip, cycling a preset on a column LEFT of the
    // active one starts a width spring whose animated `currentWidth` transiently
    // differs from `cachedWidth` by hundreds of px. `regionForColumn` must select
    // the region from the SETTLED (cached) geometry, not the animated basis —
    // otherwise the active column's scroll target resolves against the wrong
    // monitor and it stays mis-centered until the next explicit navigation.
    section("regionForColumn — settled region stable during left-column width animation")
    do {
        let r0 = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let r1 = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let ga = GroupWorkingArea(
            regions: [DisplayRegion(displayID: 1, rect: r0),
                      DisplayRegion(displayID: 2, rect: r1)],
            referenceMidX: r0.midX
        )
        var strip = Strip(groupArea: ga)
        // Left column mid-animation: currentWidth 700 while its settled width is 300
        // (+400px delta on the animated columnX basis).
        let params = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)
        let leftAnim = SpringAnimation(from: 700, to: 300, startTime: 0, params: params)
        strip.columns = [
            Column(tiles: [TileID(1)], width: .proportion(0.3)),
            Column(tiles: [TileID(2)], width: .proportion(0.3)),
            Column(tiles: [TileID(3)], width: .proportion(0.3)),
        ]
        strip.columnData = [
            ColumnData(cachedWidth: 300, widthAnimation: leftAnim),
            ColumnData(cachedWidth: 300),
            ColumnData(cachedWidth: 300),
        ]
        strip.snapIndices = [0, 0, 0]
        strip.activeColumnIndex = 2
        strip.viewOffset = .static(-1000)

        // Precondition: the animated width basis really is shifted at t=0.
        assertClose(strip.columnData[0].currentWidth(at: 0), 700, tolerance: 1.0,
                    "left column mid-animation width")
        assertClose(strip.columnData[0].cachedWidth, 300, tolerance: 0.01,
                    "left column settled width")

        // cachedColumnX(active=2) = 632; midXInStrip = 782; cached viewPos = 632-1000 = -368
        // → midXOnScreen = 782 + 368 = 1150 → region 1 (displayID 2). The mixed-basis
        // bug used animated viewPos (32) → midXOnScreen 750 → region 0 (displayID 1).
        assertEq(strip.regionForColumn(2, at: 0).displayID, UInt32(2),
                 "active column resolves to its settled region during the animation")
        // Region assignment is identical after the width animation settles.
        assertEq(strip.regionForColumn(2, at: 5.0).displayID, UInt32(2),
                 "region unchanged once the width spring settles")
    }

    section("regionForColumn — solo group ignores width animation (single-display unchanged)")
    do {
        var strip = makeStrip(columnCount: 3)
        let params = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)
        strip.columnData[0].widthAnimation = SpringAnimation(
            from: 1400, to: strip.columnData[0].cachedWidth, startTime: 0, params: params)
        strip.activeColumnIndex = 2
        strip.viewOffset = .static(-500)
        let sole = strip.groupArea.regions[0].displayID
        assertEq(strip.regionForColumn(2, at: 0).displayID, sole,
                 "solo group always returns its sole region during animation")
        assertEq(strip.regionForColumn(2, at: 5.0).displayID, sole,
                 "solo group region stable after settle")
    }

    // MARK: - #38 SwipeTracker velocity staleness + projectedEndPosition

    section("SwipeTracker.velocity — empty / single sample → 0")
    do {
        var t = SwipeTracker()
        check(t.velocity() == 0, "empty tracker → 0")
        t.push(delta: 50, timestamp: 0)
        check(t.velocity() == 0, "single sample → 0 (needs >= 2)")
    }

    section("SwipeTracker.velocity(at:) — stale samples suppressed on lift-off")
    do {
        var t = SwipeTracker()
        for i in 0..<5 { t.push(delta: 50, timestamp: Double(i) * 0.01) }  // last at t=0.04
        check(t.velocity(at: 0.04) > 0, "fresh lift-off → non-zero velocity")
        check(t.velocity(at: 0.20) == 0, "finger paused > 50ms before lift-off → 0")
        check(t.velocity() > 0, "no-time form has no staleness gate → non-zero")
    }

    section("SwipeTracker.projectedEndPosition — momentum carries in velocity direction")
    do {
        var fwd = SwipeTracker()
        for i in 0..<5 { fwd.push(delta: 50, timestamp: Double(i) * 0.01) }
        check(fwd.velocity() > 0, "forward flick → positive velocity")
        check(fwd.projectedEndPosition(isTouchpad: true) > fwd.position,
              "touchpad momentum overshoots forward")
        check(fwd.projectedEndPosition(isTouchpad: false) > fwd.position,
              "mouse momentum overshoots forward")

        var back = SwipeTracker()
        for i in 0..<5 { back.push(delta: -50, timestamp: Double(i) * 0.01) }
        check(back.velocity() < 0, "backward flick → negative velocity")
        check(back.projectedEndPosition(isTouchpad: true) < back.position,
              "negative momentum coasts backward (log-decel sign correct)")
    }

    // MARK: - #39 Rubber-band bounce trajectory

    section("createRubberBandAnimation — overshoots the edge then returns to snap")
    do {
        var strip = makeStrip(columnCount: 1)
        let target = strip.snapTargetForActive(at: 0)
        strip.viewOffset = .static(target)  // start exactly on the canonical snap
        let anim = strip.createRubberBandAnimation(direction: 1, at: 0)
        assertClose(anim.to, target, tolerance: 0.5, "targets the canonical snap")
        let start = anim.evaluate(at: 0).value
        assertClose(start, target, tolerance: 0.5, "starts at the edge")
        var maxV = start
        for i in 1...60 { maxV = max(maxV, anim.evaluate(at: Double(i) * 0.01).value) }
        check(maxV > start + 5, "overshoots past the edge (underdamped bounce), peak \(maxV)")
        assertClose(anim.evaluate(at: 3.0).value, target, tolerance: 1.0,
                    "settles back on the snap target")
    }

    section("createRubberBandAnimation — targets canonical snap, not a drifted currentPos")
    do {
        var strip = makeStrip(columnCount: 1)
        let snap = strip.snapTargetForActive(at: 0)
        strip.viewOffset = .static(snap + 37)  // drifted off-snap (interrupted animation)
        let anim = strip.createRubberBandAnimation(direction: -1, at: 0)
        assertClose(anim.from, snap + 37, tolerance: 0.5, "bounce starts from the drifted position")
        assertClose(anim.to, snap, tolerance: 0.5, "bounce targets canonical snap, not currentPos")
    }

    // MARK: - #40 ColumnWidth.resolve() .fixed clamp + .auto

    section("ColumnWidth.resolve — .fixed clamps to working area")
    do {
        assertClose(ColumnWidth.fixed(2000).resolve(workingAreaWidth: 1440, gap: 16), 1440,
                    tolerance: 0.01, "fixed wider than screen clamps down")
        assertClose(ColumnWidth.fixed(800).resolve(workingAreaWidth: 1440, gap: 16), 800,
                    tolerance: 0.01, "fixed under screen unchanged")
        assertClose(ColumnWidth.fixed(1440).resolve(workingAreaWidth: 1440, gap: 16), 1440,
                    tolerance: 0.01, "fixed exactly at working area")
    }

    section("ColumnWidth.resolve — .auto is half the working area")
    do {
        assertClose(ColumnWidth.auto.resolve(workingAreaWidth: 1440, gap: 16), 720,
                    tolerance: 0.01, "auto = 0.5 × working area")
        assertClose(ColumnWidth.auto.resolve(workingAreaWidth: 2000, gap: 0), 1000,
                    tolerance: 0.01, "auto scales with working area")
    }

    // MARK: - #41 SpringAnimation.retargeted velocity preservation

    section("SpringAnimation.retargeted — preserves in-flight velocity")
    do {
        let anim = SpringAnimation(from: 0, to: 500, initialVelocity: 0, startTime: 0,
                                   params: .horizontalScroll)
        let (midVal, midVel) = anim.evaluate(at: 0.1)
        check(midVal > 0 && midVal < 500, "mid-flight value in range: \(midVal)")
        check(midVel != 0, "in-flight velocity is non-zero: \(midVel)")
        let retargeted = anim.retargeted(to: 1000, at: 0.1)
        assertClose(retargeted.from, midVal, tolerance: 0.01, "retarget starts from current value")
        assertClose(retargeted.initialVelocity, midVel, tolerance: 0.01,
                    "retarget preserves in-flight velocity")
        assertEq(retargeted.to, 1000.0, "new target")
        assertClose(retargeted.startTime, 0.1, tolerance: 1e-9, "startTime is the retarget instant")
        // Continuity: the retargeted spring reproduces (value, velocity) at the retarget instant.
        let (rVal0, rVel0) = retargeted.evaluate(at: 0.1)
        assertClose(rVal0, midVal, tolerance: 0.01, "value continuous across retarget")
        assertClose(rVel0, midVel, tolerance: 0.01, "velocity continuous across retarget")
    }

    section("SpringAnimation.retargeted — velocity carried across all three damping regimes")
    do {
        // Ratios straddle the critical boundary (1.0): underdamped / critical / overdamped.
        let regimes: [(String, SpringParams)] = [
            ("underdamped", SpringParams(dampingRatio: 0.9, stiffness: 800, epsilon: 0.5)),
            ("critical", SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)),
            ("overdamped", SpringParams(dampingRatio: 1.1, stiffness: 800, epsilon: 0.5)),
        ]
        for (name, params) in regimes {
            let anim = SpringAnimation(from: 0, to: 400, initialVelocity: 0, startTime: 0, params: params)
            let (midVal, midVel) = anim.evaluate(at: 0.08)
            let re = anim.retargeted(to: 900, at: 0.08)
            assertClose(re.initialVelocity, midVel, tolerance: 1e-9, "\(name): velocity preserved")
            let (rVal, rVel) = re.evaluate(at: 0.08)
            assertClose(rVal, midVal, tolerance: 1e-9, "\(name): value continuous")
            assertClose(rVel, midVel, tolerance: 1e-9, "\(name): velocity continuous")
            assertClose(re.evaluate(at: 5.0).value, 900, tolerance: 1.0, "\(name): converges to new target")
        }
    }
}
