import Core

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

    var fromDisk: Bool {
        if case .disk = source { return true }
        return false
    }
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
        if let winner = bestMatch(candidates, score: { similarity($0.fingerprint, fingerprint) }) {
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

    var persisted: [Snapshot] {
        (Array(live.values) + disk.filter { lookupExact(group: $0.group, space: $0.space) == nil }).sorted {
            if $0.group != $1.group { return $0.group < $1.group }
            return $0.space.debugDescription < $1.space.debugDescription
        }
    }

    private func tolerantMatch(group: UInt32, windows: [ObservedWindow]) -> SpaceMatch? {
        let identities = Set(windows.map(WindowIdentity.init))
        let indexed = disk.indices.filter { disk[$0].group == group }
        guard let winner = bestMatch(indexed.map { disk[$0] }, score: { similarity(Set($0.windows.map(WindowIdentity.init)), identities) })
        else { return nil }
        return SpaceMatch(snapshot: disk[indexed[winner]], source: .disk(indexed[winner]))
    }
}

struct WindowIdentity: Hashable {
    let bundleID: String
    let title: String

    init(_ window: ObservedWindow) {
        bundleID = window.bundleID ?? ""
        title = window.title
    }
}

private func similarity<T: Hashable>(_ lhs: Set<T>, _ rhs: Set<T>) -> Double {
    let union = lhs.union(rhs).count
    return union == 0 ? 0 : Double(lhs.intersection(rhs).count) / Double(union)
}

private func bestMatch(_ candidates: [Snapshot], score: (Snapshot) -> Double) -> Int? {
    var best: Int?
    var bestScore = SpaceBook.matchThreshold
    for index in candidates.indices.sorted(by: {
        let lhs = candidates[$0], rhs = candidates[$1]
        if lhs.fingerprint != rhs.fingerprint { return lhs.fingerprint.sorted().lexicographicallyPrecedes(rhs.fingerprint.sorted()) }
        return lhs.space.debugDescription < rhs.space.debugDescription
    }) {
        let value = score(candidates[index])
        if value > bestScore { best = index; bestScore = value }
    }
    return best
}
