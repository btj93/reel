import AppKit
import Core
import CoreGraphics
import Foundation

/// Represents a connected display/monitor.
public struct DisplayInfo: Sendable {
    public let displayID: CGDirectDisplayID
    public let frame: CGRect          // Full display frame (AppKit coords)
    public let visibleFrame: CGRect   // Minus menu bar, dock (AppKit coords)
    public let isMain: Bool
    public let refreshRate: Double    // Hz (e.g., 60, 120)

    /// Working area for AX window placement, in CG coordinates (top-left origin).
    /// NSScreen.visibleFrame is in AppKit coords (bottom-left origin).
    /// AXUIElement positioning uses CG coords (top-left origin).
    /// We must convert: CG_y = primaryScreenHeight - AppKit_y - height
    public func workingArea(struts: Struts = .zero, primaryScreenHeight: CGFloat) -> CGRect {
        // Convert visibleFrame from AppKit (bottom-left) to CG (top-left) coordinates
        let cgY = primaryScreenHeight - visibleFrame.maxY

        return CGRect(
            x: visibleFrame.minX + struts.left,
            y: cgY + struts.top,
            width: visibleFrame.width - struts.left - struts.right,
            height: visibleFrame.height - struts.top - struts.bottom
        )
    }

    public init(
        displayID: CGDirectDisplayID,
        frame: CGRect,
        visibleFrame: CGRect,
        isMain: Bool,
        refreshRate: Double
    ) {
        self.displayID = displayID
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isMain = isMain
        self.refreshRate = refreshRate
    }
}

/// Configurable insets that shrink the working area (for external bars like SketchyBar).
public struct Struts: Sendable {
    public var left: CGFloat
    public var right: CGFloat
    public var top: CGFloat
    public var bottom: CGFloat

    public static let zero = Struts(left: 0, right: 0, top: 0, bottom: 0)

    public init(left: CGFloat = 0, right: CGFloat = 0, top: CGFloat = 0, bottom: CGFloat = 0) {
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
    }
}

/// Manages display enumeration and hot-plug detection.
public final class DisplayManager: @unchecked Sendable {
    /// Current displays, keyed by displayID.
    public private(set) var displays: [CGDirectDisplayID: DisplayInfo] = [:]

    /// Height of the primary screen in points (for AppKit→CG coordinate conversion).
    public private(set) var primaryScreenHeight: CGFloat = 0

    /// Callback when display configuration changes (including Dock show/hide).
    public var onDisplayChange: (([CGDirectDisplayID: DisplayInfo]) -> Void)?

    private var notificationObserver: NSObjectProtocol?
    private var dockObserver: NSObjectProtocol?
    private var dockPollTimer: Timer?

    public init() {}

    deinit {
        stopObserving()
    }

    // MARK: - Enumeration

    /// Refresh the display list from NSScreen.
    public func refresh() {
        // Primary screen height anchors AppKit→CG coordinate conversion.
        // Use CGMainDisplayID(), not screens[0], which is not guaranteed to be primary.
        // Preserve the last valid value if the lookup chain returns nil (transient
        // during hot-plug reconfigure): a 0 height would silently corrupt every
        // subsequent Y conversion.
        let mainID = CGMainDisplayID()
        let primary: NSScreen? = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == mainID
        }) ?? NSScreen.main ?? NSScreen.screens.first

        if let h = primary?.frame.height {
            primaryScreenHeight = h
        }
        #if DEBUG
        if primary == nil {
            print("[DisplayManager] refresh(): no primary screen resolved; keeping primaryScreenHeight=\(primaryScreenHeight)")
            fflush(stdout)
        }
        #endif
        var newDisplays: [CGDirectDisplayID: DisplayInfo] = [:]

        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                continue
            }

            let refreshRate: Double
            if let mode = CGDisplayCopyDisplayMode(displayID) {
                refreshRate = mode.refreshRate > 0 ? mode.refreshRate : 60
            } else {
                refreshRate = 60
            }

            newDisplays[displayID] = DisplayInfo(
                displayID: displayID,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                isMain: screen == NSScreen.main,
                refreshRate: refreshRate
            )
        }

        displays = newDisplays
    }

    /// Get the main display info.
    public var mainDisplay: DisplayInfo? {
        displays.values.first { $0.isMain } ?? displays.values.first
    }

    /// True if macOS "Displays have separate Spaces" is OFF — all displays share
    /// one Space stack. Required for shared-strip-across-aligned-displays mode.
    /// Wraps `NSScreen.screensHaveSeparateSpaces` (inverted).
    public var displaysShareOneSpace: Bool {
        !NSScreen.screensHaveSeparateSpaces
    }

    // MARK: - Observation

    /// Start observing display configuration changes.
    public func startObserving() {
        refresh()

        // Screen parameter changes (monitor plug/unplug, resolution change)
        notificationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleDisplayChange()
        }

        // Poll for Dock show/hide changes every 1.5 seconds.
        // There's no direct notification for Dock auto-hide state changes,
        // so we poll NSScreen.visibleFrame which changes when the Dock appears/hides.
        var lastVisibleFrame: CGRect = NSScreen.main?.visibleFrame ?? .zero
        var lastMainID: CGDirectDisplayID = CGMainDisplayID()
        dockPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            let curMainID = CGMainDisplayID()
            if curMainID != lastMainID {
                lastMainID = curMainID
                self?.handleDisplayChange()
                return
            }
            guard let currentFrame = NSScreen.main?.visibleFrame else { return }
            if currentFrame != lastVisibleFrame {
                lastVisibleFrame = currentFrame
                self?.handleDisplayChange()
            }
        }
    }

    /// Stop observing.
    public func stopObserving() {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
            notificationObserver = nil
        }
        if let observer = dockObserver {
            NotificationCenter.default.removeObserver(observer)
            dockObserver = nil
        }
        dockPollTimer?.invalidate()
        dockPollTimer = nil
    }

    private func handleDisplayChange() {
        let oldDisplays = displays
        refresh()

        // Log changes
        let added = Set(displays.keys).subtracting(oldDisplays.keys)
        let removed = Set(oldDisplays.keys).subtracting(displays.keys)
        if !added.isEmpty { print("[Display] Displays added: \(added)") }
        if !removed.isEmpty { print("[Display] Displays removed: \(removed)") }
        fflush(stdout)

        onDisplayChange?(displays)
    }

    // MARK: - Alignment Groups

    /// Static tolerance for X-edge adjacency (pixels).
    public static let alignmentEpsilon: CGFloat = 0.5

    /// Compute alignment groups from a set of displays.
    /// Two displays are in the same group iff:
    /// 1. X-edge adjacency: `|A.maxX − B.minX| ≤ ε` or symmetric, with ε = 0.5.
    /// 2. Any Y-overlap: `max(A.minY, B.minY) < min(A.maxY, B.maxY)` (strict).
    /// Both checks use `frame` (physical bounds), not `visibleFrame`.
    ///
    /// Returns groups sorted by leftmost member's `frame.minX`. Each group's
    /// members are sorted by their own `frame.minX`. Deterministic output.
    public static func alignmentGroups(
        from displays: [CGDirectDisplayID: DisplayInfo]
    ) -> [[CGDirectDisplayID]] {
        let ids = displays.keys.sorted()
        var visited: Set<CGDirectDisplayID> = []
        var groups: [[CGDirectDisplayID]] = []

        for id in ids where !visited.contains(id) {
            var component: [CGDirectDisplayID] = []
            var stack: [CGDirectDisplayID] = [id]
            while let cur = stack.popLast() {
                if visited.contains(cur) { continue }
                visited.insert(cur)
                component.append(cur)
                guard let curInfo = displays[cur] else { continue }
                for other in ids where !visited.contains(other) {
                    guard let otherInfo = displays[other] else { continue }
                    if areAligned(curInfo.frame, otherInfo.frame) {
                        stack.append(other)
                    }
                }
            }
            component.sort { (a, b) in
                (displays[a]?.frame.minX ?? 0) < (displays[b]?.frame.minX ?? 0)
            }
            groups.append(component)
        }

        groups.sort { (a, b) in
            (displays[a[0]]?.frame.minX ?? 0) < (displays[b[0]]?.frame.minX ?? 0)
        }
        return groups
    }

    /// Pair-wise alignment check: X-adjacency (ε=0.5) AND any Y-overlap.
    private static func areAligned(_ a: CGRect, _ b: CGRect) -> Bool {
        let eps = alignmentEpsilon
        let xAdjacent =
            abs(a.maxX - b.minX) <= eps || abs(b.maxX - a.minX) <= eps
        let yOverlap = max(a.minY, b.minY) < min(a.maxY, b.maxY)
        return xAdjacent && yOverlap
    }

    // MARK: - Group Working Area

    /// Build a `GroupWorkingArea` for a group of display IDs. Pure computation —
    /// no side effects, safe to unit-test in isolation.
    ///
    /// Regions are sorted left-to-right by `frame.minX`; each region's rect is
    /// that display's struts-adjusted working area in CG coords (top-left origin).
    /// `referenceMidX` is the macOS main display's working-area midpoint when the
    /// main display is a member of `members`, otherwise the leftmost region's
    /// midpoint (`regions.first?.rect.midX`, falling back to 0 when empty).
    public static func groupWorkingArea(
        members: [CGDirectDisplayID],
        displays: [CGDirectDisplayID: DisplayInfo],
        mainDisplayID: CGDirectDisplayID?,
        struts: Struts,
        primaryScreenHeight: CGFloat
    ) -> GroupWorkingArea {
        let sortedMembers = members.sorted { (a, b) in
            (displays[a]?.frame.minX ?? 0) < (displays[b]?.frame.minX ?? 0)
        }
        let regions: [DisplayRegion] = sortedMembers.compactMap { id in
            guard let info = displays[id] else { return nil }
            let rect = info.workingArea(struts: struts, primaryScreenHeight: primaryScreenHeight)
            return DisplayRegion(displayID: UInt32(id), rect: rect)
        }
        let referenceMidX: CGFloat
        if let main = mainDisplayID, members.contains(main),
           let mainInfo = displays[main] {
            let mainRect = mainInfo.workingArea(struts: struts, primaryScreenHeight: primaryScreenHeight)
            referenceMidX = mainRect.midX
        } else {
            referenceMidX = regions.first?.rect.midX ?? 0
        }
        return GroupWorkingArea(regions: regions, referenceMidX: referenceMidX)
    }
}
