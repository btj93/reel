import AppKit
import CoreGraphics
import Core

/// One left-button event or an Escape press, in CG coordinates. `modifier` says the required modifier was held.
public enum MouseEvent: Sendable {
    case down(CGPoint, modifier: Bool)
    case dragged(CGPoint)
    case up(CGPoint)
    case escape
}

/// What the tap does with a `MouseEvent`: deliver it, swallow it, or deliver a press at the point before this release.
public enum MouseVerdict: Equatable, Sendable {
    case pass
    case swallow
    case replay(CGPoint)
}

@MainActor
public final class TitleBarInteraction {
    static let reelSentinel: Int64 = 0x5245454C

    enum State {
        case idle
        case armed(columnIndex: Int, tileID: TileID, mousePoint: CGPoint, timer: DispatchWorkItem)
        case dragging(columnIndex: Int, tileID: TileID)
        case menu(columnIndex: Int, tileID: TileID)
    }

    private(set) var state: State = .idle

    // Config
    public var longPressDelayMs: Int = 300
    public var dragThresholdPx: Double = 5.0
    public var titleBarHeight: Double = 28.0
    /// Horizontal inset at each end of the title-bar hit region, reserved for macOS's
    /// native corner-resize. Events that land within this inset pass through so the
    /// window manager doesn't steal top-corner resize from vanilla macOS.
    public var titleBarCornerInsetPx: Double = 8.0
    /// Modifier that must be held for title-bar drag/long-press to activate.
    public var requiredModifier: CGEventFlags = .maskSecondaryFn

    // Callbacks
    public var onNeedsManagedFrames: (() -> (frames: [TileID: CGRect], primaryScreenHeight: CGFloat))?
    public var onNeedsTileColumnIndex: ((TileID) -> Int?)?
    public var onDragBegin: ((Int) -> Void)?
    public var onDragUpdate: ((CGPoint) -> Void)?
    public var onDragEnd: ((Int) -> Void)?
    public var onDragCancel: (() -> Void)?
    public var onMenuShow: ((Int, CGPoint) -> Void)?
    public var onMenuSelect: ((Int) -> Void)?
    public var onMenuDismiss: (() -> Void)?
    /// Fires on any non-modifier leftMouseDown that lands inside a tracked
    /// tile's full frame. Used to recover the "click an already-AX-focused
    /// window to re-center it" path — AX doesn't emit kAXFocusedWindowChanged
    /// when the clicked window is already its app's focused window, so the
    /// strip would otherwise not know to slide the column into view.
    public var onWindowFrameClick: ((TileID) -> Void)?

    /// When set, every left-button event and every Escape press while the Escape tap runs go here instead of the state
    /// machine below.
    public var onMouse: ((MouseEvent) -> MouseVerdict)?

    // Event taps
    var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    var escapeEventTap: CFMachPort?
    private var escapeRunLoopSource: CFRunLoopSource?

    // Overlay
    public let overlay = OverlayWindow()

    public init() {}

    // MARK: - Start / Stop

    @discardableResult
    public func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: titleBarCallback,
            userInfo: userInfo
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        return true
    }

    public func stop() {
        teardownEscapeTap()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        overlay.destroy()
    }

    // MARK: - Escape Key Tap

    private func setupEscapeTap() {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: escapeCallback,
            userInfo: userInfo
        ) else { return }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.escapeEventTap = tap
        self.escapeRunLoopSource = source
    }

    private func teardownEscapeTap() {
        if let tap = escapeEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = escapeRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        escapeEventTap = nil
        escapeRunLoopSource = nil
    }

    // MARK: - Event Handling

    func handleMouseEvent(_ event: CGEvent, type: CGEventType) -> CGEvent? {
        if event.getIntegerValueField(.eventSourceUserData) == Self.reelSentinel {
            return event
        }

        let location = event.location

        if let onMouse {
            let verdict: MouseVerdict = switch type {
            case .leftMouseDown: onMouse(.down(location, modifier: event.flags.contains(requiredModifier)))
            case .leftMouseDragged: onMouse(.dragged(location))
            case .leftMouseUp: onMouse(.up(location))
            default: .pass
            }
            switch verdict {
            case .pass: return event
            case .swallow: return nil
            case .replay(let point): return replay(event, pressAt: point)
            }
        }

        switch type {
        case .leftMouseDown:
            return handleMouseDown(event: event, location: location)
        case .leftMouseDragged:
            return handleMouseDragged(event: event, location: location)
        case .leftMouseUp:
            return handleMouseUp(event: event, location: location)
        default:
            return event
        }
    }

    private func handleMouseDown(event: CGEvent, location: CGPoint) -> CGEvent? {
        guard case .idle = state else { return event }

        let info = onNeedsManagedFrames?()

        // Non-modifier click: fire onWindowFrameClick only when macOS itself
        // reports the click went to a tracked tile. We use the event's
        // `mouseEventWindowUnderMousePointer` field (the window number macOS
        // chose as the click target) rather than a geometric hit-test, because
        // floating PIP-style windows (Arc PIP, AVKit PIP) use
        // CAWindowSharingType.readWriteOnTop and do NOT appear in
        // CGWindowListCopyWindowInfo — a CGWindowList z-order check would skip
        // them and falsely report the tracked tile beneath as topmost. The
        // mouseEventWindowUnderMousePointer field is set by the window server
        // and reflects the actual hit, so PIP clicks correctly return the
        // PIP's wid (which won't match any tracked TileID, so we no-op).
        //
        // Fn-modified clicks fall through to the title-bar drag/menu logic
        // below and should NOT also fire this — re-centering during drag init
        // would fight the user's intent.
        if !event.flags.contains(requiredModifier),
           let onWindowFrameClick,
           let frames = info?.frames
        {
            let widUnderRaw = event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
            // Field is 0 when the click didn't land on any window (e.g. menu
            // bar gap, between displays). Frame containment is still required
            // as a sanity check — if our last-known frame says the wid isn't
            // where we think it is, skip rather than scroll to the wrong place.
            if widUnderRaw > 0,
               let widUnder = UInt32(exactly: widUnderRaw)
            {
                let candidate = TileID(widUnder)
                if let frame = frames[candidate], frame.contains(location) {
                    onWindowFrameClick(candidate)
                }
            }
        }

        guard event.flags.contains(requiredModifier) else { return event }
        guard let info else { return event }

        guard let (columnIndex, tileID) = hitTestTitleBar(
            cgPoint: location,
            frames: info.frames
        ) else { return event }

        let timer = DispatchWorkItem { [weak self] in
            self?.transitionToMenu(columnIndex: columnIndex, tileID: tileID, mousePoint: location)
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(longPressDelayMs),
            execute: timer
        )

        state = .armed(columnIndex: columnIndex, tileID: tileID, mousePoint: location, timer: timer)
        return nil
    }

    private func handleMouseDragged(event: CGEvent, location: CGPoint) -> CGEvent? {
        switch state {
        case .armed(let columnIndex, let tileID, let startPoint, let timer):
            let dx = location.x - startPoint.x
            let dy = location.y - startPoint.y
            let distance = sqrt(dx * dx + dy * dy)
            if distance > dragThresholdPx {
                timer.cancel()
                transitionToDragging(columnIndex: columnIndex, tileID: tileID)
            }
            return nil

        case .dragging:
            // CGEvent.location is CG coordinates (top-left origin) — pass directly
            onDragUpdate?(location)
            return nil

        case .menu:
            // Convert CG to AppKit screen coords for NSView hit-testing
            let appKitPoint: NSPoint
            if let info = onNeedsManagedFrames?() {
                appKitPoint = NSPoint(x: location.x, y: info.primaryScreenHeight - location.y)
            } else {
                appKitPoint = NSPoint(x: location.x, y: location.y)
            }
            if let index = overlay.pillIndexAt(point: appKitPoint) {
                overlay.highlightPill(at: index)
            } else {
                overlay.highlightPill(at: nil)
            }
            return nil

        case .idle:
            return event
        }
    }

    private func handleMouseUp(event: CGEvent, location: CGPoint) -> CGEvent? {
        switch state {
        case .armed(_, _, let startPoint, let timer):
            timer.cancel()
            state = .idle
            return replay(event, pressAt: startPoint)

        case .dragging(let columnIndex, _):
            teardownEscapeTap()
            overlay.hide()
            onDragEnd?(columnIndex)
            state = .idle
            return nil

        case .menu:
            teardownEscapeTap()
            // Convert CG to AppKit for pill hit-testing
            let appKitPoint: NSPoint
            if let info = onNeedsManagedFrames?() {
                appKitPoint = NSPoint(x: location.x, y: info.primaryScreenHeight - location.y)
            } else {
                appKitPoint = NSPoint(x: location.x, y: location.y)
            }
            if let index = overlay.pillIndexAt(point: appKitPoint) {
                onMenuSelect?(index)
            } else {
                onMenuDismiss?()
            }
            overlay.hide()
            state = .idle
            return nil

        case .idle:
            return event
        }
    }

    /// Return the synthetic mouseDown from the callback (delivered first) and post the real mouseUp for later delivery
    /// (delivered second). Returning the mouseUp and posting the mouseDown async delivered mouseUp before mouseDown,
    /// which broke button tracking (buttons stuck in pressed state).
    private func replay(_ up: CGEvent, pressAt point: CGPoint) -> CGEvent {
        guard let syntheticDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point,
                                          mouseButton: .left) else { return up }
        syntheticDown.setIntegerValueField(.eventSourceUserData, value: Self.reelSentinel)
        up.post(tap: .cghidEventTap)
        return syntheticDown
    }

    /// Run the Escape tap only while a press, drag or menu is live, so keystrokes pay nothing otherwise.
    public func setEscapeTap(_ enabled: Bool) {
        if enabled, escapeEventTap == nil { setupEscapeTap() }
        if !enabled, escapeEventTap != nil { teardownEscapeTap() }
    }

    func handleEscapeKey() {
        teardownEscapeTap()
        switch state {
        case .dragging:
            onDragCancel?()
            overlay.hide()
        case .menu:
            onMenuDismiss?()
            overlay.hide()
        default:
            break
        }
        state = .idle
    }

    // MARK: - State Transitions

    /// Screen containing the cursor, or main as fallback. Used so the overlay
    /// panel sizes/positions to the monitor where the user is actually clicking.
    private func screenUnderCursor() -> NSScreen? {
        let loc = NSEvent.mouseLocation  // AppKit coords
        return NSScreen.screens.first(where: { $0.frame.contains(loc) })
            ?? NSScreen.main
    }

    private func transitionToDragging(columnIndex: Int, tileID: TileID) {
        state = .dragging(columnIndex: columnIndex, tileID: tileID)
        setupEscapeTap()
        if let screen = screenUnderCursor() {
            overlay.ensurePanel(for: screen)
        }
        overlay.setMousePassthrough(true)
        overlay.show()
        onDragBegin?(columnIndex)
    }

    private func transitionToMenu(columnIndex: Int, tileID: TileID, mousePoint: CGPoint) {
        state = .menu(columnIndex: columnIndex, tileID: tileID)
        setupEscapeTap()
        if let screen = screenUnderCursor() {
            overlay.ensurePanel(for: screen)
        }
        overlay.setMousePassthrough(false)
        onMenuShow?(columnIndex, mousePoint)
    }

    // MARK: - Helpers

    private func hitTestTitleBar(
        cgPoint: CGPoint,
        frames: [TileID: CGRect]
    ) -> (columnIndex: Int, tileID: TileID)? {
        let hits = frames.filter { Self.titleBarContains(cgPoint, frame: $0.value, height: titleBarHeight, cornerInset: titleBarCornerInsetPx) }
        for tileID in hits.keys {
            if let colIdx = onNeedsTileColumnIndex?(tileID) {
                return (colIdx, tileID)
            }
        }
        return nil
    }

    /// The title bar is the top `height` of `frame`, less `cornerInset` at each end, where macOS's native corner
    /// resize must keep working.
    public nonisolated static func titleBarContains(_ point: CGPoint, frame: CGRect, height: Double, cornerInset: Double) -> Bool {
        let inset = min(cornerInset, frame.width / 2)
        return CGRect(x: frame.minX + inset, y: frame.minY, width: max(0, frame.width - inset * 2), height: height).contains(point)
    }

    public func cancelIfActive() {
        switch state {
        case .dragging, .menu:
            handleEscapeKey()
        case .armed(_, _, _, let timer):
            timer.cancel()
            state = .idle
        case .idle:
            break
        }
    }
}

// MARK: - C Callbacks

// CGEvent taps run synchronously on the main run loop; the callback verifies that executor.
private struct EventCallbackInput: @unchecked Sendable {
    let event: CGEvent
    let userInfo: UnsafeMutableRawPointer?
}

// Unmanaged preserves the C callback's pass-through ownership across assumeIsolated.
private struct EventCallbackOutput: @unchecked Sendable {
    let event: Unmanaged<CGEvent>?
}

private func titleBarCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let input = EventCallbackInput(event: event, userInfo: userInfo)
    return MainActor.assumeIsolated {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let userInfo = input.userInfo {
                let handler = Unmanaged<TitleBarInteraction>.fromOpaque(userInfo).takeUnretainedValue()
                if let tap = handler.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            // The incoming event is +0, so pass it through unretained. Retaining it would
            // leak a reference the framework never balances (#21).
            return EventCallbackOutput(event: .passUnretained(input.event))
        }
        guard let userInfo = input.userInfo else {
            return EventCallbackOutput(event: .passUnretained(input.event))
        }
        let handler = Unmanaged<TitleBarInteraction>.fromOpaque(userInfo).takeUnretainedValue()
        guard let result = handler.handleMouseEvent(input.event, type: type) else {
            return EventCallbackOutput(event: nil)
        }
        // The same input event is +0; a synthetic mouseDown is +1 and must be retained.
        // Compare identity to return each with the ownership the event tap expects.
        let output = result === input.event ? Unmanaged.passUnretained(input.event) : .passRetained(result)
        return EventCallbackOutput(event: output)
    }.event
}

private func escapeCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let input = EventCallbackInput(event: event, userInfo: userInfo)
    return MainActor.assumeIsolated {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let userInfo = input.userInfo {
                let handler = Unmanaged<TitleBarInteraction>.fromOpaque(userInfo).takeUnretainedValue()
                if let tap = handler.escapeEventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            return EventCallbackOutput(event: .passUnretained(input.event))
        }
        guard let userInfo = input.userInfo else {
            return EventCallbackOutput(event: .passUnretained(input.event))
        }
        let handler = Unmanaged<TitleBarInteraction>.fromOpaque(userInfo).takeUnretainedValue()
        if input.event.getIntegerValueField(.keyboardEventKeycode) == 0x35 {
            if let onMouse = handler.onMouse, onMouse(.escape) == .pass {
                return EventCallbackOutput(event: .passUnretained(input.event))
            }
            if handler.onMouse == nil { handler.handleEscapeKey() }
            return EventCallbackOutput(event: nil)
        }
        return EventCallbackOutput(event: .passUnretained(input.event))
    }.event
}
