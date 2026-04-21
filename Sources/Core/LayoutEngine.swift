import Foundation
import CoreGraphics

/// Per-column layout state carried between the two passes of `computeTargetFrames`.
private struct ColumnLayoutSlot {
    let width: Double
    let stripX: Double
    let geometry: ColumnGeometry?
}

/// The result of laying out a single tile on screen.
public struct TargetFrame: Sendable {
    public let tileID: TileID
    public let frame: CGRect
    public let isVisible: Bool     // Overlaps the viewport
    public let isOffScreen: Bool   // Needs sliver/corner treatment
    public let visibilityZone: VisibilityZone

    public init(tileID: TileID, frame: CGRect, isVisible: Bool, isOffScreen: Bool, visibilityZone: VisibilityZone) {
        self.tileID = tileID
        self.frame = frame
        self.isVisible = isVisible
        self.isOffScreen = isOffScreen
        self.visibilityZone = visibilityZone
    }
}

/// Visibility zones for prioritizing AX call updates.
public enum VisibilityZone: Int, Comparable, Sendable {
    case visible = 0      // On screen — update every frame
    case nearBuffer = 1   // 1-2 columns beyond viewport — update at low priority
    case far = 2          // Everything else — update only on settle

    public static func < (lhs: VisibilityZone, rhs: VisibilityZone) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Pure function: compute target frames for all tiles in a strip.
///
/// This is the core layout computation. It takes the strip state and returns
/// where every window should be positioned on screen, including off-screen
/// sliver handling.
///
/// - Parameters:
///   - strip: The current strip state
///   - time: Current time (for evaluating animations)
///   - sliverWidth: Width of the visible sliver for off-screen windows (default 1px)
///   - nearBufferColumns: Number of columns beyond viewport to keep in near-buffer zone
/// - Returns: Array of target frames for all tiles
public func computeTargetFrames(
    strip: Strip,
    time: Double,
    sliverWidth: Double = 1,
    nearBufferColumns: Int = 2,
    mode: LayoutMode = .normal,
    raiseHeight: Double = 0
) -> [TargetFrame] {
    guard !strip.columns.isEmpty else { return [] }

    let viewPos = strip.viewPos(at: time)
    let wa = strip.workingArea

    let colCount = strip.columns.count

    // First pass: cache widths/positions, determine visible column range
    var colLayouts: [ColumnLayoutSlot] = []
    colLayouts.reserveCapacity(colCount)

    var visibleFirst: Int?
    var visibleLast: Int?

    var x: Double = 0
    for i in 0..<colCount {
        // Column's X center = x + half its width. We don't know width yet, so
        // estimate with cachedWidth first; then refine via A2.
        let cached = strip.columnData[i].cachedWidth
        let animated = strip.columnData[i].currentWidth(at: time)
        let hasAnim = abs(animated - cached) > 0.5
        let estimatedWidth = hasAnim ? animated : cached
        let estimatedCenterX = x - viewPos + strip.workingArea.minX + estimatedWidth / 2

        let colWidth: Double
        let geom: ColumnGeometry?
        if hasAnim {
            // Width animation takes precedence (preset toggle, etc.).
            colWidth = animated
            geom = nil
        } else if strip.columns[i].isFullWidth {
            // Full-width columns resolve against the owning region's full
            // width regardless of what's in `column.width` (which may still
            // hold a previous fixed/proportion value). Fall through to A2
            // with .proportion(1.0) so straddling/height-blend logic applies.
            let g = computeColumnGeometry(
                groupArea: strip.groupArea,
                centerX: estimatedCenterX,
                width: .proportion(1.0),
                gap: strip.gap
            )
            colWidth = g.width
            geom = g
        } else {
            let g = computeColumnGeometry(
                groupArea: strip.groupArea,
                centerX: estimatedCenterX,
                width: strip.columns[i].width,
                gap: strip.gap
            )
            colWidth = g.width
            geom = g
        }

        colLayouts.append(ColumnLayoutSlot(width: colWidth, stripX: x, geometry: geom))

        let screenLeft = x - viewPos + strip.workingArea.minX
        let screenRight = screenLeft + colWidth

        // Region-aware visibility: column is visible iff its screen rect
        // intersects ANY display region (not just fits inside totalSpan).
        var visibleHere = false
        for r in strip.groupArea.regions {
            if screenRight > Double(r.rect.minX) && screenLeft < Double(r.rect.maxX) {
                visibleHere = true
                break
            }
        }
        if visibleHere {
            if visibleFirst == nil { visibleFirst = i }
            visibleLast = i
        }

        x += colWidth + strip.gap
    }

    let vFirst = visibleFirst ?? 0
    let vLast = visibleLast ?? 0
    let nearLeft = max(0, vFirst - nearBufferColumns)
    let nearRight = min(colCount - 1, vLast + nearBufferColumns)

    // Second pass: compute target frames using cached widths
    var results: [TargetFrame] = []
    results.reserveCapacity(colCount)

    for i in 0..<colCount {
        let column = strip.columns[i]
        let slot = colLayouts[i]
        let colWidth = slot.width
        var screenX = slot.stripX - viewPos + wa.minX
        // Flush-place only applies in multi-region groups (inter-display gap).
        // In a solo-region group the column is simply off-screen; leave it.
        if strip.groupArea.regions.count > 1, let fb = slot.geometry?.fallbackRegion {
            // Column sits in an inter-display gap. Flush to the seam-facing
            // edge of the nearest region.
            let currentCenter = screenX + slot.width / 2
            if currentCenter >= Double(fb.rect.midX) {
                // Center is right of region midX → flush column LEFT edge to fb.maxX.
                screenX = Double(fb.rect.maxX) - slot.width
            } else {
                // Center is left of region midX → flush column LEFT edge to fb.minX.
                screenX = Double(fb.rect.minX)
            }
        }

        // Determine visibility zone
        let zone: VisibilityZone
        if i >= vFirst && i <= vLast {
            zone = .visible
        } else if i >= nearLeft && i <= nearRight {
            zone = .nearBuffer
        } else {
            zone = .far
        }

        let isVisible = zone == .visible
        let isPartiallyVisible = (screenX + colWidth > wa.minX) && (screenX < wa.maxX)

        // Per-column drawable rect. A2's blended height and midY for this
        // column's owning region(s); for singleton groups this reduces to the
        // single region (== wa). Columns with an in-flight width animation
        // (geometry is nil) fall back to the owning region at the current
        // scroll position.
        let columnRect: CGRect
        if let geom = slot.geometry {
            columnRect = CGRect(
                x: wa.minX,
                y: geom.midY - geom.height / 2,
                width: wa.width,
                height: geom.height
            )
        } else {
            let region = strip.regionForColumn(i, at: time)
            columnRect = CGRect(
                x: wa.minX,
                y: region.rect.minY,
                width: wa.width,
                height: region.rect.height
            )
        }

        // Raise offset: per-column Y offset read from raiseAnimation/cachedRaiseTarget
        let tileWA: CGRect
        if raiseHeight > 0 {
            let colOffset = strip.columnData[i].currentRaiseOffset(at: time)
            tileWA = CGRect(
                x: columnRect.minX,
                y: columnRect.minY + colOffset,
                width: columnRect.width,
                height: columnRect.height - raiseHeight
            )
        } else {
            tileWA = columnRect
        }

        // Compute tile frames within the column (vertical stacking)
        computeTileFrames(
            into: &results,
            column: column,
            screenX: screenX,
            colWidth: colWidth,
            workingArea: tileWA,
            gap: strip.gap,
            isVisible: isVisible,
            isPartiallyVisible: isPartiallyVisible,
            zone: zone,
            sliverWidth: sliverWidth
        )
    }

    return results
}

/// Compute frames for tiles within a single column (vertical stacking).
/// Appends TargetFrames directly into the results array, applying sliver
/// positioning for off-screen columns.
func computeTileFrames(
    into results: inout [TargetFrame],
    column: Column,
    screenX: Double,
    colWidth: Double,
    workingArea: CGRect,
    gap: Double,
    isVisible: Bool,
    isPartiallyVisible: Bool,
    zone: VisibilityZone,
    sliverWidth: Double
) {
    guard !column.tiles.isEmpty else { return }

    // Clamp column width to working area
    let clampedWidth = min(colWidth, workingArea.width)

    let tileCount = column.tiles.count
    let totalGaps = Double(max(0, tileCount - 1)) * gap
    let availableHeight = workingArea.height - totalGaps
    let tileHeight = max(1, availableHeight / Double(tileCount))

    var y = workingArea.minY

    for tile in column.tiles {
        let tileFrame = CGRect(
            x: screenX,
            y: y,
            width: clampedWidth,
            height: tileHeight
        )

        var finalFrame = tileFrame
        var offScreen = false

        if !isPartiallyVisible {
            finalFrame = sliverFrame(
                originalFrame: tileFrame,
                workingArea: workingArea,
                side: screenX < workingArea.minX ? .left : .right,
                sliverWidth: sliverWidth
            )
            offScreen = true
        }

        results.append(TargetFrame(
            tileID: tile,
            frame: finalFrame,
            isVisible: isVisible || isPartiallyVisible,
            isOffScreen: offScreen,
            visibilityZone: zone
        ))

        y += tileHeight + gap
    }
}

/// Side of the screen for sliver positioning.
enum SliverSide {
    case left, right
}

/// Compute a sliver frame for an off-screen window.
/// Keeps `sliverWidth` pixels visible at the screen edge.
func sliverFrame(
    originalFrame: CGRect,
    workingArea: CGRect,
    side: SliverSide,
    sliverWidth: Double
) -> CGRect {
    switch side {
    case .left:
        // Position so rightmost `sliverWidth` px is at left screen edge
        return CGRect(
            x: workingArea.minX - originalFrame.width + sliverWidth,
            y: originalFrame.minY,
            width: originalFrame.width,
            height: originalFrame.height
        )
    case .right:
        // Position so leftmost `sliverWidth` px is at right screen edge
        return CGRect(
            x: workingArea.maxX - sliverWidth,
            y: originalFrame.minY,
            width: originalFrame.width,
            height: originalFrame.height
        )
    }
}

/// Result of resolving a column's geometry against a `GroupWorkingArea`.
public struct ColumnGeometry: Sendable {
    public let width: Double
    public let height: Double
    public let midY: Double
    /// The region used when the trial rect had zero overlap with any region
    /// (column sitting in an inter-display gap). Caller flush-places the
    /// column to the seam-facing edge of this region.
    public let fallbackRegion: DisplayRegion?
}

/// Compute a column's `(width, height, midY)` by area-weighted blending across
/// all display regions it currently overlaps (A2 interpolation).
///
/// The column's horizontal center `centerX` is given; width/height are resolved
/// via a small fixed-point iteration because width determines the rect extent
/// which in turn determines per-region overlap areas.
///
/// Fallbacks:
/// - Column entirely in an inter-display gap (no overlap with any region): use
///   the region closest to `centerX` (treating "inside region" as distance 0);
///   width = `p × region.width`, height = region.height, midY = region.midY,
///   `fallbackRegion` is set so the caller can flush-place the column.
/// - `.fixed(f)`: width = f regardless of overlap; height/midY still blend.
public func computeColumnGeometry(
    groupArea: GroupWorkingArea,
    centerX: Double,
    width: ColumnWidth,
    gap: Double
) -> ColumnGeometry {
    // Helper — compute per-region overlaps for a trial rect.
    func overlaps(for rect: CGRect) -> [(region: DisplayRegion, area: Double)] {
        var out: [(DisplayRegion, Double)] = []
        for r in groupArea.regions {
            let inter = rect.intersection(r.rect)
            if !inter.isNull && inter.width > 0 && inter.height > 0 {
                out.append((r, Double(inter.width * inter.height)))
            }
        }
        return out
    }

    // Nearest region by horizontal distance from centerX. Distance is 0 if
    // centerX is inside the region; otherwise the gap to the nearer edge.
    func nearestRegion() -> DisplayRegion {
        var best = groupArea.regions[0]
        var bestDist = Double.infinity
        for r in groupArea.regions {
            let d: Double
            if centerX >= Double(r.rect.minX) && centerX <= Double(r.rect.maxX) {
                d = 0
            } else {
                d = min(
                    abs(centerX - Double(r.rect.minX)),
                    abs(centerX - Double(r.rect.maxX))
                )
            }
            if d < bestDist {
                bestDist = d
                best = r
            }
        }
        return best
    }

    // Distinguish three center-X placements:
    //   - inside some region → normal A2 blend below
    //   - in an inter-display gap (inside totalSpan's X extent but not any
    //     region) → flush-place to nearest seam edge (fallbackRegion set)
    //   - past totalSpan's outer edge (left of leftmost.minX or right of
    //     rightmost.maxX) → natural cumulative placement; the caller's
    //     sliver/off-strip logic handles it (fallbackRegion = nil).
    let centerInRegion = groupArea.regions.contains {
        centerX >= Double($0.rect.minX) && centerX <= Double($0.rect.maxX)
    }
    if !centerInRegion {
        let span = groupArea.totalSpan
        let centerInStrip = centerX >= Double(span.minX) && centerX <= Double(span.maxX)
        let n = nearestRegion()
        return ColumnGeometry(
            width: width.resolveBlended(overlaps: [(n, 1.0)], gap: gap),
            height: Double(n.rect.height),
            midY: Double(n.rect.midY),
            fallbackRegion: centerInStrip ? n : nil
        )
    }

    // Initial trial: seed from nearest region's dimensions.
    let seed = nearestRegion()
    var w = width.resolveBlended(overlaps: [(seed, 1.0)], gap: gap)
    var h = Double(seed.rect.height)
    var midY = Double(seed.rect.midY)

    // Fixed-point: at most 4 iterations, stop when |Δwidth| ≤ 0.5.
    for _ in 0..<4 {
        let trial = CGRect(
            x: centerX - w / 2,
            y: midY - h / 2,
            width: w,
            height: h
        )
        let ov = overlaps(for: trial)
        if ov.isEmpty {
            // Trial rect has no overlap (edge case). Fall back to nearest region.
            let n = nearestRegion()
            return ColumnGeometry(
                width: width.resolveBlended(overlaps: [(n, 1.0)], gap: gap),
                height: Double(n.rect.height),
                midY: Double(n.rect.midY),
                fallbackRegion: n
            )
        }

        let newW = width.resolveBlended(overlaps: ov, gap: gap)

        // Blend height and midY by area weights.
        let totalArea = ov.reduce(0.0) { $0 + $1.area }
        var newH = 0.0
        var newMidY = 0.0
        for (region, area) in ov {
            let weight = area / totalArea
            newH += weight * Double(region.rect.height)
            newMidY += weight * Double(region.rect.midY)
        }

        let dw = abs(newW - w)
        w = newW
        h = newH
        midY = newMidY
        if dw <= 0.5 { break }
    }

    return ColumnGeometry(width: w, height: h, midY: midY, fallbackRegion: nil)
}

