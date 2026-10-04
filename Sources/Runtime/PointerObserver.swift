import AppKit
import Core
import Engine
import Foundation
import Platform

/// Turns the scroll and left-button taps into pointer inputs. The engine decides what each one does: an input it took
/// comes back with `consumeInput` and is swallowed, a press that stayed a click comes back with `replayPress`, and
/// anything else reaches the app.
@MainActor
public final class PointerObserver {
    public nonisolated static let titleBarHeight = 28.0
    public nonisolated static let cornerInset = 8.0

    private let scroll = GestureCapture()
    private let mouse = TitleBarInteraction()
    private let menu = OverlayWindow()
    private let world: () -> World
    private let send: (PointerInput, PointerToken?) -> [Effect]
    private let paused: () -> Bool
    private let log: (String) -> Void
    private let reorder: ReorderOverlay
    private var pills: [(item: PillItem, command: Command)] = []
    var modifier: CGEventFlags = .maskSecondaryFn {
        didSet { mouse.requiredModifier = modifier }
    }

    init(world: @escaping () -> World, paused: @escaping () -> Bool, send: @escaping (PointerInput, PointerToken?) -> [Effect],
         log: @escaping (String) -> Void) {
        self.world = world
        self.paused = paused
        self.send = send
        self.log = log
        reorder = ReorderOverlay(world: world, send: { _ = send($0, $1) }, log: log)
    }

    func start() {
        scroll.onScroll = { [weak self] event in MainActor.assumeIsolated { self?.handle(event) ?? false } }
        mouse.onMouse = { [weak self] event in self?.handle(event) ?? .pass }
        log("pointer: scroll tap=\(scroll.start()) mouse tap=\(mouse.start())")
    }

    func stop() {
        scroll.stop()
        mouse.stop()
        menu.destroy()
        reorder.show(.hidden)
    }

    func show(_ overlay: Overlay) {
        reorder.show(overlay)
        guard case .menu(let open) = overlay else {
            pills = []
            menu.hide()
            return
        }
        let world = world()
        let topology = world.topology
        let frame = world.frames[open.press.tile]?.frame ?? AXRect(CGRect(origin: open.press.origin.point, size: .zero))
        pills = Self.pills(presets: world.config.widthPresets, tile: open.press.tile)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint(open.press.origin, in: topology).point) }) ?? NSScreen.main {
            menu.ensurePanel(for: screen)
        }
        menu.setMousePassthrough(false)
        menu.mode = .menu(pills: pills.map(\.item), anchorFrame: Self.pillAnchor(press: open.press, frame: frame, in: topology),
                          selectedIndex: nil)
        menu.show()
        let targets = zip(pills, menu.pillFrames()).map { pill, frame in
            let point = axPoint(ScreenPoint(CGPoint(x: frame.midX, y: frame.midY)), in: topology).point
            return "\(pill.item.label)@\(Int(point.x)),\(Int(point.y))"
        }
        log("pointer: menu tile=\(open.press.tile.rawValue) pills=\(targets.joined(separator: ";"))")
    }

    /// The Escape tap runs only while a title-bar session is live.
    func sync(_ session: PointerSession?) {
        mouse.setEscapeTap(session?.press != nil)
    }

    private func handle(_ event: ScrollEvent) -> Bool {
        guard !paused(), let input = Self.scrollInput(event, modifier: modifier) else { return false }
        return send(.scroll(input), world().pointer?.token).contains { if case .consumeInput = $0 { true } else { false } }
    }

    private func handle(_ event: MouseEvent) -> MouseVerdict {
        guard !paused() else { return .pass }
        let input: PointerInput
        switch event {
        case .down(let point, let modifier):
            let hit = !modifier ? nil : world().frames.values.first {
                TitleBarInteraction.titleBarContains(point, frame: $0.frame.rect, height: Self.titleBarHeight, cornerInset: Self.cornerInset)
            }
            input = .press(hit?.tile, at: AXPoint(point))
        case .dragged(let point):
            if !pills.isEmpty { menu.highlightPill(at: pill(at: point)) }
            reorder.cursor(AXPoint(point))
            input = .drag(AXPoint(point))
        case .up(let point):
            input = pill(at: point).map { .choose(pills[$0].command) } ?? .release(AXPoint(point))
        case .escape:
            input = .cancel
        }
        var verdict = MouseVerdict.pass
        for effect in send(input, world().pointer?.token) {
            switch effect {
            case .consumeInput: if verdict == .pass { verdict = .swallow }
            case .replayPress(let origin): verdict = .replay(origin.point)
            default: break
            }
        }
        return verdict
    }

    private func pill(at point: CGPoint) -> Int? {
        pills.isEmpty ? nil : menu.pillIndexAt(point: screenPoint(AXPoint(point), in: world().topology).point)
    }

    public nonisolated static func pills(presets: [Double], tile: TileID) -> [(item: PillItem, command: Command)] {
        let widths = presets.enumerated().map { index, share in
            let label = switch share {
            case ...0.34: "Third"
            case ...0.51: "Half"
            case ...0.68: "Two-Thirds"
            default: "\(Int(share * 100))%"
            }
            return (PillItem(label: label, isActive: false, isEnabled: true), Command.setWidthPreset(tile, index))
        }
        return widths + [
            (PillItem(label: "Full", isActive: false, isEnabled: true), .toggleFullWidth(tile)),
            (PillItem(label: "Float", isActive: false, isEnabled: true), .toggleFloating(tile)),
            (PillItem(label: "Close", isActive: false, isEnabled: true), .close(tile)),
        ]
    }

    /// The pill bar hangs from the bottom of the pressed tile's title bar, centred on the press, in AppKit global
    /// coordinates.
    public nonisolated static func pillAnchor(press: TitlePress, frame: AXRect, in topology: Topology) -> CGRect {
        let point = screenPoint(AXPoint(CGPoint(x: press.origin.point.x, y: frame.rect.minY + titleBarHeight)), in: topology)
        return CGRect(origin: point.point, size: .zero)
    }

    /// Scroll units become strip points: a trackpad's deltas double and flip so a swipe drags the strip with the
    /// fingers, a wheel notch moves the view by its dominant delta, and a shift-converted wheel counts as horizontal.
    /// Phases that start nothing (may-begin) are not the engine's.
    public nonisolated static func scrollInput(_ event: ScrollEvent, modifier: CGEventFlags) -> ScrollInput? {
        let held = event.flags.contains(modifier)
        let at = AXPoint(event.location)
        if event.momentumPhase != 0 { return ScrollInput(phase: event.momentumPhase == 3 ? .momentumEnded : .momentum, modifier: held, at: at) }
        let shifted = event.flags.contains(.maskShift) && event.continuous && event.phase == 0
        if !event.continuous || shifted {
            guard shifted || abs(event.dx) >= abs(event.dy) else { return ScrollInput(phase: .discrete, dy: event.dy, modifier: held, at: at) }
            return ScrollInput(phase: .discrete, dx: -(abs(event.dx) >= abs(event.dy) ? event.dx : event.dy), modifier: held, at: at)
        }
        let phase: ScrollPhase
        switch event.phase {
        case 1: phase = .began
        case 2: phase = .changed
        case 4: phase = .ended
        case 8: phase = .cancelled
        default: return nil
        }
        return ScrollInput(phase: phase, dx: -2 * event.dx, dy: -2 * event.dy, modifier: held, at: at)
    }
}
