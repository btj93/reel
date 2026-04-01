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
    public let hotkeyManager: HotkeyManager
    public let displayManager: DisplayManager

    /// Per-display strip controllers. One strip per connected monitor.
    public private(set) var stripControllers: [CGDirectDisplayID: StripController] = [:]

    /// Position memory for restoring window placement.
    public var positionMemory: PositionMemory?

    /// The currently active (focused) display.
    public private(set) var activeDisplayID: CGDirectDisplayID = CGMainDisplayID()

    /// Convenience: the strip controller for the active display.
    public var stripController: StripController {
        stripControllers[activeDisplayID] ?? stripControllers.values.first!
    }

    /// Whether management is paused.
    public private(set) var isPaused: Bool = false

    /// Gesture capture for trackpad scrolling.
    private var gestureCapture: GestureCapture?

    /// IPC socket server.
    private var ipcServer: SocketServer?

    /// Current configuration.
    public private(set) var config: ScrollWMConfig


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

        // Create a strip controller for each connected display
        displayManager.refresh()
        let struts = Struts(
            left: CGFloat(config.struts.left),
            right: CGFloat(config.struts.right),
            top: CGFloat(config.struts.top),
            bottom: CGFloat(config.struts.bottom)
        )
        for (displayID, info) in displayManager.displays {
            let wa = info.workingArea(struts: struts, primaryScreenHeight: displayManager.primaryScreenHeight)
            stripControllers[displayID] = StripController(workingArea: wa)
        }
        // Ensure at least one strip exists (fallback)
        if stripControllers.isEmpty {
            let wa = CGRect(x: 0, y: 25, width: 1440, height: 875)
            stripControllers[CGMainDisplayID()] = StripController(workingArea: wa)
        }
        activeDisplayID = displayManager.mainDisplay?.displayID ?? CGMainDisplayID()

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
        for (_, sc) in stripControllers {
            sc.strip.gap = config.gap
            sc.strip.defaultWidth = config.defaultWidth
            sc.strip.widthPresets = config.widthPresets
            sc.strip.snapPoints = config.snapPoints
            // Clamp snap indices to new range (prevents crash if snap points shrink)
            for i in 0..<sc.strip.snapIndices.count {
                sc.strip.snapIndices[i] = min(sc.strip.snapIndices[i], config.snapPoints.count - 1)
            }
            sc.animationEnabled = config.animationEnabled
            sc.gestureSnap = config.gestureSnap
        }

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

        print("[WM] Config applied (gap=\(config.gap), snap=\(config.snapPoints), gestureSnap=\(config.gestureSnap), animation=\(config.animationEnabled))")
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

        // Record initial Space fingerprint for all strips
        let initialWindows = getAllWindowInfo()
        let initialFingerprint = Set(initialWindows.filter { $0.layer == 0 && $0.isOnScreen }.map(\.windowID))
        for (_, sc) in stripControllers {
            sc.setSpaceFingerprint(initialFingerprint)
        }

        // Initialize position memory before window discovery
        if config.positionMemory {
            let pmStateDir = NSHomeDirectory() + "/.local/state/scrollwm"
            let filePath = URL(fileURLWithPath: pmStateDir + "/window-positions.json")
            let rules = positionMemoryMatchingRules
            positionMemory = PositionMemory(capacity: config.savedPositionLimit, filePath: filePath, matchingRules: rules)
            positionMemory?.loadFromDisk()
        }

        // Start subsystems — batch window discovery to avoid N layout passes
        for (_, sc) in stripControllers { sc.beginBatch() }
        print("[WM] tracking windows..."); fflush(stdout)
        tracker.startObserving()
        print("[WM] tracked \(tracker.windows.count) windows, \(tracker.apps.count) apps"); fflush(stdout)
        for (_, sc) in stripControllers { sc.finishBatch() }
        print("[WM] batch finished, strip has \(stripController.strip.columns.count) cols"); fflush(stdout)

        // Wire position memory save callback on each strip controller
        for (displayID, sc) in stripControllers {
            sc.onBeforeRemoveWindow = { [weak self] tileID, column, columnData, colIndex, neighborBefore, neighborAfter in
                guard let self, let positionMemory = self.positionMemory, self.config.positionMemory else { return }

                let window = sc.windowMap[tileID]
                let bundleID = window.flatMap { self.tracker.apps[$0.pid]?.bundleIdentifier }
                guard let bundleID else { return }

                let windowTitle = window?.getTitle()
                let spaceFingerprint = sc.currentSpaceFingerprint

                // Normalize .auto width to .fixed
                let width: ColumnWidth
                switch column.width {
                case .auto:
                    width = .fixed(columnData.cachedWidth)
                default:
                    width = column.width
                }

                let position = SavedPosition(
                    columnIndex: colIndex,
                    neighborBefore: neighborBefore,
                    neighborAfter: neighborAfter,
                    width: width,
                    presetIndex: column.presetIndex,
                    isFullWidth: column.isFullWidth,
                    lastSeen: Date()
                )

                positionMemory.save(bundleID: bundleID, windowTitle: windowTitle,
                                    displayID: UInt32(displayID), spaceFingerprint: spaceFingerprint,
                                    position: position)
            }
        }

        hotkeyManager.registerFromConfig(config.keybindings)
        let hotkeyOk = hotkeyManager.start()
        print("[WM] hotkeys: \(hotkeyOk)"); fflush(stdout)

        // Phase 2: Frame loop for smooth animation — shared across all strips
        let frameLoop = FrameLoop()
        frameLoop.onTick = { [weak self] time in
            guard let self = self else { return }
            for (_, sc) in self.stripControllers {
                sc.handleFrameTick(time: time)
            }
        }
        frameLoop.start()
        for (_, sc) in stripControllers {
            sc.frameLoop = frameLoop
            sc.animationEnabled = config.animationEnabled
            sc.gestureSnap = config.gestureSnap
        }
        print("[WM] animation: enabled (\(stripControllers.count) displays)"); fflush(stdout)

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
            self?.positionMemory?.persistToDisk()
        }

        print("[WM] Config loaded from \(ScrollWMConfig.configPath)"); fflush(stdout)

        // IPC socket server
        let server = SocketServer()
        server.onCommand = { [weak self] command in
            guard let self = self else { return ScrollWMResponse(success: false, message: "Shutting down") }
            return self.handleIPCCommand(command)
        }
        server.onMessage = { [weak self] message in
            guard let self else { return ScrollWMResponse(success: false, message: "No handler") }
            switch message.command {
            case "clear-positions-app":
                guard let appID = message.appID else {
                    return ScrollWMResponse(success: false, message: "Missing appID")
                }
                self.positionMemory?.clear(bundleID: appID)
                self.positionMemory?.persistToDisk()
                return ScrollWMResponse(success: true, message: "Cleared positions for \(appID)")
            default:
                // Fall back to standard command handling
                if let cmd = ScrollWMCommand(rawValue: message.command) {
                    return self.handleIPCCommand(cmd)
                }
                return ScrollWMResponse(success: false, message: "Unknown command: \(message.command)")
            }
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
        positionMemory?.persistToDisk()

        // Stop subsystems
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

    /// Reload config from disk and apply to all subsystems.
    public func reloadConfig() {
        let (newConfig, error) = ScrollWMConfig.load()
        if let err = error {
            print("[WM] Config reload error: \(err)")
            fflush(stdout)
            return
        }

        config = newConfig

        // Apply to strip
        for (_, sc) in stripControllers {
            sc.strip.gap = config.gap
            sc.strip.defaultWidth = config.defaultWidth
            sc.strip.widthPresets = config.widthPresets
            sc.strip.snapPoints = config.snapPoints
            for i in 0..<sc.strip.snapIndices.count {
                sc.strip.snapIndices[i] = min(sc.strip.snapIndices[i], config.snapPoints.count - 1)
            }
            sc.animationEnabled = config.animationEnabled
            sc.gestureSnap = config.gestureSnap
        }

        // Apply to hotkeys
        hotkeyManager.registerFromConfig(config.keybindings)

        // Apply to tracker rules
        tracker.rules = config.rules.map { rule in
            WindowRule(
                appID: rule.appID,
                appIDRegex: rule.appIDRegex,
                titleRegex: rule.titleRegex,
                classification: rule.floating ? .float : .tile
            )
        }

        // Position memory
        if config.positionMemory {
            if positionMemory == nil {
                let stateDir = NSHomeDirectory() + "/.local/state/scrollwm"
                let filePath = URL(fileURLWithPath: stateDir + "/window-positions.json")
                let rules = config.positionMemoryRules.reduce(into: [String: String]()) { dict, rule in
                    dict[rule.appID] = rule.matchBy
                }
                positionMemory = PositionMemory(capacity: config.savedPositionLimit, filePath: filePath, matchingRules: rules)
                positionMemory?.loadFromDisk()
            } else {
                let rules = config.positionMemoryRules.reduce(into: [String: String]()) { dict, rule in
                    dict[rule.appID] = rule.matchBy
                }
                positionMemory?.applyConfig(capacity: config.savedPositionLimit, matchingRules: rules)
            }
        }

        // Relayout
        stripController.strip.recalculateWidths()
        stripController.clearCommittedFrames()
        stripController.applyLayout()

        print("[WM] Config reloaded (gestureSnap=\(config.gestureSnap), snap=\(config.snapPoints))")
        fflush(stdout)
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

        // Display changes → recalculate layout for all displays
        displayManager.onDisplayChange = { [weak self] displays in
            guard let self = self else { return }
            let struts = Struts(
                left: CGFloat(self.config.struts.left),
                right: CGFloat(self.config.struts.right),
                top: CGFloat(self.config.struts.top),
                bottom: CGFloat(self.config.struts.bottom)
            )
            for (displayID, info) in displays {
                if let sc = self.stripControllers[displayID] {
                    sc.updateWorkingArea(info.workingArea(struts: struts, primaryScreenHeight: self.displayManager.primaryScreenHeight))
                }
            }
            // Use first display as fallback
            if let main = displays.values.first(where: { $0.isMain }) ?? displays.values.first {
                self.stripController.updateWorkingArea(main.workingArea(primaryScreenHeight: self.displayManager.primaryScreenHeight))
            }
        }
    }

    private func handleWindowEvent(_ event: WindowEvent) {
        // Ignore move/resize/focus events that echo from our own layout calls
        if stripController.isInEchoSuppression {
            switch event {
            case .windowResized, .windowMoved, .windowFocused, .appActivated:
                return
            default:
                break
            }
        }

        switch event {
        case .windowAdded(let window, let classification):
            guard classification == .tile else { return }
            if let app = tracker.apps[window.pid] {
                let (displayID, sc) = stripControllerEntryForWindow(window)
                let saved = lookupSavedPosition(for: window, on: sc, displayID: displayID)
                sc.addWindow(window, app: app, restoredPosition: saved)
            }

        case .windowRemoved(_, let tileID):
            // Remove from whichever strip has it
            for (_, sc) in stripControllers {
                if sc.windowMap[tileID] != nil {
                    sc.removeWindow(tileID: tileID)
                    break
                }
            }

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
                let (displayID, sc) = stripControllerEntryForWindow(window)
                let saved = lookupSavedPosition(for: window, on: sc, displayID: displayID)
                sc.addWindow(window, app: app, restoredPosition: saved)
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
            // Remember which window was focused before we modify the strip
            let savedFocusTile = stripController.strip.activeColumn?.activeTile

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
                        let (displayID, targetSC) = stripControllerEntryForWindow(window)
                        let saved = lookupSavedPosition(for: window, on: targetSC, displayID: displayID)
                        targetSC.addWindow(window, app: app, restoredPosition: saved)
                    }
                }

                print("[ScrollWM] Space restored + \(newWindowIDs.count) new windows")
            } else {
                print("[ScrollWM] Space restored: \(stripController.strip.columns.count) cols")
            }

            // Restore focus to the window the user had active before leaving.
            // Use TileID (not numeric index) so column insertions/removals don't
            // cause us to focus the wrong window.
            if let focusTile = savedFocusTile,
               stripController.windowMap[focusTile] != nil {
                stripController.scrollToWindow(tileID: focusTile)
            } else {
                // Original window was closed while away — just re-apply layout
                // with whatever activeColumnIndex removeColumn settled on
                stripController.applyLayout()
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
                let (displayID, targetSC) = stripControllerEntryForWindow(window)
                let saved = lookupSavedPosition(for: window, on: targetSC, displayID: displayID)
                targetSC.addWindow(window, app: app, restoredPosition: saved)
            }
        }
        stripController.finishBatch()

        print("[ScrollWM] Space changed: new strip with \(stripController.strip.columns.count) cols")
        fflush(stdout)
    }

    public func performAction(_ action: HotkeyAction) {
        guard !isPaused else { return }
        handleHotkeyAction(action)
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
            if let window = stripController.toggleFloating() {
                // Window is now floating — it keeps its current position
                print("[WM] Window \(window.tileID.rawValue) is now floating")
                fflush(stdout)
            }
        case .closeWindow:
            stripController.closeActiveWindow()
        case .workspace:
            break  // TODO: Phase 3
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
                let (displayID, targetSC) = stripControllerEntryForWindow(window)
                let saved = lookupSavedPosition(for: window, on: targetSC, displayID: displayID)
                targetSC.addWindow(window, app: app, restoredPosition: saved)
                adopted = true
                print("[HealthCheck] Adopted unmanaged window wid=\(window.windowID) pid=\(pid)")
                fflush(stdout)
            }
        }

        return adopted
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
            let window = stripController.toggleFloating()
            return ScrollWMResponse(success: true, message: window != nil ? "Toggled floating" : "No active window")
        case .closeWindow:
            stripController.closeActiveWindow()
            return ScrollWMResponse(success: true)
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
        case .listPositions:
            if let pm = positionMemory {
                let entries = pm.allEntries().map { entry -> [String: Any] in
                    [
                        "bundleID": entry.key.bundleID,
                        "windowTitle": entry.key.windowTitle ?? "nil",
                        "displayID": entry.key.displayID,
                        "columnIndex": entry.position.columnIndex,
                        "width": "\(entry.position.width)",
                        "lastSeen": ISO8601DateFormatter().string(from: entry.position.lastSeen),
                    ]
                }
                if let data = try? JSONSerialization.data(withJSONObject: entries),
                   let json = String(data: data, encoding: .utf8) {
                    return ScrollWMResponse(success: true, data: json)
                }
            }
            return ScrollWMResponse(success: true, data: "[]")

        case .clearPositions:
            positionMemory?.clearAll()
            positionMemory?.persistToDisk()
            return ScrollWMResponse(success: true, message: "Cleared all saved positions")
        case .recover:
            restoreAllWindows()
            return ScrollWMResponse(success: true, message: "Windows restored")
        case .quit:
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return ScrollWMResponse(success: true, message: "Quitting")
        }
    }

    // MARK: - Multi-Monitor Helpers

    /// Convert config position memory rules to the dictionary format PositionMemory expects.
    private var positionMemoryMatchingRules: [String: String] {
        config.positionMemoryRules.reduce(into: [String: String]()) { dict, rule in
            dict[rule.appID] = rule.matchBy
        }
    }

    /// Look up a saved position for a window and consume it if found.
    private func lookupSavedPosition(for window: AXWindow, on sc: StripController, displayID: CGDirectDisplayID) -> SavedPosition? {
        guard config.positionMemory, let positionMemory else { return nil }

        let bundleID = tracker.apps[window.pid]?.bundleIdentifier
        guard let bundleID else { return nil }

        let title = window.getTitle()
        let fingerprint = sc.currentSpaceFingerprint

        guard let result = positionMemory.lookup(bundleID: bundleID, windowTitle: title,
                                                  displayID: UInt32(displayID),
                                                  spaceFingerprint: fingerprint) else {
            return nil
        }

        positionMemory.consume(key: result.key)
        return result.position
    }

    /// Returns both the displayID and StripController for a window based on its frame.
    private func stripControllerEntryForWindow(_ window: AXWindow) -> (CGDirectDisplayID, StripController) {
        if let frame = try? window.getFrame().get() {
            for (displayID, sc) in stripControllers {
                if sc.strip.workingArea.intersects(frame) {
                    return (displayID, sc)
                }
            }
        }
        let primary = stripControllers.first!
        return (primary.key, primary.value)
    }

    /// Determine which strip controller a window belongs to based on its screen position.
    private func stripControllerForWindow(_ window: AXWindow) -> StripController? {
        guard case .success(let frame) = window.getFrame() else { return nil }
        let windowCenter = CGPoint(x: frame.midX, y: frame.midY)

        for (displayID, info) in displayManager.displays {
            let cgY = displayManager.primaryScreenHeight - info.frame.maxY
            let cgFrame = CGRect(x: info.frame.minX, y: cgY, width: info.frame.width, height: info.frame.height)
            if cgFrame.contains(windowCenter) {
                return stripControllers[displayID]
            }
        }
        return nil
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let scrollWMShutdown = Notification.Name("scrollWMShutdown")
}
