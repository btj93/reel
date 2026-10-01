import Core

public struct GroupSpace: Hashable, Sendable {
    public let group: UInt32
    public let space: SpaceKey

    public init(group: UInt32, space: SpaceKey) {
        self.group = group
        self.space = space
    }
}

public struct SpaceBook: Sendable {
    public internal(set) var live: [GroupSpace: Snapshot] = [:]
    public internal(set) var disk: [Snapshot] = []

    public init() {}

    public func lookupExact(group: UInt32, space: SpaceKey) -> Snapshot? {
        live[GroupSpace(group: group, space: space)]
    }

    public func lookupTolerant(group: UInt32, windows: [ObservedWindow]) -> Snapshot? {
        let identities = Set(windows.map(WindowIdentity.init))
        return bestMatch(disk.filter { $0.group == group }, score: {
            similarity(Set($0.windows.map(WindowIdentity.init)), identities)
        })
    }

    func lookup(group: UInt32, space: SpaceKey, windows: [ObservedWindow]) -> Snapshot? {
        if let exact = lookupExact(group: group, space: space) { return exact }
        let fingerprint = Set(windows.map { $0.id.rawValue })
        if case .fingerprint = space,
           let winner = bestMatch(live.values.filter { $0.group == group }, score: {
               similarity($0.fingerprint, fingerprint)
           }) { return winner }
        return lookupTolerant(group: group, windows: windows)
    }
}

struct WindowIdentity: Hashable {
    let bundleID: String
    let title: String

    init(_ window: ObservedWindow) {
        bundleID = window.bundleID ?? ""
        title = window.identity
    }
}

private func similarity<T: Hashable>(_ lhs: Set<T>, _ rhs: Set<T>) -> Double {
    let union = lhs.union(rhs).count
    return union == 0 ? 0 : Double(lhs.intersection(rhs).count) / Double(union)
}

private func bestMatch(_ candidates: [Snapshot], score: (Snapshot) -> Double) -> Snapshot? {
    var best: Snapshot?
    var bestScore = 0.5
    for candidate in candidates.sorted(by: {
        if $0.fingerprint != $1.fingerprint { return $0.fingerprint.sorted().lexicographicallyPrecedes($1.fingerprint.sorted()) }
        return $0.space.debugDescription < $1.space.debugDescription
    }) {
        let value = score(candidate)
        if value > bestScore { best = candidate; bestScore = value }
    }
    return best
}
