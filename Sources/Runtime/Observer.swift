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
    public let classification: WindowClassification

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
    /// `space` is the Space the focus was observed on, read where it happened; nil without SkyLight.
    case focused(pid: Int32, CGWindowID?, activation: Bool, space: SpaceKey?)
    /// `landed` is the frame the app kept, when known: an app may clamp the size we asked for.
    /// `scope` is the one the write was made for, so a completion from before a topology change is dropped as stale.
    case wrote(TileID, revision: UInt64, frame: CGRect, landed: CGRect?, FrameResult, scope: EventScope)
}

/// The loop's scope, readable from app threads: an observation is stamped when it happens, so one made before a
/// Space or topology change is dropped by `reduce` however late the main loop reads it.
final class ScopeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var scope: Stamp?

    var current: Stamp? {
        get { lock.withLock { scope } }
        set { lock.withLock { scope = newValue } }
    }
}

/// Scroll writes keep the last size. Settled writes retry a refused size until three identical read-backs.
/// Lives on one app thread.
public struct SizeCache {
    private struct Size {
        let asked: CGSize
        let kept: CGSize
        let refusals: Int
    }
    private var sizes: [CGWindowID: Size] = [:]

    public init() {}

    /// Write `frame` and return the result with the frame the app kept, when known. Only the read-back's size is
    /// taken: an app clamps sizes, and a different origin is more likely the user dragging mid-write.
    public mutating func write(_ frame: CGRect, to window: AXWindow, animating: Bool = false) -> (result: FrameResult, landed: CGRect?) {
        let id = window.windowID
        let previous = sizes[id].flatMap { $0.asked == frame.size ? $0 : nil }
        let retry = previous.map { !animating && !Self.matches($0.kept, frame.size) && $0.refusals < 3 } ?? false
        let kept = retry ? nil : previous?.kept
        switch kept == nil ? window.setFrame(frame) : window.setPosition(frame.origin) {
        case .success:
            let landed = if let kept { CGRect(origin: frame.origin, size: kept) } else {
                (try? window.getFrame().get()).map { CGRect(origin: frame.origin, size: $0.size) }
            }
            if kept == nil {
                let size = landed?.size ?? frame.size
                let refusals = Self.matches(size, frame.size) ? 0 :
                    (previous.map { Self.matches($0.kept, size) ? $0.refusals : 0 } ?? 0) + 1
                sizes[id] = Size(asked: frame.size, kept: size, refusals: refusals)
            }
            return (.applied, landed)
        case .failure(let error):
            sizes[id] = nil
            return (error.isTimeout ? .timedOut : .failed, nil)
        }
    }

    /// Someone else sized the window, so the next write must set the size again, not just the position. A size within
    /// the ledger's slop of the one the app kept is rounding.
    public mutating func observed(_ id: CGWindowID, frame: CGRect) {
        guard let kept = sizes[id]?.kept else { return }
        if abs(kept.width - frame.width) > EchoLedger.slop || abs(kept.height - frame.height) > EchoLedger.slop { sizes[id] = nil }
    }

    private static func matches(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= EchoLedger.slop && abs(lhs.height - rhs.height) <= EchoLedger.slop
    }

    public mutating func forget(_ id: CGWindowID) { sizes[id] = nil }

    public mutating func forgetAll() { sizes = [:] }
}

/// One app's AX state. `windows` and every AX call live on the app's `AXApp` thread; the main loop only queues work.
final class AppWorker: @unchecked Sendable {
    let app: AXApp
    private let send: @Sendable (Observation, Stamp?) -> Void
    private let clock: ScopeClock
    private var windows: [CGWindowID: AXWindow] = [:]
    private var sizes = SizeCache()
    private let lock = NSLock()
    private var queuedFrames: [TileID: (revision: UInt64, frame: CGRect, scope: EventScope, animating: Bool)] = [:]
    private var drainQueued = false
    private var forgetSizesQueued = false
    private var rediscoveryQueued = false

    var pid: Int32 { app.pid }

    init(pid: Int32, bundleID: String?, clock: ScopeClock, send: @escaping @Sendable (Observation, Stamp?) -> Void) {
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

    /// Look again for windows the app did not list at registration (it was busy), report `ids` it already holds afresh
    /// (one ignored once may tile now), and retry an app-level subscription that failed. At most one request waits on
    /// the app thread, so a hung app does not pile them up.
    func rediscover(_ ids: [CGWindowID]) {
        let first = lock.withLock { () -> Bool in
            defer { rediscoveryQueued = true }
            return !rediscoveryQueued
        }
        guard first else { return }
        let queued = app.perform { [self] in
            lock.withLock { rediscoveryQueued = false }
            app.retryAppSubscriptions()
            let held = ids.compactMap { windows[$0].map(facts) }
            let fresh = getAppWindows(pid: pid).filter { windowID(for: $0).map { windows[$0] == nil } ?? false }
            post(.discovered(pid: pid, held + fresh.compactMap(register)))
        }
        if !queued { lock.withLock { rediscoveryQueued = false } }
    }

    /// The next drain writes every size in full: nothing can tell the cache what changed while no one was listening.
    /// A flag read by the drain, not queued work, so a drain already queued with the recover's frames still sees it.
    func forgetSizes() {
        lock.withLock { forgetSizesQueued = true }
    }

    /// Coalesced per window: a write still queued when the next one arrives is replaced, never run late.
    func write(_ tile: TileID, revision: UInt64, frame: CGRect, scope: EventScope, animating: Bool) {
        lock.lock()
        queuedFrames[tile] = (revision, frame, scope, animating)
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
            sizes.forget(id)
            post(.destroyed(id))
        }
    }

    func reportFocus(activation: Bool, space: SpaceKey?) {
        app.perform { [self] in
            let stamp = clock.current
            let id = app.focusedWindowID()
            let frame = activation ? nil : id.flatMap { windows[$0] }.flatMap { try? $0.getFrame().get() }
            send(.focused(pid: pid, id, activation: activation, space: activation ? space : SpaceObserver.observedSpace(at: frame)), stamp)
        }
    }

    private func drain() {
        lock.lock()
        let batch = queuedFrames.sorted { $0.key.rawValue < $1.key.rawValue }
        queuedFrames = [:]
        drainQueued = false
        let forget = forgetSizesQueued
        forgetSizesQueued = false
        lock.unlock()
        if forget { sizes.forgetAll() }
        for (tile, write) in batch {
            let id = CGWindowID(tile.rawValue)
            guard let window = windows[id] else {
                post(.wrote(tile, revision: write.revision, frame: write.frame, landed: nil, .failed, scope: write.scope))
                continue
            }
            let (result, landed) = sizes.write(write.frame, to: window, animating: write.animating)
            post(.wrote(tile, revision: write.revision, frame: write.frame, landed: landed, result, scope: write.scope))
        }
    }

    /// Stamped before any AX read, so an observation that straddles a Space change carries the scope it began under.
    private func handle(_ name: String, _ element: AXUIElement) {
        let stamp = clock.current
        func post(_ observation: Observation) { send(observation, stamp) }
        switch name {
        case kAXWindowCreatedNotification:
            if let facts = register(element) { post(.created(facts)) }
        case kAXUIElementDestroyedNotification:
            guard let id = windows.first(where: { CFEqual($0.value.element, element) })?.key else { return }
            app.unobserveWindow(element)
            windows.removeValue(forKey: id)
            sizes.forget(id)
            post(.destroyed(id))
        case kAXWindowMiniaturizedNotification:
            if let id = windowID(for: element) { post(.minimized(id)) }
        case kAXWindowDeminiaturizedNotification:
            if let window = windowID(for: element).flatMap({ windows[$0] }) { post(.restored(facts(window))) }
        case kAXMovedNotification, kAXResizedNotification:
            guard let id = windowID(for: element), let window = windows[id], case .success(let frame) = window.getFrame() else { return }
            sizes.observed(id, frame: frame)
            post(.moved(id, frame))
        case kAXTitleChangedNotification:
            if let window = windowID(for: element).flatMap({ windows[$0] }) { post(.retitled(facts(window))) }
        case kAXFocusedWindowChangedNotification:
            let id = windowID(for: element)
            let frame = id.flatMap { windows[$0] }.flatMap { try? $0.getFrame().get() }
            post(.focused(pid: pid, id, activation: false, space: SpaceObserver.observedSpace(at: frame)))
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
        let classification = classifyWindow(properties)
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
    /// Windows to manage; the ones their app classified `.ignore` are in `ignored` instead.
    public private(set) var known: [CGWindowID: WindowFacts] = [:]
    private(set) var workers: [Int32: AppWorker] = [:]
    let allowedPids: Set<Int32>?
    private let executor: Executor
    private let emit: (Event.Kind, Stamp?) -> Void
    let clock = ScopeClock()
    private let managed: () -> Set<CGWindowID>
    /// Windows the engine keeps off the current strip: hidden ones and every saved strip's, so a close there is heard.
    private let elsewhere: () -> Set<CGWindowID>
    private let log: (String) -> Void
    private var tokens: [NSObjectProtocol] = []
    private var healthTimer: Timer?
    private var awaitingDiscovery = Set<Int32>()
    private var onDiscovered: (() -> Void)?
    /// On-screen windows their app classified `.ignore`, so the health check does not ask about them every pass.
    private var ignored = Set<CGWindowID>()
    /// While paused, the engine hears only removals and retitles; the registry still tracks everything for the resume census.
    private let paused: () -> Bool

    public static let healthInterval = 0.5

    init(executor: Executor, allowedPids: Set<Int32>?, managed: @escaping () -> Set<CGWindowID>,
         elsewhere: @escaping () -> Set<CGWindowID>, paused: @escaping () -> Bool,
         emit: @escaping (Event.Kind, Stamp?) -> Void, log: @escaping (String) -> Void) {
        self.executor = executor
        self.allowedPids = allowedPids
        self.managed = managed
        self.elsewhere = elsewhere
        self.paused = paused
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
        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] in self?.activated($0.processIdentifier) }
        observe(NSWorkspace.didHideApplicationNotification) { [weak self] in self?.hide($0.processIdentifier) }
        observe(NSWorkspace.didUnhideApplicationNotification) { [weak self] _ in self?.healthCheck() }
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
        return known.values.filter { onScreen.contains($0.id) }
            .sorted { $0.id < $1.id }.map(\.observed)
    }

    /// Removals for windows that died without a notification, additions for on-screen windows the engine lacks.
    func healthCheck() {
        let managed = managed(), tracked = managed.union(elsewhere())
        guard let alive = existingWindows(tracked.union(known.keys)) else { return log("observer: window list unavailable, health check skipped") }
        for id in known.keys where !alive.contains(id) { forget(id) }
        for id in tracked.sorted() where !alive.contains(id) { emit(.windowRemoved(TileID(id)), nil) }
        let onScreen = getAllWindowInfo()
        let visible = Set(onScreen.map(\.windowID))
        // A managed window that is alive but on no Space at all was ordered out (some apps close to the Dock that
        // way): it leaves the strip as a hidden window does, and comes back to its place if it is shown again. One on
        // another Space is left alone. Without SkyLight the two cannot be told apart, so both stay.
        var orderedOut: [TileID] = []
        for id in managed.sorted() where alive.contains(id) && !visible.contains(id) {
            known[id].flatMap { workers[$0.pid] }?.validate(id)
            if SpaceIdentity.spaces(ofWindow: id)?.isEmpty == true { orderedOut.append(TileID(id)) }
        }
        if !orderedOut.isEmpty {
            log("observer: ordered out \(orderedOut.map(\.rawValue))")
            emit(.windowsHidden(orderedOut), nil)
        }
        ignored.formIntersection(visible)
        guard !paused() else { return }
        let unknown = onScreen.filter { $0.layer == 0 && known[$0.windowID] == nil && !ignored.contains($0.windowID) }
        for (pid, windows) in Dictionary(grouping: unknown, by: \.ownerPID).sorted(by: { $0.key < $1.key }) {
            // An app can turn regular after its launch notification; its first on-screen window registers it. One that
            // was busy when it registered lists its windows now.
            // ponytail: a window AX never lists costs its app one kAXWindows read per pass; remember misses if perf shows it.
            if let worker = workers[pid] { worker.rediscover(windows.map(\.windowID)) }
            else { NSRunningApplication(processIdentifier: pid).map(register) }
        }
        for window in census(onScreen) where !managed.contains(window.id.rawValue) { emit(.windowAdded(window), nil) }
    }

    /// A Dock click or Cmd+Tab. The app is named at once, with the Space it was activated on, so a Space change that
    /// follows cannot commit before `reduce` hears of it; the app thread then names the window.
    private func activated(_ pid: Int32) {
        guard let worker = workers[pid] else { return }
        let space = SpaceObserver.observedSpace()
        if !paused(), let stamp = clock.current {
            emit(.focus(FocusIntent(tile: nil, pid: pid, source: .appActivation, observedSpace: space)), stamp)
        }
        worker.reportFocus(activation: true, space: space)
    }

    /// A hidden app's windows leave the strip, or the saved strip of the Space they are on, but stay known, so the
    /// health check adds them back, to the place they left, once they are on screen again.
    private func hide(_ pid: Int32) {
        let tracked = managed().union(elsewhere())
        let hidden = known.values.filter { $0.pid == pid && tracked.contains($0.id) }.map(\.id).sorted().map(TileID.init)
        if !hidden.isEmpty { emit(.windowsHidden(hidden), nil) }
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
        let tracked = managed().union(elsewhere())
        for id in gone.sorted() {
            forget(id)
            if tracked.contains(id) { emit(.windowRemoved(TileID(id)), nil) }
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
        if facts.classification == .ignore {
            known.removeValue(forKey: facts.id)
            ignored.insert(facts.id)
        } else {
            known[facts.id] = facts
            ignored.remove(facts.id)
        }
    }

    /// Facts that hold whatever the epoch (a window died) go out under the current scope, a finished write under the
    /// scope it was written for; what an app saw (a new window, a move, focus) keeps the scope it was observed under,
    /// and is dropped when it was seen with no scope at all (the health check and the next census pick the window up).
    func receive(_ observation: Observation, stamp: Stamp?) {
        func emitObserved(_ kind: Event.Kind) { if let stamp { emit(kind, stamp) } }
        switch observation {
        case .discovered(let pid, let windows):
            guard workers[pid] != nil else { return }
            windows.forEach(learn)
            awaitingDiscovery.remove(pid)
            if awaitingDiscovery.isEmpty { finishDiscovery() }
        case .created(let facts):
            learn(facts)
            // Only a window on the current Space joins; one that is not on screen yet joins at the next health check.
            if !paused(), facts.classification != .ignore, isWindowOnScreen(facts.id) { emitObserved(.windowAdded(facts.observed)) }
        case .destroyed(let id):
            let tracked = managed().contains(id) || elsewhere().contains(id)
            forget(id)
            if tracked { emit(.windowRemoved(TileID(id)), nil) }
        case .minimized(let id):
            known.removeValue(forKey: id)
            if managed().contains(id) { emit(.windowsHidden([TileID(id)]), nil) }
        case .restored(let facts):
            learn(facts)
            if !paused(), facts.classification != .ignore { emitObserved(.windowAdded(facts.observed)) }
        case .retitled(let facts):
            learn(facts)
            // Even while paused, so a late title is not lost; the engine's writes are held back until resume.
            if facts.classification != .ignore { emit(.windowChanged(facts.observed), nil) }
        case .moved(let id, let frame):
            guard !paused(), stamp != nil, managed().contains(id), executor.isForeign(TileID(id), frame: frame) else { return }
            emitObserved(.windowMoved(TileID(id), AXRect(frame)))
        case .focused(let pid, let id, let activation, let space):
            guard !paused() else { return }
            emitObserved(.focus(FocusIntent(tile: id.map(TileID.init), pid: pid, source: activation ? .appActivation : .axFocus,
                                            observedSpace: space)))
        case .wrote(let tile, let revision, let frame, let landed, let result, let scope):
            executor.wrote(tile, revision: revision, frame: frame, landed: landed, result: result)
            emit(.frameCompleted(tile: tile, revision: revision, result: result), Stamp(scope))
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
