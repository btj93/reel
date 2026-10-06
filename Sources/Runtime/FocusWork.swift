import Core
import Engine
import Foundation

/// A focus effect is valid only until the next decision or scope change. The app queue checks this immediately
/// before calling AX, not when work is queued on the main actor.
struct FocusTicket: Equatable, Sendable {
    let generation: UInt64
    let scope: EventScope
    let tile: TileID
    let pid: Int32
}

private struct FocusContext: Equatable {
    let stamp: Stamp
    let focus: [UInt32: FocusState]
    let changing: Set<UInt32>
    let paused: Bool
}

final class FocusWork: @unchecked Sendable {
    private struct Executed {
        let ticket: FocusTicket
        let time: Double
    }
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var observationGeneration: UInt64 = 0
    private var context: FocusContext?
    private var executed: [Executed] = []

    func synchronize(_ world: World, paused: Bool) {
        let next = FocusContext(stamp: world.stamp, focus: world.groups.mapValues(\.focus),
                                changing: Set(world.groups.filter { !$0.value.phase.acceptsFocus }.keys), paused: paused)
        lock.withLock {
            if context != next { generation &+= 1 }
            if context?.stamp != next.stamp || context?.paused != next.paused || context?.changing != next.changing
                || next.focus.contains(where: { id, focus in
                    guard let decision = focus.decision, decision.requestsOSFocus else { return false }
                    return context?.focus[id]?.decision != decision
                }) {
                observationGeneration &+= 1
            }
            context = next
        }
    }

    var currentObservationGeneration: UInt64 { lock.withLock { observationGeneration } }

    func invalidate() { lock.withLock { generation &+= 1; observationGeneration &+= 1 } }

    func ticket(tile: TileID, pid: Int32, scope: EventScope) -> FocusTicket {
        lock.withLock {
            generation &+= 1
            observationGeneration &+= 1
            return FocusTicket(generation: generation, scope: scope, tile: tile, pid: pid)
        }
    }

    func claim(_ ticket: FocusTicket, focus: Bool, now: Double) -> Bool {
        lock.withLock {
            guard ticket.generation == generation, let context, !context.paused,
                  !context.changing.contains(ticket.scope.group),
                  context.stamp.revision == ticket.scope.topologyRevision,
                  context.stamp.epochs[ticket.scope.group] == ticket.scope.spaceEpoch else { return false }
            if focus {
                executed.removeAll { now - $0.time >= EngineConfig.focusDebounce }
                executed.append(Executed(ticket: ticket, time: now))
            }
            return true
        }
    }

    /// One OS activation acknowledges one focus that really executed. A mere reducer decision or queued write is
    /// not an echo. Keep earlier executed tickets across invalidation so A's delayed activation cannot beat B.
    func consumeEcho(pid: Int32, now: Double) -> Bool {
        lock.withLock {
            executed.removeAll { now - $0.time >= EngineConfig.focusDebounce }
            guard let index = executed.firstIndex(where: { $0.ticket.pid == pid && now >= $0.time }) else { return false }
            executed.remove(at: index)
            return true
        }
    }
}
