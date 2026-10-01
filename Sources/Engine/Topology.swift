import Core
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

    public init(revision: UInt64, groups: [DisplayGroup]) {
        self.revision = revision
        self.groups = groups
    }
}

public struct AXRect: Equatable, Sendable {
    public let rect: CGRect
    public init(_ rect: CGRect) { self.rect = rect }
}

public struct ScreenRect: Equatable, Sendable {
    public let rect: CGRect
    public init(_ rect: CGRect) { self.rect = rect }
}

public struct StripRect: Equatable, Sendable {
    public let rect: CGRect
    public init(_ rect: CGRect) { self.rect = rect }
}

public struct ViewportRect: Equatable, Sendable {
    public let rect: CGRect
    public init(_ rect: CGRect) { self.rect = rect }
}

public func axRect(_ rect: ViewportRect, on group: DisplayGroup) -> AXRect {
    AXRect(rect.rect.offsetBy(dx: group.frame.minX, dy: group.frame.minY))
}

public func viewportRect(_ rect: StripRect, offset: Double) -> ViewportRect {
    ViewportRect(rect.rect.offsetBy(dx: -offset, dy: 0))
}

public func axRect(_ rect: ScreenRect) -> AXRect { AXRect(rect.rect) }

public func stripRect(_ rect: AXRect, on group: DisplayGroup, offset: Double) -> StripRect {
    StripRect(rect.rect.offsetBy(dx: offset - group.frame.minX, dy: -group.frame.minY))
}
