import AppKit
import Core
import Engine
import Foundation
import Platform

@MainActor private var flushQueued = false
@MainActor private var logLimiter = LogLimiter()

/// Flush terminal output once per main run-loop turn. Bundled output also flushes when checking rotation.
@MainActor
public func logLine(_ line: String) {
    guard logLimiter.allows(line, at: TimeUtil.now()) else { return }
    if runtimeTimestamps {
        writeRuntimeLog(String(format: "[%.6f] %@", TimeUtil.now(), line))
    } else {
        writeRuntimeLog(line)
    }
    guard !flushQueued else { return }
    flushQueued = true
    DispatchQueue.main.async { MainActor.assumeIsolated { flushQueued = false; fflush(stdout) } }
}

/// Where this instance keeps its socket, config and state. Each has a `REEL_*` override for sandboxed test runs.
public struct Paths: Sendable {
    public let configDir: String
    public let stateDir: String
    public var configFile: String { configDir + "/config.toml" }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func dir(_ key: String, _ fallback: String) -> String { environment[key].flatMap { $0.isEmpty ? nil : $0 } ?? fallback }
        configDir = dir("REEL_CONFIG_DIR", home + "/.config/reel")
        stateDir = dir("REEL_STATE_DIR", home + "/.local/state/reel")
    }
}

/// `REEL_MANAGE_ONLY_PIDS`: comma-separated pids. Unset, empty or unparsable means manage every app.
public func managedPidAllowlist(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Set<Int32>? {
    let pids = Set((environment["REEL_MANAGE_ONLY_PIDS"] ?? "").split(separator: ",").compactMap {
        Int32($0.trimmingCharacters(in: .whitespaces))
    }.filter { $0 > 0 })
    return pids.isEmpty ? nil : pids
}

/// The one main-actor loop: it stamps events, calls `reduce`, and hands the effects to the executor, the scheduler,
/// the frame loop and the focus indicator. Nothing here decides layout or focus.
@MainActor
public final class Loop {
    public private(set) var world: World
    private var censusSerial: UInt64 = 0
    private var pendingCensuses: [UInt32: UInt64] = [:]
    private var reads = LoopReads()
    private var censusObserver: (any CensusObserver)!
    private var effectsSink: (([Effect]) -> Void)?
    /// The group commands act on.
    public var group: UInt32 { world.activeGroup ?? 0 }
    public private(set) var config = AppConfig()
    public private(set) var configError: String?
    public private(set) var paused = false
    public let paths: Paths
    public let allowedPids = managedPidAllowlist()
    public var onChange: (() -> Void)?

    private(set) var executor: Executor!
    private(set) var observer: Observer!
    private(set) var scheduler: Scheduler!
    public private(set) var store: SnapshotStore!
    private(set) var spaces: SpaceObserver!
    private(set) var displays: DisplayObserver!
    private(set) var pointer: PointerObserver!
    private lazy var frameLoop = FrameLoop()
    private lazy var indicator = FocusIndicator()
    private lazy var hotkeys = HotkeyManager()
    private var replies: [UInt64: ReplyPayload] = [:]
    private var lastRequest: UInt64 = 0
    private var indicatorTile: TileID?
    private var confirmedFocus: [Int32: TileID] = [:]
    private var quitting = false
    private var observing = false

    public init(paths: Paths = Paths()) {
        self.paths = paths
        world = World(topology: DisplayObserver.read(revision: 1))
        executor = Executor(worker: { [unowned self] in observer.workers[$0] }, log: logLine)
        observer = Observer(executor: executor, allowedPids: allowedPids,
                            managed: { [unowned self] in Set(world.groups.values.flatMap(\.windows.keys).map(\.rawValue)) },
                            elsewhere: { [unowned self] in world.trackedElsewhere },
                            paused: { [unowned self] in paused },
                            emit: { [unowned self] in send($0, stamp: $1) }, log: logLine,
                            onActivation: { [weak self] in self?.updateIndicator(frontmostPID: $0) })
        scheduler = Scheduler(clock: TimeUtil.now, isCurrent: { [unowned self] in world.scope(for: $0.group) == $0 },
                              deliver: { [unowned self] in run($0) }, log: logLine)
        store = SnapshotStore(directory: paths.stateDir, log: logLine)
        censusObserver = observer
        spaces = SpaceObserver(clock: TimeUtil.now, changed: { [unowned self] in spaceChanged(after: $0) }, log: logLine,
                               readSpace: reads.space)
        displays = DisplayObserver(current: { [unowned self] in world.topology }, changed: { [unowned self] in topologyChanged($0) },
                                   log: logLine)
        pointer = PointerObserver(world: { [unowned self] in world }, paused: { [unowned self] in paused },
                                  send: { [unowned self] in send(.pointer($0, session: $1)) }, log: logLine)
        frameLoop.onTick = { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        hotkeys.onAction = { [weak self] action in MainActor.assumeIsolated { self?.hotkey(action) } }
    }

    package init(world: World, paths: Paths, censusObserver: any CensusObserver, reads: LoopReads,
                 executor: Executor? = nil, effects: @escaping ([Effect]) -> Void) {
        self.world = world
        self.paths = paths
        self.censusObserver = censusObserver
        self.reads = reads
        effectsSink = effects
        self.executor = executor
        spaces = SpaceObserver(clock: TimeUtil.now, changed: { _ in }, log: { _ in }, readSpace: reads.space)
    }

    public func start() {
        logLine("loop: groups=\(DisplayObserver.describe(world.topology)) separateSpaces=\(world.topology.separateSpaces) managedPids=\(allowedPids.map { $0.sorted().description } ?? "all")")
        observer.clock.current = world.stamp
        sendGlobal(.loadSnapshots(store.load()))
        // The defaults go live first, so a file the schema rejects leaves hotkeys working and the error in the menu bar.
        apply(config)
        reloadConfig()
        frameLoop.start()
        displays.start()
        pointer.start()
        observer.start(timeout: 1.5) { [weak self] in
            guard let self else { return }
            observing = true
            world.groups.keys.sorted().forEach(census(group:))
            spaces.start()
        }
    }

    // MARK: Events

    /// Reduce `kind` in `group`, else the group the engine routes it to, under the scope that group had in `stamp`,
    /// when it was observed, or else its current scope.
    @discardableResult
    public func send(_ kind: Event.Kind, group: UInt32? = nil, stamp: Stamp? = nil) -> [Effect] {
        guard !quitting, let id = group ?? world.route(kind),
              let scope = stamp.map({ world.scope(for: id, stamp: $0) }) ?? world.scope(for: id) else {
            if case .focus(let intent) = kind { logLine(intent.droppedLog(reason: quitting ? "quitting" : "missing-group")) }
            return []
        }
        if case .windowAdded(let window, _) = kind {
            let observed = reads.space(id, !world.topology.separateSpaces)?.key
            guard censusAdoption(reads.memberships(window.id.rawValue), observed: observed, settled: world.groups[id]?.space) else {
                logLine("loop: adoption held for Space census tile=\(window.id.rawValue) group=\(id)")
                return []
            }
        }
        return reduceAndRun(Event(scope: scope, kind: kind))
    }

    /// A global event goes out even with no display, so a topology or config change is never lost.
    private func sendGlobal(_ kind: Event.Kind) {
        let scope = world.activeGroup.flatMap(world.scope(for:))
            ?? EventScope(topologyRevision: world.topology.revision, group: 0, spaceEpoch: 0)
        reduceAndRun(Event(scope: scope, kind: kind))
    }

    @discardableResult
    private func reduceAndRun(_ event: Event) -> [Effect] {
        let currentScope = world.scope(for: event.scope.group) == event.scope
        let previousEpoch = world.groups[event.scope.group]?.epoch
        let effects = reduce(&world, event, now: max(TimeUtil.now(), world.time))
        if currentScope {
            let tile: TileID?
            switch event.kind {
            case .focus(let intent) where intent.source == .axFocus || intent.source == .appActivation:
                let group = world.groups[event.scope.group]
                tile = (intent.observedSpace == nil || intent.observedSpace == group?.space)
                    && (intent.pid == nil || intent.tile.flatMap(pid(of:)) == intent.pid) ? intent.tile : nil
            case .spaceChanged(let key, let epoch, _, let frontmost)
                where world.groups[event.scope.group]?.space == key
                    && world.groups[event.scope.group]?.phase.acceptsFocus == true && epoch > previousEpoch ?? 0:
                tile = frontmost.flatMap { world.owner(of: $0) == event.scope.group ? $0 : nil }
            default: tile = nil
            }
            if let tile, let pid = pid(of: tile) { confirmedFocus[pid] = tile }
        }
        executor?.synchronizeFocus(with: world, paused: paused)
        if let effectsSink {
            effectsSink(effects)
            return effects
        }
        observer.clock.current = world.stamp
        run(effects)
        pointer.sync(world.pointer)
        if world.needsTicks || indicator.isAnimating { frameLoop.resume() }
        updateIndicator()
        return effects
    }

    private func run(_ job: Scheduler.Job) {
        guard !quitting else { return }
        switch job {
        case .event(let event): reduceAndRun(event)
        case .census(let group): census(group: group)
        }
    }

    private func run(_ effects: [Effect]) {
        for effect in effects {
            switch effect {
            case .setFrame(let request): if !paused { executor.setFrame(request) }
            case .invalidateFrame(let tile, _): executor.invalidate(tile)
            case .focus(let tile, _): if !paused, let pid = pid(of: tile) { executor.focus(tile, pid: pid, scope: world.scope(for: world.owner(of: tile)!)!) }
            case .raise(let tile): if !paused, let pid = pid(of: tile) { executor.raise(tile, pid: pid) }
            case .close(let tile): if let pid = pid(of: tile) { executor.close(tile, pid: pid) }
            case .reply(let id, let payload): replies[id] = payload
            case .overlay(let overlay): pointer.show(overlay)
            case .consumeInput, .replayPress: break
            case .persist(let book): store.save(book.persisted)
            case .requestCensus(let group, let after):
                guard let owner = world.scope(for: group) else { continue }
                scheduler.schedule(.census(group: group), deadline: world.time + after, owner: owner, job: .census(group: group))
            case .schedule(let token, let deadline, let event):
                scheduler.schedule(.engine(token), deadline: deadline, owner: event.scope, job: .event(event))
            case .cancel(let token): scheduler.cancel(.engine(token))
            case .log(let line): logLine("engine: \(line)")
            }
        }
    }

    /// Read the census now, or after `delay` through the group's one census slot, so a later request replaces it.
    private func census(group: UInt32, after delay: Double) {
        guard delay > 0 else { return census(group: group) }
        guard let owner = world.scope(for: group) else { return }
        scheduler.schedule(.census(group: group), deadline: TimeUtil.now() + delay, owner: owner, job: .census(group: group))
    }

    /// A fresh on-screen read, sent as a new `spaceChanged`; a deferred census is never answered from a cache. Every
    /// census proposes the next epoch, so the one `reduce` commits retires the old Space's focus events and timers.
    package func census(group: UInt32) {
        guard let owner = world.scope(for: group) else { return }
        let shared = !world.topology.separateSpaces
        let target = reads.space(group, shared)?.key
        censusSerial += 1
        let serial = censusSerial
        pendingCensuses[group] = serial
        censusObserver.prepareCensus(reads.screen()) { [weak self] frontmost in
            guard let self, !quitting, pendingCensuses[group] == serial else { return }
            pendingCensuses[group] = nil
            guard world.scope(for: group) == owner,
                  reads.space(group, shared)?.key == target else { return }
            let screen = reads.screen()
            let candidates = censusObserver.census(screen, space: target)
            let windows = world.routed(candidates, to: group)
            if runtimeTimestamps {
                logLine("loop: census input group=\(group) screen=\(screen.filter { $0.layer == 0 }.map(\.windowID)) known=\(censusObserver.known.keys.sorted()) candidates=\(candidates.map { $0.id.rawValue }) memberships=\(candidates.map { "\($0.id.rawValue)=\(reads.memberships($0.id.rawValue) ?? [])" })")
            }
            guard let key = spaces.key(display: group, shared: shared, windows: windows) else {
                return logLine("loop: census skipped on a system Space group=\(group)")
            }
            let epoch = (world.groups[group]?.epoch ?? 0) + 1
            logLine("loop: census group=\(group) key=\(key.debugDescription) windows=\(windows.count)")
            send(.spaceChanged(key: key, epoch: epoch, windows: windows, frontmost: frontmost), group: group)
            if effectsSink == nil { reportFrontmostFocus() }
        }
    }

    /// Only strips whose display now shows another Space are torn down and read again, so a switch on one display
    /// leaves the others alone. A display showing a system Space (a full-screen app) is left as it is.
    private func spaceChanged(after delay: Double) {
        let shared = !world.topology.separateSpaces
        var reads: [UInt32: SpaceKey] = [:]
        var system = Set<UInt32>()
        for id in world.groups.keys {
            guard let space = SpaceObserver.space(display: id, shared: shared) else { continue }
            if space.isUserSpace { reads[id] = space.key } else { system.insert(id) }
        }
        let changing = world.groupsOnAnotherSpace(reads)
        logLine("space: routing reads=\(reads) changing=\(changing) system=\(system.sorted()) pointer=\(String(describing: world.pointer?.token.rawValue))")
        for id in changing where !system.contains(id) {
            send(.spaceWillChange, group: id)
            census(group: id, after: delay)
        }
    }

    private func tick() {
        sendGlobal(.tick)
        indicator.tick(time: TimeUtil.now())
        if !world.needsTicks && !indicator.isAnimating { frameLoop.pause() }
    }

    private func topologyChanged(_ next: Topology) {
        sendGlobal(.topologyChanged(next))
        guard observing else { return }
        world.groups.keys.sorted().forEach(census(group:))
        recover()
        onChange?()
    }

    // MARK: Commands

    public func pid(of tile: TileID) -> Int32? { world.owner(of: tile).flatMap { world.groups[$0]?.windows[tile]?.pid } }

    /// The window a toggle or close acts on: the focus decision, else the active column's tile.
    public var focusedTile: TileID? {
        guard let state = world.groups[group] else { return nil }
        return state.focus.decision?.tile ?? state.strip.activeColumn?.activeTile
    }

    /// Every frame written again in full, over whatever moved while nothing was listening.
    @discardableResult
    public func recover() -> CommandOutcome {
        observer?.workers.values.forEach { $0.forgetSizes() }
        return everyGroup(.recover)
    }

    @discardableResult
    private func everyGroup(_ command: Command) -> CommandOutcome {
        let outcomes = world.groups.keys.sorted().map { request(command, group: $0) }
        return outcomes.first { $0 != .accepted } ?? (outcomes.isEmpty ? .refused("no display") : .accepted)
    }

    /// Run a command as an IPC request and return the engine's answer.
    public func request(_ command: Command, group: UInt32? = nil) -> CommandOutcome {
        lastRequest += 1
        let id = lastRequest
        send(.ipc(id: id, command: command), group: group)
        guard case .command(let outcome)? = replies.removeValue(forKey: id) else { return .refused("no display") }
        return outcome
    }

    public func hotkey(_ action: HotkeyAction) {
        guard !paused else { return }
        let command: Command? = switch action {
        case .focusLeft: .focusLeft
        case .focusRight: .focusRight
        case .moveColumnLeft: .moveLeft
        case .moveColumnRight: .moveRight
        case .cycleWidthPreset: .cycleWidthPreset
        case .toggleFullWidth: focusedTile.map(Command.toggleFullWidth)
        case .toggleFloating: focusedTile.map(Command.toggleFloating)
        case .closeWindow: focusedTile.map(Command.close)
        case .focusUp: .focusUp
        case .focusDown: .focusDown
        }
        if let command { send(.command(command, .keyboard)) }
    }

    /// Pausing hands every window back as quitting does, so none waits out the pause as an off-screen sliver.
    public func setPaused(_ value: Bool) {
        guard value != paused else { return }
        if value, let session = world.pointer { send(.pointer(.cancel, session: session.token)) }
        if value { executor?.invalidateFocus(); send(.command(.release, .ipc)) }
        // Reconcile deaths while effects are still held; additions are admitted after resume.
        changePauseState(value) { observer.healthCheck() }
        logLine("loop: paused=\(value)")
        if value {
            indicator.hide()
            indicatorTile = nil
        } else {
            // Windows opened during the pause join, and every frame is written again over whatever moved meanwhile.
            recover()
            // Focus reports were dropped while paused; read the real focus again so commands act on it.
            reportFrontmostFocus()
        }
        onChange?()
    }

    private func reportFrontmostFocus() {
        NSWorkspace.shared.frontmostApplication.flatMap { observer.workers[$0.processIdentifier] }?.reportFocus(activation: nil)
    }

    /// Load the config file. On any error the previous config stays active and the error is kept for the menu bar.
    @discardableResult
    public func reloadConfig() -> String? {
        let path = paths.configFile
        do {
            if !FileManager.default.fileExists(atPath: path) {
                try FileManager.default.createDirectory(atPath: paths.configDir, withIntermediateDirectories: true)
                try defaultConfigSource().write(toFile: path, atomically: true, encoding: .utf8)
            }
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let next = try AppConfig.parse(text)
            configError = Self.bindingError(next.keys)
            if configError == nil {
                apply(next)
                logLine("config: loaded \(path)")
            }
        } catch let error as ConfigError {
            configError = error.description
        } catch {
            configError = "cannot read \(path): \(error.localizedDescription)"
        }
        if let configError { logLine("config: error \(configError); keeping the previous config") }
        onChange?()
        return configError
    }

    /// HotkeyManager drops a binding it cannot parse with only a print, so one fails the whole load instead. Unknown
    /// action names never get here: the schema rejects them.
    public static func bindingError(_ keys: [KeyAction: String]) -> String? {
        let parser = HotkeyManager()
        for (action, key) in keys.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where !key.isEmpty && parser.parseKeyString(key) == nil {
            return "keys.\(action.rawValue): cannot parse \"\(key)\""
        }
        return nil
    }

    private func apply(_ next: AppConfig) {
        if config.struts != next.struts {
            displays.struts = next.struts
            topologyChanged(DisplayObserver.read(revision: world.topology.revision + 1, struts: next.struts))
        }
        config = next
        var focus = FocusIndicatorConfig()
        focus.style = switch next.indicator.style {
        case .none: .none
        case .ring: .ring
        case .raise: .raise
        case .flash: .flash
        }
        focus.color = next.indicator.color
        focus.width = next.indicator.width
        focus.cornerRadius = next.indicator.cornerRadius
        focus.raiseHeight = next.indicator.raiseHeight
        indicator.reloadConfig(focus)
        pointer.modifier = switch next.gestureModifier {
        case .fn: .maskSecondaryFn
        case .ctrl: .maskControl
        case .alt: .maskAlternate
        case .cmd: .maskCommand
        }
        indicatorTile = nil
        let bindings = Dictionary(uniqueKeysWithValues: next.keys.filter { !$0.value.isEmpty }.map { ($0.key.rawValue, $0.value) })
        hotkeys.registerFromConfig(bindings)
        if bindings.isEmpty { hotkeys.stop() } else if hotkeys.eventTap == nil { _ = hotkeys.start() }
        sendGlobal(.configChanged(next.engine))
    }

    /// Pause, which brings off-screen windows back unless a pause already did, let each app thread finish its writes
    /// (at most a second), then call `done` once. The fallback timer runs in the common modes, which include the modal
    /// mode AppKit waits for a terminate reply in.
    public func quit(then done: @escaping @MainActor () -> Void) {
        guard !quitting else { return }
        setPaused(true)
        quitting = true
        hotkeys.stop()
        pointer.stop()
        spaces.stop()
        displays.stop()
        store.flush()
        var finished = false
        let finish = { @MainActor in
            guard !finished else { return }
            finished = true
            done()
        }
        // Queued behind the release writes on each app thread, and ahead of the stop.
        let drained = DispatchGroup()
        for worker in observer.workers.values {
            drained.enter()
            if !worker.app.perform({ drained.leave() }) { drained.leave() }
        }
        observer.stop()
        drained.notify(queue: .main) { MainActor.assumeIsolated { finish() } }
        RunLoop.main.add(Timer(timeInterval: 1, repeats: false) { _ in MainActor.assumeIsolated { finish() } }, forMode: .common)
    }

    // MARK: Focus indicator

    package func indicatorFocus(frontmostPID: Int32?) -> TileID? {
        guard let frontmostPID, let tile = confirmedFocus[frontmostPID],
              pid(of: tile) == frontmostPID else { return nil }
        return tile
    }

    package func changePauseState(_ value: Bool, reconcile: () -> Void) {
        if !value { reconcile() }
        paused = value
    }

    private func updateIndicator(frontmostPID: Int32? = nil) {
        guard config.indicator.style == .ring || config.indicator.style == .flash else { return }
        let frontmostPID = frontmostPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let tile = indicatorFocus(frontmostPID: frontmostPID) else {
            if indicatorTile != nil, indicator.fadeOut() { frameLoop.resume() }
            indicatorTile = nil
            return
        }
        guard !paused, let frame = world.frames[tile]?.frame,
              let area = world.owner(of: tile).flatMap(world.topology.group(id:))?.frame,
              frame.rect.intersection(area).width >= 10 else {
            indicator.hide()
            indicatorTile = nil
            return
        }
        let screen = screenRect(frame, in: world.topology).rect
        if indicator.currentFrame == nil || (indicatorTile != tile && config.indicator.style == .flash) {
            if indicator.snapTo(frame: screen) { frameLoop.resume() }
        } else {
            indicator.trackFrame(screen)
        }
        indicatorTile = tile
    }
}
