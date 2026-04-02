import AppKit
import Foundation
import Core
import Platform

/// Discovers, classifies, and tracks all windows on the system.
/// Feeds events into the serial event queue for the WindowManager.
public final class WindowTracker: @unchecked Sendable {

    /// All tracked AXWindow instances, keyed by CGWindowID.
    public private(set) var windows: [CGWindowID: AXWindow] = [:]

    /// Per-app observers, keyed by PID.
    public private(set) var apps: [pid_t: AXApp] = [:]

    /// Windows classified as floating (not on the strip).
    public private(set) var floatingWindows: Set<CGWindowID> = []

    /// Windows classified as ignored (not managed at all).
    public private(set) var ignoredWindows: Set<CGWindowID> = []

    /// Callback for window events.
    public var onEvent: ((WindowEvent) -> Void)?

    /// Register a window directly (used by startup retry).
    public func registerTrackedWindow(_ window: AXWindow) {
        windows[window.windowID] = window
    }

    /// Mark a window as floating (won't be re-adopted by health check).
    public func markFloating(_ windowID: CGWindowID) {
        floatingWindows.insert(windowID)
    }

    /// Unmark a window as floating (will be managed again).
    public func unmarkFloating(_ windowID: CGWindowID) {
        floatingWindows.remove(windowID)
    }

    /// Remove a window from tracking (used by health check).
    public func untrackWindow(_ windowID: CGWindowID) {
        windows.removeValue(forKey: windowID)
    }

    /// Window rules for per-app overrides.
    public var rules: [WindowRule] = []

    private var workspaceObservers: [NSObjectProtocol] = []

    public init() {}

    deinit {
        stopObserving()
    }

    // MARK: - Discovery

    /// Discover all existing windows and start observing.
    public func startObserving() {
        // Observe app launch/terminate
        let nc = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notif in
            if let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.handleAppLaunched(app)
            }
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notif in
            if let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.handleAppTerminated(app)
            }
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notif in
            if let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.onEvent?(.appActivated(pid: app.processIdentifier))
            }
        })

        // Observe Space changes (user switches desktop)
        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            #if DEBUG
            print("[Tracker] Space changed — re-discovering windows")
            fflush(stdout)
            #endif
            self?.onEvent?(.spaceChanged)
        })

        // Discover existing apps
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            let wins = getAppWindows(pid: app.processIdentifier)
            #if DEBUG
            print("[Tracker] app: \(app.localizedName ?? "?") pid=\(app.processIdentifier) bundleID=\(app.bundleIdentifier ?? "?") windows=\(wins.count)")
            fflush(stdout)
            #endif
            registerApp(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
        }
    }

    /// Stop all observation.
    public func stopObserving() {
        let nc = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            nc.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        for (_, app) in apps {
            app.stopObserving()
        }
        apps.removeAll()
        windows.removeAll()
    }

    // MARK: - App Registration

    private func registerApp(pid: pid_t, bundleID: String?) {
        guard apps[pid] == nil else { return }

        let app = AXApp(pid: pid, bundleIdentifier: bundleID)
        app.onEvent = { [weak self] event in
            self?.handleAXEvent(event)
        }
        apps[pid] = app
        app.startObserving()

        // Discover existing windows for this app
        let newWindows = discoverWindows(pid: pid)
        for window in newWindows {
            registerWindow(window, bundleID: bundleID)
        }
    }

    private func handleAppLaunched(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular else { return }
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier
        registerApp(pid: pid, bundleID: bundleID)

        // Newly launched apps often create their first window *after* the launch
        // notification. Retry discovery at short intervals to catch it quickly
        // instead of waiting for the 1s health check poll.
        for delay in [0.1, 0.3, 0.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.apps[pid] != nil else { return }
                let newWindows = discoverWindows(pid: pid)
                for window in newWindows {
                    guard self.windows[window.windowID] == nil else { continue }
                    self.registerWindow(window, bundleID: bundleID)
                }
            }
        }
    }

    private func handleAppTerminated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier

        // Remove all windows for this app
        let windowsToRemove = windows.values.filter { $0.pid == pid }
        for window in windowsToRemove {
            unregisterWindow(window.windowID)
        }

        // Stop observing
        apps[pid]?.stopObserving()
        apps.removeValue(forKey: pid)
    }

    // MARK: - Window Registration

    private func registerWindow(_ window: AXWindow, bundleID: String?) {
        let wid = window.windowID
        guard windows[wid] == nil else { return }

        // Classify the window — use fast path to skip non-essential AX reads
        var props = window.getPropertiesFast()
        props.bundleIdentifier = bundleID
        props.windowLayer = windowLayer(for: wid)

        // Check rules first
        let ruleResult = applyRules(props)
        let classification = ruleResult ?? classifyWindow(props)

        #if DEBUG
        print("[Tracker] registerWindow wid=\(wid) role='\(props.role ?? "nil")' subrole='\(props.subrole ?? "nil")' resizable=\(props.isResizable) closeBtn=\(props.hasCloseButton) layer=\(props.windowLayer) isMin=\(props.isMinimized) isFS=\(props.isFullscreen) → \(classification) title=\(props.title ?? "nil")")
        fflush(stdout)
        #endif

        switch classification {
        case .tile:
            windows[wid] = window

            // Start per-window observation
            if let app = apps[window.pid] {
                app.observeWindow(window.element)
            }

            // Only add to strip if not minimized (minimized windows are tracked but not tiled)
            if !props.isMinimized {
                onEvent?(.windowAdded(window: window, classification: .tile))
            }

        case .float:
            windows[wid] = window
            floatingWindows.insert(wid)

            if let app = apps[window.pid] {
                app.observeWindow(window.element)
            }

            onEvent?(.windowAdded(window: window, classification: .float))

        case .ignore:
            ignoredWindows.insert(wid)
        }
    }

    private func unregisterWindow(_ wid: CGWindowID) {
        guard let window = windows.removeValue(forKey: wid) else { return }

        if let app = apps[window.pid] {
            app.unobserveWindow(window.element)
        }

        floatingWindows.remove(wid)
        ignoredWindows.remove(wid)

        onEvent?(.windowRemoved(windowID: wid, tileID: window.tileID))
    }

    // MARK: - AX Event Handling

    private func handleAXEvent(_ event: AXAppEvent) {
        switch event.notification {
        case kAXWindowCreatedNotification:
            if let wid = event.windowID, windows[wid] == nil {
                let bundleID = apps[event.pid]?.bundleIdentifier
                let window = AXWindow(element: event.element, windowID: wid, pid: event.pid)
                registerWindow(window, bundleID: bundleID)
            }

        case kAXUIElementDestroyedNotification:
            if let wid = event.windowID {
                unregisterWindow(wid)
            }

        case kAXFocusedWindowChangedNotification:
            if let wid = event.windowID {
                // If this window isn't tracked yet, adopt it — this catches windows
                // that were created without a kAXWindowCreatedNotification.
                if windows[wid] == nil, !ignoredWindows.contains(wid), !floatingWindows.contains(wid) {
                    let bundleID = apps[event.pid]?.bundleIdentifier
                    let window = AXWindow(element: event.element, windowID: wid, pid: event.pid)
                    registerWindow(window, bundleID: bundleID)
                }
                onEvent?(.windowFocused(windowID: wid))
            }

        case kAXWindowMiniaturizedNotification:
            if let wid = event.windowID {
                onEvent?(.windowMinimized(windowID: wid))
            }

        case kAXWindowDeminiaturizedNotification:
            if let wid = event.windowID {
                onEvent?(.windowDeminimized(windowID: wid))
            }

        case kAXResizedNotification:
            if let wid = event.windowID {
                onEvent?(.windowResized(windowID: wid))
            }

        case kAXMovedNotification:
            if let wid = event.windowID {
                onEvent?(.windowMoved(windowID: wid))
            }

        default:
            break
        }
    }

    // MARK: - Window Rules

    private func applyRules(_ props: WindowProperties) -> WindowClassification? {
        for rule in rules {
            if rule.matches(props) {
                return rule.classification
            }
        }
        return nil
    }
}

/// Events emitted by the WindowTracker.
public enum WindowEvent: Sendable {
    case windowAdded(window: AXWindow, classification: WindowClassification)
    case windowRemoved(windowID: CGWindowID, tileID: TileID)
    case windowFocused(windowID: CGWindowID)
    case windowMinimized(windowID: CGWindowID)
    case windowDeminimized(windowID: CGWindowID)
    case windowResized(windowID: CGWindowID)
    case windowMoved(windowID: CGWindowID)
    case appActivated(pid: pid_t)
    case spaceChanged
}

/// A window matching rule from config.
public struct WindowRule: Sendable {
    public var appID: String?        // Bundle identifier (exact match)
    public var appIDRegex: String?   // Bundle identifier regex
    public var titleRegex: String?   // Window title regex
    public var classification: WindowClassification

    public init(appID: String? = nil, appIDRegex: String? = nil, titleRegex: String? = nil, classification: WindowClassification) {
        self.appID = appID
        self.appIDRegex = appIDRegex
        self.titleRegex = titleRegex
        self.classification = classification
    }

    public func matches(_ props: WindowProperties) -> Bool {
        if let id = appID, props.bundleIdentifier != id { return false }

        if let regex = appIDRegex, let bundleID = props.bundleIdentifier {
            guard bundleID.range(of: regex, options: .regularExpression) != nil else { return false }
        }

        if let regex = titleRegex, let title = props.title {
            guard title.range(of: regex, options: .regularExpression) != nil else { return false }
        }

        return true
    }
}
