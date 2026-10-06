import Core
import Foundation

let runtimeTimestamps = ProcessInfo.processInfo.environment["REEL_LOG_TIMESTAMPS"] == "1"

func runtimeTrace(_ line: @autoclosure () -> String) {
    guard runtimeTimestamps else { return }
    writeRuntimeLog(String(format: "[%.6f] %@", TimeUtil.now(), line()))
}

/// Coalesces app discovery while a census waits for windows the server lists but AX has not reported yet.
@MainActor
public final class CensusDiscovery {
    private struct Pending {
        let timer: Timer
        var waiters: [() -> Void]
    }
    private var pending: [Int32: Pending] = [:]
    private let request: (Int32) -> Void

    public init(request: @escaping (Int32) -> Void) { self.request = request }

    public func refresh(_ pids: Set<Int32>, completion: @escaping () -> Void) {
        guard !pids.isEmpty else { return completion() }
        runtimeTrace("census discovery: waiting pids=\(pids.sorted())")
        var remaining = pids
        let finished: (Int32) -> Void = { pid in
            remaining.remove(pid)
            if remaining.isEmpty { completion() }
        }
        var fresh: [Int32] = []
        for pid in pids.sorted() {
            if pending[pid] != nil {
                pending[pid]!.waiters.append { finished(pid) }
            } else {
                let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reported(pid) }
                }
                pending[pid] = Pending(timer: timer, waiters: [{ finished(pid) }])
                RunLoop.main.add(timer, forMode: .common)
                fresh.append(pid)
            }
        }
        fresh.forEach(request)
    }

    public func reported(_ pid: Int32) {
        guard let entry = pending.removeValue(forKey: pid) else { return }
        entry.timer.invalidate()
        runtimeTrace("census discovery: reported pid=\(pid)")
        entry.waiters.forEach { $0() }
    }
}

public func censusAdoption(_ memberships: Set<UInt64>?, observed: SpaceKey?, settled: SpaceKey?) -> Bool {
    guard observed == nil || observed == settled else { return false }
    return censusMembership(memberships, matches: observed)
}

public func censusMembership(_ memberships: Set<UInt64>?, matches space: SpaceKey?) -> Bool {
    guard case .skylight(let sid) = space, let memberships else { return true }
    return memberships.contains(sid)
}
