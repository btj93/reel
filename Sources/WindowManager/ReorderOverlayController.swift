import AppKit
import Core
import CoreGraphics

// MARK: - ReorderOverlayController

/// Brain of the drag-to-reorder overlay. Manages screenshot capture, cursor tracking,
/// insertion index computation, the isReady buffer, and animation orchestration.
///
/// Threading model:
/// - `show()` is called on the main thread; screenshot capture runs on a background queue.
/// - All other public methods (`updateCursor`, `commitDrop`, `cancel`) are main thread.
/// - The `isReady` flag + `bufferedCursorPositions` handle the race between background
///   capture completing and cursor-move events arriving during capture.
final class ReorderOverlayController {

    // MARK: - Public interface

    /// Called after ghost-settle + fade-out completes, with (sourceIndex, insertionIndex).
    var onCommit: ((Int, Int) -> Void)?

    // MARK: - Internal state

    private var overlayWindow: ReorderOverlayWindow?
    private var columns: [ColumnInfo] = []
    private var draggedIndex: Int = 0
    private var insertionIndex: Int = 0
    private var isReady: Bool = false
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

    /// Shows the drag-to-reorder overlay band. Screenshots are captured on a background queue;
    /// cursor events arriving before capture finishes are buffered and replayed.
    ///
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
        self.bufferedCursorPositions = []

        // 3. Build nonDraggedColumns (all columns except the dragged one).
        self.nonDraggedColumns = columns.enumerated().compactMap { i, col in
            i == draggedIndex ? nil : col
        }

        // 4. Create the overlay window.
        let window = ReorderOverlayWindow(screenFrame: screenFrame, thumbnailHeight: thumbnailHeight)
        window.thumbnailGap = gap
        self.overlayWindow = window

        // 5. Snapshot every input the background capture needs into immutable locals.
        //    The capture block MUST NOT read self's stored properties: a re-entrant
        //    show() on the main thread reassigns columns / draggedIndex /
        //    nonDraggedColumns / thumbnailStyle, and an unsynchronized Array read racing
        //    a copy-on-write mutation is undefined behavior (torn buffer pointer, or an
        //    out-of-range index when the new strip has fewer columns).
        let capturedDraggedCol = columns[draggedIndex]
        let capturedNonDragged = self.nonDraggedColumns
        let capturedStyle = thumbnailStyle
        let capturedThumbnailHeight = thumbnailHeight

        // Keep a weak reference for the background block. Only the pure, stateless
        // helpers (captureWindow / scaleImage) are reached through self off the main
        // thread — never any stored property.
        weak var weakSelf = self
        weak var weakWindow = window

        // 6. Capture screenshots on background queue.
        DispatchQueue.global(qos: .userInitiated).async {
            guard let self = weakSelf else { return }

            /// Returns an NSImage for one column at the target thumbnail height.
            func makeThumbnail(for col: ColumnInfo) -> (image: NSImage, width: Double) {
                let aspectRatio = col.frameWidth > 0 && col.frameHeight > 0
                    ? col.frameWidth / col.frameHeight
                    : 1.0
                let scaledWidth = capturedThumbnailHeight * aspectRatio

                if capturedStyle == "screenshot",
                   let cgImage = self.captureWindow(windowID: col.windowID) {
                    // Scale immediately and release the raw CGImage.
                    let nsImage = self.scaleImage(cgImage, toHeight: capturedThumbnailHeight)
                    return (nsImage, scaledWidth)
                } else {
                    // Fall back to app icon.
                    let icon = col.appIcon
                    return (icon, scaledWidth)
                }
            }

            // Capture the dragged column's thumbnail.
            let draggedResult = makeThumbnail(for: capturedDraggedCol)

            // Capture non-dragged column thumbnails.
            let nonDraggedResults = capturedNonDragged.map { col in
                makeThumbnail(for: col)
            }

            // 7. Back on main thread: configure and show the overlay.
            DispatchQueue.main.async {
                guard let self = weakSelf, let window = weakWindow else { return }

                // Guard: reject a completion superseded by a newer show(). The generation
                // check and the window-identity check are belt-and-suspenders — either
                // alone rejects a stale capture, but together they make the intent
                // explicit: only the current session installs thumbnails and, crucially,
                // only it may flip isReady and drain bufferedCursorPositions (which now
                // belong to the newer session). A stale capture returns here without
                // touching either.
                guard self.generation == myGeneration else { return }
                guard self.overlayWindow === window else { return }

                window.configureThumbnails(
                    thumbnails: nonDraggedResults,
                    draggedThumbnail: draggedResult.image,
                    draggedWidth: draggedResult.width
                )

                // Lay out thumbnails without a spread gap initially.
                window.layoutThumbnails(spreadIndex: nil)

                // Position indicator at the initial insertion index (same as dragged position).
                let initialGapIndex = self.mapToThumbnailGapIndex(self.draggedIndex)
                window.showIndicator(atGapIndex: initialGapIndex)

                window.orderFront(nil)
                window.animateEntrance()

                // Mark ready, then replay buffered cursor positions.
                self.isReady = true
                let buffered = self.bufferedCursorPositions
                self.bufferedCursorPositions = []
                for pos in buffered {
                    self.processUpdateCursor(position: pos)
                }
            }
        }
    }

    // MARK: - updateCursor(position:)

    /// Routes cursor position updates. Buffered while screenshots are capturing.
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
        guard let window = overlayWindow else {
            onCommit?(draggedIndex, insertionIndex)
            return
        }

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

    // MARK: - Private: captureWindow

    private func captureWindow(windowID: CGWindowID) -> CGImage? {
        // Capture at nominal (1x) resolution: the result is downscaled to a ~160pt-tall
        // thumbnail anyway, so Retina .bestResolution just burns capture time and memory
        // (a 4K window at 2x is a ~130MB transient CGImage) that scaleImage throws away.
        CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .nominalResolution]
        )
    }

    // MARK: - Private: scaleImage

    /// Scales a CGImage proportionally to the target height, returning an NSImage.
    private func scaleImage(_ cgImage: CGImage, toHeight targetHeight: Double) -> NSImage {
        let srcWidth = Double(cgImage.width)
        let srcHeight = Double(cgImage.height)
        let aspectRatio = srcHeight > 0 ? srcWidth / srcHeight : 1.0
        let w = Int(targetHeight * aspectRatio)
        let h = Int(targetHeight)
        guard w > 0, h > 0,
              let ctx = CGContext(
                  data: nil, width: w, height: h,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        // .medium is ample for a small downscaled thumbnail and noticeably cheaper than
        // .high; the source is already near-1x after the nominal-resolution capture.
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        return NSImage(cgImage: scaled, size: NSSize(width: w, height: h))
    }
}
