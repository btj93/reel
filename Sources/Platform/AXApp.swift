@preconcurrency import ApplicationServices
import Foundation
import Core

/// Manages AX observation for a single application.
/// Runs on a dedicated thread with its own CFRunLoop to prevent
/// hung apps from blocking the main thread.
///
/// `open` for testing only — the test target subclasses this to stub out AX
/// observation/dispatch. Do NOT subclass in `Sources/`.
open class AXApp: @unchecked Sendable {
    public let pid: pid_t
    public let bundleIdentifier: String?
    public let appElement: AXUIElement

    /// Serial queue for this app's AX writes (`setFrame`/`setPosition`).
    /// StripController routes every write for a window owned by this app through
    /// here, guaranteeing per-window ordering (an older mid-animation frame can
    /// never land after the final frame) and confining the `axCallCostEMA`
    /// read-modify-write to a single thread (finding #2).
    public let writeQueue: DispatchQueue

    /// Guards `observer`, `runLoop`, and `stopRequested`, which are written on
    /// the observer thread and read/written from the main thread (finding #4).
    private let lock = NSLock()
    private var observer: AXObserver?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    /// Set when `stopObserving()` runs before the observer thread reaches
    /// `CFRunLoopRun`, so the thread self-terminates instead of blocking forever.
    private var stopRequested = false

    /// App-level notifications observed for the lifetime of the observer.
    private static let appNotifications: [String] = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
    ]

    /// Callback closure invoked on the main thread when events occur.
    public var onEvent: ((AXAppEvent) -> Void)?

    /// Per-app AX call cost tracking (exponential moving average in seconds).
    /// Mutated only from `writeQueue` (via `dispatchSet*`), so the read-modify-write
    /// is serialized. A future reader must hop onto `writeQueue` to observe it.
    public private(set) var axCallCostEMA: Double = 0.002

    public init(pid: pid_t, bundleIdentifier: String?) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.appElement = AXUIElementCreateApplication(pid)
        self.writeQueue = DispatchQueue(label: "reel.ax.write.\(pid)", qos: .userInteractive)

        // Set messaging timeout on the app element too
        AXUIElementSetMessagingTimeout(appElement, 0.1)
    }

    deinit {
        stopObserving()
    }

    // MARK: - Thread & Observer Lifecycle

    /// Start observing this app on a dedicated thread.
    open func startObserving() {
        // Create the observer synchronously, before spawning the thread, so an
        // observeWindow() that races the spawn (WindowTracker discovers windows
        // immediately after registerApp) always finds a live observer instead of
        // silently dropping the subscription. AXObserverCreate and
        // AXObserverAddNotification are thread-agnostic; only the run-loop source
        // must be added on the observer thread. (finding #4)
        var obs: AXObserver?
        let err = AXObserverCreate(pid, axObserverCallback, &obs)
        guard err == .success, let observer = obs else {
            print("[AXApp] AXObserverCreate failed pid=\(pid) err=\(err.rawValue)")
            fflush(stdout)
            return
        }
        lock.lock()
        self.observer = observer
        lock.unlock()

        // Subscribe to app-level notifications now (thread-agnostic).
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in Self.appNotifications {
            let addErr = AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
            if addErr != .success {
                print("[AXApp] app AXObserverAddNotification failed pid=\(pid) note=\(notification) err=\(addErr.rawValue)")
                fflush(stdout)
            }
        }

        let t = Thread { [weak self] in
            self?.observerThreadMain(observer: observer)
        }
        t.name = "AXApp-\(pid)"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Stop observing and tear down the thread.
    open func stopObserving() {
        guard thread != nil else { return }  // never started

        lock.lock()
        stopRequested = true
        let rl = runLoop
        lock.unlock()

        // Deliver the stop as a run-loop block + wakeup rather than a bare
        // CFRunLoopStop: the latter is a no-op on a loop that has not yet entered
        // CFRunLoopRun, which would leak the thread + AXApp. The block fires
        // whenever the loop next runs. If the thread hasn't recorded its run loop
        // yet, `stopRequested` makes it self-terminate before running. (finding #4)
        if let rl = rl {
            CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) {
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            CFRunLoopWakeUp(rl)
        }

        lock.lock()
        observer = nil
        runLoop = nil
        lock.unlock()
        thread = nil
    }

    private func observerThreadMain(observer: AXObserver) {
        let rl = CFRunLoopGetCurrent()

        // Add the observer's run loop source (must happen on this thread).
        CFRunLoopAddSource(rl, AXObserverGetRunLoopSource(observer), .defaultMode)

        // Record the run loop and bail early if a stop already arrived — both
        // under the lock so stopObserving() and this method can't miss each
        // other (finding #4).
        lock.lock()
        if stopRequested {
            lock.unlock()
            CFRunLoopRemoveSource(rl, AXObserverGetRunLoopSource(observer), .defaultMode)
            return
        }
        runLoop = rl
        lock.unlock()

        // Run the loop — blocks until stopped
        CFRunLoopRun()

        // Cleanup: remove all notifications
        for notification in Self.appNotifications {
            AXObserverRemoveNotification(observer, appElement, notification as CFString)
        }
        CFRunLoopRemoveSource(rl, AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    /// Subscribe to per-window notifications.
    open func observeWindow(_ element: AXUIElement) {
        lock.lock()
        let obs = observer
        lock.unlock()
        guard let observer = obs else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let windowNotifications: [String] = [
            kAXUIElementDestroyedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXMovedNotification,
            kAXResizedNotification,
            kAXTitleChangedNotification,
        ]

        for notification in windowNotifications {
            let addErr = AXObserverAddNotification(observer, element, notification as CFString, refcon)
            if addErr != .success && addErr != .notificationAlreadyRegistered {
                print("[AXApp] window AXObserverAddNotification failed pid=\(pid) note=\(notification) err=\(addErr.rawValue)")
                fflush(stdout)
            }
        }
    }

    /// Unsubscribe from per-window notifications.
    open func unobserveWindow(_ element: AXUIElement) {
        lock.lock()
        let obs = observer
        lock.unlock()
        guard let observer = obs else { return }

        let windowNotifications: [String] = [
            kAXUIElementDestroyedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXMovedNotification,
            kAXResizedNotification,
            kAXTitleChangedNotification,
        ]

        for notification in windowNotifications {
            AXObserverRemoveNotification(observer, element, notification as CFString)
        }
    }

    // MARK: - AX Call Dispatching

    /// Execute a setFrame call, tracking cost. Must run on `writeQueue` — the
    /// `axCallCostEMA` read-modify-write is serialized by that queue (finding #2).
    @discardableResult
    open func dispatchSetFrame(_ window: AXWindow, frame: CGRect) -> AXResult<Void> {
        let start = TimeUtil.now()
        let result = window.setFrame(frame)
        let duration = TimeUtil.now() - start

        // Update EMA: 80% old, 20% new
        axCallCostEMA = axCallCostEMA * 0.8 + duration * 0.2
        return result
    }

    /// Execute a setPosition-only call (cheaper during animation). Must run on
    /// `writeQueue` (see `dispatchSetFrame`).
    @discardableResult
    open func dispatchSetPosition(_ window: AXWindow, position: CGPoint) -> AXResult<Void> {
        let start = TimeUtil.now()
        let result = window.setPosition(position)
        let duration = TimeUtil.now() - start
        axCallCostEMA = axCallCostEMA * 0.8 + duration * 0.2
        return result
    }

    // MARK: - Internal Event Handling

    fileprivate func handleNotification(_ notification: String, element: AXUIElement) {
        let wid = windowID(for: element)
        let event = AXAppEvent(
            pid: pid,
            notification: notification,
            windowID: wid,
            element: element
        )

        // Dispatch to main thread
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    // MARK: - Focused Window Query

    /// Get the CGWindowID of this app's currently focused window via AX.
    /// Returns nil if the app has no focused window or the AX call fails/times out.
    /// Thread-safe: `appElement` is immutable after init. Bounded by the app element's
    /// 100ms messaging timeout, so a hung app fails fast instead of blocking the caller.
    open func focusedWindowID() -> CGWindowID? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        )
        guard err == .success, let value else { return nil }
        let element = value as! AXUIElement
        return windowID(for: element)
    }
}

/// Event emitted by an AXApp observer.
public struct AXAppEvent: Sendable {
    public let pid: pid_t
    public let notification: String
    public let windowID: CGWindowID?
    public let element: AXUIElement
}

// MARK: - AX Observer C Callback

private func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon = refcon else { return }
    let app = Unmanaged<AXApp>.fromOpaque(refcon).takeUnretainedValue()
    app.handleNotification(notification as String, element: element)
}

