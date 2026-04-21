import CoreGraphics
import Foundation

/// A single physical display's contribution to a `GroupWorkingArea`.
/// `rect` is in CG coordinates (top-left origin), already struts-adjusted.
public struct DisplayRegion: Sendable, Equatable {
    public let displayID: UInt32
    public let rect: CGRect

    public init(displayID: UInt32, rect: CGRect) {
        self.displayID = displayID
        self.rect = rect
    }
}
