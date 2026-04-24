import CoreGraphics
import Foundation

// MARK: - Data Types

/// Describes a single slot in a strip snapshot — one column's worth of state.
public struct SlotDescriptor: Codable, Equatable {
    /// In-session fast-path; nil on disk (CGWindowIDs are ephemeral).
    public var windowID: CGWindowID?
    public let bundleID: String
    /// For multi-window disambiguation (e.g., two Chrome windows with different titles).
    public let windowTitle: String?
    public let width: ColumnWidth
    public let presetIndex: Int?
    public let isFullWidth: Bool
    /// True = ghost slot (window was removed, slot preserved for re-matching).
    public var vacant: Bool
    /// When the window was removed (for ghost slot expiry).
    public var vacatedAt: Date?

    public init(
        windowID: CGWindowID? = nil,
        bundleID: String,
        windowTitle: String?,
        width: ColumnWidth,
        presetIndex: Int?,
        isFullWidth: Bool,
        vacant: Bool = false,
        vacatedAt: Date? = nil
    ) {
        self.windowID = windowID
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.width = width
        self.presetIndex = presetIndex
        self.isFullWidth = isFullWidth
        self.vacant = vacant
        self.vacatedAt = vacatedAt
    }
}

/// An ordered array of slots representing a strip's layout at a point in time.
public struct StripSnapshot: Codable {
    public var slots: [SlotDescriptor]
    public var lastUpdated: Date

    public init(slots: [SlotDescriptor], lastUpdated: Date) {
        self.slots = slots
        self.lastUpdated = lastUpdated
    }
}

/// Plain-data representation of a strip window, used by pure matching functions.
/// Built by WindowManager from StripController + WindowTracker data.
public struct StripWindowInfo {
    public let tileID: TileID
    public let windowID: CGWindowID
    public let bundleID: String
    public let windowTitle: String?

    public init(tileID: TileID, windowID: CGWindowID, bundleID: String, windowTitle: String?) {
        self.tileID = tileID
        self.windowID = windowID
        self.bundleID = bundleID
        self.windowTitle = windowTitle
    }
}

// MARK: - Pure Matching Functions

/// Ghost slot expiry duration (10 minutes).
private let ghostExpiryInterval: TimeInterval = 600

/// Compute which snapshot slots are already filled by windows currently in the strip.
/// Two-pass algorithm: windowID first (strongest), then semantic (bundleID + title).
public func computeFilledSlots(
    slots: [SlotDescriptor],
    stripWindows: [StripWindowInfo]
) -> Set<Int> {
    var filled = Set<Int>()
    var claimedTiles = Set<TileID>()

    // Pass 1: windowID matches (strongest signal, requires bundleID match to guard against ID reuse)
    for (i, slot) in slots.enumerated() {
        if let wid = slot.windowID {
            let tid = TileID(wid)
            if let sw = stripWindows.first(where: { $0.tileID == tid }),
               !claimedTiles.contains(tid),
               sw.bundleID == slot.bundleID {
                filled.insert(i)
                claimedTiles.insert(tid)
            }
        }
    }

    // Pass 2: semantic matches (bundleID + title) for unclaimed slots/tiles
    // Ghost (vacant) slots are skipped — they have no live window to claim them.
    for (i, slot) in slots.enumerated() {
        guard !filled.contains(i), !slot.vacant else { continue }
        for sw in stripWindows {
            guard !claimedTiles.contains(sw.tileID),
                  sw.bundleID == slot.bundleID,
                  slot.windowTitle == nil || sw.windowTitle == slot.windowTitle
            else { continue }
            filled.insert(i)
            claimedTiles.insert(sw.tileID)
            break
        }
    }

    return filled
}

/// Match snapshot slots to window candidates in strip order.
/// Each candidate is used at most once. Non-vacant slots are matched; vacant
/// slots are skipped (ghosts have no live window to claim). A candidate with
/// a title matching the slot wins over one with only a bundle match.
/// Returns pairs in slot order; slots with no candidate are dropped.
public func matchSlotsToWindows(
    slots: [SlotDescriptor],
    candidates: [StripWindowInfo]
) -> [(slotIndex: Int, candidateIndex: Int)] {
    var result: [(slotIndex: Int, candidateIndex: Int)] = []
    var usedCandidates = Set<Int>()

    for (slotIdx, slot) in slots.enumerated() {
        guard !slot.vacant else { continue }

        var titleMatch: Int?
        var bundleMatch: Int?
        for (candIdx, cand) in candidates.enumerated() {
            guard !usedCandidates.contains(candIdx),
                  cand.bundleID == slot.bundleID
            else { continue }
            if let slotTitle = slot.windowTitle, cand.windowTitle == slotTitle {
                titleMatch = candIdx
                break
            }
            if bundleMatch == nil {
                bundleMatch = candIdx
            }
        }

        if let chosen = titleMatch ?? bundleMatch {
            result.append((slotIdx, chosen))
            usedCandidates.insert(chosen)
        }
    }

    return result
}

/// Match a newly-appearing window to its best slot in the snapshot.
/// Returns the slot index, or nil if no match found.
public func matchWindowToSlot(
    windowID: CGWindowID,
    bundleID: String,
    title: String?,
    snapshot: StripSnapshot,
    filledSlots: Set<Int>,
    now: Date
) -> Int? {
    // 1. WindowID fast-path (requires bundleID match to guard against macOS ID reuse)
    for (i, slot) in snapshot.slots.enumerated() {
        if let slotWID = slot.windowID,
           slotWID == windowID,
           slot.bundleID == bundleID,
           !filledSlots.contains(i) {
            return i
        }
    }

    // 2. Find unfilled slots with matching bundleID (skip expired ghosts)
    var candidates: [(index: Int, slot: SlotDescriptor)] = []
    for (i, slot) in snapshot.slots.enumerated() {
        guard !filledSlots.contains(i),
              slot.bundleID == bundleID
        else { continue }
        // Skip expired ghost slots
        if let vacatedAt = slot.vacatedAt,
           now.timeIntervalSince(vacatedAt) > ghostExpiryInterval {
            continue
        }
        candidates.append((i, slot))
    }

    guard !candidates.isEmpty else { return nil }

    // 3. Prefer title match among candidates
    if let title = title {
        if let match = candidates.first(where: { $0.slot.windowTitle == title }) {
            return match.index
        }
    }

    // 4. Tiebreaker: first unfilled slot for that bundleID
    return candidates.first?.index
}
