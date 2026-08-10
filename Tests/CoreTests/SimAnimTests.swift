import AppKit
import CoreGraphics
import Foundation
import Core
import Config
import Platform
import WindowManager

// ============================================================
// MARK: - W4b — Layer-2 animation, gestures, pause-freeze
//
// Virtual-clock convergence via settle(). No wall clock, no frame loop (nil);
// every animation is advanced by hand through handleFrameTick.
// ============================================================

func runSimAnim() {
    print()
    print("StripController Simulation — animation & gestures (W4b)")

    // ---- animated focus convergence (60Hz) ----
    section("focusLeftAnimated converges onto centered fake frame (60Hz)")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC(animationEnabled: true)
        let (_, ws) = addFakeWindows(sc, count: 2, width: 700)
        assertEq(sc.strip.activeColumnIndex, 1, "two adds → col 1 active")
        sc.focusLeftAnimated(velocity: 0)
        guard case .animation = sc.strip.viewOffset else {
            check(false, "focusLeftAnimated should start a scroll animation"); return
        }
        settle(sc, clock)
        check(sc.isFullySettled, "spring settled")
        assertEq(sc.strip.activeColumnIndex, 0, "focused col 0")
        assertClose(Double(ws[0].currentFrame.midX), 720, tolerance: 2, "col 0 centered after animation")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    section("focusLeftAnimated convergence — 120Hz precision variant")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC(animationEnabled: true)
        let (_, ws) = addFakeWindows(sc, count: 2, width: 700)
        sc.focusLeftAnimated(velocity: 0)
        settle(sc, clock, hz: 120)
        check(sc.isFullySettled, "settled at 120Hz")
        assertEq(sc.strip.activeColumnIndex, 0, "focused col 0")
        assertClose(Double(ws[0].currentFrame.midX), 720, tolerance: 1, "tight centering at 120Hz")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- gesture begin / update ----
    section("gesture begin → .gesture state; updates accumulate + clamp to bounds")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC(animationEnabled: true)
        addFakeWindows(sc, count: 3, width: 700)
        sc.strip.activeColumnIndex = 1
        sc.strip.viewOffset = .static(sc.strip.snapTargetForActive(at: clock.t))
        sc.applyLayout()
        let begin = sc.strip.viewOffset.current(at: clock.t)
        sc.handleGestureBegin(time: clock.t)
        guard case .gesture = sc.strip.viewOffset else { check(false, "gesture state entered"); return }
        for _ in 0..<3 { sc.handleGestureUpdate(deltaX: -30, time: clock.t) }
        if case .gesture(let st) = sc.strip.viewOffset {
            assertClose(st.currentOffset, begin - 90, tolerance: 1, "3×(-30) deltas accumulate")
            let bounds = sc.strip.viewOffsetBounds(at: clock.t)
            check(st.currentOffset >= bounds.lowerBound && st.currentOffset <= bounds.upperBound, "within bounds")
        } else { check(false, "still gesturing after updates") }
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- free-scroll momentum ----
    section("gesture momentum (free-scroll) converges to projected viewPos")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC(animationEnabled: true)
        sc.gestureSnap = false
        addFakeWindows(sc, count: 3, width: 700)
        sc.strip.activeColumnIndex = 1
        sc.strip.viewOffset = .static(sc.strip.snapTargetForActive(at: clock.t))
        sc.applyLayout()
        sc.handleGestureBegin(time: clock.t)
        for _ in 0..<5 { sc.handleGestureUpdate(deltaX: -20, time: clock.t); clock.advance(0.01) }
        let oldActive = sc.strip.activeColumnIndex
        sc.handleGestureEnd(time: clock.t)
        guard case .animation = sc.strip.viewOffset else {
            check(false, "flick velocity should start momentum animation"); return
        }
        let target = sc.strip.viewOffset.target
        // viewPos is preserved across the settle re-anchor (which is cursor-dependent),
        // so assert the deterministic scroll position rather than which column is active.
        let expectedViewPos = sc.strip.columnX(at: oldActive, time: clock.t) + target
        settle(sc, clock)
        check(sc.isFullySettled, "momentum settled")
        assertClose(sc.strip.viewPos(at: clock.t), expectedViewPos, tolerance: 2,
                    "free-scroll lands at projected position (viewPos preserved)")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- snap momentum ----
    section("gesture momentum (gestureSnap) starts animation and settles to static")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC(animationEnabled: true)
        sc.gestureSnap = true
        addFakeWindows(sc, count: 3, width: 700)
        sc.strip.activeColumnIndex = 1
        sc.strip.viewOffset = .static(sc.strip.snapTargetForActive(at: clock.t))
        sc.applyLayout()
        sc.handleGestureBegin(time: clock.t)
        for _ in 0..<5 { sc.handleGestureUpdate(deltaX: -20, time: clock.t); clock.advance(0.01) }
        sc.handleGestureEnd(time: clock.t)
        guard case .animation = sc.strip.viewOffset else {
            check(false, "snap flick should start momentum animation"); return
        }
        settle(sc, clock)
        check(sc.isFullySettled, "snap momentum settled")
        if case .static = sc.strip.viewOffset { check(true, "resolved to static") }
        else { check(false, "viewOffset should be static after settle") }
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- rubber-band ----
    section("rubber-band overshoots past rest then returns")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC(animationEnabled: true)
        addFakeWindows(sc, count: 1, width: 700)
        sc.strip.viewOffset = .static(sc.strip.snapTargetForActive(at: clock.t))
        sc.applyLayout()
        let rest = sc.strip.snapTargetForActive(at: clock.t)
        sc.focusRight()  // single col at boundary → rubber-band (kick 600, no velocity arg)
        guard case .animation = sc.strip.viewOffset else {
            check(false, "boundary focusRight should produce a rubber-band animation"); return
        }
        // Sample mid-flight: underdamped bounce must deviate from rest, then return.
        var maxDev = 0.0
        for i in 1...120 {
            let t = clock.t + Double(i) / 120.0
            maxDev = max(maxDev, abs(sc.strip.viewOffset.current(at: t) - rest))
        }
        check(maxDev > 1, "rubber-band deviates from rest mid-flight (got \(maxDev))")
        settle(sc, clock)
        assertClose(sc.strip.viewOffset.current(at: clock.t), rest, tolerance: 2, "returns to rest")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- width animation convergence ----
    section("width-animation converges; fake width reaches preset")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC(animationEnabled: true)
        let (_, ws) = addFakeWindows(sc, count: 1, width: 700)
        sc.strip.viewOffset = .static(sc.strip.snapTargetForActive(at: clock.t))
        sc.applyLayout()
        sc.setWidthPreset(index: 0)  // animated → width spring
        check(sc.strip.columnData[0].widthAnimation != nil, "width spring created")
        settle(sc, clock)
        check(sc.isFullySettled, "width animation settled")
        let target = 0.33 * 1440.0
        assertClose(sc.strip.columnData[0].cachedWidth, target, tolerance: 1, "cachedWidth = preset")
        assertClose(Double(ws[0].currentFrame.width), target, tolerance: 2, "fake width converged")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- focus indicator isAnimating latch (flash, suppressed) ----
    section("focus indicator flash isAnimating latch (overlaySuppressed)")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        sc.focusIndicator.overlaySuppressed = true
        var cfg = FocusIndicatorConfig(); cfg.style = .flash
        sc.focusIndicator.reloadConfig(cfg)
        let started = sc.focusIndicator.snapTo(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        check(started, "flash snapTo starts easing")
        check(sc.focusIndicator.isAnimating, "isAnimating latched during flash")
        sc.focusIndicator.tick(time: clock.t)
        check(sc.focusIndicator.isAnimating, "still animating within 0.2s window")
        clock.advance(0.3)  // past the 0.2s flash duration
        sc.focusIndicator.tick(time: clock.t)
        check(!sc.focusIndicator.isAnimating, "flash easing done → isAnimating clears")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- pause-freeze mid-flight ----
    section("isPaused=true mid-flight freezes viewOffset + drops springs")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC(animationEnabled: true)
        let (_, ws) = addFakeWindows(sc, count: 2, width: 700)
        sc.setWidthPreset(index: 0)          // width spring in flight too
        sc.focusLeftAnimated(velocity: 0)    // scroll spring in flight
        for _ in 0..<3 { clock.advance(1.0 / 60.0); sc.handleFrameTick(time: clock.t) }
        guard case .animation = sc.strip.viewOffset else { check(false, "still mid-flight"); return }
        let frozenOffset = sc.strip.viewOffset.current(at: clock.t)
        sc.isPaused = true
        if case .static(let o) = sc.strip.viewOffset {
            assertClose(o, frozenOffset, tolerance: 0.01, "viewOffset frozen at current position")
        } else { check(false, "viewOffset became static on pause") }
        check(!sc.strip.columnData.contains { $0.widthAnimation != nil }, "no width springs remain")
        check(!sc.strip.columnData.contains { $0.raiseAnimation != nil }, "no raise springs remain")

        // Tick while paused does nothing (handleFrameTick is pause-guarded).
        let f0 = ws[0].currentFrame
        clock.advance(0.5); sc.handleFrameTick(time: clock.t)
        assertEq(ws[0].currentFrame, f0, "tick while paused writes nothing")
        if case .static = sc.strip.viewOffset { check(true, "still static after paused tick") }
        else { check(false, "paused tick must not un-freeze viewOffset") }
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- applyLayout while paused dispatches zero writes ----
    // [animation] config was parsed but only ever reached widthSpringParams; every
    // scroll used a hard-coded spring and the two bounce fields had no consumer at
    // all. Drives the real production helper — asserting on a hand-populated Strip
    // would pass even with the wiring absent.
    section("config animation values reach an existing strip")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        addFakeWindows(sc, count: 2, width: 700)
        assertClose(sc.strip.bounceDistance, 40, tolerance: 0.001, "starts at the default")
        assertClose(sc.strip.scrollSpringParams.stiffness, 800, tolerance: 0.001, "default stiffness")

        var cfg = ReelConfig()
        cfg.scrollStiffness = 250
        cfg.scrollDampingRatio = 0.8
        cfg.bounceDistance = 77
        cfg.bounceDampingRatio = 0.4
        applyAnimationConfig(cfg, to: sc)

        assertClose(sc.strip.scrollSpringParams.stiffness, 250, tolerance: 0.001, "stiffness reached the strip")
        assertClose(sc.strip.bounceDistance, 77, tolerance: 0.001, "bounce distance reached the strip")
        assertClose(sc.strip.bounceDampingRatio, 0.4, tolerance: 0.001, "bounce damping reached the strip")
        _ = clock
    }

    // Storing the value is not enough — the scroll path used to hard-code
    // `.horizontalScroll` (stiffness 800) at every site, so a configured spring
    // was stored and then ignored. Assert the animation actually carries it.
    section("a configured scroll spring is used by the scroll animation")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        var strip = makeStrip(columnCount: 3, gap: 16)
        strip.activeColumnIndex = 0
        strip.scrollSpringParams = SpringParams(dampingRatio: 0.8, stiffness: 250, epsilon: 0.5)

        let anim = strip.navigateRight(at: clock.t)
        check(anim != nil, "navigateRight produced an animation")
        assertClose(anim!.params.stiffness, 250, tolerance: 0.001,
            "scroll animation uses the configured stiffness, not the hard-coded 800")
        // SpringParams stores `damping`; dampingRatio is init-only. Derive it.
        let ratio = anim!.params.damping / (2 * (anim!.params.stiffness * anim!.params.mass).squareRoot())
        assertClose(ratio, 0.8, tolerance: 0.001,
            "scroll animation uses the configured damping ratio")
    }

    // Same for the rubber-band bounce, whose distance/damping had NO consumer at all.
    section("configured bounce values are used by the rubber-band animation")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        var strip = makeStrip(columnCount: 2, gap: 16)
        strip.bounceDampingRatio = 0.35
        strip.bounceDistance = 90
        let anim = strip.createRubberBandAnimation(direction: 1, at: clock.t)
        let bounceRatio = anim.params.damping / (2 * (anim.params.stiffness * anim.params.mass).squareRoot())
        assertClose(bounceRatio, 0.35, tolerance: 0.001,
            "bounce uses the configured damping ratio, not the hard-coded 0.6")
        check(abs(anim.initialVelocity) > 0, "bounce carries a kick velocity derived from bounceDistance")
    }

    section("applyLayout while paused dispatches zero writes")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        addFakeWindows(sc, count: 2, width: 700)  // initial layout runs inline
        let cap = Capture()
        sc.frameDispatch = { _, work in cap.blocks.append(work) }
        sc.mainHop = { $0() }
        sc.isPaused = true
        sc.strip.viewOffset = .static(-123)  // would change every frame
        sc.applyLayout()
        assertEq(cap.blocks.count, 0, "paused applyLayout enqueues nothing (capturing executor empty)")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")
}
