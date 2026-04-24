import AppKit
import CoreGraphics

public enum OverlayMode {
    case hidden
    case menu(pills: [PillItem], anchorFrame: CGRect, selectedIndex: Int?)
}

public struct PillItem: Sendable {
    public let label: String
    public let isActive: Bool
    public let isEnabled: Bool

    public init(label: String, isActive: Bool, isEnabled: Bool) {
        self.label = label
        self.isActive = isActive
        self.isEnabled = isEnabled
    }
}

public class OverlayWindow {
    private var panel: NSPanel?
    private var overlayView: OverlayView?
    public var mode: OverlayMode = .hidden {
        didSet { updateDisplay() }
    }
    public var accentColor: NSColor = .systemBlue

    public func ensurePanel(for screen: NSScreen) {
        let targetFrame = NSRect(origin: .zero, size: screen.frame.size)
        if panel == nil {
            let p = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.level = .screenSaver
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .transient]
            let view = OverlayView(frame: targetFrame)
            p.contentView = view
            self.panel = p
            self.overlayView = view
        }
        panel?.setFrame(screen.frame, display: false)
        overlayView?.frame = targetFrame
    }

    public func show() {
        panel?.orderFront(nil)
        panel?.display()
    }

    public func hide() {
        mode = .hidden
        panel?.orderOut(nil)
    }

    public func destroy() {
        panel?.orderOut(nil)
        panel = nil
        overlayView = nil
    }

    public func setMousePassthrough(_ passthrough: Bool) {
        panel?.ignoresMouseEvents = passthrough
    }

    private func updateDisplay() {
        overlayView?.mode = mode
        overlayView?.accentColor = accentColor
        overlayView?.needsDisplay = true
    }

    public func pillIndexAt(point: NSPoint) -> Int? {
        guard case .menu(let pills, let anchorFrame, _) = mode else { return nil }
        return overlayView?.pillIndexAt(screenPoint: point, pills: pills, anchorFrame: anchorFrame)
    }

    public func highlightPill(at index: Int?) {
        if case .menu(let pills, let frame, _) = mode {
            mode = .menu(pills: pills, anchorFrame: frame, selectedIndex: index)
        }
    }
}

class OverlayView: NSView {
    var mode: OverlayMode = .hidden
    var accentColor: NSColor = .systemBlue

    private let pillHeight: CGFloat = 36
    private let pillPadding: CGFloat = 8
    private let pillSpacing: CGFloat = 6
    private let pillCornerRadius: CGFloat = 8
    private let containerPadding: CGFloat = 12
    private let containerCornerRadius: CGFloat = 12

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        switch mode {
        case .hidden:
            break

        case .menu(let pills, let anchorFrame, let selectedIndex):
            drawPillBar(ctx: ctx, pills: pills, anchorFrame: anchorFrame, selectedIndex: selectedIndex)
        }
    }

    /// anchorFrame is AppKit global coords (the cursor's position). Convert to
    /// this view's local coords so drawing lands in the right spot regardless
    /// of which screen the overlay window sits on.
    ///
    /// `convert(_:from: nil)` on an NSView converts from the *window*'s coord
    /// space, not AppKit-global screen space. Those only coincide when the
    /// window sits at (0,0) — the primary display. For any panel on a non-
    /// primary screen (e.g. an upper monitor in a stacked setup whose frame
    /// origin is > 0), we must go screen → window first. Since the overlay
    /// view fills the panel at local origin (0,0), window-local already equals
    /// view-local, so no further view-level conversion is needed.
    private func anchorInViewLocal(_ anchorFrame: CGRect) -> CGRect {
        guard let window = self.window else { return anchorFrame }
        return window.convertFromScreen(anchorFrame)
    }

    private func screenPointToViewLocal(_ screenPoint: NSPoint) -> NSPoint {
        guard let window = self.window else { return screenPoint }
        return window.convertPoint(fromScreen: screenPoint)
    }

    private func drawPillBar(ctx: CGContext, pills: [PillItem], anchorFrame: CGRect, selectedIndex: Int?) {
        guard !pills.isEmpty else { return }

        let localAnchor = anchorInViewLocal(anchorFrame)

        let pillWidths = pills.map { estimatePillWidth($0.label) }
        let totalPillWidth = pillWidths.reduce(0, +)
            + CGFloat(max(0, pills.count - 1)) * pillSpacing
        let containerWidth = totalPillWidth + containerPadding * 2
        let containerHeight = pillHeight + containerPadding * 2

        let containerX = localAnchor.midX - containerWidth / 2
        let containerY = localAnchor.minY - 8 - containerHeight
        let containerRect = CGRect(x: containerX, y: containerY, width: containerWidth, height: containerHeight)

        let bgColor = NSColor(white: 0.12, alpha: 0.92)
        ctx.setFillColor(bgColor.cgColor)
        let containerPath = CGPath(roundedRect: containerRect, cornerWidth: containerCornerRadius, cornerHeight: containerCornerRadius, transform: nil)
        ctx.addPath(containerPath)
        ctx.fillPath()

        var x = containerRect.minX + containerPadding
        let pillY = containerRect.minY + containerPadding

        for (i, pill) in pills.enumerated() {
            let w = pillWidths[i]
            let pillRect = CGRect(x: x, y: pillY, width: w, height: pillHeight)

            let isSelected = selectedIndex == i
            let pillBg: NSColor
            if pill.isActive || isSelected {
                pillBg = accentColor.withAlphaComponent(0.9)
            } else if !pill.isEnabled {
                pillBg = NSColor(white: 0.2, alpha: 0.3)
            } else {
                pillBg = NSColor(white: 0.2, alpha: 0.6)
            }
            ctx.setFillColor(pillBg.cgColor)
            ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: pillCornerRadius, cornerHeight: pillCornerRadius, transform: nil))
            ctx.fillPath()

            let textColor: NSColor = pill.isEnabled ? .white : NSColor(white: 1, alpha: 0.3)
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: textColor,
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
            ]
            let str = NSAttributedString(string: pill.label, attributes: attrs)
            let textSize = str.size()
            let textRect = CGRect(
                x: pillRect.midX - textSize.width / 2,
                y: pillRect.midY - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            )
            str.draw(in: textRect)

            x += w + pillSpacing
        }
    }

    private func estimatePillWidth(_ label: String) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        return max(60, size.width + 24)
    }

    func pillIndexAt(screenPoint: NSPoint, pills: [PillItem], anchorFrame: CGRect) -> Int? {
        let localPoint = screenPointToViewLocal(screenPoint)
        let localAnchor = anchorInViewLocal(anchorFrame)
        let pillWidths = pills.map { estimatePillWidth($0.label) }
        let totalPillWidth = pillWidths.reduce(0, +)
            + CGFloat(max(0, pills.count - 1)) * pillSpacing
        let containerWidth = totalPillWidth + containerPadding * 2
        let containerHeight = pillHeight + containerPadding * 2
        let containerX = localAnchor.midX - containerWidth / 2
        let containerY = localAnchor.minY - 8 - containerHeight

        var x = containerX + containerPadding
        let pillY = containerY + containerPadding

        for (i, _) in pills.enumerated() {
            let w = pillWidths[i]
            let pillRect = CGRect(x: x, y: pillY, width: w, height: pillHeight)
            if pillRect.contains(localPoint) && pills[i].isEnabled {
                return i
            }
            x += w + pillSpacing
        }
        return nil
    }
}
