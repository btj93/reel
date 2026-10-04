import Foundation

// MARK: - Space Identity Sanity

/// Does this on-screen window-ID set span more than one distinct Space?
///
/// A window belongs to exactly one Space, so a legitimate on-screen list can only
/// ever come from one. But `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` read
/// at `activeSpaceDidChange` time does not always honour that: mid-transition it
/// has been observed returning nothing at all, and — twice on a real machine — a
/// 14-window union spanning four Spaces. Committing such a read as a Space
/// identity wipes the live strip and keys the snapshot store to a Space that does
/// not exist.
///
/// The test: if two *mutually disjoint* known fingerprints both have windows in
/// `onScreenIDs`, the read straddles Spaces that cannot be on screen together.
/// Disjointness matters — stashed fingerprints legitimately overlap each other
/// (fuzzy re-keying, windows moved between Spaces), and overlapping ones are not
/// evidence of anything.
///
/// - Parameters:
///   - onScreenIDs: the window-server read being vetted.
///   - knownFingerprints: every Space fingerprint this strip has seen, current
///     included. Empty fingerprints are ignored — they carry no information.
/// - Returns: true when the read cannot describe a single Space.
public func spansMultipleSpaces(
    onScreenIDs: Set<UInt32>,
    knownFingerprints: [Set<UInt32>]
) -> Bool {
    guard onScreenIDs.count > 1 else { return false }
    // Keep only fingerprints the read actually touches; that intersection is the
    // evidence, and it collapses the pairwise scan to the relevant few.
    let touched = knownFingerprints.filter { !$0.isEmpty && !$0.isDisjoint(with: onScreenIDs) }
    guard touched.count > 1 else { return false }
    for i in touched.indices {
        for j in touched.index(after: i)..<touched.endIndex {
            if touched[i].isDisjoint(with: touched[j]) { return true }
        }
    }
    return false
}
