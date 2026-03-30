import AppKit
import CoreGraphics
import Foundation
import Core

/// Draws a colored border around the focused window using a transparent overlay NSWindow.
/// This is the focus indicator — essential for knowing which window is active on the strip.
public final class FocusRing: @unchecked Sendable {
    private var overlayWindow: NSWindow?

    /// Border color (default: system accent blue).
    public var color: NSColor = .systemBlue

    /// Border width in points.
    public var width: CGFloat = 3

    /// Corner radius.
    public var cornerRadius: CGFloat = 10

    public init() {}

    // MARK: - Show / Hide / Update

    /// Show the focus ring around the given frame.
    public func show(around frame: CGRect) {
        // Create the overlay window if needed
        if overlayWindow == nil {
            let window = NSWindow(
                contentRect: .zero,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .floating
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]

            let view = FocusRingView()
            window.contentView = view

            overlayWindow = window
        }

        guard let window = overlayWindow,
              let view = window.contentView as? FocusRingView else { return }

        // Inset the overlay to draw the border around (not inside) the window
        let inset = width + 2
        let overlayFrame = CGRect(
            x: frame.minX - inset,
            y: frame.minY - inset,
            width: frame.width + inset * 2,
            height: frame.height + inset * 2
        )

        view.borderColor = color
        view.borderWidth = width
        view.cornerRadius = cornerRadius + inset
        view.innerRect = CGRect(
            x: inset,
            y: inset,
            width: frame.width,
            height: frame.height
        )

        window.setFrame(overlayFrame, display: false)
        view.needsDisplay = true
        window.orderFrontRegardless()
    }

    /// Hide the focus ring.
    public func hide() {
        overlayWindow?.orderOut(nil)
    }

    /// Update position without recreating the window.
    public func update(frame: CGRect) {
        show(around: frame)
    }
}

/// Custom NSView that draws a rounded rectangle border.
private class FocusRingView: NSView {
    var borderColor: NSColor = .systemBlue
    var borderWidth: CGFloat = 3
    var cornerRadius: CGFloat = 12
    var innerRect: CGRect = .zero

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.clear(bounds)

        // Draw the border as a rounded rect path
        let borderRect = CGRect(
            x: innerRect.minX - borderWidth / 2,
            y: innerRect.minY - borderWidth / 2,
            width: innerRect.width + borderWidth,
            height: innerRect.height + borderWidth
        )

        let path = CGPath(
            roundedRect: borderRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        context.setStrokeColor(borderColor.cgColor)
        context.setLineWidth(borderWidth)
        context.addPath(path)
        context.strokePath()
    }
}
