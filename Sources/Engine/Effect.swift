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

public enum Overlay: Sendable {
    case hidden
    case menu(tile: TileID, scope: EventScope, session: PointerToken)
    case reorder(tile: TileID, scope: EventScope, session: PointerToken)
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
    case persist(SpaceBook)
    case requestCensus(group: UInt32, after: Double)
    case schedule(token: TimerToken, deadline: Double, event: Event)
    case cancel(TimerToken)
    case log(String)
}
