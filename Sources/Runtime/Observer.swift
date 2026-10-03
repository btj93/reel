@preconcurrency import ApplicationServices
import AppKit
import Core
import Engine
import Foundation
import Platform

/// What the runtime knows about a window, as plain values that cross threads without an AX element.
public struct WindowFacts: Equatable, Sendable {
    public let id: CGWindowID
    public let pid: Int32
    public let bundleID: String?
    public let title: String
    public let frame: CGRect?
    public let classification: Classification

    public enum Classification: Equatable, Sendable { case tile, float, ignore }

    var observed: ObservedWindow {
        ObservedWindow(id: TileID(id), pid: pid, bundleID: bundleID, title: title, floating: classification == .float,
                       initialFrame: frame.map(AXRect.init))
    }
}

/// What an app thread saw or did.
enum Observation: Sendable {
    case discovered(pid: Int32, [WindowFacts])
    case created(WindowFacts)
    case destroyed(CGWindowID)
    case minimized(CGWindowID)
    case restored(WindowFacts)
    case retitled(WindowFacts)
    case moved(CGWindowID, CGRect)
    case focused(pid: Int32, CGWindowID?, activation: Bool)
    /// `landed` is the frame the app kept, when known: an app may clamp the size we asked for.
    case wrote(TileID, revision: UInt64, frame: CGRect, landed: CGRect?, FrameResult)
}

/// The loop's scope, readable from app threads: an observation is stamped when it happens, so one made before a
/// Space or topology change is dropped by `reduce` however late the main loop reads it.
final class ScopeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var scope: EventScope?

    var current: EventScope? {
        get { lock.withLock { scope } }
        set { lock.withLock { scope = newValue } }
    }
}

/// One app's AX state. `windows` and every AX call live on the app's `AXApp` thread; the main loop only queues work.
final class AppWorker: @unchecked Sendable {
    let app: AXApp
    private let send: @Sendable (Observation, EventScope?) -> Void
    private let clock: ScopeClock
    private var windows: [CGWindowID: AXWindow] = [:]
    /// The size last asked for and the size the app kept. While a write asks for the same size, only the position is set.
    private var sizes: [CGWindowID: (asked: CGSize, kept: CGSize)] = [:]
    private let lock = NSLock()
    private var queuedFrames: [TileID: (revision: UInt64, frame: CGRect)] = [:]
    private var drainQueued = false

    var pid: Int32 { app.pid }

    init(pid: Int32, bundleID: String?, clock: ScopeClock, send: @escaping @Sendable (Observation, EventScope?) -> Void) {
        app = AXApp(pid: pid, bundleIdentifier: bundleID)
        self.send = send
        self.clock = clock
        app.onThreadNotification = { [weak self] name, element in self?.handle(name, element) }
        app.startObserving()
        if !app.perform({ [self] in post(.discovered(pid: pid, getAppWindows(pid: pid).compactMap(register))) }) {
            post(.discovered(pid: pid, []))
        }
    }

    func stop() { app.stopObserving() }

    private func post(_ observation: Observation) { send(observation, clock.current) }

    /// Coalesced per window: a write still queued when the next one arrives is replaced, never run late.
    func write(_ tile: TileID, revision: UInt64, frame: CGRect) {
        lock.lock()
        queuedFrames[tile] = (revision, frame)
        let schedule = !drainQueued
        drainQueued = true
        lock.unlock()
        if schedule { app.perform { [self] in drain() } }
    }

    func cancelWrite(_ tile: TileID) {
        lock.lock()
        queuedFrames.removeValue(forKey: tile)
        lock.unlock()
    }

    func run(_ tile: TileID, _ action: @escaping @Sendable (AXWindow) -> Void) {
        app.perform { [self] in windows[CGWindowID(tile.rawValue)].map(action) }
    }

    /// A closed window can outlive its close in the window server (an app that keeps the object), but its AX element
    /// is dead at once. Asked only for managed windows that left the screen.
    func validate(_ id: CGWindowID) {
        app.perform { [self] in
            guard let window = windows[id], case .failure(.elementInvalid) = window.getPosition() else { return }
            windows.removeValue(forKey: id)
            sizes.removeValue(forKey: id)
            post(.destroyed(id))
        }
    }

    func reportFocus(activation: Bool) {
        app.perform { [self] in post(.focused(pid: pid, app.focusedWindowID(), activation: activation)) }
    }

    private func drain() {
        lock.lock()
        let batch = queuedFrames.sorted { $0.key.rawValue < $1.key.rawValue }
        queuedFrames = [:]
        drainQueued = false
        lock.unlock()
        for (tile, write) in batch {
            let id = CGWindowID(tile.rawValue)
            guard let window = windows[id] else {
                post(.wrote(tile, revision: write.revision, frame: write.frame, landed: nil, .failed))
                continue
            }
            // A scroll keeps the size, and one position write is a third of the AX traffic of a full frame.
            let kept = sizes[id].flatMap { $0.asked == write.frame.size ? $0.kept : nil }
            let result = kept == nil ? window.setFrame(write.frame) : window.setPosition(write.frame.origin)
            switch result {
            case .success:
                let landed = if let kept { CGRect(origin: write.frame.origin, size: kept) } else { try? window.getFrame().get() }
                sizes[id] = (write.frame.size, landed?.size ?? write.frame.size)
                post(.wrote(tile, revision: write.revision, frame: write.frame, landed: landed, .applied))
            case .failure(let error):
                sizes[id] = nil
                post(.wrote(tile, revision: write.revision, frame: write.frame, landed: nil, error.isTimeout ? .timedOut : .failed))
            }
        }
    }

    private func handle(_ name: String, _ element: AXUIElement) {
        switch name {
        case kAXWindowCreatedNotification:
            if let facts = register(element) { post(.created(facts)) }
        case kAXUIElementDestroyedNotification:
            guard let id = windows.first(where: { CFEqual($0.value.element, element) })?.key else { return }
            app.unobserveWindow(element)
            windows.removeValue(forKey: id)
            sizes.removeValue(forKey: id)
            post(.destroyed(id))
        case kAXWindowMiniaturizedNotification:
            if let id = windowID(for: element) { post(.minimized(id)) }
        case kAXWindowDeminiaturizedNotification:
            if let window = windowID(for: element).flatMap({ windows[$0] }) { post(.restored(facts(window))) }
        case kAXMovedNotification, kAXResizedNotification:
            guard let id = windowID(for: element), let window = windows[id], case .success(let frame) = window.getFrame() else { return }
            // Someone else sized the window, so the next write must set the size again, not just the position. Height
            // is the app's, and a width within the ledger's slop is rounding.
            if let size = sizes[id], abs(size.kept.width - frame.width) > EchoLedger.slop { sizes[id] = nil }
            post(.moved(id, frame))
        case kAXTitleChangedNotification:
            if let window = windowID(for: element).flatMap({ windows[$0] }) { post(.retitled(facts(window))) }
        case kAXFocusedWindowChangedNotification:
            post(.focused(pid: pid, windowID(for: element), activation: false))
        default: break
        }
    }

    private func register(_ element: AXUIElement) -> WindowFacts? {
        guard let id = windowID(for: element) else { return nil }
        if let known = windows[id] { return facts(known) }
        let window = AXWindow(element: element, windowID: id, pid: pid)
        windows[id] = window
        app.observeWindow(element)
        return facts(window)
    }

    private func facts(_ window: AXWindow) -> WindowFacts {
        var properties = window.getPropertiesFast()
        properties.windowLayer = windowLayer(for: window.windowID)
        properties.bundleIdentifier = app.bundleIdentifier
        let classification: WindowFacts.Classification = switch classifyWindow(properties) {
        case .tile: .tile
        case .float: .float
        case .ignore: .ignore
        }
        return WindowFacts(id: window.windowID, pid: pid, bundleID: app.bundleIdentifier, title: properties.title ?? "",
                           frame: properties.frame, classification: properties.isMinimized ? .ignore : classification)
    }
}

extension AXCallError {
    var isTimeout: Bool {
        if case .appUnresponsive = self { return true }
        return false
    }
}

/// Turns AX notifications, NSWorkspace notifications and the health check into engine events, each stamped with the
/// epoch and topology revision it was observed under. It keeps the runtime's registry of windows but never touches the
/// world.
@MainActor
public final class Observer {
    public private(set) var known: [CGWindowID: WindowFacts] = [:]
    private(set) var workers: [Int32: AppWorker] = [:]
    let allowedPids: Set<Int32>?
    private let executor: Executor
    private let emit: (Event.Kind, EventScope?) -> Void
    let clock = ScopeClock()
    private let managed: () -> Set<CGWindowID>
    private let log: (String) -> Void
    private var tokens: [NSObjectProtocol] = []
    private var healthTimer: Timer?
    private var awaitingDiscovery = Set<Int32>()
    private var onDiscovered: (() -> Void)?
    /// While paused, the engine hears only removals; the registry still tracks everything for the resume census.
    var paused = false

    public static let healthInterval = 0.5

    init(executor: Executor, allowedPids: Set<Int32>?, managed: @escaping () -> Set<CGWindowID>,
         emit: @escaping (Event.Kind, EventScope?) -> Void, log: @escaping (String) -> Void) {
        self.executor = executor
        self.allowedPids = allowedPids
        self.managed = managed
        self.emit = emit
        self.log = log
    }

    /// Register every running app, then call `discovered` once each has reported its windows or `timeout` passed.
    func start(timeout: Double, discovered: @escaping () -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ body: @escaping @MainActor (NSRunningApplication) -> Void) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { body(app) }
            })
        }
        observe(NSWorkspace.didLaunchApplicationNotification) { [weak self] in self?.register($0) }
        observe(NSWorkspace.didTerminateApplicationNotification) { [weak self] in self?.unregister($0.processIdentifier) }
        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] in
            self?.workers[$0.processIdentifier]?.reportFocus(activation: true)
        }
        onDiscovered = discovered
        for app in NSWorkspace.shared.runningApplications { register(app) }
        awaitingDiscovery = Set(workers.keys)
        Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishDiscovery() }
        }
        if awaitingDiscovery.isEmpty { finishDiscovery() }
    }

    func stop() {
        tokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        tokens = []
        healthTimer?.invalidate()
        workers.values.forEach { $0.stop() }
    }

    /// Fresh from the window server, never cached: the managed-candidate windows on screen right now.
    func census(_ onScreen: [CGWindowInfo] = getAllWindowInfo()) -> [ObservedWindow] {
        let onScreen = Set(onScreen.map(\.windowID))
        return known.values.filter { $0.classification != .ignore && onScreen.contains($0.id) }
            .sorted { $0.id < $1.id }.map(\.observed)
    }

    /// Removals for windows that died without a notification, additions for on-screen windows the engine lacks.
    func healthCheck() {
        let managed = managed()
        guard let alive = existingWindows(managed.union(known.keys)) else { return log("observer: window list unavailable, health check skipped") }
        for id in known.keys where !alive.contains(id) { forget(id) }
        for id in managed.sorted() where !alive.contains(id) { emit(.windowRemoved(TileID(id)), nil) }
        let onScreen = getAllWindowInfo()
        let visible = Set(onScreen.map(\.windowID))
        for id in managed.sorted() where alive.contains(id) && !visible.contains(id) {
            known[id].flatMap { workers[$0.pid] }?.validate(id)
        }
        guard !paused else { return }
        // An app can turn regular after its launch notification; its first on-screen window registers it.
        for pid in Set(onScreen.filter { $0.layer == 0 }.map(\.ownerPID)) where workers[pid] == nil {
            NSRunningApplication(processIdentifier: pid).map(register)
        }
        for window in census(onScreen) where !managed.contains(window.id.rawValue) { emit(.windowAdded(window), nil) }
    }

    private func register(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != getpid(), workers[pid] == nil,
              allowedPids.map({ $0.contains(pid) }) ?? true else { return }
        workers[pid] = AppWorker(pid: pid, bundleID: app.bundleIdentifier, clock: clock) { observation, stamp in
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.receive(observation, stamp: stamp) } }
        }
    }

    private func unregister(_ pid: Int32) {
        guard let worker = workers.removeValue(forKey: pid) else { return }
        worker.stop()
        let gone = known.values.filter { $0.pid == pid }.map(\.id)
        let managed = managed()
        for id in gone.sorted() {
            forget(id)
            if managed.contains(id) { emit(.windowRemoved(TileID(id)), nil) }
        }
        log("observer: app exited pid=\(pid) windows=\(gone.count)")
    }

    private func forget(_ id: CGWindowID) {
        known.removeValue(forKey: id)
        executor.forget(TileID(id))
    }

    private func finishDiscovery() {
        guard let done = onDiscovered else { return }
        onDiscovered = nil
        if !awaitingDiscovery.isEmpty { log("observer: discovery timed out for pids \(awaitingDiscovery.sorted())") }
        done()
        // Only after the first census: until then the group has no Space and would drop every addition.
        healthTimer = Timer.scheduledTimer(withTimeInterval: Self.healthInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.healthCheck() }
        }
    }

    private func learn(_ facts: WindowFacts) {
        if facts.classification == .ignore { known.removeValue(forKey: facts.id) } else { known[facts.id] = facts }
    }

    /// Facts that hold whatever the epoch (a window died, a write finished) go out under the current scope; what an
    /// app saw (a new window, a move, focus) keeps the scope it was observed under.
    func receive(_ observation: Observation, stamp: EventScope?) {
        switch observation {
        case .discovered(let pid, let windows):
            guard workers[pid] != nil else { return }
            windows.forEach(learn)
            awaitingDiscovery.remove(pid)
            if awaitingDiscovery.isEmpty { finishDiscovery() }
        case .created(let facts):
            learn(facts)
            // Only a window on the current Space joins; one that is not on screen yet joins at the next health check.
            if !paused, facts.classification != .ignore, isWindowOnScreen(facts.id) { emit(.windowAdded(facts.observed), stamp) }
        case .destroyed(let id):
            let wasManaged = managed().contains(id)
            forget(id)
            if wasManaged { emit(.windowRemoved(TileID(id)), nil) }
        case .minimized(let id):
            known.removeValue(forKey: id)
            if managed().contains(id) { emit(.windowRemoved(TileID(id)), nil) }
        case .restored(let facts):
            learn(facts)
            if !paused, facts.classification != .ignore { emit(.windowAdded(facts.observed), stamp) }
        case .retitled(let facts):
            learn(facts)
            if !paused, facts.classification != .ignore { emit(.windowChanged(facts.observed), nil) }
        case .moved(let id, let frame):
            guard !paused, managed().contains(id), executor.isForeign(TileID(id), frame: frame) else { return }
            emit(.windowMoved(TileID(id), AXRect(frame)), stamp)
        case .focused(let pid, let id, let activation):
            guard !paused else { return }
            emit(.focus(FocusIntent(tile: id.map(TileID.init), pid: pid, source: activation ? .appActivation : .axFocus)), stamp)
        case .wrote(let tile, let revision, let frame, let landed, let result):
            executor.wrote(tile, revision: revision, frame: frame, landed: landed, result: result)
            emit(.frameCompleted(tile: tile, revision: revision, result: result), nil)
        }
    }
}

/// Which of `ids` still exist on any Space, or nil when the window server gave no answer: a failed read must never
/// look like every window closed. A window-server query, so a hung app cannot stall it.
func existingWindows(_ ids: Set<CGWindowID>) -> Set<CGWindowID>? {
    guard !ids.isEmpty else { return [] }
    var values = ids.sorted().map { UnsafeRawPointer(bitPattern: UInt($0)) }
    guard let array = CFArrayCreate(nil, &values, values.count, nil),
          let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else { return nil }
    return Set(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
}
