import AppKit
import CoreGraphics

// MARK: - ColumnInfo

/// Data describing a column for the reorder overlay.
public struct ColumnInfo {
    public let index: Int
    public let windowID: CGWindowID
    public let pid: pid_t
    public let appName: String
    public let appIcon: NSImage
    public let frameWidth: Double
    public let frameHeight: Double

    public init(
        index: Int,
        windowID: CGWindowID,
        pid: pid_t,
        appName: String,
        appIcon: NSImage,
        frameWidth: Double,
        frameHeight: Double
    ) {
        self.index = index
        self.windowID = windowID
        self.pid = pid
        self.appName = appName
        self.appIcon = appIcon
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
    }
}

// MARK: - ReorderOverlayWindow

/// HUD band window for drag-to-reorder. Purely visual — all input is handled by the CGEvent tap
/// in TitleBarInteraction. This window ignores mouse events.
public final class ReorderOverlayWindow: NSWindow {

    // MARK: - Layout constants

    private let bandHeight: Double
    private let thumbnailHeight: Double

    /// Gap between thumbnail images. Settable before or after configureThumbnails.
    public var thumbnailGap: Double = 12.0

    // MARK: - Subviews

    /// Vibrancy container that fills the window.
    private let vibrancyView: NSVisualEffectView

    /// Holds the row of thumbnail NSImageViews.
    private let containerView: NSView

    /// Ghost image — the dragged column's thumbnail at 80% opacity.
    private let ghostView: NSImageView

    /// 3px-wide vertical indicator line in systemBlue.
    private let indicatorLine: NSView

    /// Downward-pointing triangle arrow below the indicator line.
    private let indicatorArrow: NSView

    // MARK: - State

    /// The thumbnail NSImageViews created by configureThumbnails.
    private var thumbnailViews: [NSImageView] = []

    /// Per-thumbnail logical widths (used for layout math).
    private var thumbnailWidths: [Double] = []

    /// Width of the dragged ghost thumbnail.
    private var ghostWidth: Double = 0

    // MARK: - Init

    /// - Parameters:
    ///   - screenFrame: The full NSScreen frame (AppKit coordinates) for the display.
    ///   - thumbnailHeight: Height of each thumbnail image in the band.
    public init(screenFrame: CGRect, thumbnailHeight: Double) {
        self.thumbnailHeight = thumbnailHeight
        self.bandHeight = thumbnailHeight + 40

        // Window frame: full screen width, band height, vertically centered on screen.
        let windowFrame = CGRect(
            x: screenFrame.minX,
            y: screenFrame.midY - bandHeight / 2,
            width: screenFrame.width,
            height: bandHeight
        )

        // --- NSVisualEffectView (vibrancy) ---
        let effectView = NSVisualEffectView(frame: CGRect(origin: .zero, size: windowFrame.size))
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true
        vibrancyView = effectView

        // --- containerView ---
        let container = NSView(frame: CGRect(origin: .zero, size: windowFrame.size))
        container.wantsLayer = true
        containerView = container

        // --- ghostView ---
        let ghost = NSImageView(frame: .zero)
        ghost.imageScaling = .scaleAxesIndependently
        ghost.wantsLayer = true
        ghost.alphaValue = 0.8
        ghost.layer?.opacity = 0.8
        ghost.isHidden = true

        // Drop shadow on ghost
        let ghostShadow = NSShadow()
        ghostShadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        ghostShadow.shadowBlurRadius = 12
        ghostShadow.shadowOffset = NSSize(width: 0, height: -4)
        ghost.shadow = ghostShadow

        ghostView = ghost

        // --- indicatorLine ---
        let line = NSView(frame: .zero)
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.systemBlue.cgColor
        line.layer?.cornerRadius = 1.5
        line.isHidden = true
        indicatorLine = line

        // --- indicatorArrow ---
        let arrow = NSView(frame: CGRect(x: 0, y: 0, width: 12, height: 8))
        arrow.wantsLayer = true
        arrow.isHidden = true

        let arrowShape = CAShapeLayer()
        let arrowPath = CGMutablePath()
        arrowPath.move(to: CGPoint(x: 0, y: 8))
        arrowPath.addLine(to: CGPoint(x: 12, y: 8))
        arrowPath.addLine(to: CGPoint(x: 6, y: 0))
        arrowPath.closeSubpath()
        arrowShape.path = arrowPath
        arrowShape.fillColor = NSColor.systemBlue.cgColor
        arrow.layer?.addSublayer(arrowShape)
        arrowShape.frame = CGRect(x: 0, y: 0, width: 12, height: 8)
        indicatorArrow = arrow

        super.init(
            contentRect: windowFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Window properties
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .transient]

        // Make the window layer-backed
        contentView?.wantsLayer = true

        // Build view hierarchy
        contentView?.addSubview(vibrancyView)
        vibrancyView.addSubview(containerView)
        vibrancyView.addSubview(ghostView)
        vibrancyView.addSubview(indicatorLine)
        vibrancyView.addSubview(indicatorArrow)

        // Fill vibrancy view to window bounds
        vibrancyView.frame = CGRect(origin: .zero, size: windowFrame.size)
        vibrancyView.autoresizingMask = [.width, .height]
    }

    // MARK: - Thumbnail Configuration

    /// Creates NSImageViews for each thumbnail and sets up the ghost.
    /// Call this once before showing the overlay.
    ///
    /// - Parameters:
    ///   - thumbnails: Array of (image, width) pairs for the non-dragged columns.
    ///   - draggedThumbnail: The image for the column being dragged.
    ///   - draggedWidth: Logical width of the dragged column thumbnail.
    public func configureThumbnails(
        thumbnails: [(image: NSImage, width: Double)],
        draggedThumbnail: NSImage,
        draggedWidth: Double
    ) {
        // Remove old thumbnail views
        for view in thumbnailViews {
            view.removeFromSuperview()
        }
        thumbnailViews.removeAll()
        thumbnailWidths.removeAll()

        for (image, width) in thumbnails {
            let imageView = NSImageView(frame: .zero)
            imageView.image = image
            imageView.imageScaling = .scaleAxesIndependently
            imageView.wantsLayer = true

            // 6px corner radius, 1px white border at 15% opacity
            imageView.layer?.cornerRadius = 6
            imageView.layer?.masksToBounds = true
            imageView.layer?.borderWidth = 1
            imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor

            containerView.addSubview(imageView)
            thumbnailViews.append(imageView)
            thumbnailWidths.append(width)
        }

        // Configure ghost
        ghostWidth = draggedWidth
        ghostView.image = draggedThumbnail
        ghostView.layer?.cornerRadius = 6
        ghostView.layer?.masksToBounds = true
        ghostView.layer?.borderWidth = 1
        ghostView.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor

        let ghostHeight = thumbnailHeight
        ghostView.frame = CGRect(x: 0, y: 0, width: draggedWidth, height: ghostHeight)
        ghostView.isHidden = true
    }

    // MARK: - Layout

    /// Positions thumbnails centered in the band.
    ///
    /// - Parameter spreadIndex: When non-nil, an 8px gap is inserted on each side of that gap index.
    public func layoutThumbnails(spreadIndex: Int?) {
        guard !thumbnailViews.isEmpty else { return }

        let bandWidth = frame.width
        let count = thumbnailViews.count
        let gap = thumbnailGap

        // Total width = sum of all thumbnail widths + (count - 1) * gap + spread padding
        var totalWidth = thumbnailWidths.reduce(0, +) + Double(max(0, count - 1)) * gap

        // Spread padding: 8px on each side of the gap at spreadIndex
        let spreadPad: Double = 8
        if spreadIndex != nil {
            totalWidth += spreadPad * 2
        }

        var x = (bandWidth - totalWidth) / 2
        let y = (bandHeight - thumbnailHeight) / 2

        // spreadIndex is a gap index: 0 = before first, count = after last.
        // We add spreadPad on each side of that gap.

        // If spread is before the first thumbnail, add left pad at the start.
        if let si = spreadIndex, si == 0 {
            x += spreadPad
        }

        for (i, view) in thumbnailViews.enumerated() {
            view.frame = CGRect(x: x, y: y, width: thumbnailWidths[i], height: thumbnailHeight)
            x += thumbnailWidths[i]

            if i < count - 1 {
                x += gap
                // Spread padding around the gap between thumbnail i and i+1.
                // Gap index (i+1) corresponds to "insert before thumbnail i+1".
                if let si = spreadIndex, si == i + 1 {
                    x += spreadPad * 2
                }
            }
        }

        // If spread is after the last thumbnail, add right pad at the end (for totalWidth calculation only).
        // (No visual effect needed since there's no thumbnail after it.)
    }

    // MARK: - Hit Testing

    /// Returns the X midpoints between adjacent thumbnails for gap hit-testing.
    /// Result has `count + 1` elements: before first, between each pair, after last.
    /// Only the `count - 1` between-thumbnail midpoints are returned (between adjacent pairs).
    public func thumbnailMidpoints() -> [Double] {
        guard !thumbnailViews.isEmpty else { return [] }

        // For a single thumbnail, return its center X so the cursor can land on either side.
        if thumbnailViews.count == 1 {
            return [thumbnailViews[0].frame.midX]
        }

        var midpoints: [Double] = []
        for i in 0..<thumbnailViews.count - 1 {
            let leftMax = thumbnailViews[i].frame.maxX
            let rightMin = thumbnailViews[i + 1].frame.minX
            midpoints.append((leftMax + rightMin) / 2)
        }
        return midpoints
    }

    // MARK: - Ghost

    /// Positions the ghost image view centered at the given local point (in window coordinates).
    public func moveGhost(to localPoint: CGPoint) {
        let ghostHeight = thumbnailHeight
        ghostView.frame = CGRect(
            x: localPoint.x - ghostWidth / 2,
            y: localPoint.y - ghostHeight / 2,
            width: ghostWidth,
            height: ghostHeight
        )
        ghostView.isHidden = false
    }

    // MARK: - Indicator

    /// Positions the indicator at the gap before `index`.
    /// - If index <= 0: position at the left edge of the first thumbnail.
    /// - If index >= count: position at the right edge of the last thumbnail.
    /// - Otherwise: midpoint between thumbnails[index-1].maxX and thumbnails[index].minX.
    public func showIndicator(atGapIndex index: Int) {
        let indicatorX = indicatorXPosition(forGapIndex: index)

        let lineWidth: Double = 3
        let lineHeight = bandHeight * 0.7
        let lineY = (bandHeight - lineHeight) / 2
        indicatorLine.frame = CGRect(
            x: indicatorX - lineWidth / 2,
            y: lineY,
            width: lineWidth,
            height: lineHeight
        )

        let arrowWidth: Double = 12
        let arrowHeight: Double = 8
        indicatorArrow.frame = CGRect(
            x: indicatorX - arrowWidth / 2,
            y: lineY - arrowHeight - 2,
            width: arrowWidth,
            height: arrowHeight
        )

        indicatorLine.isHidden = false
        indicatorArrow.isHidden = false
    }

    /// Hides the indicator line and arrow.
    public func hideIndicator() {
        indicatorLine.isHidden = true
        indicatorArrow.isHidden = true
    }

    // MARK: - Animations

    /// Fade in the band (opacity 0→1, 200ms ease-out), scale up thumbnails (0.8→1.0 spring),
    /// and scale ghost to 1.05x.
    public func animateEntrance() {
        // Start transparent
        alphaValue = 0

        // Fade in the window
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }

        // Spring scale for each thumbnail (0.8 → 1.0)
        for view in thumbnailViews {
            guard let layer = view.layer else { continue }

            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.stiffness = 300
            spring.damping = 24.2
            spring.mass = 1.0
            spring.fromValue = 0.8
            spring.toValue = 1.0
            spring.duration = spring.settlingDuration
            spring.fillMode = .forwards
            spring.isRemovedOnCompletion = false

            layer.add(spring, forKey: "entranceScale")
            layer.setAffineTransform(CGAffineTransform(scaleX: 1.0, y: 1.0))
        }

        // Scale ghost to 1.05x
        if let ghostLayer = ghostView.layer {
            let ghostSpring = CASpringAnimation(keyPath: "transform.scale")
            ghostSpring.stiffness = 300
            ghostSpring.damping = 21
            ghostSpring.mass = 1.0
            ghostSpring.fromValue = 0.8
            ghostSpring.toValue = 1.05
            ghostSpring.duration = ghostSpring.settlingDuration
            ghostSpring.fillMode = .forwards
            ghostSpring.isRemovedOnCompletion = false

            ghostLayer.add(ghostSpring, forKey: "entranceScale")
            ghostLayer.setAffineTransform(CGAffineTransform(scaleX: 1.05, y: 1.05))
        }
    }

    /// Spring animates the indicator to a new gap position.
    public func animateIndicatorMove(toGapIndex index: Int) {
        let targetX = indicatorXPosition(forGapIndex: index)

        let lineWidth: Double = 3
        let lineHeight = bandHeight * 0.7
        let lineY = (bandHeight - lineHeight) / 2
        let newLineFrame = CGRect(
            x: targetX - lineWidth / 2,
            y: lineY,
            width: lineWidth,
            height: lineHeight
        )

        let arrowWidth: Double = 12
        let arrowHeight: Double = 8
        let newArrowFrame = CGRect(
            x: targetX - arrowWidth / 2,
            y: lineY - arrowHeight - 2,
            width: arrowWidth,
            height: arrowHeight
        )

        guard let lineLayer = indicatorLine.layer,
              let arrowLayer = indicatorArrow.layer else {
            indicatorLine.frame = newLineFrame
            indicatorArrow.frame = newArrowFrame
            return
        }

        // Animate position via CASpringAnimation on the layer's position.x
        let currentLineX = indicatorLine.frame.origin.x
        let currentArrowX = indicatorArrow.frame.origin.x

        let lineSpring = CASpringAnimation(keyPath: "position.x")
        lineSpring.stiffness = 400
        lineSpring.damping = 34
        lineSpring.mass = 1.0
        lineSpring.fromValue = currentLineX + lineWidth / 2
        lineSpring.toValue = targetX
        lineSpring.duration = lineSpring.settlingDuration

        let arrowSpring = CASpringAnimation(keyPath: "position.x")
        arrowSpring.stiffness = 400
        arrowSpring.damping = 34
        arrowSpring.mass = 1.0
        arrowSpring.fromValue = currentArrowX + arrowWidth / 2
        arrowSpring.toValue = targetX
        arrowSpring.duration = arrowSpring.settlingDuration

        lineLayer.add(lineSpring, forKey: "indicatorMove")
        arrowLayer.add(arrowSpring, forKey: "indicatorMove")

        // Update model layer frames
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        indicatorLine.frame = newLineFrame
        indicatorArrow.frame = newArrowFrame
        CATransaction.commit()
    }

    /// Spring animates the ghost to the target origin, scaling back to 1.0,
    /// then calls completion after the spring settles.
    public func animateGhostSettle(to targetOrigin: CGPoint, completion: @escaping () -> Void) {
        guard let ghostLayer = ghostView.layer else {
            ghostView.frame.origin = targetOrigin
            completion()
            return
        }

        // Scale back to 1.0
        let scaleSpring = CASpringAnimation(keyPath: "transform.scale")
        scaleSpring.stiffness = 300
        scaleSpring.damping = 21
        scaleSpring.mass = 1.0
        scaleSpring.fromValue = ghostLayer.presentation()?.value(forKeyPath: "transform.scale") ?? 1.05
        scaleSpring.toValue = 1.0
        scaleSpring.duration = scaleSpring.settlingDuration
        scaleSpring.fillMode = .forwards
        scaleSpring.isRemovedOnCompletion = false
        ghostLayer.add(scaleSpring, forKey: "ghostSettle")
        ghostLayer.setAffineTransform(.identity)

        // Position spring via frame update with animation
        let currentOrigin = ghostView.frame.origin
        let posSpring = CASpringAnimation(keyPath: "position")
        posSpring.stiffness = 300
        posSpring.damping = 21
        posSpring.mass = 1.0
        posSpring.fromValue = NSValue(point: CGPoint(
            x: currentOrigin.x + ghostWidth / 2,
            y: currentOrigin.y + thumbnailHeight / 2
        ))
        posSpring.toValue = NSValue(point: CGPoint(
            x: targetOrigin.x + ghostWidth / 2,
            y: targetOrigin.y + thumbnailHeight / 2
        ))
        posSpring.duration = posSpring.settlingDuration
        ghostLayer.add(posSpring, forKey: "ghostPosition")

        // Update model layer position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ghostView.frame = CGRect(
            origin: targetOrigin,
            size: CGSize(width: ghostWidth, height: thumbnailHeight)
        )
        CATransaction.commit()

        // Call completion after settling
        DispatchQueue.main.asyncAfter(deadline: .now() + posSpring.settlingDuration) {
            completion()
        }
    }

    /// Fades out the band (150ms ease-in), orders the window out, then calls completion.
    public func animateFadeOut(completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            completion()
        })
    }

    // MARK: - Settle Origin

    /// Computes where the ghost should land for the given gap index.
    /// The ghost is placed at the x position of where it would be inserted.
    ///
    /// - Gap index 0: before the first thumbnail.
    /// - Gap index n (n == count): after the last thumbnail.
    /// - Otherwise: between thumbnails[index-1] and thumbnails[index].
    public func settleOrigin(forGapIndex index: Int) -> CGPoint {
        let y = (bandHeight - thumbnailHeight) / 2

        if thumbnailViews.isEmpty {
            let x = (frame.width - ghostWidth) / 2
            return CGPoint(x: x, y: y)
        }

        if index <= 0 {
            // Land just to the left of the first thumbnail
            let x = thumbnailViews[0].frame.minX - ghostWidth - thumbnailGap
            return CGPoint(x: max(0, x), y: y)
        }

        if index >= thumbnailViews.count {
            // Land just to the right of the last thumbnail
            let x = thumbnailViews[thumbnailViews.count - 1].frame.maxX + thumbnailGap
            return CGPoint(x: x, y: y)
        }

        // Land in the gap between thumbnails[index-1] and thumbnails[index]
        let leftMax = thumbnailViews[index - 1].frame.maxX
        let rightMin = thumbnailViews[index].frame.minX
        let centerX = (leftMax + rightMin) / 2
        let x = centerX - ghostWidth / 2
        return CGPoint(x: x, y: y)
    }

    // MARK: - Private Helpers

    /// Computes the indicator X position for the given gap index.
    private func indicatorXPosition(forGapIndex index: Int) -> Double {
        guard !thumbnailViews.isEmpty else { return frame.width / 2 }

        if index <= 0 {
            return thumbnailViews[0].frame.minX - thumbnailGap / 2
        }

        if index >= thumbnailViews.count {
            return thumbnailViews[thumbnailViews.count - 1].frame.maxX + thumbnailGap / 2
        }

        let leftMax = thumbnailViews[index - 1].frame.maxX
        let rightMin = thumbnailViews[index].frame.minX
        return (leftMax + rightMin) / 2
    }
}
