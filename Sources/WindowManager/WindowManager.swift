import AppKit
import Config
import Core
import Foundation
import IPC
import Platform

/// Central coordinator for Reel.
/// Connects WindowTracker (discovery) → StripController (layout) → Platform APIs.
/// All state mutations happen on the main thread via the serial event queue.
public final class WindowManager: @unchecked Sendable {
    public let tracker: WindowTracker
    public let hotkeyManager: HotkeyManager
    public let displayManager: DisplayManager

    private static let isoFormatter = ISO8601DateFormatter()

    /// Per-display strip controllers. One strip per connected monitor.
    public private(set) var stripControllers: [CGDirectDisplayID: StripController] = [:]

    /// Snapshot store for restoring window placement.
    public var snapshotStore: StripSnapshotStore?

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

    /// Title bar interaction (long-press, drag-to-reorder, context menu).
    private var titleBarInteraction: TitleBarInteraction?

    /// IPC socket server.
    private var ipcServer: SocketServer?

    /// Current configuration.
    public private(set) var config: ReelConfig

    /// State persistence for crash recovery.
    private let stateFilePath: String
    private var stateWriteTimer: Timer?
    private var healthCheckTimer: Timer?

    /// Pending external focus scroll — debounced to avoid visual flash during space transitions.
    private var pendingFocusScroll: DispatchWorkItem?

    private let reorderOverlay = ReorderOverlayController()
    private var isReorderPending = false

    /// Windows that were user-toggled to floating (via alt-space / toggle-floating).
    private var userToggledFloats: Set<CGWindowID> = []

    /// Recently adopted windows — grace period prevents immediate removal on next health check.
    /// Fixes thrashing when tab-based apps (e.g. Fork) rapidly swap windows during tab switch.
    private var recentlyAdoptedWindows: [CGWindowID: Date] = [:]

    /// Position of most recently removed window per PID, for same-PID tab-switch detection.
    /// When a new window from the same PID appears shortly after, it inherits this position
    /// instead of looking up its own (potentially different) saved position.
    private var recentRemovalsByPID: [pid_t: RecentRemoval] = [:]

    /// On-screen window IDs at startup. Used to filter initial discovery so windows on
    /// other Spaces aren't added to the current strip. Cleared after initial batch finishes.
    private var startupOnScreenIDs: Set<UInt32>?

    public init() {
        // Load config first
        let (loadedConfig, configError) = ReelConfig.load()
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
        let stateDir = NSHomeDirectory() + "/.local/state/reel"
        self.stateFilePath = stateDir + "/window-state.json"

        // Apply config to all subsystems
        applyConfig(config)
        setupEventHandlers()
    }

    /// Apply config values to all subsystems.
    public func applyConfig(_ config: ReelConfig) {
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
            gc.requiredModifier = Self.parseModifierFlag(config.gestureModifier)
            gc.swipeThresholdPx = config.trackpad.swipeThresholdPx
        }

        // Trackpad config
        if let tb = titleBarInteraction {
            tb.longPressDelayMs = config.trackpad.longPressDelayMs
            tb.dragThresholdPx = config.trackpad.dragThresholdPx
            tb.requiredModifier = Self.parseModifierFlag(config.gestureModifier)
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

        // Initialize snapshot store before window discovery
        if config.positionMemory {
            let stateDir = NSHomeDirectory() + "/.local/state/reel"
            let filePath = URL(fileURLWithPath: stateDir + "/window-snapshots.json")
            snapshotStore = StripSnapshotStore(filePath: filePath)
            snapshotStore?.loadFromDisk()
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

        // No per-removal callback needed — snapshot model uses debounced strip capture

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
        gestureCapture.swipeThresholdPx = config.trackpad.swipeThresholdPx
        gestureCapture.onFocusSwipe = { [weak self] velocity in
            guard let sc = self?.stripController else { return }
            if velocity < 0 {
                sc.focusLeftAnimated(velocity: velocity)
            } else {
                sc.focusRightAnimated(velocity: velocity)
            }
        }
        let gestureOk = gestureCapture.start()
        self.gestureCapture = gestureCapture

        // Title bar interaction setup
        let titleBar = TitleBarInteraction()
        titleBar.longPressDelayMs = config.trackpad.longPressDelayMs
        titleBar.dragThresholdPx = config.trackpad.dragThresholdPx
        titleBar.requiredModifier = Self.parseModifierFlag(config.gestureModifier)
        titleBar.onNeedsManagedFrames = { [weak self] () -> (frames: [TileID: CGRect], primaryScreenHeight: CGFloat) in
            guard let sc = self?.stripController else {
                return (frames: [:], primaryScreenHeight: 0)
            }
            return (frames: sc.lastCommittedFrames, primaryScreenHeight: sc.primaryScreenHeight)
        }

        titleBar.onNeedsTileColumnIndex = { [weak self] (tileID: TileID) -> Int? in
            guard let sc = self?.stripController else { return nil }
            for (i, col) in sc.strip.columns.enumerated() {
                if col.tiles.contains(tileID) { return i }
            }
            return nil
        }

        titleBar.onDragBegin = { [weak self] columnIndex in
            guard let self = self else { return }
            let sc = self.stripController
            let columns = self.buildColumnInfos(from: sc)
            self.reorderOverlay.onCommit = { [weak self] sourceIndex, insertionIndex in
                guard let self = self else { return }
                // Convert gap-based insertion index to position index for moveColumn.
                // moveColumn uses remove-then-insert, so after removing sourceIndex,
                // indices >= sourceIndex shift down by 1.
                let destIndex = insertionIndex > sourceIndex ? insertionIndex - 1 : insertionIndex
                if sourceIndex != destIndex {
                    let time = TimeUtil.now()
                    self.stripController.strip.moveColumn(from: sourceIndex, to: destIndex, at: time)
                    let _ = self.stripController.strip.recenterActiveColumnAnimated(at: time)
                    self.stripController.frameLoop?.resume()
                    self.scheduleSnapshotSave()
                }
                self.isReorderPending = false
            }
            // Use the full display frame in AppKit coordinates for the overlay window.
            let displayID = self.stripControllers.first(where: { $0.value === sc })?.key ?? self.activeDisplayID
            let screenFrame = self.displayManager.displays[displayID]?.frame ?? sc.strip.workingArea
            self.reorderOverlay.show(
                columns: columns,
                draggedIndex: columnIndex,
                screenFrame: screenFrame,
                primaryScreenHeight: sc.primaryScreenHeight,
                thumbnailStyle: self.config.reorderOverlay.thumbnailStyle,
                thumbnailHeight: self.config.reorderOverlay.thumbnailHeight,
                gap: self.config.gap
            )
        }

        titleBar.onDragUpdate = { [weak self] (cgPoint: CGPoint) in
            self?.reorderOverlay.updateCursor(position: cgPoint)
        }

        titleBar.onDragEnd = { [weak self] (_: Int) in
            guard let self = self else { return }
            self.isReorderPending = true
            self.reorderOverlay.commitDrop()
        }

        titleBar.onDragCancel = { [weak self] in
            guard let self = self else { return }
            self.reorderOverlay.cancel()
            self.isReorderPending = false
        }
        titleBar.onMenuShow = { [weak self] (columnIndex: Int, cgMousePoint: CGPoint) in
            guard let self = self else { return }
            let sc = self.stripController
            let pills = sc.buildPillItems(for: columnIndex)
            // Convert CG cursor position to AppKit coords for overlay positioning
            let appKitY = sc.primaryScreenHeight - cgMousePoint.y
            let anchorFrame = CGRect(x: cgMousePoint.x, y: appKitY, width: 0, height: 0)
            self.titleBarInteraction?.overlay.mode = .menu(
                pills: pills, anchorFrame: anchorFrame, selectedIndex: nil
            )
            self.titleBarInteraction?.overlay.show()
        }
        titleBar.onMenuSelect = { [weak self] (actionIndex: Int) in
            guard let self = self else { return }
            let sc = self.stripController
            if let action = sc.pillAction(for: actionIndex) {
                switch action {
                case .widthPreset(let idx):
                    sc.setWidthPreset(index: idx)
                case .fullWidth:
                    sc.toggleFullWidth()
                case .toggleFloat:
                    // Use the same dispatch path as the hotkey
                    self.performAction(.toggleFloating)
                }
            }
            self.titleBarInteraction?.overlay.hide()
        }
        titleBar.onMenuDismiss = { [weak self] in
            self?.titleBarInteraction?.overlay.hide()
        }

        let titleBarOk = titleBar.start()
        self.titleBarInteraction = titleBar
        #if DEBUG
            print("[WM] title bar interaction: \(titleBarOk)")
            fflush(stdout)
        #endif
        #if DEBUG
            print("[WM] gesture capture: \(gestureOk)")
            fflush(stdout)
        #endif

        // Start periodic state persistence (every 5 seconds)
        stateWriteTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) {
            [weak self] _ in
            self?.persistState()
            self?.snapshotStore?.persistToDisk()
        }

        #if DEBUG
            print("[WM] Config loaded from \(ReelConfig.configPath)")
            fflush(stdout)
        #endif

        // IPC socket server
        let server = SocketServer()
        server.onCommand = { [weak self] command in
            guard let self = self else {
                return ReelResponse(success: false, message: "Shutting down")
            }
            return self.handleIPCCommand(command)
        }
        server.onMessage = { [weak self] message in
            guard let self else { return ReelResponse(success: false, message: "No handler") }
            switch message.command {
            case "clear-positions-app":
                guard let appID = message.appID else {
                    return ReelResponse(success: false, message: "Missing appID")
                }
                self.snapshotStore?.clear(bundleID: appID)
                self.snapshotStore?.persistToDisk()
                return ReelResponse(success: true, message: "Cleared positions for \(appID)")
            default:
                // Fall back to standard command handling
                if let cmd = ReelCommand(rawValue: message.command) {
                    return self.handleIPCCommand(cmd)
                }
                return ReelResponse(
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
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
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
            print("[Reel] Window manager started")
            print("[Reel] Tracked windows: \(tracker.windows.count)")
            print("[Reel] Tracked apps: \(tracker.apps.count)")
            print("[Reel] Strip columns: \(stripController.strip.columns.count)")
            print("[Reel] Strip working area: \(stripController.strip.workingArea)")
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
                        "[Reel] Startup retry @\(delay)s: \(self.stripController.strip.columns.count) cols"
                    )
                    fflush(stdout)
                #endif
            }
        }
    }

    /// Recover windows — reposition all managed windows to their strip positions.
    public func recoverWindows() {
        restoreAllWindows()
        for (_, sc) in stripControllers {
            sc.clearCommittedFrames()
            sc.applyLayout()
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
        healthCheckTimer?.invalidate()

        // Restore all windows to reasonable on-screen positions
        restoreAllWindows()

        // Persist final state
        persistState()
        // Save all snapshots before shutdown
        for (displayID, sc) in stripControllers {
            let key = SnapshotKey(displayID: UInt32(displayID), spaceFingerprint: sc.currentSpaceFingerprint)
            if let snapshot = captureSnapshot(sc: sc) {
                snapshotStore?.saveImmediate(snapshot, for: key)
            }
        }
        snapshotStore?.persistToDisk()

        // Stop subsystems
        ipcServer?.stop()
        for (_, sc) in stripControllers {
            sc.frameLoop?.stop()
            sc.focusIndicator.hide()
        }
        titleBarInteraction?.stop()
        titleBarInteraction = nil
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
            hotkeyManager.suspended = true
            if let tap = hotkeyManager.eventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
            }
            for (_, sc) in stripControllers { sc.focusIndicator.hide() }
            restoreAllWindows()
        } else {
            #if DEBUG
                print("[WM] Resumed")
                fflush(stdout)
            #endif
            hotkeyManager.suspended = false
            if let tap = hotkeyManager.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            // Re-discover any windows that aren't in the strip
            let onScreenIDs = Set(getAllWindowInfo().map(\.windowID))
            adoptUnmanagedWindows(onScreenIDs: onScreenIDs)
            // Clear committed frames so the next applyLayout reapplies everything
            for (_, sc) in stripControllers {
                sc.clearCommittedFrames()
                sc.applyLayout()
            }
        }
    }

    /// Reload config from disk and apply to all subsystems.
    public func reloadConfig() {
        let (newConfig, error) = ReelConfig.load()
        if let err = error {
            #if DEBUG
                print("[WM] Config reload error: \(err)")
                fflush(stdout)
            #endif
            return
        }

        // Apply shared config fields (strip layout, hotkeys, rules, gesture modifier)
        applyConfig(newConfig)

        // Snapshot store (reload-specific: may create)
        if config.positionMemory, snapshotStore == nil {
            let stateDir = NSHomeDirectory() + "/.local/state/reel"
            let filePath = URL(fileURLWithPath: stateDir + "/window-snapshots.json")
            snapshotStore = StripSnapshotStore(filePath: filePath)
            snapshotStore?.loadFromDisk()
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
            guard let self = self else { return }
            if self.isPaused {
                // While paused, still restore windows when switching spaces
                // so off-screen (sliver) windows become reachable.
                if case .spaceChanged = event {
                    self.restoreAllWindows()
                }
                return
            }
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
                    let saved = resolveSnapshotPosition(for: window, on: sc, displayID: displayID)
                    #if DEBUG
                        print("[WM] windowAdded wid=\(window.windowID) pid=\(window.pid) restored=\(saved != nil)")
                        fflush(stdout)
                    #endif
                    sc.addWindow(window, app: app, restoredPosition: saved)
                    scheduleSnapshotSave(sc: sc)
                }
            case .float:
                break
            case .ignore:
                break
            }

        case .windowRemoved(let windowID, let tileID):
            #if DEBUG
                print("[WM] windowRemoved tileID=\(tileID.rawValue)")
                fflush(stdout)
            #endif
            userToggledFloats.remove(windowID)
            // Remove from whichever strip has it
            for (_, sc) in stripControllers {
                if sc.windowMap[tileID] != nil {
                    sc.removeWindow(tileID: tileID)
                    scheduleSnapshotSave(sc: sc)
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
            scheduleSnapshotSave()

        case .windowDeminimized(let windowID):
            #if DEBUG
                print("[WM] windowDeminimized wid=\(windowID)")
                fflush(stdout)
            #endif
            if userToggledFloats.contains(windowID) {
                // Was floating before minimize — restore as floating, macOS handles the frame
                tracker.markFloating(windowID)
                #if DEBUG
                    print("[WM] windowDeminimized wid=\(windowID) restored as floating")
                    fflush(stdout)
                #endif
            } else if let window = tracker.windows[windowID],
                let app = tracker.apps[window.pid]
            {
                let (displayID, sc) = stripControllerEntryForWindow(window)
                let saved = resolveSnapshotPosition(for: window, on: sc, displayID: displayID)
                sc.addWindow(window, app: app, restoredPosition: saved)
                scheduleSnapshotSave(sc: sc)
            }

        case .windowResized(let windowID):
            // User resized a window — update the strip column width to match
            stripController.handleUserResize(windowID: windowID)
            scheduleSnapshotSave()

        case .windowMoved(let windowID):
            // User dragged a window — snap it back to its strip position
            stripController.handleUserMove(windowID: windowID)

        case .spaceChanged:
            handleSpaceChange()
        }
    }

    private func handleSpaceChange() {
        guard !isPaused else { return }

        // Cancel any in-progress title bar drag/menu — space transition invalidates context.
        titleBarInteraction?.cancelIfActive()

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

        // Save snapshot for the leaving space before switching
        saveSnapshotImmediate(sc: stripController)

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
                        let saved = resolveSnapshotPosition(
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
                let saved = resolveSnapshotPosition(for: window, on: targetSC, displayID: displayID)
                targetSC.addWindow(window, app: app, restoredPosition: saved)
            }
        }
        stripController.finishBatch()

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
        if isReorderPending {
            switch action {
            case .focusLeft, .focusRight, .moveColumnLeft, .moveColumnRight:
                return
            default:
                break
            }
        }
        switch action {
        case .focusLeft:
            stripController.focusLeft()
        case .focusRight:
            stripController.focusRight()
        case .moveColumnLeft:
            stripController.moveColumnLeft()
            scheduleSnapshotSave()
        case .moveColumnRight:
            stripController.moveColumnRight()
            scheduleSnapshotSave()
        case .cycleWidthPreset:
            stripController.cycleWidthPreset()
            scheduleSnapshotSave()
        case .toggleFullWidth:
            stripController.toggleFullWidth()
            scheduleSnapshotSave()
        case .toggleFloating:
            if let focusedWID = getFocusedWindowID(),
               tracker.floatingWindows.contains(focusedWID),
               let window = tracker.windows[focusedWID],
               let app = tracker.apps[window.pid]
            {
                tracker.unmarkFloating(focusedWID)
                userToggledFloats.remove(focusedWID)
                let (displayID, sc) = stripControllerEntryForWindow(window)
                let restored = resolveSnapshotPosition(for: window, on: sc, displayID: displayID)
                stripController.unfloatWindow(window, app: app, restoredPosition: restored)
                scheduleSnapshotSave()
                #if DEBUG
                    print("[WM] Window \(focusedWID) is now tiled (unfloated)")
                    fflush(stdout)
                #endif
            } else if let window = stripController.toggleFloating() {
                saveSnapshotImmediate(sc: stripController)
                tracker.markFloating(window.windowID)
                userToggledFloats.insert(window.windowID)
                #if DEBUG
                    print("[WM] Window \(window.tileID.rawValue) is now floating")
                    fflush(stdout)
                #endif
            }
        case .closeWindow:
            stripController.closeActiveWindow()
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

                // Capture position before removal for same-PID tab-switch detection.
                // If another window from this PID appears soon, it inherits this column.
                if let colIndex = stripController.strip.columns.firstIndex(where: { $0.tiles.contains(tileID) }) {
                    let col = stripController.strip.columns[colIndex]
                    let colData = stripController.strip.columnData[colIndex]
                    let width: ColumnWidth = col.width == .auto ? .fixed(colData.cachedWidth) : col.width
                    recentRemovalsByPID[window.pid] = RecentRemoval(
                        columnIndex: colIndex, width: width,
                        presetIndex: col.presetIndex, isFullWidth: col.isFullWidth, date: now)
                }

                #if DEBUG
                    print("[HealthCheck] Removing dead window wid=\(window.windowID) tileID=\(tileID.rawValue)")
                    fflush(stdout)
                #endif
                stripController.removeWindow(tileID: tileID)
                scheduleSnapshotSave()
                tracker.untrackWindow(window.windowID)
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
            scheduleSnapshotSave()
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
                let restored: RestoredSlot?
                if let recent = recentRemovalsByPID[pid],
                   Date().timeIntervalSince(recent.date) < 2.0 {
                    restored = RestoredSlot(
                        slotIndex: recent.columnIndex, width: recent.width,
                        presetIndex: recent.presetIndex, isFullWidth: recent.isFullWidth)
                    recentRemovalsByPID.removeValue(forKey: pid)
                    #if DEBUG
                        print("[HealthCheck] Using same-PID position for wid=\(window.windowID) pid=\(pid) col=\(recent.columnIndex)")
                        fflush(stdout)
                    #endif
                } else {
                    restored = resolveSnapshotPosition(for: window, on: targetSC, displayID: displayID)
                }

                targetSC.addWindow(window, app: app, restoredPosition: restored)

                // Fix B: Track adoption time for grace period
                recentlyAdoptedWindows[window.windowID] = Date()
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

    private func handleIPCCommand(_ command: ReelCommand) -> ReelResponse {
        if isReorderPending {
            switch command {
            case .focusLeft, .focusRight, .moveColumnLeft, .moveColumnRight:
                return ReelResponse(success: false, message: "Reorder in progress")
            default:
                break
            }
        }
        switch command {
        case .focusLeft:
            stripController.focusLeft()
            return ReelResponse(success: true)
        case .focusRight:
            stripController.focusRight()
            return ReelResponse(success: true)
        case .moveColumnLeft:
            stripController.moveColumnLeft()
            scheduleSnapshotSave()
            return ReelResponse(success: true)
        case .moveColumnRight:
            stripController.moveColumnRight()
            scheduleSnapshotSave()
            return ReelResponse(success: true)
        case .cycleWidthPreset:
            stripController.cycleWidthPreset()
            scheduleSnapshotSave()
            return ReelResponse(success: true)
        case .toggleFullWidth:
            stripController.toggleFullWidth()
            scheduleSnapshotSave()
            return ReelResponse(success: true)
        case .toggleFloating:
            if let focusedWID = getFocusedWindowID(),
               tracker.floatingWindows.contains(focusedWID),
               let window = tracker.windows[focusedWID],
               let app = tracker.apps[window.pid]
            {
                tracker.unmarkFloating(focusedWID)
                userToggledFloats.remove(focusedWID)
                let (displayID, sc) = stripControllerEntryForWindow(window)
                let restored = resolveSnapshotPosition(for: window, on: sc, displayID: displayID)
                stripController.unfloatWindow(window, app: app, restoredPosition: restored)
                scheduleSnapshotSave()
            } else if let window = stripController.toggleFloating() {
                saveSnapshotImmediate(sc: stripController)
                tracker.markFloating(window.windowID)
                userToggledFloats.insert(window.windowID)
            }
            return ReelResponse(success: true)
        case .closeWindow:
            stripController.closeActiveWindow()
            return ReelResponse(success: true)
        case .listWindows:
            let windows = stripController.windowMap.map { (tileID, window) -> [String: Any] in
                ["id": tileID.rawValue, "pid": window.pid, "title": window.getTitle() ?? ""]
            }
            if let data = try? JSONSerialization.data(withJSONObject: windows),
                let json = String(data: data, encoding: .utf8)
            {
                return ReelResponse(success: true, data: json)
            }
            return ReelResponse(success: true, data: "[]")
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
                return ReelResponse(success: true, data: json)
            }
            return ReelResponse(success: true, data: "[]")
        case .listPositions:
            if let store = snapshotStore {
                var allSlots: [[String: Any]] = []
                for (key, snapshot) in store.allSnapshots() {
                    for (i, slot) in snapshot.slots.enumerated() {
                        allSlots.append([
                            "displayID": key.displayID,
                            "slotIndex": i,
                            "bundleID": slot.bundleID,
                            "windowTitle": slot.windowTitle ?? "nil",
                            "width": "\(slot.width)",
                            "vacant": slot.vacant,
                        ])
                    }
                }
                if let data = try? JSONSerialization.data(withJSONObject: allSlots),
                    let json = String(data: data, encoding: .utf8)
                {
                    return ReelResponse(success: true, data: json)
                }
            }
            return ReelResponse(success: true, data: "[]")

        case .clearPositions:
            snapshotStore?.clearAll()
            snapshotStore?.persistToDisk()
            return ReelResponse(success: true, message: "Cleared all saved positions")
        case .recover:
            restoreAllWindows()
            for (_, sc) in stripControllers {
                sc.clearCommittedFrames()
                sc.applyLayout()
            }
            return ReelResponse(success: true, message: "Windows recovered")
        case .quit:
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return ReelResponse(success: true, message: "Quitting")
        }
    }

    // MARK: - Multi-Monitor Helpers

    /// Resolve a snapshot position for a window using the strip snapshot store.
    private func resolveSnapshotPosition(
        for window: AXWindow, on sc: StripController, displayID: CGDirectDisplayID
    ) -> RestoredSlot? {
        guard config.positionMemory, let snapshotStore else { return nil }

        let bundleID = tracker.apps[window.pid]?.bundleIdentifier
        guard let bundleID else { return nil }

        let title = window.getTitle()
        let key = SnapshotKey(displayID: UInt32(displayID), spaceFingerprint: sc.currentSpaceFingerprint)
        var currentBundleIDs = buildCurrentBundleIDs(sc: sc)
        currentBundleIDs.insert(bundleID)  // Include the incoming window for disk matching

        guard let snapshot = snapshotStore.snapshotFuzzyByBundleIDs(
            displayID: key.displayID, fingerprint: key.spaceFingerprint,
            currentBundleIDs: currentBundleIDs)
        else { return nil }

        let stripWindows = buildStripWindowInfos(sc: sc)
        let filled = computeFilledSlots(slots: snapshot.slots, stripWindows: stripWindows)

        guard let slotIndex = matchWindowToSlot(
            windowID: window.windowID,
            bundleID: bundleID,
            title: title,
            snapshot: snapshot,
            filledSlots: filled,
            now: Date())
        else { return nil }

        let slot = snapshot.slots[slotIndex]
        return RestoredSlot(
            slotIndex: slotIndex,
            width: slot.width,
            presetIndex: slot.presetIndex,
            isFullWidth: slot.isFullWidth)
    }

    /// Build StripWindowInfo array from a strip controller (caches AX title calls).
    private func buildStripWindowInfos(sc: StripController) -> [StripWindowInfo] {
        var infos: [StripWindowInfo] = []
        for column in sc.strip.columns {
            guard let tile = column.activeTile,
                  let win = sc.windowMap[tile],
                  let app = tracker.apps[win.pid]
            else { continue }
            infos.append(StripWindowInfo(
                tileID: tile,
                windowID: win.windowID,
                bundleID: app.bundleIdentifier ?? "",
                windowTitle: win.getTitle()))
        }
        return infos
    }

    /// Build the set of bundleIDs currently on a strip (for fuzzy disk matching).
    private func buildCurrentBundleIDs(sc: StripController) -> Set<String> {
        var ids = Set<String>()
        for column in sc.strip.columns {
            guard let tile = column.activeTile,
                  let win = sc.windowMap[tile],
                  let app = tracker.apps[win.pid],
                  let bid = app.bundleIdentifier
            else { continue }
            ids.insert(bid)
        }
        return ids
    }

    /// Capture the current strip state as a snapshot.
    private func captureSnapshot(sc: StripController) -> StripSnapshot? {
        var slots: [SlotDescriptor] = []
        for (i, column) in sc.strip.columns.enumerated() {
            guard let tile = column.activeTile,
                  let win = sc.windowMap[tile],
                  let app = tracker.apps[win.pid]
            else { continue }

            let colData = sc.strip.columnData[i]
            let width: ColumnWidth = column.width == .auto ? .fixed(colData.cachedWidth) : column.width

            slots.append(SlotDescriptor(
                windowID: win.windowID,
                bundleID: app.bundleIdentifier ?? "",
                windowTitle: win.getTitle(),
                width: width,
                presetIndex: column.presetIndex,
                isFullWidth: column.isFullWidth))
        }

        // Merge ghost slots from previous snapshot
        let key = snapshotStoreKey(for: sc)
        if let prevSnapshot = snapshotStore?.snapshot(for: key) {
            let now = Date()

            // Phase 1: Re-insert surviving non-expired ghosts from previous snapshot.
            // Collect insertions first, then apply in reverse order (highest index first)
            // to prevent positional drift as the array grows.
            var ghostInsertions: [(index: Int, slot: SlotDescriptor)] = []
            for (origIndex, slot) in prevSnapshot.slots.enumerated() {
                guard slot.vacant else { continue }
                // Skip expired ghosts
                if let vacatedAt = slot.vacatedAt,
                   now.timeIntervalSince(vacatedAt) > 600 { continue }
                // Skip if a live column matches this ghost
                let matched = slots.contains { !$0.vacant && $0.bundleID == slot.bundleID && ($0.windowTitle == slot.windowTitle || slot.windowTitle == nil) }
                if !matched {
                    ghostInsertions.append((min(origIndex, slots.count), slot))
                }
            }
            // Insert in reverse order so earlier insertions don't shift later indices
            for insertion in ghostInsertions.reversed() {
                let insertAt = min(insertion.index, slots.count)
                slots.insert(insertion.slot, at: insertAt)
            }

            // Phase 2: Convert newly-missing non-vacant slots to ghosts.
            // Two checks: (a) is there a live window for this slot? (b) is there already a ghost?
            // Both prevent unnecessary ghost creation while avoiding double-insertion.
            for prevSlot in prevSnapshot.slots {
                guard !prevSlot.vacant else { continue }
                let stillLive = slots.contains { !$0.vacant && $0.bundleID == prevSlot.bundleID && (prevSlot.windowTitle == nil || $0.windowTitle == prevSlot.windowTitle) }
                let ghostExists = slots.contains { $0.vacant && $0.bundleID == prevSlot.bundleID && $0.windowTitle == prevSlot.windowTitle }
                if !stillLive && !ghostExists {
                    var ghost = prevSlot
                    ghost.windowID = nil
                    ghost.vacant = true
                    ghost.vacatedAt = now  // Only set on first ghosting; inherited by Phase 1 on subsequent saves
                    slots.append(ghost)
                }
            }
        }

        guard !slots.isEmpty else { return nil }
        return StripSnapshot(slots: slots, lastUpdated: Date())
    }

    /// Build a SnapshotKey for the given strip controller.
    private func snapshotStoreKey(for sc: StripController) -> SnapshotKey {
        let displayID = stripControllers.first(where: { $0.value === sc })?.key ?? activeDisplayID
        return SnapshotKey(displayID: UInt32(displayID), spaceFingerprint: sc.currentSpaceFingerprint)
    }

    /// Parse a modifier key string into CGEventFlags. Returns empty flags for "none"/"".
    private static func parseModifierFlag(_ value: String) -> CGEventFlags {
        switch value.lowercased() {
        case "fn": return .maskSecondaryFn
        case "ctrl", "control": return .maskControl
        case "alt", "opt", "option": return .maskAlternate
        case "cmd", "command": return .maskCommand
        case "none", "": return CGEventFlags(rawValue: 0)
        default: return .maskSecondaryFn
        }
    }

    private func buildColumnInfos(from sc: StripController) -> [ColumnInfo] {
        var infos: [ColumnInfo] = []
        for (i, column) in sc.strip.columns.enumerated() {
            let tileID = column.activeTile ?? column.tiles.first
            guard let tid = tileID, let axWindow = sc.windowMap[tid] else {
                // Column has no resolvable window — use a placeholder to maintain index correspondence.
                infos.append(ColumnInfo(
                    index: i,
                    windowID: 0,
                    pid: 0,
                    appName: "Unknown",
                    appIcon: NSImage(named: NSImage.applicationIconName)!,
                    frameWidth: sc.strip.columnData[i].cachedWidth,
                    frameHeight: sc.strip.workingArea.height
                ))
                continue
            }
            let app = NSRunningApplication(processIdentifier: axWindow.pid)
            infos.append(ColumnInfo(
                index: i,
                windowID: axWindow.windowID,
                pid: axWindow.pid,
                appName: app?.localizedName ?? "Unknown",
                appIcon: app?.icon ?? NSImage(named: NSImage.applicationIconName)!,
                frameWidth: sc.strip.columnData[i].cachedWidth,
                frameHeight: sc.strip.workingArea.height
            ))
        }
        return infos
    }

    /// Schedule a debounced snapshot save for the given strip controller.
    /// Defaults to the active strip if no `sc` is provided.
    private func scheduleSnapshotSave(sc: StripController? = nil) {
        guard config.positionMemory, let snapshotStore else { return }
        let targetSC = sc ?? stripController
        let key = snapshotStoreKey(for: targetSC)
        snapshotStore.scheduleSnapshotSave(key: key) { [weak self] in
            self?.captureSnapshot(sc: targetSC)
        }
    }

    /// Immediate snapshot save for the given strip controller.
    private func saveSnapshotImmediate(sc: StripController) {
        guard config.positionMemory, let snapshotStore else { return }
        let key = snapshotStoreKey(for: sc)
        if let snapshot = captureSnapshot(sc: sc) {
            snapshotStore.saveImmediate(snapshot, for: key)
            // Consume the matching disk entry now that we have a live entry
            let bundleIDs = buildCurrentBundleIDs(sc: sc)
            snapshotStore.consumeDiskEntry(displayID: key.displayID, bundleIDs: bundleIDs)
        }
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
    static let reelShutdown = Notification.Name("reelShutdown")
}
