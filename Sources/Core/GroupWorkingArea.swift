import CoreGraphics
import Foundation

/// The working area of a display group, composed of 1..N physical display regions
/// arranged left-to-right. Solo groups (one display) reproduce today's single-rect
/// behavior; multi-region groups back the shared-strip-across-aligned-displays feature.
public struct GroupWorkingArea: Sendable, Equatable {
    /// Regions sorted left-to-right by `rect.minX`. Non-empty.
    public let regions: [DisplayRegion]

    /// CG horizontal midpoint of the macOS main display, used as the strip's
    /// coordinate origin. Falls back to `regions[0].rect.midX` when main is not a
    /// member of this group.
    public let referenceMidX: CGFloat

    public init(regions: [DisplayRegion], referenceMidX: CGFloat) {
        precondition(!regions.isEmpty, "GroupWorkingArea requires at least one region")
        self.regions = regions
        self.referenceMidX = referenceMidX
    }

    /// Bounding rect of all regions (X and Y). Used for rubber-band extent,
    /// off-strip detection, and backward-compatible `workingArea: CGRect` access.
    public var totalSpan: CGRect {
        var span = regions[0].rect
        for r in regions.dropFirst() {
            span = span.union(r.rect)
        }
        return span
    }

    /// Convenience — the first region's rect (leftmost in the strip).
    public var firstRegionRect: CGRect { regions[0].rect }
}
