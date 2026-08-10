import AppKit
import Config
import Core
import CryptoKit
import Foundation
import IPC
import Platform

/// Returns a privacy-safe window title for logging.
/// DEBUG: raw title. Release: SHA-256 hash prefix (8 hex chars).
func logTitle(_ title: String?) -> String {
    guard let title = title else { return "?" }
    #if DEBUG
    return title
    #else
    let hash = SHA256.hash(data: Data(title.utf8))
    return hash.prefix(4).map { String(format: "%02x", $0) }.joined()
    #endif
}

/// Central coordinator for Reel.
/// Connects WindowTracker (discovery) → StripController (layout) → Platform APIs.
/// All state mutations happen on the main thread via the serial event queue.
public final class WindowManager: @unchecked Sendable {
    public let tracker: WindowTracker
    public let hotkeyManager: HotkeyManager
    public let displayManager: DisplayManager

    private static let isoFormatter = ISO8601DateFormatter()

    /// A canonical identifier for a group of aligned displays. Sorted ascending
    /// so equal member sets produce equal IDs (stable across hot-plug cycles).
    public typealias GroupID = [CGDirectDisplayID]

    /// Reverse index: `displayID` → the `GroupID` it belongs to.
    /// Kept in sync with `stripControllers` at every reconciliation.
    private var displayToGroup: [CGDirectDisplayID: GroupID] = [:]

    /// Canonicalize a sequence of display IDs into a `GroupID`.
    public static func groupID<S: Sequence>(from ids: S) -> GroupID
    where S.Element == CGDirectDisplayID {
        ids.sorted()
    }

    /// Per-group strip controllers. One strip per group of aligned displays.
    public private(set) var stripControllers: [GroupID: StripController] = [:]

    /// Snapshot store for restoring window placement.
    public var snapshotStore: StripSnapshotStore?

    /// The currently active (focused) display.
    public private(set) var activeDisplayID: CGDirectDisplayID = CGMainDisplayID()

    /// Convenience: the strip controller for the active display.
    public var stripController: StripController {
        if let gid = displayToGroup[activeDisplayID], let sc = stripControllers[gid] {
            return sc
        }
        if let sc = stripControllers.values.first {
            return sc
        }
        // No strips exist — all displays disconnected (clamshell / KVM input
        // switch / resolution transition). Materialize a synthetic fallback so
        // callers never crash on an empty dictionary. Preserves the never-empty
        // invariant that init() also enforces.
        return ensureFallbackStrip().1
    }

    /// True when macOS "Displays have separate Spaces" is ON. In that state
    /// shared-strip mode is disabled and Reel falls back to per-display strips.
    /// Surfaced to the menu bar as a user-visible hint.
    public var separateSpacesEnabled: Bool {
        !displayManager.displaysShareOneSpace
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

    /// Dispatch sources for graceful-shutdown signals. Retained so they stay
    /// live; delivering the signal via a dispatch source (rather than a POSIX
    /// signal handler) keeps handling async-signal-safe.
    private var sigtermSource: DispatchSourceSignal?
    private var sigintSource: DispatchSourceSignal?

    /// Current configuration.
    public private(set) var config: ReelConfig

    /// State persistence for crash recovery.
    private let stateFilePath: String
    private var stateWriteTimer: Timer?
    private var healthCheckTimer: Timer?

    /// Pending external focus scroll — debounced to avoid visual flash during space transitions.
    private var pendingFocusScroll: DispatchWorkItem?

    /// Focus-race guard for `.appActivated` → `handleSpaceChange`: remembers the
    /// most recent app activation (dock click / Cmd+Tab) so a space-change that
    /// follows can override savedFocusTile with that app's focused window.
    /// One-shot, 0.5s TTL. Pure logic lives in `FocusEventGate` (Core).
    private var focusGate = FocusEventGate()

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

    /// Windows that were absent from CGWindowList on the *previous* health check.
    /// A window must be missing on two consecutive checks before it is reaped, so
    /// a single-tick disappearance during a Space transition (window server flips
    /// the on-screen list before activeSpaceDidChange is delivered) can't gut the
    /// departing Space's saved layout (finding #17).
    private var healthCheckMissing: Set<CGWindowID> = []

    /// Windows the health-check adoption pass has already classified as
    /// non-tileable (.ignore). Lets subsequent 500ms sweeps skip them before the
    /// ~9-call getPropertiesFast() battery. `.float` results go to
    /// `tracker.floatingWindows` instead; this set covers `.ignore`, for which
    /// the tracker exposes no public setter. Pruned to the on-screen set each
    /// sweep so it can't grow unbounded (finding #32).
    private var healthCheckIgnored: Set<CGWindowID> = []

    /// Hash of the last crash-recovery state written to disk. `persistState`
    /// skips the write when the freshly-serialized state hashes identically, so
    /// the 5s timer stops rewriting an unchanged file forever (finding #35).
    private var lastPersistedStateHash: Int?

    public init() {
        // Load config first
        let (loadedConfig, configError) = ReelConfig.load()
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
            let wa = info.workingArea(
                struts: struts, primaryScreenHeight: displayManager.primaryScreenHeight)
            let gid: GroupID = [displayID]
            stripControllers[gid] = StripController(
                workingArea: wa, primaryScreenHeight: displayManager.primaryScreenHeight)
            displayToGroup[displayID] = gid
        }
        // Ensure at least one strip exists (fallback)
        if stripControllers.isEmpty {
            let wa = CGRect(x: 0, y: 25, width: 1440, height: 875)
            let fallbackID = CGMainDisplayID()
            let gid: GroupID = [fallbackID]
            stripControllers[gid] = StripController(
                workingArea: wa, primaryScreenHeight: NSScreen.main?.frame.height ?? 0)
            displayToGroup[fallbackID] = gid
        }
        activeDisplayID = displayManager.mainDisplay?.displayID ?? CGMainDisplayID()

        // State file path
        let stateDir = ReelConfig.stateDir
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
            applyAnimationConfig(config, to: sc)
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
            gc.swipeThresholdPx = config.cursor.swipeThresholdPx
        }

        // Trackpad config
        if let tb = titleBarInteraction {
            tb.longPressDelayMs = config.cursor.longPressDelayMs
            tb.dragThresholdPx = config.cursor.dragThresholdPx
            tb.titleBarCornerInsetPx = config.cursor.titleBarCornerInsetPx
            tb.requiredModifier = Self.parseModifierFlag(config.gestureModifier)
        }
        // Terminal path is read directly from config when spawning

        print(
            "[WM] Config applied (gap=\(config.gap), snap=\(config.snapPoints), gestureSnap=\(config.gestureSnap), animation=\(config.animationEnabled))"
        )
        fflush(stdout)
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

        // Form alignment groups before window discovery — init() creates per-
        // display singletons, but shared-strip mode merges aligned displays
        // into one group. didChangeScreenParameters doesn't fire at startup,
        // so run the reconciler explicitly once here.
        reconcileDisplayTopology(newDisplays: displayManager.displays)

        // Record initial Space fingerprint for all strips
        let initialWindows = getAllWindowInfo()
        let initialFingerprint = Set(
            initialWindows.filter { $0.layer == 0 && $0.isOnScreen }.map(\.windowID))
        for (_, sc) in stripControllers {
            sc.setSpaceFingerprint(initialFingerprint)
        }

        // Initialize snapshot store before window discovery
        if config.positionMemory {
            let stateDir = ReelConfig.stateDir
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
        print("[WM] tracked \(tracker.windows.count) windows, \(tracker.apps.count) apps")
        fflush(stdout)
        for (_, sc) in stripControllers { sc.finishBatch() }
        startupOnScreenIDs = nil
        print("[WM] batch finished, strip has \(stripController.strip.columns.count) cols")
        fflush(stdout)

        // No per-removal callback needed — snapshot model uses debounced strip capture

        hotkeyManager.registerFromConfig(config.keybindings)
        let hotkeyOk = hotkeyManager.start()
        print("[WM] hotkeys: \(hotkeyOk)")
        fflush(stdout)

        // Phase 2: Frame loop for smooth animation — shared across all strips
        let fl = FrameLoop()
        self.frameLoop = fl
        fl.onTick = { [weak self] time in
            guard let self = self else { return }
            // While paused, don't advance any strip's animation — a spring left
            // in flight when the user paused would otherwise keep dispatching AX
            // setFrame/setPosition (and the settle-latch would re-hide far-zone
            // columns), fighting the restoreAllWindows() that togglePause ran.
            if self.isPaused {
                self.frameLoop?.pause()
                return
            }
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
            applyAnimationConfig(config, to: sc)
            sc.focusIndicator.reloadConfig(config.focusIndicator)
            sc.focusIndicator.springParams = config.widthSpringParams
        }
        print("[WM] animation: enabled (\(stripControllers.count) displays)")
        fflush(stdout)

        // Phase 2: Gesture capture for trackpad scrolling
        let gestureCapture = GestureCapture()
        // All trackpad gesture callbacks mutate layout (scroll / dispatch AX
        // setPosition), so gate them on pause — an fn+swipe while paused would
        // otherwise scroll and re-sliver the whole strip. onGestureCancel is a
        // pure state reset and stays ungated so a gesture in flight when pause
        // toggles still tears down cleanly.
        gestureCapture.onGestureBegin = { [weak self] time in
            guard let self, !self.isPaused else { return }
            self.stripController.handleGestureBegin(time: time)
        }
        gestureCapture.onGestureUpdate = { [weak self] deltaX, time in
            guard let self, !self.isPaused else { return }
            self.stripController.handleGestureUpdate(deltaX: deltaX, time: time)
        }
        gestureCapture.onGestureEnd = { [weak self] time in
            guard let self, !self.isPaused else { return }
            self.stripController.handleGestureEnd(time: time)
        }
        gestureCapture.onGestureCancel = { [weak self] in
            self?.stripController.handleGestureCancel()
        }
        gestureCapture.onDiscreteScroll = { [weak self] deltaX, time in
            guard let self, !self.isPaused else { return }
            self.stripController.handleDiscreteScroll(deltaX: deltaX, time: time)
        }
        gestureCapture.requiredModifier = Self.parseModifierFlag(config.gestureModifier)
        gestureCapture.swipeThresholdPx = config.cursor.swipeThresholdPx
        gestureCapture.onFocusSwipe = { [weak self] velocity in
            guard let self, !self.isPaused else { return }
            let sc = self.stripController
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
        titleBar.longPressDelayMs = config.cursor.longPressDelayMs
        titleBar.dragThresholdPx = config.cursor.dragThresholdPx
        titleBar.titleBarCornerInsetPx = config.cursor.titleBarCornerInsetPx
        titleBar.requiredModifier = Self.parseModifierFlag(config.gestureModifier)
        titleBar.onNeedsManagedFrames = { [weak self] () -> (frames: [TileID: CGRect], primaryScreenHeight: CGFloat) in
            // Merge committed frames across ALL strips so title-bar hit-testing
            // works for windows on non-active strips (e.g. second monitor).
            guard let self = self else { return (frames: [:], primaryScreenHeight: 0) }
            var merged: [TileID: CGRect] = [:]
            for (_, sc) in self.stripControllers {
                for (tid, frame) in sc.lastCommittedFrames {
                    merged[tid] = frame
                }
            }
            return (frames: merged, primaryScreenHeight: self.displayManager.primaryScreenHeight)
        }

        titleBar.onNeedsTileColumnIndex = { [weak self] (tileID: TileID) -> Int? in
            guard let self = self else { return nil }
            // Search every strip for this tile.
            for (_, sc) in self.stripControllers {
                for (i, col) in sc.strip.columns.enumerated() {
                    if col.tiles.contains(tileID) { return i }
                }
            }
            return nil
        }

        titleBar.onDragBegin = { [weak self] columnIndex in
            // Paused: don't open the reorder overlay — committing a drop runs
            // moveColumn + applyLayout + focusActiveWindow, all layout mutations.
            guard let self = self, !self.isPaused else { return }
            // Use the strip the cursor is currently on, not the active strip.
            let sc = self.stripControllerUnderCursor()
            let columns = self.buildColumnInfos(from: sc)
            // Identify the dragged column by a STABLE tile ID captured now. A
            // multi-second drag can outlive the layout it started on: focusUp/
            // focusDown hotkeys and IPC focus commands are not blocked until drop,
            // and the 500ms health check can adopt/remove columns mid-drag. Both
            // shift the frozen drag-begin index. Re-resolving the source column by
            // this tile at commit time (against the drag-origin strip `sc`, never
            // the possibly-changed active strip) keeps the reorder correct or
            // cancels cleanly if the column vanished (finding #20).
            let draggedTile: TileID? = columnIndex < sc.strip.columns.count
                ? (sc.strip.columns[columnIndex].activeTile ?? sc.strip.columns[columnIndex].tiles.first)
                : nil
            self.reorderOverlay.onCommit = { [weak self] _, insertionIndex in
                guard let self = self else { return }
                defer { self.isReorderPending = false }
                // Re-resolve the source column by its tile on the origin strip.
                // Bail if the tile is gone (window closed / migrated mid-drag).
                guard let draggedTile,
                      let sourceIndex = sc.strip.columns.firstIndex(where: {
                          $0.tiles.contains(draggedTile)
                      })
                else { return }
                // Convert gap-based insertion index to position index for moveColumn.
                // moveColumn uses remove-then-insert, so after removing sourceIndex,
                // indices >= sourceIndex shift down by 1. Clamp into the current
                // column range — the overlay's gap index was computed against the
                // drag-begin column list, which may have shrunk.
                let rawDest = insertionIndex > sourceIndex ? insertionIndex - 1 : insertionIndex
                let destIndex = max(0, min(rawDest, sc.strip.columns.count - 1))
                if sourceIndex != destIndex {
                    let time = TimeUtil.now()
                    sc.strip.moveColumn(from: sourceIndex, to: destIndex, at: time)
                    // Make the dropped column the new active/focused column. Without
                    // this, when the user drags a non-active column, the old active
                    // stays centered and the dropped column lands at a position that
                    // depends on its new strip-index relative to the old active —
                    // shifting further right the larger the destination index. Making
                    // the dropped column active pins it at its snap point (centered
                    // by default) regardless of drop index.
                    sc.strip.activeColumnIndex = destIndex
                    // Re-center the viewOffset on the new active column INSTANTLY
                    // (before applyLayout) so applyLayout places windows at their
                    // final positions. If we used the animated variant and called
                    // applyLayout before it, applyLayout would evaluate positions with
                    // the stale (old-active-centered) viewOffset, so windows would
                    // visibly snap to the wrong place and only animate to the right
                    // place over the next frames — a visible "wrong then right" jump.
                    sc.strip.recenterActiveColumn(at: time)
                    sc.applyLayout()
                    sc.focusActiveWindow()
                    self.scheduleSnapshotSave(sc: sc)
                }
            }
            // Use the full display frame in AppKit coordinates for the overlay window.
            let gid = self.stripControllers.first(where: { $0.value === sc })?.key
                ?? self.displayToGroup[self.activeDisplayID]
                ?? [self.activeDisplayID]
            let displayID = gid.first ?? self.activeDisplayID
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
            guard let self, !self.isPaused else { return }
            self.reorderOverlay.updateCursor(position: cgPoint)
        }

        titleBar.onDragEnd = { [weak self] (_: Int) in
            // Paused: skip commit. onDragBegin was gated so no overlay is
            // showing; setting isReorderPending here would otherwise stick true
            // (commitDrop on a nil overlay never resets it), and a stale onCommit
            // could fire moveColumn. Stay fully inert while paused.
            guard let self = self, !self.isPaused else { return }
            self.isReorderPending = true
            self.reorderOverlay.commitDrop()
        }

        titleBar.onDragCancel = { [weak self] in
            guard let self = self else { return }
            self.reorderOverlay.cancel()
            self.isReorderPending = false
        }
        titleBar.onMenuShow = { [weak self] (columnIndex: Int, cgMousePoint: CGPoint) in
            // Paused: don't surface the pill-bar menu — its actions
            // (setWidthPreset / toggleFullWidth / toggleFloat) all mutate layout.
            guard let self = self, !self.isPaused else { return }
            // Route to the strip under the cursor so windows on the non-active
            // monitor still get the pill-bar menu.
            let sc = self.stripControllerUnderCursor()
            let pills = sc.buildPillItems(for: columnIndex)
            let appKitY = self.displayManager.primaryScreenHeight - cgMousePoint.y
            let anchorFrame = CGRect(x: cgMousePoint.x, y: appKitY, width: 0, height: 0)
            self.titleBarInteraction?.overlay.mode = .menu(
                pills: pills, anchorFrame: anchorFrame, selectedIndex: nil
            )
            self.titleBarInteraction?.overlay.show()
        }
        titleBar.onMenuSelect = { [weak self] (actionIndex: Int) in
            guard let self = self, !self.isPaused else { return }
            let sc = self.stripControllerUnderCursor()
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

        // Self-focus click: when the user clicks a tile whose window is
        // already its app's AX-focused window, neither kAXFocusedWindowChanged
        // nor didActivateApplication fires, so the .windowFocused / .appActivated
        // handlers don't pull the column into view. Route any non-modifier
        // click on a tracked tile through scrollToWindow(.incrementalSnap) —
        // idempotent when the column is already fully visible, so it's safe
        // to fire even in the cases where AX events do arrive.
        titleBar.onWindowFrameClick = { [weak self] (tileID: TileID) in
            guard let self = self, !self.isPaused else { return }
            for (_, sc) in self.stripControllers {
                guard sc.windowMap[tileID] != nil else { continue }
                // Cancel any pending AX-driven scroll — this click is a stronger
                // signal of user intent than the debounced focus follow-up.
                self.pendingFocusScroll?.cancel()
                sc.scrollToWindow(tileID: tileID, mode: .incrementalSnap)
                sc.userActiveTileID = tileID
                sc.userActiveTileIDTime = TimeUtil.now()
                return
            }
        }

        let titleBarOk = titleBar.start()
        self.titleBarInteraction = titleBar
        print("[WM] title bar interaction: \(titleBarOk)")
        fflush(stdout)
        print("[WM] gesture capture: \(gestureOk)")
        fflush(stdout)

        // Start periodic state persistence (every 5 seconds)
        stateWriteTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) {
            [weak self] _ in
            self?.persistState()
            self?.snapshotStore?.persistToDisk()
        }
        // Let the OS coalesce these periodic wakes with other timers instead of
        // firing on the exact deadline — cheaper on battery for a backstop timer
        // whose precise phase doesn't matter (finding #35).
        stateWriteTimer?.tolerance = 1.0

        print("[WM] Config loaded from \(ReelConfig.configPath)")
        fflush(stdout)
        // Log the effective config / state / socket paths so a sandboxed run
        // (REEL_CONFIG_DIR / REEL_STATE_DIR / REEL_SOCKET_PATH overrides) makes
        // it obvious which locations this instance is actually using (W5).
        print("[WM] Paths: config=\(ReelConfig.configPath) state=\(ReelConfig.stateDir) socket=\(reelSocketPath())")
        fflush(stdout)

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
        // Terminate only once `quit`'s response has been flushed and the client
        // socket closed, so `reel-msg quit` reliably receives "Quitting" and exits 0.
        server.onFlushed = { command in
            guard command == .quit else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        let ipcOk = server.start()
        self.ipcServer = server
        print("[WM] IPC server: \(ipcOk)")
        fflush(stdout)

        // Periodic window health check — detect closed windows that AX observer missed.
        // kAXUIElementDestroyedNotification is unreliable for some apps.
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkWindowHealth()
        }
        healthCheckTimer?.tolerance = 0.1

        // Register signal handlers for graceful shutdown via NSApp.terminate
        // (ensures proper cleanup — menu bar icon removal, window restoration).
        //
        // Use DispatchSourceSignal rather than signal(2) + DispatchQueue.main.async:
        // a POSIX signal handler that calls dispatch_async is NOT async-signal-safe
        // (it allocates a continuation and takes libdispatch locks). `make run-debug`
        // routinely SIGTERMs the previous instance; if the signal lands on a thread
        // mid-malloc (e.g. a background AX dispatch closure) the handler could
        // deadlock and skip shutdown(), leaving windows slivered off-screen.
        // SIG_IGN defuses the default handler; the dispatch source then delivers
        // the notification safely on the main queue.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let sigtermSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSrc.setEventHandler { NSApp.terminate(nil) }
        sigtermSrc.resume()
        self.sigtermSource = sigtermSrc
        let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSrc.setEventHandler { NSApp.terminate(nil) }
        sigintSrc.resume()
        self.sigintSource = sigintSrc

        print("[Reel] Window manager started")
        print("[Reel] Tracked windows: \(tracker.windows.count)")
        print("[Reel] Tracked apps: \(tracker.apps.count)")
        print("[Reel] Strip columns: \(stripController.strip.columns.count)")
        print("[Reel] Strip working area: \(stripController.strip.workingArea)")
        fflush(stdout)

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
                print(
                    "[Reel] Startup retry @\(delay)s: \(self.stripController.strip.columns.count) cols"
                )
                fflush(stdout)
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
        print("[WM] Shutting down — restoring windows")
        fflush(stdout)
        isPaused = true
        stateWriteTimer?.invalidate()
        healthCheckTimer?.invalidate()

        // Restore all windows to reasonable on-screen positions
        restoreAllWindows()

        // Persist final state
        persistState()
        // Save all snapshots before shutdown
        for (gid, sc) in stripControllers {
            let key = SnapshotKey(groupID: Array(gid), spaceFingerprint: sc.currentSpaceFingerprint)
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
            print("[WM] Paused")
            fflush(stdout)
            hotkeyManager.suspended = true
            if let tap = hotkeyManager.eventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
            }
            for (_, sc) in stripControllers {
                sc.isPaused = true
                sc.focusIndicator.hide()
            }
            // Cancel in-flight work so nothing keeps mutating layout after
            // restoreAllWindows() hands windows back their natural frames:
            //  - pause the shared frame loop so an in-flight spring stops
            //    dispatching AX writes,
            //  - drop any debounced external focus-scroll,
            //  - tear down any active title-bar drag/menu and nil the reorder
            //    overlay's onCommit so a stale drop can't fire moveColumn.
            frameLoop?.pause()
            pendingFocusScroll?.cancel()
            pendingFocusScroll = nil
            titleBarInteraction?.cancelIfActive()
            reorderOverlay.cancel()
            isReorderPending = false
            restoreAllWindows()
        } else {
            print("[WM] Resumed")
            fflush(stdout)
            hotkeyManager.suspended = false
            if let tap = hotkeyManager.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            // Re-discover any windows that aren't in the strip
            let onScreenIDs = Set(getAllWindowInfo().map(\.windowID))
            adoptUnmanagedWindows(onScreenIDs: onScreenIDs)
            // Clear committed frames so the next applyLayout reapplies everything
            for (_, sc) in stripControllers {
                sc.isPaused = false
                sc.clearCommittedFrames()
                sc.applyLayout()
            }
        }
    }

    /// Reload config from disk and apply to all subsystems.
    public func reloadConfig() {
        let (newConfig, error) = ReelConfig.load()
        if let err = error {
            print("[WM] Config reload error: \(err)")
            fflush(stdout)
            return
        }

        // Apply shared config fields (strip layout, hotkeys, rules, gesture modifier)
        applyConfig(newConfig)

        // Snapshot store (reload-specific: may create)
        if config.positionMemory, snapshotStore == nil {
            let stateDir = ReelConfig.stateDir
            let filePath = URL(fileURLWithPath: stateDir + "/window-snapshots.json")
            snapshotStore = StripSnapshotStore(filePath: filePath)
            snapshotStore?.loadFromDisk()
        }

        // Relayout EVERY strip against the freshly-loaded struts/gap/widths, not
        // just the active one — on multi-monitor the others kept stale geometry
        // until something else happened to touch them.
        //
        // The DisplayInfo guard is required: building a GroupWorkingArea for a
        // member with no live DisplayInfo (display asleep, KVM switched) traps in
        // GroupWorkingArea's initializer. Such a group still gets its widths
        // recalculated and re-laid-out, just against its existing area.
        let reloadTime = TimeUtil.now()
        let struts = currentStruts
        for (gid, sc) in stripControllers {
            if gid.allSatisfy({ displayManager.displays[$0] != nil }) {
                sc.primaryScreenHeight = displayManager.primaryScreenHeight
                sc.updateGroupArea(currentGroupArea(
                    for: gid,
                    displays: displayManager.displays,
                    struts: struts,
                    primaryScreenHeight: displayManager.primaryScreenHeight
                ))
            }
            sc.strip.recalculateWidths(at: reloadTime)
            sc.clearCommittedFrames()
            sc.applyLayout()
        }

        print(
            "[WM] Config reloaded (gestureSnap=\(config.gestureSnap), snap=\(config.snapPoints))"
        )
        fflush(stdout)
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

        // Display changes → reconcile strip controller topology
        displayManager.onDisplayChange = { [weak self] displays in
            self?.reconcileDisplayTopology(newDisplays: displays)
        }
    }

    private func handleWindowEvent(_ event: WindowEvent) {
        // A real AX move event means the user is manipulating the window
        // (drag, Mission Control move, etc.). Cancel any pending focus-scroll
        // so its delayed setFrame doesn't race the drag and snap the window
        // back to its slot mid-gesture. Runs before echo suppression so a
        // drag that starts inside the 150ms echo window still disables the
        // scheduled scroll.
        if case .windowMoved = event {
            pendingFocusScroll?.cancel()
            pendingFocusScroll = nil
        }

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
                    // Skip if this tile is already owned by some strip — avoids
                    // duplicate columns when a re-discovery path (space change,
                    // health check, mission-control drag echoes) fires
                    // windowAdded for a window we already manage.
                    if stripControllers.values.contains(where: { $0.windowMap[window.tileID] != nil }) {
                        #if DEBUG
                        print("[WM] windowAdded SKIP (already managed) wid=\(window.windowID)")
                        fflush(stdout)
                        #endif
                        break
                    }
                    let (gid, sc) = stripControllerEntryForWindow(window)
                    let saved = resolveSnapshotPosition(for: window, on: sc, groupID: gid)
                    print("[WM] windowAdded wid=\(window.windowID) pid=\(window.pid) app=\(app.bundleIdentifier ?? "?") restored=\(saved != nil)")
                    fflush(stdout)
                    sc.addWindow(window, app: app, restoredPosition: saved)
                    scheduleSnapshotSave(sc: sc)
                }
            case .float:
                break
            case .ignore:
                break
            }

        case .windowRemoved(let windowID, let tileID):
            print("[WM] windowRemoved tileID=\(tileID.rawValue)")
            fflush(stdout)
            userToggledFloats.remove(windowID)
            // Remove from whichever strip has it live
            for (_, sc) in stripControllers {
                if sc.windowMap[tileID] != nil {
                    sc.removeWindow(tileID: tileID)
                    scheduleSnapshotSave(sc: sc)
                    break
                }
            }
            // The window may also be stashed in another strip's saved Space
            // (multi-monitor, or a Space that strip visited then left). The
            // owning strip's removeWindow prunes only itself; prune the destroyed
            // tile from every strip's stash so no dead AXWindow/AXApp stays pinned
            // (finding #6/#22). pruneSavedSpaces is idempotent, so re-running it on
            // the owner is harmless.
            for (_, sc) in stripControllers {
                sc.pruneSavedSpaces(removedTileID: tileID)
            }

        case .windowFocused(let windowID):
            let tileID = TileID(windowID)
            // Suppress focus events for windows not in the current strip.
            // Covers two cases that both want to no-op the strip scroll:
            //   - destination-space windows arriving during a space transition
            //   - floating / unmanaged windows (PIP, dialogs, palettes) on the current space
            guard stripController.windowMap[tileID] != nil else {
                #if DEBUG
                    print("[WM] Suppressed focus for untracked window wid=\(windowID)")
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
                // Incremental snap: if column already visible, no scroll;
                // otherwise slide to first milestone in travel direction.
                sc.scrollToWindow(tileID: tileID, mode: .incrementalSnap)
            }
            pendingFocusScroll = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            // Update user focus — marked as external so saveCurrentSpace can
            // ignore it if a space switch follows within 300ms.
            stripController.userActiveTileID = tileID
            stripController.userActiveTileIDTime = TimeUtil.now()

        case .appActivated(let pid):
            focusGate.recordAppActivation(pid: pid, at: TimeUtil.now())
            // Dock click / Cmd+Tab: resolve which window of this app to scroll to.
            let sc = stripController
            if let tileID = resolveFocusedTileID(forPID: pid, on: sc) {
                // Same-space resolution: consume the carryover so an unrelated
                // later space switch can't confuse savedFocusTile with this pid.
                focusGate.consumeRecentActivation(at: TimeUtil.now())
                pendingFocusScroll?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, !self.isPaused else { return }
                    sc.scrollToWindow(tileID: tileID, mode: .incrementalSnap)
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
            print("[WM] windowMinimized wid=\(windowID)")
            fflush(stdout)
            // Route to the OWNING strip, not just the active one — otherwise a
            // window minimized on a non-active strip lingers until the 500ms
            // health check and the wrong (active) strip's snapshot is saved.
            let tileID = TileID(windowID)
            let owner = stripControllers.first(where: { $0.value.windowMap[tileID] != nil })?.value
            let sc = owner ?? stripController
            sc.removeWindow(tileID: tileID)
            scheduleSnapshotSave(sc: sc)

        case .windowDeminimized(let windowID):
            print("[WM] windowDeminimized wid=\(windowID)")
            fflush(stdout)
            if userToggledFloats.contains(windowID) {
                // Was floating before minimize — restore as floating, macOS handles the frame
                tracker.markFloating(windowID)
                print("[WM] windowDeminimized wid=\(windowID) restored as floating")
                fflush(stdout)
            } else if let window = tracker.windows[windowID],
                let app = tracker.apps[window.pid]
            {
                let (gid, sc) = stripControllerEntryForWindow(window)
                let saved = resolveSnapshotPosition(for: window, on: sc, groupID: gid)
                sc.addWindow(window, app: app, restoredPosition: saved)
                scheduleSnapshotSave(sc: sc)
            }

        case .windowResized(let windowID):
            // User resized a window — update the OWNING strip's column width to
            // match. Routing to the active strip only would hit handleUserResize's
            // windowMap-miss SKIP path for a window on a non-active strip, leaving
            // that strip's width model stale (the resize gets reverted on its next
            // layout pass) and saving the wrong strip's snapshot.
            let tileID = TileID(windowID)
            let sc = stripControllers.first(where: { $0.value.windowMap[tileID] != nil })?.value
                ?? stripController
            sc.handleUserResize(windowID: windowID)
            scheduleSnapshotSave(sc: sc)

        case .windowMoved(let windowID):
            // User dragged a window — if it now lives on a different group's
            // working area (e.g. Mission Control drag to another monitor),
            // migrate it to that group's strip. Otherwise snap it back to its
            // current strip position.
            //
            // Destination resolution runs in two passes:
            //   1. center-inside-workingArea — fast, matches a fully-dropped
            //      window cleanly.
            //   2. max-frame-overlap fallback — handles Mission Control drops
            //      that leave the window partially off the destination monitor
            //      (the center can miss every workingArea even though the
            //      frame genuinely overlaps one). Off-strip slivers have
            //      zero overlap with every group and so remain unmigrated.
            let tileID = TileID(windowID)
            let currentOwner = stripControllers.first(where: { $0.value.windowMap[tileID] != nil })?.value
            if let owner = currentOwner, let window = owner.windowMap[tileID] {
                var destEntry: (GroupID, StripController)? = nil
                if case .success(let frame) = window.getFrame() {
                    let center = CGPoint(x: frame.midX, y: frame.midY)
                    for (gid, sc) in stripControllers {
                        if sc.strip.workingArea.contains(center) {
                            destEntry = (gid, sc)
                            break
                        }
                    }
                    if destEntry == nil {
                        var bestArea: CGFloat = 0
                        for (gid, sc) in stripControllers {
                            let inter = sc.strip.workingArea.intersection(frame)
                            let area = inter.isNull ? 0 : inter.width * inter.height
                            if area > bestArea {
                                bestArea = area
                                destEntry = (gid, sc)
                            }
                        }
                    }
                }
                if let (destGID, destSC) = destEntry, destSC !== owner {
                    // Genuine cross-group migration.
                    if let app = tracker.apps[window.pid] {
                        owner.removeWindow(tileID: tileID)
                        let restored = resolveSnapshotPosition(for: window, on: destSC, groupID: destGID)
                        destSC.addWindow(window, app: app, restoredPosition: restored)
                        scheduleSnapshotSave(sc: destSC)
                        print("[WM] window \(windowID) migrated to group \(destGID)")
                        fflush(stdout)
                    } else {
                        owner.handleUserMove(windowID: windowID)
                    }
                } else {
                    owner.handleUserMove(windowID: windowID)
                }
            } else {
                stripController.handleUserMove(windowID: windowID)
            }

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
        let leavingTile = stripController.userActiveTileID ?? stripController.strip.activeColumn?.activeTile
        let leavingWindow = leavingTile.flatMap { stripController.windowMap[$0] }
        print("[WM] spaceChanged leaving wid=\(leavingWindow?.windowID ?? 0) app=\(leavingWindow.flatMap { tracker.apps[$0.pid]?.bundleIdentifier } ?? "?") title=\(logTitle(leavingWindow?.getTitle())) onScreenIDs=\(onScreenIDs)")
        fflush(stdout)

        // With "Displays have separate Spaces" OFF (the required setting for
        // shared-strip mode), a Space switch affects EVERY display simultaneously.
        // Save+switch every strip, not just the active one, otherwise non-active
        // strips retain a stale columns list / windowMap for a Space they no
        // longer display — windows on the new Space get "stuck" unmanaged.
        //
        // Strips whose switchSpace returns false (no in-memory SavedStripState
        // for this Space) get queued for deterministic snapshot replay below.
        var stripsNeedingReplay: [(gid: GroupID, sc: StripController)] = []
        for (gid, sc) in stripControllers where sc !== stripController {
            saveSnapshotImmediate(sc: sc)
            let restoredNonActive = sc.switchSpace(onScreenWindowIDs: onScreenIDs)
            if restoredNonActive {
                // Remove windows no longer on screen (closed/minimized while away).
                let managedIDs = Set(sc.windowMap.keys.map(\.rawValue))
                let goneIDs = managedIDs.subtracting(onScreenIDs)
                for goneID in goneIDs {
                    sc.removeWindow(tileID: TileID(goneID))
                }
            } else {
                stripsNeedingReplay.append((gid, sc))
            }
        }

        // Save snapshot for the leaving space before switching
        saveSnapshotImmediate(sc: stripController)

        // Try to restore saved state for this Space
        let restored = stripController.switchSpace(onScreenWindowIDs: onScreenIDs)

        if !restored {
            // Active strip wasn't in in-memory savedSpaces — include it in replay.
            let activeGID = stripControllers.first(where: { $0.value === stripController })?.key
                ?? displayToGroup[activeDisplayID]
                ?? [activeDisplayID]
            stripsNeedingReplay.append((activeGID, stripController))
        }

        // Deterministic first-visit replay: for each non-restored strip, look up
        // its persisted snapshot (fuzzy-matched by bundle-ID set) and adopt each
        // slot in order. This closes the failure mode where a subsequent generic
        // discovery drops windows due to float classification drift or fingerprint
        // mismatches in per-window resolveSnapshotPosition lookups. Runs before
        // either branch below — replay-adopted windows then appear in
        // `managedAcrossAllStrips` on either path.
        var adoptedByReplay: Set<UInt32> = []
        for entry in stripsNeedingReplay {
            let adopted = replayFromSnapshot(
                sc: entry.sc,
                groupID: entry.gid,
                onScreenIDs: onScreenIDs,
                exclude: adoptedByReplay)
            adoptedByReplay.formUnion(adopted)
        }

        if restored {
            // Remember which window was focused before we modify the strip
            let savedFocusTile = stripController.strip.activeColumn?.activeTile

            // Remove windows that are no longer on screen (closed while away)
            let managedIDs = Set(stripController.windowMap.keys.map(\.rawValue))
            let goneIDs = managedIDs.subtracting(onScreenIDs)
            for goneID in goneIDs {
                stripController.removeWindow(tileID: TileID(goneID))
            }

            // Add new windows that weren't in the saved state. Use the UNION
            // of windowMaps across every strip — a window on a non-active
            // strip must not be treated as "new" here.
            let managedAcrossAllStrips: Set<UInt32> = stripControllers.values.reduce(into: []) { set, sc in
                for tile in sc.windowMap.keys { set.insert(tile.rawValue) }
            }
            let newWindowIDs = onScreenIDs.subtracting(managedAcrossAllStrips)

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
                        let classification = classifyWithRules(props)
                        guard classification == .tile else { continue }
                        tracker.registerTrackedWindow(window)
                        app.observeWindow(window.element)
                        let (gid, targetSC) = stripControllerEntryForWindow(window)
                        let saved = resolveSnapshotPosition(
                            for: window, on: targetSC, groupID: gid)
                        targetSC.addWindow(window, app: app, restoredPosition: saved)
                        print("[WM] space: adopted new wid=\(window.windowID) pid=\(window.pid)")
                        fflush(stdout)
                    }
                }

                print("[WM] space restored + \(newWindowIDs.count) new windows")
                fflush(stdout)
            } else {
                print("[WM] space restored: \(stripController.strip.columns.count) cols")
                fflush(stdout)
            }

            // Decide focus target: prefer a recent app activation (dock click that
            // crossed spaces) over the saved-focus tile. Fall back to saved.
            let now = TimeUtil.now()
            var dockActivationTile: TileID?
            // One-shot consume — returns the pid iff within the 0.5s TTL, and
            // always clears the record (so a later unrelated space change can't
            // reuse it).
            if let pid = focusGate.consumeRecentActivation(at: now) {
                dockActivationTile = resolveFocusedTileID(
                    forPID: pid,
                    on: stripController
                )
            }

            let focusTile = dockActivationTile ?? savedFocusTile

            if let focusTile, stripController.windowMap[focusTile] != nil {
                // Dock-driven activation animates nicer visually; saved-focus restore
                // uses .center to match historical behavior.
                let mode: StripController.ScrollMode =
                    (dockActivationTile != nil) ? .incrementalSnap : .center
                stripController.scrollToWindow(tileID: focusTile, mode: mode)
                // Trusted focus — space restore / dock activation
                stripController.userActiveTileID = focusTile
                stripController._confirmedUserActiveTileID = focusTile
            } else {
                // Neither target is present — just re-apply layout
                stripController.applyLayout()
            }

            fflush(stdout)
            return
        }

        // New Space — discover windows from scratch. Other strips may have
        // already populated via their own switchSpace above; skip windows
        // already owned by any strip.
        let managedAcrossAllStrips: Set<UInt32> = stripControllers.values.reduce(into: []) { set, sc in
            for tile in sc.windowMap.keys { set.insert(tile.rawValue) }
        }
        for (_, sc) in stripControllers { sc.beginBatch() }
        for (pid, app) in tracker.apps {
            let appWindows = discoverWindows(pid: pid)
            for window in appWindows {
                guard onScreenIDs.contains(window.windowID) else { continue }
                guard !managedAcrossAllStrips.contains(window.windowID) else { continue }
                guard !tracker.floatingWindows.contains(window.windowID),
                      !tracker.ignoredWindows.contains(window.windowID)
                else { continue }

                let props = window.getPropertiesFast()
                guard !props.isMinimized && !props.isFullscreen else { continue }

                let classification = classifyWithRules(props)
                guard classification == .tile else { continue }

                tracker.registerTrackedWindow(window)
                app.observeWindow(window.element)
                let (gid, targetSC) = stripControllerEntryForWindow(window)
                let saved = resolveSnapshotPosition(for: window, on: targetSC, groupID: gid)
                targetSC.addWindow(window, app: app, restoredPosition: saved)
            }
        }
        for (_, sc) in stripControllers { sc.finishBatch() }

        // Consume any pending dock-activation carryover — the new-Space
        // discovery path does its own focus ordering via addWindow, and
        // leaving the field set would leak into a subsequent unrelated
        // space change within the 500ms TTL.
        focusGate.consumeRecentActivation(at: TimeUtil.now())

        print(
            "[WM] space changed: new strip with \(stripController.strip.columns.count) cols"
        )
        fflush(stdout)
    }

    public func performAction(_ action: HotkeyAction) {
        guard !isPaused else { return }
        handleHotkeyAction(action)
    }

    /// Return the strip controller for the group under the current cursor.
    /// Used by hotkeys so commands route to the strip the user is looking at,
    /// not just the `activeDisplayID` one. Falls back to the active strip if
    /// the cursor's display isn't mapped (e.g. cursor on an unmanaged display).
    /// Side-effect: updates `activeDisplayID` to the cursor's display when a
    /// match is found, so subsequent non-cursor-routed code sees the right
    /// "active" display.
    private enum StripDirection { case up, down }

    /// Focus the active window of the strip immediately above/below the strip
    /// currently under the cursor, by CG-Y midpoint of each group's totalSpan.
    /// No-op if there's no strip in the requested direction.
    private func focusStripInDirection(_ dir: StripDirection) {
        let current = stripControllerUnderCursor()
        let curMidY = current.strip.groupArea.totalSpan.midY

        var best: (sc: StripController, gid: GroupID)? = nil
        var bestDist = CGFloat.infinity
        for (gid, sc) in stripControllers where sc !== current {
            let theirMidY = sc.strip.groupArea.totalSpan.midY
            let dy = theirMidY - curMidY
            switch dir {
            case .up:    guard dy < 0 else { continue }
            case .down:  guard dy > 0 else { continue }
            }
            let dist = abs(dy)
            if dist < bestDist {
                bestDist = dist
                best = (sc, gid)
            }
        }
        guard let target = best else {
            print("[WM] focus \(dir) — no strip found")
            fflush(stdout)
            return
        }
        // Snap activeDisplayID to the target group so subsequent non-cursor-
        // routed code points at the right strip.
        if let firstID = target.sc.strip.groupArea.regions.first?.displayID {
            activeDisplayID = CGDirectDisplayID(firstID)
        }
        target.sc.focusActiveWindow()
        print("[WM] focus \(dir) → group \(target.gid)")
        fflush(stdout)
    }

    private func stripControllerUnderCursor() -> StripController {
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let primaryH = displayManager.primaryScreenHeight
        for (displayID, info) in displayManager.displays {
            // DisplayInfo.frame is AppKit coords; convert to CG (top-left origin).
            let cgY = primaryH - info.frame.maxY
            let cgRect = CGRect(
                x: info.frame.minX, y: cgY,
                width: info.frame.width, height: info.frame.height
            )
            if cgRect.contains(cursor) {
                if let gid = displayToGroup[displayID], let sc = stripControllers[gid] {
                    if activeDisplayID != displayID {
                        activeDisplayID = displayID
                    }
                    return sc
                }
            }
        }
        return stripController
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
        let sc = stripControllerUnderCursor()
        switch action {
        case .focusLeft:
            sc.focusLeft()
        case .focusRight:
            sc.focusRight()
        case .focusUp:
            focusStripInDirection(.up)
        case .focusDown:
            focusStripInDirection(.down)
        case .moveColumnLeft:
            sc.moveColumnLeft()
            scheduleSnapshotSave()
        case .moveColumnRight:
            sc.moveColumnRight()
            scheduleSnapshotSave()
        case .cycleWidthPreset:
            sc.cycleWidthPreset()
            scheduleSnapshotSave()
        case .toggleFullWidth:
            sc.toggleFullWidth()
            scheduleSnapshotSave()
        case .toggleFloating:
            if let focusedWID = getFocusedWindowID(),
               tracker.floatingWindows.contains(focusedWID),
               let window = tracker.windows[focusedWID],
               let app = tracker.apps[window.pid]
            {
                tracker.unmarkFloating(focusedWID)
                userToggledFloats.remove(focusedWID)
                let (gid, targetSC) = stripControllerEntryForWindow(window)
                let restored = resolveSnapshotPosition(for: window, on: targetSC, groupID: gid)
                targetSC.unfloatWindow(window, app: app, restoredPosition: restored)
                scheduleSnapshotSave()
                print("[WM] Window \(focusedWID) is now tiled (unfloated)")
                fflush(stdout)
            } else if let window = sc.toggleFloating() {
                saveSnapshotImmediate(sc: sc)
                tracker.markFloating(window.windowID)
                userToggledFloats.insert(window.windowID)
                print("[WM] Window \(window.tileID.rawValue) is now floating")
                fflush(stdout)
            }
        case .closeWindow:
            sc.closeActiveWindow()
        }
    }

    // MARK: - Focused Window Query

    /// Get the CGWindowID of the macOS-focused window via Accessibility API.
    /// Routes through the frontmost app's tracked AXApp when possible so the
    /// call inherits the 100ms messaging timeout set in AXApp.init; falls back
    /// to a direct query for unmanaged / un-tracked apps (still with an explicit
    /// timeout so a hung app can't block main).
    private func getFocusedWindowID() -> CGWindowID? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier
        if let axApp = tracker.apps[pid] {
            return axApp.focusedWindowID()
        }
        // Fallback: app isn't tracked (unmanaged activation policy, etc.).
        // Apply the same messaging timeout defensively before querying.
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.1)
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)
        guard err == .success, let value else { return nil }
        // value is AnyObject; AXUIElement is a CFTypeRef alias that always succeeds as? cast,
        // so we rely on the err == .success check above for validity.
        let element = value as! AXUIElement
        return windowID(for: element)
    }

    /// Resolve "which tracked window of `pid` does the user mean right now" on the
    /// given strip. Tries in order:
    /// 1. AX's kAXFocusedWindow on the app (authoritative).
    /// 2. Most recently focused tracked window of pid on this strip.
    ///    If no window has focus history, the first iterated window wins
    ///    (nil-guard below) — arbitrary but no worse than the old `.first(where:)`.
    ///
    /// Scope note: `sc` is a single strip (one display). On multi-monitor setups
    /// where the activated app's focused window lives on a different monitor's
    /// strip, all tiers miss and nil is returned — the dock click produces no
    /// scroll on any monitor. This matches the pre-plan behavior, which also
    /// only scrolled `stripController` (active display). Searching all strips
    /// would risk surprising scrolls on background monitors.
    ///
    /// Also returns nil for apps whose only visible windows are floating (not
    /// in `sc.windowMap`) or cross-Space activations before the destination
    /// strip has been restored — both intentional no-ops.
    private func resolveFocusedTileID(forPID pid: pid_t, on sc: StripController) -> TileID? {
        // 1. Ask AX. If AX gives a definite answer, trust it — even when the
        //    answer is "the focused window is something we don't track" (a
        //    floating PIP, a dialog, a window on a different strip). Falling
        //    through to step 2 in that case would scroll to an unrelated
        //    tracked window of the same app, which contradicts the app's own
        //    focus state. Only proceed to step 2 when AX has nothing to say
        //    (no focused window yet — common right after activation).
        if let axApp = tracker.apps[pid],
           let wid = axApp.focusedWindowID()
        {
            let tid = TileID(wid)
            return sc.windowMap[tid] != nil ? tid : nil
        }

        // 2. Most recently focused tracked window of this pid on this strip.
        //    `bestTile == nil` guard guarantees the first matching window wins
        //    when no focus history exists; real timestamps (TimeUtil.now() values,
        //    which are far above 0) overwrite it.
        var bestTile: TileID?
        var bestTime: Double = 0
        for (tid, window) in sc.windowMap where window.pid == pid {
            let t = tracker.lastFocusTimeByWindow[window.windowID] ?? 0
            if bestTile == nil || t > bestTime {
                bestTile = tid
                bestTime = t
            }
        }
        return bestTile
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

        // Pass 1: Remove dead windows from every strip (not just the active one).
        // A window on a secondary strip that disappeared from CGWindowList is just
        // as stale as one on the active strip.
        //
        // A window is only reaped once it has been absent on TWO consecutive
        // checks. A single-tick disappearance is almost always a Space transition
        // in flight: the window server flips to the destination Space's on-screen
        // list before NSWorkspace.activeSpaceDidChange is delivered on the main
        // queue, so every departing-Space window momentarily fails the on-screen
        // test. Reaping on that first miss would gut the whole strip and then
        // handleSpaceChange would save the emptied layout over the departing
        // Space's in-session stash (finding #17). By the next check (500ms) the
        // spaceChanged handler has run switchSpace and moved those windows out of
        // windowMap, so the second-miss removal never fires for a genuine Space
        // switch — only for windows that really are gone.
        var changed = false
        var missingThisCheck: Set<CGWindowID> = []
        for (_, sc) in stripControllers {
            for (tileID, window) in sc.windowMap {
                guard !onScreenIDs.contains(window.windowID) else { continue }
                if let adoptedAt = recentlyAdoptedWindows[window.windowID],
                   now.timeIntervalSince(adoptedAt) < 2.0 {
                    #if DEBUG
                        print("[HealthCheck] Skipping recently adopted window wid=\(window.windowID)")
                        fflush(stdout)
                    #endif
                    continue
                }

                // First consecutive miss: defer removal to the next check.
                guard healthCheckMissing.contains(window.windowID) else {
                    missingThisCheck.insert(window.windowID)
                    continue
                }

                if let colIndex = sc.strip.columns.firstIndex(where: { $0.tiles.contains(tileID) }) {
                    let col = sc.strip.columns[colIndex]
                    let colData = sc.strip.columnData[colIndex]
                    let width: ColumnWidth = col.width == .auto ? .fixed(colData.cachedWidth) : col.width
                    recentRemovalsByPID[window.pid] = RecentRemoval(
                        columnIndex: colIndex, width: width,
                        presetIndex: col.presetIndex, isFullWidth: col.isFullWidth, date: now)
                }

                print("[HealthCheck] Removing dead window wid=\(window.windowID) tileID=\(tileID.rawValue)")
                fflush(stdout)
                sc.removeWindow(tileID: tileID)
                scheduleSnapshotSave(sc: sc)
                tracker.untrackWindow(window.windowID)
                recentlyAdoptedWindows.removeValue(forKey: window.windowID)
                // The destroyed tile may also be pinned in ANOTHER strip's stashed
                // Space snapshot (multi-monitor, or a Space this strip visited then
                // left). removeWindow prunes only the owning strip; prune the rest
                // so no dead AXWindow/AXApp stays referenced there (finding #6/#22).
                for (_, other) in stripControllers where other !== sc {
                    other.pruneSavedSpaces(removedTileID: tileID)
                }
                changed = true
            }
        }
        // Carry forward this check's misses. Windows that reappeared or were
        // reaped drop out, so the set stays bounded and self-correcting.
        healthCheckMissing = missingThisCheck

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

    /// Classify a window applying the user's `[[rules]]` first (mirroring the
    /// canonical `WindowTracker.registerWindow` / `adoptUnmanagedWindows` paths),
    /// then falling back to the default heuristic. Bare `classifyWindow` ignores
    /// rules — the Space-discovery loops used it directly and so would force a
    /// user-floated app into the strip whenever its window first appeared on a
    /// Space other than the startup one (finding #42). Every discovery site now
    /// funnels through here so the rule pass can't drift again.
    private func classifyWithRules(_ props: WindowProperties) -> WindowClassification {
        tracker.rules.first(where: { $0.matches(props) })?.classification
            ?? classifyWindow(props)
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

        // Bound the negative-classification cache to windows still on screen so
        // it can't grow for the process lifetime (finding #32).
        if let onScreenIDs {
            healthCheckIgnored.formIntersection(onScreenIDs)
        }

        for (pid, app) in tracker.apps {
            let newWindows = discoverWindows(pid: pid)
            for window in newWindows {
                // Skip windows already tracked and in the strip
                guard !stripWindowIDs.contains(window.windowID) else { continue }
                // Skip windows not confirmed on-screen by CGWindowList
                if let onScreenIDs, !onScreenIDs.contains(window.windowID) { continue }
                // Skip windows already tracked as floating/ignored, or already
                // classified non-tileable by a prior sweep — this check MUST come
                // before getPropertiesFast() (≈9 AX round-trips) so a resident
                // float/ignore window that missed its create notification isn't
                // re-probed every 500ms forever (finding #32).
                guard !tracker.floatingWindows.contains(window.windowID),
                    !tracker.ignoredWindows.contains(window.windowID),
                    !healthCheckIgnored.contains(window.windowID)
                else { continue }

                let props = window.getPropertiesFast()
                guard !props.isMinimized, !props.isFullscreen else { continue }

                let classification = classifyWithRules(props)

                guard classification == .tile else {
                    // Record the negative classification so subsequent sweeps
                    // skip this window before the getPropertiesFast() battery.
                    // .float → tracker.floatingWindows (also honored by every
                    // other adoption path's guard, and semantically correct —
                    // this is a floating window); .ignore → local set (the
                    // tracker exposes no public ignore setter).
                    if classification == .float {
                        tracker.markFloating(window.windowID)
                    } else {
                        healthCheckIgnored.insert(window.windowID)
                    }
                    continue
                }

                // Adopt this window into the strip
                if tracker.windows[window.windowID] == nil {
                    tracker.registerTrackedWindow(window)
                    app.observeWindow(window.element)
                }
                let (gid, targetSC) = stripControllerEntryForWindow(window)

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
                    restored = resolveSnapshotPosition(for: window, on: targetSC, groupID: gid)
                }

                targetSC.addWindow(window, app: app, restoredPosition: restored)

                // Fix B: Track adoption time for grace period
                recentlyAdoptedWindows[window.windowID] = Date()
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
        // Sort by windowID so dictionary iteration order can't make identical
        // state serialize to different bytes (which would defeat the dirty check).
        state.sort { ($0["windowID"] as? UInt32 ?? 0) < ($1["windowID"] as? UInt32 ?? 0) }

        // Serialize with sorted keys, then skip the disk write when the bytes
        // match the last persist. The 5s timer otherwise rewrites an identical
        // file forever — steady SSD traffic and a recurring wake that blocks
        // deeper idle states on battery when nothing has changed (finding #35).
        guard let data = try? JSONSerialization.data(
            withJSONObject: state, options: [.sortedKeys]) else { return }
        let hash = data.hashValue
        guard hash != lastPersistedStateHash else { return }
        lastPersistedStateHash = hash
        try? data.write(to: URL(fileURLWithPath: stateFilePath))
    }

    private func recoverFromCrash() {
        guard FileManager.default.fileExists(atPath: stateFilePath),
            let data = try? Data(contentsOf: URL(fileURLWithPath: stateFilePath)),
            let state = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return
        }

        print("[WM] Found crash recovery state — checking for orphaned windows")
        fflush(stdout)

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

            for (tileID, window) in sc.windowMap {
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
                // Queue-ordered, NOT a direct setFrame. A write already sitting on
                // this app's serial queue would otherwise land after the inline
                // restore and undo it — and once such a write has been dequeued,
                // revoking it is impossible (apply runs outside writeLock). Going
                // through the same queue makes FIFO ordering guarantee we are last.
                sc.enqueueRestore(tileID: tileID, frame: newFrame)
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
        case .focusUp:
            focusStripInDirection(.up)
            return ReelResponse(success: true)
        case .focusDown:
            focusStripInDirection(.down)
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
                let (gid, sc) = stripControllerEntryForWindow(window)
                let restored = resolveSnapshotPosition(for: window, on: sc, groupID: gid)
                // Unfloat onto the OWNING strip (matches the hotkey path) — the
                // slot was resolved against `sc`, so unfloating onto the active
                // strip would drop the window on the wrong monitor.
                sc.unfloatWindow(window, app: app, restoredPosition: restored)
                scheduleSnapshotSave(sc: sc)
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
            let now = TimeUtil.now()
            let activeGID = displayToGroup[activeDisplayID]

            let groupsJSON: [[String: Any]] = stripControllers.map { (gid, sc) -> [String: Any] in
                let strip = sc.strip
                let frames = computeTargetFrames(strip: strip, time: now)
                var frameByTile: [UInt32: TargetFrame] = [:]
                for f in frames { frameByTile[f.tileID.rawValue] = f }

                let regions: [[String: Any]] = strip.groupArea.regions.map { r in
                    [
                        "displayID": r.displayID,
                        "minX": r.rect.minX, "minY": r.rect.minY,
                        "maxX": r.rect.maxX, "maxY": r.rect.maxY,
                        "width": r.rect.width, "height": r.rect.height,
                    ]
                }

                let cols: [[String: Any]] = strip.columns.enumerated().map { (i, col) -> [String: Any] in
                    let cd = strip.columnData[i]
                    let firstTile = col.tiles.first.map { $0.rawValue } ?? 0
                    let f = frameByTile[firstTile]
                    let owningRegion = strip.regionForColumn(i, at: now)
                    var overlaps: [[String: Any]] = []
                    if let f {
                        for r in strip.groupArea.regions {
                            let inter = f.frame.intersection(r.rect)
                            let area = (inter.isNull || inter.width <= 0 || inter.height <= 0)
                                ? 0.0
                                : Double(inter.width * inter.height)
                            overlaps.append([
                                "displayID": r.displayID,
                                "interX": inter.isNull ? 0 : inter.minX,
                                "interW": inter.isNull ? 0 : inter.width,
                                "area": area,
                            ])
                        }
                    }
                    // Window metadata for this column's active tile.
                    let firstTileID = col.tiles.first
                    let window = firstTileID.flatMap { sc.windowMap[$0] }
                    return [
                        "index": i,
                        "tiles": col.tiles.map(\.rawValue),
                        "windowID": window?.windowID ?? 0,
                        "bundleID": window.flatMap { tracker.apps[$0.pid]?.bundleIdentifier } ?? "",
                        "title": window?.getTitle() ?? "",
                        "width": String(describing: col.width),
                        "cachedWidth": cd.cachedWidth,
                        "currentAnimatedWidth": cd.currentWidth(at: now),
                        "isFullWidth": col.isFullWidth,
                        "presetIndex": col.presetIndex as Any? ?? NSNull(),
                        "active": i == strip.activeColumnIndex,
                        "snapIndex": strip.snapIndices.indices.contains(i) ? strip.snapIndices[i] : -1,
                        "owningRegionDisplayID": owningRegion.displayID,
                        "frame": f.map { [
                            "x": $0.frame.minX, "y": $0.frame.minY,
                            "w": $0.frame.width, "h": $0.frame.height,
                        ] } ?? [:],
                        "isVisible": f?.isVisible ?? false,
                        "isOffScreen": f?.isOffScreen ?? false,
                        "regionOverlaps": overlaps,
                    ]
                }

                // Stashed space states (other desktops this strip has seen).
                let savedSpaces: [[String: Any]] = sc.savedSpaceFingerprints.map { fp in
                    let snap = sc.savedSpaceSnapshot(for: fp) ?? []
                    return [
                        "fingerprint": fp.sorted(),
                        "windows": snap.map { entry in
                            [
                                "tileID": entry.tileID.rawValue,
                                "windowID": entry.windowID,
                                "bundleID": entry.bundleID ?? "",
                                "title": entry.title ?? "",
                            ]
                        },
                    ]
                }

                return [
                    "groupID": gid,
                    "isActive": gid == activeGID,
                    "regions": regions,
                    "viewPos": strip.viewPos(at: now),
                    "workingAreaMinX": strip.workingArea.minX,
                    "workingAreaWidth": strip.workingArea.width,
                    "gap": strip.gap,
                    "activeColumnIndex": strip.activeColumnIndex,
                    "currentSpaceFingerprint": sc.currentSpaceFingerprint.sorted(),
                    "currentColumns": cols,
                    "savedSpaces": savedSpaces,
                ]
            }

            // Snapshot store entries (persisted spaces across all groups).
            var storeEntries: [[String: Any]] = []
            if let store = snapshotStore {
                for (key, snap) in store.allSnapshots() {
                    storeEntries.append([
                        "groupID": key.groupID,
                        "spaceFingerprint": key.spaceFingerprint.sorted(),
                        "slots": snap.slots.map { slot in
                            [
                                "bundleID": slot.bundleID,
                                "title": slot.windowTitle ?? "",
                                "width": String(describing: slot.width),
                                "windowID": slot.windowID ?? 0,
                                "isFullWidth": slot.isFullWidth,
                            ]
                        },
                    ])
                }
            }

            let payload: [String: Any] = [
                "activeDisplayID": activeDisplayID,
                "primaryScreenHeight": displayManager.primaryScreenHeight,
                "groups": groupsJSON,
                "snapshotStore": storeEntries,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
                let json = String(data: data, encoding: .utf8)
            {
                return ReelResponse(success: true, data: json)
            }
            return ReelResponse(success: true, data: "[]")
        case .getLayouts:
            // Cross-Space probe: for every space Reel knows about (current +
            // stashed in-session + persisted on-disk), list its windows with
            // their current AX frame so "stuck" windows can be spotted no
            // matter which Space they belong to.
            let now = TimeUtil.now()
            let activeGID = displayToGroup[activeDisplayID]

            // One CGWindowList pass to flag which windowIDs macOS considers
            // currently on-screen (i.e. in the active Space, un-minimized).
            let onScreenIDs: Set<CGWindowID> = {
                guard let arr = CGWindowListCopyWindowInfo(
                    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
                ) as? [[CFString: Any]] else { return [] }
                var s = Set<CGWindowID>()
                for d in arr {
                    if let n = d[kCGWindowNumber] as? CGWindowID { s.insert(n) }
                }
                return s
            }()

            func entry(
                tileID: TileID,
                window: AXWindow,
                bundleID: String?,
                columnWidth: ColumnWidth?,
                isFullWidth: Bool?,
                workingArea: CGRect
            ) -> [String: Any] {
                var frame: Any = NSNull()
                var slivered = false
                if case .success(let f) = window.getFrame() {
                    frame = [
                        "x": f.minX, "y": f.minY,
                        "w": f.width, "h": f.height,
                    ]
                    // sliverFrame keeps the window at FULL width and leaves only
                    // ~1px visible at a working-area edge, so the old
                    // width≤2 / minX≤-9000 heuristic never fired for a genuinely
                    // hidden window (no display is 9000px wide; the window is
                    // never shrunk). Use the same geometric off-screen test the
                    // unsliver watchdog uses so the diagnostic can't drift from
                    // the real technique again (finding #43).
                    slivered = self.isFrameOffScreen(f, workingArea: workingArea)
                }
                var out: [String: Any] = [
                    "tileID": tileID.rawValue,
                    "windowID": window.windowID,
                    "bundleID": bundleID ?? "",
                    "title": window.getTitle() ?? "",
                    "currentFrame": frame,
                    "isOnScreen": onScreenIDs.contains(window.windowID),
                    "slivered": slivered,
                ]
                if let w = columnWidth { out["savedWidth"] = String(describing: w) }
                if let f = isFullWidth { out["isFullWidth"] = f }
                return out
            }

            var spaces: [[String: Any]] = []
            var seen: Set<SnapshotKey> = []

            for (gid, sc) in stripControllers {
                // --- current space: use live strip + columns ---
                let strip = sc.strip
                var currWindows: [[String: Any]] = []
                for col in strip.columns {
                    for tile in col.tiles {
                        guard let w = sc.windowMap[tile] else { continue }
                        let bundle = tracker.apps[w.pid]?.bundleIdentifier
                        currWindows.append(entry(
                            tileID: tile, window: w, bundleID: bundle,
                            columnWidth: col.width, isFullWidth: col.isFullWidth,
                            workingArea: strip.workingArea
                        ))
                    }
                }
                spaces.append([
                    "groupID": gid,
                    "isActiveGroup": gid == activeGID,
                    "isCurrentSpace": true,
                    "source": "live",
                    "spaceFingerprint": sc.currentSpaceFingerprint.sorted(),
                    "windows": currWindows,
                ])
                seen.insert(SnapshotKey(groupID: gid, spaceFingerprint: sc.currentSpaceFingerprint))

                // --- stashed-in-session spaces: AXWindow refs are still alive ---
                for fp in sc.savedSpaceFingerprints {
                    guard let detail = sc.savedSpaceDetail(for: fp) else { continue }
                    var wins: [[String: Any]] = []
                    for (tile, axw, bundle, width, isFW) in detail {
                        wins.append(entry(
                            tileID: tile, window: axw, bundleID: bundle,
                            columnWidth: width, isFullWidth: isFW,
                            workingArea: strip.workingArea
                        ))
                    }
                    spaces.append([
                        "groupID": gid,
                        "isActiveGroup": false,
                        "isCurrentSpace": false,
                        "source": "session",
                        "spaceFingerprint": fp.sorted(),
                        "windows": wins,
                    ])
                    seen.insert(SnapshotKey(groupID: gid, spaceFingerprint: fp))
                }
            }

            // --- persisted snapshot-store entries not covered above ---
            if let store = snapshotStore {
                for (key, snap) in store.allSnapshots() {
                    if seen.contains(key) { continue }
                    let wins: [[String: Any]] = snap.slots.map { slot in
                        var d: [String: Any] = [
                            "tileID": NSNull(),
                            "windowID": slot.windowID ?? 0,
                            "bundleID": slot.bundleID,
                            "title": slot.windowTitle ?? "",
                            "savedWidth": String(describing: slot.width),
                            "isFullWidth": slot.isFullWidth,
                            "currentFrame": NSNull(),
                            "slivered": false,
                            "vacant": slot.vacant,
                        ]
                        if let wid = slot.windowID {
                            d["isOnScreen"] = onScreenIDs.contains(wid)
                        } else {
                            d["isOnScreen"] = false
                        }
                        return d
                    }
                    spaces.append([
                        "groupID": key.groupID,
                        "isActiveGroup": false,
                        "isCurrentSpace": false,
                        "source": "disk",
                        "spaceFingerprint": key.spaceFingerprint.sorted(),
                        "windows": wins,
                    ])
                }
            }

            let payload2: [String: Any] = [
                "activeDisplayID": activeDisplayID,
                "primaryScreenHeight": displayManager.primaryScreenHeight,
                "queryTime": now,
                "spaces": spaces,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload2, options: [.prettyPrinted, .sortedKeys]),
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
                            "groupID": key.groupID,
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
        case .pause:
            // Route through the single togglePause() path — assert the desired
            // state rather than forking the pause/resume logic, so pause
            // semantics stay single-sourced.
            if !isPaused { togglePause() }
            return ReelResponse(success: true, message: "Paused")
        case .resume:
            if isPaused { togglePause() }
            return ReelResponse(success: true, message: "Resumed")
        case .reloadConfig:
            // Same reload the menu bar's "Reload Config" button invokes.
            reloadConfig()
            return ReelResponse(success: true, message: "Config reloaded")
        case .getStatus:
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                ?? "0.4.0"  // x-release-please-version
            let status: [String: Any] = [
                "isPaused": isPaused,
                "version": version,
                "socketPath": reelSocketPath(),
                "configDir": ReelConfig.configDir,
                "stateDir": ReelConfig.stateDir,
                // Pids Reel is actively managing (an AXApp observer exists for
                // each). Under REEL_MANAGE_ONLY_PIDS this equals the allowlist —
                // registerApp refuses every pid outside it, so none are tracked.
                "managedPids": tracker.apps.keys.map { Int($0) }.sorted(),
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: status, options: [.prettyPrinted, .sortedKeys]),
                let json = String(data: data, encoding: .utf8)
            {
                return ReelResponse(success: true, data: json)
            }
            return ReelResponse(success: false, message: "Failed to serialize status")
        case .quit:
            // Termination is deferred to `onFlushed` (wired below). Calling
            // NSApp.terminate here races the response write, which happens after
            // this handler returns — reel-msg would frequently see an empty reply,
            // which is why it had to treat that as success.
            return ReelResponse(success: true, message: "Quitting")
        }
    }

    // MARK: - Multi-Monitor Helpers

    /// Resolve a snapshot position for a window using the strip snapshot store.
    private func resolveSnapshotPosition(
        for window: AXWindow, on sc: StripController, groupID: [CGDirectDisplayID]
    ) -> RestoredSlot? {
        guard config.positionMemory, let snapshotStore else { return nil }

        let bundleID = tracker.apps[window.pid]?.bundleIdentifier
        guard let bundleID else { return nil }

        let title = window.getTitle()
        let key = SnapshotKey(
            groupID: Array(groupID),
            spaceFingerprint: sc.currentSpaceFingerprint
        )
        var currentBundleIDs = buildCurrentBundleIDs(sc: sc)
        currentBundleIDs.insert(bundleID)  // Include the incoming window for disk matching

        guard let snapshot = snapshotStore.snapshotFuzzyByBundleIDs(
            groupID: key.groupID, fingerprint: key.spaceFingerprint,
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

    /// Deterministic first-visit replay: use the persisted snapshot (fuzzy-matched
    /// by bundle-ID set) to reassemble a strip in saved order when we haven't
    /// visited this Space this session. Returns the set of adopted windowIDs so
    /// the caller can skip them in its subsequent discovery pass.
    ///
    /// Bypasses `tracker.floatingWindows` — if a window was saved as a tile, a
    /// transient float classification (e.g., the empty-title popup heuristic
    /// firing on a window that is in fact a real document) is un-marked here.
    /// `tracker.ignoredWindows` is still respected.
    private func replayFromSnapshot(
        sc: StripController,
        groupID: GroupID,
        onScreenIDs: Set<UInt32>,
        exclude: Set<UInt32>
    ) -> Set<UInt32> {
        guard config.positionMemory, let snapshotStore else { return [] }

        let currentBundleIDs = Set(tracker.apps.values.compactMap { $0.bundleIdentifier })
        guard let snapshot = snapshotStore.snapshotFuzzyByBundleIDs(
            groupID: Array(groupID),
            fingerprint: sc.currentSpaceFingerprint,
            currentBundleIDs: currentBundleIDs)
        else { return [] }

        // Exclude windows already owned by any strip, plus any adopted earlier
        // in this replay pass (other strips adopted first).
        var alreadyUsed: Set<UInt32> = exclude
        for otherSC in stripControllers.values {
            for tile in otherSC.windowMap.keys { alreadyUsed.insert(tile.rawValue) }
        }

        // Collect on-screen candidate windows whose bundle matches some slot.
        let slotBundles = Set(snapshot.slots.compactMap { $0.vacant ? nil : $0.bundleID })
        struct Cand {
            let window: AXWindow
            let app: AXApp
            let info: StripWindowInfo
        }
        var candidates: [Cand] = []
        for (pid, app) in tracker.apps {
            guard let bid = app.bundleIdentifier, slotBundles.contains(bid) else { continue }
            for window in discoverWindows(pid: pid) {
                guard onScreenIDs.contains(window.windowID) else { continue }
                guard !alreadyUsed.contains(window.windowID) else { continue }
                // Ignored windows (sheets, dialogs flagged at classification) stay out.
                guard !tracker.ignoredWindows.contains(window.windowID) else { continue }
                let props = window.getPropertiesFast()
                guard !props.isMinimized && !props.isFullscreen else { continue }
                candidates.append(Cand(
                    window: window, app: app,
                    info: StripWindowInfo(
                        tileID: window.tileID,
                        windowID: window.windowID,
                        bundleID: bid,
                        windowTitle: window.getTitle())))
            }
        }
        guard !candidates.isEmpty else { return [] }

        let pairs = matchSlotsToWindows(
            slots: snapshot.slots,
            candidates: candidates.map(\.info))
        guard !pairs.isEmpty else { return [] }

        var adopted: Set<UInt32> = []
        sc.beginBatch()
        for pair in pairs {
            let slot = snapshot.slots[pair.slotIndex]
            let cand = candidates[pair.candidateIndex]

            // Float-gate bypass: snapshot says "tile", override transient float mark.
            if tracker.floatingWindows.contains(cand.window.windowID) {
                tracker.unmarkFloating(cand.window.windowID)
            }

            tracker.registerTrackedWindow(cand.window)
            cand.app.observeWindow(cand.window.element)
            sc.addWindow(
                cand.window, app: cand.app,
                restoredPosition: RestoredSlot(
                    slotIndex: adopted.count,
                    width: slot.width,
                    presetIndex: slot.presetIndex,
                    isFullWidth: slot.isFullWidth))
            adopted.insert(cand.window.windowID)
        }
        sc.finishBatch()

        print("[WM] replay: adopted \(adopted.count)/\(snapshot.slots.count) slot(s) onto group=\(groupID)")
        fflush(stdout)

        scheduleUnsliverWatchdog(sc: sc, windowIDs: adopted)

        return adopted
    }

    /// After replay, verify each adopted window's on-screen frame and force a
    /// setFrame if the window is still slivered/corner-hidden. Runs async so
    /// the setFrame dispatches from `finishBatch → applyLayout` have time to
    /// land before we read back.
    /// Geometric off-screen test matching `LayoutEngine.sliverFrame`'s technique:
    /// the window keeps its full width and is pushed almost entirely past a
    /// working-area edge (right edge left of the area, or left edge right of it),
    /// or corner-hidden at a large negative origin. Shared by the get-layouts
    /// diagnostic and the replay unsliver watchdog so the two detections of the
    /// same condition can't drift apart (finding #43).
    private func isFrameOffScreen(_ frame: CGRect, workingArea: CGRect) -> Bool {
        frame.maxX < workingArea.minX + 5
            || frame.minX > workingArea.maxX - 5
            || frame.origin.x <= -5000
            || frame.origin.y <= -5000
    }

    private func scheduleUnsliverWatchdog(sc: StripController, windowIDs: Set<UInt32>) {
        guard !windowIDs.isEmpty else { return }
        let workingArea = sc.strip.workingArea
        // Capture (window, target) pairs up-front — sc.windowMap may mutate by
        // the time the async closure runs (closed/replaced windows).
        let pairs: [(AXWindow, CGRect)] = windowIDs.compactMap { wid in
            let tid = TileID(wid)
            guard let window = sc.windowMap[tid],
                  let target = sc.lastCommittedFrames[tid] else { return nil }
            return (window, target)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            for (window, target) in pairs {
                guard case .success(let current) = window.getFrame() else { continue }
                guard self.isFrameOffScreen(current, workingArea: workingArea) else { continue }
                print("[WM] replay unsliver wid=\(window.windowID) target=\(target) current=\(current)")
                fflush(stdout)
                _ = window.setFrame(target)
            }
        }
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
        let gid = stripControllers.first(where: { $0.value === sc })?.key
            ?? displayToGroup[activeDisplayID]
            ?? [activeDisplayID]
        return SnapshotKey(groupID: Array(gid), spaceFingerprint: sc.currentSpaceFingerprint)
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
            snapshotStore.consumeDiskEntry(groupID: key.groupID, bundleIDs: bundleIDs)
        }
    }

    /// Returns both the GroupID and StripController for a window based on its frame.
    private func stripControllerEntryForWindow(_ window: AXWindow) -> (
        GroupID, StripController
    ) {
        if let frame = try? window.getFrame().get() {
            for (gid, sc) in stripControllers {
                if sc.strip.workingArea.intersects(frame) {
                    return (gid, sc)
                }
            }
        }
        // No positional match; fall back to any existing strip (or a freshly
        // materialized one if all displays have disconnected — never crash).
        return ensureFallbackStrip()
    }

    /// Ensure at least one strip controller exists, returning an arbitrary entry
    /// (the first, if any). If `stripControllers` is empty — all displays
    /// disconnected during a clamshell / KVM / resolution transition — create a
    /// synthetic fallback exactly as `init()` does, so the never-empty invariant
    /// that `stripController` and other call sites rely on always holds.
    @discardableResult
    private func ensureFallbackStrip() -> (GroupID, StripController) {
        if let entry = stripControllers.first {
            return (entry.key, entry.value)
        }
        let wa = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let fallbackID = CGMainDisplayID()
        let gid: GroupID = [fallbackID]
        let sc = StripController(
            workingArea: wa, primaryScreenHeight: NSScreen.main?.frame.height ?? 0)
        applyConfigToStrip(sc)
        stripControllers[gid] = sc
        displayToGroup[fallbackID] = gid
        print("[WM] materialized fallback strip (no displays present)")
        fflush(stdout)
        return (gid, sc)
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
                if let gid = displayToGroup[displayID] {
                    return stripControllers[gid]
                }
            }
        }
        return nil
    }

    // MARK: - Display Topology Reconciliation

    /// Reconcile `stripControllers` with the current display set.
    /// Consults `displaysShareOneSpace` + `alignmentGroups()`:
    ///   - Separate Spaces ON: force singleton groups (today's behavior).
    ///   - Separate Spaces OFF: form groups per alignment rule.
    /// Handles pure-new, pure-dissolve, metric-change diff cases. Merge
    /// (subsuming) and split (partitioning) group-diff cases arrive in
    /// follow-up tasks. Idempotent.
    private func reconcileDisplayTopology(
        newDisplays: [CGDirectDisplayID: DisplayInfo]
    ) {
        // NSScreen.screens can transiently report zero screens during hot-plug /
        // dock renegotiation / KVM input switch / resolution transitions, and as
        // a real event on a headless-capable Mac when the sole display sleeps.
        // Reconciling against an empty set would land every group in removedGIDs
        // with no successors, silently drop all windows + stashed Space state,
        // and leave stripControllers EMPTY — after which the never-empty
        // invariant relied on by `stripController` and `stripControllerEntryForWindow`
        // is violated. Keep the last-known controllers frozen until a display returns.
        guard !newDisplays.isEmpty else {
            print("[WM] reconcile: empty display set — keeping last-known strips")
            fflush(stdout)
            return
        }

        let struts = Struts(
            left: CGFloat(config.struts.left),
            right: CGFloat(config.struts.right),
            top: CGFloat(config.struts.top),
            bottom: CGFloat(config.struts.bottom)
        )
        let primaryH = displayManager.primaryScreenHeight

        // Compute new groups. If separate-Spaces is ON, force singletons.
        let newGroups: [[CGDirectDisplayID]]
        if displayManager.displaysShareOneSpace {
            newGroups = DisplayManager.alignmentGroups(from: newDisplays)
        } else {
            newGroups = newDisplays.keys.sorted().map { [$0] }
        }

        let newGroupIDs = Set(newGroups.map { WindowManager.groupID(from: $0) })
        let oldGroupIDs = Set(stripControllers.keys)
        let addedGIDs = newGroupIDs.subtracting(oldGroupIDs)
        let removedGIDs = oldGroupIDs.subtracting(newGroupIDs)
        let persistingGIDs = oldGroupIDs.intersection(newGroupIDs)

        // Helper: build a GroupWorkingArea for a group of display IDs.
        // Binds the reconcile-local inputs to the shared `currentGroupArea` so
        // reloadConfig and this path can never diverge on strut→geometry handling.
        func buildGroupArea(for members: [CGDirectDisplayID]) -> GroupWorkingArea {
            currentGroupArea(
                for: members,
                displays: newDisplays,
                struts: struts,
                primaryScreenHeight: primaryH
            )
        }

        // Distance from an X coordinate to a working area's horizontal span
        // (0 if inside). Used to pick the nearest successor on split when a
        // column's display region isn't owned by any successor group.
        func distanceX(_ x: Double, from area: CGRect?) -> Double {
            guard let area else { return .infinity }
            if x < Double(area.minX) { return Double(area.minX) - x }
            if x > Double(area.maxX) { return x - Double(area.maxX) }
            return 0
        }

        // 1. Persisting groups — update geometry, refresh primaryScreenHeight.
        for gid in persistingGIDs {
            guard let sc = stripControllers[gid] else { continue }
            sc.primaryScreenHeight = primaryH
            sc.updateGroupArea(buildGroupArea(for: gid))
        }

        // 2. Added groups — may be pure-new or merged from predecessor groups.
        for gid in addedGIDs {
            let ga = buildGroupArea(for: gid)

            // Merge case: if this new group's member set is a superset of one
            // or more groups being removed, adopt those groups' columns before
            // the dying controllers are disposed.
            let gidSet = Set(gid)
            var predecessors: [GroupID] = []
            for oldGID in removedGIDs where gidSet.isSuperset(of: Set(oldGID)) {
                predecessors.append(oldGID)
            }

            let sc = StripController(
                workingArea: ga.totalSpan,
                primaryScreenHeight: primaryH
            )
            applyConfigToStrip(sc)
            sc.strip.groupArea = ga
            if let fp = stripControllers.values.first?.currentSpaceFingerprint {
                sc.setSpaceFingerprint(fp)
            }
            stripControllers[gid] = sc

            if predecessors.isEmpty {
                rehomeWindows(onto: sc, newGroupID: gid)
                print("[WM] group added: \(gid)")
            } else {
                // Adopt columns from predecessors in X order (leftmost first).
                // removedGIDs is an unordered Set and windowMap an unordered
                // Dictionary, so the old code scrambled the user's column order
                // on every merge. Sort predecessors by their group's leftmost X
                // and iterate each predecessor's strip.columns in index order,
                // preserving per-column width / preset / full-width via a
                // RestoredSlot with a monotonically increasing slot index.
                sc.beginBatch()
                var adopted = 0
                let orderedPredecessors = predecessors.sorted {
                    (stripControllers[$0]?.strip.workingArea.minX ?? 0)
                        < (stripControllers[$1]?.strip.workingArea.minX ?? 0)
                }
                for oldGID in orderedPredecessors {
                    guard let oldSC = stripControllers[oldGID] else { continue }
                    for (i, column) in oldSC.strip.columns.enumerated() {
                        let colData = oldSC.strip.columnData[i]
                        let width: ColumnWidth =
                            column.width == .auto ? .fixed(colData.cachedWidth) : column.width
                        for tile in column.tiles {
                            guard let window = oldSC.windowMap[tile],
                                let app = tracker.apps[window.pid] else { continue }
                            sc.addWindow(window, app: app, restoredPosition: RestoredSlot(
                                slotIndex: adopted,
                                width: width,
                                presetIndex: column.presetIndex,
                                isFullWidth: column.isFullWidth))
                            adopted += 1
                        }
                    }
                    // Clear predecessor's windowMap so the removed-branch's
                    // rehomeWindowsOff is a no-op for these controllers.
                    for tileID in Array(oldSC.windowMap.keys) {
                        oldSC.removeWindow(tileID: tileID)
                    }
                }
                sc.finishBatch()
                print("[WM] group merged: \(predecessors) → \(gid), adopted \(adopted) columns")
            }
            fflush(stdout)
        }

        // 3. Removed groups — may be pure-dissolve or split into ≥2 new groups.
        for gid in removedGIDs {
            guard let dyingSC = stripControllers[gid] else { continue }

            let gidSet = Set(gid)
            // Split case: new groups whose members are subsets of this old one.
            var successors: [GroupID] = []
            for newGID in addedGIDs where gidSet.isSuperset(of: Set(newGID)) {
                successors.append(newGID)
            }

            if successors.isEmpty {
                // Pure dissolve — windows migrate to any surviving strip by position.
                rehomeWindowsOff(dyingSC: dyingSC)
            } else {
                // Partition dyingSC's columns into successors deterministically:
                // walk strip.columns in index order and route each column by its
                // OWNING display region (regionForColumn), not the live AX frame —
                // a slivered / corner-hidden window reports an off-screen frame
                // that would otherwise dump every hidden column onto the leftmost
                // successor in arbitrary order. Preserve per-column width / preset
                // / full-width and left-to-right order via per-successor slot
                // counters. (Successor controllers were created in step 2.)
                var partitioned = 0
                let now = TimeUtil.now()
                var slotCounters: [GroupID: Int] = [:]
                for (i, column) in dyingSC.strip.columns.enumerated() {
                    let region = dyingSC.strip.regionForColumn(i, at: now)
                    // Prefer the successor that owns this column's display; else
                    // pick the successor whose working area is nearest in X.
                    var targetGID = successors.first(where: { $0.contains(region.displayID) })
                    if targetGID == nil {
                        let cx = Double(region.rect.midX)
                        targetGID = successors.min(by: { a, b in
                            distanceX(cx, from: stripControllers[a]?.strip.workingArea)
                                < distanceX(cx, from: stripControllers[b]?.strip.workingArea)
                        })
                    }
                    guard let chosenGID = targetGID,
                        let target = stripControllers[chosenGID] else { continue }
                    let colData = dyingSC.strip.columnData[i]
                    let width: ColumnWidth =
                        column.width == .auto ? .fixed(colData.cachedWidth) : column.width
                    for tile in column.tiles {
                        guard let window = dyingSC.windowMap[tile],
                            let app = tracker.apps[window.pid] else { continue }
                        let slot = slotCounters[chosenGID, default: 0]
                        target.addWindow(window, app: app, restoredPosition: RestoredSlot(
                            slotIndex: slot,
                            width: width,
                            presetIndex: column.presetIndex,
                            isFullWidth: column.isFullWidth))
                        slotCounters[chosenGID] = slot + 1
                        partitioned += 1
                    }
                }
                // Stop the dying strip from enqueueing FRESH targets for tiles it
                // has already handed to successors: removeWindow ends in
                // applyLayout(), so this loop would otherwise write N shrinking-strip
                // layouts. Being last on each app's serial queue, they land after the
                // successors' writes and yank migrated windows back to pre-split
                // coordinates — or re-sliver ones the shrinking strip pushed out of
                // view, which the successors then never correct because they recorded
                // lastCommittedFrames during addWindow.
                //
                // MUST come after the partition loop above, never before: the
                // isPaused setter freezes in-flight width springs by writing
                // cachedWidth = currentWidth, and the loop reads colData.cachedWidth
                // to build each successor's RestoredSlot. Set early, successors
                // inherit an interpolated width instead of the animation target.
                dyingSC.isPaused = true
                for tileID in Array(dyingSC.windowMap.keys) {
                    dyingSC.removeWindow(tileID: tileID)
                }
                print("[WM] group split: \(gid) → \(successors), partitioned \(partitioned) columns")
                fflush(stdout)
            }

            dyingSC.focusIndicator.hide()
            stripControllers.removeValue(forKey: gid)
            print("[WM] group removed: \(gid)")
            fflush(stdout)
        }

        // Rebuild the display→group routing in one pass. Doing this inline in the
        // add/remove loops deleted the entries the add step had just written: for a
        // merge ([A]+[B] → [A,B]) or a split, every affected display ended up
        // unroutable while its controller was alive. `reconcileDisplayMap` installs
        // successors first and prunes only entries still pointing at a dying group.
        displayToGroup = reconcileDisplayMap(
            current: displayToGroup,
            added: Array(addedGIDs),
            removed: Array(removedGIDs)
        )

        // 4. Snap activeDisplayID to a live display if its group vanished.
        let hasLiveGroup: Bool
        if let gid = displayToGroup[activeDisplayID], stripControllers[gid] != nil {
            hasLiveGroup = true
        } else {
            hasLiveGroup = false
        }
        if !hasLiveGroup {
            activeDisplayID = displayManager.mainDisplay?.displayID
                ?? displayToGroup.keys.first
                ?? CGMainDisplayID()
            print("[WM] activeDisplayID → \(activeDisplayID)")
            fflush(stdout)
        }
    }

    /// Configured struts converted to the Platform `Struts` type.
    private var currentStruts: Struts {
        Struts(
            left: CGFloat(config.struts.left),
            right: CGFloat(config.struts.right),
            top: CGFloat(config.struts.top),
            bottom: CGFloat(config.struts.bottom)
        )
    }

    /// Build a `GroupWorkingArea` for `members`. Delegates to the pure,
    /// unit-tested `DisplayManager.groupWorkingArea`. Shared by
    /// `reconcileDisplayTopology` and `reloadConfig` so there is exactly one
    /// strut→geometry path.
    private func currentGroupArea(
        for members: [CGDirectDisplayID],
        displays: [CGDirectDisplayID: DisplayInfo],
        struts: Struts,
        primaryScreenHeight: CGFloat
    ) -> GroupWorkingArea {
        DisplayManager.groupWorkingArea(
            members: members,
            displays: displays,
            mainDisplayID: displayManager.mainDisplay?.displayID,
            struts: struts,
            primaryScreenHeight: primaryScreenHeight
        )
    }

    /// Apply current config state + frame loop to a fresh StripController.
    private func applyConfigToStrip(_ sc: StripController) {
        sc.strip.gap = config.gap
        sc.strip.defaultWidth = config.defaultWidth
        sc.strip.widthPresets = config.widthPresets
        sc.strip.snapPoints = config.snapPoints
        sc.animationEnabled = config.animationEnabled
        sc.gestureSnap = config.gestureSnap
        sc.widthSpringParams = config.widthSpringParams
        applyAnimationConfig(config, to: sc)
        sc.focusIndicator.reloadConfig(config.focusIndicator)
        sc.focusIndicator.springParams = config.widthSpringParams
        sc.frameLoop = frameLoop
        // Inherit the current pause state. A display hot-plug / rearrangement
        // while paused creates a fresh StripController here (via reconcile) or a
        // fallback (via ensureFallbackStrip); without this it would default to
        // isPaused=false, adopt windows, and re-show the focus indicator that
        // togglePause hid — the exact regression the flag exists to prevent.
        sc.isPaused = isPaused
    }

    /// Migrate windows from other strips whose current frame center lands inside
    /// the newly-added display's working area.
    private func rehomeWindows(onto targetSC: StripController, newGroupID: GroupID) {
        let newWA = targetSC.strip.workingArea
        var migrated = 0
        for (otherGID, otherSC) in stripControllers where otherGID != newGroupID {
            let candidates = otherSC.windowMap.map { ($0.key, $0.value) }
            for (tileID, window) in candidates {
                guard case .success(let frame) = window.getFrame() else { continue }
                let center = CGPoint(x: frame.midX, y: frame.midY)
                guard newWA.contains(center) else { continue }
                guard let app = tracker.apps[window.pid] else { continue }
                otherSC.removeWindow(tileID: tileID)
                targetSC.addWindow(window, app: app)
                migrated += 1
            }
        }
        if migrated > 0 {
            print("[WM] add: migrated \(migrated) windows onto group \(newGroupID)")
            fflush(stdout)
        }
    }

    /// Re-home every window on a dying strip to a surviving strip chosen by
    /// frame position (macOS has already reassigned frames to live displays).
    private func rehomeWindowsOff(dyingSC: StripController) {
        let survivors = stripControllers.filter { $0.value !== dyingSC }
        guard !survivors.isEmpty else { return }
        let entries = dyingSC.windowMap.map { ($0.key, $0.value) }
        var migrated = 0
        for (tileID, window) in entries {
            guard let app = tracker.apps[window.pid] else {
                dyingSC.removeWindow(tileID: tileID)
                continue
            }
            let targetSC = surviving(for: window, among: survivors) ?? survivors.values.first!
            dyingSC.removeWindow(tileID: tileID)
            targetSC.addWindow(window, app: app)
            migrated += 1
        }
        if migrated > 0 {
            print("[WM] remove: migrated \(migrated) windows off dying strip")
            fflush(stdout)
        }
    }

    /// Pick a surviving strip whose working area contains the window's center.
    private func surviving(
        for window: AXWindow,
        among survivors: [GroupID: StripController]
    ) -> StripController? {
        guard case .success(let frame) = window.getFrame() else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        for (_, sc) in survivors where sc.strip.workingArea.contains(center) {
            return sc
        }
        return nil
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let reelShutdown = Notification.Name("reelShutdown")
}
