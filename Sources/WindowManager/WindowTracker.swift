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

    /// Windows that were floated solely because their title was empty at
    /// registration time. Apps like TablePlus open their main window before
    /// populating the title — we re-classify those on `kAXTitleChangedNotification`
    /// so they can rejoin the strip once the real title arrives.
    private var floatedDueToEmptyTitle: Set<CGWindowID> = []

    /// Last time each tracked window of each pid was focused. Used as a
    /// fallback when resolving "which window of this pid did the user mean."
    public private(set) var lastFocusTimeByWindow: [CGWindowID: Double] = [:]

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
        lastFocusTimeByWindow.removeValue(forKey: windowID)
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
            print("[Tracker] Space changed — re-discovering windows")
            fflush(stdout)
            self?.onEvent?(.spaceChanged)
        })

        // Discover existing apps
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            let wins = getAppWindows(pid: app.processIdentifier)
            print("[Tracker] app: \(app.localizedName ?? "?") pid=\(app.processIdentifier) bundleID=\(app.bundleIdentifier ?? "?") windows=\(wins.count)")
            fflush(stdout)
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
        // instead of waiting for the 500ms health check poll.
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

        print("[Tracker] registerWindow wid=\(wid) app=\(bundleID ?? "?") role='\(props.role ?? "nil")' subrole='\(props.subrole ?? "nil")' resizable=\(props.isResizable) closeBtn=\(props.hasCloseButton) layer=\(props.windowLayer) isMin=\(props.isMinimized) isFS=\(props.isFullscreen) → \(classification) title=\(logTitle(props.title))")
        fflush(stdout)

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

            // Remember if this window was floated only because its title was
            // empty at registration. If a non-rule classification path floated
            // an otherwise-tileable AXStandardWindow purely for that reason,
            // a later kAXTitleChangedNotification will re-run classification.
            if ruleResult == nil,
               props.subrole == "AXStandardWindow",
               props.isResizable,
               props.hasCloseButton,
               (props.title?.isEmpty ?? true) {
                floatedDueToEmptyTitle.insert(wid)
                // Backstop: if no AX event triggers a reclassify within 500 ms,
                // re-check with the frame fallback enabled. Catches apps whose
                // AXTitle never populates (e.g., System Settings).
                let pid = window.pid
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.tryAdoptFloatedEmpty(wid: wid, pid: pid, allowFrameFallback: true)
                }
            }

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
        floatedDueToEmptyTitle.remove(wid)
        lastFocusTimeByWindow.removeValue(forKey: wid)

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
                // Some apps (e.g. System Settings) never fire a title-changed
                // notification, so use focus as another reclassification trigger.
                tryAdoptFloatedEmpty(wid: wid, pid: event.pid, allowFrameFallback: false)
                lastFocusTimeByWindow[wid] = TimeUtil.now()
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
                tryAdoptFloatedEmpty(wid: wid, pid: event.pid, allowFrameFallback: false)
                onEvent?(.windowResized(windowID: wid))
            }

        case kAXMovedNotification:
            if let wid = event.windowID {
                tryAdoptFloatedEmpty(wid: wid, pid: event.pid, allowFrameFallback: false)
                onEvent?(.windowMoved(windowID: wid))
            }

        case kAXTitleChangedNotification:
            if let wid = event.windowID {
                tryAdoptFloatedEmpty(wid: wid, pid: event.pid, allowFrameFallback: false)
            }

        default:
            break
        }
    }

    /// Re-classify a window previously floated due to an empty title.
    ///
    /// Apps like TablePlus open their main window before populating the title;
    /// `kAXTitleChangedNotification` later carries the real title and we adopt
    /// the window into the strip. But some apps (notably System Settings) never
    /// reliably fire a title-changed notification, so we also re-check on focus,
    /// move, and resize events, plus a deferred retry after registration. If the
    /// title is still empty by the deferred check but the window has a usable
    /// frame and clearly looks like a real document window, we accept it as a
    /// tile anyway (`allowFrameFallback`).
    private func tryAdoptFloatedEmpty(wid: CGWindowID, pid: pid_t, allowFrameFallback: Bool) {
        guard floatedDueToEmptyTitle.contains(wid),
              floatingWindows.contains(wid),
              let window = windows[wid] else { return }

        var props = window.getPropertiesFast()
        props.bundleIdentifier = apps[pid]?.bundleIdentifier
        props.windowLayer = windowLayer(for: wid)

        if !(props.title?.isEmpty ?? true) {
            // Title arrived — reclassify via the regular path.
            floatedDueToEmptyTitle.remove(wid)
            let ruleResult = applyRules(props)
            let classification = ruleResult ?? classifyWindow(props)
            if classification == .tile {
                floatingWindows.remove(wid)
                print("[Tracker] reclassify wid=\(wid) float→tile title=\(logTitle(props.title))")
                fflush(stdout)
                onEvent?(.windowAdded(window: window, classification: .tile))
            }
            return
        }

        guard allowFrameFallback else { return }

        // Frame-based fallback: AXStandardWindow + resizable + closeButton with a
        // usable frame is almost certainly a real app window; the popups the
        // empty-title check was guarding against are caught by the frame size
        // threshold instead.
        if props.subrole == "AXStandardWindow",
           props.isResizable,
           props.hasCloseButton,
           let f = props.frame,
           f.width >= minTileableWidth,
           f.height >= minTileableHeight {
            // Respect explicit rules — only fall back if no rule overrides.
            if let ruleResult = applyRules(props), ruleResult != .tile { return }
            floatedDueToEmptyTitle.remove(wid)
            floatingWindows.remove(wid)
            print("[Tracker] reclassify wid=\(wid) float→tile (frame fallback, title still empty, frame=\(Int(f.width))x\(Int(f.height)))")
            fflush(stdout)
            onEvent?(.windowAdded(window: window, classification: .tile))
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
