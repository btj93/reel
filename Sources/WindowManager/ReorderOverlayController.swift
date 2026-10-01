import AppKit
import Core
import CoreGraphics
import ScreenCaptureKit

// MARK: - ReorderOverlayController

/// Brain of the drag-to-reorder overlay. Manages screenshot capture, cursor tracking,
/// insertion index computation, the isReady buffer, and animation orchestration.
///
/// Threading model: all methods are main-actor isolated; capture suspends for ScreenCaptureKit.
@MainActor
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
        // 0. A multi-second press can outlive the layout it started on: focus
        //    hotkeys, IPC commands and the 500ms health check can all remove columns
        //    between mouse-down and drag-begin. The caller already computes this
        //    condition for its own tile lookup but still passes the raw index, and
        //    `columns[draggedIndex]` below would trap.
        guard draggedIndex >= 0, draggedIndex < columns.count else { return }

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

        let capturedColumns = [columns[draggedIndex]] + self.nonDraggedColumns
        let capturedStyle = thumbnailStyle
        let capturedThumbnailHeight = thumbnailHeight

        Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            let screenshots = await withTaskGroup(of: (Int, CGImage?).self) { group in
                if capturedStyle == "screenshot" {
                    for (index, column) in capturedColumns.enumerated() {
                        let windowID = column.windowID
                        group.addTask { (index, await Self.captureWindow(windowID: windowID)) }
                    }
                }
                var images = Array<CGImage?>(repeating: nil, count: capturedColumns.count)
                for await (index, image) in group { images[index] = image }
                return images
            }
            let thumbnails = capturedColumns.enumerated().map { index, col in
                let aspectRatio = col.frameWidth > 0 && col.frameHeight > 0
                    ? col.frameWidth / col.frameHeight
                    : 1.0
                let image = screenshots[index].map {
                    Self.scaleImage($0, toHeight: capturedThumbnailHeight)
                } ?? col.appIcon
                return (image: image, width: capturedThumbnailHeight * aspectRatio)
            }

            guard self.generation == myGeneration, self.overlayWindow === window else { return }
            let draggedResult = thumbnails[0]
            let nonDraggedResults = Array(thumbnails.dropFirst())

            window.configureThumbnails(
                thumbnails: nonDraggedResults,
                draggedThumbnail: draggedResult.image,
                draggedWidth: draggedResult.width
            )

            window.layoutThumbnails(spreadIndex: nil)
            let initialGapIndex = self.mapToThumbnailGapIndex(self.draggedIndex)
            window.showIndicator(atGapIndex: initialGapIndex)
            window.orderFront(nil)
            window.animateEntrance()

            self.isReady = true
            let buffered = self.bufferedCursorPositions
            self.bufferedCursorPositions = []
            for pos in buffered { self.processUpdateCursor(position: pos) }
            if self.pendingCommit {
                self.pendingCommit = false
                self.commitDrop()
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

    // MARK: - Private: captureWindow

    nonisolated private static func captureWindow(windowID: CGWindowID) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
            return try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: SCStreamConfiguration()
            )
        } catch {
            return nil
        }
    }

    // MARK: - Private: scaleImage

    /// Scales a CGImage proportionally to the target height, returning an NSImage.
    private static func scaleImage(_ cgImage: CGImage, toHeight targetHeight: Double) -> NSImage {
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
