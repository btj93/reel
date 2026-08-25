import Foundation

/// Identity of a macOS Space, from one of two sources.
///
/// `.skylight` is the window server's own 64-bit Space id, read through
/// `Platform.SpaceIdentity`. It is a fact: stable while the Space exists,
/// unaffected by which windows happen to be on screen, and correct during a
/// Space transition.
///
/// `.fingerprint` is the legacy inference — the set of on-screen CGWindowIDs at
/// the moment `activeSpaceDidChange` fired — kept as the fallback for when the
/// SkyLight symbols are unavailable. It is unreliable by construction: the same
/// read has been observed returning an empty set mid-transition and a union
/// spanning four Spaces, and it cannot distinguish "this Space is empty" from
/// "the window server has not caught up".
///
/// The two cases must never be conflated: matching a fingerprint uses Jaccard
/// similarity, matching a SkyLight id must be exact.
public enum SpaceKey: Hashable, Sendable {
    case skylight(UInt64)
    case fingerprint(Set<UInt32>)

    /// No usable identity. `saveCurrentSpace` refuses to stash under one of
    /// these, because every empty key would alias to the same bucket.
    /// SkyLight uses sid 0 as its "no space" sentinel.
    public var isEmpty: Bool {
        switch self {
        case .skylight(let sid): return sid == 0
        case .fingerprint(let fp): return fp.isEmpty
        }
    }

    /// True when this identity came from the window server rather than being
    /// inferred. Callers use it to decide whether fuzzy matching is legal at all.
    public var isAuthoritative: Bool {
        if case .skylight = self { return true }
        return false
    }

    /// The legacy payload, for the fuzzy-matching path only.
    public var fingerprintValue: Set<UInt32>? {
        if case .fingerprint(let fp) = self { return fp }
        return nil
    }

    public var debugDescription: String {
        switch self {
        case .skylight(let sid): return "sid:\(sid)"
        case .fingerprint(let fp): return "fp:\(fp.sorted())"
        }
    }
}

/// Normalize a raw SkyLight Space name into a usable persistent identity.
///
/// `SLSSpaceCopyName` returns an EMPTY STRING — not nil — for a Space macOS has
/// never named, which on a normal setup includes the very first Space (measured:
/// `sid=1 type=0 name=""`, corroborated by `defaults read com.apple.spaces`).
/// An `Optional("")` would become a real disk key that every unnamed Space
/// aliases into, silently merging their saved layouts. Anything blank is
/// therefore "no identity".
///
/// Pure so it can be tested without depending on which Space is active.
public func normalizedSpaceUUID(_ raw: String?) -> String? {
    guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return raw
}
