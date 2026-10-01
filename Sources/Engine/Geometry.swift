import Foundation

public struct AXPoint: Equatable, Sendable {
    public let point: CGPoint
    public init(_ point: CGPoint) { self.point = point }
}

public struct ScreenPoint: Equatable, Sendable {
    public let point: CGPoint
    public init(_ point: CGPoint) { self.point = point }
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

public func axPoint(_ point: ScreenPoint, in topology: Topology) -> AXPoint {
    AXPoint(CGPoint(x: point.point.x, y: topology.primaryScreenHeight - point.point.y))
}

public func screenPoint(_ point: AXPoint, in topology: Topology) -> ScreenPoint {
    ScreenPoint(CGPoint(x: point.point.x, y: topology.primaryScreenHeight - point.point.y))
}

public func axRect(_ rect: ViewportRect, on group: DisplayGroup) -> AXRect {
    AXRect(rect.rect.offsetBy(dx: group.frame.minX, dy: group.frame.minY))
}

public func viewportRect(_ rect: StripRect, offset: Double) -> ViewportRect {
    ViewportRect(rect.rect.offsetBy(dx: -offset, dy: 0))
}

public func axRect(_ rect: ScreenRect, in topology: Topology) -> AXRect {
    AXRect(CGRect(x: rect.rect.minX, y: topology.primaryScreenHeight - rect.rect.maxY,
                  width: rect.rect.width, height: rect.rect.height))
}

public func screenRect(_ rect: AXRect, in topology: Topology) -> ScreenRect {
    ScreenRect(CGRect(x: rect.rect.minX, y: topology.primaryScreenHeight - rect.rect.maxY,
                      width: rect.rect.width, height: rect.rect.height))
}

public func stripRect(_ rect: AXRect, on group: DisplayGroup, offset: Double) -> StripRect {
    StripRect(rect.rect.offsetBy(dx: offset - group.frame.minX, dy: -group.frame.minY))
}
