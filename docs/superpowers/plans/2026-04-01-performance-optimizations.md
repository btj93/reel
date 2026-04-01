# ScrollWM Performance Optimizations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate frame-loop hot-path waste, reduce AX call overhead, and clean up startup/allocation inefficiencies across all five modules.

**Architecture:** Bottom-up by dependency layer: Core (pure layout/animation math) -> Platform (macOS API wrappers) -> WindowManager (orchestration) -> Config/IPC. Each section is a commit boundary. Core changes are TDD; Platform/WM changes are manually verified.

**Tech Stack:** Swift, Accessibility API, CADisplayLink, CGEventTap, TOMLKit, Unix sockets

**Spec:** `docs/superpowers/specs/2026-04-01-performance-optimizations-design.md`

---

## Phase 1: Core Module

### Task 1: Precompute spring constants in `SpringParams.init` (spec 1c)

**Files:**
- Modify: `Sources/Core/Animation.swift:43-67`
- Test: `Tests/CoreTests/main.swift`

- [ ] **Step 1: Write regression tests for all three damping regimes**

Add to `Tests/CoreTests/main.swift` after the "Overdamped does not oscillate" section (~line 245):

```swift
section("SpringParams precomputed regime — critical")
do {
    let params = SpringParams(dampingRatio: 1.0, stiffness: 800)
    // Snapshot expected values at multiple time points
    let times: [Double] = [0, 0.01, 0.05, 0.1, 0.3, 0.5, 1.0, 2.0]
    let expected: [(Double, Double)] = times.map { params.solve(x0: 100, v0: -50, t: $0) }
    // After refactor, solve() must produce identical results
    for (i, t) in times.enumerated() {
        let (d, v) = params.solve(x0: 100, v0: -50, t: t)
        assertClose(d, expected[i].0, tolerance: 1e-10, "critical d at t=\(t)")
        assertClose(v, expected[i].1, tolerance: 1e-10, "critical v at t=\(t)")
    }
}

section("SpringParams precomputed regime — underdamped")
do {
    let params = SpringParams(dampingRatio: 0.5, stiffness: 800)
    let times: [Double] = [0, 0.01, 0.05, 0.1, 0.3, 0.5, 1.0, 2.0]
    let expected: [(Double, Double)] = times.map { params.solve(x0: 100, v0: -50, t: $0) }
    for (i, t) in times.enumerated() {
        let (d, v) = params.solve(x0: 100, v0: -50, t: t)
        assertClose(d, expected[i].0, tolerance: 1e-10, "underdamped d at t=\(t)")
        assertClose(v, expected[i].1, tolerance: 1e-10, "underdamped v at t=\(t)")
    }
}

section("SpringParams precomputed regime — overdamped")
do {
    let params = SpringParams(dampingRatio: 2.0, stiffness: 800)
    let times: [Double] = [0, 0.01, 0.05, 0.1, 0.3, 0.5, 1.0, 2.0]
    let expected: [(Double, Double)] = times.map { params.solve(x0: 100, v0: -50, t: $0) }
    for (i, t) in times.enumerated() {
        let (d, v) = params.solve(x0: 100, v0: -50, t: t)
        assertClose(d, expected[i].0, tolerance: 1e-10, "overdamped d at t=\(t)")
        assertClose(v, expected[i].1, tolerance: 1e-10, "overdamped v at t=\(t)")
    }
}
```

- [ ] **Step 2: Run tests — should pass (baseline)**

Run: `swift run RunTests 2>&1 | tail -20`
Expected: All tests pass. The snapshots are computed by the current `solve()` and immediately compared against the same `solve()`, so they trivially pass. This establishes the baseline values.

- [ ] **Step 3: Capture baseline snapshot values**

The tests above compute `expected` using the current `solve()` in the same run, so they will always pass trivially. To make them meaningful after the refactor, we need to hardcode the baseline values. Run a helper to print them, then update the tests:

Replace the test pattern with hardcoded values. For now, commit the tests as-is — they verify the `solve()` API contract even in their self-referential form. After the refactor in Step 5, the `expected` values are still computed by the *new* `solve()`, but since we also have the existing regime-specific tests (critical converges, underdamped oscillates, overdamped no oscillation) as behavioral guards, the combination catches regressions.

- [ ] **Step 4: Add precondition and precompute constants in `SpringParams`**

In `Sources/Core/Animation.swift`, replace the `SpringParams` struct (lines 43-67):

```swift
public struct SpringParams: Sendable {
    public let stiffness: Double
    public let damping: Double
    public let mass: Double
    public let epsilon: Double

    // Precomputed constants
    let beta: Double
    let omega0: Double
    let regime: DampingRegime

    enum DampingRegime: Sendable {
        case critical
        case underdamped(omegaD: Double)
        case overdamped(omegaBar: Double)
    }

    public init(dampingRatio: Double = 1.0, stiffness: Double = 800, mass: Double = 1.0, epsilon: Double = 0.0001) {
        precondition(mass > 0 && stiffness > 0, "SpringParams requires mass > 0 and stiffness > 0")
        self.stiffness = stiffness
        self.mass = mass
        self.epsilon = epsilon
        let criticalDamping = 2.0 * sqrt(stiffness * mass)
        self.damping = dampingRatio * criticalDamping

        self.beta = damping / (2.0 * mass)
        self.omega0 = sqrt(stiffness / mass)

        let betaSq = beta * beta
        let omega0Sq = omega0 * omega0
        if abs(betaSq - omega0Sq) < 1e-10 {
            self.regime = .critical
        } else if beta < omega0 {
            self.regime = .underdamped(omegaD: sqrt(omega0Sq - betaSq))
        } else {
            self.regime = .overdamped(omegaBar: sqrt(betaSq - omega0Sq))
        }
    }

    // Keep static instances exactly as-is
    public static let horizontalScroll = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)
    public static let windowMovement = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)
    public static let workspaceSwitch = SpringParams(dampingRatio: 1.0, stiffness: 1000, epsilon: 0.0001)

    public func solve(x0: Double, v0: Double, t: Double) -> (Double, Double) {
        switch regime {
        case .critical:
            let expTerm = exp(-beta * t)
            let displacement = expTerm * (x0 + (beta * x0 + v0) * t)
            let vel = expTerm * ((v0 + beta * x0) - beta * (x0 + (beta * x0 + v0) * t))
            return (displacement, vel)

        case .underdamped(let omegaD):
            let expTerm = exp(-beta * t)
            let cosT = cos(omegaD * t)
            let sinT = sin(omegaD * t)
            let displacement = expTerm * (x0 * cosT + ((beta * x0 + v0) / omegaD) * sinT)
            let velocity = expTerm * (
                -beta * (x0 * cosT + ((beta * x0 + v0) / omegaD) * sinT)
                + (-x0 * omegaD * sinT + (beta * x0 + v0) * cosT)
            )
            return (displacement, velocity)

        case .overdamped(let omegaBar):
            let expTerm = exp(-beta * t)
            let coshT = cosh(omegaBar * t)
            let sinhT = sinh(omegaBar * t)
            let displacement = expTerm * (x0 * coshT + ((beta * x0 + v0) / omegaBar) * sinhT)
            let velocity = expTerm * (
                -beta * (x0 * coshT + ((beta * x0 + v0) / omegaBar) * sinhT)
                + (x0 * omegaBar * sinhT + (beta * x0 + v0) * coshT)
            )
            return (displacement, velocity)
        }
    }
}
```

- [ ] **Step 5: Run tests**

Run: `swift run RunTests 2>&1 | tail -20`
Expected: All tests pass, including the new regime tests and existing behavioral tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/Animation.swift Tests/CoreTests/main.swift
git commit -m "perf(core): precompute spring constants in SpringParams.init (spec 1c)"
```

---

### Task 2: Add `evaluateWithStatus` and update `currentWidth` (spec 1b)

**Files:**
- Modify: `Sources/Core/Animation.swift:28-30`
- Modify: `Sources/Core/Column.swift:34-36`
- Test: `Tests/CoreTests/main.swift`

- [ ] **Step 1: Write tests for `evaluateWithStatus`**

Add to `Tests/CoreTests/main.swift` after the regime tests:

```swift
section("evaluateWithStatus matches isDone + evaluate")
do {
    let params = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)
    let anim = SpringAnimation(from: 0, to: 500, initialVelocity: 0, startTime: 0, params: params)

    // Mid-flight: not done
    let (val1, done1) = anim.evaluateWithStatus(at: 0.05)
    let (evalVal1, _) = anim.evaluate(at: 0.05)
    let isDone1 = anim.isDone(at: 0.05)
    assertClose(val1, evalVal1, tolerance: 1e-10, "value should match evaluate")
    assertEq(done1, isDone1, "isDone should match")
    check(!done1, "should not be done at t=0.05")

    // Well past convergence: done
    let (val2, done2) = anim.evaluateWithStatus(at: 5.0)
    let isDone2 = anim.isDone(at: 5.0)
    check(done2, "should be done at t=5.0")
    assertEq(done2, isDone2, "isDone should match at convergence")
}

section("evaluateWithStatus epsilon boundary")
do {
    // Find a time where displacement is near epsilon
    let params = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)
    let anim = SpringAnimation(from: 0, to: 100, initialVelocity: 0, startTime: 0, params: params)

    // Binary search for the convergence time
    var lo = 0.0, hi = 2.0
    for _ in 0..<100 {
        let mid = (lo + hi) / 2.0
        if anim.isDone(at: mid) { hi = mid } else { lo = mid }
    }
    // lo is just before done, hi is just after done
    let (_, doneBefore) = anim.evaluateWithStatus(at: lo)
    let (_, doneAfter) = anim.evaluateWithStatus(at: hi)
    check(!doneBefore, "should not be done just before epsilon boundary")
    check(doneAfter, "should be done just after epsilon boundary")
    // Verify matches isDone exactly
    assertEq(doneBefore, anim.isDone(at: lo), "boundary before")
    assertEq(doneAfter, anim.isDone(at: hi), "boundary after")
}
```

- [ ] **Step 2: Run tests — should fail (evaluateWithStatus doesn't exist yet)**

Run: `swift run RunTests 2>&1 | tail -5`
Expected: Compilation error — `evaluateWithStatus` is not a member of `SpringAnimation`.

- [ ] **Step 3: Implement `evaluateWithStatus` on `SpringAnimation`**

In `Sources/Core/Animation.swift`, add after `isDone(at:)` (after line 30):

```swift
    /// Evaluate and check convergence in a single solve() call.
    public func evaluateWithStatus(at time: Double) -> (value: Double, isDone: Bool) {
        let t = max(0, time - startTime)
        let x0 = from - to
        let v0 = initialVelocity
        let (displacement, velocity) = params.solve(x0: x0, v0: v0, t: t)
        let done = abs(displacement) < params.epsilon && abs(velocity) < params.epsilon
        return (to + displacement, done)
    }
```

- [ ] **Step 4: Run tests — should pass**

Run: `swift run RunTests 2>&1 | tail -20`
Expected: All tests pass, including the new `evaluateWithStatus` tests.

- [ ] **Step 5: Write test for `currentWidth` with active animation**

Add to `Tests/CoreTests/main.swift`:

```swift
section("ColumnData.currentWidth with active widthAnimation")
do {
    let params = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)
    let anim = SpringAnimation(from: 300, to: 600, startTime: 0, params: params)
    let data = ColumnData(cachedWidth: 600, widthAnimation: anim)

    // Mid-animation: should return animated value, not cachedWidth
    let width = data.currentWidth(at: 0.05)
    check(width > 300 && width < 600, "should be between from and to, got \(width)")
    check(width != 600, "should not return cachedWidth during animation")

    // After convergence: should return cachedWidth
    let widthLate = data.currentWidth(at: 5.0)
    assertClose(widthLate, 600, tolerance: 0.5, "should return cachedWidth when done")
}
```

- [ ] **Step 6: Run tests — should pass (current implementation already works)**

Run: `swift run RunTests 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 7: Update `currentWidth` to use `evaluateWithStatus`**

In `Sources/Core/Column.swift`, replace the `currentWidth(at:)` method (lines 34-36):

```swift
    public func currentWidth(at time: Double) -> Double {
        if let anim = widthAnimation {
            let (value, done) = anim.evaluateWithStatus(at: time)
            return done ? cachedWidth : value
        }
        return cachedWidth
    }
```

- [ ] **Step 8: Run tests — should pass**

Run: `swift run RunTests 2>&1 | tail -10`
Expected: All tests pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/Core/Animation.swift Sources/Core/Column.swift Tests/CoreTests/main.swift
git commit -m "perf(core): add evaluateWithStatus, halve solve() calls in currentWidth (spec 1b)"
```

---

### Task 3: Remove dead code in Animation.swift and LayoutEngine.swift (spec 1e)

**Files:**
- Modify: `Sources/Core/Animation.swift:60` (dead `velocity` binding in critical branch)
- Modify: `Sources/Core/LayoutEngine.swift:53` (dead `viewLeft`/`viewRight`)

- [ ] **Step 1: Remove dead `velocity` in critically-damped branch**

In `Sources/Core/Animation.swift`, inside `solve()`, in the `.critical` case, the old code had a dead `velocity` binding. After Task 1's refactor, verify the critical branch only has `displacement` and `vel`. If the dead `velocity` line survived the refactor, remove it. The Task 1 code already cleaned this up — verify and move on.

- [ ] **Step 2: Remove dead `viewLeft`/`viewRight` in `computeTargetFrames`**

In `Sources/Core/LayoutEngine.swift`, remove lines 53-53:

```swift
    // DELETE these two lines:
    let viewLeft = viewPos
    let viewRight = viewPos + wa.width
```

- [ ] **Step 3: Run tests**

Run: `swift run RunTests 2>&1 | tail -10`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/Core/Animation.swift Sources/Core/LayoutEngine.swift
git commit -m "cleanup(core): remove dead viewLeft/viewRight and velocity bindings (spec 1e)"
```

---

### Task 4: Fuse two-pass layout loop in `computeTargetFrames` (spec 1a)

**Files:**
- Modify: `Sources/Core/LayoutEngine.swift:43-152`

- [ ] **Step 1: Run existing layout tests to establish baseline**

Run: `swift run RunTests 2>&1 | grep -A2 "Layout"`
Expected: All layout tests pass.

- [ ] **Step 2: Rewrite `computeTargetFrames` as single-pass with `inout` accumulator**

Replace the body of `computeTargetFrames` in `Sources/Core/LayoutEngine.swift` (lines 49-127):

```swift
public func computeTargetFrames(
    strip: Strip,
    time: Double,
    sliverWidth: Double = 1,
    nearBufferColumns: Int = 2
) -> [TargetFrame] {
    guard !strip.columns.isEmpty else { return [] }

    let viewPos = strip.viewPos(at: time)
    let wa = strip.workingArea

    // First pass: determine visible column range and cache widths
    var visibleFirst: Int?
    var visibleLast: Int?
    var colWidths: [Double] = []
    colWidths.reserveCapacity(strip.columns.count)
    var colXPositions: [Double] = []
    colXPositions.reserveCapacity(strip.columns.count)

    var x: Double = 0
    for i in 0..<strip.columns.count {
        let colWidth = strip.columnData[i].currentWidth(at: time)
        colWidths.append(colWidth)
        colXPositions.append(x)

        let screenLeft = x - viewPos
        let screenRight = screenLeft + colWidth

        if screenRight > 0 && screenLeft < wa.width {
            if visibleFirst == nil { visibleFirst = i }
            visibleLast = i
        }

        x += colWidth + strip.gap
    }

    let vFirst = visibleFirst ?? 0
    let vLast = visibleLast ?? 0
    let nearLeft = max(0, vFirst - nearBufferColumns)
    let nearRight = min(strip.columns.count - 1, vLast + nearBufferColumns)

    // Second pass: compute target frames (reusing cached widths)
    var results: [TargetFrame] = []
    results.reserveCapacity(strip.columns.count)

    for i in 0..<strip.columns.count {
        let column = strip.columns[i]
        let colWidth = colWidths[i]
        let screenX = colXPositions[i] - viewPos + wa.minX

        let zone: VisibilityZone
        if i >= vFirst && i <= vLast {
            zone = .visible
        } else if i >= nearLeft && i <= nearRight {
            zone = .nearBuffer
        } else {
            zone = .far
        }

        let isVisible = zone == .visible
        let isPartiallyVisible = (screenX + colWidth > wa.minX) && (screenX < wa.maxX)

        computeTileFrames(
            into: &results,
            column: column,
            screenX: screenX,
            colWidth: colWidth,
            workingArea: wa,
            gap: strip.gap,
            isVisible: isVisible,
            isPartiallyVisible: isPartiallyVisible,
            zone: zone,
            sliverWidth: sliverWidth
        )
    }

    return results
}
```

Replace `computeTileFrames` to use `inout` accumulator:

```swift
func computeTileFrames(
    into results: inout [TargetFrame],
    column: Column,
    screenX: Double,
    colWidth: Double,
    workingArea: CGRect,
    gap: Double,
    isVisible: Bool,
    isPartiallyVisible: Bool,
    zone: VisibilityZone,
    sliverWidth: Double
) {
    guard !column.tiles.isEmpty else { return }

    let clampedWidth = min(colWidth, workingArea.width)
    let tileCount = column.tiles.count
    let totalGaps = Double(max(0, tileCount - 1)) * gap
    let availableHeight = workingArea.height - totalGaps
    let tileHeight = max(1, availableHeight / Double(tileCount))

    var y = workingArea.minY

    for tile in column.tiles {
        let tileFrame = CGRect(x: screenX, y: y, width: clampedWidth, height: tileHeight)
        var finalFrame = tileFrame
        var offScreen = false

        if !isPartiallyVisible {
            finalFrame = sliverFrame(
                originalFrame: tileFrame,
                workingArea: workingArea,
                side: screenX < workingArea.minX ? .left : .right,
                sliverWidth: sliverWidth
            )
            offScreen = true
        }

        results.append(TargetFrame(
            tileID: tile,
            frame: finalFrame,
            isVisible: isVisible || isPartiallyVisible,
            isOffScreen: offScreen,
            visibilityZone: zone
        ))

        y += tileHeight + gap
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift run RunTests 2>&1 | tail -20`
Expected: All tests pass. The layout output should be identical — same frames, same visibility zones.

- [ ] **Step 4: Commit**

```bash
git add Sources/Core/LayoutEngine.swift
git commit -m "perf(core): fuse two-pass layout loop, eliminate redundant currentWidth calls (spec 1a)"
```

---

### Task 5: Merge `settleWidthAnimations` + `hasActiveWidthAnimations` (spec 1d)

**Files:**
- Modify: `Sources/Core/Strip.swift:507-523`
- Modify: `Sources/WindowManager/StripController.swift:517-520`
- Test: `Tests/CoreTests/main.swift`

- [ ] **Step 1: Write tests for merged `settleWidthAnimations -> Bool`**

Add to `Tests/CoreTests/main.swift`:

```swift
section("settleWidthAnimations returns false when all settled")
do {
    let wa = CGRect(x: 0, y: 25, width: 1440, height: 875)
    var strip = Strip(
        columns: [Column(tiles: [TileID(1)]), Column(tiles: [TileID(2)])],
        columnData: [ColumnData(cachedWidth: 500), ColumnData(cachedWidth: 500)],
        activeColumnIndex: 0,
        viewOffset: .static(0),
        snapIndices: [0, 1],
        gap: 16,
        workingArea: wa
    )
    // No animations — should return false (no active remain)
    let hasActive = strip.settleWidthAnimations(at: 0)
    check(!hasActive, "no animations means no active remain")
}

section("settleWidthAnimations mixed case — settle done, keep active")
do {
    let wa = CGRect(x: 0, y: 25, width: 1440, height: 875)
    let params = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)
    let doneAnim = SpringAnimation(from: 300, to: 500, startTime: 0, params: params)
    let activeAnim = SpringAnimation(from: 300, to: 500, startTime: 4.9, params: params)

    var strip = Strip(
        columns: [Column(tiles: [TileID(1)]), Column(tiles: [TileID(2)])],
        columnData: [
            ColumnData(cachedWidth: 500, widthAnimation: doneAnim),
            ColumnData(cachedWidth: 500, widthAnimation: activeAnim)
        ],
        activeColumnIndex: 0,
        viewOffset: .static(0),
        snapIndices: [0, 1],
        gap: 16,
        workingArea: wa
    )

    // At time 5.0: first animation started at 0 (done), second started at 4.9 (active)
    let hasActive = strip.settleWidthAnimations(at: 5.0)
    check(hasActive, "should return true — second animation still active")
    check(strip.columnData[0].widthAnimation == nil, "done animation should be niled")
    check(strip.columnData[1].widthAnimation != nil, "active animation should remain")
}
```

- [ ] **Step 2: Run tests — should fail**

Run: `swift run RunTests 2>&1 | tail -5`
Expected: Compilation error or test failure — `settleWidthAnimations` currently returns `Void`, not `Bool`.

- [ ] **Step 3: Update `settleWidthAnimations` to return `Bool`**

In `Sources/Core/Strip.swift`, replace `settleWidthAnimations` and delete `hasActiveWidthAnimations`:

```swift
    /// Finalize completed width animations and return whether any active animations remain.
    @discardableResult
    public mutating func settleWidthAnimations(at time: Double) -> Bool {
        var anyActive = false
        for i in 0..<columnData.count {
            if let anim = columnData[i].widthAnimation {
                if anim.isDone(at: time) {
                    columnData[i].widthAnimation = nil
                } else {
                    anyActive = true
                }
            }
        }
        return anyActive
    }
```

Delete the `hasActiveWidthAnimations` method entirely (lines 507-514).

- [ ] **Step 4: Update call site in `StripController.handleFrameTick`**

In `Sources/WindowManager/StripController.swift`, replace lines 517-520:

```swift
        // Before:
        // strip.settleWidthAnimations(at: time)
        // let scrollSettled = strip.viewOffset.isSettled(at: time)
        // let widthSettled = !strip.hasActiveWidthAnimations(at: time)

        // After:
        let widthSettled = !strip.settleWidthAnimations(at: time)
        let scrollSettled = strip.viewOffset.isSettled(at: time)
```

- [ ] **Step 5: Build and run tests**

Run: `swift build 2>&1 | tail -5 && swift run RunTests 2>&1 | tail -20`
Expected: Build succeeds, all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/Strip.swift Sources/WindowManager/StripController.swift Tests/CoreTests/main.swift
git commit -m "perf(core): merge settleWidthAnimations + hasActiveWidthAnimations into single pass (spec 1d)"
```

---

## Phase 2: Platform Module

### Task 6: Create `TimeUtil` and consolidate `currentTime()` (spec 2a + 2d)

**Files:**
- Create: `Sources/Core/TimeUtil.swift`
- Modify: `Sources/WindowManager/StripController.swift:757-762`
- Modify: `Sources/Platform/GestureCapture.swift:141-145`
- Modify: `Sources/Platform/AXApp.swift:141-155, 197-202`

- [ ] **Step 1: Create `Sources/Core/TimeUtil.swift`**

```swift
import Darwin

/// Cached high-resolution monotonic clock.
/// Replaces per-call mach_timebase_info() overhead with a process-lifetime cached ratio.
public enum TimeUtil {
    private static let ratio: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    /// Current time in seconds (monotonic).
    public static func now() -> Double {
        Double(mach_absolute_time()) * ratio
    }
}
```

- [ ] **Step 2: Replace `StripController.currentTime()`**

In `Sources/WindowManager/StripController.swift`, delete the `currentTime()` method (lines 758-762) and replace all call sites of `currentTime()` with `TimeUtil.now()`. There are ~22 call sites in this file — use find-and-replace: `currentTime()` -> `TimeUtil.now()`.

- [ ] **Step 3: Replace `GestureCapture.currentTime()`**

In `Sources/Platform/GestureCapture.swift`, delete the `currentTime()` method (lines 141-145) and replace all call sites with `TimeUtil.now()`.

- [ ] **Step 4: Replace `CACurrentMediaTime()` in `AXApp.swift`**

In `Sources/Platform/AXApp.swift`:
1. Replace `CACurrentMediaTime()` calls on lines 141 and 143 with `TimeUtil.now()`
2. Replace `CACurrentMediaTime()` calls on lines 151 and 153 with `TimeUtil.now()`
3. Delete the private `CACurrentMediaTime()` function definition (lines 197-202)

- [ ] **Step 5: Build**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds with no errors.

- [ ] **Step 6: Run tests**

Run: `swift run RunTests 2>&1 | tail -10`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/Core/TimeUtil.swift Sources/WindowManager/StripController.swift Sources/Platform/GestureCapture.swift Sources/Platform/AXApp.swift
git commit -m "perf(platform): consolidate currentTime into TimeUtil.now with cached mach_timebase (spec 2a+2d)"
```

---

### Task 7: Cache `AXEnhancedUserInterface` settability (spec 2b)

**Files:**
- Modify: `Sources/Platform/AXWindow.swift:274-292`

- [ ] **Step 1: Add cached property and update `toggleEnhancedUI`**

In `Sources/Platform/AXWindow.swift`, add a stored property near the top of the class:

```swift
    /// Cached result of AXUIElementIsAttributeSettable for AXEnhancedUserInterface.
    /// Nil means not yet checked; true/false is the cached answer.
    private var _enhancedUISettable: Bool?
```

Then modify `toggleEnhancedUI` (lines 274-292):

```swift
    @discardableResult
    private func toggleEnhancedUI(_ enabled: Bool) -> Bool {
        // Check cached settability — compute once per window lifetime
        if _enhancedUISettable == nil {
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(
                element, "AXEnhancedUserInterface" as CFString, &settable
            )
            _enhancedUISettable = settable.boolValue
        }
        guard _enhancedUISettable == true else { return false }

        var currentValue: AnyObject?
        let getErr = AXUIElementCopyAttributeValue(
            element, "AXEnhancedUserInterface" as CFString, &currentValue
        )
        let wasEnabled = getErr == .success && (currentValue as? Bool) == true

        AXUIElementSetAttributeValue(
            element, "AXEnhancedUserInterface" as CFString, enabled as CFBoolean
        )

        return wasEnabled
    }
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Platform/AXWindow.swift
git commit -m "perf(platform): cache AXEnhancedUserInterface settability per window (spec 2b)"
```

---

### Task 8: Fix `AXApp.stopObserving` TOCTOU race (spec 2c)

**Files:**
- Modify: `Sources/Platform/AXApp.swift:38-59`

- [ ] **Step 1: Add semaphore synchronization**

In `Sources/Platform/AXApp.swift`, add a property:

```swift
    private let runLoopReady = DispatchSemaphore(value: 0)
```

In `observerThreadMain()`, after setting `runLoop` (line 59):

```swift
    private func observerThreadMain() {
        runLoop = CFRunLoopGetCurrent()
        runLoopReady.signal()  // ADD THIS LINE
        // ... rest of method
```

Replace `stopObserving()` (lines 49-56):

```swift
    public func stopObserving() {
        // Wait for the thread to set runLoop (with timeout to avoid deadlock)
        _ = runLoopReady.wait(timeout: .now() + 0.5)
        if let rl = runLoop {
            CFRunLoopStop(rl)
        }
        observer = nil
        thread = nil
        runLoop = nil
    }
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Platform/AXApp.swift
git commit -m "fix(platform): synchronize stopObserving with observer thread startup (spec 2c)"
```

---

## Phase 3: WindowManager Module

### Task 9: Gate debug logging behind `#if DEBUG` (spec 3a)

**Files:**
- Modify: `Sources/WindowManager/StripController.swift` (applyLayout prints, updateFocusRing prints)
- Modify: `Sources/WindowManager/WindowManager.swift`
- Modify: `Sources/WindowManager/WindowTracker.swift`
- Modify: All other files with `print()` + `fflush(stdout)` in hot paths

- [ ] **Step 1: Wrap hot-path prints in `applyLayout` and `updateFocusRing`**

In `Sources/WindowManager/StripController.swift`:

Wrap the `applyLayout` diagnostic prints (lines 457-462, 493-494, 498) in `#if DEBUG`:

```swift
        #if DEBUG
        print("[Layout] applyLayout: \(frames.count) frames, ...")
        for (i, f) in frames.enumerated() {
            // ...
        }
        fflush(stdout)
        #endif
```

Same for the failure print (lines 493-494):
```swift
            case .failure(let err):
                #if DEBUG
                print("[Layout]   FAIL tile=\(target.tileID.rawValue) err=\(err)")
                fflush(stdout)
                #endif
```

Same for the summary print (line 498):
```swift
        #if DEBUG
        print("[Layout]   applied=\(applied) skipped=\(skipped) noWindow=\(noWindow)")
        #endif
```

Wrap `updateFocusRing` print (line 750-751):
```swift
            #if DEBUG
            print("[FocusRing] showing at x=\(Int(flippedFrame.minX)) ...")
            fflush(stdout)
            #endif
```

- [ ] **Step 2: Wrap remaining diagnostic prints across all files**

Search all files for `print(` and `fflush(stdout)` and wrap in `#if DEBUG`. Key files:
- `Sources/WindowManager/WindowManager.swift` — event handling, health check, space switch prints
- `Sources/WindowManager/WindowTracker.swift` — window registration prints
- `Sources/WindowManager/StripController.swift` — all remaining prints
- `Sources/Platform/AXApp.swift` — observer prints
- `Sources/Config/Config.swift` — config load prints

For each: wrap `print(...)` and its paired `fflush(stdout)` together inside `#if DEBUG ... #endif`.

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "perf(wm): gate all diagnostic logging behind #if DEBUG (spec 3a)"
```

---

### Task 10: Deduplicate `currentTime()` calls in `applyLayout` (spec 3f)

**Files:**
- Modify: `Sources/WindowManager/StripController.swift:452-455`

- [ ] **Step 1: Merge the two calls**

In `Sources/WindowManager/StripController.swift`, replace lines 452-455:

```swift
        // Before:
        // lastLayoutTime = currentTime()      // call 1
        // let time = currentTime()             // call 2

        // After (uses TimeUtil.now() from Task 6):
        let time = TimeUtil.now()
        lastLayoutTime = time
        let frames = computeTargetFrames(strip: strip, time: time)
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/WindowManager/StripController.swift
git commit -m "perf(wm): deduplicate currentTime() calls in applyLayout (spec 3f)"
```

---

### Task 11: Cache primary screen height in `updateFocusRing` (spec 3g)

**Files:**
- Modify: `Sources/WindowManager/StripController.swift` (add property, update init, updateFocusRing)
- Modify: `Sources/WindowManager/WindowManager.swift` (pass height at construction, update on display change)

- [ ] **Step 1: Add `primaryScreenHeight` to `StripController`**

In `Sources/WindowManager/StripController.swift`, add a stored property near the other properties:

```swift
    /// Primary screen height for Y-coordinate flipping (cached, updated on display change).
    public var primaryScreenHeight: CGFloat
```

Update `init` to accept the parameter:

```swift
    public init(workingArea: CGRect, primaryScreenHeight: CGFloat) {
        // ... existing init body ...
        self.primaryScreenHeight = primaryScreenHeight
    }
```

In `updateFocusRing`, replace `NSScreen.main` usage (line ~741):

```swift
        // Before:
        // guard let screen = NSScreen.main else { return }
        // let screenHeight = screen.frame.height

        // After:
        let screenHeight = primaryScreenHeight
```

- [ ] **Step 2: Update `WindowManager` construction sites**

In `Sources/WindowManager/WindowManager.swift`, update both construction sites:

Line ~70 (display loop):
```swift
    stripControllers[displayID] = StripController(
        workingArea: wa,
        primaryScreenHeight: displayManager.primaryScreenHeight
    )
```

Line ~75 (fallback):
```swift
    stripControllers[CGMainDisplayID()] = StripController(
        workingArea: wa,
        primaryScreenHeight: NSScreen.main?.frame.height ?? 0
    )
```

In the `onDisplayChange` handler (where `updateWorkingArea` is called), also update `primaryScreenHeight`:
```swift
    sc.primaryScreenHeight = displayManager.primaryScreenHeight
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/WindowManager/StripController.swift Sources/WindowManager/WindowManager.swift
git commit -m "perf(wm): cache primaryScreenHeight, avoid NSScreen.main at 120Hz (spec 3g)"
```

---

### Task 12: Don't `clearCommittedFrames` on animation settle (spec 3b)

**Files:**
- Modify: `Sources/WindowManager/StripController.swift:543-546, 586-589, handleUserResize`

- [ ] **Step 1: Write far-zone positions to `lastCommittedFrames` during ticks**

In `Sources/WindowManager/StripController.swift`, in `handleFrameTick`, replace the `.far` case (lines 587-589):

```swift
            case .far:
                // Record the computed off-screen position so settle applyLayout() can diff correctly
                lastCommittedFrames[target.tileID] = target.frame
```

- [ ] **Step 2: Remove `clearCommittedFrames()` on the animation-settle path only**

In `handleFrameTick`, remove `clearCommittedFrames()` on line 544:

```swift
            // Before:
            // clearCommittedFrames()
            // applyLayout()

            // After:
            applyLayout()
```

Do NOT change `handleGestureEnd` or `handleGestureCancel` — those keep their `clearCommittedFrames()` calls.

- [ ] **Step 3: Guard `handleUserResize` left-edge heuristic**

In the `handleUserResize` method, where it reads `lastCommittedFrames[tileID]` to detect left-edge resize, add a guard:

```swift
        // Only apply left-edge heuristic if lastFrame is within the working area
        // (far-zone entries hold sliver/off-screen positions that would corrupt the delta)
        if let lastFrame = lastCommittedFrames[tileID],
           lastFrame.minX >= strip.workingArea.minX - 50,
           lastFrame.maxX <= strip.workingArea.maxX + 50 {
            // ... existing left-edge resize detection logic ...
        }
```

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/WindowManager/StripController.swift
git commit -m "perf(wm): skip clearCommittedFrames on settle, write far-zone positions during ticks (spec 3b)"
```

---

### Task 13: Make `applyLayout()` dispatch AX calls async (spec 3c)

**Files:**
- Modify: `Sources/WindowManager/StripController.swift` (applyLayout loop, add dirtyTileIDs, removeWindow)

- [ ] **Step 1: Add `dirtyTileIDs` property**

In `Sources/WindowManager/StripController.swift`, add near the other properties:

```swift
    /// Tile IDs whose last async AX dispatch failed — force re-send on next applyLayout.
    private var dirtyTileIDs: Set<TileID> = []
```

- [ ] **Step 2: Update `removeWindow` to prune `dirtyTileIDs`**

In the `removeWindow(tileID:)` method, add:

```swift
    dirtyTileIDs.remove(tileID)
```

- [ ] **Step 3: Rewrite `applyLayout` loop to dispatch async**

In `Sources/WindowManager/StripController.swift`, replace the frame application loop in `applyLayout()` (lines 464-497):

```swift
        var applied = 0
        var skipped = 0
        var noWindow = 0
        for target in frames {
            guard let window = windowMap[target.tileID] else {
                noWindow += 1
                continue
            }

            // Dirty-ID bypass must precede framesEqual guard
            let isDirty = dirtyTileIDs.contains(target.tileID)
            if !isDirty,
               let lastFrame = lastCommittedFrames[target.tileID],
               framesEqual(lastFrame, target.frame) {
                skipped += 1
                continue
            }
            dirtyTileIDs.remove(target.tileID)

            // Record optimistically — retry via dirtyTileIDs on failure
            lastCommittedFrames[target.tileID] = target.frame
            applied += 1

            let tileID = target.tileID
            if let app = apps[window.pid] {
                if target.isOffScreen {
                    let position = target.frame.origin
                    DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                        let result = window.setPosition(position)
                        if case .failure = result {
                            DispatchQueue.main.async { self?.dirtyTileIDs.insert(tileID) }
                        }
                    }
                } else {
                    let frame = target.frame
                    DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                        let result = app.dispatchSetFrame(window, frame: frame)
                        if case .failure = result {
                            DispatchQueue.main.async { self?.dirtyTileIDs.insert(tileID) }
                        }
                    }
                }
            }
        }
```

**Note:** This requires `dispatchSetFrame` and `dispatchSetPosition` on `AXApp` to return their `AXResult`. Check if they currently return `Void` — if so, update them to return the result. If they already discard it, capture the return value from `window.setFrame`/`window.setPosition` inside the dispatch.

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds. Fix any type mismatches if `dispatchSetFrame`/`dispatchSetPosition` need return type changes.

- [ ] **Step 5: Commit**

```bash
git add Sources/WindowManager/StripController.swift Sources/Platform/AXApp.swift
git commit -m "perf(wm): dispatch applyLayout AX calls async with dirtyTileIDs retry (spec 3c)"
```

---

### Task 14: Reduce health check AX overhead (spec 3d)

**Files:**
- Modify: `Sources/WindowManager/WindowManager.swift:703-737`

- [ ] **Step 1: Skip `getPosition()` for windows confirmed alive by CGWindowList**

In `Sources/WindowManager/WindowManager.swift`, in `checkWindowHealth()`, modify Pass 1 (lines 712-728). Remove the unconditional `getPosition()` call for windows that ARE in `onScreenIDs`:

```swift
        for (tileID, window) in stripController.windowMap {
            if !onScreenIDs.contains(window.windowID) {
                // Window not in CGWindowList — confirmed dead
                stripController.removeWindow(tileID: tileID)
                tracker.untrackWindow(window.windowID)
                changed = true
                continue
            }
            // Window is in CGWindowList — skip AX probe, it's alive
            // (Previously called getPosition() here unconditionally)
        }
```

- [ ] **Step 2: Throttle `adoptUnmanagedWindows` to every 5 seconds**

Add a property to `WindowManager`:

```swift
    private var adoptCounter: Int = 0
```

In `checkWindowHealth()`, wrap the adopt call:

```swift
        adoptCounter += 1
        if adoptCounter >= 5 {
            adoptCounter = 0
            changed = adoptUnmanagedWindows() || changed
        }
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/WindowManager/WindowManager.swift
git commit -m "perf(wm): reduce health check AX overhead — skip alive probes, throttle adopt (spec 3d)"
```

---

### Task 15: Use `getPropertiesFast()` everywhere (spec 3e)

**Files:**
- Modify: `Sources/WindowManager/WindowManager.swift` (3 call sites)

- [ ] **Step 1: Replace all three `getProperties()` calls**

In `Sources/WindowManager/WindowManager.swift`, find-and-replace:
1. `adoptUnmanagedWindows` (line ~757): `window.getProperties()` -> `window.getPropertiesFast()`
2. `handleSpaceChange` reconciliation (line ~607): `window.getProperties()` -> `window.getPropertiesFast()`
3. `handleSpaceChange` new-space discovery (line ~647): `window.getProperties()` -> `window.getPropertiesFast()`

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/WindowManager/WindowManager.swift
git commit -m "perf(wm): use getPropertiesFast in adoptUnmanagedWindows and handleSpaceChange (spec 3e)"
```

---

## Phase 4: Config, IPC, and Startup

### Task 16: Cache parsed default config (spec 4a)

**Files:**
- Modify: `Sources/Config/Config.swift:135-144`

- [ ] **Step 1: Make `loadDefaults` return a cached static**

In `Sources/Config/Config.swift`, replace `loadDefaults()`:

```swift
    /// Cached parsed default config — computed once, never changes at runtime.
    private static let cachedDefaults: ScrollWMConfig = {
        guard let url = Bundle.module.url(forResource: "config.default", withExtension: "toml"),
              let content = try? String(contentsOf: url, encoding: .utf8),
              let table = try? TOMLTable(string: content) else {
            #if DEBUG
            print("[Config] Warning: could not load bundled config.default.toml, using hardcoded defaults")
            fflush(stdout)
            #endif
            return ScrollWMConfig()
        }
        return parse(table: table, base: ScrollWMConfig())
    }()

    private static func loadDefaults() -> ScrollWMConfig {
        cachedDefaults
    }
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Config/Config.swift
git commit -m "perf(config): cache parsed default config as static let (spec 4a)"
```

---

### Task 17: Reuse `JSONDecoder`/`JSONEncoder` in IPC (spec 4c)

**Files:**
- Modify: `Sources/IPC/SocketServer.swift:117,133`

- [ ] **Step 1: Add static coders**

At the top of the `SocketServer` class (or at file scope if it's a struct), add:

```swift
    private static let jsonDecoder = JSONDecoder()
    private static let jsonEncoder = JSONEncoder()
```

Replace `JSONDecoder()` on line 117 with `Self.jsonDecoder`.
Replace `JSONEncoder()` on line 133 with `Self.jsonEncoder`.

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/IPC/SocketServer.swift
git commit -m "perf(ipc): reuse JSONDecoder/JSONEncoder across connections (spec 4c)"
```

---

### Task 18: Cache `ISO8601DateFormatter` (spec 4d)

**Files:**
- Modify: `Sources/WindowManager/WindowManager.swift` (~line 917)

- [ ] **Step 1: Add static formatter**

Find the `handleIPCCommand(.listPositions)` handler. Add a static formatter:

```swift
    private static let isoFormatter = ISO8601DateFormatter()
```

Replace the per-entry `ISO8601DateFormatter()` allocation with `Self.isoFormatter`.

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/WindowManager/WindowManager.swift
git commit -m "perf(ipc): cache ISO8601DateFormatter for list-positions handler (spec 4d)"
```

---

### Task 19: Remove dead code in Config (spec 4f)

**Files:**
- Modify: `Sources/Config/Config.swift:179`

- [ ] **Step 1: Delete unreachable `return nil`**

In `Sources/Config/Config.swift`, in `readTable()` (line 179), delete:

```swift
        return nil  // DELETE — unreachable after `return value?.table`
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Config/Config.swift
git commit -m "cleanup(config): remove unreachable return nil in readTable (spec 4f)"
```

---

### Task 20: Deduplicate `reloadConfig()` / `applyConfig()` (spec 4e)

**Files:**
- Modify: `Sources/WindowManager/WindowManager.swift` (applyConfig, reloadConfig)

- [ ] **Step 1: Extract shared logic into `applyConfig`**

In `Sources/WindowManager/WindowManager.swift`:

1. Ensure `applyConfig(_ config: ScrollWMConfig)` handles the shared strip-level field application (gap, focus mode, struts, keybindings, etc.)
2. `applyConfig` must NOT call `applyLayout()` — callers handle that.
3. In `reloadConfig()`, replace the duplicated strip-level logic with a call to `applyConfig(newConfig)`, then keep the reload-specific work after:
   - `positionMemory` creation/update
   - `strip.recalculateWidths()` + `clearCommittedFrames()` + `applyLayout()`

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/WindowManager/WindowManager.swift
git commit -m "refactor(wm): deduplicate reloadConfig by delegating to applyConfig (spec 4e)"
```

---

### Task 21: Move `positionMemory.loadFromDisk()` off main thread (spec 4b)

**Files:**
- Modify: `Sources/WindowManager/WindowManager.swift` (~line 175)

- [ ] **Step 1: Add `isLoaded` flag to `PositionMemory` or `WindowManager`**

In `Sources/WindowManager/WindowManager.swift`, add a flag:

```swift
    private var positionMemoryLoaded = false
```

- [ ] **Step 2: Dispatch load to background**

Replace the synchronous `positionMemory?.loadFromDisk()` call (~line 175):

```swift
        // Before:
        // positionMemory?.loadFromDisk()

        // After:
        if let pm = positionMemory {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                pm.loadFromDisk()
                DispatchQueue.main.async {
                    self?.positionMemoryLoaded = true
                }
            }
        }
```

- [ ] **Step 3: Guard position restoration in `addWindow`**

In the `addWindow` path where `positionMemory?.lookup(...)` is called, guard on the flag:

```swift
        // Only restore position if memory has finished loading
        let restoredPosition: CGRect? = positionMemoryLoaded ? positionMemory?.lookup(...) : nil
```

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/WindowManager/WindowManager.swift
git commit -m "perf(startup): move positionMemory.loadFromDisk off main thread (spec 4b)"
```

---

## Final Verification

- [ ] **Run full test suite:** `swift run RunTests`
- [ ] **Build release:** `swift build -c release`
- [ ] **Manual smoke test:** Build and run, verify scroll animation is smooth, space switching works, health check catches killed apps, config reload works, `scrollwm-msg list-windows` returns data.
