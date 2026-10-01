import Core
import Foundation

public func reduce(_ world: inout World, _ event: Event, now: TimeInterval) -> [Effect] {
    guard now.isFinite, now >= world.time else { return [.log("rejected clock")] }
    guard event.scope.topologyRevision == world.topology.revision else { return [] }
    switch event.kind {
    case .topologyChanged, .loadSnapshots: break
    default: guard world.scope(for: event.scope.group) == event.scope else { return [] }
    }
    world.time = now
    var effects: [Effect] = []
    var layoutGroups = Set<UInt32>()
    var shouldPersist = false

    func nextRevision() -> UInt64 {
        world.serial += 1
        return world.serial
    }

    func cancelTimers(_ group: UInt32) {
        for token in world.timers.keys.sorted(by: { $0.rawValue < $1.rawValue }) where world.timers[token]?.scope.group == group {
            world.timers.removeValue(forKey: token)
            effects.append(.cancel(token))
        }
    }

    func cancelFocusTimers(_ id: UInt32) {
        for token in world.timers.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let work = world.timers[token], work.scope.group == id, case .focus = work.action else { continue }
            world.timers.removeValue(forKey: token)
            effects.append(.cancel(token))
        }
    }

    func schedule(_ action: ScheduledAction, scope: EventScope, delay: Double) {
        let token = TimerToken(nextRevision())
        world.timers[token] = ScheduledWork(scope: scope, deadline: now + delay, action: action)
        effects.append(.schedule(token: token, deadline: now + delay, event: Event(scope: scope, kind: .timer(token))))
    }

    func invalidate(_ tile: TileID) {
        world.frames.removeValue(forKey: tile)
        world.appliedFrames.removeValue(forKey: tile)
        effects.append(.invalidateFrame(tile: tile, revision: nextRevision()))
    }

    func cancelPointer() {
        if case .gesture(let session) = world.pointer,
           var group = world.groups[session.scope.group] {
            group.strip.viewOffset = .static(group.strip.viewOffset.current(at: now))
            world.groups[session.scope.group] = group
            layoutGroups.insert(session.scope.group)
        }
        if world.pointer.session != nil { effects.append(.overlay(.hidden)) }
        world.pointer = .idle
    }

    func persist() { shouldPersist = true }

    func focus(_ intent: FocusIntent, group id: UInt32) {
        guard var group = world.groups[id] else { return }
        if intent.source == .appActivation, let appID = intent.appID,
           !group.windows.values.contains(where: { $0.appID == appID }) {
            if let observed = intent.observedSpace, observed.isAuthoritative,
               let current = group.space, current.isAuthoritative, observed != current { return }
            group.focus = .crossing(intent: intent, time: now, previous: group.focus.decision)
            world.groups[id] = group
            return
        }
        guard !group.changingSpace, let tile = intent.tile, group.windows[tile] != nil else { return }
        if case .gesture(let session) = world.pointer, session.scope.group == id { cancelPointer(); group = world.groups[id]! }
        if let index = group.strip.columns.firstIndex(where: { $0.tiles.contains(tile) }) {
            if intent.source.centers {
                let previousX = group.strip.columnX(at: group.strip.activeColumnIndex, time: now)
                let nextX = group.strip.columnX(at: index, time: now)
                group.strip.viewOffset.shiftBy(previousX - nextX)
                group.strip.activeColumnIndex = index
                group.strip.snapIndices[index] = group.strip.defaultSnapIndex
                if world.config.animate { _ = group.strip.recenterActiveColumnAnimated(at: now) }
                else { group.strip.recenterActiveColumn(at: now) }
            } else {
                group.strip.focusColumnIncremental(colIndex: index, at: now, animated: world.config.animate)
            }
            group.strip.columns[index].activeTileIndex = group.strip.columns[index].tiles.firstIndex(of: tile)!
        }
        group.focus = .resolved(FocusDecision(tile: tile, source: intent.source, time: now))
        world.groups[id] = group
        if intent.source != .axNotification {
            effects.append(.focus(tile: tile, source: intent.source))
            effects.append(.raise(tile))
        }
        effects.append(.log("focus source=\(intent.source.rawValue) tile=\(tile.rawValue)"))
        layoutGroups.insert(id)
        persist()
    }

    func add(_ window: ObservedWindow, to id: UInt32) {
        guard window.id.rawValue != 0, var group = world.groups[id], group.space != nil, !group.changingSpace,
              !world.groups.values.contains(where: { $0.windows[window.id] != nil }) else { return }
        cancelFocusTimers(id)
        group.windows[window.id] = window
        if shouldFloat(window, config: world.config) { group.floating.insert(window.id) }
        else { group.strip.insertColumn(Column(tiles: [window.id], width: .proportion(world.config.defaultWidth)), at: now, atIndex: group.strip.columns.count) }
        world.groups[id] = group
        layoutGroups.insert(id)
    }

    func remove(_ tile: TileID, from id: UInt32) {
        guard var group = world.groups[id], !group.changingSpace, group.windows[tile] != nil else { return }
        cancelFocusTimers(id)
        if world.pointer.session?.tile == tile { cancelPointer(); group = world.groups[id]! }
        if let index = group.strip.columns.firstIndex(where: { $0.tiles.contains(tile) }) {
            group.strip.columns[index].tiles.removeAll { $0 == tile }
            if group.strip.columns[index].tiles.isEmpty { group.strip.removeColumn(at: index, at: now) }
            else { group.strip.columns[index].activeTileIndex = min(group.strip.columns[index].activeTileIndex, group.strip.columns[index].tiles.count - 1) }
        }
        group.windows.removeValue(forKey: tile)
        group.floating.remove(tile)
        if group.focus.decision?.tile == tile { group.focus = .none }
        world.groups[id] = group
        invalidate(tile)
        for (key, saved) in world.spaces.live where saved.windows.contains(where: { $0.id == tile }) {
            world.spaces.live[key] = removing(tile, from: saved)
        }
        layoutGroups.insert(id)
    }

    func command(_ command: Command, source: FocusSource, group id: UInt32) {
        guard var group = world.groups[id], !group.changingSpace else { return }
        cancelFocusTimers(id)
        var recenterWidth = false
        switch command {
        case .focus(let tile): focus(FocusIntent(tile: tile, source: source), group: id); return
        case .focusLeft, .focusRight:
            guard !group.strip.columns.isEmpty else { return }
            let delta = if case .focusLeft = command { -1 } else { 1 }
            let index = max(0, min(group.strip.columns.count - 1, group.strip.activeColumnIndex + delta))
            focus(FocusIntent(tile: group.strip.columns[index].activeTile, source: source), group: id)
            return
        case .moveLeft: group.strip.moveColumnLeft(at: now)
        case .moveRight: group.strip.moveColumnRight(at: now)
        case .setWidth(let tile, let width):
            guard width.isFinite, width > 0, let index = group.strip.columns.firstIndex(where: { $0.tiles.contains(tile) }) else { return }
            let target = ColumnWidth.fixed(width).resolve(workingAreaWidth: Double(group.strip.workingArea.width), gap: group.strip.gap)
            let current = group.strip.columnData[index].currentWidth(at: now)
            group.strip.columns[index].width = .fixed(width)
            group.strip.columns[index].isFullWidth = false
            group.strip.columns[index].presetIndex = nil
            if world.config.animate {
                group.strip.columnData[index].widthAnimation = group.strip.columnData[index].widthAnimation?.retargeted(to: target, at: now)
                    ?? SpringAnimation(from: current, to: target, startTime: now, params: group.strip.scrollSpringParams)
            } else { group.strip.columnData[index].widthAnimation = nil }
            group.strip.columnData[index].cachedWidth = target
            recenterWidth = index == group.strip.activeColumnIndex
        case .cycleWidthPreset:
            group.strip.cycleWidthPreset(at: now, params: world.config.animate ? group.strip.scrollSpringParams : nil)
            recenterWidth = true
        case .toggleFullWidth(let tile):
            guard let index = group.strip.columns.firstIndex(where: { $0.tiles.contains(tile) }) else { return }
            group.strip.toggleFullWidth(at: now, column: index)
            recenterWidth = index == group.strip.activeColumnIndex
        case .toggleFloating(let tile):
            guard group.windows[tile] != nil else { return }
            if world.pointer.session?.tile == tile { cancelPointer(); group = world.groups[id]! }
            if group.floating.remove(tile) != nil {
                group.strip.insertColumn(Column(tiles: [tile], width: .proportion(world.config.defaultWidth)), at: now)
            } else if let index = group.strip.columns.firstIndex(where: { $0.tiles.contains(tile) }) {
                group.strip.columns[index].tiles.removeAll { $0 == tile }
                if group.strip.columns[index].tiles.isEmpty { group.strip.removeColumn(at: index, at: now) }
                else { group.strip.columns[index].activeTileIndex = min(group.strip.columns[index].activeTileIndex, group.strip.columns[index].tiles.count - 1) }
                group.floating.insert(tile)
                invalidate(tile)
            }
        case .close(let tile):
            if group.windows[tile] != nil { effects.append(.close(tile)) }
            return
        }
        if recenterWidth, !group.strip.columns.isEmpty {
            switch group.strip.viewOffset {
            case .gesture: break
            default:
                if world.config.animate {
                    _ = group.strip.recenterActiveColumnAnimated(at: now, columnWidth: group.strip.columnData[group.strip.activeColumnIndex].cachedWidth)
                } else { group.strip.recenterActiveColumn(at: now) }
            }
        }
        world.groups[id] = group
        layoutGroups.insert(id)
        persist()
    }

    func pointer(_ input: PointerInput, group id: UInt32) {
        switch input {
        case .beginGesture(let tile), .openMenu(let tile), .beginReorder(let tile):
            cancelPointer()
            guard var group = world.groups[id], !group.changingSpace,
                  let index = group.strip.columns.firstIndex(where: { $0.tiles.contains(tile) }), let scope = world.scope(for: id) else { return }
            var settled = group.strip
            for i in settled.columnData.indices { settled.columnData[i].widthAnimation = nil }
            let activeX = settled.columnX(at: settled.activeColumnIndex, time: now)
            let targets = settled.columns.indices.map {
                settled.columnX(at: $0, time: now) - activeX + settled.snapTarget(forColumn: $0, at: now)
            }
            let session = PointerSession(scope: scope, tile: tile, startOffset: group.strip.viewOffset.current(at: now),
                                         snapWidth: group.strip.columnData[index].cachedWidth, snapTargets: targets)
            switch input {
            case .beginGesture:
                group.strip.viewOffset = .gesture(GestureState(currentOffset: session.startOffset, isTouchpad: true))
                world.pointer = .gesture(session)
            case .openMenu:
                world.pointer = .menu(session)
                effects.append(.overlay(.menu(tile: tile, scope: scope)))
            default:
                world.pointer = .reorder(session)
                effects.append(.overlay(.reorder(tile: tile, scope: scope)))
            }
            world.groups[id] = group
        case .delta(let delta):
            guard delta.isFinite, case .gesture(var session) = world.pointer, session.scope == event.scope,
                  var group = world.groups[id], case .gesture(var gesture) = group.strip.viewOffset else { cancelPointer(); return }
            session.delta += delta
            guard session.delta.isFinite else { cancelPointer(); return }
            gesture.currentOffset = session.startOffset + session.delta
            gesture.tracker.push(delta: delta, timestamp: now)
            group.strip.viewOffset = .gesture(gesture)
            world.groups[id] = group
            world.pointer = .gesture(session)
            layoutGroups.insert(id)
        case .endGesture:
            guard case .gesture(let session) = world.pointer, session.scope == event.scope,
                  var group = world.groups[id] else { cancelPointer(); return }
            let current = group.strip.viewOffset.current(at: now)
            guard case .gesture(let gesture) = group.strip.viewOffset else { cancelPointer(); return }
            let velocity = gesture.tracker.velocity(at: now)
            let projected = velocity == 0 ? current : session.startOffset + gesture.tracker.projectedEndPosition(isTouchpad: true)
            let target = world.config.gestureSnap
                ? session.snapTargets.min(by: { abs($0 - projected) < abs($1 - projected) }) ?? current : projected
            group.strip.viewOffset = world.config.animate
                ? .animation(SpringAnimation(from: current, to: target, initialVelocity: velocity, startTime: now, params: group.strip.scrollSpringParams)) : .static(target)
            world.groups[id] = group
            world.pointer = .idle
            layoutGroups.insert(id)
        case .menu(let action):
            guard case .menu(let session) = world.pointer, session.scope == event.scope else { cancelPointer(); return }
            cancelPointer()
            let targeted: Command
            switch action {
            case .setWidth(_, let width): targeted = .setWidth(session.tile, width)
            case .toggleFloating: targeted = .toggleFloating(session.tile)
            case .toggleFullWidth: targeted = .toggleFullWidth(session.tile)
            case .close: targeted = .close(session.tile)
            case .focus: targeted = .focus(session.tile)
            default: return
            }
            command(targeted, source: .pointer, group: id)
        case .dropReorder(let requested):
            guard case .reorder(let session) = world.pointer, session.scope == event.scope,
                  var group = world.groups[id], let index = group.strip.columns.firstIndex(where: { $0.tiles.contains(session.tile) }) else { cancelPointer(); return }
            let destination = max(0, min(group.strip.columns.count - 1, requested))
            group.strip.moveColumn(from: index, to: destination, at: now)
            if world.config.animate { _ = group.strip.recenterActiveColumnAnimated(at: now) }
            else { group.strip.recenterActiveColumn(at: now) }
            world.groups[id] = group
            cancelPointer()
            layoutGroups.insert(id)
            persist()
        case .cancel: cancelPointer()
        }
    }

    switch event.kind {
    case .topologyChanged(let topology):
        guard topology.revision > world.topology.revision, topology.isValid else { return [] }
        cancelPointer()
        for id in world.groups.keys.sorted() { cancelTimers(id) }
        for tile in world.frames.keys.sorted(by: { $0.rawValue < $1.rawValue }) { invalidate(tile) }
        let previous = world.groups
        let previousTopology = world.topology
        world.topology = topology
        world.groups = [:]
        for display in topology.groups {
            var group = previous[display.id] ?? GroupState(display: display, config: world.config)
            group.strip.groupArea = GroupState(display: display, config: world.config).strip.groupArea
            group.strip.recalculateWidths(at: now)
            group.changingSpace = false
            group.focus = .none
            world.groups[display.id] = group
            layoutGroups.insert(display.id)
        }
        for id in previous.keys.sorted() where world.groups[id] == nil {
            guard let old = previous[id], let oldDisplay = previousTopology.groups.first(where: { $0.id == id }),
                  let destination = topology.groups.min(by: { distance($0.frame, oldDisplay.frame) < distance($1.frame, oldDisplay.frame) }) else { continue }
            var group = world.groups[destination.id]!
            if group.space == nil { group.space = old.space; group.epoch = old.epoch }
            if group.space == old.space {
                for window in old.windows.values.sorted(by: { $0.id.rawValue < $1.id.rawValue }) where group.windows[window.id] == nil {
                    group.windows[window.id] = window
                    if old.floating.contains(window.id) { group.floating.insert(window.id) }
                }
                for column in old.strip.columns { group.strip.insertColumn(column, at: now, atIndex: group.strip.columns.count) }
                world.groups[destination.id] = group
            } else if let saved = snapshot(old, id: destination.id, time: now) {
                world.spaces.live[GroupSpace(group: destination.id, space: saved.space)] = saved
            }
        }
        persist()
    case .loadSnapshots(let snapshots):
        world.spaces.disk = snapshots.filter(\.isValid)
    default:
        guard world.scope(for: event.scope.group) == event.scope else { return [] }
        let id = event.scope.group
        switch event.kind {
        case .windowAdded(let window):
            let known = world.groups.values.contains { $0.windows[window.id] != nil }
            add(window, to: id)
            if !known { focus(FocusIntent(tile: window.id, source: .adoption), group: id) }
            persist()
        case .windowRemoved(let tile): remove(tile, from: id); persist()
        case .focus(let intent):
            let group = world.groups[id]!
            guard !group.changingSpace || intent.source == .appActivation else { break }
            cancelFocusTimers(id)
            if intent.source == .axNotification || (intent.source == .appActivation && group.windows.values.contains(where: { $0.appID == intent.appID })) {
                if let previous = group.focus.decision, previous.source.protectsFocus, now - previous.time < 0.15 { break }
                if let tile = intent.tile, group.windows[tile] != nil { schedule(.focus(intent), scope: event.scope, delay: 0.15) }
            } else { focus(intent, group: id) }
        case .command(let action, let source): command(action, source: source, group: id)
        case .ipc(let requestID, let action):
            command(action, source: .ipc, group: id)
            effects.append(.reply(id: requestID, payload: .accepted))
        case .query(let requestID):
            let snapshots = world.groups.keys.sorted().compactMap { groupID in
                world.groups[groupID].flatMap { snapshot($0, id: groupID, time: now) }
            }
            effects.append(.reply(id: requestID, payload: .snapshots(snapshots)))
        case .pointer(let input): pointer(input, group: id)
        case .spaceWillChange:
            if world.pointer.session?.scope.group == id { cancelPointer() }
            cancelTimers(id)
            for tile in world.groups[id]!.windows.keys.sorted(by: { $0.rawValue < $1.rawValue }) { invalidate(tile) }
            world.groups[id]?.changingSpace = true
        case .spaceChanged(let key, let epoch, let windows):
            guard !key.isEmpty, var group = world.groups[id] else { break }
            if group.space == key {
                group.changingSpace = false
                if case .crossing(_, _, let previous) = group.focus { group.focus = previous.map(FocusState.resolved) ?? .none }
                world.groups[id] = group
                layoutGroups.insert(id)
                break
            }
            let otherTiles = Set(world.groups.filter { $0.key != id }.values.flatMap { $0.windows.keys })
            guard epoch > group.epoch, Set(windows.map(\.id)).count == windows.count,
                  windows.allSatisfy({ $0.id.rawValue != 0 && !otherTiles.contains($0.id) }),
                  !(windows.isEmpty && !group.windows.isEmpty) else {
                effects.append(.log("space census deferred")); break
            }
            let ids = Set(windows.map { $0.id.rawValue })
            var fingerprints = world.spaces.live.values.filter { $0.group == id }.map(\.fingerprint)
            fingerprints.append(Set(group.windows.keys.map(\.rawValue)))
            guard !spansMultipleSpaces(onScreenIDs: ids, knownFingerprints: fingerprints) else {
                effects.append(.log("mixed space census deferred")); break
            }
            let crossing = group.focus
            if let saved = snapshot(group, id: id, time: now) { world.spaces.live[GroupSpace(group: id, space: saved.space)] = saved }
            if world.pointer.session?.scope.group == id { cancelPointer() }
            cancelTimers(id)
            for tile in group.windows.keys.sorted(by: { $0.rawValue < $1.rawValue }) { invalidate(tile) }
            let saved = world.spaces.lookup(group: id, space: key, windows: windows)
            let display = world.topology.groups.first { $0.id == id }!
            group = restoredGroup(display: display, config: world.config, key: key, epoch: epoch,
                                  windows: windows, saved: saved, time: now)
            world.groups[id] = group
            var restore = group.focus.decision?.tile ?? group.strip.activeColumn?.activeTile
            var source: FocusSource = .spaceRestore
            if case .crossing(let intent, let time, _) = crossing, now - time <= 0.5,
               let appID = intent.appID {
                let appWindows = windows.filter { $0.appID == appID }
                if let tile = intent.tile, appWindows.contains(where: { $0.id == tile }) { restore = tile; source = .appActivation }
                else if let tile = appWindows.sorted(by: { $0.id.rawValue < $1.id.rawValue }).first?.id { restore = tile; source = .appActivation }
            }
            focus(FocusIntent(tile: restore, source: source), group: id)
            layoutGroups.insert(id)
            persist()
        case .frameCompleted(let tile, let revision, let result):
            guard let request = world.frames[tile], request.revision == revision, request.scope == event.scope else { break }
            switch result {
            case .applied: world.appliedFrames[tile] = request
            case .failed, .timedOut:
                world.frames.removeValue(forKey: tile)
                world.appliedFrames.removeValue(forKey: tile)
                if !world.timers.values.contains(where: { if case .retryFrames = $0.action { return $0.scope == event.scope }; return false }) {
                    schedule(.retryFrames, scope: event.scope, delay: 0.1)
                }
            }
        case .timer(let token):
            guard let work = world.timers[token], work.scope == event.scope, now >= work.deadline else { break }
            world.timers.removeValue(forKey: token)
            switch work.action {
            case .retryFrames: layoutGroups.insert(id)
            case .focus(let intent): focus(intent, group: id)
            }
        case .tick:
            if var group = world.groups[id], !group.changingSpace {
                _ = group.strip.settleWidthAnimations(at: now)
                _ = group.strip.settleRaiseAnimations(at: now)
                if case .animation(let animation) = group.strip.viewOffset, animation.isDone(at: now) {
                    group.strip.viewOffset = .static(animation.to)
                }
                world.groups[id] = group
                layoutGroups.insert(id)
            }
        case .topologyChanged, .loadSnapshots: break
        }
    }
    for id in layoutGroups.sorted() {
        guard let group = world.groups[id], !group.changingSpace, let scope = world.scope(for: id),
              let display = world.topology.groups.first(where: { $0.id == id }) else { continue }
        for target in computeTargetFrames(strip: group.strip, time: now) {
            let frame = axRect(ViewportRect(target.frame), on: display)
            guard frame.rect.isFinite else { effects.append(.log("nonfinite layout rejected")); continue }
            if let existing = world.frames[target.tileID], existing.frame == frame, existing.scope == scope { continue }
            let request = FrameRequest(tile: target.tileID, frame: frame, revision: nextRevision(), scope: scope)
            world.frames[target.tileID] = request
            effects.append(.setFrame(request))
        }
    }
    if shouldPersist {
        for id in world.groups.keys.sorted() {
            if let group = world.groups[id], let saved = snapshot(group, id: id, time: now) {
                world.spaces.live[GroupSpace(group: id, space: saved.space)] = saved
            }
        }
        let snapshots = world.spaces.live.values.sorted {
            if $0.group != $1.group { return $0.group < $1.group }
            return $0.space.debugDescription < $1.space.debugDescription
        }
        effects.append(.persist(snapshots))
    }
    return effects
}

private func shouldFloat(_ window: ObservedWindow, config: EngineConfig) -> Bool {
    config.rules.last(where: { window.bundleID == $0.bundleID })?.floating ?? window.floating
}

private func distance(_ lhs: CGRect, _ rhs: CGRect) -> Double {
    hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
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

private func restoredGroup(display: DisplayGroup, config: EngineConfig, key: SpaceKey, epoch: UInt64,
                           windows: [ObservedWindow], saved: Snapshot?, time: Double) -> GroupState {
    var group = GroupState(display: display, config: config)
    group.space = key
    group.epoch = epoch
    group.windows = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
    var unused = Set(windows.map(\.id))
    var mappedIDs: [TileID: TileID] = [:]
    func match(_ window: ObservedWindow) -> ObservedWindow? {
        let candidate = windows.first { $0.id == window.id && unused.contains($0.id) }
            ?? windows.sorted(by: { $0.id.rawValue < $1.id.rawValue }).first { WindowIdentity($0) == WindowIdentity(window) && unused.contains($0.id) }
        if let candidate { unused.remove(candidate.id); mappedIDs[window.id] = candidate.id }
        return candidate
    }
    if let saved {
        for column in saved.columns {
            let matched = column.windows.compactMap { match($0) }
            let tiled = matched.filter { !shouldFloat($0, config: config) }
            for window in matched where shouldFloat(window, config: config) { group.floating.insert(window.id) }
            guard !tiled.isEmpty else { continue }
            var restored = Column(tiles: [tiled[0].id], width: column.width.width)
            restored.tiles = tiled.map(\.id)
            let active = mappedIDs[column.windows[column.activeTileIndex].id]
            restored.activeTileIndex = tiled.firstIndex(where: { $0.id == active }) ?? min(column.activeTileIndex, tiled.count - 1)
            restored.presetIndex = column.presetIndex
            restored.isFullWidth = column.isFullWidth
            group.strip.insertColumn(restored, at: time, atIndex: group.strip.columns.count)
            group.strip.snapIndices[group.strip.columns.count - 1] = min(column.snapIndex, max(0, group.strip.snapPoints.count - 1))
        }
        for window in saved.floating { if let match = match(window) { group.floating.insert(match.id) } }
    }
    for window in windows where unused.contains(window.id) {
        if shouldFloat(window, config: config) { group.floating.insert(window.id) }
        else { group.strip.insertColumn(Column(tiles: [window.id], width: .proportion(config.defaultWidth)), at: time, atIndex: group.strip.columns.count) }
    }
    group.strip.activeColumnIndex = min(saved?.activeColumnIndex ?? 0, max(0, group.strip.columns.count - 1))
    group.strip.viewOffset = .static(saved?.offset ?? 0)
    if let oldFocus = saved?.focusedTile, let focused = mappedIDs[oldFocus] {
        group.focus = .resolved(FocusDecision(tile: focused, source: .spaceRestore, time: time))
    }
    group.strip.recalculateWidths(at: time)
    return group
}
