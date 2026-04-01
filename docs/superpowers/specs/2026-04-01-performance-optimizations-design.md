# ScrollWM Performance Optimizations

## Overview

Comprehensive performance sweep across all five modules, ordered bottom-up by dependency layer: Core -> Platform -> WindowManager -> Config/IPC. Targets three classes of problem: frame-loop hot path (animation smoothness at 120Hz), AX call overhead (per-frame during animation, per-second at idle), and startup/allocation waste.

## Section 1: Core Module

All changes are to pure functions with no AX or AppKit dependencies. Fully testable via `swift run RunTests`.

### 1a. Fuse two-pass layout loop in `computeTargetFrames`

**File:** `Sources/Core/LayoutEngine.swift`

Currently two passes over columns: first builds `columnPositions` array calling `currentWidth(at:)` per column, second iterates `columnPositions` calling `currentWidth(at:)` again. This doubles spring `solve()` calls per frame.

**Change:** Single fused loop. Accumulate `x` position inline, compute `colWidth` once, build `TargetFrame` results directly. Eliminate the `columnPositions` intermediate array. Add `reserveCapacity(strip.columns.count)` on the results array. Refactor `computeTileFrames` to take an `inout [TargetFrame]` accumulator instead of returning a heap-allocated array.

**Impact:** Eliminates N redundant `solve()` calls per frame (each involves transcendental math: `exp()`, `sqrt()`, `sin()`/`cos()`). Removes one per-frame array allocation. Removes N per-frame tile-array allocations.

### 1b. Merge `isDone()` + `evaluate()` into single `solve()` call

**Files:** `Sources/Core/Animation.swift`, `Sources/Core/Column.swift`, `Sources/Core/ViewOffset.swift`

`ColumnData.currentWidth(at:)` calls `isDone()` (which calls `solve()`) then `evaluate()` (which calls `solve()` again). Same pattern exists in `ViewOffset.isSettled(at:)`.

**Change:** Add `evaluateWithStatus(at:) -> (value: Double, isDone: Bool)` on `SpringAnimation`. Calls `solve()` once, returns both the interpolated value and whether displacement+velocity are below epsilon. Update `ColumnData.currentWidth(at:)` to use it — if done, set `cachedWidth` and nil the animation in one pass. Update `ViewOffset` to use it where both value and convergence status are needed.

**Impact:** Halves the number of `solve()` calls per animated column per frame.

### 1c. Precompute spring constants in `SpringParams.init`

**File:** `Sources/Core/Animation.swift`

`solve()` recomputes on every call:
- `beta = damping / (2 * mass)`
- `omega0 = sqrt(stiffness / mass)`
- Damping regime check: `abs(beta*beta - omega0*omega0) < 1e-10`

These are constant for the lifetime of a `SpringParams` instance.

**Change:** Store precomputed values in `SpringParams`:
- `beta: Double`
- `omega0: Double`
- `regime: enum { case critical, overdamped(omegaBar: Double), underdamped(omegaD: Double) }`

The regime enum carries the precomputed derived constant for its branch (`omegaBar = sqrt(beta^2 - omega0^2)` or `omegaD = sqrt(omega0^2 - beta^2)`), eliminating the per-call `sqrt` in the branch body.

**Impact:** Removes 1 `sqrt` + 2 multiplications + 1 division + 1 branch comparison per `solve()` call. For underdamped/overdamped regimes, removes an additional `sqrt` per call.

### 1d. Merge `settleWidthAnimations` + `hasActiveWidthAnimations`

**Files:** `Sources/Core/Strip.swift`, `Sources/WindowManager/StripController.swift`

Two separate full-column scans per frame: `settleWidthAnimations(at:)` nils out done animations, then `hasActiveWidthAnimations(at:)` re-scans to check if any remain.

**Change:** Replace both with `settleWidthAnimations(at:) -> Bool` that returns `true` if any active animations remain after settling. Single pass.

**Impact:** Eliminates one O(N) column scan per frame.

### 1e. Remove dead code

**File:** `Sources/Core/Animation.swift`
- Remove dead `velocity` binding in critically-damped `solve()` branch (computed but shadowed by `vel`, never read).

**File:** `Sources/Core/LayoutEngine.swift`
- Remove unused `viewLeft` / `viewRight` variables.

## Section 2: Platform Module

### 2a. Consolidate `currentTime()` into a shared utility

**Files:** `Sources/WindowManager/StripController.swift`, `Sources/Platform/GestureCapture.swift`, `Sources/Platform/AXApp.swift`

Three independent implementations each call `mach_timebase_info()` on every invocation. The numer/denom ratio is constant for the process lifetime.

**Change:** Create `Sources/Core/TimeUtil.swift` (Core has no AppKit dependency):
```swift
public enum TimeUtil {
    private static let ratio: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    public static func now() -> Double {
        Double(mach_absolute_time()) * ratio
    }
}
```

Replace all three `currentTime()` / `CACurrentMediaTime()` implementations with `TimeUtil.now()`.

**Impact:** Eliminates per-call `mach_timebase_info` syscall overhead. Removes the `CACurrentMediaTime` shadow in `AXApp.swift` that hides the more efficient system function.

### 2b. Cache `AXEnhancedUserInterface` settability per window

**File:** `Sources/Platform/AXWindow.swift`

`toggleEnhancedUI` calls `AXUIElementIsAttributeSettable` on every `setFrame`. For Electron apps this adds 6 extra AX IPC calls per `setFrame`. The answer is constant for the lifetime of a window element.

**Change:** Add a `lazy var isEnhancedUISettable: Bool` on `AXWindow`, computed on first access via `AXUIElementIsAttributeSettable`, cached thereafter. `toggleEnhancedUI` checks the cached value and returns immediately if false.

**Impact:** Saves up to 72 AX IPC calls per Electron window per animation cycle (36 frames x 2 toggles). For native apps (where settable is false), saves 1 AX call per `setFrame`.

### 2c. Fix `AXApp.stopObserving` TOCTOU race

**File:** `Sources/Platform/AXApp.swift`

`stopObserving` checks `if let rl = runLoop` but `runLoop` is set asynchronously by the observer thread. If called before the thread starts, `CFRunLoopStop` is never called and the background thread runs indefinitely.

**Change:** Add synchronization so `stopObserving` waits for the thread to set `runLoop` before attempting `CFRunLoopStop`. Use a `DispatchSemaphore` with a short timeout (e.g., 500ms) to avoid deadlock if the thread never starts.

### 2d. Delete `CACurrentMediaTime` shadow

**File:** `Sources/Platform/AXApp.swift`

After 2a consolidates timing, remove the private `CACurrentMediaTime()` function entirely. Any remaining callers use `TimeUtil.now()`.

## Section 3: WindowManager Module

### 3a. Gate debug logging behind `#if DEBUG`

**Files:** `Sources/WindowManager/StripController.swift`, `Sources/WindowManager/WindowManager.swift`, `Sources/WindowManager/WindowTracker.swift`, and others

Zero `#if DEBUG` guards in the entire codebase. `print()` + `fflush(stdout)` fires at 60-120Hz during animations (`updateFocusRing`, per-window in `applyLayout`). Swift's `print` takes a global lock.

**Change:** Wrap all diagnostic/coordinate prints in `#if DEBUG`. For frame-tick and `applyLayout` hot paths, remove per-window coordinate prints entirely (use Instruments for profiling, not stdout). Keep structural prints (startup banner, window add/remove, space switch) but gate them behind `#if DEBUG`.

**Impact:** Eliminates global-lock contention and syscall overhead at 120Hz. Likely the single biggest win for animation smoothness.

### 3b. Don't `clearCommittedFrames()` before settle `applyLayout()`

**File:** `Sources/WindowManager/StripController.swift`

On animation settle, `clearCommittedFrames()` + `applyLayout()` forces re-sending every window's frame, defeating the `framesEqual` diff logic.

**Change:** Remove the `clearCommittedFrames()` call on the settle path. Let `applyLayout`'s existing diff skip unchanged windows. Only clear committed frames on structural changes (window add/remove, column reorder, space switch).

**Impact:** Reduces settle-frame AX calls from N to ~1-2 (only the windows that actually moved during the last animation frame).

### 3c. Make `applyLayout()` dispatch AX calls async

**File:** `Sources/WindowManager/StripController.swift`

`applyLayout()` runs N synchronous `setFrame` calls on main thread. For 10 Electron windows worst case: ~300ms blocking main.

**Change:** Dispatch `setFrame`/`setPosition` calls to GCD pool (same pattern as `handleFrameTick`'s dispatch). Keep `lastCommittedFrames` write synchronous on main. Track dispatch success: if the AX call fails (background thread), mark the tileID dirty so the next layout pass retries.

**Impact:** Unblocks main thread during layout. AX calls run in parallel across apps.

### 3d. Reduce health check AX overhead

**File:** `Sources/WindowManager/WindowManager.swift`

`checkWindowHealth` calls `getPosition()` on every alive window every second. `adoptUnmanagedWindows` calls `discoverWindows()` for every app every second.

**Change:**
- Skip `getPosition()` for windows confirmed alive by `CGWindowList`. Only AX-probe windows present in `windowMap` but absent from `onScreenIDs`.
- Reduce `adoptUnmanagedWindows` frequency to every 5 seconds instead of every 1 second.

**Impact:** Reduces idle AX calls from O(N windows + M apps) per second to O(dead windows) per second + O(M apps) per 5 seconds.

### 3e. Use `getPropertiesFast()` in `adoptUnmanagedWindows`

**File:** `Sources/WindowManager/WindowManager.swift`

Simple substitution: `getProperties()` (8 AX reads) -> `getPropertiesFast()` (5 AX reads).

**Impact:** Saves 3 AX calls per adopted window.

### 3f. Deduplicate `currentTime()` calls in `applyLayout()`

**File:** `Sources/WindowManager/StripController.swift`

Two back-to-back `currentTime()` calls at lines 452 and 454.

**Change:** Single `let time = currentTime()` used for both `lastLayoutTime` and `computeTargetFrames`.

### 3g. Cache `NSScreen.main` height in `updateFocusRing`

**File:** `Sources/WindowManager/StripController.swift`

Re-queries `NSScreen.main` every vsync frame for Y-flip.

**Change:** Use `DisplayManager.primaryScreenHeight` (already maintained on display change events) instead of querying `NSScreen.main` at 120Hz.

## Section 4: Config, IPC, and Startup

### 4a. Cache parsed default config

**File:** `Sources/Config/Config.swift`

`ScrollWMConfig.load()` re-parses bundled `config.default.toml` from disk on every call.

**Change:** `private static let defaultTable: TOMLTable = { ... parse from bundle ... }()`. Subsequent `load()` calls start from the cached default.

### 4b. Move `positionMemory.loadFromDisk()` off main thread

**File:** `Sources/WindowManager/WindowManager.swift`

Blocks main thread synchronously during startup.

**Change:** Dispatch to background queue. Add a `isLoaded` flag. If `addWindow` fires before load completes, skip position restoration for that window (it gets a fresh position).

### 4c. Reuse `JSONDecoder`/`JSONEncoder` in IPC

**File:** `Sources/IPC/SocketServer.swift`

Allocated per connection.

**Change:** `static let decoder = JSONDecoder()` and `static let encoder = JSONEncoder()` on the server.

### 4d. Cache `ISO8601DateFormatter` in IPC handler

**File:** `Sources/WindowManager/WindowManager.swift`

Allocated per entry in `list-positions`.

**Change:** `static let` — one instance reused.

### 4e. Deduplicate `reloadConfig()` / `applyConfig()`

**File:** `Sources/WindowManager/WindowManager.swift`

`reloadConfig()` copy-pastes `applyConfig()` logic.

**Change:** Have `reloadConfig()` call `applyConfig(newConfig)` for shared logic, then handle reload-specific work after.

### 4f. Remove dead code in Config

**File:** `Sources/Config/Config.swift`

Unreachable `return nil` after `return value?.table` in `readTable()`.

## Implementation Order

1. **Core** (1a-1e) — pure functions, test with `swift run RunTests`
2. **Platform** (2a-2d) — timing consolidation, AX caching, race fix
3. **WindowManager** (3a-3g) — logging, dispatch, health check
4. **Config/IPC** (4a-4f) — caching, dedup, startup

Each section is a natural commit/review boundary.

## Testing Strategy

- **Core changes:** `swift run RunTests` — existing test suite covers layout, springs, and animations
- **Platform changes:** Manual — build and run, verify animations still smooth, verify Electron app windows resize correctly
- **WindowManager changes:** Manual — verify space switching, health check still catches dead windows (kill an app), animation settle still snaps correctly
- **Config/IPC changes:** Manual — `scrollwm-msg list-windows`, config reload via menu bar

## Risks

- **3c (async `applyLayout`)** is the highest-risk change. If AX calls complete out of order, windows could briefly flash at wrong positions. Mitigated by the `lastCommittedFrames` diff logic and the existing tolerance for async dispatch in `handleFrameTick`.
- **3b (no `clearCommittedFrames` on settle)** could cause windows to be stuck at stale positions if `lastCommittedFrames` has a wrong entry. Mitigated by the fact that `handleFrameTick` updates `lastCommittedFrames` on every dispatched frame.
- **1b (`evaluateWithStatus`)** changes the settle semantics for width animations — need to verify the `cachedWidth` invariant (any `cachedWidth` write must nil `widthAnimation`) is preserved.
