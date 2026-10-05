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
    guard event.scope.topologyRevision == world.topology.revision,
          event.kind.isGlobal || world.scope(for: event.scope.group) == event.scope else {
        switch event.kind {
        case .ipc(let requestID, _): return [.reply(id: requestID, payload: .command(.refused("stale scope")))]
        case .query(let requestID): return [.reply(id: requestID, payload: .snapshots([]))]
        default:
            guard event.scope.topologyRevision != world.topology.revision else { return [] }
            return [.log("stale topology revision dropped rev=\(event.scope.topologyRevision) current=\(world.topology.revision)")]
        }
    }
    world.time = now
    world.expireMomentum(now)
    let overlay = world.pointer?.overlay ?? .hidden
    var pass = Pass(now: now, scope: event.scope)
    let id = event.scope.group
    switch event.kind {
    case .topologyChanged(let topology): world.onTopology(topology, &pass)
    case .configChanged(let config): world.onConfig(config, &pass)
    case .loadSnapshots(let snapshots): world.spaces.disk = snapshots.filter(\.isValid)
    case .windowAdded(let window): world.onWindowAdded(window, group: id, &pass)
    case .windowChanged(let window): world.onWindowChanged(window, &pass)
    case .windowRemoved(let tile):
        world.remove(tile, from: id, &pass)
        pass.persist = true
    case .windowsHidden(let tiles):
        world.hide(tiles, &pass)
        pass.persist = true
    case .windowMoved(let tile, let frame): world.onWindowMoved(tile, frame: frame, group: id, &pass)
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
    case .spaceWillChange: world.onSpaceWillChange(group: id, &pass)
    case .spaceChanged(let key, let epoch, let windows): world.onSpaceChanged(key: key, epoch: epoch, windows: windows, group: id, &pass)
    case .frameCompleted(let tile, let revision, let result): world.onFrameCompleted(tile, revision: revision, result: result, &pass)
    case .timer(let token): world.onTimer(token, group: id, &pass)
    case .tick: world.onTick(&pass)
    }
    world.flush(&pass)
    let shown = world.pointer?.overlay ?? .hidden
    if shown != overlay { pass.effects.append(.overlay(shown)) }
    return pass.effects
}

extension World {
    mutating func expireMomentum(_ now: Double) {
        if let tail = gestureTail, now - tail >= EngineConfig.gestureQuiet { gestureTail = nil }
        guard case .momentum(let settled?) = pointer?.phase, now - settled >= EngineConfig.gestureQuiet, gestureTail == nil else { return }
        pointer = nil
    }

    fileprivate mutating func nextRevision() -> UInt64 {
        serial += 1
        return serial
    }

    mutating func cancelTimers(group: UInt32, _ pass: inout Pass, focusOnly: Bool = false) {
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
        let scope = scope(for: pass.scope.group) ?? pass.scope
        timers[token] = ScheduledWork(scope: scope, deadline: deadline, action: action)
        pass.effects.append(.schedule(token: token, deadline: deadline, event: Event(scope: scope, kind: .timer(token))))
    }

    mutating func invalidate(_ tile: TileID, _ pass: inout Pass) {
        frames.removeValue(forKey: tile)
        appliedFrames.removeValue(forKey: tile)
        pass.effects.append(.invalidateFrame(tile: tile, revision: nextRevision()))
    }

    /// Ending a session cancels its timer and leaves a swipe's view where it is; the overlay follows the session. The
    /// rest of an ended swipe's gesture stays Reel's.
    mutating func cancelPointer(_ pass: inout Pass) {
        guard let session = pointer else { return }
        pointer = nil
        if session.swipe != nil { gestureTail = pass.now }
        if let timer = session.timer { pass.effects.append(.cancel(timer.token)) }
        let id = session.scope.group
        if var group = groups[id], case .gesture = group.strip.viewOffset {
            group.strip.viewOffset = .static(group.strip.viewOffset.current(at: pass.now))
            groups[id] = group
            pass.layout.insert(id)
        }
    }

    /// A change to the strip a session began on ends it: its snap targets and its overlay describe the old strip.
    mutating func cancelPointer(in id: UInt32, _ pass: inout Pass) {
        if pointer?.scope.group == id { cancelPointer(&pass) }
    }

    fileprivate mutating func onFocusObserved(_ intent: FocusIntent, group id: UInt32, _ pass: inout Pass) {
        let group = groups[id]!
        guard group.phase.acceptsFocus || intent.source == .appActivation else { return }
        cancelTimers(group: id, &pass, focusOnly: true)
        let local = intent.source == .appActivation && group.windows.values.contains { $0.pid == intent.pid }
        guard intent.source == .axFocus || local else { return focus(intent, group: id, &pass) }
        // A report this soon after a focus Reel made, here or on the display commands act on, is stale.
        let recent = [group.focus.decision, activeGroup.flatMap { groups[$0]?.focus.decision }].compactMap { $0 }
        if recent.contains(where: { $0.source.protectsFocus && pass.now - $0.time < EngineConfig.focusDebounce }) { return }
        guard let tile = intent.tile else { return }
        if group.windows[tile] != nil { schedule(.focus(intent), delay: EngineConfig.focusDebounce, &pass) }
        else if group.hidden[tile] != nil { groups[id]!.focus = .crossing(intent: intent, time: pass.now, previous: group.focus.decision) }
    }

    /// With `quietSince`, the decision is recorded at that time and the OS is not asked to focus.
    fileprivate mutating func focus(_ intent: FocusIntent, group id: UInt32, _ pass: inout Pass, quietSince: Double? = nil, animated: Bool? = nil) {
        guard var group = groups[id] else { return }
        if let observed = intent.observedSpace, observed.isAuthoritative,
           let current = group.space, current.isAuthoritative, observed != current { return }
        if intent.source == .appActivation, let pid = intent.pid, !group.windows.values.contains(where: { $0.pid == pid }) {
            // The app may be on another Space of any display, so whichever display changes Space next takes the click.
            for other in groups.keys where !groups[other]!.windows.values.contains(where: { $0.pid == pid }) {
                groups[other]!.focus = .crossing(intent: intent, time: pass.now, previous: groups[other]!.focus.decision)
            }
            return
        }
        guard group.phase.acceptsFocus, let tile = intent.tile, group.windows[tile] != nil else { return }
        if pointer.isSwiping(group: id), intent.source.centers {
            cancelPointer(&pass)
            group = groups[id]!
        }
        if !pointer.isSwiping(group: id), let index = group.strip.columnIndex(of: tile) {
            if intent.source.centers {
                let previousX = group.strip.columnX(at: group.strip.activeColumnIndex, time: pass.now)
                group.strip.viewOffset.shiftBy(previousX - group.strip.columnX(at: index, time: pass.now))
                group.strip.activeColumnIndex = index
                group.strip.snapIndices[index] = group.strip.defaultSnapIndex
                group.strip.recenter(animated: animated ?? config.animate, at: pass.now)
            } else {
                group.strip.focusColumnIncremental(colIndex: index, at: pass.now, animated: animated ?? config.animate)
            }
            group.strip.columns[index].activeTileIndex = group.strip.columns[index].tiles.firstIndex(of: tile)!
        }
        group.focus = .resolved(FocusDecision(tile: tile, source: intent.source, time: quietSince ?? pass.now))
        group.focusedAt = max(group.focusedAt, quietSince ?? pass.now)
        groups[id] = group
        if intent.source != .axFocus, quietSince == nil {
            pass.effects.append(.focus(tile: tile, source: intent.source))
            pass.effects.append(.raise(tile))
        }
        pass.effects.append(.log("focus source=\(intent.source.rawValue) tile=\(tile.rawValue)"))
        pass.layout.insert(id)
        pass.persist = true
    }

    /// A new window is on this group's current Space, so it moves here from any stash that still lists it.
    fileprivate mutating func onWindowAdded(_ window: ObservedWindow, group id: UInt32, _ pass: inout Pass) {
        guard window.isValid else { return pass.effects.append(.log("invalid window ignored tile=\(window.id.rawValue)")) }
        if groups[id]?.windows[window.id] != nil { return refreshIfSameOwner(window, &pass) }
        let returning = groups[id]?.returning(window) != nil
        add(window, to: id, &pass)
        guard let group = groups[id], group.windows[window.id] != nil else { return }
        prune([window.id.rawValue], from: otherSpaces(than: id))
        // A window back from a hide is not new: its app's focus report or activation decides focus, even one that came first.
        if !returning { focus(FocusIntent(tile: window.id, source: .adoption), group: id, &pass) }
        else if case .crossing(let intent, _, _) = group.focus, intent.tile == window.id { focus(intent, group: id, &pass) }
        pass.persist = true
    }

    /// Metadata only: whichever group or stash holds the window takes the new title and frame.
    fileprivate mutating func onWindowChanged(_ window: ObservedWindow, _ pass: inout Pass) {
        guard window.isValid else { return pass.effects.append(.log("invalid window ignored tile=\(window.id.rawValue)")) }
        refreshIfSameOwner(window, &pass)
    }

    /// A tiled window keeps its column's place: a new width becomes the column's logical width, and the frame is
    /// rewritten. A floating window belongs to the user, so its frame is left alone.
    fileprivate mutating func onWindowMoved(_ tile: TileID, frame: AXRect, group id: UInt32, _ pass: inout Pass) {
        guard frame.rect.isFinite, var group = groups[id], !group.phase.isChanging,
              let index = group.strip.columnIndex(of: tile) else { return }
        let width = min(frame.rect.width, group.strip.workingArea.width)
        if abs(width - group.strip.columnData[index].cachedWidth) > EngineConfig.userResizeSlop {
            group.strip.setWidth(.fixed(width), column: index, at: pass.now, params: nil)
            groups[id] = group
            pass.persist = true
            pass.effects.append(.log("user resize tile=\(tile.rawValue) width=\(Int(width))"))
        }
        frames.removeValue(forKey: tile)
        appliedFrames.removeValue(forKey: tile)
        pass.layout.insert(id)
    }

    /// An id can be reused by another app's window, so only a holder with the same owner takes the update. A window
    /// that floated only because it registered untitled joins the strip, focused as a new window is, once its app says
    /// it tiles; one the user floated never had floating facts, so it stays. A refused join keeps the old facts, so
    /// the next report of the new ones tries again.
    private mutating func refreshIfSameOwner(_ window: ObservedWindow, _ pass: inout Pass) {
        var mismatched = false
        for id in groups.keys.sorted() {
            guard let known = groups[id]!.windows[window.id] else { continue }
            guard known.hasSameOwner(as: window) else { mismatched = true; continue }
            let window = window.adoptingTitle(known.ruleTitle ?? known.title)
            guard known != window else { continue }
            if joinsStrip(was: known, now: window, config: config), groups[id]!.floating.contains(window.id) {
                guard run(.toggleFloating(window.id), source: .adoption, group: id, &pass) == .accepted else { continue }
                focus(FocusIntent(tile: window.id, source: .adoption), group: id, &pass)
            }
            groups[id]!.windows[window.id] = window
            pass.persist = true
        }
        for (key, saved) in spaces.live {
            guard let known = saved.windows.first(where: { $0.id == window.id }) else { continue }
            guard known.hasSameOwner(as: window) else { mismatched = true; continue }
            let window = window.adoptingTitle(known.ruleTitle ?? known.title)
            let floated = saved.floating.contains { $0.id == window.id }
            guard known != window, !(floated && joinsStrip(was: known, now: window, config: config)) else { continue }
            spaces.live[key] = refreshing(window, in: saved)
            pass.persist = true
        }
        if mismatched { pass.effects.append(.log("window identity changed tile=\(window.id.rawValue)")) }
    }

    fileprivate mutating func add(_ window: ObservedWindow, to id: UInt32, _ pass: inout Pass) {
        guard var group = groups[id], case .settled = group.phase else {
            return pass.effects.append(.log("window add dropped during space change tile=\(window.id.rawValue)"))
        }
        if group.windows[window.id] != nil { return refreshIfSameOwner(window, &pass) }
        guard !groups.values.contains(where: { $0.windows[window.id] != nil }) else { return }
        let returning = group.returning(window)
        let window = window.adoptingTitle(returning?.window.ruleTitle ?? window.ruleTitle ?? window.title)
        if returning == nil { cancelTimers(group: id, &pass, focusOnly: true) }
        cancelPointer(in: id, &pass)
        group = groups[id]!
        if group.space?.isEmpty == true { group.phase = .settled(.fingerprint([window.id.rawValue])) }
        group.windows[window.id] = window
        group.hidden.removeValue(forKey: window.id)
        for other in groups.keys where other != id { groups[other]!.hidden[window.id] = nil }
        if let returning { group.putBack(window, from: returning, config: config, at: pass.now) }
        else if shouldFloat(window, config: config) { group.floating.insert(window.id) }
        else { group.strip.insertTile(window.id, at: pass.now) }
        groups[id] = group
        pass.layout.insert(id)
    }

    private mutating func prune(_ ids: Set<UInt32>, from stashes: [GroupSpace: Snapshot], hiddenOnly: Bool = false) {
        for (key, saved) in stashes {
            let gone = hiddenOnly ? ids.subtracting(saved.fingerprint) : ids
            guard !saved.fingerprint.isDisjoint(with: gone) || saved.hidden.contains(where: { gone.contains($0.window.id.rawValue) }) else { continue }
            let pruned = removing(gone, from: saved)
            spaces.live[key] = pruned.isEmpty ? nil : pruned
        }
    }

    /// Disk entries keep closed ids: after a reboot an id can name another window, and restore skips absent ones anyway.
    fileprivate mutating func remove(_ tile: TileID, from id: UInt32, _ pass: inout Pass) {
        prune([tile.rawValue], from: spaces.live)
        for group in groups.keys { groups[group]!.hidden[tile] = nil }
        guard groups[id]?.windows[tile] != nil else { return }
        cancelTimers(group: id, &pass, focusOnly: true)
        cancelPointer(in: id, &pass)
        var group = groups[id]!
        group.strip.removeTile(tile, at: pass.now)
        group.windows.removeValue(forKey: tile)
        group.floating.remove(tile)
        if group.focus.decision?.tile == tile { group.focus = .none }
        groups[id] = group
        invalidate(tile, &pass)
        pass.layout.insert(id)
    }

    fileprivate mutating func run(_ command: Command, source: FocusSource, group id: UInt32, _ pass: inout Pass) -> CommandOutcome {
        switch command {
        case .release:
            // Quitting must never strand a window off screen, even mid Space change.
            gestureTail = nil
            release(group: id, &pass)
            return .accepted
        case .recover:
            return recover(group: id, &pass)
        case .clearPositions:
            return clearPositions(&pass)
        case .clearPositionsApp(let bundleID):
            return clearPositions(&pass, bundleID: bundleID)
        case .focusUp, .focusDown:
            if case .focusUp = command { return focusVertically(up: true, source: source, from: id, &pass) }
            return focusVertically(up: false, source: source, from: id, &pass)
        default:
            break
        }
        let outcome = execute(command, source: source, group: id, &pass)
        if outcome == .accepted { cancelTimers(group: id, &pass, focusOnly: true) }
        return outcome
    }

    private mutating func execute(_ command: Command, source: FocusSource, group id: UInt32, _ pass: inout Pass) -> CommandOutcome {
        guard groups[id]?.phase.isChanging == false else { return .refused("space change in progress") }
        switch command {
        case .moveLeft, .moveRight, .toggleFloating: cancelPointer(in: id, &pass)
        default: break
        }
        var group = groups[id]!
        func missing(_ tile: TileID) -> CommandOutcome {
            group.windows[tile] == nil ? .unknownWindow(tile) : .refused("floating window")
        }
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
            // At the strip's edge the view stretches past it and springs back, from wherever the focus left it. The focus
            // already ended any swipe, so the bounce cannot strand one without its view.
            if index == group.strip.activeColumnIndex, config.animate, var focused = groups[id] {
                focused.strip.createRubberBandAnimation(direction: Double(delta), at: now)
                groups[id] = focused
            }
            return .accepted
        case .moveLeft, .moveRight:
            guard !group.strip.columns.isEmpty else { return .refused("empty strip") }
            if case .moveLeft = command { group.strip.moveColumnLeft(at: now) } else { group.strip.moveColumnRight(at: now) }
        case .setWidth(let tile, let width):
            guard width.isFinite, width > 0 else { return .refused("invalid width") }
            guard let index = group.strip.columnIndex(of: tile) else { return missing(tile) }
            group.strip.setWidth(.fixed(width), column: index, at: now, params: config.animate ? group.strip.scrollSpringParams : nil)
            recenter = index == group.strip.activeColumnIndex
        case .setWidthPreset(let tile, let preset):
            guard group.strip.widthPresets.indices.contains(preset) else { return .refused("no such preset") }
            guard let index = group.strip.columnIndex(of: tile) else { return missing(tile) }
            group.strip.setWidthPreset(index: preset, at: now, params: config.animate ? group.strip.scrollSpringParams : nil, column: index)
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
        case .recover, .release, .clearPositions, .clearPositionsApp, .focusUp, .focusDown:
            preconditionFailure("run handles recover, release, clearPositions and vertical focus")
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

    private mutating func focusVertically(up: Bool, source: FocusSource, from id: UInt32, _ pass: inout Pass) -> CommandOutcome {
        let here = topology.group(id: id)!.frame.midY
        let target = topology.groups.filter { up ? $0.frame.midY < here : $0.frame.midY > here }
            .min { abs($0.frame.midY - here) < abs($1.frame.midY - here) }
        guard let target else { return .refused(up ? "no strip above" : "no strip below") }
        guard let group = groups[target.id], let tile = group.focus.decision?.tile ?? group.strip.activeColumn?.activeTile else {
            return .refused("empty strip")
        }
        return run(.focus(tile), source: source, group: target.id, &pass)
    }

    fileprivate mutating func onPointer(_ input: PointerInput, token: PointerToken?, group id: UInt32, _ pass: inout Pass) {
        if case .scroll(let scroll) = input {
            switch scroll.phase {
            case .began:
                if pointer?.press == nil { cancelPointer(&pass) }
                gestureTail = nil
            case .discrete: break
            default:
                if gestureTail != nil {
                    gestureTail = scroll.phase == .momentumEnded ? nil : pass.now
                    return pass.effects.append(.consumeInput)
                }
                if scroll.phase == .momentum || scroll.phase == .momentumEnded { return }
            }
            // Scroll input ends only swipes: a title-bar press, drag or menu outlives a scroll on any display.
            if pointer?.press != nil { return }
        }
        switch input {
        case .scroll(let scroll) where scroll.phase == .discrete: return wheel(scroll, group: id, &pass)
        case .scroll(let scroll) where scroll.phase == .began:
            if scroll.modifier { begin(.gestureTracking(nil), group: id, &pass) }
            return
        case .press(let tile, let origin):
            cancelPointer(&pass)
            guard let tile else { return }
            return begin(.titleArmed(TitlePress(tile: tile, origin: origin)), group: id, &pass)
        default: break
        }
        // An input from an ended session is dropped; it must not end the one that replaced it.
        guard var session = pointer, session.token == token, session.scope == pass.scope else { return }
        switch (session.phase, input) {
        case (.gestureTracking(nil), .scroll(let scroll)) where scroll.phase == .changed && scroll.modifier:
            guard scroll.dx != 0 || scroll.dy != 0 else { return }
            guard scroll.isHorizontal, var group = groups[id], !group.strip.columns.isEmpty else { return cancelPointer(&pass) }
            session.startOffset = group.strip.viewOffset.current(at: pass.now)
            session.phase = .gestureTracking(Swipe())
            group.strip.viewOffset = .gesture(GestureState(currentOffset: session.startOffset, isTouchpad: true))
            groups[id] = group
            pointer = session
            track(scroll.dx, group: id, &pass)
        case (.gestureTracking(.some), .scroll(let scroll)) where scroll.phase == .changed && scroll.modifier:
            track(scroll.dx, group: id, &pass)
        case (.gestureTracking(.some(let swipe)), .scroll(let scroll)) where [.changed, .ended, .cancelled].contains(scroll.phase):
            guard var group = groups[id], case .gesture(let gesture) = group.strip.viewOffset else { return cancelPointer(&pass) }
            release(gesture, swipe: swipe, from: session.startOffset, strip: &group.strip, at: pass.now)
            groups[id] = group
            session.phase = .momentum(settledAt: group.strip.viewOffset.isAnimating ? nil : pass.now)
            pointer = session
            gestureTail = pass.now
            pass.effects.append(.consumeInput)
            pass.layout.insert(id)
            pass.persist = true
        case (.titleArmed(let press), .drag(let point)):
            pass.effects.append(.consumeInput)
            guard hypot(point.point.x - press.origin.point.x, point.point.y - press.origin.point.y) > EngineConfig.dragThreshold,
                  let display = topology.displays.min(by: { $0.distance(to: point.point) < $1.distance(to: point.point) }) else { return }
            setTimer(&session, nil, &pass)
            session.phase = .titleDragging(press, display: display.id, released: false)
            pointer = session
        case (.titleArmed(let press), .release):
            cancelPointer(&pass)
            pass.effects.append(.consumeInput)
            pass.effects.append(.replayPress(press.origin))
        case (.titleDragging(_, _, false), .drag), (.reorderDragging(_, _, false), .drag), (.menuOpen, .drag):
            pass.effects.append(.consumeInput)
        case (.titleDragging(let press, let display, let released), .overlayReady):
            session.phase = .reorderDragging(press, display: display, released: released)
            pointer = session
        case (.titleDragging(let press, let display, false), .release):
            setTimer(&session, EngineConfig.dropDeadline, &pass)
            session.phase = .titleDragging(press, display: display, released: true)
            pointer = session
            pass.effects.append(.consumeInput)
        case (.reorderDragging(let press, let display, false), .release):
            setTimer(&session, EngineConfig.dropDeadline, &pass)
            session.phase = .reorderDragging(press, display: display, released: true)
            pointer = session
            pass.effects.append(.consumeInput)
        case (.reorderDragging(let press, _, true), .drop(let gap)):
            cancelPointer(&pass)
            drop(press.tile, gap: gap, group: id, &pass)
        case (.menuOpen(let press), .choose(let action)):
            cancelPointer(&pass)
            pass.effects.append(.consumeInput)
            choose(action, tile: press.tile, group: id, &pass)
        case (.menuOpen, .release):
            cancelPointer(&pass)
            pass.effects.append(.consumeInput)
        case (_, .cancel):
            cancelPointer(&pass)
            gestureTail = nil
            pass.effects.append(.consumeInput)
        default:
            cancelPointer(&pass)
        }
    }

    /// A session starts only on a strip that is settled and holds its tile; a gesture waits for its first moving sample.
    private mutating func begin(_ phase: PointerSession.Phase, group id: UInt32, _ pass: inout Pass) {
        guard let group = groups[id], !group.phase.isChanging, !group.strip.columns.isEmpty, let scope = scope(for: id) else { return }
        if case .titleArmed(let press) = phase, group.strip.columnIndex(of: press.tile) == nil { return }
        var session = PointerSession(token: PointerToken(nextRevision()), scope: scope,
                                     startOffset: group.strip.viewOffset.current(at: pass.now), phase: phase)
        if case .titleArmed = phase {
            setTimer(&session, EngineConfig.longPress, &pass)
            pass.effects.append(.consumeInput)
        }
        pointer = session
    }

    private mutating func setTimer(_ session: inout PointerSession, _ delay: Double?, _ pass: inout Pass) {
        if let timer = session.timer { pass.effects.append(.cancel(timer.token)) }
        session.timer = delay.map { (TimerToken(nextRevision()), pass.now + $0) }
        if let timer = session.timer {
            pass.effects.append(.schedule(token: timer.token, deadline: timer.deadline, event: Event(scope: session.scope, kind: .timer(timer.token))))
        }
    }

    /// A long press opens the menu; a released drag whose drop never came ends with the order unchanged.
    private mutating func onSessionTimer(_ session: PointerSession, _ pass: inout Pass) {
        guard session.scope == pass.scope, let timer = session.timer, pass.now >= timer.deadline else { return }
        guard case .titleArmed(let press) = session.phase else {
            pass.effects.append(.log("pointer: drop never came, reorder cancelled"))
            return cancelPointer(&pass)
        }
        pointer = PointerSession(token: session.token, scope: session.scope, startOffset: session.startOffset, phase: .menuOpen(press))
    }

    /// Each column's snap point with every width at its target: `target` in the active column's basis, `rest` in the
    /// column's own.
    private func snapPoints(_ strip: Strip, at now: Double) -> [(target: Double, rest: Double)] {
        var settled = strip
        for i in settled.columnData.indices { settled.columnData[i].widthAnimation = nil }
        let activeX = settled.columnX(at: settled.activeColumnIndex, time: now)
        return settled.columns.indices.map {
            let rest = settled.snapTarget(forColumn: $0, at: now)
            return (settled.columnX(at: $0, time: now) - activeX + rest, rest)
        }
    }

    private mutating func track(_ delta: Double, group id: UInt32, _ pass: inout Pass) {
        guard delta.isFinite, var session = pointer, case .gestureTracking(var swipe?) = session.phase, var group = groups[id],
              case .gesture(var gesture) = group.strip.viewOffset else { return cancelPointer(&pass) }
        let bounds = group.strip.viewOffsetBounds(at: pass.now)
        let wanted = gesture.currentOffset + delta
        let next = min(max(wanted, bounds.lowerBound), bounds.upperBound)
        swipe.edge = wanted > next ? 1 : wanted < next ? -1 : 0
        gesture.tracker.push(delta: next - gesture.currentOffset, timestamp: pass.now)
        gesture.currentOffset = next
        group.strip.viewOffset = .gesture(gesture)
        groups[id] = group
        session.phase = .gestureTracking(swipe)
        pointer = session
        pass.effects.append(.consumeInput)
        pass.layout.insert(id)
    }

    /// The release projects from the start offset, the tracker's origin, and lands the column whose snap point is
    /// nearest there at that snap point once every width settles. A swipe that pushed or was flung past the
    /// strip's end lands on the end column with an underdamped spring kicked outward, so it overshoots and comes back.
    private func release(_ gesture: GestureState, swipe: Swipe, from start: Double, strip: inout Strip, at now: Double) {
        var from = gesture.currentOffset
        let velocity = gesture.tracker.velocity(at: now)
        let projected = abs(velocity) < EngineConfig.flickVelocity ? from : start + gesture.tracker.projectedEndPosition(isTouchpad: true)
        let bounds = strip.viewOffsetBounds(at: now)
        var target: Double
        let snaps = config.gestureSnap ? snapPoints(strip, at: now) : []
        if let column = snaps.indices.min(by: { abs(snaps[$0].target - projected) < abs(snaps[$1].target - projected) }) {
            from += strip.columnX(at: strip.activeColumnIndex, time: now) - strip.columnX(at: column, time: now)
            strip.activeColumnIndex = column
            target = snaps[column].rest
        } else {
            target = min(max(projected, bounds.lowerBound), bounds.upperBound)
        }
        let edge = swipe.edge != 0 ? swipe.edge : projected > bounds.upperBound ? 1 : projected < bounds.lowerBound ? -1 : 0
        if config.animate, edge != 0 {
            let kick = edge * max(abs(velocity), strip.rubberBandKick)
            strip.viewOffset = .animation(SpringAnimation(from: from, to: target, initialVelocity: kick, startTime: now,
                                                          params: strip.rubberBandParams))
        } else {
            strip.viewOffset = config.animate && abs(target - from) >= 1
                ? .animation(SpringAnimation(from: from, to: target, initialVelocity: velocity, startTime: now, params: strip.scrollSpringParams))
                : .static(target)
        }
    }

    /// A wheel notch with the modifier moves the view by its delta, onto the target of a scroll still in flight.
    private mutating func wheel(_ scroll: ScrollInput, group id: UInt32, _ pass: inout Pass) {
        guard scroll.modifier, scroll.isHorizontal, scroll.dx.isFinite else { return }
        cancelPointer(&pass)
        guard var group = groups[id], !group.phase.isChanging, !group.strip.columns.isEmpty else { return }
        let bounds = group.strip.viewOffsetBounds(at: pass.now)
        let current = group.strip.viewOffset.current(at: pass.now)
        let base = if case .animation(let animation) = group.strip.viewOffset { animation.to } else { current }
        let target = min(max(base + scroll.dx, bounds.lowerBound), bounds.upperBound)
        if !config.animate {
            group.strip.viewOffset = .static(target)
        } else if case .animation(let animation) = group.strip.viewOffset {
            group.strip.viewOffset = .animation(animation.retargeted(to: target, at: pass.now))
        } else {
            group.strip.viewOffset = .animation(SpringAnimation(from: current, to: target, initialVelocity: 0, startTime: pass.now,
                                                                params: group.strip.scrollSpringParams))
        }
        groups[id] = group
        pass.effects.append(.consumeInput)
        pass.layout.insert(id)
    }

    /// `gap` counts columns left of the drop; past either end clamps there. The dropped tile takes focus. A strip
    /// changing Space refuses the drop, as it refuses commands.
    private mutating func drop(_ tile: TileID, gap: Int, group id: UInt32, _ pass: inout Pass) {
        guard var group = groups[id], let source = group.strip.columnIndex(of: tile) else { return }
        guard !group.phase.isChanging else { return pass.effects.append(.log("pointer: drop refused, strip changing Space")) }
        let count = group.strip.columns.count
        let gap = min(max(gap, 0), count)
        let destination = min(gap > source ? gap - 1 : gap, count - 1)
        group.strip.moveColumn(from: source, to: destination, at: pass.now)
        groups[id] = group
        pass.effects.append(.log("pointer: drop tile=\(tile.rawValue) from=\(source) to=\(destination)"))
        focus(FocusIntent(tile: tile, source: .click), group: id, &pass)
        pass.layout.insert(id)
        pass.persist = true
    }

    /// A pill acts on the tile the menu opened for, whatever tile the command names.
    private mutating func choose(_ action: Command, tile: TileID, group id: UInt32, _ pass: inout Pass) {
        let targeted: Command
        switch action {
        case .setWidth(_, let width): targeted = .setWidth(tile, width)
        case .setWidthPreset(_, let preset): targeted = .setWidthPreset(tile, preset)
        case .toggleFloating: targeted = .toggleFloating(tile)
        case .toggleFullWidth: targeted = .toggleFullWidth(tile)
        case .close: targeted = .close(tile)
        case .focus: targeted = .focus(tile)
        case .focusLeft, .focusRight, .focusUp, .focusDown, .moveLeft, .moveRight, .cycleWidthPreset, .recover, .release,
             .clearPositions, .clearPositionsApp: return
        }
        let outcome = run(targeted, source: .click, group: id, &pass)
        pass.effects.append(.log("pointer: menu \(targeted) tile=\(tile.rawValue) outcome=\(outcome)"))
    }

    fileprivate mutating func beginSpaceChange(group id: UInt32, _ pass: inout Pass) {
        cancelPointer(in: id, &pass)
        cancelTimers(group: id, &pass)
        guard var group = groups[id] else { return }
        for tile in group.windows.keys.ordered() { invalidate(tile, &pass) }
        if group.phase.awaitsTeardown, let key = group.phase.key {
            // A pending re-read no longer holds: focus from here on is an echo.
            group.phase = .changing(from: key, deferred: group.phase.deferred.map { DeferredCensus(key: $0.key, since: $0.since) })
            // A Dock click counts from the first notification of a change, not the last one of a storm.
            if case .crossing(_, let time, let previous) = group.focus, pass.now - time > EngineConfig.crossingTTL {
                group.focus = previous.map(FocusState.resolved) ?? .none
            }
        }
        groups[id] = group
    }

    /// A read confirms only a full settle after the last Space notification, so one taken mid-transition cannot ride
    /// the clock of a re-read that was pending before it.
    fileprivate mutating func onSpaceWillChange(group id: UInt32, _ pass: inout Pass) {
        beginSpaceChange(group: id, &pass)
        guard let group = groups[id], let deferred = group.phase.deferred else { return }
        groups[id]!.phase = SpacePhase(space: group.space, deferred: DeferredCensus(key: deferred.key, since: pass.now))
    }

    fileprivate mutating func onSpaceChanged(key: SpaceKey, epoch: UInt64, windows observed: [ObservedWindow], group id: UInt32, _ pass: inout Pass) {
        guard let group = groups[id], !key.isEmpty || (observed.isEmpty && !key.isAuthoritative) else {
            return pass.effects.append(.log("space census without identity ignored"))
        }
        let mine = Set(routed(observed, to: id).map(\.id))
        let windows = observed.filter { $0.isValid && mine.contains($0.id) }
        for window in observed where !window.isValid || owner(of: window.id).map({ $0 != id }) == true {
            pass.effects.append(.log("census window dropped tile=\(window.id.rawValue)"))
        }
        let verdict = censusVerdict(windows, group: id)
        let deferred = group.phase.deferred.flatMap { $0.covers(key) ? $0 : nil }
        let settled = deferred.map { pass.now - $0.since >= EngineConfig.censusSettle } ?? false
        let ids = Set(windows.map { $0.id.rawValue })
        if key == group.space {
            let moved = stashedElsewhere(ids, group: id)
            // Nothing has left the screen, so the hold skips the teardown: swipes, timers and focus survive. Like any
            // deferral it still holds frames, refuses commands and new gestures, and drops windowAdded until the re-read.
            if key.isAuthoritative, !settled, !moved.isEmpty {
                return deferCensus(DeferredCensus(key: key, since: deferred?.since ?? pass.now, holds: group.phase.awaitsTeardown),
                                   reason: "same-Space census lists windows stashed elsewhere", group: id, &pass)
            }
            groups[id]!.phase = .settled(key)
            if case .crossing(_, _, let previous) = group.focus { groups[id]!.focus = previous.map(FocusState.resolved) ?? .none }
            if verdict == .trusted || (verdict == .mixed && (settled || moved.isEmpty)) {
                let skipped = settled ? [] : moved
                for window in visualOrder(windows) where !skipped.contains(window.id.rawValue) { add(window, to: id, &pass) }
                if !skipped.isEmpty { pass.effects.append(.log("same-Space census skipped windows stashed elsewhere")) }
            } else if !windows.isEmpty {
                pass.effects.append(.log("same-Space census not adopted"))
            }
            pass.layout.insert(id)
            pass.persist = true
            return
        }
        guard epoch > group.epoch else { return pass.effects.append(.log("stale space census ignored")) }
        let reads = (deferred?.settledReads ?? 0) + (settled ? 1 : 0)
        var target: (onto: SpaceKey?, prunes: Bool) = (key, false)
        switch verdict {
        case .trusted: break
        case .empty where group.windows.isEmpty || settled: break
        case .mixed where settled && key.isAuthoritative: break
        // A stale fingerprint read changes when it is read again.
        case .mixed where settled && (deferred?.lastSettled == key || reads >= EngineConfig.censusReads):
            target = commitTarget(ids, group: id)
        case .empty, .mixed, .invalid:
            // A read that cannot commit leaves the group torn down, so nothing the health check adds lands on the
            // Space it left.
            if group.phase.awaitsTeardown { beginSpaceChange(group: id, &pass) }
            let census = DeferredCensus(key: key, since: settled ? pass.now : deferred?.since ?? pass.now,
                                        settledReads: reads, lastSettled: settled ? key : deferred?.lastSettled)
            return deferCensus(census, reason: "\(verdict) space census", group: id, &pass)
        }
        commitSpace(key, onto: target.onto, epoch: epoch, windows: windows, group: id, &pass)
        // A fingerprint is matched by overlap, so a window that moved here must leave the Space it came from, or that
        // Space's stash stops matching its own windows. A window on screen here is hidden nowhere else.
        if target.prunes { prune(ids, from: otherSpaces(than: id)) }
        else if verdict == .trusted || key.isAuthoritative { prune(ids, from: otherSpaces(than: id), hiddenOnly: true) }
    }

    private mutating func deferCensus(_ census: DeferredCensus, reason: String, group id: UInt32, _ pass: inout Pass) {
        groups[id]!.phase = SpacePhase(space: groups[id]!.space, deferred: census)
        pass.effects.append(.log("\(reason) deferred"))
        pass.effects.append(.requestCensus(group: id, after: census.since + EngineConfig.censusSettle - pass.now))
    }

    /// `onto` names the saved strip to restore, by key or by overlap; nil restores none.
    private mutating func commitSpace(_ key: SpaceKey, onto: SpaceKey?, epoch: UInt64, windows: [ObservedWindow],
                                      group id: UInt32, _ pass: inout Pass) {
        let leads = activeGroup == id && groups[id]!.focusedAt > -.infinity
        beginSpaceChange(group: id, &pass)
        let departing = groups[id]!
        stash(departing, id: id, time: pass.now)
        let display = topology.group(id: id)!
        let match = onto.flatMap { spaces.lookup(group: display, space: $0, windows: windows, separateSpaces: topology.separateSpaces) }
        if let match { spaces.adopt(match, as: key, group: id) }
        let live = if case .live? = match?.source { true } else { false }
        var group = restoredGroup(display: display, config: config, key: key, epoch: epoch, windows: windows,
                                  saved: match?.snapshot, hidesMissing: live, time: pass.now)
        group.focusedAt = departing.focusedAt
        // A saved window another display holds now, on screen or hidden, is that display's.
        group.hidden = group.hidden.filter { tile, _ in !groups.contains { $0.key != id && ($0.value.windows[tile] != nil || $0.value.hidden[tile] != nil) } }
        groups[id] = group
        for other in groups.keys where other != id {
            for window in windows { groups[other]!.hidden[window.id] = nil }
        }
        var restore = group.focus.decision?.tile ?? group.strip.activeColumn?.activeTile
        var source: FocusSource = .restore
        // Only an activation of an app with no window here is a Dock click across Spaces; a focus held for a hidden
        // window of an app that is still here is not.
        if case .crossing(let intent, _, _) = departing.focus, intent.source == .appActivation, let pid = intent.pid,
           !departing.windows.values.contains(where: { $0.pid == pid }) {
            let appWindows = windows.filter { $0.pid == pid }
            if let tile = intent.tile, appWindows.contains(where: { $0.id == tile }) { restore = tile; source = .appActivation }
            else if let tile = appWindows.map(\.id).ordered().first { restore = tile; source = .appActivation }
        }
        // One display takes OS focus: the one the Dock click crossed to, else the one that had it. The rest restore
        // at their old decision time, so they neither take the commands nor hold off a focus report.
        let quiet = source == .appActivation || leads ? nil : departing.focus.decision?.time ?? -.infinity
        focus(FocusIntent(tile: restore, source: source), group: id, &pass, quietSince: quiet, animated: false)
        pass.layout.insert(id)
        pass.persist = true
    }

    mutating func stash(_ group: GroupState?, id: UInt32, time: Double) {
        guard let group, let saved = snapshot(group, id: id, time: time), !saved.space.isEmpty else { return }
        spaces.live[GroupSpace(group: id, space: saved.space)] = saved
    }

    private func censusVerdict(_ windows: [ObservedWindow], group id: UInt32) -> CensusVerdict {
        guard Set(windows.map(\.id)).count == windows.count else { return .invalid }
        guard !windows.isEmpty else { return .empty }
        let fingerprints = sessionSpaces(group: id).map(\.windows)
        return spansMultipleSpaces(onScreenIDs: Set(windows.map { $0.id.rawValue }), knownFingerprints: fingerprints) ? .mixed : .trusted
    }

    /// This group's Spaces of this session: every saved strip, and the current one as it stands.
    private func sessionSpaces(group id: UInt32) -> [(space: SpaceKey, windows: Set<UInt32>)] {
        var known = otherSpaces(than: id).filter { $0.key.group == id }.map { ($0.key.space, $0.value.fingerprint) }
        if let here = groups[id]!.space { known.append((here, Set(groups[id]!.windows.keys.map(\.rawValue)))) }
        return known
    }

    /// Windows that moved between two Spaces leave the one they came from partly listed, so a mixed read commits onto
    /// the one Space of this session it lists whole, and only then prunes. Of several, the strip just left, else the
    /// largest; of none, a fresh strip (nil). An ambiguous read deletes no saved strip.
    private func commitTarget(_ ids: Set<UInt32>, group id: UInt32) -> (onto: SpaceKey?, prunes: Bool) {
        let whole = sessionSpaces(group: id).filter { !$0.windows.isEmpty && $0.windows.isSubset(of: ids) }
        if whole.count == 1 { return (whole[0].space, true) }
        if let here = groups[id]!.space, whole.contains(where: { $0.space == here }) { return (here, false) }
        let largest = whole.max {
            $0.windows.count != $1.windows.count ? $0.windows.count < $1.windows.count : SpaceOrder(id, $1.space) < SpaceOrder(id, $0.space)
        }
        return (largest?.space, false)
    }

    /// Every live stash except this group's current Space, on any display.
    private func otherSpaces(than id: UInt32) -> [GroupSpace: Snapshot] {
        let here = groups[id]!.space.map { GroupSpace(group: id, space: $0) }
        return spaces.live.filter { $0.key != here }
    }

    private func stashedElsewhere(_ ids: Set<UInt32>, group id: UInt32) -> Set<UInt32> {
        let newcomers = ids.filter { groups[id]!.windows[TileID($0)] == nil }
        return otherSpaces(than: id).values.reduce(into: []) { $0.formUnion($1.fingerprint.intersection(newcomers)) }
    }

    fileprivate mutating func onFrameCompleted(_ tile: TileID, revision: UInt64, result: FrameResult, _ pass: inout Pass) {
        guard let request = frames[tile], request.revision == revision, request.scope == pass.scope else { return }
        switch result {
        case .applied: appliedFrames[tile] = request
        case .failed, .timedOut, .sizeUnconfirmed:
            frames.removeValue(forKey: tile)
            if case .sizeUnconfirmed = result { appliedFrames[tile] = request }
            else { appliedFrames.removeValue(forKey: tile) }
            if !timers.values.contains(where: { if case .retryFrames = $0.action { return $0.scope == pass.scope }; return false }) {
                schedule(.retryFrames, delay: EngineConfig.frameRetryDelay, &pass)
            }
        }
    }

    fileprivate mutating func onTimer(_ token: TimerToken, group id: UInt32, _ pass: inout Pass) {
        if let session = pointer, session.timer?.token == token { return onSessionTimer(session, &pass) }
        guard let work = timers[token], work.scope == pass.scope, pass.now >= work.deadline else { return }
        timers.removeValue(forKey: token)
        switch work.action {
        case .retryFrames: pass.layout.insert(id)
        case .focus(let intent): focus(intent, group: id, &pass)
        }
    }

    /// Only strips still moving are laid out, so a frame tick costs nothing on displays at rest.
    fileprivate mutating func onTick(_ pass: inout Pass) {
        for id in groups.keys.sorted() {
            guard var group = groups[id], !group.phase.isChanging else { continue }
            let momentum = if case .momentum(nil) = pointer?.phase { pointer?.scope.group == id } else { false }
            guard group.isAnimating || momentum else { continue }
            _ = group.strip.settleWidthAnimations(at: pass.now)
            _ = group.strip.settleRaiseAnimations(at: pass.now)
            if case .animation(let animation) = group.strip.viewOffset, animation.isDone(at: pass.now) {
                group.strip.viewOffset = .static(animation.to)
            }
            if momentum, !group.strip.viewOffset.isAnimating {
                pointer?.phase = .momentum(settledAt: pass.now)
            }
            groups[id] = group
            pass.layout.insert(id)
        }
    }

    /// Forget what was written so the flush writes every frame again. Pending focus is left alone.
    private mutating func recover(group id: UInt32, _ pass: inout Pass) -> CommandOutcome {
        guard let group = groups[id], !group.phase.isChanging else { return .refused("space change in progress") }
        for tile in group.windows.keys.ordered() {
            frames.removeValue(forKey: tile)
            appliedFrames.removeValue(forKey: tile)
        }
        pass.layout.insert(id)
        return .accepted
    }

    /// Forget every saved strip, on disk and in this session. No pending work may save one again: a Space change still
    /// in progress would stash the departing strip, so it refuses, and a debounced focus would save the strip it moves,
    /// so it is cancelled. The empty book goes out at once; the strips on screen are saved again at their next change.
    private mutating func clearPositions(_ pass: inout Pass, bundleID: String? = nil) -> CommandOutcome {
        guard !groups.values.contains(where: \.phase.isChanging) else { return .refused("space change in progress") }
        for id in groups.keys.sorted() { cancelTimers(group: id, &pass, focusOnly: true) }
        if let bundleID {
            guard !bundleID.isEmpty else { return .refused("bundle id is required") }
            spaces.live = spaces.live.mapValues { $0.excluding(bundleID: bundleID) }
            spaces.disk = spaces.disk.map { $0.excluding(bundleID: bundleID) }
        } else { spaces = SpaceBook() }
        pass.effects.append(.persist(spaces))
        pass.effects.append(.log("positions cleared"))
        return .accepted
    }

    /// Hidden windows get their release frames again: the write at hide time may have failed.
    fileprivate mutating func release(group id: UInt32, _ pass: inout Pass) {
        let hidden = (groups[id]?.hidden ?? [:]).sorted { $0.key.rawValue < $1.key.rawValue }
            .compactMap { tile, hidden in hidden.frame.map { (tile: tile, pid: hidden.window.pid, frame: $0) } }
        write(releaseFrames(group: id, at: pass.now) + hidden, group: id, &pass)
    }

    /// Release only walks the strip, so windows that leave it alive (their app hid, or one minimized) get their release
    /// frames now, from one cascade. Written after the removals, whose invalidation would cancel them. Each one's
    /// column, or its floating, and its release frame are remembered.
    fileprivate mutating func hide(_ tiles: [TileID], _ pass: inout Pass) {
        hideOnSavedStrips(Set(tiles).filter { owner(of: $0) == nil }, at: pass.now)
        for id in groups.keys.sorted() where tiles.contains(where: { groups[id]!.windows[$0] != nil }) {
            hide(tiles.filter { groups[id]!.windows[$0] != nil }, from: id, &pass)
        }
    }

    private mutating func hide(_ tiles: [TileID], from id: UInt32, _ pass: inout Pass) {
        let writes = releaseFrames(group: id, at: pass.now).filter { tiles.contains($0.tile) }
        for tile in tiles {
            guard let group = groups[id], let window = group.windows[tile] else { continue }
            let index = group.strip.columnIndex(of: tile)
            let column = index.map { group.strip.columns[$0] }.map {
                Column(tiles: [tile], width: $0.width, presetIndex: $0.presetIndex, isFullWidth: $0.isFullWidth)
            }
            remove(tile, from: id, &pass)
            groups[id]!.hidden[tile] = HiddenTile(window: window, column: column, place: index.map(group.placeAmongHidden) ?? 0,
                                                  frame: writes.first { $0.tile == tile }?.frame)
        }
        write(writes, group: id, &pass)
    }

    /// An app that hid while its windows were on another Space hid them there too: each keeps its place on that saved
    /// strip, as an absent window does on return, so the strip is still listed whole when the rest comes back on screen.
    private mutating func hideOnSavedStrips(_ tiles: Set<TileID>, at time: Double) {
        for (key, saved) in spaces.live where saved.windows.contains(where: { tiles.contains($0.id) }) {
            guard let display = topology.group(id: key.group) else { continue }
            let rest = saved.windows.filter { !tiles.contains($0.id) }
            let group = restoredGroup(display: display, config: config, key: key.space, epoch: 0, windows: rest, saved: saved,
                                      hidesMissing: true, time: time)
            spaces.live[key] = snapshot(group, id: key.group, time: time)
        }
    }

    private mutating func write(_ writes: [(tile: TileID, pid: Int32, frame: AXRect)], group id: UInt32, _ pass: inout Pass) {
        guard let scope = scope(for: id) else { return }
        for (tile, pid, frame) in writes { write(tile, pid: pid, frame: frame, scope: scope, &pass) }
    }

    /// Where quitting leaves each tile: off-screen ones come back on screen at their own size, cascaded so none hides
    /// another completely, and columns the raise style lowered, or whose last write failed, go to their full frame.
    /// The cascade starts one step further for each hidden window, so successive hides do not stack exactly. Each
    /// lands on the display of the group nearest where it was parked.
    private func releaseFrames(group id: UInt32, at time: Double) -> [(tile: TileID, pid: Int32, frame: AXRect)] {
        guard let group = groups[id], let display = topology.group(id: id) else { return [] }
        var step = 30 * Double(group.hidden.count)
        return computeTargetFrames(strip: group.strip, time: time).compactMap { target in
            guard let pid = group.windows[target.tileID]?.pid else { return nil }
            let frame = axRect(ViewportRect(target.frame), on: display)
            guard target.isOffScreen else {
                return config.raiseHeight > 0 || frames[target.tileID]?.frame != frame ? (target.tileID, pid, frame) : nil
            }
            let size = target.frame.size
            let area = display.displays.min { abs($0.area.midX - frame.rect.midX) < abs($1.area.midX - frame.rect.midX) }!.area
            defer { step += 30 }
            return (target.tileID, pid, AXRect(CGRect(x: area.minX + step.truncatingRemainder(dividingBy: max(1, area.width - size.width)),
                                                      y: area.minY + step.truncatingRemainder(dividingBy: max(1, area.height - size.height)),
                                                      width: size.width, height: size.height)))
        }
    }

    /// One frame write. A non-finite frame never leaves the engine.
    @discardableResult
    private mutating func write(_ tile: TileID, pid: Int32, frame: AXRect, scope: EventScope, animating: Bool = false, _ pass: inout Pass) -> FrameRequest? {
        guard frame.rect.isFinite else {
            pass.effects.append(.log("invalid layout rejected"))
            return nil
        }
        let request = FrameRequest(tile: tile, pid: pid, frame: frame, revision: nextRevision(), scope: scope, animating: animating)
        pass.effects.append(.setFrame(request))
        return request
    }

    fileprivate mutating func onConfig(_ next: EngineConfig, _ pass: inout Pass) {
        cancelPointer(&pass)
        config = next
        for id in groups.keys.sorted() {
            next.configure(&groups[id]!.strip)
            groups[id]!.strip.recalculateWidths(at: pass.now)
            pass.layout.insert(id)
        }
        pass.persist = true
    }

    fileprivate mutating func flush(_ pass: inout Pass) {
        for id in pass.layout.sorted() {
            guard var group = groups[id], !group.phase.isChanging, let scope = scope(for: id),
                  let display = topology.group(id: id) else { continue }
            if config.raiseHeight > 0 {
                group.strip.retargetRaise(height: config.raiseHeight, params: config.animate ? config.scroll : nil, at: pass.now)
                groups[id] = group
            }
            for target in computeTargetFrames(strip: group.strip, time: pass.now, raiseHeight: config.raiseHeight) {
                let frame = axRect(ViewportRect(target.frame), on: display)
                guard let pid = group.windows[target.tileID]?.pid else { continue }
                if let existing = frames[target.tileID], existing.frame == frame, existing.scope == scope,
                   existing.animating == group.isAnimating { continue }
                if let request = write(target.tileID, pid: pid, frame: frame, scope: scope, animating: group.isAnimating, &pass) { frames[target.tileID] = request }
            }
        }
        guard pass.persist else { return }
        for id in groups.keys.sorted() { stash(groups[id], id: id, time: pass.now) }
        pass.effects.append(.persist(spaces))
    }
}

enum CensusVerdict {
    case trusted, empty, mixed, invalid
}

extension Strip {
    func columnIndex(of tile: TileID) -> Int? { columns.firstIndex { $0.tiles.contains(tile) } }

    mutating func insertTile(_ tile: TileID, at time: Double) {
        insertColumn(Column(tiles: [tile], width: defaultWidth), at: time)
    }

    /// Puts a column back at `index` without moving the view: the active column stays active, where it was on screen.
    mutating func restoreColumn(_ column: Column, at index: Int, time: Double) {
        guard !columns.isEmpty else { return insertColumn(column, at: time, atIndex: 0) }
        let index = min(index, columns.count), active = activeColumnIndex, offset = viewOffset
        insertColumn(column, at: time, atIndex: index)
        activeColumnIndex = index <= active ? active + 1 : active
        viewOffset = offset
    }

    mutating func removeTile(_ tile: TileID, at time: Double) {
        guard let index = columnIndex(of: tile) else { return }
        columns[index].tiles.removeAll { $0 == tile }
        if columns[index].tiles.isEmpty { removeColumn(at: index, at: time) }
        else { columns[index].activeTileIndex = min(columns[index].activeTileIndex, columns[index].tiles.count - 1) }
    }

    /// Raise targets derive from the active column, so no focus path has to remember to start them.
    mutating func retargetRaise(height: Double, params: SpringParams?, at time: Double) {
        for index in columnData.indices {
            let target = index == activeColumnIndex ? 0 : height
            guard columnData[index].cachedRaiseTarget != target else { continue }
            let from = columnData[index].currentRaiseOffset(at: time)
            columnData[index].raiseAnimation = params.map { SpringAnimation(from: from, to: target, startTime: time, params: $0) }
            columnData[index].cachedRaiseTarget = target
        }
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

func shouldFloat(_ window: ObservedWindow, config: EngineConfig) -> Bool {
    config.rules.first(where: { $0.matches(window) })?.floating ?? window.floating
}

/// A window that floated only for its facts (it registered untitled) tiles once new facts say it tiles. One the user
/// floated never had floating facts, so it stays.
func joinsStrip(was old: ObservedWindow, now new: ObservedWindow, config: EngineConfig) -> Bool {
    shouldFloat(old, config: config) && !shouldFloat(new, config: config)
}

func visualOrder(_ windows: [ObservedWindow]) -> [ObservedWindow] {
    windows.sorted {
        let lhsX = $0.initialFrame?.rect.minX ?? 0
        let rhsX = $1.initialFrame?.rect.minX ?? 0
        if lhsX != rhsX { return lhsX < rhsX }
        return $0.id.rawValue < $1.id.rawValue
    }
}
