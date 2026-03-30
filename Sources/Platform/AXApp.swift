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
        if let rl = runLoop {
            CFRunLoopStop(rl)
        }
        observer = nil
        thread = nil
        runLoop = nil
    }

    private func observerThreadMain() {
        runLoop = CFRunLoopGetCurrent()

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
    public func dispatchSetFrame(_ window: AXWindow, frame: CGRect) {
        let start = CACurrentMediaTime()
        let _ = window.setFrame(frame)
        let duration = CACurrentMediaTime() - start

        // Update EMA: 80% old, 20% new
        axCallCostEMA = axCallCostEMA * 0.8 + duration * 0.2
    }

    /// Execute a setPosition-only call (cheaper during animation).
    public func dispatchSetPosition(_ window: AXWindow, position: CGPoint) {
        let start = CACurrentMediaTime()
        let _ = window.setPosition(position)
        let duration = CACurrentMediaTime() - start
        axCallCostEMA = axCallCostEMA * 0.8 + duration * 0.2
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

/// Get the current time for AX cost tracking.
private func CACurrentMediaTime() -> Double {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let now = mach_absolute_time()
    return Double(now) * Double(info.numer) / Double(info.denom) / 1_000_000_000
}
