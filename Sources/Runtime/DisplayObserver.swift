import AppKit
import Engine
import Foundation
import Platform

/// Turns each screen-parameter change into one `topologyChanged` with the next revision. A notification that leaves
/// every display and the Spaces setting as they were sends nothing, so it cannot drop work stamped a moment before.
@MainActor
public final class DisplayObserver {
    private var token: NSObjectProtocol?
    private let current: () -> Topology
    private let changed: (Topology) -> Void
    private let log: (String) -> Void

    public init(current: @escaping () -> Topology, changed: @escaping (Topology) -> Void, log: @escaping (String) -> Void) {
        self.current = current
        self.changed = changed
        self.log = log
    }

    public func start() {
        token = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                       object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    public func stop() {
        token.map(NotificationCenter.default.removeObserver)
        token = nil
    }

    private func screensChanged() {
        let now = current()
        let next = Self.read(revision: now.revision + 1)
        guard next.displays != now.displays || next.separateSpaces != now.separateSpaces else {
            return log("display: screen parameters unchanged rev=\(now.revision)")
        }
        log("display: topology rev=\(next.revision) separateSpaces=\(next.separateSpaces) groups=\(Self.describe(next))")
        changed(next)
    }

    /// Every display, with frames and working areas in AX coordinates.
    public static func read(revision: UInt64) -> Topology {
        let manager = DisplayManager()
        manager.refresh()
        let height = manager.primaryScreenHeight
        let displays = manager.displays.values.sorted { $0.displayID < $1.displayID }.map {
            Display(id: $0.displayID, frame: $0.cgFrame(primaryScreenHeight: height), area: $0.workingArea(primaryScreenHeight: height))
        }
        return Topology(revision: revision, displays: displays, separateSpaces: NSScreen.screensHaveSeparateSpaces,
                        primaryScreenHeight: height)
    }

    public static func describe(_ topology: Topology) -> String {
        topology.groups.map { "\($0.id):\($0.displays.map(\.id))" }.joined(separator: ",")
    }
}
