import AppKit
import Core
import Engine
import Foundation
import ScreenCaptureKit

// SCWindow is immutable metadata; capture tasks only read it.
private struct CaptureRequest: @unchecked Sendable {
    let tile: TileID
    let window: SCWindow
    let size: CGSize
}

/// The drag-to-reorder band, driven by the session's `reorder` overlay. It shows the strip's columns on the display
/// the drag began over, tells the engine when it is ready, and answers a released drag with the gap under the cursor.
/// Cursor samples before it is ready only keep the latest one, which is all the gap and the ghost need.
@MainActor
public final class ReorderOverlay {
    nonisolated static let thumbnailHeight = 160.0
    nonisolated static let spacing = 12.0
    public nonisolated static let readyDeadline: Duration = .milliseconds(300)

    private let world: () -> World
    private let send: (PointerInput, PointerToken) -> Void
    private let log: (String) -> Void
    private var request: ReorderRequest?
    private var panel: NSPanel?
    private var thumbnails: [NSImageView] = []
    private let ghost = NSImageView()
    private let indicator = NSView()
    private var tiles: [TileID] = []
    private var widths: [Double] = []
    private var dragged = 0
    private var midpoints: [Double] = []
    private var ready = false
    private var answered = false
    private var latest: AXPoint?
    private var gap = 0
    private var started = ContinuousClock.now
    private var tasks: [Task<Void, Never>] = []

    init(world: @escaping () -> World, send: @escaping (PointerInput, PointerToken) -> Void, log: @escaping (String) -> Void) {
        self.world = world
        self.send = send
        self.log = log
    }

    func show(_ overlay: Overlay) {
        guard case .reorder(let next) = overlay else { return hide() }
        guard next.session == request?.session else {
            hide()
            return begin(next)
        }
        request = next
        if next.released, ready { answer() }
    }

    func cursor(_ point: AXPoint) {
        guard request != nil else { return }
        latest = point
        if ready { move(to: point) }
    }

    private func begin(_ next: ReorderRequest) {
        let world = world()
        let columns = world.groups[next.scope.group]?.strip.columns ?? []
        tiles = columns.compactMap { $0.activeTile ?? $0.tiles.first }
        guard let index = columns.firstIndex(where: { $0.tiles.contains(next.tile) }),
              let display = world.topology.displays.first(where: { $0.id == next.display }) else {
            return post(.cancel, next.session)
        }
        request = next
        dragged = index
        ready = false
        answered = false
        latest = nil
        gap = index
        started = .now
        widths = tiles.map { tile in
            let frame = world.frames[tile]?.frame.rect ?? .zero
            return Self.thumbnailHeight * (frame.height > 0 ? min(3, max(0.3, frame.width / frame.height)) : 1.6)
        }
        let frame = screenRect(AXRect(display.frame), in: world.topology).rect
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .transient]
        panel.isReleasedWhenClosed = false
        let band = NSVisualEffectView(frame: Self.band(in: frame.size))
        band.material = .hudWindow
        band.state = .active
        band.wantsLayer = true
        band.layer?.cornerRadius = 12
        panel.contentView?.addSubview(band)
        let icons = tiles.map { tile in
            world.owner(of: tile).flatMap { world.groups[$0]?.windows[tile]?.pid }
                .flatMap { NSRunningApplication(processIdentifier: $0)?.icon }
        }
        thumbnails = tiles.indices.map { index in
            let view = NSImageView(image: icons[index] ?? NSImage())
            view.imageScaling = .scaleProportionallyUpOrDown
            if index != dragged { panel.contentView?.addSubview(view) }
            return view
        }
        ghost.image = thumbnails[dragged].image
        ghost.imageScaling = .scaleProportionallyUpOrDown
        ghost.alphaValue = 0.8
        ghost.frame = CGRect(x: 0, y: 0, width: widths[dragged], height: Self.thumbnailHeight)
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        panel.contentView?.addSubview(indicator)
        panel.contentView?.addSubview(ghost)
        self.panel = panel
        layout()
        log("reorder: trigger session=\(next.session.rawValue) tiles=\(tiles.count) dragged=\(index) display=\(display.id)")
        let session = next.session
        tasks = [
            Task { [weak self] in
                try? await Task.sleep(for: Self.readyDeadline)
                self?.becomeReady(session, reason: "deadline")
            },
            Task { [weak self] in
                await self?.capture(session, scale: Double(NSScreen.main?.backingScaleFactor ?? 2))
                self?.becomeReady(session, reason: "captures")
            },
        ]
    }

    private func capture(_ session: PointerToken, scale: Double) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return log("reorder: capture unavailable, icons stand in")
        }
        let windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let requests = zip(tiles, widths).compactMap { tile, width in
            windows[tile.rawValue].map { CaptureRequest(tile: tile, window: $0, size: CGSize(width: width * scale, height: Self.thumbnailHeight * scale)) }
        }
        await withTaskGroup(of: (TileID, CGImage?).self) { group in
            for request in requests { group.addTask { await Self.capture(request) } }
            for await (tile, image) in group {
                guard request?.session == session, let image, let index = tiles.firstIndex(of: tile) else { continue }
                thumbnails[index].image = NSImage(cgImage: image, size: NSSize(width: widths[index], height: Self.thumbnailHeight))
                if index == dragged { ghost.image = thumbnails[index].image }
            }
        }
    }

    nonisolated private static func capture(_ request: CaptureRequest) async -> (TileID, CGImage?) {
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(request.size.width.rounded()))
        configuration.height = max(1, Int(request.size.height.rounded()))
        configuration.scalesToFit = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: request.window),
                                                                configuration: configuration)
        return (request.tile, image)
    }

    /// Ready once every capture landed or the deadline passed, whichever is first; tiles still missing keep their icon.
    private func becomeReady(_ session: PointerToken, reason: String) {
        guard request?.session == session, !ready, let panel else { return }
        ready = true
        panel.orderFrontRegardless()
        post(.overlayReady, session)
        let band = Self.band(in: panel.frame.size)
        let slots = Self.slots(midpoints, bounds: band).enumerated().map { slot, x in "\(slot < dragged + 1 ? slot : slot + 1):\(Int(panel.frame.minX + x))" }
        log("reorder: ready session=\(session.rawValue) reason=\(reason) elapsedMs=\(Int(started.duration(to: .now) / .milliseconds(1))) "
            + "slots=\(slots.joined(separator: ",")) y=\(Int(world().topology.primaryScreenHeight - panel.frame.minY - band.midY))")
        if let latest { move(to: latest) }
        if request?.released == true { answer() }
    }

    private func answer() {
        guard let request, !answered else { return }
        answered = true
        log("reorder: drop session=\(request.session.rawValue) gap=\(gap)")
        post(.drop(gap), request.session)
    }

    /// Engine inputs leave on the next run-loop turn, never from inside the effects of the reduce that asked for this.
    private func post(_ input: PointerInput, _ session: PointerToken) {
        DispatchQueue.main.async { [send] in send(input, session) }
    }

    private func move(to point: AXPoint) {
        guard let panel else { return }
        let local = Self.local(point, panel: panel.frame, in: world().topology)
        ghost.setFrameOrigin(CGPoint(x: local.x - widths[dragged] / 2, y: local.y - Self.thumbnailHeight / 2))
        let others = tiles.indices.filter { $0 != dragged }
        let next = computeReorderInsertionIndex(cursorX: local.x, thumbnailMidpoints: midpoints, nonDraggedOriginalIndices: others,
                                                draggedIndex: dragged, columnCount: tiles.count)
        guard next != gap else { return }
        gap = next
        layout()
    }

    private func layout() {
        guard let panel else { return }
        let band = Self.band(in: panel.frame.size)
        let others = tiles.indices.filter { $0 != dragged }
        let row = Self.thumbnailFrames(widths: others.map { widths[$0] }, bandWidth: band.width, spacing: Self.spacing)
        let height = row.first?.height ?? Self.thumbnailHeight
        let y = band.midY - height / 2
        midpoints = row.map { band.minX + $0.midX }
        for (index, frame) in zip(others, row) {
            thumbnails[index].frame = frame.offsetBy(dx: band.minX, dy: y)
        }
        let slot = others.filter { $0 < gap }.count
        let x = slot == 0 ? (row.first?.minX ?? band.width / 2) / 2
            : slot == row.count ? ((row.last?.maxX ?? band.width / 2) + band.width) / 2
            : (row[slot - 1].maxX + row[slot].minX) / 2
        indicator.frame = CGRect(x: band.minX + x - 1.5, y: y - 10, width: 3, height: height + 20)
    }

    private func hide() {
        if let request { log("reorder: hide session=\(request.session.rawValue)") }
        tasks.forEach { $0.cancel() }
        tasks = []
        request = nil
        ready = false
        thumbnails.forEach { $0.removeFromSuperview() }
        thumbnails = []
        ghost.removeFromSuperview()
        indicator.removeFromSuperview()
        panel?.orderOut(nil)
        panel = nil
    }

    public nonisolated static func band(in size: CGSize) -> CGRect {
        let height = thumbnailHeight + 40
        return CGRect(x: 20, y: size.height - height - 40, width: max(0, size.width - 40), height: height)
    }

    /// A cursor x inside each gap between thumbnails centred at `midpoints`, the ends included.
    public nonisolated static func slots(_ midpoints: [Double], bounds: CGRect? = nil) -> [Double] {
        guard let first = midpoints.first, let last = midpoints.last else { return [] }
        return [bounds?.minX ?? first - 40] + zip(midpoints, midpoints.dropFirst()).map { ($0 + $1) / 2 } + [bounds?.maxX ?? last + 40]
    }

    public nonisolated static func origins(widths: [Double], bandWidth: Double, spacing: Double) -> [Double] {
        thumbnailFrames(widths: widths, bandWidth: bandWidth, spacing: spacing).map(\.minX)
    }

    /// One geometry drives the visible thumbnails, insertion thresholds and indicator. Edge gaps stay visible too.
    public nonisolated static func thumbnailFrames(widths: [Double], bandWidth: Double, spacing: Double) -> [CGRect] {
        let total = widths.reduce(0, +) + spacing * Double(max(0, widths.count - 1))
        let scale = min(1, max(0, bandWidth) / max(1, total + spacing * 2))
        var x = (bandWidth - total * scale) / 2
        return widths.map { width in
            defer { x += (width + spacing) * scale }
            return CGRect(x: x, y: 0, width: width * scale, height: thumbnailHeight * scale)
        }
    }

    /// A cursor in AX coordinates in the panel's own coordinates. The panel's origin is the display's AppKit origin,
    /// which is not zero on any display but the primary, so `NSView.convert(_:from: nil)` would be off by it.
    public nonisolated static func local(_ point: AXPoint, panel: CGRect, in topology: Topology) -> CGPoint {
        let screen = screenPoint(point, in: topology).point
        return CGPoint(x: screen.x - panel.minX, y: screen.y - panel.minY)
    }
}
