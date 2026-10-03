import AppKit
import Core
import Engine
import Foundation

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
    /// Apps round frames to whole points.
    public static let slop = 1.0

    private var writes: [TileID: [(revision: UInt64, frame: CGRect)]] = [:]
    private var foreign: [TileID: CGRect] = [:]

    public init() {}

    public mutating func wrote(_ tile: TileID, revision: UInt64, frame: CGRect) {
        writes[tile, default: []].append((revision, frame))
        if writes[tile]!.count > Self.history { writes[tile]!.removeFirst() }
    }

    /// What a finished write leaves in the ledger.
    public mutating func record(_ tile: TileID, revision: UInt64, requested: CGRect, result: FrameResult) {
        guard case .applied = result else { return }
        wrote(tile, revision: revision, frame: requested)
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
    private var owners: [TileID: Int32] = [:]
    private let worker: (Int32) -> AppWorker?
    private let log: (String) -> Void

    init(worker: @escaping (Int32) -> AppWorker?, log: @escaping (String) -> Void) {
        self.worker = worker
        self.log = log
    }

    func setFrame(_ request: FrameRequest) {
        guard let worker = worker(request.pid) else {
            return log("executor: no app thread pid=\(request.pid) tile=\(request.tile.rawValue) rev=\(request.revision)")
        }
        owners[request.tile] = request.pid
        worker.write(request.tile, revision: request.revision, frame: request.frame.rect)
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

    func wrote(_ tile: TileID, revision: UInt64, frame: CGRect, result: FrameResult) {
        ledger.record(tile, revision: revision, requested: frame, result: result)
        guard case .applied = result else { return log("executor: write failed tile=\(tile.rawValue) rev=\(revision) result=\(result)") }
        log("executor: wrote tile=\(tile.rawValue) rev=\(revision)")
    }

    /// True when a move or resize came from the user; echoes and repeats are dropped here with a log line.
    func isForeign(_ tile: TileID, frame: CGRect) -> Bool {
        switch ledger.classify(tile, observed: frame) {
        case .echo(let revision):
            log("executor: echo dropped rev=\(revision) tile=\(tile.rawValue)")
            return false
        case .repeated:
            log("executor: app kept its own frame tile=\(tile.rawValue) frame=\(frame)")
            return false
        case .foreign:
            return true
        }
    }

    func focus(_ tile: TileID, pid: Int32) {
        worker(pid)?.run(tile) { $0.focus() }
    }

    func raise(_ tile: TileID, pid: Int32) {
        worker(pid)?.run(tile) { _ = $0.raise() }
    }

    func close(_ tile: TileID, pid: Int32) {
        worker(pid)?.run(tile) { _ = $0.close() }
    }
}
