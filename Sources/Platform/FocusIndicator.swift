import AppKit
import CoreGraphics
import Foundation
import Core
import Config

/// Draws a focus indicator around the active window.
/// Supports four styles: none, ring (animated border), raise (AX raise), flash (brief color pulse).
public final class FocusIndicator: @unchecked Sendable {
    private var overlayWindow: NSWindow?

    // MARK: - Config-driven properties

    public private(set) var style: FocusIndicatorConfig.Style = .ring
    public private(set) var color: NSColor = .controlAccentColor
    public private(set) var width: CGFloat = 3
    public private(set) var cornerRadius: CGFloat = 10

    // MARK: - Animation state

    /// Current animated frame (AppKit coordinates). nil when hidden or never shown.
    public private(set) var currentFrame: CGRect?

    /// Per-axis springs for ring-mode frame animation.
    private var springX: SpringAnimation?
    private var springY: SpringAnimation?
    private var springW: SpringAnimation?
    private var springH: SpringAnimation?

    /// Opacity easing for flash-mode fade-out.
    private var flashEasing: EasingAnimation?

    /// Opacity easing for fadeOut() — used when an unmanaged app becomes frontmost.
    private var fadeOutEasing: EasingAnimation?

    /// Spring params (injected from config, matches scroll animation).
    public var springParams: SpringParams = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)

    /// True when any animation is in flight — used by StripController.isFullySettled.
    public var isAnimating: Bool {
        springX != nil || flashEasing != nil || fadeOutEasing != nil
    }

    public init() {}

    // MARK: - Config

    public func reloadConfig(_ config: FocusIndicatorConfig) {
        let oldStyle = style
        let newStyle = config.style

        // Style-transition teardown
        if oldStyle != newStyle {
            switch oldStyle {
            case .ring:
                springX = nil; springY = nil; springW = nil; springH = nil
                fadeOutEasing = nil
                destroyOverlay()
                currentFrame = nil
            case .flash:
                flashEasing = nil
                fadeOutEasing = nil
                destroyOverlay()
                currentFrame = nil
            case .raise, .none:
                break
            }

            // Incoming teardown
            switch newStyle {
            case .raise, .none:
                destroyOverlay()
            case .ring, .flash:
                break // created on demand
            }
        }

        style = newStyle
        color = NSColor.from(configString: config.color)
        width = CGFloat(config.width)
        cornerRadius = CGFloat(config.cornerRadius)

        // Update overlay appearance if it exists
        if let view = overlayWindow?.contentView as? FocusIndicatorView {
            view.borderColor = color
            view.borderWidth = width
            view.cornerRadius = cornerRadius
            view.needsDisplay = true
        }
    }

    // MARK: - Public API

    /// Snap overlay to frame instantly. Returns true if an animation was started (flash mode only).
    @discardableResult
    public func snapTo(frame: CGRect) -> Bool {
        guard style == .ring || style == .flash else { return false }

        // Kill any frame springs
        springX = nil; springY = nil; springW = nil; springH = nil

        currentFrame = frame
        positionOverlay(at: frame)

        // Flash mode: start flash easing
        if style == .flash {
            flashEasing = EasingAnimation(
                from: 0.2, to: 0.0,
                startTime: TimeUtil.now(),
                duration: 0.2,
                curve: .easeOutCubic
            )
            overlayWindow?.alphaValue = 0.2
            return true
        }

        return false
    }

    /// Spring-animate overlay to frame. Returns true if an animation was started/retargeted.
    @discardableResult
    public func animateTo(frame: CGRect, at time: Double) -> Bool {
        guard style == .ring else {
            // Non-ring styles don't spring-animate frames
            return snapTo(frame: frame)
        }

        guard let current = currentFrame else {
            // Bootstrap: no current frame, snap instead
            return snapTo(frame: frame)
        }

        if let sx = springX {
            // Retarget existing springs
            springX = sx.retargeted(to: frame.minX, at: time)
            springY = springY!.retargeted(to: frame.minY, at: time)
            springW = springW!.retargeted(to: frame.width, at: time)
            springH = springH!.retargeted(to: frame.height, at: time)
        } else {
            // Create new springs
            springX = SpringAnimation(from: current.minX, to: frame.minX, initialVelocity: 0, startTime: time, params: springParams)
            springY = SpringAnimation(from: current.minY, to: frame.minY, initialVelocity: 0, startTime: time, params: springParams)
            springW = SpringAnimation(from: current.width, to: frame.width, initialVelocity: 0, startTime: time, params: springParams)
            springH = SpringAnimation(from: current.height, to: frame.height, initialVelocity: 0, startTime: time, params: springParams)
        }

        return true
    }

    /// Fade out the overlay (unmanaged app became frontmost). Returns true if animation started.
    @discardableResult
    public func fadeOut() -> Bool {
        guard style == .ring || style == .flash else { return false }
        guard overlayWindow != nil, currentFrame != nil else { return false }

        fadeOutEasing = EasingAnimation(
            from: 1.0, to: 0.0,
            startTime: TimeUtil.now(),
            duration: 0.15,
            curve: .easeOutCubic
        )
        return true
    }

    /// Advance animations by one frame. Call unconditionally at top of handleFrameTick.
    public func tick(time: Double) {
        // Evaluate frame springs (ring mode)
        if let sx = springX, let sy = springY, let sw = springW, let sh = springH {
            let x = sx.evaluate(at: time).value
            let y = sy.evaluate(at: time).value
            let w = sw.evaluate(at: time).value
            let h = sh.evaluate(at: time).value
            currentFrame = CGRect(x: x, y: y, width: w, height: h)
            positionOverlay(at: currentFrame!)

            // Nil on convergence
            if sx.isDone(at: time) && sy.isDone(at: time) && sw.isDone(at: time) && sh.isDone(at: time) {
                springX = nil; springY = nil; springW = nil; springH = nil
            }
        }

        // Evaluate flash easing (flash mode opacity)
        if let easing = flashEasing {
            let alpha = easing.evaluate(at: time)
            overlayWindow?.alphaValue = CGFloat(alpha)
            if easing.isDone(at: time) {
                flashEasing = nil
                overlayWindow?.orderOut(nil)
            }
        }

        // Evaluate fadeOut easing (any mode with overlay)
        if let easing = fadeOutEasing {
            let alpha = easing.evaluate(at: time)
            overlayWindow?.alphaValue = CGFloat(alpha)
            if easing.isDone(at: time) {
                fadeOutEasing = nil
                overlayWindow?.orderOut(nil)
                currentFrame = nil
            }
        }
    }

    /// Hide the indicator and clear all animation state.
    public func hide() {
        switch style {
        case .ring:
            springX = nil; springY = nil; springW = nil; springH = nil
            fadeOutEasing = nil
            overlayWindow?.orderOut(nil)
            currentFrame = nil
        case .flash:
            flashEasing = nil
            fadeOutEasing = nil
            overlayWindow?.orderOut(nil)
            currentFrame = nil
        case .raise, .none:
            break
        }
    }

    // MARK: - Overlay management

    private func ensureOverlay() {
        guard overlayWindow == nil else { return }
        guard style == .ring || style == .flash else { return }

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
        window.collectionBehavior = [.transient]

        let view = FocusIndicatorView()
        view.borderColor = color
        view.borderWidth = width
        view.cornerRadius = cornerRadius
        window.contentView = view

        overlayWindow = window
    }

    private func destroyOverlay() {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
    }

    private func positionOverlay(at frame: CGRect) {
        guard style == .ring || style == .flash else { return }

        ensureOverlay()
        guard let window = overlayWindow,
              let view = window.contentView as? FocusIndicatorView else { return }

        if style == .ring {
            // Ring: draw border around the window
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
            view.drawMode = .ring
            view.innerRect = CGRect(x: inset, y: inset, width: frame.width, height: frame.height)
            window.setFrame(overlayFrame, display: false)
        } else {
            // Flash: fill the window frame
            view.fillColor = color.withAlphaComponent(0.2)
            view.drawMode = .flash
            view.innerRect = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
            window.setFrame(frame, display: false)
        }

        view.needsDisplay = true
        window.alphaValue = fadeOutEasing != nil ? window.alphaValue : 1.0
        window.orderFrontRegardless()
    }
}

// MARK: - Drawing

/// Custom NSView that draws either a rounded rectangle border (ring) or a filled rect (flash).
private class FocusIndicatorView: NSView {
    enum DrawMode { case ring, flash }

    var drawMode: DrawMode = .ring
    var borderColor: NSColor = .controlAccentColor
    var borderWidth: CGFloat = 3
    var cornerRadius: CGFloat = 12
    var innerRect: CGRect = .zero
    var fillColor: NSColor = .controlAccentColor

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)

        switch drawMode {
        case .ring:
            let borderRect = CGRect(
                x: innerRect.minX - borderWidth / 2,
                y: innerRect.minY - borderWidth / 2,
                width: innerRect.width + borderWidth,
                height: innerRect.height + borderWidth
            )
            let path = CGPath(roundedRect: borderRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            context.setStrokeColor(borderColor.cgColor)
            context.setLineWidth(borderWidth)
            context.addPath(path)
            context.strokePath()

        case .flash:
            let path = CGPath(roundedRect: innerRect, cornerWidth: 8, cornerHeight: 8, transform: nil)
            context.setFillColor(fillColor.cgColor)
            context.addPath(path)
            context.fillPath()
        }
    }
}

// MARK: - Color Parsing

extension NSColor {
    /// Parse a config color string: "auto" → accent color, "#RGB" or "#RRGGBB" → hex.
    static func from(configString: String) -> NSColor {
        if configString == "auto" {
            return .controlAccentColor
        }

        var hex = configString
        if hex.hasPrefix("#") { hex = String(hex.dropFirst()) }

        // Expand "#RGB" → "#RRGGBB"
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }

        guard hex.count == 6, let value = UInt64(hex, radix: 16) else {
            #if DEBUG
            print("[FocusIndicator] Invalid color '\(configString)', falling back to accent color")
            fflush(stdout)
            #endif
            return .controlAccentColor
        }

        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }
}
