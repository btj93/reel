import Core
import Foundation

public struct GroupSpace: Hashable, Sendable {
    public let group: UInt32
    public let space: SpaceKey

    public init(group: UInt32, space: SpaceKey) {
        self.group = group
        self.space = space
    }
}

struct SpaceMatch {
    enum Source { case live(SpaceKey), disk(Int) }
    let snapshot: Snapshot
    let source: Source
}

public struct SpaceBook: Sendable {
    public static let matchThreshold = 0.5

    public internal(set) var live: [GroupSpace: Snapshot] = [:]
    public internal(set) var disk: [Snapshot] = []

    public init() {}

    public func lookupExact(group: UInt32, space: SpaceKey) -> Snapshot? {
        live[GroupSpace(group: group, space: space)]
    }

    public func lookupTolerant(group: UInt32, windows: [ObservedWindow]) -> Snapshot? {
        tolerantMatch(group: group, windows: windows)?.snapshot
    }

    func lookup(group: UInt32, space: SpaceKey, windows: [ObservedWindow]) -> SpaceMatch? {
        if let exact = lookupExact(group: group, space: space) { return SpaceMatch(snapshot: exact, source: .live(space)) }
        let fingerprint = Set(windows.map { $0.id.rawValue })
        let candidates = live.filter { $0.key.group == group && (!space.isAuthoritative || !$0.key.space.isAuthoritative) }.map(\.value)
        if let winner = bestMatch(candidates, score: { MatchScore(gate: similarity($0.fingerprint.union($0.hidden.map(\.window.id.rawValue).filter(fingerprint.contains)), fingerprint)) }) {
            return SpaceMatch(snapshot: candidates[winner], source: .live(candidates[winner].space))
        }
        return tolerantMatch(group: group, windows: windows)
    }

    mutating func adopt(_ match: SpaceMatch, as key: SpaceKey) {
        switch match.source {
        case .live(let matched) where matched != key: live[GroupSpace(group: match.snapshot.group, space: matched)] = nil
        case .live: break
        case .disk(let index): disk.remove(at: index)
        }
    }

    /// A disk entry's Space id is never matched exactly: a reboot hands it to another Space. So one under a live key
    /// is still written, and is only gone once a census adopts it.
    // ponytail: a disk entry no Space ever matches is written back forever; cap entries per group if the file grows.
    public var persisted: [Snapshot] {
        (Array(live.values) + disk).map { ($0, SpaceOrder($0.group, $0.space)) }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    private func tolerantMatch(group: UInt32, windows: [ObservedWindow]) -> SpaceMatch? {
        let identities = Set(windows.map(WindowIdentity.init))
        let bundles = appBundles(windows)
        let bundleByID = Dictionary(windows.map { ($0.id, $0.knownBundleID) }, uniquingKeysWith: { first, _ in first })
        let indexed = disk.indices.filter { disk[$0].group == group }
        let winner = bestMatch(indexed.map { disk[$0] }) { saved in
            let sameWindows = saved.windows.reduce(0) { bundleByID[$1.id] == .some($1.knownBundleID) ? $0 + 1 : $0 }
            let union = saved.windows.count + windows.count - sameWindows
            return MatchScore(gate: similarity(saved.bundles, bundles), windowIDs: union == 0 ? 0 : Double(sameWindows) / Double(union),
                              titles: similarity(saved.identities, identities))
        }
        guard let winner else { return nil }
        return SpaceMatch(snapshot: disk[indexed[winner]], source: .disk(indexed[winner]))
    }
}

struct SpaceOrder: Comparable {
    let group: UInt32
    let sid: UInt64
    let fingerprint: [UInt32]

    init(_ group: UInt32, _ space: SpaceKey) {
        self.group = group
        switch space {
        case .skylight(let id): sid = id; fingerprint = []
        case .fingerprint(let ids): sid = .max; fingerprint = ids.sorted()
        }
    }

    static func < (lhs: SpaceOrder, rhs: SpaceOrder) -> Bool {
        if lhs.group != rhs.group { return lhs.group < rhs.group }
        if lhs.sid != rhs.sid { return lhs.sid < rhs.sid }
        return lhs.fingerprint.lexicographicallyPrecedes(rhs.fingerprint)
    }
}

struct WindowIdentity: Hashable {
    let bundleID: String
    let title: String

    init(_ window: ObservedWindow) {
        bundleID = window.knownBundleID ?? ""
        title = window.title
    }
}

private func similarity<T: Hashable>(_ lhs: Set<T>, _ rhs: Set<T>) -> Double {
    let (small, large) = lhs.count <= rhs.count ? (lhs, rhs) : (rhs, lhs)
    let shared = small.reduce(0) { large.contains($1) ? $0 + 1 : $0 }
    let union = lhs.count + rhs.count - shared
    return union == 0 ? 0 : Double(shared) / Double(union)
}

/// `gate` or `windowIDs` must clear the threshold; window ids above it outrank the gate, because ids survive a Reel
/// restart (not a reboot) and windows without a bundle have no app set to gate on.
private struct MatchScore: Comparable {
    let gate: Double
    var windowIDs = 0.0
    var titles = 0.0

    var passes: Bool { max(gate, windowIDs) > SpaceBook.matchThreshold }

    private var rank: (Double, Double, Double, Double) {
        (windowIDs > SpaceBook.matchThreshold ? windowIDs : 0, gate, windowIDs, titles)
    }

    static func < (lhs: MatchScore, rhs: MatchScore) -> Bool { lhs.rank < rhs.rank }
}

private func bestMatch(_ candidates: [Snapshot], score: (Snapshot) -> MatchScore) -> Int? {
    let scored = candidates.indices.map { (index: $0, score: score(candidates[$0])) }.filter(\.score.passes)
    return scored.min {
        if $0.score != $1.score { return $0.score > $1.score }
        let lhs = candidates[$0.index], rhs = candidates[$1.index]
        if lhs.fingerprint != rhs.fingerprint { return lhs.fingerprint.sorted().lexicographicallyPrecedes(rhs.fingerprint.sorted()) }
        return SpaceOrder(lhs.group, lhs.space) < SpaceOrder(rhs.group, rhs.space)
    }?.index
}

public enum SpaceBookError: Error, Equatable {
    case version(Int)
}

/// The one codec for saved strips. The state file is `{"version": n, "snapshots": [...]}`; any other version, or a
/// file that is not this shape, throws, and the caller starts fresh.
extension SpaceBook {
    public static let version = 1

    private struct File: Codable {
        let version: Int
        let snapshots: [Snapshot]
    }

    private struct Header: Decodable {
        let version: Int
    }

    public static func encode(_ snapshots: [Snapshot]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(File(version: version, snapshots: snapshots))
    }

    /// Entries that fail validation are dropped; their valid siblings are kept.
    public static func decode(_ data: Data) throws -> [Snapshot] {
        let found = try JSONDecoder().decode(Header.self, from: data).version
        guard found == version else { throw SpaceBookError.version(found) }
        return try JSONDecoder().decode(File.self, from: data).snapshots.filter(\.isValid)
    }
}
