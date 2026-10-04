import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Core
import Platform

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
    /// One-shot: the next set times out, as a busy app's does.
    var timeoutNextSet = false
    /// Models an app that refuses off-screen positioning. In instant `applyLayout`,
    /// `setPosition` is only ever called for OFF-SCREEN tiles (on-screen tiles use
    /// `setFrame`), so failing every `setPosition` fails exactly the off-screen
    /// (sliver) writes. NOTE: there is NO corner-hide fallback in production (see
    /// SimFocusTests "off-screen sliver …") — the write simply stays dirty.
    var resistsOffscreen = false
    /// Minimum size clamp applied in `apply` → models a macOS size constraint.
    var minSize: CGSize = .zero
    /// One-shot: the user drags the window this far right after the next set lands, before anyone reads it back.
    var dragAfterNextSet: CGFloat?

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
        if timeoutNextSet {
            timeoutNextSet = false
            return .failure(.appUnresponsive)
        }
        if failNextSet {
            failNextSet = false
            return .failure(.transientFailure(.failure))
        }
        var g = frame
        g.size.width = max(g.size.width, minSize.width)
        g.size.height = max(g.size.height, minSize.height)
        currentFrame = g
        frameLog.append(g)
        if let drag = dragAfterNextSet {
            dragAfterNextSet = nil
            currentFrame.origin.x += drag
        }
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
    override func focus(timeout: Float?) { focusCount += 1 }
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
