import AppKit
import Core
import Engine
import Foundation
import Platform

/// When to read the census after a Space notification. macOS has been measured firing 678 notifications in 180 s with
/// the Space id genuinely cycling, so notifications closer than `threshold` are churn: each one waits out `settle`
/// again and only the last is read. A notification after a quiet `threshold` is read at once, so normal switching pays
/// no latency. `settle` is shorter than `threshold`, and the gap is measured between notifications, never from a read,
/// so a read can never look like more churn.
public struct SpaceStorm: Sendable {
    public static let threshold = 0.3
    public static let settle = 0.25

    private var last: Double?
    public private(set) var coalesced = 0

    public init() {}

    /// The delay before the census for a notification at `now`: zero, or `settle` while the churn lasts.
    public mutating func notified(at now: Double) -> Double {
        defer { last = now }
        guard let last, now - last < Self.threshold else {
            coalesced = 0
            return 0
        }
        coalesced += 1
        return Self.settle
    }
}

/// Turns `activeSpaceDidChange` into one `spaceWillChange` per notification and one census per change, and names the
/// Space a census read. Every notification tears the strip down, since a focus or swipe pending against it may be
/// about to land on another Space (1aa4ede); a system Space (Mission Control, the Dock, Notification Center) is
/// ignored, as it is not a place windows live.
@MainActor
public final class SpaceObserver {
    private var storm = SpaceStorm()
    private var token: NSObjectProtocol?
    private var fallbackLogged = false
    private let clock: () -> Double
    private let notify: () -> Void
    private let census: (_ delay: Double) -> Void
    private let log: (String) -> Void

    /// `notify` sends `spaceWillChange`; `census` reads the Space now (delay 0) or after the churn settles.
    public init(clock: @escaping () -> Double, notify: @escaping () -> Void, census: @escaping (_ delay: Double) -> Void,
                log: @escaping (String) -> Void) {
        self.clock = clock
        self.notify = notify
        self.census = census
        self.log = log
    }

    public func start() {
        log("space: \(SpaceIdentity.diagnostics)")
        token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceDidChange() }
        }
    }

    public func stop() {
        token.map(NSWorkspace.shared.notificationCenter.removeObserver)
        token = nil
    }

    private func spaceDidChange() {
        if let space = SpaceIdentity.currentSpace(), !space.isUserSpace { return log("space: system Space ignored sid=\(space.sid)") }
        notify()
        let delay = storm.notified(at: clock())
        if delay > 0 { log("space: storm, coalesced \(storm.coalesced) notification(s)") }
        census(delay)
    }

    /// The key for a census of `windows` on `display`: the window server's Space id, or the fingerprint of the read when
    /// SkyLight cannot answer. Nil for a system Space, which no strip belongs to.
    public func key(display: CGDirectDisplayID, windows: [ObservedWindow]) -> SpaceKey? {
        if let space = SpaceIdentity.currentSpace(displayID: display) {
            fallbackLogged = false
            return space.isUserSpace ? space.key : nil
        }
        if !fallbackLogged { log("space: fingerprint fallback") }
        fallbackLogged = true
        return .fingerprint(Set(windows.map(\.id.rawValue)))
    }

    /// The Space focus is observed on, stamped where the observation is made: an activation recorded on the departing
    /// Space is a Dock click, one recorded on the destination is macOS arriving there (e3e6267). Nil without SkyLight.
    nonisolated public static func observedSpace() -> SpaceKey? {
        SpaceIdentity.currentSpace().flatMap { $0.isUserSpace ? $0.key : nil }
    }
}
