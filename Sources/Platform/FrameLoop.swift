import AppKit
import QuartzCore
import CoreGraphics
import Foundation

/// Per-monitor CADisplayLink wrapper for vsync-driven animation.
/// Pauses automatically when idle to save battery.
///
/// A `CADisplayLink` created from an `NSScreen` is tied to that physical
/// display: when the display disconnects its callbacks stop and the link is
/// invalidated permanently. To survive hot-plug / dock / lid-close events,
/// `FrameLoop` observes `NSApplication.didChangeScreenParametersNotification`
/// and rebinds the link onto a live screen whenever the bound display goes
/// away (or appears for the first time), preserving the running/paused state.
public final class FrameLoop: @unchecked Sendable {

    /// Called every frame with the target timestamp (seconds).
    public var onTick: ((Double) -> Void)?

    /// Whether the frame loop is currently ticking (link exists and unpaused).
    public private(set) var isRunning: Bool = false

    /// Caller intent, independent of whether a live link currently exists.
    /// resume() sets it true, pause() sets it false. On a rebind the new link
    /// inherits this so an in-flight animation keeps ticking across a display
    /// disconnect, and a resume() issued while no display is present takes
    /// effect the moment a display reconnects.
    private var desiredRunning: Bool = false

    private var displayLink: CADisplayLink?

    /// The display the current link is bound to, so we can detect when *that*
    /// specific display disconnects (vs. benign screen-parameter changes).
    private var boundDisplayID: CGDirectDisplayID?

    /// Token for the screen-reconfiguration notification observer.
    private var screenObserver: NSObjectProtocol?

    /// Weak target wrapper to prevent retain cycle.
    /// CADisplayLink retains its target, so we use an intermediary.
    private var targetWrapper: DisplayLinkTarget?

    public init() {}

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Register for display changes and create the display link on the main
    /// run loop. Safe to call before any display is available (clamshell boot):
    /// the link is created lazily once a screen appears.
    public func start() {
        registerScreenObserver()
        createLinkOnCurrentScreen()
    }

    /// Remove the display link entirely and stop observing display changes.
    public func stop() {
        unregisterScreenObserver()
        displayLink?.invalidate()
        displayLink = nil
        boundDisplayID = nil
        targetWrapper = nil
        isRunning = false
        desiredRunning = false
    }

    /// Resume ticking (called when animation starts).
    public func resume() {
        desiredRunning = true
        guard let link = displayLink else {
            // No live link (bound display gone, or none present yet). Ticking
            // will begin automatically when a screen appears via the rebind path.
            return
        }
        guard link.isPaused else { return }  // already running
        link.isPaused = false
        isRunning = true
    }

    /// Pause ticking (called when animation settles).
    public func pause() {
        desiredRunning = false
        guard let link = displayLink else {
            isRunning = false
            return
        }
        guard !link.isPaused else { return }  // already paused
        link.isPaused = true
        isRunning = false
    }

    // MARK: - Display Link Creation / Rebind

    /// Create the display link on the current `NSScreen.main` if one doesn't
    /// already exist. Honors `desiredRunning` for the initial pause state, so a
    /// resume() issued before any screen was present takes effect immediately.
    private func createLinkOnCurrentScreen() {
        guard displayLink == nil else { return }
        guard let screen = NSScreen.main else {
            // Nothing to tick against. Keep `desiredRunning` so a reconnect
            // resumes automatically, but `isRunning` must reflect reality.
            isRunning = false
            print("[FrameLoop] No screen available — deferring link creation")
            fflush(stdout)
            return
        }

        let target = targetWrapper ?? DisplayLinkTarget(frameLoop: self)
        targetWrapper = target

        let link = screen.displayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))

        // Request highest refresh rate (120Hz on ProMotion displays)
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30,
            maximum: 120,
            preferred: 120
        )

        // Inherit the desired running state (paused on a fresh start).
        link.isPaused = !desiredRunning

        link.add(to: .main, forMode: .common)
        displayLink = link
        boundDisplayID = displayID(of: screen)
        isRunning = desiredRunning

        print("[FrameLoop] Created on display \(boundDisplayID.map(String.init) ?? "?") (running: \(isRunning))")
        fflush(stdout)
    }

    /// Tear down the current link and recreate it on a live screen, preserving
    /// the running/paused state.
    private func rebindDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        boundDisplayID = nil
        createLinkOnCurrentScreen()
    }

    // MARK: - Display Reconfiguration

    private func registerScreenObserver() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenChange()
        }
    }

    private func unregisterScreenObserver() {
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
            screenObserver = nil
        }
    }

    /// React to a display arrangement / connect / disconnect event.
    /// Rebinds only when necessary — benign parameter changes (resolution,
    /// dock, menu-bar) that leave the bound display connected are ignored so an
    /// in-flight animation isn't interrupted.
    private func handleScreenChange() {
        guard let _ = displayLink else {
            // No live link yet (clamshell boot, or all displays were gone).
            // A screen may now be available — try to create.
            createLinkOnCurrentScreen()
            return
        }

        let liveIDs = NSScreen.screens.compactMap { displayID(of: $0) }
        if let bound = boundDisplayID, liveIDs.contains(bound) {
            return  // bound display still connected — nothing to do
        }

        // Bound display disconnected (or its ID is unknown) — rebind to a live one.
        print("[FrameLoop] Bound display gone — rebinding display link")
        fflush(stdout)
        rebindDisplayLink()
    }

    /// CGDirectDisplayID backing an NSScreen, via its device description.
    private func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    // MARK: - Frame Callback

    fileprivate func handleTick(_ link: CADisplayLink) {
        // Use targetTimestamp for prediction (smoother than actual timestamp)
        let time = link.targetTimestamp
        onTick?(time)
    }
}

/// Weak-reference wrapper to break the retain cycle:
/// CADisplayLink → DisplayLinkTarget → [weak] FrameLoop
private class DisplayLinkTarget: NSObject {
    weak var frameLoop: FrameLoop?

    init(frameLoop: FrameLoop) {
        self.frameLoop = frameLoop
    }

    @objc func tick(_ link: CADisplayLink) {
        frameLoop?.handleTick(link)
    }
}
