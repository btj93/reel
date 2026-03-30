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
    private var currentSpaceFingerprint: Set<UInt32> = []

    /// Timestamp of the last layout application. Used to suppress echo AX events.
    public private(set) var lastLayoutTime: Double = 0

    /// How long to ignore AX echo events after a layout (100ms).
    public static let echoSuppressionInterval: Double = 0.15

    /// Focus ring overlay.
    public let focusRing: FocusRing

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

    /// Remove a window from the strip.
    public func removeWindow(tileID: TileID) {
        // Find the column containing this tile
        if let colIndex = strip.columns.firstIndex(where: { $0.tiles.contains(tileID) }) {
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
            if let _ = strip.focusLeftAnimated(at: time) {
                frameLoop?.resume()
            }
        } else {
            strip.focusLeft(at: time)
            applyLayout()
        }
        focusActiveWindow()
    }

    public func focusRight() {
        let time = currentTime()
        if animationEnabled {
            if let _ = strip.focusRightAnimated(at: time) {
                frameLoop?.resume()
            }
        } else {
            strip.focusRight(at: time)
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

        // Remove from strip — it becomes floating
        removeWindow(tileID: activeTile)
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

        strip.columns[colIndex].width = .fixed(newWidth)
        strip.columns[colIndex].presetIndex = nil
        strip.columnData[colIndex].cachedWidth = newWidth

        // Re-apply layout to reposition other columns
        applyLayout()
    }

    // MARK: - Scroll to Window (Cmd+Tab support)

    /// Scroll the strip to make a specific window visible.
    public func scrollToWindow(tileID: TileID) {
        guard let colIndex = strip.columns.firstIndex(where: { $0.tiles.contains(tileID) }) else { return }

        let previous = strip.activeColumnIndex
        strip.activeColumnIndex = colIndex

        let newOffset = computeNewViewOffset(
            forColumn: colIndex,
            previousColumn: previous,
            focusMode: strip.focusMode,
            columns: strip.columns,
            columnData: strip.columnData,
            gap: strip.gap,
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
        // Snap to the centered offset for the nearest column
        let time = currentTime()
        let viewPos = strip.columnX(at: strip.activeColumnIndex) + offset

        // Find which column center is closest to the viewport center
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
        return computeNewViewOffset(
            forColumn: bestIndex,
            previousColumn: nil,
            focusMode: strip.focusMode,
            columns: strip.columns,
            columnData: strip.columnData,
            gap: strip.gap,
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
            activeColumnIndex: strip.activeColumnIndex,
            viewOffset: strip.viewOffset,
            windowMap: windowMap,
            apps: apps,
            lastCommittedFrames: lastCommittedFrames
        )
    }

    /// Switch to a new Space. Saves current state, restores if we've been here before,
    /// or starts fresh if it's a new Space.
    /// - Parameter onScreenWindowIDs: CGWindowIDs currently on screen
    /// - Returns: true if restored from saved state, false if needs fresh discovery
    public func switchSpace(onScreenWindowIDs: Set<UInt32>) -> Bool {
        // Save current space
        saveCurrentSpace()

        // Update fingerprint
        currentSpaceFingerprint = onScreenWindowIDs

        // Check if we have saved state for this space
        if let saved = savedSpaces[onScreenWindowIDs] {
            // Restore saved state
            strip.columns = saved.columns
            strip.columnData = saved.columnData
            strip.activeColumnIndex = saved.activeColumnIndex
            strip.viewOffset = saved.viewOffset
            windowMap = saved.windowMap
            apps = saved.apps
            lastCommittedFrames.removeAll()  // Force re-apply

            applyLayout()
            return true
        }

        // New space — clear for fresh discovery
        strip.columns.removeAll()
        strip.columnData.removeAll()
        strip.activeColumnIndex = 0
        strip.viewOffset = .static(0)
        windowMap.removeAll()
        apps.removeAll()
        lastCommittedFrames.removeAll()
        focusRing.hide()
        return false
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
    let activeColumnIndex: Int
    let viewOffset: ViewOffset
    let windowMap: [TileID: AXWindow]
    let apps: [pid_t: AXApp]
    let lastCommittedFrames: [TileID: CGRect]
}
