@preconcurrency import ApplicationServices
import Foundation
import Core

/// Manages AX observation for a single application.
/// Runs on a dedicated thread with its own CFRunLoop to prevent
/// hung apps from blocking the main thread.
public final class AXApp: @unchecked Sendable {
    public let pid: pid_t
    public let bundleIdentifier: String?
    public let appElement: AXUIElement

    private var observer: AXObserver?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let runLoopReady = DispatchSemaphore(value: 0)

    /// Callback closure invoked on the main thread when events occur.
    public var onEvent: ((AXAppEvent) -> Void)?

    /// Per-app AX call cost tracking (exponential moving average in seconds).
    public private(set) var axCallCostEMA: Double = 0.002

    public init(pid: pid_t, bundleIdentifier: String?) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.appElement = AXUIElementCreateApplication(pid)

        // Set messaging timeout on the app element too
        AXUIElementSetMessagingTimeout(appElement, 0.1)
    }

    deinit {
        stopObserving()
    }

    // MARK: - Thread & Observer Lifecycle

    /// Start observing this app on a dedicated thread.
    public func startObserving() {
        let t = Thread { [weak self] in
            self?.observerThreadMain()
        }
        t.name = "AXApp-\(pid)"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Stop observing and tear down the thread.
    public func stopObserving() {
        guard thread != nil else { return }  // never started
        _ = runLoopReady.wait(timeout: .now() + 0.5)
        if let rl = runLoop {
            CFRunLoopStop(rl)
        }
        observer = nil
        thread = nil
        runLoop = nil
        runLoopReady.signal()  // allow safe re-entry from deinit
    }

    private func observerThreadMain() {
        runLoop = CFRunLoopGetCurrent()
        runLoopReady.signal()

        // Create the AX observer
        var obs: AXObserver?
        let err = AXObserverCreate(pid, axObserverCallback, &obs)
        guard err == .success, let observer = obs else {
            return
        }
        self.observer = observer

        // Subscribe to app-level notifications
        let appNotifications: [String] = [
            kAXWindowCreatedNotification,
            kAXFocusedWindowChangedNotification,
        ]

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in appNotifications {
            AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
        }

        // Add the observer's run loop source
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )

        // Run the loop — blocks until stopped
        CFRunLoopRun()

        // Cleanup: remove all notifications
        for notification in appNotifications {
            AXObserverRemoveNotification(observer, appElement, notification as CFString)
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
    }

    /// Subscribe to per-window notifications.
    public func observeWindow(_ element: AXUIElement) {
        guard let observer = observer else { return }
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
            AXObserverAddNotification(observer, element, notification as CFString, refcon)
        }
    }

    /// Unsubscribe from per-window notifications.
    public func unobserveWindow(_ element: AXUIElement) {
        guard let observer = observer else { return }

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

    /// Execute a setFrame call on this app's thread, tracking cost.
    @discardableResult
    public func dispatchSetFrame(_ window: AXWindow, frame: CGRect) -> AXResult<Void> {
        let start = TimeUtil.now()
        let result = window.setFrame(frame)
        let duration = TimeUtil.now() - start

        // Update EMA: 80% old, 20% new
        axCallCostEMA = axCallCostEMA * 0.8 + duration * 0.2
        return result
    }

    /// Execute a setPosition-only call (cheaper during animation).
    @discardableResult
    public func dispatchSetPosition(_ window: AXWindow, position: CGPoint) -> AXResult<Void> {
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
    /// Safe to call from main thread — uses the app element's 100ms messaging timeout.
    public func focusedWindowID() -> CGWindowID? {
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

