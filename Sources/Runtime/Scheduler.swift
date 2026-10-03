import Engine
import Foundation

/// Delayed work, each job under a token owned by a strip. `reduce` cancels the tokens its owners drop, and a job that
/// fires still checks its owner's scope, so a timer can never act for a Space or topology that has moved on.
@MainActor
public final class Scheduler {
    public enum Key: Hashable, Sendable {
        case engine(TimerToken)
        /// One pending census re-read per group; a new request replaces the old one.
        case census(group: UInt32)
    }

    public enum Job: Sendable {
        case event(Event)
        case census(group: UInt32)
    }

    private struct Entry {
        let deadline: Double
        let owner: EventScope
        let job: Job
    }

    private var entries: [Key: Entry] = [:]
    private var timer: Timer?
    private let clock: () -> Double
    private let isCurrent: (EventScope) -> Bool
    private let deliver: (Job) -> Void
    private let log: (String) -> Void

    /// `isCurrent` answers whether an owner scope is still live, `deliver` runs a due job. Neither is called after
    /// the job's token was cancelled.
    public init(clock: @escaping () -> Double, isCurrent: @escaping (EventScope) -> Bool,
                deliver: @escaping (Job) -> Void, log: @escaping (String) -> Void) {
        self.clock = clock
        self.isCurrent = isCurrent
        self.deliver = deliver
        self.log = log
    }

    public var pendingCount: Int { entries.count }

    public func schedule(_ key: Key, deadline: Double, owner: EventScope, job: Job) {
        entries[key] = Entry(deadline: deadline, owner: owner, job: job)
        arm()
    }

    public func cancel(_ key: Key) {
        guard entries.removeValue(forKey: key) != nil else { return }
        arm()
    }

    /// Deliver every due job whose owner is still current, earliest first. Stale jobs are dropped with a log line.
    public func fire(now: Double) {
        let due = entries.filter { $0.value.deadline <= now }.sorted { $0.value.deadline < $1.value.deadline }
        for (key, entry) in due {
            // An earlier job in this batch may have cancelled this one.
            guard entries.removeValue(forKey: key) != nil else { continue }
            guard isCurrent(entry.owner) else {
                log("scheduler: dropped \(key) for a stale owner epoch=\(entry.owner.spaceEpoch) rev=\(entry.owner.topologyRevision)")
                continue
            }
            deliver(entry.job)
        }
        arm()
    }

    private func arm() {
        timer?.invalidate()
        timer = nil
        guard let next = entries.values.map(\.deadline).min() else { return }
        let timer = Timer(timeInterval: max(0, next - clock()), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self.map { $0.fire(now: $0.clock()) } }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
