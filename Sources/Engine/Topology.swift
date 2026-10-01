import Foundation

public struct DisplayGroup: Sendable {
    public let id: UInt32
    public let displays: [UInt32]
    public let frame: CGRect

    public init(id: UInt32, displays: [UInt32], frame: CGRect) {
        self.id = id
        self.displays = displays
        self.frame = frame
    }
}

public struct Topology: Sendable {
    public let revision: UInt64
    public let groups: [DisplayGroup]
    public let primaryScreenHeight: Double

    public init(revision: UInt64, groups: [DisplayGroup], primaryScreenHeight: Double) {
        self.revision = revision
        self.groups = groups
        self.primaryScreenHeight = primaryScreenHeight
    }
}
