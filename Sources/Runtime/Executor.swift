import AppKit
import Core
import Engine
import Foundation
import Platform

/// The frames the runtime wrote, per window. A move or resize that lands on a frame we wrote is our own echo; anything
/// else is the user. No clock is involved, so a slow app's late echo is still recognized and a fast user is not missed.
public struct EchoLedger: Sendable {
    public enum Verdict: Equatable, Sendable {
        case echo(revision: UInt64)
        /// Not ours, and the engine already heard this exact frame: the app keeps refusing our write.
        case repeated
        case foreign
    }

    /// Writes kept per window. An animation can queue several before the first echo arrives.
    public static let history = 8
    /// Apps round frames to whole points. The engine's own rounding tolerance, so a frame both call rounding never
    /// reaches it as the user.
    public static let slop = EngineConfig.userResizeSlop

    private var writes: [TileID: [(revision: UInt64, frame: CGRect)]] = [:]
    private var foreign: [TileID: CGRect] = [:]

    public init() {}

    public mutating func wrote(_ tile: TileID, revision: UInt64, frame: CGRect) {
        writes[tile, default: []].append((revision, frame))
        if writes[tile]!.count > Self.history { writes[tile]!.removeFirst() }
    }

    /// A write that timed out may still land, so only a hard failure is left out. `landed` is the frame the app kept:
    /// one that clamps our width echoes that, not what we asked for, and is not the user resizing.
    public mutating func record(_ tile: TileID, revision: UInt64, requested: CGRect, landed: CGRect? = nil, result: FrameResult) {
        if case .failed = result { return }
        wrote(tile, revision: revision, frame: requested)
        if let landed, !Self.matches(landed, requested) { wrote(tile, revision: revision, frame: landed) }
    }

    public mutating func forget(_ tile: TileID) {
        writes.removeValue(forKey: tile)
        foreign.removeValue(forKey: tile)
    }

    /// Height is the app's to choose (terminals snap to rows); position and width are the strip's.
    public mutating func classify(_ tile: TileID, observed: CGRect) -> Verdict {
        let history = writes[tile] ?? []
        if let index = history.lastIndex(where: { Self.matches($0.frame, observed) }) {
            writes[tile] = Array(history[index...])
            foreign.removeValue(forKey: tile)
            return .echo(revision: history[index].revision)
        }
        if let previous = foreign[tile], Self.matches(previous, observed) { return .repeated }
        foreign[tile] = observed
        return .foreign
    }

    static func matches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= slop && abs(lhs.minY - rhs.minY) <= slop && abs(lhs.width - rhs.width) <= slop
    }
}

/// Runs effects that touch windows. Every AX call goes to the owning app's thread; this class only queues work and
/// keeps the echo ledger, so a hung app never blocks the main loop.
@MainActor
public final class Executor {
    public private(set) var ledger = EchoLedger()
    private let focusWork = FocusWork()
    private var focusTicket: FocusTicket?
    private var owners: [TileID: Int32] = [:]
    private let worker: (Int32) -> AppWorker?
    private let log: (String) -> Void
    private let now: @Sendable () -> Double

    package init(worker: @escaping (Int32) -> AppWorker?, log: @escaping (String) -> Void,
                 now: @escaping @Sendable () -> Double = TimeUtil.now) {
        self.worker = worker
        self.log = log
        self.now = now
    }

    func setFrame(_ request: FrameRequest) {
        guard let worker = worker(request.pid) else {
            return log("executor: no app thread pid=\(request.pid) tile=\(request.tile.rawValue) rev=\(request.revision)")
        }
        owners[request.tile] = request.pid
        worker.write(request)
    }

    /// The engine dropped the window or its frame: a write still queued for it must not run. The ledger keeps what was
    /// already written, so a late echo of it is still recognized as ours.
    func invalidate(_ tile: TileID) {
        if let pid = owners[tile] { worker(pid)?.cancelWrite(tile) }
    }

    /// The window is gone.
    func forget(_ tile: TileID) {
        invalidate(tile)
        ledger.forget(tile)
        owners.removeValue(forKey: tile)
    }

    func wrote(_ tile: TileID, revision: UInt64, frame: CGRect, landed: CGRect?, result: FrameResult) {
        guard owners[tile] != nil else {
            return log("executor: write skipped, window gone tile=\(tile.rawValue) rev=\(revision)")
        }
        ledger.record(tile, revision: revision, requested: frame, landed: landed, result: result)
        if case .applied = result { runtimeTrace("executor: wrote tile=\(tile.rawValue) rev=\(revision)") }
        else if case .sizeUnconfirmed = result { runtimeTrace("executor: size unconfirmed tile=\(tile.rawValue) rev=\(revision)") }
        else { log("executor: write failed tile=\(tile.rawValue) rev=\(revision) result=\(result)") }
    }

    /// True when a move or resize came from the user; echoes and repeats are dropped here with a log line.
    func isForeign(_ tile: TileID, frame: CGRect) -> Bool {
        switch ledger.classify(tile, observed: frame) {
        case .echo(let revision):
            runtimeTrace("executor: echo dropped rev=\(revision) tile=\(tile.rawValue)")
            return false
        case .repeated:
            runtimeTrace("executor: app kept its own frame tile=\(tile.rawValue) frame=\(frame)")
            return false
        case .foreign:
            return true
        }
    }

    package func synchronizeFocus(with world: World, paused: Bool) {
        focusWork.synchronize(world, paused: paused)
    }

    package var focusObservationGeneration: UInt64 { focusWork.currentObservationGeneration }

    package func invalidateFocus() { focusWork.invalidate() }

    func consumeFocusEcho(pid: Int32) -> Bool { focusWork.consumeEcho(pid: pid, now: now()) }

    package func focus(_ tile: TileID, pid: Int32, scope: EventScope) {
        let ticket = focusWork.ticket(tile: tile, pid: pid, scope: scope)
        focusTicket = ticket
        let work = focusWork, now = now
        worker(pid)?.run(tile) { window in
            guard work.claim(ticket, focus: true, now: now()) else { return }
            window.focus(timeout: 0.1)
        }
    }

    package func raise(_ tile: TileID, pid: Int32) {
        guard let ticket = focusTicket, ticket.tile == tile, ticket.pid == pid else { return }
        let work = focusWork, now = now
        worker(pid)?.run(tile) { window in
            guard work.claim(ticket, focus: false, now: now()) else { return }
            _ = window.raise()
        }
    }

    func close(_ tile: TileID, pid: Int32) {
        worker(pid)?.run(tile) { _ = $0.close() }
    }
}
