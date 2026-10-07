import Foundation

public struct WorkingInsets: Equatable, Sendable {
    public var top = 0.0
    public var bottom = 0.0
    public var left = 0.0
    public var right = 0.0

    public init() {}

    public func apply(to area: CGRect) -> CGRect {
        let x = min(left, max(0, area.width - 1))
        let y = min(top, max(0, area.height - 1))
        return CGRect(x: area.minX + x, y: area.minY + y,
                      width: max(1, area.width - x - right), height: max(1, area.height - y - bottom))
    }
}
