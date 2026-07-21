import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Core
import Config
import Platform
import WindowManager

// ============================================================
// MARK: - Layer-2 simulation harness
//
// Real `StripController` driven against subclass fakes of the now-`open`
// `AXWindow` / `AXApp`. Single-threaded, virtual-clock (`TestClock` →
// `TimeUtil.nowProvider`), inline frame-dispatch. No real windows, no CFRunLoop
// thread, no wall-clock. Every AX-touching method is overridden so the dummy
// `AXUIElement` (from `AXUIElementCreateApplication(pid)`) is never messaged for
// anything StripController exercises.
//
// These types live only in the test target; production never subclasses the
// `open` classes.
// ============================================================

/// Fake window. Records every applied frame, exposes failure knobs.
final class FakeAXWindow: AXWindow, @unchecked Sendable {
    /// The window's current frame — updated by every successful set.
    var currentFrame: CGRect
    var titleValue: String?
    var closed = false
    var raiseCount = 0
    var focusCount = 0
    /// Every frame the fake actually committed (in order).
    private(set) var frameLog: [CGRect] = []

    /// One-shot transient failure on the next set → exercises `dirtyTileIDs` retry.
    var failNextSet = false
    /// Models an app that refuses off-screen positioning. In instant `applyLayout`,
    /// `setPosition` is only ever called for OFF-SCREEN tiles (on-screen tiles use
    /// `setFrame`), so failing every `setPosition` fails exactly the off-screen
    /// (sliver) writes. NOTE: there is NO corner-hide fallback in production (see
    /// SimFocusTests "off-screen sliver …") — the write simply stays dirty.
    var resistsOffscreen = false
    /// Minimum size clamp applied in `apply` → models a macOS size constraint.
    var minSize: CGSize = .zero

    init(windowID: CGWindowID, pid: pid_t, frame: CGRect, title: String? = "w") {
        self.currentFrame = frame
        self.titleValue = title
        // Dummy element: never messaged because every AX-touching method below
        // is overridden. (super.init issues one IsAttributeSettable probe against
        // the dead pid, which fails fast — no real app is contacted.)
        super.init(element: AXUIElementCreateApplication(pid), windowID: windowID, pid: pid)
    }

    override func getFrame() -> AXResult<CGRect> { .success(currentFrame) }

    override func setFrame(_ frame: CGRect) -> AXResult<Void> { apply(frame) }

    override func setPosition(_ point: CGPoint) -> AXResult<Void> {
        if resistsOffscreen { return .failure(.transientFailure(.failure)) }
        return apply(CGRect(origin: point, size: currentFrame.size))
    }

    override func setSize(_ size: CGSize) -> AXResult<Void> {
        apply(CGRect(origin: currentFrame.origin, size: size))
    }

    override func getPosition() -> AXResult<CGPoint> { .success(currentFrame.origin) }
    override func getSize() -> AXResult<CGSize> { .success(currentFrame.size) }

    private func apply(_ frame: CGRect) -> AXResult<Void> {
        if failNextSet {
            failNextSet = false
            return .failure(.transientFailure(.failure))
        }
        var g = frame
        g.size.width = max(g.size.width, minSize.width)
        g.size.height = max(g.size.height, minSize.height)
        currentFrame = g
        frameLog.append(g)
        return .success(())
    }

    override func getTitle() -> String? { titleValue }
    override func getRole() -> String? { "AXWindow" }
    override func getSubrole() -> String? { "AXStandardWindow" }
    override func isMinimized() -> Bool { false }
    override func isFullscreen() -> Bool { false }
    override func isResizable() -> Bool { true }
    override func hasCloseButton() -> Bool { true }
    override func hasMinimizeButton() -> Bool { true }
    override func hasZoomButton() -> Bool { true }

    override func raise() -> AXResult<Void> { raiseCount += 1; return .success(()) }
    override func close() -> AXResult<Void> { closed = true; return .success(()) }
    override func focus() { focusCount += 1 }
}

/// Fake app. Overrides observation to no-ops so no CFRunLoop thread spawns.
/// `dispatchSet*` are inherited (they just call `window.setFrame`/`setPosition`
/// synchronously, which the fake window handles).
final class FakeAXApp: AXApp, @unchecked Sendable {
    override func startObserving() {}
    override func stopObserving() {}
    override func observeWindow(_ element: AXUIElement) {}
    override func unobserveWindow(_ element: AXUIElement) {}
}

/// Virtual monotonic clock. `install()` routes `TimeUtil.now()` through it.
final class TestClock: @unchecked Sendable {
    var t: Double
    init(_ t0: Double = 1000) { t = t0 }
    func advance(_ dt: Double) { t += dt }
    func install() { TimeUtil.nowProvider = { [unowned self] in self.t } }
}

/// Reference box so a `@Sendable` frame-dispatch closure can capture accumulated
/// drain blocks without capturing a mutable local (which `@Sendable` forbids).
final class Capture: @unchecked Sendable {
    var blocks: [@Sendable () -> Void] = []
    func run(_ i: Int) { blocks[i]() }
    func runAll() { for b in blocks { b() } }
}

// MARK: - Builders

private let stdWorkingArea = CGRect(x: 0, y: 25, width: 1440, height: 875)

/// Monotonic pid source — high values avoid colliding with any real process.
private var nextFakePid: pid_t = 90000
private func freshPid() -> pid_t { nextFakePid += 1; return nextFakePid }

/// Build a StripController wired for single-threaded virtual-clock testing:
/// overlay suppressed, inline frame-dispatch + main-hop, animation toggle as asked.
func makeSC(
    animationEnabled: Bool = false,
    workingArea: CGRect = stdWorkingArea,
    primaryScreenHeight: CGFloat = 900
) -> StripController {
    let sc = StripController(workingArea: workingArea, primaryScreenHeight: primaryScreenHeight)
    sc.focusIndicator.overlaySuppressed = true
    sc.animationEnabled = animationEnabled
    sc.frameDispatch = { _, work in work() }
    sc.mainHop = { work in work() }
    return sc
}

/// Add `count` fake windows (all under one fake app) to `sc`, sized to sit inside
/// the working area. Returns the windows in insertion order.
@discardableResult
func addFakeWindows(
    _ sc: StripController,
    count: Int,
    width: CGFloat = 700,
    app: FakeAXApp? = nil
) -> (app: FakeAXApp, windows: [FakeAXWindow]) {
    let a = app ?? FakeAXApp(pid: freshPid(), bundleIdentifier: "test.app")
    var out: [FakeAXWindow] = []
    for i in 0..<count {
        let w = FakeAXWindow(
            windowID: CGWindowID(i + 1),
            pid: a.pid,
            frame: CGRect(x: 0, y: 25, width: width, height: 850),
            title: "w\(i + 1)"
        )
        sc.addWindow(w, app: a)
        out.append(w)
    }
    return (a, out)
}

// MARK: - Settle helper

/// Advance the virtual clock frame-by-frame, ticking `sc`, until fully settled or
/// the hard cap is hit. On non-convergence, fails loudly with a state dump — hangs
/// become assertions (Determinism rule #4).
func settle(_ sc: StripController, _ clock: TestClock, maxSeconds: Double = 5, hz: Double = 60) {
    let step = 1.0 / hz
    var elapsed = 0.0
    while elapsed < maxSeconds {
        clock.advance(step)
        sc.handleFrameTick(time: clock.t)
        elapsed += step
        if sc.isFullySettled { return }
    }
    check(false, "settle() exceeded \(maxSeconds)s — cols=\(sc.strip.columns.count), "
        + "viewOffset unsettled, dirty=\(sc.debugDirtyCount)")
}
