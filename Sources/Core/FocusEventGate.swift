import Foundation

/// Pure, unit-testable state machine for the WindowManager-owned focus-race
/// guard: the "recent app activation" carryover that bridges a dock click /
/// Cmd+Tab which then crosses a Space boundary.
///
/// When an app is activated (`.appActivated`), macOS may switch Space as part
/// of the same dock click, firing `handleSpaceChange` shortly after. The gate
/// remembers the activated pid for a short TTL so the space-restore path can
/// prefer that app's focused window over the saved-focus tile. The record is
/// one-shot: consumed the first time it is read and **always cleared on consume,
/// regardless of TTL**.
///
/// This is a mechanical extraction of WindowManager's `recentAppActivation`
/// field + `appActivationCarryover` constant. It preserves the recent
/// focus-race fixes (commits ecc2697 / 180c814 / 36bbec2) exactly: same TTL
/// (0.5s), same strict `<` comparison direction, same clear-regardless
/// (one-shot) semantics.
public struct FocusEventGate {
    /// TTL for a recorded app activation. Matches the historical
    /// `WindowManager.appActivationCarryover`.
    public static let appActivationCarryover: Double = 0.5

    /// Most recent `.appActivated` event: the activated pid and the time it was
    /// recorded. `nil` when no activation is pending (never recorded, or already
    /// consumed).
    private var recentAppActivation: (pid: pid_t, time: Double, spaceKey: SpaceKey?)?

    public init() {}

    /// Record an app activation (dock click / Cmd+Tab). Overwrites any prior
    /// record — the newest activation wins.
    /// - Parameter spaceKey: the Space that was active AT THE MOMENT OF THE
    ///   ACTIVATION. This is what separates a real dock click from macOS's own
    ///   arrival-activation: clicking a dock icon happens while the user is still
    ///   on the OLD Space, whereas macOS activates the destination Space's
    ///   frontmost app only once it has already switched. Timing alone cannot tell
    ///   them apart — both land within milliseconds of the Space change.
    public mutating func recordAppActivation(pid: pid_t, at t: Double, spaceKey: SpaceKey? = nil) {
        recentAppActivation = (pid: pid, time: t, spaceKey: spaceKey)
    }

    /// One-shot consume. Returns the recorded pid iff a record exists AND it is
    /// still within the TTL (`t - recordedTime < appActivationCarryover`, strict);
    /// returns `nil` otherwise. **Always clears the record** ("consume regardless
    /// — one-shot"), so a second consume — this turn or later — returns `nil`.
    @discardableResult
    public mutating func consumeRecentActivation(at t: Double) -> pid_t? {
        defer { recentAppActivation = nil }
        guard let recent = recentAppActivation,
              t - recent.time < Self.appActivationCarryover
        else { return nil }
        return recent.pid
    }

    /// Consume, but only accept the activation if it was recorded while the given
    /// Space was still active — i.e. the user acted BEFORE the Space changed.
    ///
    /// Returns nil (while still consuming) when the recorded Space differs, which
    /// means macOS activated the app as part of ARRIVING somewhere, not because
    /// the user asked for it. Falls back to the plain TTL rule when either side
    /// has no Space identity, so behaviour is unchanged where SkyLight is
    /// unavailable.
    @discardableResult
    public mutating func consumeRecentActivation(
        at t: Double, requiringSpace departing: SpaceKey?
    ) -> pid_t? {
        defer { recentAppActivation = nil }
        guard let recent = recentAppActivation,
              t - recent.time < Self.appActivationCarryover
        else { return nil }
        guard let departing, let recorded = recent.spaceKey else { return recent.pid }
        return recorded == departing ? recent.pid : nil
    }
}
