import Core
import Foundation

struct Pass {
    let now: Double
    let scope: EventScope
    var effects: [Effect] = []
    var layout = Set<UInt32>()
    var persist = false
}

public func reduce(_ world: inout World, _ event: Event, now: TimeInterval) -> [Effect] {
    guard now.isFinite, now >= world.time else { return [.log("rejected clock")] }
    guard event.scope.topologyRevision == world.topology.revision else { return [] }
    guard event.kind.isGlobal || world.scope(for: event.scope.group) == event.scope else { return [] }
    world.time = now
    world.expireMomentum(now)
    var pass = Pass(now: now, scope: event.scope)
    let id = event.scope.group
    switch event.kind {
    case .topologyChanged(let topology): world.onTopology(topology, &pass)
    case .configChanged(let config): world.onConfig(config, &pass)
    case .loadSnapshots(let snapshots): world.spaces.disk = snapshots.filter(\.isValid)
    case .windowAdded(let window): world.onWindowAdded(window, group: id, &pass)
    case .windowRemoved(let tile):
        world.remove(tile, from: id, &pass)
        pass.persist = true
    case .focus(let intent): world.onFocusObserved(intent, group: id, &pass)
    case .command(let command, let source): _ = world.run(command, source: source, group: id, &pass)
    case .ipc(let requestID, let command):
        let outcome = world.run(command, source: .ipc, group: id, &pass)
        pass.effects.append(.reply(id: requestID, payload: .command(outcome)))
    case .query(let requestID):
        let snapshots = world.groups.keys.sorted().compactMap { groupID in
            world.groups[groupID].flatMap { snapshot($0, id: groupID, time: now) }
        }
        pass.effects.append(.reply(id: requestID, payload: .snapshots(snapshots)))
    case .pointer(let input, let token): world.onPointer(input, token: token, group: id, &pass)
    case .spaceWillChange: world.beginSpaceChange(group: id, &pass)
    case .spaceChanged(let key, let epoch, let windows): world.onSpaceChanged(key: key, epoch: epoch, windows: windows, group: id, &pass)
    case .frameCompleted(let tile, let revision, let result): world.onFrameCompleted(tile, revision: revision, result: result, &pass)
    case .timer(let token): world.onTimer(token, group: id, &pass)
    case .tick: world.onTick(group: id, &pass)
    }
    world.flush(&pass)
    return pass.effects
}

extension World {
    mutating func expireMomentum(_ now: Double) {
        if case .momentum(_, let settled?) = pointer, now - settled >= EngineConfig.gestureQuiet { pointer = .idle }
    }

    fileprivate mutating func nextRevision() -> UInt64 {
        serial += 1
        return serial
    }

    fileprivate mutating func cancelTimers(group: UInt32, _ pass: inout Pass, focusOnly: Bool = false) {
        for token in timers.keys.sorted() {
            guard let work = timers[token], work.scope.group == group else { continue }
            if focusOnly, case .retryFrames = work.action { continue }
            timers.removeValue(forKey: token)
            pass.effects.append(.cancel(token))
        }
    }

    fileprivate mutating func schedule(_ action: ScheduledAction, delay: Double, _ pass: inout Pass) {
        let token = TimerToken(nextRevision())
        let deadline = pass.now + delay
        timers[token] = ScheduledWork(scope: pass.scope, deadline: deadline, action: action)
        pass.effects.append(.schedule(token: token, deadline: deadline, event: Event(scope: pass.scope, kind: .timer(token))))
    }

    fileprivate mutating func invalidate(_ tile: TileID, _ pass: inout Pass) {
        frames.removeValue(forKey: tile)
        appliedFrames.removeValue(forKey: tile)
        pass.effects.append(.invalidateFrame(tile: tile, revision: nextRevision()))
    }

    fileprivate mutating func cancelPointer(_ pass: inout Pass) {
        switch pointer {
        case .gesture(let session):
            if var group = groups[session.scope.group] {
                group.strip.viewOffset = .static(group.strip.viewOffset.current(at: pass.now))
                groups[session.scope.group] = group
                pass.layout.insert(session.scope.group)
            }
        case .menu, .reorder: pass.effects.append(.overlay(.hidden))
        case .idle, .momentum: break
        }
        pointer = .idle
    }

    // MARK: Focus

    fileprivate mutating func onFocusObserved(_ intent: FocusIntent, group id: UInt32, _ pass: inout Pass) {
        let group = groups[id]!
        guard !group.phase.isChanging || intent.source == .appActivation else { return }
        if !intent.source.centers, pointer.isSwiping(group: id) {
            pass.effects.append(.log("focus suppressed during swipe source=\(intent.source.rawValue)"))
            return
        }
        cancelTimers(group: id, &pass, focusOnly: true)
        let local = intent.source == .appActivation && group.windows.values.contains { $0.pid == intent.pid }
        guard intent.source == .axFocus || local else { return focus(intent, group: id, &pass) }
        if let previous = group.focus.decision, previous.source.protectsFocus, pass.now - previous.time < EngineConfig.focusDebounce { return }
        if let tile = intent.tile, group.windows[tile] != nil { schedule(.focus(intent), delay: EngineConfig.focusDebounce, &pass) }
    }

    fileprivate mutating func focus(_ intent: FocusIntent, group id: UInt32, _ pass: inout Pass) {
        guard var group = groups[id] else { return }
        if let observed = intent.observedSpace, observed.isAuthoritative,
           let current = group.space, current.isAuthoritative, observed != current { return }
        if intent.source == .appActivation, let pid = intent.pid, !group.windows.values.contains(where: { $0.pid == pid }) {
            group.focus = .crossing(intent: intent, time: pass.now, previous: group.focus.decision)
            groups[id] = group
            return
        }
        guard !group.phase.isChanging, let tile = intent.tile, group.windows[tile] != nil else { return }
        if pointer.isSwiping(group: id) {
            guard intent.source.centers else { return }
            cancelPointer(&pass)
            group = groups[id]!
        }
        if let index = group.strip.columnIndex(of: tile) {
            if intent.source.centers {
                let previousX = group.strip.columnX(at: group.strip.activeColumnIndex, time: pass.now)
                group.strip.viewOffset.shiftBy(previousX - group.strip.columnX(at: index, time: pass.now))
                group.strip.activeColumnIndex = index
                group.strip.snapIndices[index] = group.strip.defaultSnapIndex
                group.strip.recenter(animated: config.animate, at: pass.now)
            } else {
                group.strip.focusColumnIncremental(colIndex: index, at: pass.now, animated: config.animate)
            }
            group.strip.columns[index].activeTileIndex = group.strip.columns[index].tiles.firstIndex(of: tile)!
        }
        group.focus = .resolved(FocusDecision(tile: tile, source: intent.source, time: pass.now))
        groups[id] = group
        if intent.source != .axFocus {
            pass.effects.append(.focus(tile: tile, source: intent.source))
            pass.effects.append(.raise(tile))
        }
        pass.effects.append(.log("focus source=\(intent.source.rawValue) tile=\(tile.rawValue)"))
        pass.layout.insert(id)
        pass.persist = true
    }

    // MARK: Membership

    fileprivate mutating func onWindowAdded(_ window: ObservedWindow, group id: UInt32, _ pass: inout Pass) {
        let known = groups.values.contains { $0.windows[window.id] != nil }
        add(window, to: id, &pass)
        if !known { focus(FocusIntent(tile: window.id, source: .adoption), group: id, &pass) }
        pass.persist = true
    }

    fileprivate mutating func add(_ window: ObservedWindow, to id: UInt32, _ pass: inout Pass) {
        guard window.isValid, var group = groups[id], case .settled = group.phase,
              !groups.values.contains(where: { $0.windows[window.id] != nil }) else { return }
        cancelTimers(group: id, &pass, focusOnly: true)
        group.windows[window.id] = window
        if shouldFloat(window, config: config) { group.floating.insert(window.id) }
        else { group.strip.insertTile(window.id, at: pass.now) }
        groups[id] = group
        pass.layout.insert(id)
    }

    fileprivate mutating func remove(_ tile: TileID, from id: UInt32, _ pass: inout Pass) {
        guard let current = groups[id], !current.phase.isChanging, current.windows[tile] != nil else { return }
        cancelTimers(group: id, &pass, focusOnly: true)
        if pointer.tile == tile { cancelPointer(&pass) }
        var group = groups[id]!
        group.strip.removeTile(tile, at: pass.now)
        group.windows.removeValue(forKey: tile)
        group.floating.remove(tile)
        if group.focus.decision?.tile == tile { group.focus = .none }
        groups[id] = group
        invalidate(tile, &pass)
        for (key, saved) in spaces.live where saved.windows.contains(where: { $0.id == tile }) {
            let pruned = removing(tile, from: saved)
            spaces.live[key] = pruned.windows.isEmpty ? nil : pruned
        }
        pass.layout.insert(id)
    }

    // MARK: Commands

    fileprivate mutating func run(_ command: Command, source: FocusSource, group id: UInt32, _ pass: inout Pass) -> CommandOutcome {
        guard var group = groups[id], !group.phase.isChanging else { return .refused("space change in progress") }
        func missing(_ tile: TileID) -> CommandOutcome {
            group.windows[tile] == nil ? .unknownWindow(tile) : .refused("floating window")
        }
        cancelTimers(group: id, &pass, focusOnly: true)
        let now = pass.now
        var recenter = false
        switch command {
        case .focus(let tile):
            guard group.windows[tile] != nil else { return .unknownWindow(tile) }
            focus(FocusIntent(tile: tile, source: source), group: id, &pass)
            return .accepted
        case .focusLeft, .focusRight:
            guard !group.strip.columns.isEmpty else { return .refused("empty strip") }
            let delta = if case .focusLeft = command { -1 } else { 1 }
            let index = max(0, min(group.strip.columns.count - 1, group.strip.activeColumnIndex + delta))
            focus(FocusIntent(tile: group.strip.columns[index].activeTile, source: source), group: id, &pass)
            return .accepted
        case .moveLeft, .moveRight:
            guard !group.strip.columns.isEmpty else { return .refused("empty strip") }
            if case .moveLeft = command { group.strip.moveColumnLeft(at: now) } else { group.strip.moveColumnRight(at: now) }
        case .setWidth(let tile, let width):
            guard width.isFinite, width > 0 else { return .refused("invalid width") }
            guard let index = group.strip.columnIndex(of: tile) else { return missing(tile) }
            group.strip.setWidth(.fixed(width), column: index, at: now, params: config.animate ? group.strip.scrollSpringParams : nil)
            recenter = index == group.strip.activeColumnIndex
        case .cycleWidthPreset:
            guard !group.strip.columns.isEmpty else { return .refused("empty strip") }
            group.strip.cycleWidthPreset(at: now, params: config.animate ? group.strip.scrollSpringParams : nil)
            recenter = true
        case .toggleFullWidth(let tile):
            guard let index = group.strip.columnIndex(of: tile) else { return missing(tile) }
            group.strip.toggleFullWidth(at: now, column: index)
            recenter = index == group.strip.activeColumnIndex
        case .toggleFloating(let tile):
            guard group.windows[tile] != nil else { return .unknownWindow(tile) }
            if pointer.tile == tile {
                cancelPointer(&pass)
                group = groups[id]!
            }
            if group.floating.remove(tile) != nil {
                group.strip.insertTile(tile, at: now)
            } else {
                group.strip.removeTile(tile, at: now)
                group.floating.insert(tile)
                invalidate(tile, &pass)
            }
        case .close(let tile):
            guard group.windows[tile] != nil else { return .unknownWindow(tile) }
            pass.effects.append(.close(tile))
            return .accepted
        }
        if recenter, !group.strip.columns.isEmpty {
            if case .gesture = group.strip.viewOffset {} else {
                group.strip.recenter(animated: config.animate, at: now,
                                     columnWidth: group.strip.columnData[group.strip.activeColumnIndex].cachedWidth)
            }
        }
        groups[id] = group
        pass.layout.insert(id)
        pass.persist = true
        return .accepted
    }

    // MARK: Pointer

    fileprivate mutating func onPointer(_ input: PointerInput, token: PointerToken?, group id: UInt32, _ pass: inout Pass) {
        switch input {
        case .beginGesture(let tile), .openMenu(let tile), .beginReorder(let tile):
            return beginPointer(input, tile: tile, group: id, &pass)
        default:
            guard let current = pointer.token, current == token, pointer.scope == pass.scope else { return }
        }
        switch input {
        case .beginGesture, .openMenu, .beginReorder: break
        case .delta(let delta):
            guard delta.isFinite, case .gesture = pointer, var group = groups[id],
                  case .gesture(var gesture) = group.strip.viewOffset else { return cancelPointer(&pass) }
            let bounds = group.strip.viewOffsetBounds(at: pass.now)
            let next = min(max(gesture.currentOffset + delta, bounds.lowerBound), bounds.upperBound)
            gesture.tracker.push(delta: next - gesture.currentOffset, timestamp: pass.now)
            gesture.currentOffset = next
            group.strip.viewOffset = .gesture(gesture)
            groups[id] = group
            pass.layout.insert(id)
        case .endGesture:
            guard case .gesture(let session) = pointer, var group = groups[id],
                  case .gesture(let gesture) = group.strip.viewOffset else { return cancelPointer(&pass) }
            release(gesture, session: session, strip: &group.strip, at: pass.now)
            groups[id] = group
            pointer = .momentum(session.scope, settledAt: group.strip.viewOffset.isAnimating ? nil : pass.now)
            pass.layout.insert(id)
            pass.persist = true
        case .menu(let action):
            guard case .menu(let session) = pointer else { return cancelPointer(&pass) }
            cancelPointer(&pass)
            let targeted: Command
            switch action {
            case .setWidth(_, let width): targeted = .setWidth(session.tile, width)
            case .toggleFloating: targeted = .toggleFloating(session.tile)
            case .toggleFullWidth: targeted = .toggleFullWidth(session.tile)
            case .close: targeted = .close(session.tile)
            case .focus: targeted = .focus(session.tile)
            case .focusLeft, .focusRight, .moveLeft, .moveRight, .cycleWidthPreset: return
            }
            _ = run(targeted, source: .click, group: id, &pass)
        case .dropReorder(let requested):
            guard case .reorder(let session) = pointer, var group = groups[id],
                  let index = group.strip.columnIndex(of: session.tile) else { return cancelPointer(&pass) }
            group.strip.moveColumn(from: index, to: max(0, min(group.strip.columns.count - 1, requested)), at: pass.now)
            group.strip.recenter(animated: config.animate, at: pass.now)
            groups[id] = group
            cancelPointer(&pass)
            pass.layout.insert(id)
            pass.persist = true
        case .cancel: cancelPointer(&pass)
        }
    }

    private mutating func beginPointer(_ input: PointerInput, tile: TileID, group id: UInt32, _ pass: inout Pass) {
        cancelPointer(&pass)
        guard var group = groups[id], !group.phase.isChanging, group.strip.columnIndex(of: tile) != nil,
              let scope = scope(for: id) else { return }
        let token = PointerToken(nextRevision())
        switch input {
        case .beginGesture:
            var settled = group.strip
            for i in settled.columnData.indices { settled.columnData[i].widthAnimation = nil }
            let activeX = settled.columnX(at: settled.activeColumnIndex, time: pass.now)
            let targets = settled.columns.indices.map {
                settled.columnX(at: $0, time: pass.now) - activeX + settled.snapTarget(forColumn: $0, at: pass.now)
            }
            let session = GestureSession(token: token, scope: scope, tile: tile,
                                         startOffset: group.strip.viewOffset.current(at: pass.now), snapTargets: targets)
            group.strip.viewOffset = .gesture(GestureState(currentOffset: session.startOffset, isTouchpad: true))
            groups[id] = group
            pointer = .gesture(session)
        case .openMenu:
            pointer = .menu(TargetSession(token: token, scope: scope, tile: tile))
            pass.effects.append(.overlay(.menu(tile: tile, scope: scope, session: token)))
        default:
            pointer = .reorder(TargetSession(token: token, scope: scope, tile: tile))
            pass.effects.append(.overlay(.reorder(tile: tile, scope: scope, session: token)))
        }
    }

    private func release(_ gesture: GestureState, session: GestureSession, strip: inout Strip, at now: Double) {
        let current = gesture.currentOffset
        let velocity = gesture.tracker.velocity(at: now)
        let projected = abs(velocity) < EngineConfig.flickVelocity
            ? current : session.startOffset + gesture.tracker.projectedEndPosition(isTouchpad: true)
        var from = current
        var target: Double
        if config.gestureSnap, session.snapTargets.count == strip.columns.count,
           let column = session.snapTargets.indices.min(by: { abs(session.snapTargets[$0] - projected) < abs(session.snapTargets[$1] - projected) }) {
            let shift = strip.columnX(at: strip.activeColumnIndex, time: now) - strip.columnX(at: column, time: now)
            strip.activeColumnIndex = column
            from += shift
            target = session.snapTargets[column] + shift
        } else {
            let bounds = strip.viewOffsetBounds(at: now)
            target = min(max(projected, bounds.lowerBound), bounds.upperBound)
        }
        strip.viewOffset = config.animate && abs(target - from) >= 1
            ? .animation(SpringAnimation(from: from, to: target, initialVelocity: velocity, startTime: now, params: strip.scrollSpringParams))
            : .static(target)
    }

    // MARK: Spaces

    fileprivate mutating func beginSpaceChange(group id: UInt32, _ pass: inout Pass) {
        if pointer.scope?.group == id { cancelPointer(&pass) }
        cancelTimers(group: id, &pass)
        guard var group = groups[id] else { return }
        for tile in group.windows.keys.ordered() { invalidate(tile, &pass) }
        if case .settled(let key) = group.phase { group.phase = .changing(from: key, deferred: nil) }
        groups[id] = group
    }

    fileprivate mutating func onSpaceChanged(key: SpaceKey, epoch: UInt64, windows: [ObservedWindow], group id: UInt32, _ pass: inout Pass) {
        guard !key.isEmpty, let group = groups[id] else { return pass.effects.append(.log("space census without identity ignored")) }
        let verdict = censusVerdict(windows, group: id)
        if key == group.space {
            groups[id]!.phase = .settled(key)
            if case .crossing(_, _, let previous) = group.focus { groups[id]!.focus = previous.map(FocusState.resolved) ?? .none }
            if verdict == .trusted { syncMembership(windows, group: id, &pass) }
            pass.layout.insert(id)
            pass.persist = true
            return
        }
        guard epoch > group.epoch else { return pass.effects.append(.log("stale space census ignored")) }
        let deferred = group.phase.deferred
        let settled = deferred.map { pass.now - $0.since >= EngineConfig.censusSettle } ?? false
        switch verdict {
        case .trusted: break
        case .empty where group.windows.isEmpty || (settled && deferred?.key == key): break
        case .mixed where settled, .invalid where settled:
            if let from = group.space { groups[id]!.phase = .settled(from) }
            pass.effects.append(.log("\(verdict) space census dropped after settle"))
            pass.layout.insert(id)
            return
        case .empty, .mixed, .invalid:
            if case .settled = group.phase { beginSpaceChange(group: id, &pass) }
            let since = deferred.flatMap { verdict != .empty || $0.key == key ? $0.since : nil } ?? pass.now
            if let from = groups[id]!.space { groups[id]!.phase = .changing(from: from, deferred: DeferredCensus(key: key, since: since)) }
            pass.effects.append(.log("\(verdict) space census deferred"))
            pass.effects.append(.requestCensus(group: id, after: since + EngineConfig.censusSettle - pass.now))
            return
        }
        commitSpace(key, epoch: epoch, windows: windows, group: id, &pass)
    }

    private mutating func commitSpace(_ key: SpaceKey, epoch: UInt64, windows: [ObservedWindow], group id: UInt32, _ pass: inout Pass) {
        let departing = groups[id]!
        if let saved = snapshot(departing, id: id, time: pass.now) { spaces.live[GroupSpace(group: id, space: saved.space)] = saved }
        beginSpaceChange(group: id, &pass)
        let match = spaces.lookup(group: id, space: key, windows: windows)
        if let match { spaces.adopt(match, as: key) }
        let display = topology.groups.first { $0.id == id }!
        let group = restoredGroup(display: display, config: config, key: key, epoch: epoch, windows: windows,
                                  saved: match?.snapshot, identityOnly: match?.fromDisk ?? false, time: pass.now)
        groups[id] = group
        var restore = group.focus.decision?.tile ?? group.strip.activeColumn?.activeTile
        var source: FocusSource = .restore
        if case .crossing(let intent, let time, _) = departing.focus, pass.now - time <= EngineConfig.crossingTTL, let pid = intent.pid {
            let appWindows = windows.filter { $0.pid == pid }
            if let tile = intent.tile, appWindows.contains(where: { $0.id == tile }) { restore = tile; source = .appActivation }
            else if let tile = appWindows.map(\.id).ordered().first { restore = tile; source = .appActivation }
        }
        focus(FocusIntent(tile: restore, source: source), group: id, &pass)
        pass.layout.insert(id)
        pass.persist = true
    }

    private func censusVerdict(_ windows: [ObservedWindow], group id: UInt32) -> CensusVerdict {
        let otherTiles = Set(groups.filter { $0.key != id }.values.flatMap { $0.windows.keys })
        guard Set(windows.map(\.id)).count == windows.count,
              windows.allSatisfy({ $0.isValid && !otherTiles.contains($0.id) }) else { return .invalid }
        guard !windows.isEmpty else { return .empty }
        var fingerprints = spaces.live.values.filter { $0.group == id }.map(\.fingerprint)
        fingerprints.append(Set(groups[id]!.windows.keys.map(\.rawValue)))
        return spansMultipleSpaces(onScreenIDs: Set(windows.map { $0.id.rawValue }), knownFingerprints: fingerprints) ? .mixed : .trusted
    }

    private mutating func syncMembership(_ windows: [ObservedWindow], group id: UInt32, _ pass: inout Pass) {
        let present = Set(windows.map(\.id))
        for tile in groups[id]!.windows.keys.ordered() where !present.contains(tile) { remove(tile, from: id, &pass) }
        for window in visualOrder(windows) where groups[id]!.windows[window.id] == nil { add(window, to: id, &pass) }
    }

    // MARK: Frames, timers, ticks

    fileprivate mutating func onFrameCompleted(_ tile: TileID, revision: UInt64, result: FrameResult, _ pass: inout Pass) {
        guard let request = frames[tile], request.revision == revision, request.scope == pass.scope else { return }
        switch result {
        case .applied: appliedFrames[tile] = request
        case .failed, .timedOut:
            frames.removeValue(forKey: tile)
            appliedFrames.removeValue(forKey: tile)
            if !timers.values.contains(where: { if case .retryFrames = $0.action { return $0.scope == pass.scope }; return false }) {
                schedule(.retryFrames, delay: EngineConfig.frameRetryDelay, &pass)
            }
        }
    }

    fileprivate mutating func onTimer(_ token: TimerToken, group id: UInt32, _ pass: inout Pass) {
        guard let work = timers[token], work.scope == pass.scope, pass.now >= work.deadline else { return }
        timers.removeValue(forKey: token)
        switch work.action {
        case .retryFrames: pass.layout.insert(id)
        case .focus(let intent): focus(intent, group: id, &pass)
        }
    }

    fileprivate mutating func onTick(group id: UInt32, _ pass: inout Pass) {
        guard var group = groups[id], !group.phase.isChanging else { return }
        _ = group.strip.settleWidthAnimations(at: pass.now)
        _ = group.strip.settleRaiseAnimations(at: pass.now)
        if case .animation(let animation) = group.strip.viewOffset, animation.isDone(at: pass.now) {
            group.strip.viewOffset = .static(animation.to)
        }
        if case .momentum(let scope, nil) = pointer, scope.group == id, !group.strip.viewOffset.isAnimating {
            pointer = .momentum(scope, settledAt: pass.now)
        }
        groups[id] = group
        pass.layout.insert(id)
    }

    // MARK: Topology and config

    fileprivate mutating func onTopology(_ next: Topology, _ pass: inout Pass) {
        guard next.revision > topology.revision, next.isValid else { return }
        cancelPointer(&pass)
        for id in groups.keys.sorted() { cancelTimers(group: id, &pass) }
        for tile in frames.keys.ordered() { invalidate(tile, &pass) }
        let previous = groups
        let previousTopology = topology
        topology = next
        groups = [:]
        for display in next.groups {
            var group = previous[display.id] ?? GroupState(display: display, config: config)
            group.strip.groupArea = GroupState.area(for: display)
            group.strip.recalculateWidths(at: pass.now)
            if case .changing(let from, _) = group.phase { group.phase = .settled(from) }
            group.focus = .none
            groups[display.id] = group
            pass.layout.insert(display.id)
        }
        for id in previous.keys.sorted() where groups[id] == nil {
            guard let old = previous[id], let oldDisplay = previousTopology.groups.first(where: { $0.id == id }),
                  let destination = next.groups.min(by: { distance($0.frame, oldDisplay.frame) < distance($1.frame, oldDisplay.frame) })
            else { continue }
            var group = groups[destination.id]!
            if group.space == nil, let key = old.space {
                group.phase = .settled(key)
                group.epoch = old.epoch
            }
            if group.space == old.space {
                for window in old.windows.values.sorted(by: { $0.id.rawValue < $1.id.rawValue }) where group.windows[window.id] == nil {
                    group.windows[window.id] = window
                    if old.floating.contains(window.id) { group.floating.insert(window.id) }
                }
                for column in old.strip.columns { group.strip.insertColumn(column, at: pass.now, atIndex: group.strip.columns.count) }
                groups[destination.id] = group
            } else if let saved = snapshot(old, id: destination.id, time: pass.now) {
                spaces.live[GroupSpace(group: destination.id, space: saved.space)] = saved
            }
        }
        pass.persist = true
    }

    fileprivate mutating func onConfig(_ next: EngineConfig, _ pass: inout Pass) {
        config = next
        for id in groups.keys.sorted() {
            groups[id]!.strip.gap = next.gap
            groups[id]!.strip.defaultWidth = .proportion(next.defaultWidth)
            groups[id]!.strip.recalculateWidths(at: pass.now)
            pass.layout.insert(id)
        }
        pass.persist = true
    }

    // MARK: Output

    fileprivate mutating func flush(_ pass: inout Pass) {
        for id in pass.layout.sorted() {
            guard let group = groups[id], !group.phase.isChanging, let scope = scope(for: id),
                  let display = topology.groups.first(where: { $0.id == id }) else { continue }
            for target in computeTargetFrames(strip: group.strip, time: pass.now) {
                let frame = axRect(ViewportRect(target.frame), on: display)
                guard frame.rect.isFinite, let pid = group.windows[target.tileID]?.pid else {
                    pass.effects.append(.log("invalid layout rejected"))
                    continue
                }
                if let existing = frames[target.tileID], existing.frame == frame, existing.scope == scope { continue }
                let request = FrameRequest(tile: target.tileID, pid: pid, frame: frame, revision: nextRevision(), scope: scope)
                frames[target.tileID] = request
                pass.effects.append(.setFrame(request))
            }
        }
        guard pass.persist else { return }
        for id in groups.keys.sorted() {
            if let group = groups[id], let saved = snapshot(group, id: id, time: pass.now) {
                spaces.live[GroupSpace(group: id, space: saved.space)] = saved
            }
        }
        pass.effects.append(.persist(spaces))
    }
}

enum CensusVerdict: CustomStringConvertible {
    case trusted, empty, mixed, invalid

    var description: String {
        switch self {
        case .trusted: "trusted"
        case .empty: "empty"
        case .mixed: "mixed"
        case .invalid: "invalid"
        }
    }
}

extension Strip {
    func columnIndex(of tile: TileID) -> Int? { columns.firstIndex { $0.tiles.contains(tile) } }

    mutating func insertTile(_ tile: TileID, at time: Double) {
        insertColumn(Column(tiles: [tile], width: defaultWidth), at: time)
    }

    mutating func removeTile(_ tile: TileID, at time: Double) {
        guard let index = columnIndex(of: tile) else { return }
        columns[index].tiles.removeAll { $0 == tile }
        if columns[index].tiles.isEmpty { removeColumn(at: index, at: time) }
        else { columns[index].activeTileIndex = min(columns[index].activeTileIndex, columns[index].tiles.count - 1) }
    }

    mutating func recenter(animated: Bool, at time: Double, columnWidth: Double? = nil) {
        if animated { _ = recenterActiveColumnAnimated(at: time, columnWidth: columnWidth) }
        else { recenterActiveColumn(at: time) }
    }
}

extension ViewOffset {
    var isAnimating: Bool {
        if case .animation = self { return true }
        return false
    }
}

extension Sequence where Element == TileID {
    func ordered() -> [TileID] { sorted { $0.rawValue < $1.rawValue } }
}

private func shouldFloat(_ window: ObservedWindow, config: EngineConfig) -> Bool {
    config.rules.last(where: { window.bundleID == $0.bundleID })?.floating ?? window.floating
}

private func distance(_ lhs: CGRect, _ rhs: CGRect) -> Double {
    hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
}

private func visualOrder(_ windows: [ObservedWindow]) -> [ObservedWindow] {
    windows.sorted {
        let lhsX = $0.initialFrame?.rect.minX ?? 0
        let rhsX = $1.initialFrame?.rect.minX ?? 0
        if lhsX != rhsX { return lhsX < rhsX }
        return $0.id.rawValue < $1.id.rawValue
    }
}

private func removing(_ tile: TileID, from saved: Snapshot) -> Snapshot {
    let columns = saved.columns.compactMap { column -> SnapshotColumn? in
        let windows = column.windows.filter { $0.id != tile }
        guard !windows.isEmpty else { return nil }
        return SnapshotColumn(windows: windows, width: column.width, activeTileIndex: min(column.activeTileIndex, windows.count - 1),
                              snapIndex: column.snapIndex, presetIndex: column.presetIndex, isFullWidth: column.isFullWidth)
    }
    return Snapshot(group: saved.group, space: saved.space, columns: columns, floating: saved.floating.filter { $0.id != tile },
                    activeColumnIndex: min(saved.activeColumnIndex, max(0, columns.count - 1)), offset: saved.offset,
                    focusedTile: saved.focusedTile == tile ? nil : saved.focusedTile)
}

private func restoredGroup(display: DisplayGroup, config: EngineConfig, key: SpaceKey, epoch: UInt64, windows: [ObservedWindow],
                           saved: Snapshot?, identityOnly: Bool, time: Double) -> GroupState {
    var group = GroupState(display: display, config: config)
    group.phase = .settled(key)
    group.epoch = epoch
    group.windows = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
    var unused = Set(windows.map(\.id))
    var mappedIDs: [TileID: TileID] = [:]
    let byID = windows.sorted { $0.id.rawValue < $1.id.rawValue }
    func match(_ window: ObservedWindow) -> ObservedWindow? {
        let sameID = identityOnly ? nil : byID.first { $0.id == window.id && unused.contains($0.id) }
        let candidate = sameID ?? byID.first { WindowIdentity($0) == WindowIdentity(window) && unused.contains($0.id) }
        if let candidate { unused.remove(candidate.id); mappedIDs[window.id] = candidate.id }
        return candidate
    }
    if let saved {
        for column in saved.columns {
            let matched = column.windows.compactMap { match($0) }
            let tiled = matched.filter { !shouldFloat($0, config: config) }
            for window in matched where shouldFloat(window, config: config) { group.floating.insert(window.id) }
            guard !tiled.isEmpty else { continue }
            var restored = Column(tiles: tiled.map(\.id), width: column.width)
            let active = mappedIDs[column.windows[column.activeTileIndex].id]
            restored.activeTileIndex = tiled.firstIndex(where: { $0.id == active }) ?? min(column.activeTileIndex, tiled.count - 1)
            restored.presetIndex = column.presetIndex.flatMap { group.strip.widthPresets.indices.contains($0) ? $0 : nil }
            restored.isFullWidth = column.isFullWidth
            group.strip.insertColumn(restored, at: time, atIndex: group.strip.columns.count)
            group.strip.snapIndices[group.strip.columns.count - 1] = min(column.snapIndex, max(0, group.strip.snapPoints.count - 1))
        }
        for window in saved.floating { if let match = match(window) { group.floating.insert(match.id) } }
    }
    for window in visualOrder(windows) where unused.contains(window.id) {
        if shouldFloat(window, config: config) { group.floating.insert(window.id) }
        else { group.strip.insertColumn(Column(tiles: [window.id], width: group.strip.defaultWidth), at: time, atIndex: group.strip.columns.count) }
    }
    group.strip.activeColumnIndex = min(saved?.activeColumnIndex ?? 0, max(0, group.strip.columns.count - 1))
    group.strip.viewOffset = .static(saved?.offset ?? 0)
    if let oldFocus = saved?.focusedTile, let focused = mappedIDs[oldFocus] {
        group.focus = .resolved(FocusDecision(tile: focused, source: .restore, time: time))
    }
    group.strip.recalculateWidths(at: time)
    return group
}
