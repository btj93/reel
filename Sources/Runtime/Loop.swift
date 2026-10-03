import AppKit
import Config
import Core
import Engine
import Foundation
import Platform

public func log(_ line: String) {
    print(line)
    fflush(stdout)
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
        executor = Executor(worker: { [unowned self] in observer.workers[$0] }, log: log)
        observer = Observer(executor: executor, allowedPids: allowedPids,
                            managed: { [unowned self] in Set(world.groups[group]?.windows.keys.map(\.rawValue) ?? []) },
                            emit: { [unowned self] in send($0) }, log: log)
        scheduler = Scheduler(clock: TimeUtil.now, isCurrent: { [unowned self] in world.scope(for: $0.group) == $0 },
                              deliver: { [unowned self] in run($0) }, log: log)
        frameLoop.onTick = { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        hotkeys.onAction = { [weak self] action in MainActor.assumeIsolated { self?.hotkey(action) } }
    }

    public func start() {
        log("loop: group=\(group) area=\(world.topology.groups.first?.frame ?? .zero) managedPids=\(allowedPids.map { $0.sorted().description } ?? "all")")
        reloadConfig()
        frameLoop.start()
        screenToken = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        observer.start(timeout: 1.5) { [weak self] in self?.census(group: self?.group ?? 0) }
    }

    // MARK: Events

    /// Stamp `kind` with the group's current scope and reduce it.
    public func send(_ kind: Event.Kind) {
        guard !quitting, let scope = world.scope(for: group) else { return }
        reduceAndRun(Event(scope: scope, kind: kind))
    }

    private func reduceAndRun(_ event: Event) {
        let effects = reduce(&world, event, now: max(TimeUtil.now(), world.time))
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
                if !persistLogged { log("loop: persist skipped, the snapshot store arrives with R4") }
                persistLogged = true
            case .requestCensus(let group, let after):
                guard let owner = world.scope(for: group) else { continue }
                scheduler.schedule(.census(group: group), deadline: world.time + after, owner: owner, job: .census(group: group))
            case .schedule(let token, let deadline, let event):
                scheduler.schedule(.engine(token), deadline: deadline, owner: event.scope, job: .event(event))
            case .cancel(let token): scheduler.cancel(.engine(token))
            case .log(let line): log("engine: \(line)")
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
            log("space: fingerprint fallback")
        }
        let epoch = (world.groups[group]?.epoch ?? 0) + 1
        log("loop: census key=\(key.debugDescription) windows=\(windows.count)")
        send(.spaceChanged(key: key, epoch: epoch, windows: windows))
    }

    private func tick() {
        send(.tick)
        indicator.tick(time: TimeUtil.now())
        if !world.needsTicks && !indicator.isAnimating { frameLoop.pause() }
    }

    private func screensChanged() {
        let next = Self.readTopology(revision: world.topology.revision + 1)
        guard let id = next.groups.first?.id, next.groups.first?.frame != world.topology.groups.first?.frame || id != group else { return }
        log("loop: topology rev=\(next.revision) group=\(id) area=\(next.groups.first?.frame ?? .zero)")
        send(.topologyChanged(next))
        group = id
        send(.command(.recover, .ipc))
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

    public func setPaused(_ value: Bool) {
        guard value != paused else { return }
        paused = value
        observer.paused = value
        log("loop: paused=\(value)")
        if value {
            indicator.hide()
            indicatorTile = nil
        } else {
            // Windows opened during the pause join, and every frame is written again over whatever moved meanwhile.
            observer.healthCheck()
            send(.command(.recover, .ipc))
        }
        onChange?()
    }

    /// Load the config file. On any error the previous config stays active and the error is kept for the menu bar.
    @discardableResult
    public func reloadConfig() -> String? {
        let path = paths.configFile
        do {
            let text = FileManager.default.fileExists(atPath: path) ? try String(contentsOfFile: path, encoding: .utf8) : ""
            apply(try AppConfig.parse(text))
            configError = nil
            log("config: loaded \(path)")
        } catch let error as ConfigError {
            configError = error.description
        } catch {
            configError = "cannot read \(path): \(error.localizedDescription)"
        }
        if let configError { log("config: error \(configError); keeping the previous config") }
        onChange?()
        return configError
    }

    private func apply(_ next: AppConfig) {
        config = next
        var focus = FocusIndicatorConfig()
        focus.style = FocusIndicatorConfig.Style(rawValue: next.indicator.style.rawValue) ?? .ring
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

    /// Bring off-screen windows back, let each app thread finish its writes (at most a second), then exit.
    public func quit() {
        guard !quitting else { return }
        paused = false
        send(.command(.release, .ipc))
        quitting = true
        observer.stop()
        hotkeys.stop()
        let drained = DispatchGroup()
        for worker in observer.workers.values {
            drained.enter()
            worker.app.perform { drained.leave() }
        }
        drained.notify(queue: .main) { exit(0) }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in exit(0) }
    }

    // MARK: Focus indicator

    private func updateIndicator() {
        guard config.indicator.style == .ring || config.indicator.style == .flash else { return }
        guard !paused, let tile = focusedTile, let frame = world.frames[tile]?.frame.rect,
              let area = world.topology.groups.first(where: { $0.id == group })?.frame,
              frame.intersection(area).width >= 10 else {
            indicator.hide()
            indicatorTile = nil
            return
        }
        let screen = CGRect(x: frame.minX, y: world.topology.primaryScreenHeight - frame.maxY, width: frame.width, height: frame.height)
        if indicator.currentFrame == nil || (indicatorTile != tile && config.indicator.style == .flash) {
            if indicator.snapTo(frame: screen) { frameLoop.resume() }
        } else {
            indicator.trackFrame(screen)
        }
        indicatorTile = tile
    }
}
