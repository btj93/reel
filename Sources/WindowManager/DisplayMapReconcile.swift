import CoreGraphics
import Foundation

/// Recompute the display→group routing table across a topology change.
///
/// Added groups are installed first, then dying groups are pruned — but only
/// where the entry still points at the dying group. Without that guard a merge
/// ([A]+[B] → [A,B]) deletes the very entries the add step just wrote, leaving
/// both displays unroutable while the merged controller is alive. A split
/// ([A,B] → [A]+[B]) fails the same way.
///
/// Pure and order-independent so it can be tested without a live display setup;
/// `reconcileDisplayTopology` owns the controller side-effects.
package func reconcileDisplayMap(
    current: [CGDirectDisplayID: [CGDirectDisplayID]],
    added: [[CGDirectDisplayID]],
    removed: [[CGDirectDisplayID]]
) -> [CGDirectDisplayID: [CGDirectDisplayID]] {
    var map = current
    for gid in added {
        for did in gid { map[did] = gid }
    }
    for gid in removed {
        // Only prune an entry that still points at the dying group. A display
        // that has already been re-pointed at a successor must keep that mapping.
        for did in gid where map[did] == gid { map.removeValue(forKey: did) }
    }
    return map
}
