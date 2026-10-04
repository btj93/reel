import Core

public struct TimerToken: Hashable, Comparable, Sendable {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public static func < (lhs: TimerToken, rhs: TimerToken) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct FrameRequest: Equatable, Sendable {
    public let tile: TileID
    public let pid: Int32
    public let frame: AXRect
    public let revision: UInt64
    public let scope: EventScope
}

public struct MenuOverlay: Equatable, Sendable {
    public let session: PointerToken
    public let scope: EventScope
    public let press: TitlePress
}

/// `display` is the display under the cursor when the drag began. Once `released`, the runtime answers with the drop.
public struct ReorderOverlay: Equatable, Sendable {
    public let session: PointerToken
    public let scope: EventScope
    public let tile: TileID
    public let display: UInt32
    public let released: Bool
}

public enum Overlay: Equatable, Sendable {
    case hidden
    case menu(MenuOverlay)
    case reorder(ReorderOverlay)
}

public enum CommandOutcome: Equatable, Sendable {
    case accepted
    case refused(String)
    case unknownWindow(TileID)
}

public enum ReplyPayload: Sendable {
    case command(CommandOutcome)
    case snapshots([Snapshot])
}

public enum Effect: Sendable {
    case setFrame(FrameRequest)
    case invalidateFrame(tile: TileID, revision: UInt64)
    case focus(tile: TileID, source: FocusSource)
    case raise(TileID)
    case reply(id: UInt64, payload: ReplyPayload)
    case close(TileID)
    case overlay(Overlay)
    /// The pointer input this pass reduced is Reel's: the tap must not deliver it to the app.
    case consumeInput
    /// A modifier press that never became a drag or a menu is a click: deliver a press at `origin`, then the release.
    case replayPress(AXPoint)
    case persist(SpaceBook)
    case requestCensus(group: UInt32, after: Double)
    case schedule(token: TimerToken, deadline: Double, event: Event)
    case cancel(TimerToken)
    case log(String)
}
