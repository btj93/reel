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

    var observed: ObservedWindow { observed(at: frame) }

    func observed(at frame: CGRect?) -> ObservedWindow {
        ObservedWindow(id: TileID(id), pid: pid, bundleID: bundleID, title: title, floating: classification == .float,
                       initialFrame: frame.map(AXRect.init))
    }
}

/// What an app thread saw or did.
package struct ActivationReport: Sendable {
    let generation: UInt64
    let focusGeneration: UInt64
    let stamp: Stamp?
}

package enum Observation: Sendable {
    case discovered(pid: Int32, [WindowFacts])
    case created(WindowFacts)
    case destroyed(CGWindowID)
    case minimized(CGWindowID)
    case restored(WindowFacts)
    case retitled(WindowFacts)
    case reclassified(WindowFacts, activation: ActivationReport?)
    case moved(CGWindowID, CGRect)
    /// `space` is the Space the focus was observed on, read where it happened; nil without SkyLight.
    case focused(pid: Int32, CGWindowID?, activation: ActivationReport?, space: SpaceKey?)
    /// `landed` is the frame the app kept, when known: an app may clamp the size we asked for.
    /// `scope` is the one the write was made for, so a completion from before a topology change is dropped as stale.
    case wrote(TileID, revision: UInt64, frame: CGRect, landed: CGRect?, FrameResult, scope: EventScope)
}

/// The loop's scope, readable from app threads: an observation is stamped when it happens, so one made before a
/// Space or topology change is dropped by `reduce` however late the main loop reads it.
package final class ScopeClock: @unchecked Sendable {
    package init() {}
    private let lock = NSLock()
    private var scope: Stamp?

    package var current: Stamp? {
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
        let lastRefused: CGSize?
        let retryOrigin: CGPoint
        let refusals: Int
    }
    private var sizes: [CGWindowID: Size] = [:]

    public init() {}

    public mutating func write(_ request: FrameRequest, to window: AXWindow) -> (result: FrameResult, landed: CGRect?) {
        switch request.purpose {
        case .layout: return write(request.frame.rect, to: window, animating: request.animating)
        case .release(let bounds): return release(request.frame.rect, inside: bounds.rect, to: window)
        }
    }

    private mutating func release(_ frame: CGRect, inside bounds: CGRect, to window: AXWindow) -> (result: FrameResult, landed: CGRect?) {
        let initial = write(frame, to: window)
        guard initial.result == .applied || initial.result == .sizeUnconfirmed else { return initial }
        for attempt in 0..<2 {
            let landed: CGRect
            switch window.getFrame() {
            case .success(let actual):
                guard [actual.minX, actual.minY, actual.width, actual.height].allSatisfy(\.isFinite) else { return (.failed, actual) }
                landed = actual
            case .failure(let error): return (error.isTimeout ? .timedOut : .failed, nil)
            }
            guard !bounds.contains(landed) else { return (.applied, landed) }
            guard attempt == 0, landed.width <= bounds.width, landed.height <= bounds.height else { return (.failed, landed) }
            let origin = CGPoint(x: min(max(landed.minX, bounds.minX), bounds.maxX - landed.width),
                                 y: min(max(landed.minY, bounds.minY), bounds.maxY - landed.height))
            if case .failure(let error) = window.setPosition(origin) {
                return (error.isTimeout ? .timedOut : .failed, landed)
            }
        }
        return (.failed, nil)
    }

    /// Write `frame` and return the result with the frame the app kept, when known. Only the read-back's size is
    /// taken: an app clamps sizes, and a different origin is more likely the user dragging mid-write.
    public mutating func write(_ frame: CGRect, to window: AXWindow, animating: Bool = false) -> (result: FrameResult, landed: CGRect?) {
        let id = window.windowID
        let previous = sizes[id].flatMap { $0.asked == frame.size ? $0 : nil }
        let actual = !animating && previous != nil ? (try? window.getFrame().get())?.size : nil
        let current = actual ?? previous?.kept
        let sameOrigin = previous?.retryOrigin == frame.origin
        let sameRefusal = sameOrigin && (current.flatMap { size in previous?.lastRefused.map { Self.matches($0, size) } } ?? false)
        let refusals = sameRefusal ? previous?.refusals ?? 0 : 0
        let retry = current.map { !animating && !Self.matches($0, frame.size) && refusals < 3 } ?? false
        let kept = retry ? nil : current
        runtimeTrace("size cache: tile=\(id) asked=\(frame.size) cached=\(String(describing: previous?.kept)) actual=\(String(describing: actual)) animating=\(animating) full=\(kept == nil) refusals=\(refusals)")
        switch kept == nil ? window.setFrame(frame) : window.setPosition(frame.origin) {
        case .success:
            let landed = if let kept { CGRect(origin: frame.origin, size: kept) } else {
                (try? window.getFrame().get()).map { CGRect(origin: frame.origin, size: $0.size) }
            }
            let size = landed?.size ?? frame.size
            let refused = !Self.matches(size, frame.size) ? size : current.flatMap { Self.matches($0, frame.size) ? nil : $0 }
            if kept == nil {
                let repeats = sameOrigin && (refused.flatMap { value in previous?.lastRefused.map { Self.matches($0, value) } } ?? false)
                sizes[id] = Size(asked: frame.size, kept: size, lastRefused: refused, retryOrigin: frame.origin,
                                 refusals: refused == nil ? 0 : (repeats ? previous?.refusals ?? 0 : 0) + 1)
            } else if !animating {
                sizes[id] = Size(asked: frame.size, kept: size, lastRefused: refused, retryOrigin: frame.origin,
                                 refusals: refused == nil ? 0 : refusals)
            }
            let confirm = !animating && kept == nil && (sizes[id]?.refusals ?? 0) < 3
            runtimeTrace("size cache: tile=\(id) landed=\(String(describing: landed?.size)) confirm=\(confirm)")
            return (confirm ? .sizeUnconfirmed : .applied, landed)
        case .failure(let error):
            sizes[id] = nil
            return (error.isTimeout ? .timedOut : .failed, nil)
        }
    }

    /// A notification replaces the immediate read-back without spending another resize attempt.
    public mutating func observed(_ id: CGWindowID, frame: CGRect) {
        guard let size = sizes[id], !Self.matches(size.kept, frame.size) else { return }
        let repeats = size.lastRefused.map { Self.matches($0, frame.size) } ?? false
        sizes[id] = Size(asked: size.asked, kept: frame.size, lastRefused: frame.size,
                         retryOrigin: size.retryOrigin, refusals: repeats ? size.refusals : 0)
    }

    private static func matches(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= EchoLedger.slop && abs(lhs.height - rhs.height) <= EchoLedger.slop
    }

    public mutating func forget(_ id: CGWindowID) { sizes[id] = nil }

    public mutating func forgetAll() { sizes = [:] }
}

/// One app's AX state. `windows` and every AX call live on the app's `AXApp` thread; the main loop only queues work.
package final class AppWorker: @unchecked Sendable {
    let app: AXApp
    private let send: @Sendable (Observation, Stamp?) -> Void
    private let clock: ScopeClock
    private var windows: [CGWindowID: AXWindow] = [:]
    private var focusSpace: @Sendable (CGRect?) -> SpaceKey? = { SpaceObserver.observedSpace(at: $0) }
    private var sizes = SizeCache()
    private let lock = NSLock()
    private var queuedFrames: [TileID: FrameRequest] = [:]
    private var drainQueued = false
    private var forgetSizesQueued = false
    private var rediscoveryQueued = false
    private var classificationQueued = false
    private var pendingClassification = Set<CGWindowID>()

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

    package init(app: AXApp, windows: [CGWindowID: AXWindow], clock: ScopeClock,
                 focusSpace: @escaping @Sendable (CGRect?) -> SpaceKey? = { SpaceObserver.observedSpace(at: $0) },
                 send: @escaping @Sendable (Observation, Stamp?) -> Void) {
        self.app = app
        self.windows = windows
        pendingClassification = Set(windows.keys)
        self.focusSpace = focusSpace
        self.clock = clock
        self.send = send
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
    func write(_ request: FrameRequest) {
        lock.lock()
        queuedFrames[request.tile] = request
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
            pendingClassification.remove(id)
            sizes.forget(id)
            post(.destroyed(id))
        }
    }

    package func readFocus(_ completion: @escaping @Sendable (CGWindowID?) -> Void) -> Bool {
        app.perform { [self] in completion(app.focusedWindowID()) }
    }

    func reportFocus(activation: ActivationReport?) {
        app.perform { [self] in
            let stamp = if let activation { activation.stamp } else { clock.current }
            let id = app.focusedWindowID()
            if let id { refreshClassification(id, stamp: stamp, activation: activation) }
            let frame = id.flatMap { windows[$0] }.flatMap { try? $0.getFrame().get() }
            send(.focused(pid: pid, id, activation: activation, space: frame.flatMap { focusSpace($0) }), stamp)
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
                post(.wrote(tile, revision: write.revision, frame: write.frame.rect, landed: nil, .failed, scope: write.scope))
                continue
            }
            let (result, landed) = sizes.write(write, to: window)
            post(.wrote(tile, revision: write.revision, frame: write.frame.rect, landed: landed, result, scope: write.scope))
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
            pendingClassification.remove(id)
            sizes.forget(id)
            post(.destroyed(id))
        case kAXWindowMiniaturizedNotification:
            if let id = windowID(for: element) { post(.minimized(id)) }
        case kAXWindowDeminiaturizedNotification:
            if let window = windowID(for: element).flatMap({ windows[$0] }) { post(.restored(facts(window))) }
        case kAXMovedNotification, kAXResizedNotification:
            guard let id = windowID(for: element), let window = windows[id], case .success(let frame) = window.getFrame() else { return }
            sizes.observed(id, frame: frame)
            refreshClassification(id, stamp: stamp)
            post(.moved(id, frame))
        case kAXTitleChangedNotification:
            if let window = windowID(for: element).flatMap({ windows[$0] }) { post(.retitled(facts(window))) }
        case kAXFocusedWindowChangedNotification:
            let id = windowID(for: element)
            if let id { refreshClassification(id, stamp: stamp) }
            let frame = id.flatMap { windows[$0] }.flatMap { try? $0.getFrame().get() }
            post(.focused(pid: pid, id, activation: nil, space: frame.flatMap { SpaceObserver.observedSpace(at: $0) }))
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

    /// Only provisional facts are re-read on frequent events; a titled tiled window costs no extra AX calls.
    private func refreshClassification(_ id: CGWindowID, stamp: Stamp?, activation: ActivationReport? = nil, force: Bool = false) {
        guard let stamp, force || pendingClassification.contains(id), let window = windows[id] else { return }
        send(.reclassified(facts(window), activation: activation), stamp)
    }

    package func refreshClassifications(_ ids: [CGWindowID]) {
        let first = lock.withLock { () -> Bool in
            guard !classificationQueued else { return false }
            classificationQueued = true
            return true
        }
        guard first else { return }
        if !app.perform({ [self] in
            lock.withLock { classificationQueued = false }
            let stamp = clock.current
            ids.forEach { refreshClassification($0, stamp: stamp, force: true) }
        }) { lock.withLock { classificationQueued = false } }
    }

    private func facts(_ window: AXWindow) -> WindowFacts {
        var properties = window.getPropertiesFast()
        properties.windowLayer = windowLayer(for: window.windowID)
        properties.bundleIdentifier = app.bundleIdentifier
        let classification = classifyWindow(properties)
        if classification == .float || properties.title?.isEmpty != false { pendingClassification.insert(window.windowID) }
        else { pendingClassification.remove(window.windowID) }
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
public final class Observer: CensusObserver {
    /// Windows to manage; the ones their app classified `.ignore` are in `ignored` instead.
    public private(set) var known: [CGWindowID: WindowFacts] = [:]
    package var workers: [Int32: AppWorker] = [:]
    let allowedPids: Set<Int32>?
    private let executor: Executor
    private let emit: (Event.Kind, Stamp?) -> Void
    package let clock = ScopeClock()
    private let managed: () -> Set<CGWindowID>
    /// Windows the engine keeps off the current strip: hidden ones and every saved strip's, so a close there is heard.
    private let elsewhere: () -> Set<CGWindowID>
    private let log: (String) -> Void
    private let onActivation: (Int32) -> Void
    private let frontmostPID: () -> Int32?
    private var tokens: [NSObjectProtocol] = []
    private var healthTimer: Timer?
    private var awaitingDiscovery = Set<Int32>()
    private var onDiscovered: (() -> Void)?
    /// On-screen windows their app classified `.ignore`, so the health check does not ask about them every pass.
    private var ignored = Set<CGWindowID>()
    /// While paused, the engine hears only removals and retitles; the registry still tracks everything for the resume census.
    private let paused: () -> Bool
    private var activationGeneration: UInt64 = 0

    private lazy var censusDiscovery: CensusDiscovery = CensusDiscovery { [weak self] pid in
        guard let self else { return }
        if let worker = workers[pid] { worker.rediscover([]) }
        else {
            if let app = NSRunningApplication(processIdentifier: pid) { register(app) }
            if workers[pid] == nil { censusDiscovery.reported(pid) }
        }
    }

    public static let healthInterval = 0.5

    package init(executor: Executor, allowedPids: Set<Int32>?, managed: @escaping () -> Set<CGWindowID>,
         elsewhere: @escaping () -> Set<CGWindowID>, paused: @escaping () -> Bool,
         emit: @escaping (Event.Kind, Stamp?) -> Void, log: @escaping (String) -> Void,
         onActivation: @escaping (Int32) -> Void = { _ in },
         frontmostPID: @escaping () -> Int32? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }) {
        self.executor = executor
        self.allowedPids = allowedPids
        self.managed = managed
        self.elsewhere = elsewhere
        self.paused = paused
        self.emit = emit
        self.onActivation = onActivation
        self.frontmostPID = frontmostPID
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
    package func census(_ onScreen: [CGWindowInfo] = getAllWindowInfo(), space: SpaceKey? = nil) -> [ObservedWindow] {
        let frames = Dictionary(onScreen.map { ($0.windowID, $0.bounds) }, uniquingKeysWith: { first, _ in first })
        return known.values.filter { frames[$0.id] != nil && (space == nil || censusMembership(SpaceIdentity.spaces(ofWindow: $0.id), matches: space)) }
            .sorted { $0.id < $1.id }.map { $0.observed(at: frames[$0.id]) }
    }

    package func prepareCensus(_ onScreen: [CGWindowInfo], completion: @escaping (TileID?) -> Void) {
        let unknown = onScreen.filter {
            $0.layer == 0 && known[$0.windowID] == nil && !ignored.contains($0.windowID) &&
                (allowedPids?.contains($0.ownerPID) ?? true)
        }
        censusDiscovery.refresh(Set(unknown.map(\.ownerPID))) { [weak self] in
            guard let self else { return completion(nil) }
            readFrontmost(completion: completion)
        }
    }

    package func readFrontmost(completion: @escaping (TileID?) -> Void) {
        guard let pid = frontmostPID(), let worker = workers[pid] else { return completion(nil) }
        let focusGeneration = executor.focusGeneration
        let read = FrontmostRead(completion: completion)
        if !worker.readFocus({ [weak self] id in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, self.frontmostPID() == pid, self.executor.focusGeneration == focusGeneration else { return read.finish(nil) }
                read.finish(id.map(TileID.init))
            } }
        }) { read.finish(nil) }
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
        let provisional = known.values.filter { visible.contains($0.id) && ($0.classification == .float || $0.title.isEmpty) }
        for (pid, facts) in Dictionary(grouping: provisional, by: \.pid) {
            workers[pid]?.refreshClassifications(facts.map(\.id))
        }
        let unknown = onScreen.filter { $0.layer == 0 && known[$0.windowID] == nil && !ignored.contains($0.windowID) }
        for (pid, windows) in Dictionary(grouping: unknown, by: \.ownerPID).sorted(by: { $0.key < $1.key }) {
            // An app can turn regular after its launch notification; its first on-screen window registers it. One that
            // was busy when it registered lists its windows now.
            // ponytail: a window AX never lists costs its app one kAXWindows read per pass; remember misses if perf shows it.
            if let worker = workers[pid] { worker.rediscover(windows.map(\.windowID)) }
            else { NSRunningApplication(processIdentifier: pid).map(register) }
        }
        for window in census(onScreen) where !managed.contains(window.id.rawValue) { emit(.windowAdded(window, frontmost: window.pid == frontmostPID()), nil) }
    }

    /// Name the app before a destination census can commit, then read its focused window on the app thread.
    package func activated(_ pid: Int32) {
        onActivation(pid)
        if executor.consumeFocusEcho(pid: pid) {
            return log(FocusIntent(tile: nil, pid: pid, source: .appActivation).droppedLog(reason: "executed-focus-echo"))
        }
        activationGeneration &+= 1
        executor.invalidateFocus()
        guard let worker = workers[pid] else {
            return log(FocusIntent(tile: nil, pid: pid, source: .appActivation).droppedLog(reason: "untracked-app"))
        }
        // The OS may already expose the destination Space. The current epoch, not that key, scopes the click.
        let space: SpaceKey? = nil
        let intent = FocusIntent(tile: nil, pid: pid, source: .appActivation, observedSpace: space)
        if paused() { log(intent.droppedLog(reason: "paused")) }
        else if let stamp = clock.current { emit(.focus(intent), stamp) }
        else { log(intent.droppedLog(reason: "missing-scope")) }
        worker.reportFocus(activation: ActivationReport(generation: activationGeneration, focusGeneration: executor.focusGeneration, stamp: clock.current))
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
    package func receive(_ observation: Observation, stamp: Stamp?) {
        func emitObserved(_ kind: Event.Kind) { if let stamp { emit(kind, stamp) } }
        switch observation {
        case .discovered(let pid, let windows):
            guard workers[pid] != nil else { return }
            windows.forEach(learn)
            awaitingDiscovery.remove(pid)
            censusDiscovery.reported(pid)
            if awaitingDiscovery.isEmpty { finishDiscovery() }
        case .created(let facts):
            learn(facts)
            // Only a window on the current Space joins; one that is not on screen yet joins at the next health check.
            if !paused(), facts.classification != .ignore, isWindowOnScreen(facts.id) { emitObserved(.windowAdded(facts.observed, frontmost: facts.pid == frontmostPID())) }
        case .destroyed(let id):
            let tracked = managed().contains(id) || elsewhere().contains(id)
            forget(id)
            if tracked { emit(.windowRemoved(TileID(id)), nil) }
        case .minimized(let id):
            known.removeValue(forKey: id)
            if managed().contains(id) { emit(.windowsHidden([TileID(id)]), nil) }
        case .restored(let facts):
            learn(facts)
            if !paused(), facts.classification != .ignore { emitObserved(.windowAdded(facts.observed, frontmost: facts.pid == frontmostPID())) }
        case .retitled(let facts):
            learn(facts)
            // Even while paused, so a late title is not lost; the engine's writes are held back until resume.
            if facts.classification != .ignore { emit(.windowChanged(facts.observed, frontmost: facts.pid == frontmostPID()), nil) }
        case .reclassified(let facts, let activation):
            // Provisional facts may change membership/focus. Never apply an activation's metadata to a newer scope.
            guard let stamp, stamp == clock.current else { return }
            if let activation, activation.generation != activationGeneration || activation.focusGeneration != executor.focusGeneration { return }
            learn(facts)
            if facts.classification != .ignore { emit(.windowChanged(facts.observed, frontmost: facts.pid == frontmostPID()), stamp) }
        case .moved(let id, let frame):
            guard !paused(), stamp != nil, managed().contains(id), executor.isForeign(TileID(id), frame: frame) else { return }
            emitObserved(.windowMoved(TileID(id), AXRect(frame)))
        case .focused(let pid, let id, let activation, let space):
            let intent = FocusIntent(tile: id.map(TileID.init), pid: pid, source: activation != nil ? .appActivation : .axFocus, observedSpace: space)
            if let activation, activation.generation != activationGeneration || activation.focusGeneration != executor.focusGeneration {
                return log(intent.droppedLog(reason: "superseded-activation"))
            }
            guard !paused() else { return log(intent.droppedLog(reason: "paused")) }
            guard let stamp else { return log(intent.droppedLog(reason: "missing-scope")) }
            emit(.focus(intent), stamp)
        case .wrote(let tile, let revision, let frame, let landed, let result, let scope):
            executor.wrote(tile, revision: revision, frame: frame, landed: landed, result: result)
            emit(.frameCompleted(tile: tile, revision: revision, result: result, landed: landed.map(AXRect.init)), Stamp(scope))
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
