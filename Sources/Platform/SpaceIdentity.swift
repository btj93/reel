import ColorSync
import CoreGraphics
import Foundation
import Core

/// One reading of the window server's Space state.
public struct SpaceSnapshot: Equatable, Sendable {
    /// The window server's 64-bit Space id. Stable while the Space exists, but
    /// reassigned across logout/reboot — do not persist this.
    public let sid: UInt64

    /// The Space's persistent UUID, the same value macOS itself stores in
    /// `com.apple.spaces`. Survives reboot, so this is the disk key.
    ///
    /// nil when macOS has no name for the Space. NOTE: `SLSSpaceCopyName` returns
    /// an EMPTY STRING (not nil) for the first Space — verified on this machine,
    /// sid 1 → `""`, corroborated by `defaults read com.apple.spaces`. That is
    /// normalized to nil here, because an `Optional("")` would otherwise become a
    /// real disk key that every unnamed Space aliases into.
    public let uuid: String?

    /// True only for real user Spaces (`SLSSpaceGetType == 0`).
    ///
    /// System Spaces share the id range with user Spaces — measured on this
    /// machine, sids 10-20 are `NotificationCenter`, `com.apple.loginUI`,
    /// `mission-control`, `show-front`, `dock`, `SystemBanner`, all type 3, and
    /// they interleave with user Spaces 1/3/4/5. Acting on one as if it were a
    /// user Space would wipe the strip, so every caller must check this.
    public let isUserSpace: Bool

    public var key: SpaceKey { .skylight(sid) }
}

/// Reads Space identity from SkyLight.
///
/// Everything here is a QUERY. No call in this file mutates window-server state,
/// so none of it requires SIP to be disabled, a Dock scripting addition, or any
/// entitlement — verified on macOS 26.6.1 (build 25G76) from an unsigned binary
/// with SIP enabled and no Accessibility grant. That boundary is deliberate and
/// must be preserved: the SkyLight functions that DO require SIP disabled are all
/// mutations (create/destroy/focus space, move window to space, set opacity).
///
/// Symbols are resolved with `dlsym` rather than linked, so a macOS release that
/// removes them degrades to `isAvailable == false` and callers fall back to the
/// legacy fingerprint path. Note that `SLSSetWindowAlpha`/`SLSSetWindowLevel` in
/// this same framework became no-ops on macOS 26 — that precedent is why the
/// fallback exists.
public enum SpaceIdentity {

    // MARK: - Symbol resolution

    private typealias FnConnection = @convention(c) () -> Int32
    private typealias FnActiveSpace = @convention(c) (Int32) -> UInt64
    private typealias FnCurrentSpace = @convention(c) (Int32, CFString) -> UInt64
    private typealias FnSpaceName = @convention(c) (Int32, UInt64) -> Unmanaged<CFString>?
    private typealias FnSpaceType = @convention(c) (Int32, UInt64) -> Int32

    private struct Symbols {
        let connectionID: FnConnection
        let activeSpace: FnActiveSpace
        let currentSpace: FnCurrentSpace?
        let spaceName: FnSpaceName?
        let spaceType: FnSpaceType?
    }

    /// Only the function pointers are cached — those genuinely cannot change for
    /// the life of the process. The CONNECTION is deliberately NOT cached: one
    /// unlucky early evaluation (no GUI session yet, login window, a fast user
    /// switch) would otherwise pin this unavailable forever with no retry, and a
    /// connection that dies later would keep being used. `SLSMainConnectionID` is
    /// a cheap call, so it is re-read on every query instead.
    private static let symbols: Symbols? = {
        guard let sky = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        else { return nil }

        // Required — without these there is no authoritative identity at all.
        guard let pConn = dlsym(sky, "SLSMainConnectionID"),
              let pActive = dlsym(sky, "SLSGetActiveSpace")
        else { return nil }

        // Optional — each degrades one capability, not the whole shim.
        return Symbols(
            connectionID: unsafeBitCast(pConn, to: FnConnection.self),
            activeSpace: unsafeBitCast(pActive, to: FnActiveSpace.self),
            currentSpace: dlsym(sky, "SLSManagedDisplayGetCurrentSpace")
                .map { unsafeBitCast($0, to: FnCurrentSpace.self) },
            spaceName: dlsym(sky, "SLSSpaceCopyName")
                .map { unsafeBitCast($0, to: FnSpaceName.self) },
            spaceType: dlsym(sky, "SLSSpaceGetType")
                .map { unsafeBitCast($0, to: FnSpaceType.self) })
    }()

    /// A live window-server connection, or nil if one cannot be obtained right now.
    private static func connection() -> (Symbols, Int32)? {
        guard let sym = symbols else { return nil }
        let cid = sym.connectionID()
        guard cid > 0 else { return nil }
        return (sym, cid)
    }

    /// True when a usable Space id can be read *right now*.
    public static var isAvailable: Bool { connection() != nil }

    // MARK: - Queries

    /// The Space currently displayed, optionally on a specific display.
    ///
    /// Pass `displayID` to ask per-display; that path is required when "Displays
    /// have separate Spaces" is ON, and was verified to also work (and to agree
    /// with the global answer) when it is OFF. When a specific display is named
    /// but cannot be resolved, this returns nil rather than falling back to the
    /// global active Space — that fallback would stamp a display that is
    /// mid-hot-plug or asleep with the cursor display's Space id AND uuid, which
    /// is silently wrong and would be written to disk.
    ///
    /// Returns nil when the shim is unavailable or the window server reports no
    /// Space — callers must treat nil as "use the legacy fingerprint".
    public static func currentSpace(displayID: CGDirectDisplayID? = nil) -> SpaceSnapshot? {
        guard let (sym, cid) = connection() else { return nil }

        let sid: UInt64
        if let displayID {
            // CGDisplayCreateUUIDFromDisplayID is public ColorSync API.
            guard let currentSpace = sym.currentSpace,
                  let uuidRef = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
                  let uuidStr = CFUUIDCreateString(nil, uuidRef)
            else { return nil }
            sid = currentSpace(cid, uuidStr)
        } else {
            sid = sym.activeSpace(cid)
        }
        guard sid != 0 else { return nil }

        // See normalizedSpaceUUID: sid 1 returns "" and an Optional("") would
        // become a disk key shared by every unnamed Space.
        let rawName = sym.spaceName?(cid, sid)?.takeRetainedValue() as String?
        let uuid = normalizedSpaceUUID(rawName)

        // Absent SLSSpaceGetType, assume a user Space — the common case, and it
        // keeps behaviour identical to today rather than silently excluding.
        let isUser = sym.spaceType.map { $0(cid, sid) == 0 } ?? true

        return SpaceSnapshot(sid: sid, uuid: uuid, isUserSpace: isUser)
    }

    /// One-line capability summary for the startup log.
    public static var diagnostics: String {
        guard let (sym, cid) = connection() else {
            return "SpaceIdentity: UNAVAILABLE (falling back to fingerprints)"
        }
        var caps: [String] = []
        if sym.currentSpace != nil { caps.append("per-display") }
        if sym.spaceName != nil { caps.append("uuid") }
        if sym.spaceType != nil { caps.append("type") }
        return "SpaceIdentity: available cid=\(cid) caps=[\(caps.joined(separator: ","))]"
    }
}
