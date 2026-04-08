import AppKit
import CoreGraphics
import Core

public final class TitleBarInteraction: @unchecked Sendable {
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
        guard event.flags.contains(requiredModifier) else { return event }
        guard let info = onNeedsManagedFrames?() else { return event }

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
            // Overlay uses AppKit coords — convert for insertion indicator
            if let info = onNeedsManagedFrames?() {
                let appKitX = location.x
                overlay.mode = .minimap(insertionX: appKitX, dimAlpha: 0.4)
            }
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
            reInjectMouseDown(at: startPoint)
            state = .idle
            return event

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

    private func transitionToDragging(columnIndex: Int, tileID: TileID) {
        state = .dragging(columnIndex: columnIndex, tileID: tileID)
        setupEscapeTap()
        if let screen = NSScreen.main {
            overlay.ensurePanel(for: screen)
        }
        overlay.setMousePassthrough(true)
        overlay.mode = .minimap(insertionX: 0, dimAlpha: 0.4)
        overlay.show()
        onDragBegin?(columnIndex)
    }

    private func transitionToMenu(columnIndex: Int, tileID: TileID, mousePoint: CGPoint) {
        state = .menu(columnIndex: columnIndex, tileID: tileID)
        setupEscapeTap()
        if let screen = NSScreen.main {
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

        for (tileID, frame) in frames {
            let titleBarRect = CGRect(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.width,
                height: titleBarHeight
            )
            if titleBarRect.contains(cgPoint) {
                if let colIdx = onNeedsTileColumnIndex?(tileID) {
                    return (colIdx, tileID)
                }
            }
        }
        return nil
    }

    private func reInjectMouseDown(at point: CGPoint) {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.reelSentinel)
        event.post(tap: .cghidEventTap)
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

private func titleBarCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Handle tap disabled notification
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            let handler = Unmanaged<TitleBarInteraction>.fromOpaque(userInfo).takeUnretainedValue()
            if let tap = handler.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passRetained(event)
    }

    guard let userInfo = userInfo else { return Unmanaged.passRetained(event) }
    let handler = Unmanaged<TitleBarInteraction>.fromOpaque(userInfo).takeUnretainedValue()

    if let result = handler.handleMouseEvent(event, type: type) {
        return Unmanaged.passRetained(result)
    }
    return nil
}

private func escapeCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            let handler = Unmanaged<TitleBarInteraction>.fromOpaque(userInfo).takeUnretainedValue()
            if let tap = handler.escapeEventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passRetained(event)
    }

    guard let userInfo = userInfo else { return Unmanaged.passRetained(event) }
    let handler = Unmanaged<TitleBarInteraction>.fromOpaque(userInfo).takeUnretainedValue()

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    if keyCode == 0x35 {
        handler.handleEscapeKey()
        return nil
    }
    return Unmanaged.passRetained(event)
}
