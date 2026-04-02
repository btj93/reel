# Focus Indicator Enhancement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hardcoded FocusRing with a configurable FocusIndicator supporting four styles (none/ring/raise/flash), spring-animated transitions, and automatic hiding during Mission Control/Cmd-Tab.

**Architecture:** Single `FocusIndicator` class in Platform module with style switching, driven by FrameLoop ticks via `StripController`. Config parsed from `[focus_indicator]` TOML section. FrameLoop pause centralized in `WindowManager.onTick` to fix multi-display race.

**Tech Stack:** Swift, AppKit (NSWindow overlay), SpringAnimation/EasingAnimation from Core, TOMLKit config

**Spec:** `docs/superpowers/specs/2026-04-01-focus-indicator-design.md`

---

### Task 1: Add FocusIndicatorConfig and TOML parsing

**Files:**
- Modify: `Sources/Config/Config.swift`
- Modify: `config.default.toml`

- [ ] **Step 1: Add `FocusIndicatorConfig` struct to Config.swift**

Add after the `StrutsConfig` struct (after line 104):

```swift
/// Focus indicator configuration.
public struct FocusIndicatorConfig: Sendable {
    public enum Style: String, Sendable {
        case none, ring, raise, flash
    }
    public var style: Style = .ring
    public var color: String = "auto"    // "auto" or hex "#RRGGBB" / "#RGB"
    public var width: Double = 3
    public var cornerRadius: Double = 10

    public init() {}
}
```

- [ ] **Step 2: Add `focusIndicator` property to `ScrollWMConfig`**

Add in the `ScrollWMConfig` struct, after the `startAtLogin` property (after line 58):

```swift
    // MARK: - Focus Indicator

    public var focusIndicator: FocusIndicatorConfig = FocusIndicatorConfig()
```

- [ ] **Step 3: Add parsing logic in `parse()` method**

Add after the `start_at_login` parsing (after line 305 in the `parse` method):

```swift
        // [focus_indicator]
        if let fi = readTable(table["focus_indicator"]) {
            if let v = readString(fi["style"]) {
                if let style = FocusIndicatorConfig.Style(rawValue: v) {
                    config.focusIndicator.style = style
                } else {
                    #if DEBUG
                    print("[Config] Unknown focus_indicator style: \(v)")
                    fflush(stdout)
                    #endif
                }
            }
            if let v = readString(fi["color"]) { config.focusIndicator.color = v }
            if let v = readDouble(fi["width"]) { config.focusIndicator.width = v }
            if let v = readDouble(fi["corner_radius"]) { config.focusIndicator.cornerRadius = v }
        }
```

- [ ] **Step 4: Add `[focus_indicator]` section to `config.default.toml`**

Add after the `[gesture]` section (after line 46), before the window rules comments:

```toml

# Focus indicator: visual highlight for the active window
# [focus_indicator]
# style = "ring"        # "none", "ring", "raise", or "flash"
# color = "auto"        # "auto" (system accent) or hex "#RRGGBB" / "#RGB"
# width = 3             # border width in points (ring mode only)
# corner_radius = 10    # corner radius in points (ring mode only)
```

- [ ] **Step 5: Build and verify**

Run: `swift build`
Expected: Compiles with no errors.

- [ ] **Step 6: Commit**

```bash
git add Sources/Config/Config.swift config.default.toml
git commit -m "feat: add FocusIndicatorConfig struct and TOML parsing"
```

---

### Task 2: Create FocusIndicator class (rename and rewrite FocusRing)

**Files:**
- Rename: `Sources/Platform/FocusRing.swift` → `Sources/Platform/FocusIndicator.swift`

- [ ] **Step 1: Rename the file**

```bash
git mv Sources/Platform/FocusRing.swift Sources/Platform/FocusIndicator.swift
```

- [ ] **Step 2: Rewrite FocusIndicator.swift**

Replace the entire file contents with the new `FocusIndicator` class. Key changes from `FocusRing`:
- Add `style`, `springX/Y/W/H`, `flashEasing`, `fadeOutEasing`, `currentFrame` properties
- Change collection behavior from `[.canJoinAllSpaces, .stationary]` to `[.transient]`
- Add `snapTo(frame:) -> Bool`, `animateTo(frame:at:) -> Bool`, `fadeOut() -> Bool`
- Add `tick(time:)`, `hide()`, `reloadConfig()`, `isAnimating` property
- Keep the `FocusRingView` NSView subclass for drawing (used by ring and flash modes)
- Add `NSColor.from(configString:)` hex color parsing

```swift
import AppKit
import CoreGraphics
import Foundation
import Core

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
        if let view = overlayWindow?.contentView as? FocusRingView {
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
        guard style != .none else { return false }

        // Kill any frame springs
        springX = nil; springY = nil; springW = nil; springH = nil

        currentFrame = frame
        positionOverlay(at: frame)

        // Flash mode: start flash easing
        if style == .flash {
            flashEasing = EasingAnimation(
                from: 0.2, to: 0.0,
                startTime: CACurrentMediaTime(),
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
            startTime: CACurrentMediaTime(),
            duration: 0.15,
            curve: .easeOutCubic
        )
        return true
    }

    /// Advance animations by one frame. Call unconditionally at top of handleFrameTick.
    public func tick(time: Double) {
        // Evaluate frame springs (ring mode)
        if let sx = springX, let sy = springY, let sw = springW, let sh = springH {
            let x = sx.currentValue(at: time)
            let y = sy.currentValue(at: time)
            let w = sw.currentValue(at: time)
            let h = sh.currentValue(at: time)
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

        let view = FocusRingView()
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
              let view = window.contentView as? FocusRingView else { return }

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
private class FocusRingView: NSView {
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
```

- [ ] **Step 3: Build and verify**

Run: `swift build`
Expected: Build will fail because `StripController` and `WindowManager` still reference `FocusRing`. That's expected — we fix those in the next tasks.

- [ ] **Step 4: Commit**

```bash
git add Sources/Platform/FocusIndicator.swift
git commit -m "feat: create FocusIndicator class (rename FocusRing, add styles/animations)"
```

---

### Task 3: Update StripController — rename, wrappers, and updateFocusIndicator

**Files:**
- Modify: `Sources/WindowManager/StripController.swift`

This task replaces all `focusRing` references with `focusIndicator`, rewrites `updateFocusRing` → `updateFocusIndicator` with the snap/animate heuristic, adds wrapper methods, and the `lastRaisedTileID` guard.

- [ ] **Step 1: Replace property declaration and init**

At line 72-73, change:
```swift
    /// Focus ring overlay.
    public let focusRing: FocusRing
```
to:
```swift
    /// Focus indicator (ring/flash/raise/none).
    public let focusIndicator: FocusIndicator
```

At line 84, change:
```swift
        self.focusRing = FocusRing()
```
to:
```swift
        self.focusIndicator = FocusIndicator()
```

- [ ] **Step 2: Add new properties**

Add after the `focusIndicator` declaration:

```swift
    /// Latch: true once scroll+width have settled, reset on new animation.
    private var scrollWidthSettled: Bool = false

    /// Last tile we called AXWindow.raise() on — prevents 120Hz AX spam in raise style.
    private var lastRaisedTileID: TileID?
```

- [ ] **Step 3: Add `isFullySettled` computed property**

Add as a public computed property:

```swift
    /// True when all animations (scroll, width, focus indicator) have settled.
    public var isFullySettled: Bool {
        let time = TimeUtil.now()
        let scrollSettled = strip.viewOffset.isSettled(at: time)
        let widthSettled = !strip.columnData.contains(where: { $0.widthAnimation != nil })
        return scrollSettled && widthSettled && !focusIndicator.isAnimating
    }
```

- [ ] **Step 4: Rewrite `updateFocusRing` → `updateFocusIndicator`**

Replace the entire `updateFocusRing` method (lines 762-781) with:

```swift
    private func updateFocusIndicator(frames: [TargetFrame]) {
        guard focusIndicator.style != .none else { return }

        guard let activeTile = strip.activeColumn?.activeTile,
              let target = frames.first(where: { $0.tileID == activeTile && $0.isVisible }) else {
            focusIndicator.hide()
            lastRaisedTileID = nil
            return
        }

        // Raise style: call AXWindow.raise() only when the active tile changes
        if focusIndicator.style == .raise {
            if lastRaisedTileID != activeTile {
                lastRaisedTileID = activeTile
                if let window = windowMap[activeTile] {
                    let _ = window.raise()
                }
            }
            return
        }

        // Convert to screen coordinates (flip Y for AppKit)
        let screenHeight = primaryScreenHeight
        let flippedFrame = CGRect(
            x: target.frame.minX,
            y: screenHeight - target.frame.maxY,
            width: target.frame.width,
            height: target.frame.height
        )

        // Bootstrap guard + large-jump detection
        let shouldSnap: Bool
        if let current = focusIndicator.currentFrame {
            shouldSnap = abs(flippedFrame.midX - current.midX) > strip.workingArea.width
        } else {
            shouldSnap = true
        }

        let started: Bool
        if shouldSnap {
            started = focusIndicator.snapTo(frame: flippedFrame)
        } else {
            started = focusIndicator.animateTo(frame: flippedFrame, at: TimeUtil.now())
        }

        if started {
            frameLoop?.resume()
        }
    }
```

- [ ] **Step 5: Add wrapper methods for WindowManager**

Add these public methods:

```swift
    /// Wrapper for WindowManager — fades out the indicator when an unmanaged app activates.
    public func fadeOutIndicator() {
        if focusIndicator.fadeOut() {
            frameLoop?.resume()
        }
    }

    /// Wrapper for WindowManager — shows the indicator when a managed app activates.
    public func showIndicator() {
        let time = TimeUtil.now()
        let frames = computeTargetFrames(strip: strip, time: time)
        updateFocusIndicator(frames: frames)
    }
```

- [ ] **Step 6: Update all `focusRing.hide()` call sites**

Replace `focusRing.hide()` with `focusIndicator.hide()` at:
- `rebuildStrip()` (line 241)
- `switchSpace()` new-space branch (line 873)

Also add `focusIndicator.hide()` in the **restore-space branch** of `switchSpace()`, before the `applyLayout()` call at line 859:

```swift
            focusIndicator.hide()
            lastRaisedTileID = nil
            applyLayout()
```

And add `lastRaisedTileID = nil` next to every `focusIndicator.hide()` call.

- [ ] **Step 7: Update `applyLayout()` to call `updateFocusIndicator`**

At line 526, change:
```swift
        updateFocusRing(frames: frames)
```
to:
```swift
        updateFocusIndicator(frames: frames)
```

- [ ] **Step 8: Update `handleFrameTick()`**

This is the most complex change. The new structure:

1. Call `focusIndicator.tick(time:)` unconditionally at the top
2. Add the settle latch
3. Remove `frameLoop?.pause()` from the settled branch
4. Call `updateFocusIndicator` at the end (line 623)

Replace the `handleFrameTick` method body. The key changes from the existing code:

At the very top of the method (after line 543), add:
```swift
        // Advance indicator animations unconditionally (before settled check)
        focusIndicator.tick(time: time)
```

In the `if scrollSettled && widthSettled` block:
- Remove `frameLoop?.pause()` (line 566)
- Wrap the one-shot work in a latch check:

```swift
        if scrollSettled && widthSettled {
            if !scrollWidthSettled {
                scrollWidthSettled = true

                let finalOffset = strip.viewOffset.current(at: time)
                if gestureAnimating {
                    gestureAnimating = false
                    let viewPos = strip.columnX(at: strip.activeColumnIndex, time: time) + finalOffset
                    let newActive = columnUnderCursor(gestureOffset: finalOffset)
                    strip.activeColumnIndex = newActive
                    let adjustedOffset = viewPos - strip.columnX(at: newActive, time: time)
                    strip.viewOffset = .static(adjustedOffset)
                } else {
                    strip.viewOffset = .static(finalOffset)
                }

                applyLayout()
            } else if focusIndicator.isAnimating {
                // Scroll/width done but indicator still animating — just update indicator position
                let frames = computeTargetFrames(strip: strip, time: time)
                updateFocusIndicator(frames: frames)
            }
            return
        }

        scrollWidthSettled = false  // Reset latch when not settled
```

At the end of `handleFrameTick` (line 623), change:
```swift
        updateFocusRing(frames: frames)
```
to:
```swift
        updateFocusIndicator(frames: frames)
```

- [ ] **Step 9: Remove `frameLoop?.pause()` from gesture methods**

In `handleGestureEnd` low-velocity branch (~line 705): remove `frameLoop?.pause()`.

In `handleGestureCancel` (~line 718): remove `frameLoop?.pause()`.

- [ ] **Step 10: Reset latch on new animations**

Where scroll animations start (e.g., `focusLeft`, `focusRight`, `scrollToWindow`, gesture start), add:
```swift
        scrollWidthSettled = false
```

The simplest approach: add it in any method that sets `strip.viewOffset = .animation(...)`. Search for `.animation(` in StripController to find all sites.

- [ ] **Step 11: Build and verify**

Run: `swift build`
Expected: May still fail if WindowManager references haven't been updated. That's Task 4.

- [ ] **Step 12: Commit**

```bash
git add Sources/WindowManager/StripController.swift
git commit -m "feat: integrate FocusIndicator into StripController with animation support"
```

---

### Task 4: Update WindowManager — frameLoop, suppression, appActivated, config

**Files:**
- Modify: `Sources/WindowManager/WindowManager.swift`

- [ ] **Step 1: Promote `frameLoop` to stored property**

Add a stored property on `WindowManager` (near the other properties around line 19):

```swift
    private var frameLoop: FrameLoop?
```

In `start()`, change the local `let frameLoop = FrameLoop()` (line 253) to:
```swift
        let fl = FrameLoop()
        self.frameLoop = fl
```

And update all references from `frameLoop` to `fl` within `start()` (lines 254-266).

- [ ] **Step 2: Centralize pause in `onTick` closure**

Update the `onTick` closure (lines 254-259) to:

```swift
        fl.onTick = { [weak self] time in
            guard let self = self else { return }
            for (_, sc) in self.stripControllers {
                sc.handleFrameTick(time: time)
            }
            if self.stripControllers.values.allSatisfy({ $0.isFullySettled }) {
                self.frameLoop?.pause()
            }
        }
```

- [ ] **Step 3: Remove `.appActivated` from echo suppression gate**

In `handleWindowEvent` (line 508), change:
```swift
            case .windowResized, .windowMoved, .windowFocused, .appActivated:
```
to:
```swift
            case .windowResized, .windowMoved, .windowFocused:
```

- [ ] **Step 4: Remove `.appActivated` from space-switch suppression gate**

At line 520, change:
```swift
            case .windowFocused, .appActivated:
```
to:
```swift
            case .windowFocused:
```

- [ ] **Step 5: Extend `.appActivated` handler with indicator logic**

After the existing Cmd-Tab scroll logic in the `.appActivated` case (after line 563), add:

```swift
            // Focus indicator: hide when unmanaged app activates, show when managed
            let isManaged = tracker.windows.values.contains(where: { $0.pid == pid })
            if isManaged {
                for (_, sc) in stripControllers {
                    // Show on strips that have windows for this PID
                    if sc.windowMap.values.contains(where: { $0.pid == pid }) {
                        sc.showIndicator()
                    }
                }
            } else {
                for (_, sc) in stripControllers {
                    sc.fadeOutIndicator()
                }
            }
```

- [ ] **Step 6: Update `shutdown()`**

At line 399, change:
```swift
            sc.focusRing.hide()
```
to:
```swift
            sc.focusIndicator.hide()
```

- [ ] **Step 7: Update `togglePause()`**

At line 414, change:
```swift
            for (_, sc) in stripControllers { sc.focusRing.hide() }
```
to:
```swift
            for (_, sc) in stripControllers { sc.focusIndicator.hide() }
```

- [ ] **Step 8: Add config propagation in `applyConfig()`**

In `applyConfig` (line 96-118), add inside the `for (_, sc) in stripControllers` loop, after line 117:

```swift
            sc.focusIndicator.reloadConfig(config.focusIndicator)
            sc.focusIndicator.springParams = config.widthSpringParams
```

- [ ] **Step 9: Build and verify**

Run: `swift build`
Expected: Compiles successfully. All `FocusRing` references should now be gone.

- [ ] **Step 10: Run tests**

Run: `swift run RunTests`
Expected: All existing tests pass (no Core changes were made).

- [ ] **Step 11: Commit**

```bash
git add Sources/WindowManager/WindowManager.swift
git commit -m "feat: centralize FrameLoop pause, add indicator hide/show on app activation"
```

---

### Task 5: Manual testing and polish

**Files:** None (testing only)

- [ ] **Step 1: Build and run**

```bash
swift build && .build/debug/ScrollWM &
```

- [ ] **Step 2: Test ring mode (default)**

- Focus left/right — verify the border animates smoothly between windows (not snapping)
- Rapid focus-left, focus-left, focus-left — verify spring velocity compounds (ring accelerates)
- Scroll via gesture — verify ring follows the focused window during scroll animation

- [ ] **Step 3: Test space switching**

- Switch to a different macOS desktop (Ctrl+arrow or swipe)
- Verify the ring snaps to the correct window on the new desktop (no flash of wrong size)

- [ ] **Step 4: Test Mission Control**

- Activate Mission Control (swipe up with 3 fingers, or Ctrl+Up)
- Verify the indicator fades out (not visible during Mission Control)
- Select a window to dismiss Mission Control — verify indicator reappears

- [ ] **Step 5: Test Cmd-Tab**

- Cmd-Tab to Finder (or another non-managed app)
- Verify indicator fades out
- Cmd-Tab back — verify indicator returns

- [ ] **Step 6: Test config hot-reload — change style**

Edit `~/.config/scrollwm/config.toml`, add:
```toml
[focus_indicator]
style = "flash"
```
Save — verify indicator switches to flash mode (brief color pulse on focus change).

Change to `style = "none"` — verify indicator disappears.

Change to `style = "raise"` — verify focused window pops to front, no overlay.

Change back to `style = "ring"` — verify ring returns.

- [ ] **Step 7: Test config hot-reload — change color**

```toml
[focus_indicator]
color = "#FF6600"
```
Save — verify ring turns orange.

Change to `color = "#F00"` — verify ring turns red.

Change to `color = "auto"` — verify ring returns to system accent.

Change to `color = "invalid"` — verify fallback to system accent, warning in console.

- [ ] **Step 8: Test config hot-reload — change width**

```toml
[focus_indicator]
width = 6
corner_radius = 20
```
Save — verify ring gets thicker and rounder.

- [ ] **Step 9: Commit final state**

If any fixes were needed during testing:
```bash
git add -u
git commit -m "fix: polish focus indicator based on manual testing"
```
