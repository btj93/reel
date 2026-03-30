import AppKit
import QuartzCore
import Foundation

/// Per-monitor CADisplayLink wrapper for vsync-driven animation.
/// Pauses automatically when idle to save battery.
public final class FrameLoop: @unchecked Sendable {

    /// Called every frame with the target timestamp (seconds).
    public var onTick: ((Double) -> Void)?

    /// Whether the frame loop is currently ticking.
    public private(set) var isRunning: Bool = false

    private var displayLink: CADisplayLink?

    /// Weak target wrapper to prevent retain cycle.
    /// CADisplayLink retains its target, so we use an intermediary.
    private var targetWrapper: DisplayLinkTarget?

    public init() {}

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Create and start the display link on the main run loop.
    public func start() {
        guard displayLink == nil else { return }
        guard let screen = NSScreen.main else {
            print("[FrameLoop] No main screen — cannot create display link")
            return
        }

        let target = DisplayLinkTarget(frameLoop: self)
        targetWrapper = target

        let link = screen.displayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))

        // Request highest refresh rate (120Hz on ProMotion displays)
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30,
            maximum: 120,
            preferred: 120
        )

        // Start paused — resume() will activate when animation begins
        link.isPaused = true

        link.add(to: .main, forMode: .common)
        displayLink = link

        print("[FrameLoop] Created (paused, waiting for animation)")
        fflush(stdout)
    }

    /// Remove the display link entirely.
    public func stop() {
        displayLink?.invalidate()
        displayLink = nil
        targetWrapper = nil
        isRunning = false
    }

    /// Resume ticking (called when animation starts).
    public func resume() {
        guard let link = displayLink else { return }
        guard link.isPaused else { return }  // already running
        link.isPaused = false
        isRunning = true
    }

    /// Pause ticking (called when animation settles).
    public func pause() {
        guard let link = displayLink else { return }
        guard !link.isPaused else { return }  // already paused
        link.isPaused = true
        isRunning = false
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
