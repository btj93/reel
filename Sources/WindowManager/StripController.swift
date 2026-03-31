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

    /// Whether animation is enabled (Phase 2 toggle).
    public var animationEnabled: Bool = false

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

    /// Timestamp of the last layout application. Used to suppress echo AX events.
    public private(set) var lastLayoutTime: Double = 0

    /// How long to ignore AX echo events after a layout (100ms).
    public static let echoSuppressionInterval: Double = 0.15

    /// Focus ring overlay.
    public let focusRing: FocusRing

    /// Debounced recenter after user resize settles.
    private var resizeRecenterWork: DispatchWorkItem?

    /// Frame loop for animated scrolling (nil until Phase 2 is wired).
    public var frameLoop: FrameLoop?

    public init(workingArea: CGRect) {
        self.strip = Strip(workingArea: workingArea)
        self.focusRing = FocusRing()
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
        print("[Strip] addWindow: tileID=\(window.tileID.rawValue) pid=\(window.pid) title=\(window.getTitle() ?? "?")")
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
        strip.insertColumn(column, at: currentTime())

        if !isBatching {
            applyLayout()
        }
    }

    /// Add a window at a specific position with saved column properties from position memory.
    /// When restoredPosition is non-nil, inserts at the saved position with saved width.
    /// When nil, falls back to default behavior.
    public func addWindow(_ window: AXWindow, app: AXApp, restoredPosition: SavedPosition?) {
        guard let saved = restoredPosition else {
            addWindow(window, app: app)
            return
        }

        print("[Strip] addWindow (restored): tileID=\(window.tileID.rawValue) pid=\(window.pid) at index=\(saved.columnIndex)")
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
        strip.insertColumn(column, at: currentTime(), atIndex: insertIndex)

        if !isBatching {
            // Pre-position the new window immediately before the full layout pass.
            // This eliminates the flicker where the window briefly appears at its
            // native/app-default position before snapping to the strip position.
            let frames = computeTargetFrames(strip: strip, time: currentTime())
            if let target = frames.first(where: { $0.tileID == window.tileID }) {
                _ = window.setFrame(target.frame)
                lastCommittedFrames[window.tileID] = target.frame
            }
            applyLayout()
        }
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

            strip.removeColumn(at: colIndex, at: currentTime())
        }
        windowMap.removeValue(forKey: tileID)
        lastCommittedFrames.removeValue(forKey: tileID)
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
        focusRing.hide()
    }

    // MARK: - Navigation

    public func focusLeft() {
        let time = currentTime()
        if animationEnabled {
            if let _ = strip.navigateLeft(at: time) {
                frameLoop?.resume()
            }
        } else {
            strip.navigateLeftInstant(at: time)
            applyLayout()
        }
        focusActiveWindow()
    }

    public func focusRight() {
        let time = currentTime()
        if animationEnabled {
            if let _ = strip.navigateRight(at: time) {
                frameLoop?.resume()
            }
        } else {
            strip.navigateRightInstant(at: time)
            applyLayout()
        }
        focusActiveWindow()
    }

    public func moveColumnLeft() {
        strip.moveColumnLeft(at: currentTime())
        applyLayout()
        focusActiveWindow()
    }

    public func moveColumnRight() {
        strip.moveColumnRight(at: currentTime())
        applyLayout()
        focusActiveWindow()
    }

    public func cycleWidthPreset() {
        strip.cycleWidthPreset()
        applyLayout()
    }

    public func toggleFullWidth() {
        strip.toggleFullWidth()
        applyLayout()
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

        let widthDelta = newWidth - oldWidth

        // Detect left-edge resize: if the right edge stayed roughly in place
        // while the left edge moved, the user is dragging from the left side.
        // Adjust the view offset so the right edge stays anchored on screen.
        if let lastFrame = lastCommittedFrames[tileID] {
            let rightEdgeDelta = abs(Double(currentFrame.maxX) - Double(lastFrame.maxX))
            let leftEdgeDelta = abs(Double(currentFrame.minX) - Double(lastFrame.minX))
            if leftEdgeDelta > rightEdgeDelta && leftEdgeDelta > 2 {
                let currentOffset = strip.viewOffset.current(at: currentTime())
                strip.viewOffset = .static(currentOffset + widthDelta)
            }
        }

        strip.columns[colIndex].width = .fixed(newWidth)
        strip.columns[colIndex].presetIndex = nil
        strip.columnData[colIndex].cachedWidth = newWidth

        // Apply layout immediately during drag
        applyLayout()

        // Debounce recenter: wait for drag to settle before animating back to center
        resizeRecenterWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let time = self.currentTime()
            if self.animationEnabled {
                if let _ = self.strip.recenterActiveColumnAnimated(at: time) {
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

        strip.activeColumnIndex = colIndex
        strip.snapIndices[colIndex] = strip.defaultSnapIndex

        let snapPoint = strip.snapPoints[strip.snapIndices[colIndex]]
        let newOffset = computeSnapOffset(
            snapPoint: snapPoint,
            columnWidth: strip.columnData[colIndex].currentWidth,
            workingAreaWidth: strip.workingArea.width
        )
        strip.viewOffset = .static(newOffset)

        applyLayout()
    }

    // MARK: - Layout Application

    /// Compute target frames and apply to real windows.
    /// This is the Phase 1 "instant" mode.
    public func applyLayout() {
        // Record timestamp so echo AX events can be suppressed
        lastLayoutTime = currentTime()

        let time = currentTime()
        let frames = computeTargetFrames(strip: strip, time: time)

        print("[Layout] applyLayout: \(frames.count) frames, \(strip.columns.count) cols, active=\(strip.activeColumnIndex) viewOffset=\(strip.viewOffset.current(at: time))")
        for (i, f) in frames.enumerated() {
            let isFocused = strip.activeColumn?.tiles.contains(f.tileID) == true
            print("[Layout]   [\(i)] tile=\(f.tileID.rawValue) x=\(Int(f.frame.minX)) w=\(Int(f.frame.width)) vis=\(f.isVisible) off=\(f.isOffScreen)\(isFocused ? " ★" : "")")
        }
        fflush(stdout)

        // Apply frames to real windows
        var applied = 0
        var skipped = 0
        var noWindow = 0
        for target in frames {
            guard let window = windowMap[target.tileID] else {
                noWindow += 1
                continue
            }

            // Only update if the frame actually changed
            if let lastFrame = lastCommittedFrames[target.tileID],
               framesEqual(lastFrame, target.frame) {
                skipped += 1
                continue
            }

            // Apply frame via AX — only record in lastCommittedFrames on success
            let result: AXResult<Void>
            if target.isOffScreen {
                result = window.setPosition(target.frame.origin)
            } else {
                result = window.setFrame(target.frame)
            }
            switch result {
            case .success:
                applied += 1
                lastCommittedFrames[target.tileID] = target.frame
            case .failure(let err):
                print("[Layout]   FAIL tile=\(target.tileID.rawValue) err=\(err)")
                fflush(stdout)
                // Don't record — will retry next applyLayout
            }
        }
        print("[Layout]   applied=\(applied) skipped=\(skipped) noWindow=\(noWindow)")

        // Update focus ring
        updateFocusRing(frames: frames)
    }

    /// Focus the active window (activate app + keyboard focus + raise).
    /// Only call this on explicit user navigation, NOT during startup/batch/relayout.
    public func focusActiveWindow() {
        guard let activeTile = strip.activeColumn?.activeTile,
              let window = windowMap[activeTile] else { return }
        window.focus()
    }

    // MARK: - Animation Frame Tick

    /// Called by FrameLoop every vsync frame during animation.
    public func handleFrameTick(time: Double) {
        // Check if animation has settled
        if strip.viewOffset.isSettled(at: time) {
            let finalOffset = strip.viewOffset.current(at: time)
            strip.viewOffset = .static(finalOffset)
            frameLoop?.pause()

            // One final layout with exact positions + full setFrame (not position-only)
            clearCommittedFrames()
            applyLayout()
            return
        }

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
               abs(lastFrame.minY - target.frame.minY) < 2.0 {
                continue
            }

            // During animation: position-only for visible, skip far windows
            switch target.visibilityZone {
            case .visible, .nearBuffer:
                // Dispatch to per-app thread (non-blocking)
                if let app = apps[window.pid] {
                    let position = target.frame.origin
                    DispatchQueue.global(qos: .userInteractive).async {
                        app.dispatchSetPosition(window, position: position)
                    }
                }
                lastCommittedFrames[target.tileID] = target.frame
            case .far:
                // Skip during animation — will be updated on settle
                break
            }
        }

        // Update focus ring position
        updateFocusRing(frames: frames)
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
    public func handleGestureEnd(time: Double) {
        guard case .gesture(let state) = strip.viewOffset else { return }
        let velocity = state.tracker.velocity()

        if abs(velocity) > 50 {
            // Momentum → snap to nearest column edge
            let projected = state.tracker.projectedEndPosition(isTouchpad: state.isTouchpad)
            let snapped = snapToNearestColumnEdge(offset: projected)
            let anim = SpringAnimation(
                from: state.currentOffset,
                to: snapped,
                initialVelocity: velocity,
                startTime: time,
                params: .horizontalScroll
            )
            strip.viewOffset = .animation(anim)
            // Frame loop continues to tick
        } else {
            // No significant velocity — just stop
            strip.viewOffset = .static(state.currentOffset)
            frameLoop?.pause()
            clearCommittedFrames()
            applyLayout()
        }
    }

    /// Cancel a gesture (e.g., another event interrupted it).
    public func handleGestureCancel() {
        let time = currentTime()
        let current = strip.viewOffset.current(at: time)
        strip.viewOffset = .static(current)
        frameLoop?.pause()
        clearCommittedFrames()
        applyLayout()
    }

    /// Snap a scroll offset to the nearest column edge for the active column.
    private func snapToNearestColumnEdge(offset: Double) -> Double {
        let viewPos = strip.columnX(at: strip.activeColumnIndex) + offset
        let viewCenter = viewPos + strip.workingArea.width / 2
        var bestIndex = strip.activeColumnIndex
        var bestDist = Double.infinity

        for i in 0..<strip.columns.count {
            let colCenter = strip.columnX(at: i) + strip.columnData[i].currentWidth / 2
            let dist = abs(colCenter - viewCenter)
            if dist < bestDist {
                bestDist = dist
                bestIndex = i
            }
        }

        strip.activeColumnIndex = bestIndex
        strip.snapIndices[bestIndex] = strip.defaultSnapIndex

        let snapPoint = strip.snapPoints[strip.snapIndices[bestIndex]]
        return computeSnapOffset(
            snapPoint: snapPoint,
            columnWidth: strip.columnData[bestIndex].currentWidth,
            workingAreaWidth: strip.workingArea.width
        )
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

    // MARK: - Focus Ring

    private func updateFocusRing(frames: [TargetFrame]) {
        guard let activeTile = strip.activeColumn?.activeTile,
              let target = frames.first(where: { $0.tileID == activeTile && $0.isVisible }) else {
            focusRing.hide()
            return
        }

        // Convert to screen coordinates (flip Y for AppKit)
        // CGRect from layout uses top-left origin (like CGWindowList),
        // but NSWindow uses bottom-left origin.
        if let screen = NSScreen.main {
            let screenHeight = screen.frame.height
            let flippedFrame = CGRect(
                x: target.frame.minX,
                y: screenHeight - target.frame.maxY,
                width: target.frame.width,
                height: target.frame.height
            )
            print("[FocusRing] showing at x=\(Int(flippedFrame.minX)) y=\(Int(flippedFrame.minY)) w=\(Int(flippedFrame.width)) h=\(Int(flippedFrame.height))")
            fflush(stdout)
            focusRing.show(around: flippedFrame)
        }
    }

    // MARK: - Helpers

    private func currentTime() -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_absolute_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }

    private func framesEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 &&
        abs(a.minY - b.minY) < 0.5 &&
        abs(a.width - b.width) < 0.5 &&
        abs(a.height - b.height) < 0.5
    }

    /// Whether we are within the echo suppression window after a layout.
    public var isInEchoSuppression: Bool {
        currentTime() - lastLayoutTime < Self.echoSuppressionInterval
    }

    // MARK: - Space Management

    /// Save the current strip state for the current Space.
    public func saveCurrentSpace() {
        guard !currentSpaceFingerprint.isEmpty else { return }
        savedSpaces[currentSpaceFingerprint] = SavedStripState(
            columns: strip.columns,
            columnData: strip.columnData,
            snapIndices: strip.snapIndices,
            activeColumnIndex: strip.activeColumnIndex,
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

            applyLayout()
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
        focusRing.hide()
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
