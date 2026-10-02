import AppKit
import Core
import CoreGraphics
import ScreenCaptureKit

// MARK: - ReorderOverlayController

// SCWindow is immutable metadata; concurrent capture tasks only read it.
private struct ThumbnailCaptureRequest: @unchecked Sendable {
    let index: Int
    let window: SCWindow
    let aspectRatio: Double
    let thumbnailHeight: Double
}

/// Brain of the drag-to-reorder overlay. Manages screenshot capture, cursor tracking,
/// insertion index computation, the isReady buffer, and animation orchestration.
///
/// Threading model: UI and session state are main-actor isolated; captures run in child tasks.
@MainActor
final class ReorderOverlayController {

    // MARK: - Public interface

    /// Called after ghost-settle + fade-out completes, with (sourceIndex, insertionIndex).
    var onCommit: ((Int, Int) -> Void)?

    // MARK: - Internal state

    private var overlayWindow: ReorderOverlayWindow?
    private var captureTask: Task<Void, Never>?
    private var readyDeadlineTask: Task<Void, Never>?
    private var columns: [ColumnInfo] = []
    private var draggedIndex: Int = 0
    private var insertionIndex: Int = 0
    private var isReady: Bool = false

    // Upper bound on trigger -> overlay showing every tile. The R1 perf gate (trunk p95 + 100 ms)
    // is measured on that span; tiles still missing a screenshot at the deadline show a
    // placeholder and are swapped in when their late capture lands.
    private static let thumbnailReadyDeadline: Duration = .milliseconds(300)

    /// When `show()` ran (the drag-threshold trigger). The logger has no timestamps, so every
    /// `[ReorderOverlay]` line carries `elapsedMs` measured from here.
    private var triggerInstant = ContinuousClock.now

    /// Screenshots keyed by position in `[dragged] + nonDragged`. Filled as each capture
    /// finishes; tiles without an entry show a placeholder until a late capture lands.
    private var thumbnailImages: [Int: CGImage] = [:]

    /// Set when the user released before the async thumbnail capture finished.
    /// The drop is completed from the capture completion instead of being computed
    /// against geometry that does not exist yet.
    private var pendingCommit: Bool = false
    private var bufferedCursorPositions: [CGPoint] = []

    /// Monotonic session id. Bumped on every `show()`. A background capture stamps the
    /// generation it was launched under; its main-thread completion is discarded unless
    /// the counter still matches, so a slow capture from a superseded drag can never
    /// install its thumbnails or flip `isReady` over a newer session.
    private var generation: Int = 0
    private var screenFrame: CGRect = .zero
    private var primaryScreenHeight: Double = 0
    private var thumbnailStyle: String = "screenshot"
    private var thumbnailHeight: Double = 160
    private var nonDraggedColumns: [ColumnInfo] = []

    // MARK: - show()

    /// Shows the drag-to-reorder overlay band; cursor events are buffered during capture.
    /// - Parameters:
    ///   - columns: All columns in current strip order.
    ///   - draggedIndex: Index of the column being dragged.
    ///   - screenFrame: NSScreen frame in AppKit coordinates for the display.
    ///   - primaryScreenHeight: Height of the primary screen for CG↔AppKit Y-flip.
    ///   - thumbnailStyle: `"screenshot"` or `"icon"`.
    ///   - thumbnailHeight: Height of each thumbnail in the overlay band.
    ///   - gap: Gap between thumbnails.
    func show(
        columns: [ColumnInfo],
        draggedIndex: Int,
        screenFrame: CGRect,
        primaryScreenHeight: Double,
        thumbnailStyle: String,
        thumbnailHeight: Double,
        gap: Double
    ) {
        // 0. A multi-second press can outlive the layout it started on: focus
        //    hotkeys, IPC commands and the 500ms health check can all remove columns
        //    between mouse-down and drag-begin. The caller already computes this
        //    condition for its own tile lookup but still passes the raw index, and
        //    `columns[draggedIndex]` below would trap.
        guard draggedIndex >= 0, draggedIndex < columns.count else { return }

        triggerInstant = .now
        log("trigger columns=\(columns.count) dragged=\(draggedIndex) style=\(thumbnailStyle)")

        captureTask?.cancel()
        readyDeadlineTask?.cancel()
        captureTask = nil
        readyDeadlineTask = nil

        // 1. Tear down any existing overlay immediately (handles drag-during-fade-out).
        if let existing = overlayWindow {
            existing.orderOut(nil)
            overlayWindow = nil
        }

        // 2. Store parameters, reset readiness, clear buffered positions.
        //    Bump the generation first so any capture still in flight from a previous
        //    show() is stamped as stale and its completion will be rejected below.
        generation += 1
        let myGeneration = generation
        self.columns = columns
        self.draggedIndex = draggedIndex
        self.insertionIndex = draggedIndex
        self.screenFrame = screenFrame
        self.primaryScreenHeight = primaryScreenHeight
        self.thumbnailStyle = thumbnailStyle
        self.thumbnailHeight = thumbnailHeight
        self.isReady = false
        self.thumbnailImages = [:]
        self.bufferedCursorPositions = []
        // A superseded drag must not auto-commit into this new session.
        self.pendingCommit = false

        // 3. Build nonDraggedColumns (all columns except the dragged one).
        self.nonDraggedColumns = columns.enumerated().compactMap { i, col in
            i == draggedIndex ? nil : col
        }

        // 4. Create the overlay window.
        let window = ReorderOverlayWindow(screenFrame: screenFrame, thumbnailHeight: thumbnailHeight)
        window.thumbnailGap = gap
        self.overlayWindow = window

        guard thumbnailStyle == "screenshot" else {
            installThumbnails(generation: myGeneration, reason: "icon")
            return
        }

        let capturedColumns = orderedColumns
        let capturedThumbnailHeight = thumbnailHeight
        captureTask = Task { @MainActor [weak self] in
            let content: SCShareableContent?
            do {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                content = nil
                self?.logFallback("capture-unavailable", generation: myGeneration, detail: "error=\"\(error)\"")
            }
            guard !Task.isCancelled else { return }
            let windows = Dictionary((content?.windows ?? []).map { ($0.windowID, $0) },
                                     uniquingKeysWith: { first, _ in first })
            let requests = capturedColumns.enumerated().compactMap { index, column -> ThumbnailCaptureRequest? in
                guard let window = windows[column.windowID] else {
                    if content != nil {
                        self?.logFallback("window-missing", generation: myGeneration,
                                          detail: "index=\(index) windowID=\(column.windowID)")
                    }
                    return nil
                }
                return ThumbnailCaptureRequest(index: index, window: window,
                                               aspectRatio: column.aspectRatio,
                                               thumbnailHeight: capturedThumbnailHeight)
            }
            await withTaskGroup(of: (Int, CGImage?).self) { group in
                for request in requests {
                    group.addTask { await Self.captureWindow(request) }
                }
                for await (index, image) in group {
                    if let image {
                        self?.receiveThumbnail(image, at: index, generation: myGeneration)
                    } else if !Task.isCancelled {
                        self?.logFallback("capture-failed", generation: myGeneration, detail: "index=\(index)")
                    }
                }
            }
            self?.installThumbnails(generation: myGeneration, reason: "captures")
        }
        readyDeadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.thumbnailReadyDeadline)
            guard !Task.isCancelled else { return }
            self?.logFallback("deadline", generation: myGeneration, detail: "deadline=\(Self.thumbnailReadyDeadline)")
            self?.installThumbnails(generation: myGeneration, reason: "deadline")
        }
    }

    // MARK: - updateCursor(position:)

    /// Routes cursor position updates. Buffered until the overlay is ready (all captures
    /// landed or the thumbnail deadline passed), then replayed.
    /// Position is in CG screen coordinates (top-left origin).
    func updateCursor(position: CGPoint) {
        if isReady {
            processUpdateCursor(position: position)
        } else {
            bufferedCursorPositions.append(position)
        }
    }

    // MARK: - commitDrop()

    /// Fires the commit immediately, then fades the overlay out.
    ///
    /// We intentionally do NOT animate the ghost to the overlay's band-centered gap
    /// before committing: that target doesn't correspond to where the dropped column
    /// actually lands on the strip, so the user saw the ghost "settle in the wrong
    /// spot, then at the last instant the real windows snapped to the right place."
    /// By firing `onCommit` up front, the real windows rearrange while the ghost
    /// simply fades in place from the cursor's release position.
    func commitDrop() {
        // Released before the capture landed: thumbnailMidpoints() is still empty, so
        // computeInsertionIndex would resolve every buffered cursor sample to the last
        // gap — a fast drag would commit a confidently wrong index (previously it
        // committed the unchanged one and the drag silently did nothing). Defer.
        //
        // Deliberately does NOT bump `generation`: that would make the in-flight
        // capture fail its own guard, so isReady would never flip and this deferred
        // commit would never run.
        // No live session at all (show() bailed on a vanished column, or the overlay
        // was already torn down). Fire immediately: deferring here would strand
        // `pendingCommit` forever, and with it the caller's `isReorderPending` flag,
        // which gates IPC focus commands.
        guard let window = overlayWindow else {
            pendingCommit = false
            onCommit?(draggedIndex, insertionIndex)
            return
        }

        guard isReady else {
            pendingCommit = true
            return
        }
        generation += 1   // ready path only: retire this session
        captureTask?.cancel()
        captureTask = nil
        thumbnailImages = [:]

        onCommit?(draggedIndex, insertionIndex)

        window.animateFadeOut { [weak self] in
            self?.overlayWindow = nil
        }
    }

    // MARK: - cancel()

    /// Cancels the overlay. Nils `onCommit` first so any in-flight animation cannot fire it.
    func cancel() {
        // CRITICAL: nil out onCommit before anything else so a late-firing completion
        // from an in-progress animateGhostSettle cannot call moveColumn.
        onCommit = nil
        captureTask?.cancel()
        readyDeadlineTask?.cancel()
        captureTask = nil
        readyDeadlineTask = nil
        thumbnailImages = [:]
        // Retire the session so an in-flight capture landing before the fade
        // completes cannot orderFront a dead overlay, and drop any deferred commit
        // from an abandoned drag.
        generation += 1
        pendingCommit = false

        if let window = overlayWindow {
            // Animate ghost back to its original position, then fade out.
            let originalGapIndex = mapToThumbnailGapIndex(draggedIndex)
            let returnOrigin = window.settleOrigin(forGapIndex: originalGapIndex)
            window.animateGhostSettle(to: returnOrigin) { [weak self] in
                window.animateFadeOut { [weak self] in
                    self?.overlayWindow = nil
                }
            }
        } else {
            overlayWindow = nil
        }
    }

    // MARK: - Private: processUpdateCursor

    private func processUpdateCursor(position: CGPoint) {
        guard let window = overlayWindow else { return }

        // Convert CG screen coordinates (top-left origin) → overlay-local AppKit coordinates
        // (bottom-left origin, relative to the overlay window's frame).
        let appKitScreenY = primaryScreenHeight - position.y
        let localX = position.x - window.frame.minX
        let localY = appKitScreenY - window.frame.minY

        // Move the ghost image to follow the cursor.
        window.moveGhost(to: CGPoint(x: localX, y: localY))

        // Recompute insertion index.
        let newIndex = computeInsertionIndex(cursorLocalX: localX)
        if newIndex != insertionIndex {
            insertionIndex = newIndex
            let gapIndex = mapToThumbnailGapIndex(newIndex)
            window.animateIndicatorMove(toGapIndex: gapIndex)
            window.layoutThumbnails(spreadIndex: gapIndex)
        }
    }

    // MARK: - Private: computeInsertionIndex

    /// Translates a cursor X position (in overlay-local coordinates) to an insertion index
    /// in the *original* column array (i.e., the index where the dragged column would land).
    private func computeInsertionIndex(cursorLocalX: Double) -> Int {
        let midpoints = overlayWindow?.thumbnailMidpoints() ?? []
        let nonDraggedIndices = nonDraggedColumns.map { $0.index }
        return computeReorderInsertionIndex(
            cursorX: cursorLocalX,
            thumbnailMidpoints: midpoints,
            nonDraggedOriginalIndices: nonDraggedIndices,
            draggedIndex: draggedIndex,
            columnCount: columns.count
        )
    }

    // MARK: - Private: mapToThumbnailGapIndex

    /// Maps an original-column-space insertion index to a gap index in the non-dragged thumbnail array.
    /// The gap index is the number of non-dragged columns whose original index is less than `originalIndex`.
    private func mapToThumbnailGapIndex(_ originalIndex: Int) -> Int {
        var count = 0
        for i in 0..<originalIndex {
            if i != draggedIndex {
                count += 1
            }
        }
        return count
    }

    private func log(_ message: String) {
        let c = triggerInstant.duration(to: .now).components
        let ms = Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
        print("[ReorderOverlay] \(message) elapsedMs=\(String(format: "%.1f", ms))")
    }

    /// Fallback lines are dropped for a superseded session so they never pollute the new drag's timing.
    private func logFallback(_ reason: String, generation: Int, detail: String) {
        guard self.generation == generation else { return }
        log("fallback reason=\(reason) \(detail)")
    }

    private var orderedColumns: [ColumnInfo] { [columns[draggedIndex]] + nonDraggedColumns }

    private func tileImage(_ image: CGImage, for column: ColumnInfo) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: thumbnailHeight * column.aspectRatio, height: thumbnailHeight))
    }

    private func receiveThumbnail(_ image: CGImage, at index: Int, generation: Int) {
        guard self.generation == generation else { return }
        thumbnailImages[index] = image
        if thumbnailImages.count == orderedColumns.count {
            log("all-tiles tiles=\(thumbnailImages.count) ready=\(isReady)")
        }
        guard isReady else { return }
        overlayWindow?.replaceThumbnail(at: index, with: tileImage(image, for: orderedColumns[index]))
    }

    private func installThumbnails(generation: Int, reason: String) {
        guard self.generation == generation, !isReady, let window = overlayWindow else { return }
        readyDeadlineTask?.cancel()
        readyDeadlineTask = nil

        let thumbnails = orderedColumns.enumerated().map { index, column in
            let screenshot = thumbnailImages[index]
            let placeholder = thumbnailStyle == "screenshot" && screenshot == nil
            let image = screenshot.map { tileImage($0, for: column) } ?? column.appIcon
            return (image: image, width: thumbnailHeight * column.aspectRatio, isPlaceholder: placeholder)
        }
        let placeholders = thumbnails.filter(\.isPlaceholder).count
        log("ready tiles=\(thumbnails.count) images=\(thumbnailImages.count) placeholders=\(placeholders) reason=\(reason)")
        let draggedResult = thumbnails[0]
        window.configureThumbnails(
            thumbnails: Array(thumbnails.dropFirst()),
            draggedThumbnail: draggedResult.image,
            draggedWidth: draggedResult.width,
            draggedIsPlaceholder: draggedResult.isPlaceholder
        )

        window.layoutThumbnails(spreadIndex: nil)
        let initialGapIndex = mapToThumbnailGapIndex(draggedIndex)
        window.showIndicator(atGapIndex: initialGapIndex)
        window.orderFront(nil)
        window.animateEntrance()

        isReady = true
        let buffered = bufferedCursorPositions
        bufferedCursorPositions = []
        for position in buffered { processUpdateCursor(position: position) }
        if pendingCommit {
            pendingCommit = false
            commitDrop()
        }
    }

    nonisolated private static func captureWindow(
        _ request: ThumbnailCaptureRequest
    ) async -> (Int, CGImage?) {
        guard !Task.isCancelled else { return (request.index, nil) }
        let filter = SCContentFilter(desktopIndependentWindow: request.window)
        let scale = Double(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((request.thumbnailHeight * request.aspectRatio * scale).rounded()))
        configuration.height = max(1, Int((request.thumbnailHeight * scale).rounded()))
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        do {
            return (request.index, try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ))
        } catch {
            return (request.index, nil)
        }
    }
}
