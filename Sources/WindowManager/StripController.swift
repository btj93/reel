import AppKit
import CoreGraphics
import Foundation
import Core
import Platform

/// Bridges the Core Strip model to real AX window positioning.
/// Has two modes: instant (Phase 1) and animated (Phase 2).
public final class StripController: @unchecked Sendable {
    /// The current strip state.
    public var strip: Strip

    /// Per-app observers for dispatching AX calls.
    private var apps: [pid_t: AXApp] = [:]

    /// Tracked AXWindow instances by TileID.
    public private(set) var windowMap: [TileID: AXWindow] = [:]

    /// Last committed positions (for diffing).
    public private(set) var lastCommittedFrames: [TileID: CGRect] = [:]

    /// Tile IDs that need retry because a previous async AX dispatch failed.
    private var dirtyTileIDs: Set<TileID> = []

    /// Whether animation is enabled (Phase 2 toggle).
    public var animationEnabled: Bool = false

    /// Whether trackpad gestures snap to columns after flick.
    public var gestureSnap: Bool = true

    /// Spring parameters for width animation (from config, reuses scroll spring values).
    public var widthSpringParams: SpringParams = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)

    /// True while a gesture-initiated momentum animation is in flight.
    /// Used to defer focus changes until the animation settles.
    private var gestureAnimating: Bool = false

    /// Timestamp when gesture momentum settled — used to suppress AX focus echoes
    /// that arrive after the settle re-anchors activeColumnIndex.
    private var gestureSettleTime: Double = 0

    /// Saved strip states per Space, keyed by a fingerprint of on-screen window IDs.
    private var savedSpaces: [Set<UInt32>: SavedStripState] = [:]

    /// Debug-introspection: fingerprints of spaces whose state this controller
    /// currently has stashed (does NOT include the live current space).
    public var savedSpaceFingerprints: [Set<UInt32>] {
        Array(savedSpaces.keys)
    }

    /// Debug-introspection: the column list + window titles for a stashed space.
    /// Returns nil if the fingerprint isn't stashed.
    public func savedSpaceSnapshot(for fingerprint: Set<UInt32>) -> [(tileID: TileID, windowID: UInt32, bundleID: String?, title: String?)]? {
        guard let state = savedSpaces[fingerprint] else { return nil }
        var out: [(TileID, UInt32, String?, String?)] = []
        for col in state.columns {
            for tile in col.tiles {
                guard let w = state.windowMap[tile] else { continue }
                let bundle = state.apps[w.pid]?.bundleIdentifier
                out.append((tile, w.windowID, bundle, w.getTitle()))
            }
        }
        return out
    }

    /// Debug-introspection: returns the stashed columns together with their
    /// AXWindow references and per-column metadata so callers can query live AX
    /// frames for windows that belong to another Space.
    public func savedSpaceDetail(for fingerprint: Set<UInt32>) -> [(tileID: TileID, window: AXWindow, bundleID: String?, columnWidth: ColumnWidth, isFullWidth: Bool)]? {
        guard let state = savedSpaces[fingerprint] else { return nil }
        var out: [(TileID, AXWindow, String?, ColumnWidth, Bool)] = []
        for col in state.columns {
            for tile in col.tiles {
                guard let w = state.windowMap[tile] else { continue }
                let bundle = state.apps[w.pid]?.bundleIdentifier
                out.append((tile, w, bundle, col.width, col.isFullWidth))
            }
        }
        return out
    }

    /// The fingerprint of the current Space.
    public internal(set) var currentSpaceFingerprint: Set<UInt32> = []

    /// The user's intended active tile. Updated by hotkeys, addWindow, space restore,
    /// and external window focus (clicks). Used by saveCurrentSpace to persist focus.
    public var userActiveTileID: TileID?

    /// Timestamp of the last external (AX-driven) userActiveTileID update.
    /// saveCurrentSpace ignores updates within 300ms — they may be macOS
    /// space-transition artifacts rather than genuine user clicks.
    public var userActiveTileIDTime: Double = 0

    /// The confirmed userActiveTileID — not affected by recent external focus changes.
    /// Falls back to userActiveTileID if the external update is old enough.
    public var confirmedUserActiveTileID: TileID? {
        if TimeUtil.now() - userActiveTileIDTime < 0.3 {
            // Recent external focus — might be a space-transition artifact.
            // Return the previous confirmed value (set by hotkeys/addWindow/restore).
            return _confirmedUserActiveTileID
        }
        return userActiveTileID
    }
    internal var _confirmedUserActiveTileID: TileID?

    /// Promote an *external* focus (tile click, kAXFocusedWindowChanged, dock /
    /// Cmd+Tab activation) to the CONFIRMED active tile.
    ///
    /// Why this exists: `confirmedUserActiveTileID` distrusts any external focus
    /// younger than 300ms because macOS fires a focus event just BEFORE it
    /// delivers activeSpaceDidChange (commit 6ac3b1a), and that event can name a
    /// destination-Space window. But the fallback it uses, `_confirmedUserActiveTileID`,
    /// was written only by hotkey nav / addWindow / space restore — never by any
    /// click or trackpad path. For a user who navigates by clicking, it stayed
    /// pinned to the LAST-ADOPTED column (addWindow below) for as long as the
    /// Space lived, so `saveCurrentSpace` persisted that arbitrary column as the
    /// active one and the next return to the Space focused the wrong window.
    ///
    /// Call this only once an external focus has survived the debounce that a
    /// Space change would have cancelled — at that point it is genuine user
    /// intent, not a transition artifact. The 300ms distrust window is unchanged;
    /// what changes is that its fallback is now at most one real focus old
    /// instead of arbitrarily stale.
    public func confirmUserActive(tileID: TileID) {
        userActiveTileID = tileID
        _confirmedUserActiveTileID = tileID
    }

    /// Timestamp of the last layout application. Used to suppress echo AX events.
    public private(set) var lastLayoutTime: Double = 0

    /// How long to ignore AX echo events after a layout (150ms).
    public static let echoSuppressionInterval: Double = 0.15

    /// Timestamp of the last space switch. Used to suppress macOS-initiated
    /// focus changes that arrive after echo suppression expires.
    private var lastSpaceSwitchTime: Double = 0

    /// How long to ignore focus events after a space switch (300ms).
    /// macOS space-switch animations take ~250ms; focus notifications for the
    /// previously-frontmost app arrive during or just after. 300ms gives margin.
    public static let spaceSwitchFocusSuppressionInterval: Double = 0.3

    /// Cached primary screen height for Y-coordinate flipping (avoids NSScreen.main at 120Hz).
    public var primaryScreenHeight: CGFloat

    /// Focus indicator overlay.
    public let focusIndicator: FocusIndicator

    /// Latch: true once scroll+width have settled, reset on new animation.
    private var scrollWidthSettled: Bool = false

    /// Last tile we called AXWindow.raise() on — prevents 120Hz AX spam in raise style.
    private var lastRaisedTileID: TileID?

    /// Last tile the indicator tracked — detects focus changes for flash trigger.
    private var lastIndicatorTileID: TileID?

    /// Debounced recenter after user resize settles.
    private var resizeRecenterWork: DispatchWorkItem?

    /// Frame loop for animated scrolling (nil until Phase 2 is wired).
    public var frameLoop: FrameLoop?

    /// True while management is paused (mirrors `WindowManager.isPaused`).
    /// `WindowManager.togglePause` does a one-shot `focusIndicator.hide()`, but the
    /// frame loop and gesture/title-bar callbacks aren't pause-aware and can re-enter
    /// `updateFocusIndicator` (e.g. an `fn`+trackpad pan), re-showing the overlay.
    /// Gating the indicator on this flag keeps the pause-time hide durable.
    ///
    /// On the false→true edge we also cancel the debounced recenter and freeze any
    /// in-flight scroll/width/raise animation at its current value: a pause landing
    /// mid-animation must not later fire `applyLayout()` via the recenter work item,
    /// nor have `resume()` replay a stale spring against the user's windows once
    /// management resumes. `applyLayout`/`handleFrameTick` are additionally gated on
    /// this flag as backstops.
    public var isPaused: Bool = false {
        didSet {
            guard isPaused, !oldValue else { return }
            // Cancel the debounced recenter so it can't fire applyLayout() during pause.
            resizeRecenterWork?.cancel()
            resizeRecenterWork = nil
            // Freeze in-flight animations to their current value.
            let time = TimeUtil.now()
            strip.viewOffset = .static(strip.viewOffset.current(at: time))
            for i in strip.columnData.indices {
                if strip.columnData[i].widthAnimation != nil {
                    // cachedWidth write must nil out the width spring (invariant).
                    strip.columnData[i].cachedWidth = strip.columnData[i].currentWidth(at: time)
                    strip.columnData[i].widthAnimation = nil
                }
                if strip.columnData[i].raiseAnimation != nil {
                    strip.columnData[i].cachedRaiseTarget = strip.columnData[i].currentRaiseOffset(at: time)
                    strip.columnData[i].raiseAnimation = nil
                }
            }
        }
    }

    public init(workingArea: CGRect, primaryScreenHeight: CGFloat) {
        self.strip = Strip(workingArea: workingArea)
        self.primaryScreenHeight = primaryScreenHeight
        self.focusIndicator = FocusIndicator()
    }

    /// True when all animations (scroll, width, focus indicator) have settled.
    public var isFullySettled: Bool {
        let time = TimeUtil.now()
        let scrollSettled = strip.viewOffset.isSettled(at: time)
        let widthSettled = !strip.columnData.contains(where: { $0.widthAnimation != nil })
        let raiseSettled = !strip.columnData.contains(where: { $0.raiseAnimation != nil })
        return scrollSettled && widthSettled && raiseSettled && !focusIndicator.isAnimating
    }

    // MARK: - Window Registration

    /// If true, suppress layout until `finishBatch()` is called.
    private var isBatching: Bool = false

    /// Begin a batch of window additions (suppresses layout until `finishBatch`).
    public func beginBatch() { isBatching = true }

    /// End a batch and apply layout once.
    public func finishBatch() {
        isBatching = false
        applyLayout()
    }

    /// Register a window and add it to the strip.
    public func addWindow(_ window: AXWindow, app: AXApp) {
        // Prevent duplicate columns for the same tile.
        if windowMap[window.tileID] != nil {
            print("[Strip] addWindow SKIP (duplicate): tileID=\(window.tileID.rawValue)")
            fflush(stdout)
            return
        }
        // getTitle() is a synchronous AX round-trip; keep it out of release builds
        // (finding #33) so window adoption never pays for-logging AX latency.
        #if DEBUG
        print("[Strip] addWindow: tileID=\(window.tileID.rawValue) pid=\(window.pid) app=\(app.bundleIdentifier ?? "?") title=\(logTitle(window.getTitle()))")
        #else
        print("[Strip] addWindow: tileID=\(window.tileID.rawValue) pid=\(window.pid) app=\(app.bundleIdentifier ?? "?")")
        #endif
        fflush(stdout)
        windowMap[window.tileID] = window
        apps[window.pid] = app

        // Get current size to use as initial column width, clamped to working area
        let currentFrame = window.getFrame()
        let width: ColumnWidth
        if case .success(let frame) = currentFrame {
            let clampedWidth = min(Double(frame.width), strip.workingArea.width)
            width = .fixed(clampedWidth)
        } else {
            width = strip.defaultWidth
        }

        let column = Column(tiles: [window.tileID], width: width)
        strip.insertColumn(column, at: TimeUtil.now())
        userActiveTileID = strip.activeColumn?.activeTile
        _confirmedUserActiveTileID = userActiveTileID

        if !isBatching {
            applyLayout()
        }

    }

    /// Add a window at a specific position with saved column properties from snapshot restore.
    /// When restoredPosition is non-nil, inserts at the saved slot with saved width.
    /// When nil, falls back to default behavior.
    public func addWindow(_ window: AXWindow, app: AXApp, restoredPosition: RestoredSlot?) {
        guard let restored = restoredPosition else {
            addWindow(window, app: app)
            return
        }

        // Prevent duplicate columns for the same tile.
        if windowMap[window.tileID] != nil {
            print("[Strip] addWindow (restored) SKIP (duplicate): tileID=\(window.tileID.rawValue)")
            fflush(stdout)
            return
        }

        #if DEBUG
        print("[Strip] addWindow (restored): tileID=\(window.tileID.rawValue) pid=\(window.pid) at index=\(restored.slotIndex) width=\(restored.width)")
        fflush(stdout)
        #endif
        windowMap[window.tileID] = window
        apps[window.pid] = app

        let insertIndex = max(0, min(restored.slotIndex, strip.columns.count))

        // Normalize width: never restore .auto
        let width: ColumnWidth
        switch restored.width {
        case .auto:
            let region = strip.regionForColumn(insertIndex, at: TimeUtil.now())
            width = .fixed(restored.width.resolve(workingAreaWidth: Double(region.rect.width), gap: strip.gap))
        default:
            width = restored.width
        }

        let column = Column(tiles: [window.tileID], width: width,
                            presetIndex: restored.presetIndex, isFullWidth: restored.isFullWidth)
        strip.insertColumn(column, at: TimeUtil.now(), atIndex: insertIndex)

        // Belt-and-suspenders: a stale `lastCommittedFrames` entry (e.g., from
        // a prior window that reused this CGWindowID, or from before the strip
        // was cleared) would let applyLayout skip the new setFrame dispatch if
        // the target happened to match. Force the next layout pass to re-dispatch.
        lastCommittedFrames.removeValue(forKey: window.tileID)

        if !isBatching {
            // Pre-position the new window immediately before the full layout pass.
            // This eliminates the flicker where the window briefly appears at its
            // native/app-default position before snapping to the strip position.
            // Skip while paused — this is a direct setFrame on the reconcile →
            // addWindow path and must not move the user's window; applyLayout()
            // (also pause-guarded) will position it on resume.
            if !isPaused {
                let frames = computeTargetFrames(strip: strip, time: TimeUtil.now(), raiseHeight: raiseHeight)
                if let target = frames.first(where: { $0.tileID == window.tileID }) {
                    _ = window.setFrame(target.frame)
                    lastCommittedFrames[window.tileID] = target.frame
                }
            }
            applyLayout()
        }

    }

    /// Remove a window from the strip.
    public func removeWindow(tileID: TileID) {

        if let colIndex = strip.columns.firstIndex(where: { $0.tiles.contains(tileID) }) {
            strip.removeColumn(at: colIndex, at: TimeUtil.now())
        }
        windowMap.removeValue(forKey: tileID)
        lastCommittedFrames.removeValue(forKey: tileID)
        dirtyTileIDs.remove(tileID)
        // Revoke any queued write: this tile is leaving, so nothing will supersede
        // the stale target already baked into the pending closure.
        invalidatePendingWrite(tileID: tileID)
        // Also drop this window from any stashed Space snapshot so it can't pin
        // a dead AXWindow/AXApp there (finding #22).
        pruneSavedSpaces(removedTileID: tileID)
        applyLayout()
    }

    /// Clear all committed frame state, forcing the next applyLayout to reposition everything.
    public func clearCommittedFrames() {
        lastCommittedFrames.removeAll()
    }

    /// Reset the strip entirely (used when switching Spaces).
    /// Keeps the working area and config, clears all columns and window mappings.
    public func rebuildStrip() {
        strip.columns.removeAll()
        strip.columnData.removeAll()
        strip.snapIndices.removeAll()
        strip.activeColumnIndex = 0
        strip.viewOffset = .static(0)
        windowMap.removeAll()
        apps.removeAll()
        lastCommittedFrames.removeAll()
        focusIndicator.hide()

        lastRaisedTileID = nil
        lastIndicatorTileID = nil
    }

    // MARK: - Navigation

    public func focusLeft() {
        let time = TimeUtil.now()
        let oldActive = strip.activeColumnIndex
        if animationEnabled {
            if let _ = strip.navigateLeft(at: time) {
                startRaiseAnimations(oldColumn: oldActive, newColumn: strip.activeColumnIndex, at: time)
                scrollWidthSettled = false
                frameLoop?.resume()
            }
        } else {
            strip.navigateLeftInstant(at: time)
            startRaiseAnimations(oldColumn: oldActive, newColumn: strip.activeColumnIndex, at: time)
            applyLayout()
        }
        userActiveTileID = strip.activeColumn?.activeTile
        _confirmedUserActiveTileID = userActiveTileID
        focusActiveWindow()

    }

    public func focusRight() {
        let time = TimeUtil.now()
        let oldActive = strip.activeColumnIndex
        if animationEnabled {
            if let _ = strip.navigateRight(at: time) {
                startRaiseAnimations(oldColumn: oldActive, newColumn: strip.activeColumnIndex, at: time)
                scrollWidthSettled = false
                frameLoop?.resume()
            }
        } else {
            strip.navigateRightInstant(at: time)
            startRaiseAnimations(oldColumn: oldActive, newColumn: strip.activeColumnIndex, at: time)
            applyLayout()
        }
        userActiveTileID = strip.activeColumn?.activeTile
        _confirmedUserActiveTileID = userActiveTileID
        focusActiveWindow()

    }

    // MARK: - Trackpad Focus (velocity-aware)

    package func focusLeftAnimated(velocity: Double) {
        let time = TimeUtil.now()
        let oldActive = strip.activeColumnIndex
        if animationEnabled {
            let clampedVelocity = max(-5000, min(5000, velocity))
            if let _ = strip.navigateLeft(at: time, velocity: clampedVelocity) {
                startRaiseAnimations(oldColumn: oldActive, newColumn: strip.activeColumnIndex, at: time)
                scrollWidthSettled = false
                frameLoop?.resume()
            }
        } else {
            strip.navigateLeftInstant(at: time)
            startRaiseAnimations(oldColumn: oldActive, newColumn: strip.activeColumnIndex, at: time)
            applyLayout()
        }
        userActiveTileID = strip.activeColumn?.activeTile
        _confirmedUserActiveTileID = userActiveTileID
        focusActiveWindow()
    }

    package func focusRightAnimated(velocity: Double) {
        let time = TimeUtil.now()
        let oldActive = strip.activeColumnIndex
        if animationEnabled {
            let clampedVelocity = max(-5000, min(5000, velocity))
            if let _ = strip.navigateRight(at: time, velocity: clampedVelocity) {
                startRaiseAnimations(oldColumn: oldActive, newColumn: strip.activeColumnIndex, at: time)
                scrollWidthSettled = false
                frameLoop?.resume()
            }
        } else {
            strip.navigateRightInstant(at: time)
            startRaiseAnimations(oldColumn: oldActive, newColumn: strip.activeColumnIndex, at: time)
            applyLayout()
        }
        userActiveTileID = strip.activeColumn?.activeTile
        _confirmedUserActiveTileID = userActiveTileID
        focusActiveWindow()
    }

    public func moveColumnLeft() {
        strip.moveColumnLeft(at: TimeUtil.now())
        applyLayout()
        focusActiveWindow()
    }

    public func moveColumnRight() {
        strip.moveColumnRight(at: TimeUtil.now())
        applyLayout()
        focusActiveWindow()
    }

    public func cycleWidthPreset() {
        // Core no-ops on an empty strip, but the animated branch below still reads
        // columnData[activeColumnIndex] — an index-out-of-range trap reachable from
        // the cycle-width hotkey or `reel-msg cycle-width-preset` with no windows.
        guard !strip.columns.isEmpty else { return }
        let time = TimeUtil.now()
        if animationEnabled {
            strip.cycleWidthPreset(at: time, params: widthSpringParams)
            let targetWidth = strip.columnData[strip.activeColumnIndex].cachedWidth
            let _ = strip.recenterActiveColumnAnimated(at: time, columnWidth: targetWidth)
            #if DEBUG
            print("[Strip] cycleWidth animated: col=\(strip.activeColumnIndex) targetWidth=\(targetWidth) presetIndex=\(strip.columns[strip.activeColumnIndex].presetIndex ?? -1)")
            fflush(stdout)
            #endif
            // Apply immediately to start resizing and refresh echo suppression
            applyLayout()
            scrollWidthSettled = false
            frameLoop?.resume()
        } else {
            strip.cycleWidthPreset(at: time, params: nil)
            strip.recenterActiveColumn(at: time)
            applyLayout()
        }
    }

    /// `column` targets a specific column (the pill menu's clicked one); nil means
    /// the active column, as the hotkey path expects.
    package func setWidthPreset(index: Int, column: Int? = nil) {
        // See cycleWidthPreset: the animated branch indexes columnData directly.
        guard !strip.columns.isEmpty else { return }
        let time = TimeUtil.now()
        strip.setWidthPreset(
            index: index,
            at: time,
            params: animationEnabled ? widthSpringParams : nil,
            column: column
        )
        let target = column ?? strip.activeColumnIndex
        guard target == strip.activeColumnIndex else {
            // A non-active column changed width. Column X is DERIVED from cumulative
            // widths, so a left-side resize shifts the active column's strip-space X
            // and the focused window would visibly slide. Re-pin it. Safe to call
            // unconditionally: recenterActiveColumn computes an absolute snap target,
            // so it is idempotent and cannot double-shift viewOffset.
            strip.recenterActiveColumn(at: time)
            applyLayout()
            return
        }
        if animationEnabled {
            let targetWidth = strip.columnData[strip.activeColumnIndex].cachedWidth
            let _ = strip.recenterActiveColumnAnimated(at: time, columnWidth: targetWidth)
            applyLayout()
            scrollWidthSettled = false
            frameLoop?.resume()
        } else {
            strip.recenterActiveColumn(at: time)
            applyLayout()
        }
    }

    /// `column` targets a specific column; nil means the active column.
    public func toggleFullWidth(column: Int? = nil) {
        let time = TimeUtil.now()
        strip.toggleFullWidth(at: time, column: column)
        let target = column ?? strip.activeColumnIndex
        guard target == strip.activeColumnIndex else {
            // See setWidthPreset: re-pin the active column against the derived-X shift.
            strip.recenterActiveColumn(at: time)
            applyLayout()
            return
        }
        if animationEnabled {
            // Apply layout immediately so the window resizes right away,
            // then animate the scroll to recenter the column.
            applyLayout()
            if let _ = strip.recenterActiveColumnAnimated(at: time) {
                scrollWidthSettled = false
                frameLoop?.resume()
            }
        } else {
            strip.recenterActiveColumn(at: time)
            applyLayout()
        }
    }

    /// Close the focused window via its AX close button.
    public func closeActiveWindow() {
        guard let activeTile = strip.activeColumn?.activeTile,
              let window = windowMap[activeTile] else { return }
        let _ = window.close()
        // The window destruction will be detected by health check or AX observer,
        // which will remove it from the strip.
    }

    /// Toggle the focused window between tiled (on strip) and floating (free).
    /// Returns the window that was toggled, or nil if no active window.
    public func toggleFloating() -> AXWindow? {
        guard let activeTile = strip.activeColumn?.activeTile,
              let window = windowMap[activeTile] else { return nil }

        removeWindow(tileID: activeTile)
        return window
    }

    /// Float a specific tile (the pill menu's clicked one) rather than the active
    /// one. Tile→float direction only: the menu is built from a tiled column, so it
    /// can never target an already-floating window.
    public func floatWindow(tileID: TileID) -> AXWindow? {
        guard let window = windowMap[tileID] else { return nil }
        removeWindow(tileID: tileID)
        return window
    }

    /// Re-add a floating window back to the strip at a restored position.
    public func unfloatWindow(_ window: AXWindow, app: AXApp, restoredPosition: RestoredSlot? = nil) {
        addWindow(window, app: app, restoredPosition: restoredPosition)
    }

    // MARK: - Pill Bar Menu

    /// Build pill items for the active column's current state.
    package func buildPillItems(for columnIndex: Int) -> [PillItem] {
        guard columnIndex >= 0, columnIndex < strip.columns.count else { return [] }
        let col = strip.columns[columnIndex]
        let isFloating = false  // floating windows are not in the strip

        var pills: [PillItem] = []
        for (i, preset) in strip.widthPresets.enumerated() {
            let label: String
            switch preset {
            case .proportion(let p):
                if p <= 0.34 { label = "Third" }
                else if p <= 0.51 { label = "Half" }
                else if p <= 0.68 { label = "Two-Thirds" }
                else { label = "\(Int(p * 100))%" }
            case .fixed(let w): label = "\(Int(w))px"
            case .auto: label = "Auto"
            }
            pills.append(PillItem(
                label: label,
                isActive: col.presetIndex == i,
                isEnabled: !isFloating
            ))
        }
        // Full width pill
        pills.append(PillItem(
            label: "Full",
            isActive: col.isFullWidth,
            isEnabled: !isFloating
        ))
        // Float toggle
        pills.append(PillItem(
            label: "Float",
            isActive: false,
            isEnabled: true
        ))
        return pills
    }

    /// Dispatch a pill bar action. Returns the action for WindowManager to handle (for float toggle).
    package enum PillAction {
        case widthPreset(Int)
        case fullWidth
        case toggleFloat
    }

    package func pillAction(for index: Int) -> PillAction? {
        let presetCount = strip.widthPresets.count
        if index < presetCount {
            return .widthPreset(index)
        } else if index == presetCount {
            return .fullWidth
        } else if index == presetCount + 1 {
            return .toggleFloat
        }
        return nil
    }

    // MARK: - User Move/Resize Handling

    /// Called when a user drags a window. Snaps it back to its strip position.
    public func handleUserMove(windowID: CGWindowID) {
        let tileID = TileID(windowID)
        guard windowMap[tileID] != nil,
              let colIndex = strip.columns.firstIndex(where: { $0.tiles.contains(tileID) })
        else { return }

        // If the user moved the active column, re-compute its snap target so
        // the column centers on its owning region using the CURRENT cachedWidth.
        // A prior snap may have been computed against a stale width if the app
        // adjusted its own size after the initial column insertion.
        if colIndex == strip.activeColumnIndex {
            let time = TimeUtil.now()
            strip.viewOffset = .static(strip.snapTargetForActive(at: time))
        }

        // Clear the committed frame so applyLayout will reposition it
        lastCommittedFrames.removeValue(forKey: tileID)
        applyLayout()
    }

    /// Called when a user manually resizes a window. Updates the column width to match,
    /// and enforces that the window cannot be wider/taller than the working area.
    public func handleUserResize(windowID: CGWindowID) {
        let tileID = TileID(windowID)
        guard let window = windowMap[tileID],
              let colIndex = strip.columns.firstIndex(where: { $0.tiles.contains(tileID) }) else {
            print("[Strip] handleUserResize SKIP: window not found wid=\(windowID)")
            fflush(stdout)
            return
        }

        guard case .success(let currentFrame) = window.getFrame() else {
            print("[Strip] handleUserResize SKIP: getFrame failed wid=\(windowID)")
            fflush(stdout)
            return
        }

        let maxWidth = strip.workingArea.width
        let maxHeight = strip.workingArea.height
        var needsEnforce = false

        var newWidth = Double(currentFrame.width)
        var newHeight = Double(currentFrame.height)

        // Clamp to working area
        if newWidth > maxWidth {
            newWidth = maxWidth
            needsEnforce = true
        }
        if newHeight > maxHeight {
            newHeight = maxHeight
            needsEnforce = true
        }

        // If the window exceeds bounds, resize it back immediately
        if needsEnforce {
            let enforcedFrame = CGRect(
                x: currentFrame.minX,
                y: strip.workingArea.minY,
                width: newWidth,
                height: newHeight
            )
            let _ = window.setFrame(enforcedFrame)
        }

        let oldWidth = strip.columnData[colIndex].cachedWidth

        // Only update strip model if width changed significantly
        guard abs(newWidth - oldWidth) > 2 else {
            print("[Strip] handleUserResize SKIP: delta too small wid=\(windowID) new=\(newWidth) old=\(oldWidth) delta=\(abs(newWidth - oldWidth))")
            fflush(stdout)
            return
        }

        // User drag-resize overrides any active width preset.
        // The width threshold above already filters late AX echo notifications
        // (by the time they arrive, getFrame() returns the preset width → delta ≈ 0).
        strip.columns[colIndex].presetIndex = nil

        #if DEBUG
        print("[Strip] handleUserResize wid=\(windowID) oldWidth=\(oldWidth) newWidth=\(newWidth)")
        fflush(stdout)
        #endif

        let widthDelta = newWidth - oldWidth

        // Detect left-edge resize: if the right edge stayed roughly in place
        // while the left edge moved, the user is dragging from the left side.
        // Adjust the view offset so the right edge stays anchored on screen.
        // Only apply when lastFrame is on-screen — far-zone sliver positions
        // (written during animation ticks) would produce bogus deltas.
        if let lastFrame = lastCommittedFrames[tileID],
           lastFrame.minX >= strip.workingArea.minX - 50,
           lastFrame.maxX <= strip.workingArea.maxX + 50 {
            let rightEdgeDelta = abs(Double(currentFrame.maxX) - Double(lastFrame.maxX))
            let leftEdgeDelta = abs(Double(currentFrame.minX) - Double(lastFrame.minX))
            if leftEdgeDelta > rightEdgeDelta && leftEdgeDelta > 2 {
                let currentOffset = strip.viewOffset.current(at: TimeUtil.now())
                strip.viewOffset = .static(currentOffset + widthDelta)
            }
        }

        strip.columns[colIndex].width = .fixed(newWidth)
        strip.columnData[colIndex].widthAnimation = nil
        strip.columnData[colIndex].cachedWidth = newWidth

        // Apply layout immediately during drag
        applyLayout()

        // Debounce recenter: wait for drag to settle before animating back to center
        resizeRecenterWork?.cancel()
        let colWidth = newWidth
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let time = TimeUtil.now()
            let curOffset = self.strip.viewOffset.current(at: time)
            print("[Strip] recenter fired: colWidth=\(colWidth) viewOffset=\(curOffset) cols=\(self.strip.columns.count) anim=\(self.animationEnabled)")
            fflush(stdout)
            if self.animationEnabled {
                if let anim = self.strip.recenterActiveColumnAnimated(at: time) {
                    print("[Strip] recenter: animation created from=\(anim.from) to=\(anim.to)")
                    fflush(stdout)
                    self.scrollWidthSettled = false
                    self.frameLoop?.resume()
                } else {
                    print("[Strip] recenter: no animation needed, applying layout")
                    fflush(stdout)
                    // Already near target — viewOffset was snapped but layout
                    // still needs applying so the window and indicator update.
                    self.applyLayout()
                }
            } else {
                self.strip.recenterActiveColumn(at: time)
                self.applyLayout()
            }
        }
        resizeRecenterWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: - Scroll to Window

    /// Scroll strategy used by `scrollToWindow`.
    public enum ScrollMode: Sendable {
        /// Center the target column on its default snap point (snapIndex reset).
        /// Used by keyboard/IPC focus and pure space-restore (no recent dock activation).
        case center
        /// Only scroll if the target column isn't fully visible, otherwise no-op.
        /// When scrolling, slide to the first unreached snap milestone in travel direction.
        /// Used by mouse-driven focus (window click, dock click, Cmd+Tab) and dock-driven
        /// space restore.
        case incrementalSnap
    }

    /// Scroll the strip to make a specific window visible.
    public func scrollToWindow(tileID: TileID, mode: ScrollMode = .center) {
        // Suppress external focus-triggered scrolls during gesture momentum and
        // shortly after settle — the re-anchor triggers AX focus events that
        // would snap the view away from where the gesture left it.
        if mode == .incrementalSnap {
            if gestureAnimating {
                #if DEBUG
                print("[Gesture] SUPPRESSED scrollToWindow (gestureAnimating) tileID=\(tileID.rawValue)")
                fflush(stdout)
                #endif
                return
            }
            let elapsed = TimeUtil.now() - gestureSettleTime
            if elapsed < 0.3 {
                #if DEBUG
                print("[Gesture] SUPPRESSED scrollToWindow (settle echo, \(String(format: "%.0f", elapsed * 1000))ms) tileID=\(tileID.rawValue)")
                fflush(stdout)
                #endif
                return
            }
        }
        guard let colIndex = strip.columns.firstIndex(where: { $0.tiles.contains(tileID) }) else { return }
        let window = windowMap[tileID]
        // getTitle() is a synchronous AX round-trip on the hot focus path; keep
        // it out of release builds (finding #33).
        #if DEBUG
        print("[Strip] scrollTo wid=\(window?.windowID ?? 0) tileID=\(tileID.rawValue) col=\(colIndex) mode=\(mode) app=\(window.flatMap { apps[$0.pid]?.bundleIdentifier } ?? "?") title=\(logTitle(window?.getTitle()))")
        #else
        print("[Strip] scrollTo wid=\(window?.windowID ?? 0) tileID=\(tileID.rawValue) col=\(colIndex) mode=\(mode) app=\(window.flatMap { apps[$0.pid]?.bundleIdentifier } ?? "?")")
        #endif
        fflush(stdout)

        let time = TimeUtil.now()
        // Clear any width animation on the target — snap offsets use current width,
        // stale springs would race our scroll.
        strip.columnData[colIndex].widthAnimation = nil

        switch mode {
        case .center:
            let oldActive = strip.activeColumnIndex
            strip.activeColumnIndex = colIndex
            startRaiseAnimations(oldColumn: oldActive, newColumn: colIndex, at: time)
            strip.snapIndices[colIndex] = strip.defaultSnapIndex

            // Region-aware: snapTarget centres the column in its OWNING display and
            // subtracts the region offset. computeSnapOffset against
            // workingArea.width used the whole merged span, so on a shared strip the
            // column landed in the seam between displays. snapIndices was just set
            // above and the width animation cleared, so this reads the same inputs.
            strip.viewOffset = .static(strip.snapTarget(forColumn: colIndex, at: time))
            applyLayout()

        case .incrementalSnap:
            let oldActive = strip.activeColumnIndex
            let result = strip.focusColumnIncremental(
                colIndex: colIndex,
                at: time,
                animated: animationEnabled
            )
            startRaiseAnimations(oldColumn: oldActive, newColumn: strip.activeColumnIndex, at: time)
            switch result {
            case .noChange:
                return
            case .anchorOnly:
                applyLayout()
            case .scrolledInstant:
                applyLayout()
            case .scrolledAnimated:
                scrollWidthSettled = false
                // Bump lastLayoutTime so the AX move/resize echoes from the
                // first animation frame (which arrives ~8ms from now via the
                // frame loop) are caught by isInEchoSuppression. The .center
                // and .scrolledInstant paths get this for free via applyLayout().
                // IMPORTANT: if applyLayout() ever acquires additional init
                // side effects beyond bumping lastLayoutTime, mirror them here
                // or extract a shared helper to keep the two paths in sync.
                lastLayoutTime = TimeUtil.now()
                frameLoop?.resume()
                // Don't call applyLayout — frame loop will tick within one frame.
            }
        }
    }

    // MARK: - AX Write Dispatch (injectable + coalesced)

    /// Off-main executor for a single AX write. The production default routes the
    /// work through the owning app's serial `writeQueue`, so all writes for one
    /// window are ordered and can never land out of sequence (finding #2). Tests
    /// override this to run inline for single-threaded, virtual-clock determinism.
    public var frameDispatch: @Sendable (AXApp, @Sendable @escaping () -> Void) -> Void =
        { app, work in app.writeQueue.async(execute: work) }

    /// Main-thread hop for dirty-tile retry bookkeeping (`dirtyTileIDs` is
    /// main-confined). Production default is `DispatchQueue.main.async`; tests run
    /// it inline.
    public var mainHop: @Sendable (@Sendable @escaping () -> Void) -> Void =
        { work in DispatchQueue.main.async(execute: work) }

    /// Latest undelivered write per tile. A newer frame supersedes an older one
    /// instead of queueing every 120Hz tick, decimating input to the app's real
    /// AX throughput and bounding queued work to one block per tile (finding #2).
    /// Guarded by `writeLock`.
    private var pendingWrites: [TileID: PendingWrite] = [:]
    /// Tiles with a drain block already in flight on their app's write queue.
    /// Guarded by `writeLock`.
    private var inFlightTiles: Set<TileID> = []
    private let writeLock = NSLock()
    /// Serial fallback for the (defensive) case where a tile's window has no
    /// tracked AXApp — preserves ordering without the concurrent global queue.
    private let fallbackWriteQueue = DispatchQueue(label: "reel.ax.write.fallback", qos: .userInteractive)

    /// Bumped whenever the controller loses ownership of a tile. A drain block
    /// stamped with an older value is discarded at dequeue. Guarded by `writeLock`.
    private var writeGeneration: [TileID: UInt64] = [:]

    private struct PendingWrite {
        let app: AXApp?
        let apply: @Sendable () -> AXResult<Void>
        let generation: UInt64
    }

    /// Debug-introspection for the test settle helper.
    package var debugDirtyCount: Int { dirtyTileIDs.count }

    /// Revoke any undelivered write for `tileID` and invalidate blocks already
    /// dispatched for it. Called when the controller loses ownership of a tile —
    /// removal, float, Space replacement — where no superseding write will ever
    /// arrive to overwrite the stale target baked into the queued closure.
    ///
    /// `inFlightTiles` is deliberately untouched: a dispatched block clears it once
    /// it finds nothing pending, and clearing it here would allow two concurrent
    /// drains for one tile.
    ///
    /// LIMIT: this cannot stop a block that has ALREADY dequeued, because
    /// `pending.apply()` runs outside `writeLock` (holding the lock across an AX
    /// call with a 100ms messaging timeout would stall the caller). Corrective
    /// writes must therefore be *queue-ordered* via `enqueueRestore`, not merely
    /// issued after invalidation.
    package func invalidatePendingWrite(tileID: TileID) {
        writeLock.lock()
        pendingWrites.removeValue(forKey: tileID)
        writeGeneration[tileID, default: 0] &+= 1
        writeLock.unlock()
    }

    /// Restore `tileID` to `frame` immediately, revoking any queued write first.
    ///
    /// Callers (pause, shutdown, the `recover` IPC command) mean "put this back
    /// NOW": the write must be complete before the operation is observable. An
    /// earlier version enqueued this onto the app's serial queue for guaranteed FIFO
    /// ordering, but that defers the write — at pause the restore then landed AFTER
    /// the caller had already been told the manager was paused, correcting a window
    /// a paused manager must leave alone. The smoke suite catches exactly that.
    ///
    /// So: revoke, then write inline. Revoking covers the realistic case (a write
    /// queued but not yet dequeued). A write already dequeued and mid-`apply()` can
    /// still land afterwards — inherent, since stopping it would mean holding
    /// `writeLock` across a 100ms AX call. Strictly better than the previous code,
    /// which revoked nothing.
    package func restoreFrame(tileID: TileID, frame: CGRect) {
        guard let window = windowMap[tileID] else { return }
        invalidatePendingWrite(tileID: tileID)
        _ = window.setFrame(frame)
        lastCommittedFrames[tileID] = frame
    }

    /// Enqueue an AX write for `tileID`, coalescing with any undelivered write for
    /// the same tile. At most one drain block per tile is ever in flight; a
    /// superseding frame just replaces the pending target (finding #2).
    private func enqueueWrite(tileID: TileID, app: AXApp?, apply: @escaping @Sendable () -> AXResult<Void>) {
        writeLock.lock()
        pendingWrites[tileID] = PendingWrite(
            app: app, apply: apply, generation: writeGeneration[tileID, default: 0])
        let alreadyInFlight = inFlightTiles.contains(tileID)
        if !alreadyInFlight { inFlightTiles.insert(tileID) }
        writeLock.unlock()
        // A drain block is already running for this tile; it will pick up the
        // target we just stored.
        guard !alreadyInFlight else { return }
        if let app = app {
            frameDispatch(app) { [weak self] in self?.drainWrites(tileID) }
        } else {
            fallbackWriteQueue.async { [weak self] in self?.drainWrites(tileID) }
        }
    }

    /// Drain coalesced writes for `tileID` on the owning app's serial write queue.
    /// Applies the latest pending target, then re-checks for a newer one that
    /// arrived while applying, until none remain — then clears the in-flight flag.
    private func drainWrites(_ tileID: TileID) {
        while true {
            writeLock.lock()
            guard let pending = pendingWrites.removeValue(forKey: tileID) else {
                inFlightTiles.remove(tileID)
                writeLock.unlock()
                return
            }
            // Discard a write whose tile changed ownership after it was enqueued.
            // Checked under the lock so an invalidation that lands before dequeue
            // is always honored.
            let isStale = pending.generation != writeGeneration[tileID, default: 0]
            writeLock.unlock()
            if isStale { continue }
            let result = pending.apply()
            if case .failure = result {
                mainHop { [weak self] in self?.dirtyTileIDs.insert(tileID) }
            }
        }
    }

    // MARK: - Layout Application

    private var raiseHeight: Double {
        focusIndicator.style == .raise ? Double(focusIndicator.raiseHeight) : 0
    }

    /// Start raise animations when focus changes between columns.
    /// Old active column: spring toward raiseHeight (fall to bottom).
    /// New active column: spring toward 0 (rise to ceiling).
    /// Reads the live offset via currentRaiseOffset so interrupted animations
    /// or intermediate positions animate smoothly without pops.
    /// Resumes the frame loop so the springs get ticked.
    private func startRaiseAnimations(oldColumn: Int, newColumn: Int, at time: Double) {
        let rh = raiseHeight
        guard rh > 0, oldColumn != newColumn else { return }

        // Old column falls to bottom
        if oldColumn >= 0, oldColumn < strip.columnData.count {
            if let existing = strip.columnData[oldColumn].raiseAnimation, !existing.isDone(at: time) {
                strip.columnData[oldColumn].raiseAnimation = existing.retargeted(to: rh, at: time)
            } else {
                let fromOld = strip.columnData[oldColumn].currentRaiseOffset(at: time)
                strip.columnData[oldColumn].raiseAnimation = SpringAnimation(from: fromOld, to: rh, startTime: time, params: widthSpringParams)
            }
            strip.columnData[oldColumn].cachedRaiseTarget = rh
        }

        // New column rises to ceiling
        if newColumn >= 0, newColumn < strip.columnData.count {
            if let existing = strip.columnData[newColumn].raiseAnimation, !existing.isDone(at: time) {
                strip.columnData[newColumn].raiseAnimation = existing.retargeted(to: 0, at: time)
            } else {
                let fromNew = strip.columnData[newColumn].currentRaiseOffset(at: time)
                strip.columnData[newColumn].raiseAnimation = SpringAnimation(from: fromNew, to: 0, startTime: time, params: widthSpringParams)
            }
            strip.columnData[newColumn].cachedRaiseTarget = 0
        }

        frameLoop?.resume()
    }

    /// Compute target frames and apply to real windows.
    /// This is the Phase 1 "instant" mode.
    public func applyLayout() {
        // Backstop: never dispatch AX writes while paused. reconcileDisplayTopology
        // stays pause-reachable, so a hot-plug while paused runs reconcile →
        // addWindow → applyLayout; this guard keeps it from moving the user's
        // windows. A resume triggers a fresh layout.
        guard !isPaused else { return }

        // Sync raise targets for columns without in-flight animations.
        // Handles startup, config reload, space restore, and new window insertion.
        let rh = raiseHeight
        if rh > 0 {
            for i in 0..<strip.columnData.count where strip.columnData[i].raiseAnimation == nil {
                strip.columnData[i].cachedRaiseTarget = (i == strip.activeColumnIndex) ? 0 : rh
            }
        }

        // Record timestamp so echo AX events can be suppressed
        let time = TimeUtil.now()
        lastLayoutTime = time

        let frames = computeTargetFrames(strip: strip, time: time, raiseHeight: raiseHeight)

        // Hot-path logging removed — fires at 120Hz during animation

        // Apply frames to real windows
        var applied = 0
        var skipped = 0
        var noWindow = 0
        for target in frames {
            guard let window = windowMap[target.tileID] else {
                noWindow += 1
                continue
            }

            // Dirty-ID bypass must precede framesEqual guard — otherwise
            // optimistically-written frames from failed dispatches are never retried
            let isDirty = dirtyTileIDs.contains(target.tileID)
            if !isDirty,
               let lastFrame = lastCommittedFrames[target.tileID],
               framesEqual(lastFrame, target.frame) {
                skipped += 1
                continue
            }
            dirtyTileIDs.remove(target.tileID)

            // Record optimistically — retry via dirtyTileIDs on failure
            lastCommittedFrames[target.tileID] = target.frame
            applied += 1

            let tileID = target.tileID
            let app = apps[window.pid]
            if target.isOffScreen {
                // Off-screen sliver/corner-hide: position-only, no cost tracking.
                let position = target.frame.origin
                enqueueWrite(tileID: tileID, app: app) { window.setPosition(position) }
            } else {
                let frame = target.frame
                if let app = app {
                    enqueueWrite(tileID: tileID, app: app) { app.dispatchSetFrame(window, frame: frame) }
                } else {
                    // Fallback: setFrame directly when app not in dict (defensive).
                    enqueueWrite(tileID: tileID, app: nil) { window.setFrame(frame) }
                }
            }
        }
        // Hot-path logging removed — fires at 120Hz during animation

        // Update focus indicator
        updateFocusIndicator(frames: frames)
    }

    /// Focus the active window (activate app + keyboard focus + raise).
    /// Only call this on explicit user navigation, NOT during startup/batch/relayout.
    public func focusActiveWindow() {
        guard let activeTile = strip.activeColumn?.activeTile,
              let window = windowMap[activeTile] else { return }
        // getTitle() is a synchronous AX round-trip on the hot focus path; keep
        // it out of release builds (finding #33).
        #if DEBUG
        print("[Strip] focus wid=\(window.windowID) tileID=\(activeTile.rawValue) col=\(strip.activeColumnIndex) app=\(apps[window.pid]?.bundleIdentifier ?? "?") title=\(logTitle(window.getTitle()))")
        #else
        print("[Strip] focus wid=\(window.windowID) tileID=\(activeTile.rawValue) col=\(strip.activeColumnIndex) app=\(apps[window.pid]?.bundleIdentifier ?? "?")")
        #endif
        fflush(stdout)
        window.focus()
    }

    // MARK: - Animation Frame Tick

    /// Called by FrameLoop every vsync frame during animation.
    public func handleFrameTick(time: Double) {
        // Backstop: WindowManager gates its onTick on pause, but harden against
        // any other caller. Animations are frozen on the pause edge, so there is
        // nothing to advance here anyway.
        guard !isPaused else { return }

        // Advance focus indicator animations first (unconditional)
        focusIndicator.tick(time: time)

        // Settle any completed width animations (single pass: settle + check)
        let widthSettled = !strip.settleWidthAnimations(at: time)
        let raiseSettled = !strip.settleRaiseAnimations(at: time)
        let scrollSettled = strip.viewOffset.isSettled(at: time)

        // Keep echo suppression armed for the full animation. We dispatch AX
        // writes every tick below; their echoes arrive with AX-observer latency
        // that can exceed the 150ms window if we only rely on the initial
        // applyLayout bump. Re-bumping each tick makes suppression self-sustaining
        // while the frame loop is active (it pauses on settle, so suppression
        // expires normally when we stop writing).
        //
        // Only re-arm while this strip is actually writing frames this tick.
        // WindowManager ticks EVERY strip whenever ANY strip or the focus
        // indicator is animating, so a fully-settled strip would otherwise keep
        // re-arming its echo window at 120Hz and swallow genuine user
        // move/resize events on THIS strip (finding #18). When everything is
        // settled the one-shot settle-latch applyLayout() below arms suppression
        // for its final write; subsequent settled ticks write nothing.
        if !(scrollSettled && widthSettled && raiseSettled) {
            lastLayoutTime = time
        }

        // Settle latch: once scroll+width settle, do one-shot work then hold until fully settled
        if scrollSettled && widthSettled {
            if !scrollWidthSettled {
                scrollWidthSettled = true

                let finalOffset = strip.viewOffset.current(at: time)

                // After gesture momentum settles, re-anchor focus to the cursor column.
                // viewPos = columnX(oldActive) + finalOffset — we preserve this while
                // switching activeColumnIndex, so there's no visual jump.
                if gestureAnimating {
                    gestureAnimating = false
                    gestureSettleTime = time
                    let viewPos = strip.columnX(at: strip.activeColumnIndex, time: time) + finalOffset
                    let oldActive = strip.activeColumnIndex
                    let newActive = columnUnderCursor(gestureOffset: finalOffset)
                    #if DEBUG
                    print("[Gesture] SETTLE oldActive=\(strip.activeColumnIndex) newActive=\(newActive) finalOffset=\(String(format: "%.1f", finalOffset)) adjustedOffset=\(String(format: "%.1f", viewPos - strip.columnX(at: newActive, time: time)))")
                    fflush(stdout)
                    #endif
                    strip.activeColumnIndex = newActive
                    startRaiseAnimations(oldColumn: oldActive, newColumn: newActive, at: time)
                    let adjustedOffset = viewPos - strip.columnX(at: newActive, time: time)
                    strip.viewOffset = .static(adjustedOffset)
                } else {
                    // Snap to the canonical target, not the spring's evaluated value.
                    // Spring epsilon (0.5) admits a small drift, and a previous animation
                    // could have been retargeted off-snap by rapid keypresses — locking in
                    // `finalOffset` would persist that drift.
                    strip.viewOffset = .static(strip.snapTargetForActive(at: time))
                }

                // One final layout with exact positions + full setFrame.
                // Don't clearCommittedFrames() — visible windows have committed entries,
                // so applyLayout()'s diff logic can skip unchanged windows.
                // Far-zone windows still have their last-visible position in
                // lastCommittedFrames, so applyLayout() will detect the change
                // and dispatch the off-screen move.
                applyLayout()
            }
            if raiseSettled {
                // Everything settled — only tick focus indicator if needed
                if focusIndicator.isAnimating {
                    let frames = computeTargetFrames(strip: strip, time: time, raiseHeight: raiseHeight)
                    updateFocusIndicator(frames: frames)
                }
                return
            }
            // Raise still animating — fall through to main animation loop below
        } else {
            scrollWidthSettled = false
        }

        // Compute frames with animation evaluated at this timestamp
        let frames = computeTargetFrames(strip: strip, time: time, raiseHeight: raiseHeight)

        // Dispatch position updates to per-app threads IN PARALLEL.
        // This prevents a slow Electron app from blocking a fast native app.
        for target in frames {
            guard let window = windowMap[target.tileID] else { continue }

            // Skip if position hasn't changed enough to matter.
            // During animation, use a larger threshold (2px) to reduce AX call volume.
            // Each AX call costs 0.5-5ms, so skipping sub-pixel changes saves significant time.
            if let lastFrame = lastCommittedFrames[target.tileID],
               abs(lastFrame.minX - target.frame.minX) < 2.0 &&
               abs(lastFrame.minY - target.frame.minY) < 2.0 &&
               abs(lastFrame.width - target.frame.width) < 2.0 &&
               abs(lastFrame.height - target.frame.height) < 2.0 {
                continue
            }

            // During animation: use setFrame for visible (width may be changing), skip far windows
            switch target.visibilityZone {
            case .visible, .nearBuffer:
                let tileID = target.tileID
                if let app = apps[window.pid] {
                    if widthSettled && raiseSettled {
                        // Width and raise done, only horizontal position changing — position-only is cheaper
                        let position = target.frame.origin
                        enqueueWrite(tileID: tileID, app: app) { app.dispatchSetPosition(window, position: position) }
                    } else {
                        // Width still animating — need full setFrame to resize
                        let frame = target.frame
                        enqueueWrite(tileID: tileID, app: app) { app.dispatchSetFrame(window, frame: frame) }
                    }
                }
                lastCommittedFrames[target.tileID] = target.frame
            case .far:
                // Don't write — let settle applyLayout() detect the position change
                // from last-visible to off-screen and dispatch the move
                break
            }
        }

        // Update focus indicator position
        updateFocusIndicator(frames: frames)
    }

    // MARK: - Gesture Handling

    /// Begin a trackpad gesture scroll.
    public func handleGestureBegin(time: Double) {
        let current = strip.viewOffset.current(at: time)
        #if DEBUG
        print("[Gesture] BEGIN offset=\(String(format: "%.1f", current)) snap=\(gestureSnap)")
        fflush(stdout)
        #endif
        strip.viewOffset = .gesture(GestureState(currentOffset: current, isTouchpad: true))
        // Reset the settle latch deterministically. It is otherwise only cleared by
        // an intervening frame tick, so a begin/end pair completed inside one frame
        // left it true from the previous settle — the settle branch was skipped and
        // the release never snapped. Timing-dependent snapping, in other words.
        scrollWidthSettled = false
        frameLoop?.resume()
    }

    /// Update during an active gesture.
    public func handleGestureUpdate(deltaX: Double, time: Double) {
        guard case .gesture(var state) = strip.viewOffset else { return }
        let bounds = strip.viewOffsetBounds(at: time)
        let oldOffset = state.currentOffset
        state.currentOffset = min(max(oldOffset + deltaX, bounds.lowerBound), bounds.upperBound)
        // Feed the tracker the actual offset change (not raw deltaX) so velocity
        // doesn't inflate when clamped at a boundary.
        let actualDelta = state.currentOffset - oldOffset
        state.tracker.push(delta: actualDelta, timestamp: time)
        strip.viewOffset = .gesture(state)
    }

    /// End a gesture — start momentum animation or stop.
    /// Focus is NOT changed here — it's deferred until the animation settles
    /// (in handleFrameTick) to avoid a visual jump from shifting the coordinate reference.
    public func handleGestureEnd(time: Double) {
        guard case .gesture(let state) = strip.viewOffset else { return }
        let velocity = state.tracker.velocity(at: time)
        #if DEBUG
        let bounds = strip.viewOffsetBounds(at: time)
        print("[Gesture] END offset=\(String(format: "%.1f", state.currentOffset)) vel=\(String(format: "%.1f", velocity)) snap=\(gestureSnap) bounds=[\(String(format: "%.1f", bounds.lowerBound)),\(String(format: "%.1f", bounds.upperBound))]")
        fflush(stdout)
        #endif

        if abs(velocity) > 50 {
            let projected = state.tracker.projectedEndPosition(isTouchpad: state.isTouchpad)

            if gestureSnap {
                // Determine target column for snap calculation (but don't change focus yet)
                let targetColumn = columnUnderCursor(gestureOffset: state.currentOffset)
                let colWidth = strip.columnData[targetColumn].currentWidth(at: time)
                // Owning region, not the whole group span. `workingArea.width` on a
                // merged two-display strip is the COMBINED width, so computeSnapOffset
                // centred the column across both displays and dropped it in the seam.
                let region = strip.regionForColumn(targetColumn, at: time)
                let wa = Double(region.rect.width)
                let regionOffset = Double(region.rect.minX - strip.groupArea.totalSpan.minX)

                // computeSnapOffset returns offsets assuming the target column IS the
                // active column. Translate into the current activeColumnIndex coordinate
                // space by adding the distance between the two columns.
                let columnDelta = strip.columnX(at: targetColumn, time: time)
                    - strip.columnX(at: strip.activeColumnIndex, time: time)

                let (snapIdx, rawSnapOffset): (Int, Double)
                if velocity > 0 {
                    (snapIdx, rawSnapOffset) = nextSnapMilestoneRight(
                        currentOffset: state.currentOffset - columnDelta + regionOffset,
                        snapPoints: strip.snapPoints,
                        columnWidth: colWidth,
                        workingAreaWidth: wa
                    )
                } else {
                    (snapIdx, rawSnapOffset) = nextSnapMilestoneLeft(
                        currentOffset: state.currentOffset - columnDelta + regionOffset,
                        snapPoints: strip.snapPoints,
                        columnWidth: colWidth,
                        workingAreaWidth: wa
                    )
                }
                let snapOffset = rawSnapOffset - regionOffset + columnDelta
                // Store snap index for the target column — will be applied when focus moves on settle
                strip.snapIndices[targetColumn] = snapIdx

                let anim = SpringAnimation(
                    from: state.currentOffset,
                    to: snapOffset,
                    initialVelocity: velocity,
                    startTime: time,
                    params: strip.scrollSpringParams
                )
                strip.viewOffset = .animation(anim)
            } else {
                // Free scroll — animate to projected position, no column alignment.
                // projectedEndPosition is relative to tracker.position (starts at 0),
                // but currentOffset includes the pre-gesture viewOffset. Add the
                // momentum delta so the target is in the same coordinate space.
                let momentumDelta = projected - state.tracker.position
                let fsBounds = strip.viewOffsetBounds(at: time)
                let rawTarget = state.currentOffset + momentumDelta
                let clampedTarget = min(max(rawTarget, fsBounds.lowerBound), fsBounds.upperBound)
                #if DEBUG
                print("[Gesture] FREE-SCROLL from=\(String(format: "%.1f", state.currentOffset)) rawTarget=\(String(format: "%.1f", rawTarget)) clamped=\(String(format: "%.1f", clampedTarget)) vel=\(String(format: "%.1f", velocity)) momentumDelta=\(String(format: "%.1f", momentumDelta))")
                fflush(stdout)
                #endif
                // If clamped target ≈ current position (at boundary), just stop —
                // a spring from X to X with velocity creates a visible bounce-back.
                if abs(clampedTarget - state.currentOffset) < 1.0 {
                    #if DEBUG
                    print("[Gesture] FREE-SCROLL at boundary, stopping immediately")
                    fflush(stdout)
                    #endif
                    strip.viewOffset = .static(state.currentOffset)
                    clearCommittedFrames()
                    applyLayout()
                    return
                }
                let anim = SpringAnimation(
                    from: state.currentOffset,
                    to: clampedTarget,
                    initialVelocity: velocity,
                    startTime: time,
                    params: .freeScrollMomentum
                )
                strip.viewOffset = .animation(anim)
            }
            scrollWidthSettled = false
            gestureAnimating = true
            // Frame loop continues to tick
        } else {
            // No significant velocity — just stop, then re-anchor focus to cursor column
            let bounds = strip.viewOffsetBounds(at: time)
            let clampedOffset = min(max(state.currentOffset, bounds.lowerBound), bounds.upperBound)
            let viewPos = strip.columnX(at: strip.activeColumnIndex, time: time) + clampedOffset
            let oldActive = strip.activeColumnIndex
            let newActive = columnUnderCursor(gestureOffset: clampedOffset)
            strip.activeColumnIndex = newActive
            startRaiseAnimations(oldColumn: oldActive, newColumn: newActive, at: time)
            let adjustedOffset = viewPos - strip.columnX(at: newActive, time: time)
            strip.viewOffset = .static(adjustedOffset)
            clearCommittedFrames()
            applyLayout()
            // Free scroll is a deliberate drop wherever the user let go. Mark the
            // settle work done so the latch's snapTargetForActive lock-in cannot
            // teleport it to a snap point on the next tick. Safe because
            // clearCommittedFrames() above forces applyLayout to rewrite every tile,
            // including the off-screen slivers the latch's own applyLayout exists to
            // dispatch. With gestureSnap the latch SHOULD run, so leave it alone.
            if !gestureSnap { scrollWidthSettled = true }
        }
    }

    /// Handle a discrete mouse scroll tick — smooth spring animation, no momentum.
    /// Consecutive ticks retarget the in-flight spring so they blend smoothly.
    public func handleDiscreteScroll(deltaX: Double, time: Double) {
        guard !strip.columns.isEmpty else { return }
        let bounds = strip.viewOffsetBounds(at: time)
        let current = strip.viewOffset.current(at: time)
        // Accumulate onto the current target (not current position) so rapid
        // ticks compound rather than fighting the in-flight spring.
        let baseTarget: Double
        if case .animation(let existing) = strip.viewOffset {
            baseTarget = existing.to
        } else {
            baseTarget = current
        }
        let target = min(max(baseTarget - deltaX, bounds.lowerBound), bounds.upperBound)
        #if DEBUG
        print("[Gesture] DISCRETE delta=\(String(format: "%.1f", deltaX)) from=\(String(format: "%.1f", current)) to=\(String(format: "%.1f", target)) bounds=[\(String(format: "%.1f", bounds.lowerBound)),\(String(format: "%.1f", bounds.upperBound))]")
        fflush(stdout)
        #endif
        if case .animation(let existing) = strip.viewOffset {
            let retargeted = existing.retargeted(to: target, at: time)
            strip.viewOffset = .animation(retargeted)
        } else {
            let anim = SpringAnimation(
                from: current,
                to: target,
                initialVelocity: 0,
                startTime: time,
                params: strip.scrollSpringParams
            )
            strip.viewOffset = .animation(anim)
        }
        scrollWidthSettled = false
        gestureAnimating = true
        frameLoop?.resume()
    }

    /// Cancel a gesture (e.g., another event interrupted it).
    public func handleGestureCancel() {
        gestureAnimating = false
        let time = TimeUtil.now()
        let current = strip.viewOffset.current(at: time)
        strip.viewOffset = .static(current)
        clearCommittedFrames()
        applyLayout()
    }

    /// Determine which column is under the cursor, using the current gesture offset.
    /// Falls back to the current activeColumnIndex if the cursor is outside the working area.
    private func columnUnderCursor(gestureOffset: Double) -> Int {
        guard !strip.columns.isEmpty else { return strip.activeColumnIndex }

        let cursorScreenX = NSEvent.mouseLocation.x
        let wa = strip.workingArea
        let time = TimeUtil.now()

        // If cursor is outside the working area X range, keep current active column
        guard cursorScreenX >= wa.minX && cursorScreenX <= wa.maxX else {
            return strip.activeColumnIndex
        }

        // Convert screen X to strip-space X:
        // From LayoutEngine: screenX = stripX - viewPos + wa.minX
        // viewPos = columnX(activeColumnIndex) + viewOffset
        // So: stripX = (screenX - wa.minX) + columnX(activeColumnIndex) + viewOffset
        let cursorStripX = (cursorScreenX - wa.minX)
            + strip.columnX(at: strip.activeColumnIndex, time: time)
            + gestureOffset

        return columnIndexAtStripX(cursorStripX, columnData: strip.columnData, gap: strip.gap, time: time)
    }

    /// Update the strip's group area (e.g., after display change, Dock show/hide,
    /// or main-display change). Solo-region groups behave exactly as today.
    public func updateGroupArea(_ area: GroupWorkingArea) {
        let changed = strip.groupArea != area
        strip.groupArea = area
        let time = TimeUtil.now()
        strip.recalculateWidths(at: time)
        // recalculateWidths may have changed the active column's cachedWidth;
        // without a re-snap, the stored viewOffset would leave the active
        // column off-center by the width delta on the next layout pass.
        if !strip.columns.isEmpty {
            strip.viewOffset = .static(strip.snapTargetForActive(at: time))
        }
        if changed {
            clearCommittedFrames()
        }
        applyLayout()
    }

    // MARK: - Focus Indicator

    private func updateFocusIndicator(frames: [TargetFrame]) {
        guard focusIndicator.style != .none else { return }

        // While paused, keep the indicator hidden. The frame loop and gesture
        // callbacks aren't pause-aware, so each tick/pan would otherwise re-show
        // the overlay via snapTo/trackFrame — undoing the pause-time hide().
        guard !isPaused else {
            focusIndicator.hide()
            lastRaisedTileID = nil
            lastIndicatorTileID = nil
            return
        }

        guard let activeTile = strip.activeColumn?.activeTile,
              let target = frames.first(where: { $0.tileID == activeTile && $0.isVisible }) else {
            focusIndicator.hide()
            lastRaisedTileID = nil
            lastIndicatorTileID = nil
            return
        }

        // Raise style: call AXWindow.raise() only when the active tile changes
        if focusIndicator.style == .raise {
            if lastRaisedTileID != activeTile {
                lastRaisedTileID = activeTile
                if let window = windowMap[activeTile] {
                    _ = window.raise()
                }
            }
            return
        }

        // Convert to screen coordinates (flip Y for AppKit)
        let screenHeight = primaryScreenHeight
        let flippedFrame = CGRect(
            x: target.frame.minX,
            y: screenHeight - target.frame.maxY,
            width: target.frame.width,
            height: target.frame.height
        )

        let tileChanged = lastIndicatorTileID != activeTile
        lastIndicatorTileID = activeTile

        // Bootstrap (no current frame) or tile change in flash mode → snapTo triggers flash easing
        let isBootstrap = focusIndicator.currentFrame == nil
        if isBootstrap || (tileChanged && focusIndicator.style == .flash) {
            let started = focusIndicator.snapTo(frame: flippedFrame)
            if started {
                frameLoop?.resume()
            }
        } else {
            // Direct tracking: position indicator exactly at the computed frame.
            // The scroll/width animations already produce smooth positions, so no
            // separate indicator springs are needed — this eliminates the double-spring lag.
            focusIndicator.trackFrame(flippedFrame)
        }
    }

    /// Wrapper for WindowManager — fades out the indicator when an unmanaged app activates.
    public func fadeOutIndicator() {
        if focusIndicator.fadeOut() {
            frameLoop?.resume()
        }
    }

    /// Wrapper for WindowManager — shows the indicator when a managed app activates.
    public func showIndicator() {
        let time = TimeUtil.now()
        let frames = computeTargetFrames(strip: strip, time: time, raiseHeight: raiseHeight)
        updateFocusIndicator(frames: frames)
    }

    // MARK: - Helpers

    private func framesEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 &&
        abs(a.minY - b.minY) < 0.5 &&
        abs(a.width - b.width) < 0.5 &&
        abs(a.height - b.height) < 0.5
    }

    /// Whether we are within the echo suppression window after a layout.
    public var isInEchoSuppression: Bool {
        TimeUtil.now() - lastLayoutTime < Self.echoSuppressionInterval
    }

    /// True if we recently switched spaces and should ignore external focus changes.
    public var isInSpaceSwitchSuppression: Bool {
        TimeUtil.now() - lastSpaceSwitchTime < Self.spaceSwitchFocusSuppressionInterval
    }

    // MARK: - Space Management

    /// Save the current strip state for the current Space.
    public func saveCurrentSpace() {
        guard !currentSpaceFingerprint.isEmpty else { return }
        // Clear in-flight width animations — stale springs with old startTimes
        // would evaluate incorrectly when restored later.
        for i in 0..<strip.columnData.count {
            strip.columnData[i].widthAnimation = nil
            strip.columnData[i].raiseAnimation = nil
        }

        // Use confirmedUserActiveTileID to determine the correct active column.
        // strip.activeColumnIndex may have been corrupted by macOS AX focus events
        // sent during space transition gestures. confirmedUserActiveTileID ignores
        // external focus changes within the last 300ms.
        let activeIndex: Int
        if let tile = confirmedUserActiveTileID,
           let idx = strip.columns.firstIndex(where: { $0.tiles.contains(tile) })
        {
            activeIndex = idx
        } else {
            activeIndex = strip.activeColumnIndex
        }

        #if DEBUG
        print("[Strip] saveSpace activeIdx=\(activeIndex) stripActiveIdx=\(strip.activeColumnIndex)"
            + " confirmed=\(_confirmedUserActiveTileID?.rawValue.description ?? "nil")"
            + " userActive=\(userActiveTileID?.rawValue.description ?? "nil")"
            + " externalFocusAgeMs=\(Int(((TimeUtil.now() - userActiveTileIDTime) * 1000).rounded()))")
        fflush(stdout)
        #endif

        savedSpaces[currentSpaceFingerprint] = SavedStripState(
            columns: strip.columns,
            columnData: strip.columnData,
            snapIndices: strip.snapIndices,
            activeColumnIndex: activeIndex,
            viewOffset: strip.viewOffset,
            windowMap: windowMap,
            apps: apps,
            lastCommittedFrames: lastCommittedFrames,
            savedAt: TimeUtil.now()
        )
        evictStaleSavedSpaces()
    }

    /// Cap the number of stashed Space snapshots so orphaned entries — spaces
    /// whose window population drifts past the Jaccard match threshold, or spaces
    /// deleted in Mission Control — can't pin dead AXWindow/AXApp objects for the
    /// life of the process. Drops least-recently-saved entries beyond the cap
    /// (finding #22).
    public static let maxSavedSpaces = 16
    private func evictStaleSavedSpaces() {
        guard savedSpaces.count > Self.maxSavedSpaces else { return }
        let overflow = savedSpaces.count - Self.maxSavedSpaces
        let oldest = savedSpaces.sorted { $0.value.savedAt < $1.value.savedAt }.prefix(overflow)
        for (key, _) in oldest {
            savedSpaces.removeValue(forKey: key)
        }
    }

    /// Prune a destroyed window from every stashed Space snapshot so closed
    /// windows don't keep pinning dead AXWindow/AXApp objects (each holds a CF
    /// AXUIElement) in `savedSpaces`. Removes the tile from its column (dropping
    /// the column, and the snapshot itself, if it becomes empty) and drops AXApp
    /// references for pids no longer used by any remaining stashed window.
    /// Safe to call from the window-removed handler / health check (finding #22).
    public func pruneSavedSpaces(removedTileID tileID: TileID) {
        // Snapshot the affected keys before mutating `savedSpaces`.
        let affected = savedSpaces.filter { $0.value.windowMap[tileID] != nil }.map { $0.key }
        for key in affected {
            guard var s = savedSpaces[key] else { continue }
            s.windowMap.removeValue(forKey: tileID)
            s.lastCommittedFrames.removeValue(forKey: tileID)

            // Remove the tile from its column; collect columns left empty.
            var dropIndices: [Int] = []
            for i in s.columns.indices {
                if let ti = s.columns[i].tiles.firstIndex(of: tileID) {
                    s.columns[i].tiles.remove(at: ti)
                }
                if s.columns[i].tiles.isEmpty { dropIndices.append(i) }
            }
            for i in dropIndices.reversed() {
                s.columns.remove(at: i)
                if i < s.columnData.count { s.columnData.remove(at: i) }
                if i < s.snapIndices.count { s.snapIndices.remove(at: i) }
                if i < s.activeColumnIndex { s.activeColumnIndex -= 1 }
            }
            if s.activeColumnIndex >= s.columns.count {
                s.activeColumnIndex = max(0, s.columns.count - 1)
            }

            // Drop AXApp refs for pids no longer referenced by any window.
            let livePids = Set(s.windowMap.values.map { $0.pid })
            s.apps = s.apps.filter { livePids.contains($0.key) }

            if s.columns.isEmpty {
                savedSpaces.removeValue(forKey: key)
            } else {
                savedSpaces[key] = s
            }
        }
    }

    /// Switch to a new Space. Saves current state, restores if we've been here before,
    /// or starts fresh if it's a new Space.
    /// Uses fuzzy fingerprint matching: if >50% of window IDs overlap with a saved space,
    /// it's considered the same space (handles windows created/destroyed while away).
    /// - Parameter onScreenWindowIDs: CGWindowIDs currently on screen
    /// - Returns: true if restored from saved state, false if needs fresh discovery
    public func switchSpace(onScreenWindowIDs: Set<UInt32>) -> Bool {
        // Save current space
        saveCurrentSpace()

        // Revoke queued writes for every tile currently held. switchSpace replaces
        // windowMap wholesale, so any tile not carried into the new Space has no
        // successor write and its queued closure would reposition it afterwards.
        for tileID in windowMap.keys { invalidatePendingWrite(tileID: tileID) }

        // Update fingerprint
        currentSpaceFingerprint = onScreenWindowIDs

        // Find best matching saved space (fuzzy: Jaccard similarity > 0.5)
        if let (matchedKey, saved) = findBestSavedSpace(for: onScreenWindowIDs) {
            // Update the saved key to the current fingerprint
            if matchedKey != onScreenWindowIDs {
                savedSpaces.removeValue(forKey: matchedKey)
            }

            // Restore saved state
            strip.columns = saved.columns
            strip.columnData = saved.columnData
            strip.activeColumnIndex = saved.activeColumnIndex
            // Nil any stale raise animations from saved state; sync targets
            let rh = raiseHeight
            for i in 0..<strip.columnData.count {
                strip.columnData[i].raiseAnimation = nil
                strip.columnData[i].cachedRaiseTarget = (i == strip.activeColumnIndex) ? 0 : rh
            }
            strip.viewOffset = saved.viewOffset
            // Restore snap indices with migration fallback
            if saved.snapIndices.count == saved.columns.count {
                strip.snapIndices = saved.snapIndices
            } else {
                strip.snapIndices = Array(repeating: strip.defaultSnapIndex, count: saved.columns.count)
            }
            windowMap = saved.windowMap
            apps = saved.apps
            lastCommittedFrames.removeAll()  // Force re-apply
            userActiveTileID = strip.activeColumn?.activeTile
            _confirmedUserActiveTileID = userActiveTileID

            focusIndicator.hide()
            lastRaisedTileID = nil
            lastIndicatorTileID = nil
            applyLayout()
            lastSpaceSwitchTime = TimeUtil.now()
            return true
        }

        // New space — clear for fresh discovery
        strip.columns.removeAll()
        strip.columnData.removeAll()
        strip.snapIndices.removeAll()
        strip.activeColumnIndex = 0
        strip.viewOffset = .static(0)
        windowMap.removeAll()
        apps.removeAll()
        lastCommittedFrames.removeAll()
        focusIndicator.hide()

        lastRaisedTileID = nil
        lastIndicatorTileID = nil
        lastSpaceSwitchTime = TimeUtil.now()
        return false
    }

    /// Find the saved space with the best fingerprint overlap.
    /// Returns nil if no saved space has >50% Jaccard similarity.
    private func findBestSavedSpace(for fingerprint: Set<UInt32>) -> (Set<UInt32>, SavedStripState)? {
        var bestKey: Set<UInt32>?
        var bestScore: Double = 0

        for key in savedSpaces.keys {
            let intersection = key.intersection(fingerprint).count
            let union = key.union(fingerprint).count
            guard union > 0 else { continue }
            let jaccard = Double(intersection) / Double(union)
            if jaccard > bestScore {
                bestScore = jaccard
                bestKey = key
            }
        }

        guard let key = bestKey, bestScore > 0.5, let state = savedSpaces[key] else {
            return nil
        }
        return (key, state)
    }

    /// Set the current Space fingerprint (used on initial startup).
    public func setSpaceFingerprint(_ fingerprint: Set<UInt32>) {
        currentSpaceFingerprint = fingerprint
    }
}

/// Saved state for a Space's strip layout.
struct SavedStripState {
    var columns: [Column]
    var columnData: [ColumnData]
    var snapIndices: [Int]
    var activeColumnIndex: Int
    var viewOffset: ViewOffset
    var windowMap: [TileID: AXWindow]
    var apps: [pid_t: AXApp]
    var lastCommittedFrames: [TileID: CGRect]
    /// When this snapshot was last saved. Drives LRU eviction (finding #22).
    var savedAt: Double
}
