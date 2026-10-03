import AppKit
import Config
import Core
import Engine
import Foundation
import Platform

@MainActor private var flushQueued = false

/// One flush per main run-loop turn, so a scroll that logs every write and echo costs one syscall per turn.
@MainActor
public func logLine(_ line: String) {
    print(line)
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
    public private(set) var group: UInt32
    public private(set) var config = AppConfig()
    public private(set) var configError: String?
    public private(set) var paused = false
    public let paths = Paths()
    public let allowedPids = managedPidAllowlist()
    public var onChange: (() -> Void)?

    private(set) var executor: Executor!
    private(set) var observer: Observer!
    private(set) var scheduler: Scheduler!
    private let frameLoop = FrameLoop()
    private let indicator = FocusIndicator()
    private let hotkeys = HotkeyManager()
    private var replies: [UInt64: ReplyPayload] = [:]
    private var lastRequest: UInt64 = 0
    private var indicatorTile: TileID?
    private var persistLogged = false
    private var quitting = false
    private var screenToken: NSObjectProtocol?

    public init() {
        let topology = Self.readTopology(revision: 1)
        world = World(topology: topology)
        group = topology.groups.first?.id ?? 0
        executor = Executor(worker: { [unowned self] in observer.workers[$0] }, log: logLine)
        observer = Observer(executor: executor, allowedPids: allowedPids,
                            managed: { [unowned self] in Set(world.groups[group]?.windows.keys.map(\.rawValue) ?? []) },
                            paused: { [unowned self] in paused },
                            emit: { [unowned self] in send($0, stamp: $1) }, log: logLine)
        scheduler = Scheduler(clock: TimeUtil.now, isCurrent: { [unowned self] in world.scope(for: $0.group) == $0 },
                              deliver: { [unowned self] in run($0) }, log: logLine)
        frameLoop.onTick = { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        hotkeys.onAction = { [weak self] action in MainActor.assumeIsolated { self?.hotkey(action) } }
    }

    public func start() {
        logLine("loop: group=\(group) area=\(world.topology.groups.first?.frame ?? .zero) managedPids=\(allowedPids.map { $0.sorted().description } ?? "all")")
        observer.clock.current = world.scope(for: group)
        // The defaults go live first, so a file the schema rejects leaves hotkeys working and the error in the menu bar.
        apply(config)
        reloadConfig()
        frameLoop.start()
        screenToken = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        observer.start(timeout: 1.5) { [weak self] in self?.census(group: self?.group ?? 0) }
    }

    // MARK: Events

    /// Reduce `kind` under `stamp`, the scope it was observed under, or else the group's current scope.
    public func send(_ kind: Event.Kind, stamp: EventScope? = nil) {
        guard !quitting, let scope = stamp ?? world.scope(for: group) else { return }
        reduceAndRun(Event(scope: scope, kind: kind))
    }

    private func reduceAndRun(_ event: Event) {
        let effects = reduce(&world, event, now: max(TimeUtil.now(), world.time))
        observer.clock.current = world.scope(for: group)
        run(effects)
        if world.needsTicks || indicator.isAnimating { frameLoop.resume() }
        updateIndicator()
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
            case .focus(let tile, _): if !paused, let pid = pid(of: tile) { executor.focus(tile, pid: pid) }
            case .raise(let tile): if !paused, let pid = pid(of: tile) { executor.raise(tile, pid: pid) }
            case .close(let tile): if let pid = pid(of: tile) { executor.close(tile, pid: pid) }
            case .reply(let id, let payload): replies[id] = payload
            case .overlay: break
            case .persist:
                if !persistLogged { logLine("loop: persist skipped, the snapshot store arrives with R4") }
                persistLogged = true
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

    /// A fresh on-screen read, sent as a new `spaceChanged`; a deferred census is never answered from a cache.
    private func census(group: UInt32) {
        let windows = observer.census()
        let key: SpaceKey
        if let space = SpaceIdentity.currentSpace(displayID: group) {
            key = space.key
        } else {
            key = .fingerprint(Set(windows.map(\.id.rawValue)))
            logLine("space: fingerprint fallback")
        }
        let epoch = (world.groups[group]?.epoch ?? 0) + 1
        logLine("loop: census key=\(key.debugDescription) windows=\(windows.count)")
        send(.spaceChanged(key: key, epoch: epoch, windows: windows))
    }

    private func tick() {
        send(.tick)
        indicator.tick(time: TimeUtil.now())
        if !world.needsTicks && !indicator.isAnimating { frameLoop.pause() }
    }

    /// A new working area or primary display. The census adopts windows into a group that just appeared (the first
    /// display after a headless start), and recover rewrites every frame for the new area.
    private func screensChanged() {
        let next = Self.readTopology(revision: world.topology.revision + 1)
        let id = next.groups.first?.id ?? 0
        guard next.groups.first?.frame != world.topology.groups.first?.frame || id != group else { return }
        logLine("loop: topology rev=\(next.revision) group=\(id) area=\(next.groups.first?.frame ?? .zero)")
        let scope = world.scope(for: group) ?? EventScope(topologyRevision: world.topology.revision, group: group, spaceEpoch: 0)
        reduceAndRun(Event(scope: scope, kind: .topologyChanged(next)))
        group = id
        // A config loaded while no display existed was dropped for want of a scope.
        send(.configChanged(config.engine))
        census(group: id)
        recover()
    }

    /// The primary display only; multi-display grouping arrives with R5.
    static func readTopology(revision: UInt64) -> Topology {
        let displays = DisplayManager()
        displays.refresh()
        guard let main = displays.displays[CGMainDisplayID()] ?? displays.mainDisplay else {
            return Topology(revision: revision, groups: [], primaryScreenHeight: 0)
        }
        let area = main.workingArea(primaryScreenHeight: displays.primaryScreenHeight)
        return Topology(revision: revision, groups: [DisplayGroup(id: main.displayID, displays: [main.displayID], frame: area)],
                        primaryScreenHeight: displays.primaryScreenHeight)
    }

    // MARK: Commands

    public func pid(of tile: TileID) -> Int32? { world.groups[group]?.windows[tile]?.pid }

    /// The window a toggle or close acts on: the focus decision, else the active column's tile.
    public var focusedTile: TileID? {
        guard let state = world.groups[group] else { return nil }
        return state.focus.decision?.tile ?? state.strip.activeColumn?.activeTile
    }

    /// Every frame written again in full, over whatever moved while nothing was listening.
    @discardableResult
    public func recover() -> CommandOutcome {
        observer.workers.values.forEach { $0.forgetSizes() }
        return request(.recover)
    }

    /// Run a command as an IPC request and return the engine's answer.
    public func request(_ command: Command) -> CommandOutcome {
        lastRequest += 1
        let id = lastRequest
        send(.ipc(id: id, command: command))
        guard case .command(let outcome)? = replies.removeValue(forKey: id) else { return .refused("no display") }
        return outcome
    }

    private func hotkey(_ action: HotkeyAction) {
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
        case .focusUp, .focusDown: nil
        }
        if let command { send(.command(command, .keyboard)) }
    }

    /// Pausing hands every window back as quitting does, so none waits out the pause as an off-screen sliver.
    public func setPaused(_ value: Bool) {
        guard value != paused else { return }
        if value { send(.command(.release, .ipc)) }
        paused = value
        logLine("loop: paused=\(value)")
        if value {
            indicator.hide()
            indicatorTile = nil
        } else {
            // Windows opened during the pause join, and every frame is written again over whatever moved meanwhile.
            observer.healthCheck()
            recover()
            // Focus reports were dropped while paused; read the real focus again so commands act on it.
            NSWorkspace.shared.frontmostApplication.flatMap { observer.workers[$0.processIdentifier] }?.reportFocus(activation: false)
        }
        onChange?()
    }

    /// Load the config file. On any error the previous config stays active and the error is kept for the menu bar.
    @discardableResult
    public func reloadConfig() -> String? {
        let path = paths.configFile
        do {
            let text = FileManager.default.fileExists(atPath: path) ? try String(contentsOfFile: path, encoding: .utf8) : ""
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
        indicatorTile = nil
        let bindings = Dictionary(uniqueKeysWithValues: next.keys.filter { !$0.value.isEmpty }.map { ($0.key.rawValue, $0.value) })
        hotkeys.registerFromConfig(bindings)
        if bindings.isEmpty { hotkeys.stop() } else if hotkeys.eventTap == nil { _ = hotkeys.start() }
        send(.configChanged(next.engine))
    }

    /// Pause, which brings off-screen windows back unless a pause already did, let each app thread finish its writes
    /// (at most a second), then call `done` once. The fallback timer runs in the common modes, which include the modal
    /// mode AppKit waits for a terminate reply in.
    public func quit(then done: @escaping @MainActor () -> Void) {
        guard !quitting else { return }
        setPaused(true)
        quitting = true
        hotkeys.stop()
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

    private func updateIndicator() {
        guard config.indicator.style == .ring || config.indicator.style == .flash else { return }
        guard !paused, let tile = focusedTile, let frame = world.frames[tile]?.frame,
              let area = world.topology.groups.first(where: { $0.id == group })?.frame,
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
