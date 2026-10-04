import Engine
import Foundation

/// The only reader and writer of the state file. It keeps the newest book only, so a write queued before a
/// `clear-positions` can never land after it: the clear replaced what it would have written (73ef68d). Writes are
/// atomic. A missing file is an empty book; an unreadable one, or one of another version, is a logged fresh start.
@MainActor
public final class SnapshotStore {
    public static let fileName = "next-spaces.json"
    /// Focus and width changes come in bursts; one write a second is plenty for a file read only at launch.
    public static let writeDelay = 1.0

    public let path: String
    private var pending: [Snapshot]?
    private var timer: Timer?
    private let log: (String) -> Void

    public init(directory: String, log: @escaping (String) -> Void) {
        path = directory + "/" + Self.fileName
        self.log = log
    }

    public func load() -> [Snapshot] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        do {
            let snapshots = try SpaceBook.decode(data)
            log("store: loaded \(snapshots.count) saved strip(s) from \(path)")
            return snapshots
        } catch {
            log("store: starting fresh, \(path) is unreadable: \(error)")
            return []
        }
    }

    public func list() -> [Snapshot] { pending ?? load() }

    public func clear() {
        save([])
        flush()
    }

    /// Keep `snapshots` as the next write, replacing any not yet written.
    public func save(_ snapshots: [Snapshot]) {
        pending = snapshots
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.writeDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Write the pending book now: at a clear, and before quitting.
    public func flush() {
        timer?.invalidate()
        timer = nil
        guard let snapshots = pending else { return }
        pending = nil
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try SpaceBook.encode(snapshots).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            log("store: write failed: \(error)")
        }
    }
}
