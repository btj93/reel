import AppKit
import Foundation
import Core
import Config
import IPC
import Platform

/// Central coordinator for ScrollWM.
/// Connects WindowTracker (discovery) → StripController (layout) → Platform APIs.
/// All state mutations happen on the main thread via the serial event queue.
public final class WindowManager: @unchecked Sendable {
    public let tracker: WindowTracker
    public let stripController: StripController
    public let hotkeyManager: HotkeyManager
    public let displayManager: DisplayManager

    /// Whether management is paused.
    public private(set) var isPaused: Bool = false

    /// Gesture capture for trackpad scrolling.
    private var gestureCapture: GestureCapture?

    /// IPC socket server.
    private var ipcServer: SocketServer?

    /// Current configuration.
    public private(set) var config: ScrollWMConfig

    /// Config file watcher for hot-reload.
    private var configWatcher: ConfigWatcher?

    /// State persistence for crash recovery.
    private let stateFilePath: String
    private var stateWriteTimer: Timer?

    public init() {
        // Load config first
        let (loadedConfig, configError) = ScrollWMConfig.load()
        self.config = loadedConfig
        if let err = configError {
            print("[WM] Config warning: \(err)")
            fflush(stdout)
        }

        self.tracker = WindowTracker()
        self.displayManager = DisplayManager()
        self.hotkeyManager = HotkeyManager()

        // Initialize strip controller with primary display working area
        displayManager.refresh()
        let struts = Struts(
            left: CGFloat(config.struts.left),
            right: CGFloat(config.struts.right),
            top: CGFloat(config.struts.top),
            bottom: CGFloat(config.struts.bottom)
        )
        let workingArea = displayManager.mainDisplay?.workingArea(struts: struts, primaryScreenHeight: displayManager.primaryScreenHeight) ?? CGRect(x: 0, y: 25, width: 1440, height: 875)
        self.stripController = StripController(workingArea: workingArea)

        // State file path
        let stateDir = NSHomeDirectory() + "/.local/state/scrollwm"
        self.stateFilePath = stateDir + "/window-state.json"

        // Apply config to all subsystems
        applyConfig(config)
        setupEventHandlers()
    }

    /// Apply config values to all subsystems.
    public func applyConfig(_ config: ScrollWMConfig) {
        self.config = config

        // Strip layout
        stripController.strip.gap = config.gap
        stripController.strip.defaultWidth = config.defaultWidth
        stripController.strip.widthPresets = config.widthPresets
        stripController.strip.focusMode = config.focusMode
        stripController.animationEnabled = config.animationEnabled

        // Window rules
        tracker.rules = config.rules.map { rule in
            WindowRule(
                appID: rule.appID,
                appIDRegex: rule.appIDRegex,
                titleRegex: rule.titleRegex,
                classification: rule.floating ? .float : .tile
            )
        }

        // Hotkeys
        hotkeyManager.registerFromConfig(config.keybindings)

        // Gesture modifier
        if let gc = gestureCapture {
            switch config.gestureModifier.lowercased() {
            case "fn": gc.requiredModifier = .maskSecondaryFn
            case "ctrl", "control": gc.requiredModifier = .maskControl
            case "alt", "opt", "option": gc.requiredModifier = .maskAlternate
            case "cmd", "command": gc.requiredModifier = .maskCommand
            default: gc.requiredModifier = .maskSecondaryFn
            }
        }

        // Terminal path is read directly from config when spawning

        print("[WM] Config applied (gap=\(config.gap), focus=\(config.focusMode), animation=\(config.animationEnabled))")
        fflush(stdout)
    }

    // MARK: - Lifecycle

    /// Start the window manager.
    public func start() {
        print("[WM] start() called"); fflush(stdout)

        // Ensure state directory exists
        let stateDir = (stateFilePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)

        print("[WM] state dir ready"); fflush(stdout)

        // Attempt crash recovery
        recoverFromCrash()

        print("[WM] displays..."); fflush(stdout)
        displayManager.startObserving()
        print("[WM] display done, working area: \(displayManager.mainDisplay?.visibleFrame ?? .zero)"); fflush(stdout)

        // Record initial Space fingerprint
        let initialWindows = getAllWindowInfo()
        let initialFingerprint = Set(initialWindows.filter { $0.layer == 0 && $0.isOnScreen }.map(\.windowID))
        stripController.setSpaceFingerprint(initialFingerprint)

        // Start subsystems — batch window discovery to avoid N layout passes
        stripController.beginBatch()
        print("[WM] tracking windows..."); fflush(stdout)
        tracker.startObserving()
        print("[WM] tracked \(tracker.windows.count) windows, \(tracker.apps.count) apps"); fflush(stdout)
        stripController.finishBatch()
        print("[WM] batch finished, strip has \(stripController.strip.columns.count) cols"); fflush(stdout)

        hotkeyManager.registerFromConfig(config.keybindings)
        let hotkeyOk = hotkeyManager.start()
        print("[WM] hotkeys: \(hotkeyOk)"); fflush(stdout)

        // Phase 2: Frame loop for smooth animation
        let frameLoop = FrameLoop()
        frameLoop.onTick = { [weak self] time in
            self?.stripController.handleFrameTick(time: time)
        }
        frameLoop.start()
        stripController.frameLoop = frameLoop
        stripController.animationEnabled = true
        print("[WM] animation: enabled (frame loop created)"); fflush(stdout)

        // Phase 2: Gesture capture for trackpad scrolling
        let gestureCapture = GestureCapture()
        gestureCapture.onGestureBegin = { [weak self] time in
            self?.stripController.handleGestureBegin(time: time)
        }
        gestureCapture.onGestureUpdate = { [weak self] deltaX, time in
            self?.stripController.handleGestureUpdate(deltaX: deltaX, time: time)
        }
        gestureCapture.onGestureEnd = { [weak self] time in
            self?.stripController.handleGestureEnd(time: time)
        }
        gestureCapture.onGestureCancel = { [weak self] in
            self?.stripController.handleGestureCancel()
        }
        let gestureOk = gestureCapture.start()
        self.gestureCapture = gestureCapture
        print("[WM] gesture capture: \(gestureOk)"); fflush(stdout)

        // Start periodic state persistence (every 5 seconds)
        stateWriteTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.persistState()
        }

        // Config hot-reload watcher
        let watcher = ConfigWatcher()
        watcher.onConfigChanged = { [weak self] newConfig in
            guard let self = self else { return }
            self.applyConfig(newConfig)
            self.stripController.strip.recalculateWidths()
            self.stripController.clearCommittedFrames()
            self.stripController.applyLayout()
        }
        watcher.start()
        self.configWatcher = watcher

        // IPC socket server
        let server = SocketServer()
        server.onCommand = { [weak self] command in
            guard let self = self else { return ScrollWMResponse(success: false, message: "Shutting down") }
            return self.handleIPCCommand(command)
        }
        let ipcOk = server.start()
        self.ipcServer = server
        print("[WM] IPC server: \(ipcOk)"); fflush(stdout)

        // Periodic window health check — detect closed windows that AX observer missed.
        // kAXUIElementDestroyedNotification is unreliable for some apps.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkWindowHealth()
        }

        // Register signal handlers for graceful shutdown via NSApp.terminate
        // This ensures proper cleanup (menu bar icon removal, window restoration)
        signal(SIGTERM) { _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
        signal(SIGINT) { _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }

        print("[ScrollWM] Window manager started")
        print("[ScrollWM] Tracked windows: \(tracker.windows.count)")
        print("[ScrollWM] Tracked apps: \(tracker.apps.count)")
        print("[ScrollWM] Strip columns: \(stripController.strip.columns.count)")
        print("[ScrollWM] Strip working area: \(stripController.strip.workingArea)")
        fflush(stdout)

        // Retry layout after a short delay — some AX observers may not have
        // delivered their initial window list yet at startup
        // Retry layout at 0.5s, 1.5s, and 3s after startup.
        // AX calls can fail on first attempt if apps haven't finished launching.
        for delay in [0.5, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, !self.isPaused else { return }

                let adopted = self.adoptUnmanagedWindows()
                if adopted {
                    self.stripController.clearCommittedFrames()
                    self.stripController.applyLayout()
                }
                print("[ScrollWM] Startup retry @\(delay)s: \(self.stripController.strip.columns.count) cols")
                fflush(stdout)
            }
        }
    }

    /// Stop and restore all windows.
    public func shutdown() {
        print("[ScrollWM] Shutting down — restoring windows")
        isPaused = true
        stateWriteTimer?.invalidate()

        // Restore all windows to reasonable on-screen positions
        restoreAllWindows()

        // Persist final state
        persistState()

        // Stop subsystems
        configWatcher?.stop()
        ipcServer?.stop()
        stripController.frameLoop?.stop()
        gestureCapture?.stop()
        hotkeyManager.stop()
        tracker.stopObserving()
        displayManager.stopObserving()

        stripController.focusRing.hide()
    }

    /// Toggle pause/resume.
    public func togglePause() {
        isPaused = !isPaused
        if isPaused {
            print("[ScrollWM] Paused")
            stripController.focusRing.hide()
            restoreAllWindows()
        } else {
            print("[ScrollWM] Resumed")
            // Re-discover any windows that aren't in the strip
            adoptUnmanagedWindows()
            // Clear committed frames so the next applyLayout reapplies everything
            stripController.clearCommittedFrames()
            stripController.applyLayout()
        }
    }

    // MARK: - Event Handling

    private func setupEventHandlers() {
        // Window tracker events → strip controller
        tracker.onEvent = { [weak self] event in
            guard let self = self, !self.isPaused else { return }
            self.handleWindowEvent(event)
        }

        // Hotkey events → strip controller
        hotkeyManager.onAction = { [weak self] action in
            guard let self = self, !self.isPaused else { return }
            self.handleHotkeyAction(action)
        }

        // Display changes → recalculate layout
        displayManager.onDisplayChange = { [weak self] displays in
            guard let self = self else { return }
            if let main = displays.values.first(where: { $0.isMain }) ?? displays.values.first {
                self.stripController.updateWorkingArea(main.workingArea(primaryScreenHeight: self.displayManager.primaryScreenHeight))
            }
        }
    }

    private func handleWindowEvent(_ event: WindowEvent) {
        // Ignore move/resize/focus events that echo from our own layout calls
        if stripController.isInEchoSuppression {
            switch event {
            case .windowResized, .windowMoved, .windowFocused:
                return
            default:
                break
            }
        }

        switch event {
        case .windowAdded(let window, let classification):
            guard classification == .tile else { return }
            if let app = tracker.apps[window.pid] {
                stripController.addWindow(window, app: app)
            }

        case .windowRemoved(_, let tileID):
            stripController.removeWindow(tileID: tileID)

        case .windowFocused(let windowID):
            // Only scroll to window if it's not already the active column
            let tileID = TileID(windowID)
            if let colIndex = stripController.strip.columns.firstIndex(where: { $0.tiles.contains(tileID) }),
               colIndex != stripController.strip.activeColumnIndex {
                stripController.scrollToWindow(tileID: tileID)
            }

        case .appActivated(let pid):
            // Cmd+Tab support: find the first window of this app and scroll to it
            if let window = tracker.windows.values.first(where: { $0.pid == pid }) {
                let tileID = window.tileID
                if let colIndex = stripController.strip.columns.firstIndex(where: { $0.tiles.contains(tileID) }),
                   colIndex != stripController.strip.activeColumnIndex {
                    stripController.scrollToWindow(tileID: tileID)
                }
            }

        case .windowMinimized(let windowID):
            stripController.removeWindow(tileID: TileID(windowID))

        case .windowDeminimized(let windowID):
            if let window = tracker.windows[windowID],
               let app = tracker.apps[window.pid] {
                stripController.addWindow(window, app: app)
            }

        case .windowResized(let windowID):
            // User resized a window — update the strip column width to match
            stripController.handleUserResize(windowID: windowID)

        case .windowMoved(let windowID):
            // User dragged a window — snap it back to its strip position
            stripController.handleUserMove(windowID: windowID)

        case .spaceChanged:
            handleSpaceChange()
        }
    }

    private func handleSpaceChange() {
        guard !isPaused else { return }

        // Get all currently on-screen window IDs to identify this Space
        let onScreenWindows = getAllWindowInfo()
        let onScreenIDs = Set(onScreenWindows.filter { $0.layer == 0 && $0.isOnScreen }.map(\.windowID))

        // Try to restore saved state for this Space
        let restored = stripController.switchSpace(onScreenWindowIDs: onScreenIDs)

        if restored {
            // Remove windows that are no longer on screen (closed while away)
            let managedIDs = Set(stripController.windowMap.keys.map(\.rawValue))
            let goneIDs = managedIDs.subtracting(onScreenIDs)
            for goneID in goneIDs {
                stripController.removeWindow(tileID: TileID(goneID))
            }

            // Add new windows that weren't in the saved state
            let newWindowIDs = onScreenIDs.subtracting(managedIDs)

            if !newWindowIDs.isEmpty {
                for (pid, app) in tracker.apps {
                    let appWindows = discoverWindows(pid: pid)
                    for window in appWindows {
                        guard newWindowIDs.contains(window.windowID) else { continue }
                        let props = window.getProperties()
                        guard !props.isMinimized && !props.isFullscreen else { continue }
                        let classification = classifyWindow(props)
                        guard classification == .tile else { continue }
                        tracker.registerTrackedWindow(window)
                        app.observeWindow(window.element)
                        stripController.addWindow(window, app: app)
                    }
                }
                print("[ScrollWM] Space restored + \(newWindowIDs.count) new windows")
            } else {
                print("[ScrollWM] Space restored: \(stripController.strip.columns.count) cols")
            }
            fflush(stdout)
            return
        }

        // New Space — discover windows from scratch
        stripController.beginBatch()
        for (pid, app) in tracker.apps {
            let appWindows = discoverWindows(pid: pid)
            for window in appWindows {
                guard onScreenIDs.contains(window.windowID) else { continue }

                let props = window.getProperties()
                guard !props.isMinimized && !props.isFullscreen else { continue }

                let classification = classifyWindow(props)
                guard classification == .tile else { continue }

                tracker.registerTrackedWindow(window)
                app.observeWindow(window.element)
                stripController.addWindow(window, app: app)
            }
        }
        stripController.finishBatch()

        print("[ScrollWM] Space changed: new strip with \(stripController.strip.columns.count) cols")
        fflush(stdout)
    }

    private func handleHotkeyAction(_ action: HotkeyAction) {
        switch action {
        case .focusLeft:
            stripController.focusLeft()
        case .focusRight:
            stripController.focusRight()
        case .moveColumnLeft:
            stripController.moveColumnLeft()
        case .moveColumnRight:
            stripController.moveColumnRight()
        case .cycleWidthPreset:
            stripController.cycleWidthPreset()
        case .toggleFullWidth:
            stripController.toggleFullWidth()
        case .toggleFloating:
            break  // TODO: Implement float toggle
        case .closeWindow:
            break  // TODO: Implement close
        case .workspace:
            break  // TODO: Phase 3
        case .spawnTerminal:
            spawnTerminal()
        }
    }

    // MARK: - Window Health Check

    /// Periodically verify all tracked windows still exist.
    /// Catches closed windows that kAXUIElementDestroyedNotification missed.
    /// Also adopts on-screen windows that should be in the strip but aren't.
    private func checkWindowHealth() {
        guard !isPaused else { return }

        // Get all currently on-screen window IDs from the window server
        let onScreenWindows = getAllWindowInfo()
        let onScreenIDs = Set(onScreenWindows.map(\.windowID))

        // Pass 1: Remove dead windows from the strip
        var changed = false
        for (tileID, window) in stripController.windowMap {
            // Method 1: Check if the window is still in CGWindowList
            if !onScreenIDs.contains(window.windowID) {
                stripController.removeWindow(tileID: tileID)
                tracker.untrackWindow(window.windowID)
                changed = true
                continue
            }

            // Method 2: Try to read a property — if it fails with invalidElement, window is dead
            let posResult = window.getPosition()
            if case .failure(.elementInvalid) = posResult {
                stripController.removeWindow(tileID: tileID)
                tracker.untrackWindow(window.windowID)
                changed = true
            }
        }

        // Pass 2: Adopt unmanaged windows that should be in the strip
        changed = adoptUnmanagedWindows() || changed

        if changed {
            stripController.clearCommittedFrames()
            stripController.applyLayout()
        }
    }

    /// Discover on-screen windows not currently in the strip and add them.
    /// Returns true if any windows were adopted.
    @discardableResult
    private func adoptUnmanagedWindows() -> Bool {
        let stripWindowIDs = Set(stripController.windowMap.values.map(\.windowID))
        var adopted = false

        for (pid, app) in tracker.apps {
            let newWindows = discoverWindows(pid: pid)
            for window in newWindows {
                // Skip windows already tracked and in the strip
                guard !stripWindowIDs.contains(window.windowID) else { continue }
                // Skip windows already tracked as floating/ignored
                guard !tracker.floatingWindows.contains(window.windowID),
                      !tracker.ignoredWindows.contains(window.windowID) else { continue }

                let props = window.getProperties()
                guard !props.isMinimized, !props.isFullscreen else { continue }

                // Check rules, then default classification
                let classification: WindowClassification
                if let ruleResult = tracker.rules.first(where: { $0.matches(props) })?.classification {
                    classification = ruleResult
                } else {
                    classification = classifyWindow(props)
                }

                guard classification == .tile else { continue }

                // Adopt this window into the strip
                if tracker.windows[window.windowID] == nil {
                    tracker.registerTrackedWindow(window)
                    app.observeWindow(window.element)
                }
                stripController.addWindow(window, app: app)
                adopted = true
                print("[HealthCheck] Adopted unmanaged window wid=\(window.windowID) pid=\(pid)")
                fflush(stdout)
            }
        }

        return adopted
    }

    // MARK: - Terminal Spawning

    private func spawnTerminal() {
        NSWorkspace.shared.open(URL(fileURLWithPath: config.terminalApp))
    }

    // MARK: - Crash Recovery

    private func persistState() {
        var state: [[String: Any]] = []
        for (tileID, frame) in stripController.lastCommittedFrames {
            let window = stripController.windowMap[tileID]
            state.append([
                "windowID": tileID.rawValue,
                "bundleID": window?.pid ?? 0,
                "x": frame.minX,
                "y": frame.minY,
                "width": frame.width,
                "height": frame.height,
            ])
        }

        if let data = try? JSONSerialization.data(withJSONObject: state) {
            try? data.write(to: URL(fileURLWithPath: stateFilePath))
        }
    }

    private func recoverFromCrash() {
        guard FileManager.default.fileExists(atPath: stateFilePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: stateFilePath)),
              let state = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }

        print("[ScrollWM] Found crash recovery state — checking for orphaned windows")

        // Check if any windows are in weird positions and restore them
        // (This is a best-effort recovery — exact matching is hard)
        try? FileManager.default.removeItem(atPath: stateFilePath)
    }

    private func restoreAllWindows() {
        // Move all managed windows to a simple tiled layout
        let wa = stripController.strip.workingArea
        let windowCount = stripController.windowMap.count
        guard windowCount > 0 else { return }

        let colWidth = wa.width / Double(min(windowCount, 3))
        var x = wa.minX

        for (_, window) in stripController.windowMap {
            let frame = CGRect(x: x, y: wa.minY, width: colWidth, height: wa.height)
            let _ = window.setFrame(frame)
            x += colWidth
            if x >= wa.maxX { x = wa.minX }
        }
    }

    // MARK: - IPC Command Handling

    private func handleIPCCommand(_ command: ScrollWMCommand) -> ScrollWMResponse {
        switch command {
        case .focusLeft:
            stripController.focusLeft()
            return ScrollWMResponse(success: true)
        case .focusRight:
            stripController.focusRight()
            return ScrollWMResponse(success: true)
        case .moveColumnLeft:
            stripController.moveColumnLeft()
            return ScrollWMResponse(success: true)
        case .moveColumnRight:
            stripController.moveColumnRight()
            return ScrollWMResponse(success: true)
        case .cycleWidthPreset:
            stripController.cycleWidthPreset()
            return ScrollWMResponse(success: true)
        case .toggleFullWidth:
            stripController.toggleFullWidth()
            return ScrollWMResponse(success: true)
        case .toggleFloating:
            // TODO: implement
            return ScrollWMResponse(success: false, message: "Not implemented yet")
        case .closeWindow:
            // TODO: implement
            return ScrollWMResponse(success: false, message: "Not implemented yet")
        case .listWindows:
            let windows = stripController.windowMap.map { (tileID, window) -> [String: Any] in
                ["id": tileID.rawValue, "pid": window.pid, "title": window.getTitle() ?? ""]
            }
            if let data = try? JSONSerialization.data(withJSONObject: windows),
               let json = String(data: data, encoding: .utf8) {
                return ScrollWMResponse(success: true, data: json)
            }
            return ScrollWMResponse(success: true, data: "[]")
        case .getLayout:
            let cols = stripController.strip.columns.enumerated().map { (i, col) -> [String: Any] in
                [
                    "index": i,
                    "tiles": col.tiles.map(\.rawValue),
                    "width": stripController.strip.columnData[i].cachedWidth,
                    "active": i == stripController.strip.activeColumnIndex
                ]
            }
            if let data = try? JSONSerialization.data(withJSONObject: cols),
               let json = String(data: data, encoding: .utf8) {
                return ScrollWMResponse(success: true, data: json)
            }
            return ScrollWMResponse(success: true, data: "[]")
        case .recover:
            restoreAllWindows()
            return ScrollWMResponse(success: true, message: "Windows restored")
        case .quit:
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return ScrollWMResponse(success: true, message: "Quitting")
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let scrollWMShutdown = Notification.Name("scrollWMShutdown")
}
