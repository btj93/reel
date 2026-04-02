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

    /// Saved strip states per Space, keyed by a fingerprint of on-screen window IDs.
    private var savedSpaces: [Set<UInt32>: SavedStripState] = [:]

    /// The fingerprint of the current Space.
    public internal(set) var currentSpaceFingerprint: Set<UInt32> = []

    /// Called before a column is removed. Provides column metadata for position memory.
    /// Parameters: tileID, column, columnData, columnIndex, neighborBefore bundleID, neighborAfter bundleID
    public var onBeforeRemoveWindow: ((_ tileID: TileID, _ column: Column, _ columnData: ColumnData,
                                        _ columnIndex: Int, _ neighborBefore: String?,
                                        _ neighborAfter: String?) -> Void)?

    /// Set to true to suppress position save during removeWindow (e.g., toggleFloating)
    public var suppressPositionSave: Bool = false

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

    /// Timestamp of the last layout application. Used to suppress echo AX events.
    public private(set) var lastLayoutTime: Double = 0

    /// How long to ignore AX echo events after a layout (100ms).
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

    /// Zen mode dimmer for unfocused windows.
    public let zenDimmer: ZenDimmer

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

    public init(workingArea: CGRect, primaryScreenHeight: CGFloat) {
        self.strip = Strip(workingArea: workingArea)
        self.primaryScreenHeight = primaryScreenHeight
        self.focusIndicator = FocusIndicator()
        self.zenDimmer = ZenDimmer()
    }

    /// True when all animations (scroll, width, focus indicator) have settled.
    public var isFullySettled: Bool {
        let time = TimeUtil.now()
        let scrollSettled = strip.viewOffset.isSettled(at: time)
        let widthSettled = !strip.columnData.contains(where: { $0.widthAnimation != nil })
        return scrollSettled && widthSettled && !focusIndicator.isAnimating && !zenDimmer.isAnimating
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
        #if DEBUG
        print("[Strip] addWindow: tileID=\(window.tileID.rawValue) pid=\(window.pid) title=\(window.getTitle() ?? "?")")
        fflush(stdout)
        #endif
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
        updateZenDimmer(at: TimeUtil.now())
    }

    /// Add a window at a specific position with saved column properties from position memory.
    /// When restoredPosition is non-nil, inserts at the saved position with saved width.
    /// When nil, falls back to default behavior.
    public func addWindow(_ window: AXWindow, app: AXApp, restoredPosition: SavedPosition?) {
        guard let saved = restoredPosition else {
            addWindow(window, app: app)
            return
        }

        #if DEBUG
        print("[Strip] addWindow (restored): tileID=\(window.tileID.rawValue) pid=\(window.pid) at index=\(saved.columnIndex) width=\(saved.width)")
        fflush(stdout)
        #endif
        windowMap[window.tileID] = window
        apps[window.pid] = app

        // Determine insertion index: neighbor → columnIndex → default
        let insertIndex = resolveInsertIndex(saved: saved)

        // Normalize width: never restore .auto
        let width: ColumnWidth
        switch saved.width {
        case .auto:
            width = .fixed(saved.width.resolve(workingAreaWidth: strip.workingArea.width, gap: strip.gap))
        default:
            width = saved.width
        }

        let column = Column(tiles: [window.tileID], width: width,
                            presetIndex: saved.presetIndex, isFullWidth: saved.isFullWidth)
        strip.insertColumn(column, at: TimeUtil.now(), atIndex: insertIndex)

        if !isBatching {
            // Pre-position the new window immediately before the full layout pass.
            // This eliminates the flicker where the window briefly appears at its
            // native/app-default position before snapping to the strip position.
            let frames = computeTargetFrames(strip: strip, time: TimeUtil.now())
            if let target = frames.first(where: { $0.tileID == window.tileID }) {
                _ = window.setFrame(target.frame)
                lastCommittedFrames[window.tileID] = target.frame
            }
            applyLayout()
        }
        updateZenDimmer(at: TimeUtil.now())
    }

    /// Resolve the best insertion index from saved position data.
    private func resolveInsertIndex(saved: SavedPosition) -> Int {
        // Priority 1: Insert right of neighborBefore
        if let beforeID = saved.neighborBefore {
            for (i, col) in strip.columns.enumerated() {
                if let tile = col.activeTile, let win = windowMap[tile],
                   let app = apps[win.pid], app.bundleIdentifier == beforeID {
                    return i + 1
                }
            }
        }

        // Priority 2: Insert left of neighborAfter
        if let afterID = saved.neighborAfter {
            for (i, col) in strip.columns.enumerated() {
                if let tile = col.activeTile, let win = windowMap[tile],
                   let app = apps[win.pid], app.bundleIdentifier == afterID {
                    return i
                }
            }
        }

        // Priority 3: Clamped columnIndex
        return max(0, min(saved.columnIndex, strip.columns.count))
    }

    /// Remove a window from the strip.
    public func removeWindow(tileID: TileID) {
        zenDimmer.restoreWindow(tileID)
        if let colIndex = strip.columns.firstIndex(where: { $0.tiles.contains(tileID) }) {
            // Fire callback before removal so strip state is intact
            if !suppressPositionSave, let callback = onBeforeRemoveWindow {
                let column = strip.columns[colIndex]
                let colData = strip.columnData[colIndex]

                let neighborBefore: String? = if colIndex > 0,
                    let tile = strip.columns[colIndex - 1].activeTile,
                    let win = windowMap[tile],
                    let app = apps[win.pid] { app.bundleIdentifier } else { nil }

                let neighborAfter: String? = if colIndex < strip.columns.count - 1,
                    let tile = strip.columns[colIndex + 1].activeTile,
                    let win = windowMap[tile],
                    let app = apps[win.pid] { app.bundleIdentifier } else { nil }

                callback(tileID, column, colData, colIndex, neighborBefore, neighborAfter)
            }

            strip.removeColumn(at: colIndex, at: TimeUtil.now())
        }
        windowMap.removeValue(forKey: tileID)
        lastCommittedFrames.removeValue(forKey: tileID)
        dirtyTileIDs.remove(tileID)
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
        zenDimmer.restoreAll()
        lastRaisedTileID = nil
        lastIndicatorTileID = nil
    }

    // MARK: - Navigation

    public func focusLeft() {
        let time = TimeUtil.now()
        if animationEnabled {
            if let _ = strip.navigateLeft(at: time) {
                scrollWidthSettled = false
                frameLoop?.resume()
            }
        } else {
            strip.navigateLeftInstant(at: time)
            applyLayout()
        }
        userActiveTileID = strip.activeColumn?.activeTile
        _confirmedUserActiveTileID = userActiveTileID
        focusActiveWindow()
        updateZenDimmer(at: TimeUtil.now())
    }

    public func focusRight() {
        let time = TimeUtil.now()
        if animationEnabled {
            if let _ = strip.navigateRight(at: time) {
                scrollWidthSettled = false
                frameLoop?.resume()
            }
        } else {
            strip.navigateRightInstant(at: time)
            applyLayout()
        }
        userActiveTileID = strip.activeColumn?.activeTile
        _confirmedUserActiveTileID = userActiveTileID
        focusActiveWindow()
        updateZenDimmer(at: TimeUtil.now())
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

    public func toggleFullWidth() {
        strip.toggleFullWidth()
        let time = TimeUtil.now()
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

        suppressPositionSave = true
        removeWindow(tileID: activeTile)
        suppressPositionSave = false
        return window
    }

    /// Re-add a floating window back to the strip.
    public func unfloatWindow(_ window: AXWindow, app: AXApp) {
        addWindow(window, app: app)
    }

    // MARK: - User Move/Resize Handling

    /// Called when a user drags a window. Snaps it back to its strip position.
    public func handleUserMove(windowID: CGWindowID) {
        let tileID = TileID(windowID)
        guard windowMap[tileID] != nil,
              strip.columns.contains(where: { $0.tiles.contains(tileID) }) else { return }

        // Clear the committed frame so applyLayout will reposition it
        lastCommittedFrames.removeValue(forKey: tileID)
        applyLayout()
    }

    /// Called when a user manually resizes a window. Updates the column width to match,
    /// and enforces that the window cannot be wider/taller than the working area.
    public func handleUserResize(windowID: CGWindowID) {
        let tileID = TileID(windowID)
        guard let window = windowMap[tileID],
              let colIndex = strip.columns.firstIndex(where: { $0.tiles.contains(tileID) }) else { return }

        guard case .success(let currentFrame) = window.getFrame() else { return }

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
        guard abs(newWidth - oldWidth) > 2 else { return }

        // Skip if the column width was set by cycleWidthPreset — late AX resize
        // notifications can arrive after echo suppression expires.
        guard strip.columns[colIndex].presetIndex == nil else { return }

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
        strip.columns[colIndex].presetIndex = nil
        strip.columnData[colIndex].widthAnimation = nil
        strip.columnData[colIndex].cachedWidth = newWidth

        // Apply layout immediately during drag
        applyLayout()

        // Debounce recenter: wait for drag to settle before animating back to center
        resizeRecenterWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let time = TimeUtil.now()
            if self.animationEnabled {
                if let _ = self.strip.recenterActiveColumnAnimated(at: time) {
                    self.scrollWidthSettled = false
                    self.frameLoop?.resume()
                }
            } else {
                self.strip.recenterActiveColumn(at: time)
                self.applyLayout()
            }
        }
        resizeRecenterWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: - Scroll to Window (Cmd+Tab support)

    /// Scroll the strip to make a specific window visible.
    public func scrollToWindow(tileID: TileID) {
        guard let colIndex = strip.columns.firstIndex(where: { $0.tiles.contains(tileID) }) else { return }
        #if DEBUG
        let window = windowMap[tileID]
        print("[Strip] scrollTo wid=\(window?.windowID ?? 0) tileID=\(tileID.rawValue) col=\(colIndex) title=\(window?.getTitle() ?? "?")")
        fflush(stdout)
        #endif

        let time = TimeUtil.now()
        strip.columnData[colIndex].widthAnimation = nil
        strip.activeColumnIndex = colIndex
        strip.snapIndices[colIndex] = strip.defaultSnapIndex

        let snapPoint = strip.snapPoints[strip.snapIndices[colIndex]]
        let newOffset = computeSnapOffset(
            snapPoint: snapPoint,
            columnWidth: strip.columnData[colIndex].currentWidth(at: time),
            workingAreaWidth: strip.workingArea.width
        )
        strip.viewOffset = .static(newOffset)

        applyLayout()
        updateZenDimmer(at: time)
    }

    // MARK: - Layout Application

    /// Compute target frames and apply to real windows.
    /// This is the Phase 1 "instant" mode.
    public func applyLayout() {
        // Record timestamp so echo AX events can be suppressed
        let time = TimeUtil.now()
        lastLayoutTime = time

        let frames = computeTargetFrames(strip: strip, time: time)

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
            if target.isOffScreen {
                let position = target.frame.origin
                DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                    let result = window.setPosition(position)
                    if case .failure = result {
                        DispatchQueue.main.async { self?.dirtyTileIDs.insert(tileID) }
                    }
                }
            } else {
                let frame = target.frame
                if let app = apps[window.pid] {
                    DispatchQueue.global(qos: .userInteractive).async {
                        app.dispatchSetFrame(window, frame: frame)
                    }
                } else {
                    // Fallback: dispatch setFrame directly when app not in dict
                    DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                        let result = window.setFrame(frame)
                        if case .failure = result {
                            DispatchQueue.main.async { self?.dirtyTileIDs.insert(tileID) }
                        }
                    }
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
        #if DEBUG
        print("[Strip] focus wid=\(window.windowID) tileID=\(activeTile.rawValue) col=\(strip.activeColumnIndex) title=\(window.getTitle() ?? "?")")
        fflush(stdout)
        #endif
        window.focus()
    }

    // MARK: - Animation Frame Tick

    /// Called by FrameLoop every vsync frame during animation.
    public func handleFrameTick(time: Double) {
        // Advance focus indicator animations first (unconditional)
        focusIndicator.tick(time: time)
        zenDimmer.tick(time: time)

        // Settle any completed width animations (single pass: settle + check)
        let widthSettled = !strip.settleWidthAnimations(at: time)
        let scrollSettled = strip.viewOffset.isSettled(at: time)

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
                    let viewPos = strip.columnX(at: strip.activeColumnIndex, time: time) + finalOffset
                    let newActive = columnUnderCursor(gestureOffset: finalOffset)
                    strip.activeColumnIndex = newActive
                    let adjustedOffset = viewPos - strip.columnX(at: newActive, time: time)
                    strip.viewOffset = .static(adjustedOffset)
                } else {
                    strip.viewOffset = .static(finalOffset)
                }

                // One final layout with exact positions + full setFrame.
                // Don't clearCommittedFrames() — visible windows have committed entries,
                // so applyLayout()'s diff logic can skip unchanged windows.
                // Far-zone windows still have their last-visible position in
                // lastCommittedFrames, so applyLayout() will detect the change
                // and dispatch the off-screen move.
                applyLayout()
                updateZenDimmer(at: time)
            } else if focusIndicator.isAnimating || zenDimmer.isAnimating {
                // Scroll and width are done but indicator/zen is still animating — keep ticking
                if focusIndicator.isAnimating {
                    let frames = computeTargetFrames(strip: strip, time: time)
                    updateFocusIndicator(frames: frames)
                }
            }
            return
        }

        scrollWidthSettled = false

        // Compute frames with animation evaluated at this timestamp
        let frames = computeTargetFrames(strip: strip, time: time)

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
                if let app = apps[window.pid] {
                    if widthSettled {
                        // Width done, only position changing — position-only is cheaper
                        let position = target.frame.origin
                        DispatchQueue.global(qos: .userInteractive).async {
                            app.dispatchSetPosition(window, position: position)
                        }
                    } else {
                        // Width still animating — need full setFrame to resize
                        let frame = target.frame
                        DispatchQueue.global(qos: .userInteractive).async {
                            app.dispatchSetFrame(window, frame: frame)
                        }
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
        strip.viewOffset = .gesture(GestureState(currentOffset: current, isTouchpad: true))
        frameLoop?.resume()
    }

    /// Update during an active gesture.
    public func handleGestureUpdate(deltaX: Double, time: Double) {
        guard case .gesture(var state) = strip.viewOffset else { return }
        state.currentOffset += deltaX
        state.tracker.push(delta: deltaX, timestamp: time)
        strip.viewOffset = .gesture(state)
    }

    /// End a gesture — start momentum animation or stop.
    /// Focus is NOT changed here — it's deferred until the animation settles
    /// (in handleFrameTick) to avoid a visual jump from shifting the coordinate reference.
    public func handleGestureEnd(time: Double) {
        guard case .gesture(let state) = strip.viewOffset else { return }
        let velocity = state.tracker.velocity()

        if abs(velocity) > 50 {
            let projected = state.tracker.projectedEndPosition(isTouchpad: state.isTouchpad)

            if gestureSnap {
                // Determine target column for snap calculation (but don't change focus yet)
                let targetColumn = columnUnderCursor(gestureOffset: state.currentOffset)
                let colWidth = strip.columnData[targetColumn].currentWidth(at: time)
                let wa = strip.workingArea.width
                let (snapIdx, snapOffset): (Int, Double)
                if velocity > 0 {
                    (snapIdx, snapOffset) = nextSnapMilestoneRight(
                        currentOffset: state.currentOffset,
                        snapPoints: strip.snapPoints,
                        columnWidth: colWidth,
                        workingAreaWidth: wa
                    )
                } else {
                    (snapIdx, snapOffset) = nextSnapMilestoneLeft(
                        currentOffset: state.currentOffset,
                        snapPoints: strip.snapPoints,
                        columnWidth: colWidth,
                        workingAreaWidth: wa
                    )
                }
                // Store snap index for the target column — will be applied when focus moves on settle
                strip.snapIndices[targetColumn] = snapIdx

                let anim = SpringAnimation(
                    from: state.currentOffset,
                    to: snapOffset,
                    initialVelocity: velocity,
                    startTime: time,
                    params: .horizontalScroll
                )
                strip.viewOffset = .animation(anim)
            } else {
                // Free scroll — animate to projected position, no column alignment
                let anim = SpringAnimation(
                    from: state.currentOffset,
                    to: projected,
                    initialVelocity: velocity,
                    startTime: time,
                    params: .horizontalScroll
                )
                strip.viewOffset = .animation(anim)
            }
            scrollWidthSettled = false
            gestureAnimating = true
            // Frame loop continues to tick
        } else {
            // No significant velocity — just stop, then re-anchor focus to cursor column
            let viewPos = strip.columnX(at: strip.activeColumnIndex, time: time) + state.currentOffset
            let newActive = columnUnderCursor(gestureOffset: state.currentOffset)
            strip.activeColumnIndex = newActive
            let adjustedOffset = viewPos - strip.columnX(at: newActive, time: time)
            strip.viewOffset = .static(adjustedOffset)
            clearCommittedFrames()
            applyLayout()
            updateZenDimmer(at: time)
        }
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

    /// Update the working area (e.g., after display change or Dock show/hide).
    public func updateWorkingArea(_ rect: CGRect) {
        let changed = !framesEqual(strip.workingArea, rect)
        strip.workingArea = rect
        strip.recalculateWidths()
        if changed {
            // Clear committed frames so all windows reposition
            clearCommittedFrames()
        }
        applyLayout()
    }

    // MARK: - Focus Indicator

    private func updateFocusIndicator(frames: [TargetFrame]) {
        guard focusIndicator.style != .none else { return }

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

    /// Notify zen dimmer of the current focus state. Resumes FrameLoop if animations start.
    private func updateZenDimmer(at time: Double) {
        guard let activeTile = strip.activeColumn?.activeTile else { return }
        let allTileIDs = strip.columns.compactMap(\.activeTile)
        if zenDimmer.setFocusedWindow(activeTile, allTileIDs: allTileIDs, at: time) {
            frameLoop?.resume()
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
        let frames = computeTargetFrames(strip: strip, time: time)
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

        savedSpaces[currentSpaceFingerprint] = SavedStripState(
            columns: strip.columns,
            columnData: strip.columnData,
            snapIndices: strip.snapIndices,
            activeColumnIndex: activeIndex,
            viewOffset: strip.viewOffset,
            windowMap: windowMap,
            apps: apps,
            lastCommittedFrames: lastCommittedFrames
        )
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
            // Re-apply zen dimming with force — macOS may reset compositing on space switch
            if let activeTile = strip.activeColumn?.activeTile {
                let allTileIDs = strip.columns.compactMap(\.activeTile)
                if zenDimmer.setFocusedWindow(activeTile, allTileIDs: allTileIDs, at: TimeUtil.now(), force: true) {
                    frameLoop?.resume()
                }
            }
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
        zenDimmer.restoreAll()
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
    let columns: [Column]
    let columnData: [ColumnData]
    let snapIndices: [Int]
    let activeColumnIndex: Int
    let viewOffset: ViewOffset
    let windowMap: [TileID: AXWindow]
    let apps: [pid_t: AXApp]
    let lastCommittedFrames: [TileID: CGRect]
}
