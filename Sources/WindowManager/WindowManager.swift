import AppKit
import Config
import Core
import Foundation
import IPC
import Platform

/// Central coordinator for ScrollWM.
/// Connects WindowTracker (discovery) → StripController (layout) → Platform APIs.
/// All state mutations happen on the main thread via the serial event queue.
public final class WindowManager: @unchecked Sendable {
    public let tracker: WindowTracker
    public let hotkeyManager: HotkeyManager
    public let displayManager: DisplayManager

    private static let isoFormatter = ISO8601DateFormatter()

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

    /// Frame loop for smooth animation — shared across all strip controllers.
    private var frameLoop: FrameLoop?

    /// Gesture capture for trackpad scrolling.
    private var gestureCapture: GestureCapture?

    /// IPC socket server.
    private var ipcServer: SocketServer?

    /// Current configuration.
    public private(set) var config: ScrollWMConfig

    /// State persistence for crash recovery.
    private let stateFilePath: String
    private var stateWriteTimer: Timer?

    /// Pending external focus scroll — debounced to avoid visual flash during space transitions.
    private var pendingFocusScroll: DispatchWorkItem?

    /// Opacity applied to floating windows, keyed by CGWindowID.
    private var floatingWindowOpacities: [CGWindowID: Double] = [:]

    /// Windows that were user-toggled to floating (via alt-space / toggle-floating).
    private var userToggledFloats: Set<CGWindowID> = []

    /// Windows currently pinned (always-on-top), keyed by CGWindowID.
    private var pinnedWindows: Set<CGWindowID> = []

    /// Windows that were user-toggled to always-on-top (via hotkey/IPC).
    private var userToggledPinned: Set<CGWindowID> = []

    /// Recently adopted windows — grace period prevents immediate removal on next health check.
    /// Fixes thrashing when tab-based apps (e.g. Fork) rapidly swap windows during tab switch.
    private var recentlyAdoptedWindows: [CGWindowID: Date] = [:]

    /// Position of most recently removed window per PID, for same-PID tab-switch detection.
    /// When a new window from the same PID appears shortly after, it inherits this position
    /// instead of looking up its own (potentially different) saved position.
    private var recentRemovalsByPID: [pid_t: (position: SavedPosition, date: Date)] = [:]

    /// On-screen window IDs at startup. Used to filter initial discovery so windows on
    /// other Spaces aren't added to the current strip. Cleared after initial batch finishes.
    private var startupOnScreenIDs: Set<UInt32>?

    public init() {
        // Load config first
        let (loadedConfig, configError) = ScrollWMConfig.load()
        self.config = loadedConfig
        if let err = configError {
            #if DEBUG
                print("[WM] Config warning: \(err)")
                fflush(stdout)
            #endif
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
            let wa = info.workingArea(
                struts: struts, primaryScreenHeight: displayManager.primaryScreenHeight)
            stripControllers[displayID] = StripController(
                workingArea: wa, primaryScreenHeight: displayManager.primaryScreenHeight)
        }
        // Ensure at least one strip exists (fallback)
        if stripControllers.isEmpty {
            let wa = CGRect(x: 0, y: 25, width: 1440, height: 875)
            stripControllers[CGMainDisplayID()] = StripController(
                workingArea: wa, primaryScreenHeight: NSScreen.main?.frame.height ?? 0)
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
            // Nil out preset indices that are out of range for the new presets
            for i in 0..<sc.strip.columns.count {
                if let idx = sc.strip.columns[i].presetIndex, idx >= config.widthPresets.count {
                    sc.strip.columns[i].presetIndex = nil
                }
            }
            sc.strip.snapPoints = config.snapPoints
            // Clamp snap indices to new range (prevents crash if snap points shrink)
            for i in 0..<sc.strip.snapIndices.count {
                sc.strip.snapIndices[i] = min(sc.strip.snapIndices[i], config.snapPoints.count - 1)
            }
            sc.animationEnabled = config.animationEnabled
            sc.gestureSnap = config.gestureSnap
            sc.widthSpringParams = config.widthSpringParams
            sc.focusIndicator.reloadConfig(config.focusIndicator)
            sc.focusIndicator.springParams = config.widthSpringParams
            // Zen mode
            let oldZenEnabled = sc.zenDimmer.enabled
            sc.zenDimmer.reloadConfig(config.zenMode)
            // If zen mode was just enabled, apply dimming to already-unfocused windows
            if !oldZenEnabled && config.zenMode.enabled {
                if let activeTile = sc.strip.activeColumn?.activeTile {
                    let allTileIDs = sc.strip.columns.compactMap(\.activeTile)
                    if sc.zenDimmer.setFocusedWindow(
                        activeTile, allTileIDs: allTileIDs, at: TimeUtil.now())
                    {
                        sc.frameLoop?.resume()
                    }
                }
            }
        }

        // Window rules
        tracker.rules = config.rules.map { rule in
            WindowRule(
                appID: rule.appID,
                appIDRegex: rule.appIDRegex,
                titleRegex: rule.titleRegex,
                classification: rule.floating ? .float : .tile,
                opacity: rule.opacity,
                alwaysOnTop: rule.alwaysOnTop
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

        #if DEBUG
            print(
                "[WM] Config applied (gap=\(config.gap), snap=\(config.snapPoints), gestureSnap=\(config.gestureSnap), animation=\(config.animationEnabled))"
            )
            fflush(stdout)
        #endif
    }

    // MARK: - Lifecycle

    /// Start the window manager.
    public func start() {
        #if DEBUG
            print("[WM] start() called")
            fflush(stdout)
        #endif

        // Ensure state directory exists
        let stateDir = (stateFilePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: stateDir, withIntermediateDirectories: true)

        #if DEBUG
            print("[WM] state dir ready")
            fflush(stdout)
        #endif

        // Attempt crash recovery
        recoverFromCrash()

        #if DEBUG
            print("[WM] displays...")
            fflush(stdout)
        #endif
        displayManager.startObserving()
        #if DEBUG
            print(
                "[WM] display done, working area: \(displayManager.mainDisplay?.visibleFrame ?? .zero)"
            )
            fflush(stdout)
        #endif

        // Record initial Space fingerprint for all strips
        let initialWindows = getAllWindowInfo()
        let initialFingerprint = Set(
            initialWindows.filter { $0.layer == 0 && $0.isOnScreen }.map(\.windowID))
        for (_, sc) in stripControllers {
            sc.setSpaceFingerprint(initialFingerprint)
        }

        // Initialize position memory before window discovery
        if config.positionMemory {
            let pmStateDir = NSHomeDirectory() + "/.local/state/scrollwm"
            let filePath = URL(fileURLWithPath: pmStateDir + "/window-positions.json")
            let rules = positionMemoryMatchingRules
            positionMemory = PositionMemory(
                capacity: config.savedPositionLimit, filePath: filePath, matchingRules: rules)
            positionMemory?.loadFromDisk()
        }

        // Start subsystems — batch window discovery to avoid N layout passes.
        // Store on-screen IDs so .windowAdded filters out windows on other Spaces
        // (AX returns ALL windows of an app regardless of Space).
        startupOnScreenIDs = initialFingerprint
        for (_, sc) in stripControllers { sc.beginBatch() }
        #if DEBUG
            print("[WM] tracking windows...")
            fflush(stdout)
        #endif
        tracker.startObserving()
        #if DEBUG
            print("[WM] tracked \(tracker.windows.count) windows, \(tracker.apps.count) apps")
            fflush(stdout)
        #endif
        for (_, sc) in stripControllers { sc.finishBatch() }
        startupOnScreenIDs = nil
        #if DEBUG
            print("[WM] batch finished, strip has \(stripController.strip.columns.count) cols")
            fflush(stdout)
        #endif

        // Wire position memory save callback on each strip controller
        for (displayID, sc) in stripControllers {
            sc.onBeforeRemoveWindow = {
                [weak self] tileID, column, columnData, colIndex, neighborBefore, neighborAfter in
                guard let self, let positionMemory = self.positionMemory, self.config.positionMemory
                else { return }

                guard let window = sc.windowMap[tileID],
                      let bundleID = self.tracker.apps[window.pid]?.bundleIdentifier
                else { return }

                let windowTitle = window.getTitle()
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

                positionMemory.save(
                    bundleID: bundleID, windowTitle: windowTitle,
                    displayID: UInt32(displayID), spaceFingerprint: spaceFingerprint,
                    windowID: window.windowID,
                    position: position)
            }
        }

        hotkeyManager.registerFromConfig(config.keybindings)
        let hotkeyOk = hotkeyManager.start()
        #if DEBUG
            print("[WM] hotkeys: \(hotkeyOk)")
            fflush(stdout)
        #endif

        // Phase 2: Frame loop for smooth animation — shared across all strips
        let fl = FrameLoop()
        self.frameLoop = fl
        fl.onTick = { [weak self] time in
            guard let self = self else { return }
            for (_, sc) in self.stripControllers {
                sc.handleFrameTick(time: time)
            }
            if self.stripControllers.values.allSatisfy({ $0.isFullySettled }) {
                self.frameLoop?.pause()
            }
        }
        fl.start()
        for (_, sc) in stripControllers {
            sc.frameLoop = fl
            sc.animationEnabled = config.animationEnabled
            sc.gestureSnap = config.gestureSnap
            sc.widthSpringParams = config.widthSpringParams
        }
        #if DEBUG
            print("[WM] animation: enabled (\(stripControllers.count) displays)")
            fflush(stdout)
        #endif

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
        #if DEBUG
            print("[WM] gesture capture: \(gestureOk)")
            fflush(stdout)
        #endif

        // Start periodic state persistence (every 5 seconds)
        stateWriteTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) {
            [weak self] _ in
            self?.persistState()
            self?.positionMemory?.persistToDisk()
        }

        #if DEBUG
            print("[WM] Config loaded from \(ScrollWMConfig.configPath)")
            fflush(stdout)
        #endif

        // IPC socket server
        let server = SocketServer()
        server.onCommand = { [weak self] command in
            guard let self = self else {
                return ScrollWMResponse(success: false, message: "Shutting down")
            }
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
                return ScrollWMResponse(
                    success: false, message: "Unknown command: \(message.command)")
            }
        }
        let ipcOk = server.start()
        self.ipcServer = server
        #if DEBUG
            print("[WM] IPC server: \(ipcOk)")
            fflush(stdout)
        #endif

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

        #if DEBUG
            print("[ScrollWM] Window manager started")
            print("[ScrollWM] Tracked windows: \(tracker.windows.count)")
            print("[ScrollWM] Tracked apps: \(tracker.apps.count)")
            print("[ScrollWM] Strip columns: \(stripController.strip.columns.count)")
            print("[ScrollWM] Strip working area: \(stripController.strip.workingArea)")
            fflush(stdout)
        #endif

        // Retry layout after a short delay — some AX observers may not have
        // delivered their initial window list yet at startup
        // Retry layout at 0.5s, 1.5s, and 3s after startup.
        // AX calls can fail on first attempt if apps haven't finished launching.
        for delay in [0.5, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, !self.isPaused else { return }

                let onScreenIDs = Set(getAllWindowInfo().map(\.windowID))
                let adopted = self.adoptUnmanagedWindows(onScreenIDs: onScreenIDs)
                if adopted {
                    self.stripController.clearCommittedFrames()
                    self.stripController.applyLayout()
                }
                #if DEBUG
                    print(
                        "[ScrollWM] Startup retry @\(delay)s: \(self.stripController.strip.columns.count) cols"
                    )
                    fflush(stdout)
                #endif
            }
        }
    }

    /// Stop and restore all windows.
    public func shutdown() {
        #if DEBUG
            print("[WM] Shutting down — restoring windows")
            fflush(stdout)
        #endif
        isPaused = true
        stateWriteTimer?.invalidate()

        // Restore all windows to reasonable on-screen positions
        restoreAllWindows()

        // Restore zen mode alpha for all windows
        for (_, sc) in stripControllers {
            sc.zenDimmer.restoreAll()
        }

        // Restore floating window opacities
        for (wid, _) in floatingWindowOpacities {
            ZenDimmer.setWindowAlpha(wid, 1.0)
        }
        floatingWindowOpacities.removeAll()

        // Restore all pinned windows to normal level
        for wid in pinnedWindows {
            ZenDimmer.setWindowLevel(wid, CGWindowLevelForKey(.normalWindow))
        }
        pinnedWindows.removeAll()
        userToggledPinned.removeAll()

        // Persist final state
        persistState()
        positionMemory?.persistToDisk()

        // Stop subsystems
        ipcServer?.stop()
        for (_, sc) in stripControllers {
            sc.frameLoop?.stop()
            sc.focusIndicator.hide()
        }
        gestureCapture?.stop()
        hotkeyManager.stop()
        tracker.stopObserving()
        displayManager.stopObserving()
    }

    /// Toggle pause/resume.
    public func togglePause() {
        isPaused = !isPaused
        if isPaused {
            #if DEBUG
                print("[WM] Paused")
                fflush(stdout)
            #endif
            for (_, sc) in stripControllers { sc.focusIndicator.hide() }
            restoreAllWindows()
        } else {
            #if DEBUG
                print("[WM] Resumed")
                fflush(stdout)
            #endif
            // Re-discover any windows that aren't in the strip
            let onScreenIDs = Set(getAllWindowInfo().map(\.windowID))
            adoptUnmanagedWindows(onScreenIDs: onScreenIDs)
            // Clear committed frames so the next applyLayout reapplies everything
            for (_, sc) in stripControllers {
                sc.clearCommittedFrames()
                sc.applyLayout()
            }
            // Re-apply always-on-top levels
            for wid in pinnedWindows {
                ZenDimmer.setWindowLevel(wid, CGWindowLevelForKey(.floatingWindow))
            }
        }
    }

    /// Reload config from disk and apply to all subsystems.
    public func reloadConfig() {
        let (newConfig, error) = ScrollWMConfig.load()
        if let err = error {
            #if DEBUG
                print("[WM] Config reload error: \(err)")
                fflush(stdout)
            #endif
            return
        }

        // Apply shared config fields (strip layout, hotkeys, rules, gesture modifier)
        applyConfig(newConfig)

        // Re-evaluate rule opacities for all tiled windows
        for (_, sc) in stripControllers {
            for (_, window) in sc.windowMap {
                let ruleAlpha = resolveRuleOpacity(for: window)
                if let alpha = ruleAlpha, alpha < 1.0 {
                    sc.zenDimmer.setRuleOpacity(for: window.windowID, opacity: alpha)
                } else {
                    sc.zenDimmer.clearRuleOpacity(for: window.windowID)
                }
            }
        }

        // Re-evaluate floating window opacities
        var updatedFloatingOpacities: [CGWindowID: Double] = [:]
        for wid in tracker.floatingWindows {
            guard let window = tracker.windows[wid] else { continue }
            let ruleAlpha = resolveRuleOpacity(for: window)
            if let ruleAlpha, ruleAlpha < 1.0 {
                updatedFloatingOpacities[wid] = ruleAlpha
                ZenDimmer.setWindowAlpha(wid, Float(ruleAlpha))
            } else if userToggledFloats.contains(wid) {
                let alpha = config.floatingOpacity
                if alpha < 1.0 {
                    updatedFloatingOpacities[wid] = alpha
                    ZenDimmer.setWindowAlpha(wid, Float(alpha))
                } else {
                    ZenDimmer.setWindowAlpha(wid, 1.0)
                }
            } else if floatingWindowOpacities[wid] != nil {
                ZenDimmer.setWindowAlpha(wid, 1.0)
            }
        }
        floatingWindowOpacities = updatedFloatingOpacities

        // Re-evaluate always-on-top rules
        let oldPinned = pinnedWindows
        var newPinned = userToggledPinned
        for (_, sc) in stripControllers {
            for (_, window) in sc.windowMap {
                if resolveAlwaysOnTop(for: window) == true {
                    newPinned.insert(window.windowID)
                }
            }
        }
        for wid in tracker.floatingWindows {
            guard let window = tracker.windows[wid] else { continue }
            if resolveAlwaysOnTop(for: window) == true {
                newPinned.insert(wid)
            } else if userToggledFloats.contains(wid) && config.floatingAlwaysOnTop {
                newPinned.insert(wid)
            }
        }
        // Restore level for dropped windows
        for wid in oldPinned.subtracting(newPinned) {
            ZenDimmer.setWindowLevel(wid, CGWindowLevelForKey(.normalWindow))
        }
        pinnedWindows = newPinned
        // Re-apply level for all pinned windows
        for wid in pinnedWindows {
            ZenDimmer.setWindowLevel(wid, CGWindowLevelForKey(.floatingWindow))
        }

        // Position memory (reload-specific: may create or update)
        if config.positionMemory {
            if positionMemory == nil {
                let stateDir = NSHomeDirectory() + "/.local/state/scrollwm"
                let filePath = URL(fileURLWithPath: stateDir + "/window-positions.json")
                positionMemory = PositionMemory(
                    capacity: config.savedPositionLimit, filePath: filePath,
                    matchingRules: positionMemoryMatchingRules)
                positionMemory?.loadFromDisk()
            } else {
                positionMemory?.applyConfig(
                    capacity: config.savedPositionLimit, matchingRules: positionMemoryMatchingRules)
            }
        }

        // Relayout
        stripController.strip.recalculateWidths()
        stripController.clearCommittedFrames()
        stripController.applyLayout()

        #if DEBUG
            print(
                "[WM] Config reloaded (gestureSnap=\(config.gestureSnap), snap=\(config.snapPoints))"
            )
            fflush(stdout)
        #endif
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
                    sc.primaryScreenHeight = self.displayManager.primaryScreenHeight
                    sc.updateWorkingArea(
                        info.workingArea(
                            struts: struts,
                            primaryScreenHeight: self.displayManager.primaryScreenHeight))
                }
            }
            // Use first display as fallback
            if let main = displays.values.first(where: { $0.isMain }) ?? displays.values.first {
                self.stripController.updateWorkingArea(
                    main.workingArea(primaryScreenHeight: self.displayManager.primaryScreenHeight))
            }
        }
    }

    private func handleWindowEvent(_ event: WindowEvent) {
        // Ignore move/resize/focus events that echo from our own layout calls
        if stripController.isInEchoSuppression {
            switch event {
            case .windowResized(let wid):
                #if DEBUG
                    print("[WM] echo-suppressed resize wid=\(wid)")
                    fflush(stdout)
                #endif
                return
            case .windowMoved, .windowFocused:
                return
            default:
                break
            }
        }

        // Suppress focus events after a space switch — macOS refocuses
        // the previously-frontmost app's window on the new space, which
        // would override our restored activeColumnIndex.
        if stripController.isInSpaceSwitchSuppression {
            switch event {
            case .windowFocused:
                #if DEBUG
                    print("[WM] Suppressed post-space-switch focus event")
                    fflush(stdout)
                #endif
                return
            default:
                break
            }
        }

        switch event {
        case .windowAdded(let window, let classification):
            // During startup, skip windows on other Spaces — AX returns all windows
            // regardless of Space, but we should only manage the current one.
            if let onScreen = startupOnScreenIDs, !onScreen.contains(window.windowID) {
                #if DEBUG
                    print("[WM] windowAdded SKIP (off-space) wid=\(window.windowID) pid=\(window.pid)")
                    fflush(stdout)
                #endif
                break
            }

            switch classification {
            case .tile:
                if let app = tracker.apps[window.pid] {
                    let (displayID, sc) = stripControllerEntryForWindow(window)
                    let saved = lookupSavedPosition(for: window, on: sc, displayID: displayID)
                    #if DEBUG
                        print("[WM] windowAdded wid=\(window.windowID) pid=\(window.pid) restored=\(saved != nil)")
                        fflush(stdout)
                    #endif
                    sc.addWindow(window, app: app, restoredPosition: saved)
                    if let ruleAlpha = resolveRuleOpacity(for: window), ruleAlpha < 1.0 {
                        sc.zenDimmer.setRuleOpacity(for: window.windowID, opacity: ruleAlpha)
                    }
                    if resolveAlwaysOnTop(for: window) == true {
                        applyPinState(windowID: window.windowID, pinned: true)
                    }
                }
            case .float:
                // Apply rule opacity to auto-classified floating windows (NOT config.floatingOpacity,
                // which is for user-toggled floats only). Track in floatingWindowOpacities for
                // space-switch reapplication.
                if let ruleAlpha = resolveRuleOpacity(for: window), ruleAlpha < 1.0 {
                    floatingWindowOpacities[window.windowID] = ruleAlpha
                    ZenDimmer.setWindowAlpha(window.windowID, Float(ruleAlpha))
                }
                if resolveAlwaysOnTop(for: window) == true {
                    applyPinState(windowID: window.windowID, pinned: true)
                }
            case .ignore:
                break
            }

        case .windowRemoved(let windowID, let tileID):
            #if DEBUG
                print("[WM] windowRemoved tileID=\(tileID.rawValue)")
                fflush(stdout)
            #endif
            if floatingWindowOpacities.removeValue(forKey: windowID) != nil {
                ZenDimmer.setWindowAlpha(windowID, 1.0)
            }
            userToggledFloats.remove(windowID)
            pinnedWindows.remove(windowID)
            userToggledPinned.remove(windowID)
            ZenDimmer.setWindowLevel(windowID, CGWindowLevelForKey(.normalWindow))
            // Remove from whichever strip has it
            for (_, sc) in stripControllers {
                if sc.windowMap[tileID] != nil {
                    sc.removeWindow(tileID: tileID)
                    break
                }
            }

        case .windowFocused(let windowID):
            let tileID = TileID(windowID)
            // Suppress focus events for windows not on the current strip
            // (destination-space windows during space transitions).
            guard stripController.windowMap[tileID] != nil else {
                #if DEBUG
                    print("[WM] Suppressed pre-space-switch focus wid=\(windowID)")
                    fflush(stdout)
                #endif
                break
            }
            // Debounce the scroll — if spaceChanged arrives within 150ms,
            // the scroll is cancelled and we avoid a visual flash.
            pendingFocusScroll?.cancel()
            let sc = stripController
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isPaused else { return }
                if let colIndex = sc.strip.columns.firstIndex(where: {
                    $0.tiles.contains(tileID)
                }),
                    colIndex != sc.strip.activeColumnIndex
                {
                    sc.scrollToWindow(tileID: tileID)
                }
            }
            pendingFocusScroll = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            // Update user focus — marked as external so saveCurrentSpace can
            // ignore it if a space switch follows within 300ms.
            stripController.userActiveTileID = tileID
            stripController.userActiveTileIDTime = TimeUtil.now()

        case .appActivated(let pid):
            // Cmd+Tab support: find the first window of this app and scroll to it
            if let window = tracker.windows.values.first(where: { $0.pid == pid }) {
                let tileID = window.tileID
                // Debounce — same as windowFocused to avoid space-transition flash
                pendingFocusScroll?.cancel()
                let sc = stripController
                let work = DispatchWorkItem { [weak self] in
                    guard let self, !self.isPaused else { return }
                    if let colIndex = sc.strip.columns.firstIndex(where: {
                        $0.tiles.contains(tileID)
                    }),
                        colIndex != sc.strip.activeColumnIndex
                    {
                        sc.scrollToWindow(tileID: tileID)
                    }
                }
                pendingFocusScroll = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
                stripController.userActiveTileID = tileID
                stripController.userActiveTileIDTime = TimeUtil.now()
            }
            // Focus indicator: hide when unmanaged app activates, show when managed
            let isManaged = tracker.windows.values.contains(where: { $0.pid == pid })
            if isManaged {
                for (_, sc) in stripControllers {
                    if sc.windowMap.values.contains(where: { $0.pid == pid }) {
                        sc.showIndicator()
                    }
                }
            } else {
                for (_, sc) in stripControllers {
                    sc.fadeOutIndicator()
                }
            }

        case .windowMinimized(let windowID):
            #if DEBUG
                print("[WM] windowMinimized wid=\(windowID)")
                fflush(stdout)
            #endif
            stripController.removeWindow(tileID: TileID(windowID))

        case .windowDeminimized(let windowID):
            #if DEBUG
                print("[WM] windowDeminimized wid=\(windowID)")
                fflush(stdout)
            #endif
            if let window = tracker.windows[windowID],
                let app = tracker.apps[window.pid]
            {
                let (displayID, sc) = stripControllerEntryForWindow(window)
                let saved = lookupSavedPosition(for: window, on: sc, displayID: displayID)
                sc.addWindow(window, app: app, restoredPosition: saved)
                if let ruleAlpha = resolveRuleOpacity(for: window), ruleAlpha < 1.0 {
                    sc.zenDimmer.setRuleOpacity(for: window.windowID, opacity: ruleAlpha)
                }
                if pinnedWindows.contains(windowID) || resolveAlwaysOnTop(for: window) == true {
                    applyPinState(windowID: windowID, pinned: true)
                }
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

        // Cancel any pending external focus scroll — it was a space-transition artifact.
        pendingFocusScroll?.cancel()
        pendingFocusScroll = nil

        // Get all currently on-screen window IDs to identify this Space
        let onScreenWindows = getAllWindowInfo()
        let onScreenIDs = Set(
            onScreenWindows.filter { $0.layer == 0 && $0.isOnScreen }.map(\.windowID))
        #if DEBUG
            let leavingTile = stripController.userActiveTileID ?? stripController.strip.activeColumn?.activeTile
            let leavingWindow = leavingTile.flatMap { stripController.windowMap[$0] }
            print("[WM] spaceChanged leaving wid=\(leavingWindow?.windowID ?? 0) title=\(leavingWindow?.getTitle() ?? "none") onScreenIDs=\(onScreenIDs)")
            fflush(stdout)
        #endif

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
                pinnedWindows.remove(goneID)
                userToggledPinned.remove(goneID)
            }

            // Add new windows that weren't in the saved state
            let newWindowIDs = onScreenIDs.subtracting(managedIDs)

            if !newWindowIDs.isEmpty {
                for (pid, app) in tracker.apps {
                    let appWindows = discoverWindows(pid: pid)
                    for window in appWindows {
                        guard newWindowIDs.contains(window.windowID) else { continue }
                        guard !tracker.floatingWindows.contains(window.windowID),
                              !tracker.ignoredWindows.contains(window.windowID)
                        else { continue }
                        let props = window.getPropertiesFast()
                        guard !props.isMinimized && !props.isFullscreen else { continue }
                        let classification = classifyWindow(props)
                        guard classification == .tile else { continue }
                        tracker.registerTrackedWindow(window)
                        app.observeWindow(window.element)
                        let (displayID, targetSC) = stripControllerEntryForWindow(window)
                        let saved = lookupSavedPosition(
                            for: window, on: targetSC, displayID: displayID)
                        targetSC.addWindow(window, app: app, restoredPosition: saved)
                        #if DEBUG
                            print("[WM] space: adopted new wid=\(window.windowID) pid=\(window.pid)")
                            fflush(stdout)
                        #endif
                    }
                }

                #if DEBUG
                    print("[WM] space restored + \(newWindowIDs.count) new windows")
                    fflush(stdout)
                #endif
            } else {
                #if DEBUG
                    print("[WM] space restored: \(stripController.strip.columns.count) cols")
                    fflush(stdout)
                #endif
            }

            // Re-apply rule opacities and always-on-top for all tiled windows on restored space
            for (_, window) in stripController.windowMap {
                if let ruleAlpha = resolveRuleOpacity(for: window), ruleAlpha < 1.0 {
                    stripController.zenDimmer.setRuleOpacity(for: window.windowID, opacity: ruleAlpha)
                }
                if resolveAlwaysOnTop(for: window) == true {
                    applyPinState(windowID: window.windowID, pinned: true)
                }
            }

            // Restore focus to the window the user had active before leaving.
            // Use TileID (not numeric index) so column insertions/removals don't
            // cause us to focus the wrong window.
            if let focusTile = savedFocusTile,
                stripController.windowMap[focusTile] != nil
            {
                stripController.scrollToWindow(tileID: focusTile)
                // Trusted focus — space restore
                stripController.userActiveTileID = focusTile
                stripController._confirmedUserActiveTileID = focusTile
            } else {
                // Original window was closed while away — just re-apply layout
                // with whatever activeColumnIndex removeColumn settled on
                stripController.applyLayout()
            }

            #if DEBUG
                fflush(stdout)
            #endif

            // Reapply floating window opacities — macOS may reset compositing alpha on space switch
            for (wid, alpha) in floatingWindowOpacities {
                ZenDimmer.setWindowAlpha(wid, Float(alpha))
            }

            // Re-apply always-on-top levels
            for wid in pinnedWindows {
                ZenDimmer.setWindowLevel(wid, CGWindowLevelForKey(.floatingWindow))
            }
            return
        }

        // New Space — discover windows from scratch
        stripController.beginBatch()
        for (pid, app) in tracker.apps {
            let appWindows = discoverWindows(pid: pid)
            for window in appWindows {
                guard onScreenIDs.contains(window.windowID) else { continue }
                guard !tracker.floatingWindows.contains(window.windowID),
                      !tracker.ignoredWindows.contains(window.windowID)
                else { continue }

                let props = window.getPropertiesFast()
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

        // Apply rule opacities for tiled windows on new space
        for (_, window) in stripController.windowMap {
            if let ruleAlpha = resolveRuleOpacity(for: window), ruleAlpha < 1.0 {
                stripController.zenDimmer.setRuleOpacity(for: window.windowID, opacity: ruleAlpha)
            }
        }

        // Reapply floating window opacities — macOS may reset compositing alpha on space switch
        for (wid, alpha) in floatingWindowOpacities {
            ZenDimmer.setWindowAlpha(wid, Float(alpha))
        }

        // Evaluate rules for new-space tiled windows
        for (_, window) in stripController.windowMap {
            if resolveAlwaysOnTop(for: window) == true {
                applyPinState(windowID: window.windowID, pinned: true)
            }
        }

        // Re-apply always-on-top levels for pre-existing pinned windows
        for wid in pinnedWindows {
            ZenDimmer.setWindowLevel(wid, CGWindowLevelForKey(.floatingWindow))
        }

        #if DEBUG
            print(
                "[WM] space changed: new strip with \(stripController.strip.columns.count) cols"
            )
            fflush(stdout)
        #endif
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
            if let focusedWID = getFocusedWindowID(),
               tracker.floatingWindows.contains(focusedWID),
               let window = tracker.windows[focusedWID],
               let app = tracker.apps[window.pid]
            {
                tracker.unmarkFloating(focusedWID)
                userToggledFloats.remove(focusedWID)
                // Restore to 1.0 before unfloating — prevents visual jump
                // when ZenDimmer assumes currentAlpha is 1.0
                restoreFloatingOpacity(windowID: focusedWID)
                // Remove auto-pin from floating (keep if user explicitly toggled pin)
                if pinnedWindows.contains(focusedWID) && !userToggledPinned.contains(focusedWID) {
                    applyPinState(windowID: focusedWID, pinned: false)
                }
                stripController.unfloatWindow(window, app: app)
                if let ruleAlpha = resolveRuleOpacity(for: window), ruleAlpha < 1.0 {
                    stripController.zenDimmer.setRuleOpacity(for: focusedWID, opacity: ruleAlpha)
                }
                // Re-apply rule-based pin if matched (now as tiled window)
                if resolveAlwaysOnTop(for: window) == true {
                    applyPinState(windowID: focusedWID, pinned: true)
                }
                #if DEBUG
                    print("[WM] Window \(focusedWID) is now tiled (unfloated)")
                    fflush(stdout)
                #endif
            } else if let window = stripController.toggleFloating() {
                tracker.markFloating(window.windowID)
                userToggledFloats.insert(window.windowID)
                applyFloatingOpacity(windowID: window.windowID, window: window)
                // Auto-pin if floatingAlwaysOnTop or rule matches
                if resolveAlwaysOnTop(for: window) == true || config.floatingAlwaysOnTop {
                    applyPinState(windowID: window.windowID, pinned: true)
                }
                #if DEBUG
                    print("[WM] Window \(window.tileID.rawValue) is now floating")
                    fflush(stdout)
                #endif
            }
        case .closeWindow:
            stripController.closeActiveWindow()
        case .toggleAlwaysOnTop:
            guard let focusedWID = getFocusedWindowID() else { break }
            if pinnedWindows.contains(focusedWID) {
                applyPinState(windowID: focusedWID, pinned: false)
                userToggledPinned.remove(focusedWID)
                #if DEBUG
                    print("[WM] Window \(focusedWID) unpinned")
                    fflush(stdout)
                #endif
            } else {
                applyPinState(windowID: focusedWID, pinned: true)
                userToggledPinned.insert(focusedWID)
                #if DEBUG
                    print("[WM] Window \(focusedWID) pinned (always-on-top)")
                    fflush(stdout)
                #endif
            }
        case .workspace:
            break  // TODO: Phase 3
        }
    }

    // MARK: - Focused Window Query

    /// Get the CGWindowID of the macOS-focused window via Accessibility API.
    private func getFocusedWindowID() -> CGWindowID? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)
        guard err == .success, let value else { return nil }
        // value is AnyObject; AXUIElement is a CFTypeRef alias that always succeeds as? cast,
        // so we rely on the err == .success check above for validity.
        let element = value as! AXUIElement
        return windowID(for: element)
    }

    /// Find the opacity rule that matches a window, if any.
    private func resolveRuleOpacity(for window: AXWindow) -> Double? {
        let bundleID = tracker.apps[window.pid]?.bundleIdentifier
        let title = window.getTitle()
        var props = WindowProperties()
        props.bundleIdentifier = bundleID
        props.title = title
        return tracker.rules.first(where: {
            $0.opacity != nil
            && $0.matches(props)
            && ($0.appIDRegex == nil || bundleID != nil)
            && ($0.titleRegex == nil || title != nil)
        })?.opacity
    }

    /// Apply opacity to a user-toggled floating window and track it.
    private func applyFloatingOpacity(windowID: CGWindowID, window: AXWindow) {
        let ruleOpacity = resolveRuleOpacity(for: window)
        let alpha = ruleOpacity ?? config.floatingOpacity
        if alpha < 1.0 {
            floatingWindowOpacities[windowID] = alpha
            ZenDimmer.setWindowAlpha(windowID, Float(alpha))
        } else {
            floatingWindowOpacities.removeValue(forKey: windowID)
            ZenDimmer.setWindowAlpha(windowID, 1.0)
        }
    }

    /// Restore a floating window to full opacity and remove from tracking.
    private func restoreFloatingOpacity(windowID: CGWindowID) {
        floatingWindowOpacities.removeValue(forKey: windowID)
        ZenDimmer.setWindowAlpha(windowID, 1.0)
    }

    /// Find whether a window matches an always_on_top rule.
    private func resolveAlwaysOnTop(for window: AXWindow) -> Bool? {
        let bundleID = tracker.apps[window.pid]?.bundleIdentifier
        let title = window.getTitle()
        var props = WindowProperties()
        props.bundleIdentifier = bundleID
        props.title = title
        return tracker.rules.first(where: {
            $0.alwaysOnTop != nil
            && $0.matches(props)
            && ($0.appIDRegex == nil || bundleID != nil)
            && ($0.titleRegex == nil || title != nil)
        })?.alwaysOnTop
    }

    /// Apply or remove always-on-top for a window.
    private func applyPinState(windowID: CGWindowID, pinned: Bool) {
        let level: Int32 = pinned ? CGWindowLevelForKey(.floatingWindow) : CGWindowLevelForKey(.normalWindow)
        ZenDimmer.setWindowLevel(windowID, level)
        if pinned {
            pinnedWindows.insert(windowID)
        } else {
            pinnedWindows.remove(windowID)
        }
    }

    // MARK: - Window Health Check

    /// Periodically verify all tracked windows still exist.
    /// Catches closed windows that kAXUIElementDestroyedNotification missed.
    /// Also adopts on-screen windows that should be in the strip but aren't.
    private func checkWindowHealth() {
        guard !isPaused else { return }

        let now = Date()

        // Expire stale tracking entries (> 2s old)
        recentlyAdoptedWindows = recentlyAdoptedWindows.filter { now.timeIntervalSince($0.value) < 2.0 }
        recentRemovalsByPID = recentRemovalsByPID.filter { now.timeIntervalSince($0.value.date) < 2.0 }

        // Get all currently on-screen window IDs from the window server
        let onScreenWindows = getAllWindowInfo()
        let onScreenIDs = Set(onScreenWindows.map(\.windowID))

        // Pass 1: Remove dead windows from the strip
        var changed = false
        for (tileID, window) in stripController.windowMap {
            // Method 1: Check if the window is still in CGWindowList
            if !onScreenIDs.contains(window.windowID) {
                // Fix B: Skip recently adopted windows — gives tab-based apps time
                // to stabilize after a tab switch before we declare the window dead.
                if let adoptedAt = recentlyAdoptedWindows[window.windowID],
                   now.timeIntervalSince(adoptedAt) < 2.0 {
                    #if DEBUG
                        print("[HealthCheck] Skipping recently adopted window wid=\(window.windowID)")
                        fflush(stdout)
                    #endif
                    continue
                }

                // Fix D: Capture position before removal for same-PID tab-switch detection.
                // If another window from this PID appears soon, it inherits this column.
                if let colIndex = stripController.strip.columns.firstIndex(where: { $0.tiles.contains(tileID) }) {
                    let col = stripController.strip.columns[colIndex]
                    let colData = stripController.strip.columnData[colIndex]
                    let width: ColumnWidth = col.width == .auto ? .fixed(colData.cachedWidth) : col.width

                    let neighborBefore: String? = if colIndex > 0,
                        let tile = stripController.strip.columns[colIndex - 1].activeTile,
                        let win = stripController.windowMap[tile],
                        let app = tracker.apps[win.pid] { app.bundleIdentifier } else { nil }
                    let neighborAfter: String? = if colIndex < stripController.strip.columns.count - 1,
                        let tile = stripController.strip.columns[colIndex + 1].activeTile,
                        let win = stripController.windowMap[tile],
                        let app = tracker.apps[win.pid] { app.bundleIdentifier } else { nil }

                    recentRemovalsByPID[window.pid] = (
                        position: SavedPosition(
                            columnIndex: colIndex,
                            neighborBefore: neighborBefore,
                            neighborAfter: neighborAfter,
                            width: width,
                            presetIndex: col.presetIndex,
                            isFullWidth: col.isFullWidth,
                            lastSeen: now),
                        date: now)
                }

                #if DEBUG
                    print("[HealthCheck] Removing dead window wid=\(window.windowID) tileID=\(tileID.rawValue)")
                    fflush(stdout)
                #endif
                stripController.removeWindow(tileID: tileID)
                tracker.untrackWindow(window.windowID)
                pinnedWindows.remove(window.windowID)
                userToggledPinned.remove(window.windowID)
                recentlyAdoptedWindows.removeValue(forKey: window.windowID)
                changed = true
                continue
            }
            // Note: We skip AX probing for windows confirmed alive by CGWindowList.
            // Hung-but-alive apps will still appear here — they are cleaned up
            // when the process eventually terminates and disappears from CGWindowList.
        }

        // Pass 2: Adopt unmanaged windows that should be in the strip.
        // Filter by onScreenIDs to avoid re-adopting windows that Pass 1 just removed
        // (AX API can find windows that CGWindowList doesn't report).
        let didAdopt = adoptUnmanagedWindows(onScreenIDs: onScreenIDs)
        changed = didAdopt || changed

        if changed {
            stripController.clearCommittedFrames()
            stripController.applyLayout()
        }
    }

    /// Discover on-screen windows not currently in the strip and add them.
    /// When `onScreenIDs` is provided, only adopts windows present in that set
    /// (prevents re-adopting windows that CGWindowList doesn't report).
    /// Returns true if any windows were adopted.
    @discardableResult
    private func adoptUnmanagedWindows(onScreenIDs: Set<CGWindowID>? = nil) -> Bool {
        let stripWindowIDs: Set<UInt32> = stripControllers.values.reduce(into: []) { set, sc in
            set.formUnion(sc.windowMap.values.map(\.windowID))
        }
        var adopted = false

        for (pid, app) in tracker.apps {
            let newWindows = discoverWindows(pid: pid)
            for window in newWindows {
                // Skip windows already tracked and in the strip
                guard !stripWindowIDs.contains(window.windowID) else { continue }
                // Skip windows not confirmed on-screen by CGWindowList
                if let onScreenIDs, !onScreenIDs.contains(window.windowID) { continue }
                // Skip windows already tracked as floating/ignored
                guard !tracker.floatingWindows.contains(window.windowID),
                    !tracker.ignoredWindows.contains(window.windowID)
                else { continue }

                let props = window.getPropertiesFast()
                guard !props.isMinimized, !props.isFullscreen else { continue }

                // Check rules, then default classification
                let classification: WindowClassification
                if let ruleResult = tracker.rules.first(where: { $0.matches(props) })?
                    .classification
                {
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

                // Fix D: If a window from this PID was recently removed (tab switch),
                // inherit its position instead of looking up this window's own saved position.
                let saved: SavedPosition?
                if let recent = recentRemovalsByPID[pid],
                   Date().timeIntervalSince(recent.date) < 2.0 {
                    saved = recent.position
                    recentRemovalsByPID.removeValue(forKey: pid)
                    #if DEBUG
                        print("[HealthCheck] Using same-PID position for wid=\(window.windowID) pid=\(pid) col=\(recent.position.columnIndex)")
                        fflush(stdout)
                    #endif
                } else {
                    saved = lookupSavedPosition(for: window, on: targetSC, displayID: displayID)
                }

                targetSC.addWindow(window, app: app, restoredPosition: saved)

                // Fix B: Track adoption time for grace period
                recentlyAdoptedWindows[window.windowID] = Date()

                if let ruleAlpha = resolveRuleOpacity(for: window), ruleAlpha < 1.0 {
                    targetSC.zenDimmer.setRuleOpacity(for: window.windowID, opacity: ruleAlpha)
                }
                if resolveAlwaysOnTop(for: window) == true {
                    applyPinState(windowID: window.windowID, pinned: true)
                }
                adopted = true
                #if DEBUG
                    print(
                        "[HealthCheck] Adopted unmanaged window wid=\(window.windowID) pid=\(pid)")
                    fflush(stdout)
                #endif
            }
        }

        return adopted
    }

    // MARK: - Crash Recovery

    private func persistState() {
        var state: [[String: Any]] = []
        for (_, sc) in stripControllers {
            for (tileID, frame) in sc.lastCommittedFrames {
                let window = sc.windowMap[tileID]
                state.append([
                    "windowID": tileID.rawValue,
                    "bundleID": window?.pid ?? 0,
                    "x": frame.minX,
                    "y": frame.minY,
                    "width": frame.width,
                    "height": frame.height,
                ])
            }
        }

        if let data = try? JSONSerialization.data(withJSONObject: state) {
            try? data.write(to: URL(fileURLWithPath: stateFilePath))
        }
    }

    private func recoverFromCrash() {
        guard FileManager.default.fileExists(atPath: stateFilePath),
            let data = try? Data(contentsOf: URL(fileURLWithPath: stateFilePath)),
            let state = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return
        }

        #if DEBUG
            print("[WM] Found crash recovery state — checking for orphaned windows")
            fflush(stdout)
        #endif

        // Check if any windows are in weird positions and restore them
        // (This is a best-effort recovery — exact matching is hard)
        try? FileManager.default.removeItem(atPath: stateFilePath)
    }

    private func restoreAllWindows() {
        // Preserve each window's current width/height.
        // Only reposition off-screen (sliver) windows back into view.
        for (_, sc) in stripControllers {
            let wa = sc.strip.workingArea
            guard !sc.windowMap.isEmpty else { continue }

            var cascadeOffset: Double = 0
            let cascadeStep: Double = 30

            for (_, window) in sc.windowMap {
                guard case .success(let frame) = window.getFrame() else { continue }

                // Window center is within working area — leave it alone
                let centerX = frame.midX
                let centerY = frame.midY
                if centerX >= wa.minX && centerX <= wa.maxX
                    && centerY >= wa.minY && centerY <= wa.maxY
                {
                    continue
                }

                // Off-screen window: bring back on-screen, keep width/height
                let maxCascade = min(wa.width - frame.width, wa.height - frame.height)
                let wrapLimit = max(maxCascade, cascadeStep)
                let offset = cascadeOffset.truncatingRemainder(dividingBy: wrapLimit)
                let newFrame = CGRect(
                    x: wa.minX + offset, y: wa.minY + offset,
                    width: frame.width, height: frame.height)
                _ = window.setFrame(newFrame)
                cascadeOffset += cascadeStep
            }
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
            if let focusedWID = getFocusedWindowID(),
               tracker.floatingWindows.contains(focusedWID),
               let window = tracker.windows[focusedWID],
               let app = tracker.apps[window.pid]
            {
                tracker.unmarkFloating(focusedWID)
                userToggledFloats.remove(focusedWID)
                restoreFloatingOpacity(windowID: focusedWID)
                if pinnedWindows.contains(focusedWID) && !userToggledPinned.contains(focusedWID) {
                    applyPinState(windowID: focusedWID, pinned: false)
                }
                stripController.unfloatWindow(window, app: app)
                if let ruleAlpha = resolveRuleOpacity(for: window), ruleAlpha < 1.0 {
                    stripController.zenDimmer.setRuleOpacity(for: focusedWID, opacity: ruleAlpha)
                }
                if resolveAlwaysOnTop(for: window) == true {
                    applyPinState(windowID: focusedWID, pinned: true)
                }
            } else if let window = stripController.toggleFloating() {
                tracker.markFloating(window.windowID)
                userToggledFloats.insert(window.windowID)
                applyFloatingOpacity(windowID: window.windowID, window: window)
                if resolveAlwaysOnTop(for: window) == true || config.floatingAlwaysOnTop {
                    applyPinState(windowID: window.windowID, pinned: true)
                }
            }
            return ScrollWMResponse(success: true)
        case .closeWindow:
            stripController.closeActiveWindow()
            return ScrollWMResponse(success: true)
        case .toggleAlwaysOnTop:
            guard let focusedWID = getFocusedWindowID() else {
                return ScrollWMResponse(success: false, message: "No focused window")
            }
            let wasPinned = pinnedWindows.contains(focusedWID)
            if wasPinned {
                applyPinState(windowID: focusedWID, pinned: false)
                userToggledPinned.remove(focusedWID)
            } else {
                applyPinState(windowID: focusedWID, pinned: true)
                userToggledPinned.insert(focusedWID)
            }
            return ScrollWMResponse(success: true,
                message: wasPinned ? "Unpinned" : "Pinned")
        case .listWindows:
            let windows = stripController.windowMap.map { (tileID, window) -> [String: Any] in
                ["id": tileID.rawValue, "pid": window.pid, "title": window.getTitle() ?? ""]
            }
            if let data = try? JSONSerialization.data(withJSONObject: windows),
                let json = String(data: data, encoding: .utf8)
            {
                return ScrollWMResponse(success: true, data: json)
            }
            return ScrollWMResponse(success: true, data: "[]")
        case .getLayout:
            let cols = stripController.strip.columns.enumerated().map { (i, col) -> [String: Any] in
                [
                    "index": i,
                    "tiles": col.tiles.map(\.rawValue),
                    "width": stripController.strip.columnData[i].cachedWidth,
                    "active": i == stripController.strip.activeColumnIndex,
                ]
            }
            if let data = try? JSONSerialization.data(withJSONObject: cols),
                let json = String(data: data, encoding: .utf8)
            {
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
                        "lastSeen": Self.isoFormatter.string(from: entry.position.lastSeen),
                    ]
                }
                if let data = try? JSONSerialization.data(withJSONObject: entries),
                    let json = String(data: data, encoding: .utf8)
                {
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
            for (_, sc) in stripControllers {
                sc.clearCommittedFrames()
                sc.applyLayout()
            }
            return ScrollWMResponse(success: true, message: "Windows recovered")
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
    private func lookupSavedPosition(
        for window: AXWindow, on sc: StripController, displayID: CGDirectDisplayID
    ) -> SavedPosition? {
        guard config.positionMemory, let positionMemory else { return nil }

        let bundleID = tracker.apps[window.pid]?.bundleIdentifier
        guard let bundleID else { return nil }

        let title = window.getTitle()
        let fingerprint = sc.currentSpaceFingerprint

        return positionMemory.lookupAndConsume(
            bundleID: bundleID, windowTitle: title,
            displayID: UInt32(displayID),
            spaceFingerprint: fingerprint,
            windowID: window.windowID)
    }

    /// Returns both the displayID and StripController for a window based on its frame.
    private func stripControllerEntryForWindow(_ window: AXWindow) -> (
        CGDirectDisplayID, StripController
    ) {
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
            let cgFrame = CGRect(
                x: info.frame.minX, y: cgY, width: info.frame.width, height: info.frame.height)
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
