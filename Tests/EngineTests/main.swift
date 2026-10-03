import Core
import Engine
import Foundation
import Platform
import Runtime

let environment = ProcessInfo.processInfo.environment
let only = environment["ENGINE_ONLY"]?.lowercased() ?? ""
let margin = 0.05
var checks = 0
var failures = 0

@MainActor func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    checks += 1
    if !condition() { failures += 1; print("FAIL: \(message) (main.swift:\(line))") }
}

@MainActor func section(_ name: String, _ body: () throws -> Void) rethrows {
    guard only.isEmpty || name.lowercased().contains(only) else { return }
    print("▸ \(name)")
    try body()
}

func window(_ id: UInt32, app: Int32? = nil, bundle: String? = "test.app", floating: Bool = false, x: Double? = nil) -> ObservedWindow {
    ObservedWindow(id: TileID(id), pid: app ?? Int32(id), bundleID: bundle, title: "window-\(id)", floating: floating,
                   initialFrame: x.map { AXRect(CGRect(x: $0, y: 30, width: 350, height: 600)) })
}

func display(_ id: UInt32 = 1, x: Double = 0) -> DisplayGroup {
    DisplayGroup(id: id, displays: [id], frame: CGRect(x: x, y: 30, width: 1000, height: 800))
}

func threadCPUTime() -> Duration {
    var spec = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &spec)
    return .seconds(spec.tv_sec) + .nanoseconds(spec.tv_nsec)
}

struct Harness {
    var world: World
    var time = 1.0
    var effects: [Effect] = []
    var reduceTime: Duration = .zero
    var reduceCPU: Duration = .zero

    init(animate: Bool = false, gestureSnap: Bool = true, rules: [Rule] = [], displays: [DisplayGroup] = [display()]) {
        world = World(topology: Topology(revision: 1, groups: displays, primaryScreenHeight: 900),
                      config: EngineConfig(animate: animate, gestureSnap: gestureSnap, rules: rules))
    }

    @discardableResult mutating func send(_ kind: Event.Kind, group: UInt32 = 1, scope: EventScope? = nil, advance: Double = 0.01) -> [Effect] {
        time += advance
        let stamped: Event.Kind
        switch kind {
        case .pointer(let input, nil):
            switch input {
            case .beginGesture, .openMenu, .beginReorder: stamped = kind
            default: stamped = .pointer(input, session: world.pointer.token)
            }
        default: stamped = kind
        }
        apply(Event(scope: scope ?? world.scope(for: group)!, kind: stamped))
        return effects
    }

    mutating func apply(_ event: Event) {
        let cpu = threadCPUTime()
        let start = ContinuousClock.now
        effects = reduce(&world, event, now: time)
        reduceTime += start.duration(to: .now)
        reduceCPU += threadCPUTime() - cpu
    }

    mutating func census(_ id: UInt64, _ windows: [ObservedWindow], group: UInt32 = 1) {
        send(.spaceChanged(key: .skylight(id), epoch: world.groups[group]!.epoch + 1, windows: windows), group: group)
    }

    mutating func advance(_ delta: Double) {
        let target = time + delta
        while let entry = world.timers.filter({ $0.value.deadline <= target }).min(by: {
            if $0.value.deadline == $1.value.deadline { return $0.key.rawValue < $1.key.rawValue }
            return $0.value.deadline < $1.value.deadline
        }) {
            time = max(time, entry.value.deadline)
            apply(Event(scope: entry.value.scope, kind: .timer(entry.key)))
        }
        time = target
    }

    var active: TileID? { world.groups[1]?.strip.activeColumn?.activeTile }
    var gesture: GestureSession? { if case .gesture(let session) = world.pointer { session } else { nil } }
    var tiles: [TileID] { world.groups[1]!.strip.columns.flatMap(\.tiles) }
    var offset: Double { world.groups[1]!.strip.viewOffset.current(at: time) }

    var widths: [ColumnWidth] { world.groups[1]!.strip.columns.map(\.width) }

    var requests: [FrameRequest] {
        effects.compactMap { if case .setFrame(let request) = $0 { return request }; return nil }
    }

    var persisted: Bool { effects.contains { if case .persist = $0 { return true }; return false } }

    var censusRequest: Double? {
        effects.lazy.compactMap { if case .requestCensus(_, let after) = $0 { return after }; return nil }.first
    }

    func logged(_ text: String) -> Bool {
        effects.contains { if case .log(let line) = $0 { return line.contains(text) }; return false }
    }

    func stash(_ space: UInt64, group: UInt32 = 1) -> [TileID]? {
        world.spaces.lookupExact(group: group, space: .skylight(space))?.windows.map(\.id)
    }
}

@MainActor func replayTests() throws {
    section("2d4bb1d: mixed and empty census preserve both Space stashes") {
        var h = Harness()
        h.census(10, [window(1), window(2)])
        h.send(.command(.setWidth(TileID(1), 377), .ipc))
        h.census(20, [window(3), window(4)])
        let before = h.world.spaces.live.count
        h.census(30, [window(1), window(3)])
        check(h.world.groups[1]!.space == .skylight(20), "mixed census did not commit")
        check(h.world.spaces.live.count == before, "mixed census did not prune")
        check(h.censusRequest.map { abs($0 - EngineConfig.censusSettle) < 1e-9 } == true,
              "mixed census asks the observer for a settled re-read")
        h.census(30, [])
        check(h.world.groups[1]!.space == .skylight(20), "unconfirmed empty census did not commit")
        check(h.censusRequest.map { $0 < EngineConfig.censusSettle } == true,
              "repeat read keeps the original settle deadline")
        h.advance(EngineConfig.censusSettle)
        h.census(30, [])
        check(h.world.groups[1]!.space == .skylight(30) && h.tiles.isEmpty, "settled empty re-read commits the empty Space")
        check(h.world.spaces.lookupExact(group: 1, space: .skylight(20))?.windows.map(\.id) == [TileID(3), TileID(4)],
              "departing stash saved before the empty Space")
        h.census(10, [window(1), window(2)])
        check(h.world.groups[1]!.strip.columns[0].width == .fixed(377), "departing layout survives bad census")
        check(h.world.check().isEmpty, "census invariants")
    }
    section("2d4bb1d: a mixed read repeated past the settle keeps both Spaces' layouts") {
        var h = Harness()
        h.census(10, [window(1), window(2)])
        h.send(.command(.setWidth(TileID(1), 377), .ipc))
        h.census(20, [window(3), window(4)])
        h.send(.command(.setWidth(TileID(3), 333), .ipc))
        h.census(30, [window(1), window(3)])
        h.advance(EngineConfig.censusSettle + margin)
        h.census(30, [window(1), window(3)])
        h.census(10, [window(1), window(2)])
        check(h.world.groups[1]!.space == .skylight(10) && h.censusRequest == nil, "returning to Space 10 is not deferred")
        check(h.tiles == [TileID(1), TileID(2)] && h.widths.first == .fixed(377), "Space 10 keeps width 377")
        h.census(20, [window(3), window(4)])
        check(h.tiles == [TileID(3), TileID(4)] && h.widths.first == .fixed(333), "Space 20 keeps width 333")
        check(h.world.check().isEmpty, "census invariants")
    }
    section("c9d3e80 1aa4ede: Space-switch focus echoes cannot overwrite departing focus") {
        var h = Harness()
        h.census(10, [window(1), window(2), window(3)])
        h.send(.command(.focus(TileID(3)), .keyboard))
        h.advance(EngineConfig.focusDebounce + margin)
        h.send(.focus(FocusIntent(tile: TileID(1), source: .axFocus)))
        let deferred = h.world.timers.keys.first!
        let old = h.world.scope(for: 1)!
        h.send(.spaceWillChange)
        check(h.world.timers.isEmpty, "space observation cancels deferred focus")
        h.census(20, [window(4)])
        h.send(.timer(deferred), scope: old)
        let staleEffects = h.send(.focus(FocusIntent(tile: TileID(1), source: .axFocus)), scope: old)
        check(staleEffects.isEmpty, "old-epoch focus produces no effects")
        h.census(10, [window(1), window(2), window(3)])
        check(h.active == TileID(3), "echo did not change saved active column")
        h.send(.focus(FocusIntent(tile: TileID(1), source: .axFocus)))
        h.advance(EngineConfig.focusDebounce + margin)
        check(h.active == TileID(3), "post-restore echo rejected on receipt, not after debounce")
        h.send(.focus(FocusIntent(tile: TileID(1), source: .axFocus, observedSpace: .skylight(20))))
        h.advance(EngineConfig.focusDebounce + margin)
        check(h.active == TileID(3), "AX focus from a different observed identity cannot beat delayed Space notification")
        check(h.world.check().isEmpty, "focus echo invariants")
    }
    section("e3e6267 0ea87ee: cross-Space app activation wins once; local or arriving activation does not") {
        var h = Harness()
        h.census(20, [window(3, app: 30), window(4, app: 40)])
        h.send(.command(.focus(TileID(4)), .ipc))
        h.census(10, [window(1, app: 10), window(2, app: 20)])
        h.send(.focus(FocusIntent(tile: TileID(3), pid: 30, source: .appActivation)))
        h.send(.spaceWillChange)
        h.census(20, [window(3, app: 30), window(4, app: 40)])
        check(h.active == TileID(3), "dock crossing chooses activated app")
        check(h.world.groups[1]!.focus.decision?.source == .appActivation, "dock source retained")
        h.send(.command(.focus(TileID(4)), .ipc))
        h.census(10, [window(1, app: 10), window(2, app: 20)])
        h.send(.focus(FocusIntent(tile: TileID(1), pid: 10, source: .appActivation)))
        h.census(20, [window(3, app: 10), window(4, app: 40)])
        check(h.active == TileID(4), "local activation cannot override saved focus")
        h.send(.command(.focus(TileID(4)), .ipc))
        h.census(10, [window(1, app: 10), window(2, app: 20)])
        h.send(.focus(FocusIntent(tile: TileID(3), pid: 30, source: .appActivation)))
        h.advance(EngineConfig.crossingTTL + margin)
        h.census(20, [window(3, app: 30), window(4, app: 40)])
        check(h.active == TileID(4), "expired crossing does not override saved focus")
        h.census(10, [window(1, app: 10), window(2, app: 20)])
        h.send(.focus(FocusIntent(tile: TileID(3), pid: 30, source: .appActivation, observedSpace: .skylight(20))))
        h.census(20, [window(3, app: 30), window(4, app: 40)])
        check(h.active == TileID(4), "arrival activation carrying destination identity cannot impersonate dock crossing")
    }
    section("c34080d: app activation uses incremental snap, keyboard recenters") {
        var h = Harness()
        h.census(10, [window(1), window(2), window(3)])
        h.send(.command(.focus(TileID(1)), .ipc))
        h.send(.pointer(.beginGesture(TileID(1))))
        h.send(.pointer(.delta(50)))
        h.send(.pointer(.cancel))
        let prior = h.offset
        h.send(.focus(FocusIntent(tile: TileID(1), pid: 1, source: .appActivation)))
        h.advance(EngineConfig.focusDebounce + margin)
        check(h.offset == prior, "visible external target retains viewport")
        h.send(.command(.focus(TileID(1)), .keyboard))
        check(h.offset != prior, "keyboard target recenters")
    }
    section("fc92b12: removed and floating windows revoke queued AX writes") {
        var h = Harness(animate: true)
        h.census(10, [window(1), window(2)])
        let old = h.world.frames[TileID(1)]!
        h.send(.command(.setWidth(TileID(1), 650), .ipc))
        h.send(.tick, advance: 0.1)
        let new = h.world.frames[TileID(1)]!
        check(new.revision > old.revision, "new animation frame has newer revision")
        h.send(.frameCompleted(tile: old.tile, revision: old.revision, result: .applied))
        check(h.world.appliedFrames[old.tile] == nil, "old completion rejected")
        h.send(.windowRemoved(TileID(1)))
        check(h.effects.contains { if case .invalidateFrame(let tile, _) = $0 { return tile == TileID(1) }; return false }, "remove revokes executor mailbox")
        h.send(.frameCompleted(tile: new.tile, revision: new.revision, result: .applied))
        check(h.world.appliedFrames[new.tile] == nil, "removed completion rejected")
        let floating = h.world.frames[TileID(2)]!
        h.send(.command(.toggleFloating(TileID(2)), .ipc))
        check(h.world.frames[TileID(2)] == nil && h.tiles.isEmpty, "floating window removed from frame stream")
        h.send(.frameCompleted(tile: floating.tile, revision: floating.revision, result: .applied))
        check(h.world.appliedFrames[floating.tile] == nil, "floating completion rejected")
        h.send(.tick)
        check(h.requests.isEmpty, "tick cannot reposition floating window")
        check(h.world.check().isEmpty, "AX lifecycle invariants")
    }
    section("abf1b87 d227a21: adoption and Space observation cancel old gesture and focus latches") {
        var h = Harness()
        h.census(10, [window(1), window(2)])
        h.send(.pointer(.beginGesture(TileID(1))))
        h.send(.pointer(.delta(90)))
        h.send(.pointer(.beginGesture(TileID(999))))
        check(h.world.pointer.token == nil, "rejected gesture resets idle")
        if case .gesture = h.world.groups[1]!.strip.viewOffset { check(false, "reject left gesture latch") }
        h.advance(EngineConfig.focusDebounce + margin)
        h.send(.focus(FocusIntent(tile: TileID(1), source: .axFocus)))
        let timer = h.world.timers.keys.first!
        h.send(.windowAdded(window(3)))
        check(h.world.timers.isEmpty, "adoption cancels deferred old focus")
        h.send(.timer(timer), advance: EngineConfig.focusDebounce + margin)
        check(h.active == TileID(3), "late pre-adoption focus cannot win")
        h.send(.pointer(.beginGesture(TileID(3))))
        h.send(.spaceWillChange)
        check(h.world.pointer.token == nil, "observed Space change cancels immediately")
    }
    section("eebb564: menu commands retain open-time target after active column changes") {
        var h = Harness()
        h.census(10, [window(1), window(2)])
        h.send(.pointer(.openMenu(TileID(1))))
        h.send(.command(.focus(TileID(2)), .ipc))
        h.send(.pointer(.menu(.setWidth(TileID(2), 333))))
        check(h.world.groups[1]!.strip.columns[0].width == .fixed(333), "menu acts on captured tile")
        check(h.world.groups[1]!.strip.columns[1].width != .fixed(333), "later active tile unchanged")
        check(h.world.pointer.token == nil, "menu consumed")
    }
    section("eebb564: late menu and reorder callbacks cannot act on a replacement session") {
        var h = Harness()
        h.census(10, [window(1), window(2)])
        h.send(.pointer(.openMenu(TileID(1))))
        let oldMenu = h.world.pointer.token!
        h.send(.pointer(.openMenu(TileID(2))))
        let newMenu = h.world.pointer.token!
        h.send(.pointer(.menu(.setWidth(TileID(1), 311)), session: oldMenu))
        check(h.effects.isEmpty && h.world.pointer.token == newMenu, "old menu callback cannot mutate or cancel new menu")
        check(h.world.groups[1]!.strip.columns.allSatisfy { $0.width != .fixed(311) }, "stale callback touches neither tile")
        h.send(.pointer(.menu(.setWidth(TileID(1), 322)), session: newMenu))
        check(h.world.groups[1]!.strip.columns[1].width == .fixed(322), "current menu still acts on captured target")
        h.send(.pointer(.beginReorder(TileID(1))))
        let oldDrag = h.world.pointer.token!
        h.send(.pointer(.beginReorder(TileID(2))))
        let newDrag = h.world.pointer.token!
        h.send(.pointer(.dropReorder(0), session: oldDrag))
        check(h.tiles == [TileID(1), TileID(2)] && h.world.pointer.token == newDrag, "late drop cannot commit new drag")
    }
    section("5753fc0: topology revision invalidates gesture, overlay, queued frames and stale events") {
        var h = Harness(displays: [display(), display(2, x: 1000)])
        h.census(10, [window(1)])
        h.census(10, [window(2)], group: 2)
        h.send(.pointer(.openMenu(TileID(1))))
        let old = h.world.scope(for: 1)!
        let oldFrame = h.world.frames[TileID(1)]!
        h.send(.topologyChanged(Topology(revision: 2, groups: [display()], primaryScreenHeight: 900)))
        check(h.world.pointer.token == nil, "topology cancels overlay")
        check(Set(h.tiles) == Set([TileID(1), TileID(2)]), "hot-unplug migrates windows")
        let staleEffects = h.send(.windowRemoved(TileID(1)), scope: old)
        check(staleEffects.isEmpty, "old-topology event produces no effects")
        h.send(.frameCompleted(tile: oldFrame.tile, revision: oldFrame.revision, result: .applied), scope: old)
        check(h.tiles.contains(TileID(1)), "old topology cannot remove current tile")
        check(h.world.appliedFrames[TileID(1)] == nil, "old topology cannot acknowledge frame")
        check(h.world.check().isEmpty, "topology invariants")
    }
    section("2b2457b abf1b87: width and gesture snap basis survive overlapping animations") {
        var h = Harness(animate: true)
        h.census(10, [window(1), window(2)])
        h.send(.command(.setWidth(TileID(1), 650), .ipc))
        h.send(.pointer(.beginGesture(TileID(1))))
        let targets = h.gesture!.snapTargets
        h.send(.command(.setWidth(TileID(1), 350), .ipc))
        h.send(.pointer(.delta(400)))
        let strip = h.world.groups[1]!.strip
        let shift = strip.columnX(at: 0, time: h.time + 0.01) - strip.columnX(at: 1, time: h.time + 0.01)
        h.send(.pointer(.endGesture))
        check(h.world.groups[1]!.strip.activeColumnIndex == 1, "release lands on the next column")
        if case .animation(let release) = h.world.groups[1]!.strip.viewOffset {
            check(abs(release.to - shift - targets[1]) < 0.001, "release targets the captured column boundary, not a new-width grid")
        } else { check(false, "gesture release starts spring") }
        check(h.world.groups[1]!.strip.columns[0].width == .fixed(350), "logical width is latest target")
        h.send(.tick, advance: 5)
        check(h.world.groups[1]!.strip.columnData[0].cachedWidth == 350, "animated width settles to logical width")
        check(h.world.check().isEmpty, "overlapping animation invariants")
    }
    section("2b2457b 67240b9: free gesture projection retains the starting coordinate basis") {
        var h = Harness(gestureSnap: false)
        h.census(10, [window(1), window(2)])
        h.send(.command(.focus(TileID(2)), .ipc))
        h.send(.pointer(.beginGesture(TileID(2))))
        let start = h.gesture!.startOffset
        h.send(.pointer(.delta(-90)))
        h.send(.pointer(.delta(-30)))
        guard case .gesture(let gesture) = h.world.groups[1]!.strip.viewOffset else { check(false, "gesture state"); return }
        let expected = start + gesture.tracker.projectedEndPosition(isTouchpad: true)
        check(start != 0, "nonzero starting offset exercises the coordinate bug")
        check(h.world.groups[1]!.strip.viewOffsetBounds(at: h.time).contains(expected), "projection lands inside the strip")
        h.send(.pointer(.endGesture))
        check(abs(h.offset - expected) < 0.001, "free release uses start offset plus tracker projection")
        check(h.world.pointer.token == nil, "release clears latch without a tick")
        h.send(.pointer(.beginGesture(TileID(2))))
        h.send(.pointer(.delta(17)), advance: 0.1)
        let dropped = h.offset
        h.send(.pointer(.endGesture), advance: 0.1)
        check(h.offset == dropped, "slow free release does not snap or reuse old momentum")
    }
    section("2be34bd: secondary screen coordinate round trip and reorder at end") {
        let group = display(2, x: -1000)
        let local = StripRect(CGRect(x: 100, y: 20, width: 300, height: 400))
        let global = axRect(viewportRect(local, offset: 50), on: group)
        check(global.rect.minX == -950 && global.rect.minY == 50, "local offset becomes global AX frame")
        check(stripRect(global, on: group, offset: 50) == local, "coordinate round trip")
        let topology = Topology(revision: 1, groups: [group], primaryScreenHeight: 900)
        let appKit = screenRect(global, in: topology)
        check(appKit.rect.minY == 450, "screen wrapper uses AppKit bottom-left origin")
        check(axRect(appKit, in: topology) == global, "AppKit/AX round trip")
        let point = AXPoint(CGPoint(x: -400, y: 200))
        check(axPoint(screenPoint(point, in: topology), in: topology) == point, "typed point round trip")
        var h = Harness()
        h.census(10, [window(1), window(2), window(3)])
        h.send(.pointer(.beginReorder(TileID(1))))
        h.send(.pointer(.dropReorder(Int.max)))
        check(h.tiles == [TileID(2), TileID(3), TileID(1)], "past-end drop moves to end")
    }
    section("524cd8a 283afe2: hung app does not block a healthy app; cancelled retries cannot fire") {
        var h = Harness()
        h.census(10, [window(1), window(2)])
        let hung = h.world.frames[TileID(1)]!
        let healthy = h.world.frames[TileID(2)]!
        h.send(.frameCompleted(tile: hung.tile, revision: hung.revision, result: .timedOut))
        check(h.world.timers.count == 1, "timeout schedules scoped retry")
        h.send(.frameCompleted(tile: healthy.tile, revision: healthy.revision, result: .applied))
        check(h.world.appliedFrames[healthy.tile] == healthy, "healthy app completes while peer hung")
        h.advance(EngineConfig.frameRetryDelay + margin)
        check(h.world.frames[hung.tile]!.revision > hung.revision, "retry issued newer revision")
        check(h.world.timers.isEmpty, "fired token consumed")
        let retried = h.world.frames[hung.tile]!
        h.send(.frameCompleted(tile: retried.tile, revision: retried.revision, result: .failed))
        let cancelled = h.world.timers.keys.first!
        let old = h.world.scope(for: 1)!
        h.census(20, [window(3)])
        h.send(.timer(cancelled), scope: old, advance: EngineConfig.frameRetryDelay + margin)
        check(h.world.frames[hung.tile] == nil && h.world.timers.isEmpty, "cancelled retry cannot resurrect departed tile")
    }
    try section("554b4ed: snapshot round trip, logical widths, snap positions, nil bundle IDs, deterministic restore") {
        var h = Harness()
        h.census(10, [window(1, bundle: nil), window(2), window(3, floating: true)])
        h.send(.command(.setWidth(TileID(1), 317), .ipc))
        h.send(.command(.focus(TileID(2)), .ipc))
        let snapshots = Array(h.world.spaces.live.values)
        let data = try Snapshot.encode(snapshots)
        let decoded = try Snapshot.decode(data)
        let encodedAgain = try Snapshot.encode(decoded)
        check(encodedAgain == data, "codec round trip byte stable")
        check(decoded[0].columns[0].windows[0].bundleID == nil, "nil bundle round trip")
        let stacked = Snapshot(group: 1, space: .fingerprint([7, 8]), columns: [
            SnapshotColumn(windows: [window(7), window(8)], width: .proportion(0.7), activeTileIndex: 1,
                           snapIndex: 2, presetIndex: 1, isFullWidth: true)
        ], offset: -120)
        let stackedRoundTrip = try Snapshot.decode(Snapshot.encode([stacked]))[0]
        check(stackedRoundTrip.columns[0].activeTileIndex == 1 && stackedRoundTrip.columns[0].snapIndex == 2,
              "codec retains stacked active tile and snap milestone")
        check(stackedRoundTrip.columns[0].isFullWidth && stackedRoundTrip.columns[0].width == .proportion(0.7)
              && stackedRoundTrip.offset == -120, "codec retains width intent independently of full width")
        var fresh = Harness()
        fresh.send(.loadSnapshots(decoded))
        fresh.census(99, [ObservedWindow(id: TileID(11), pid: 1, bundleID: "", title: "window-1"),
                          ObservedWindow(id: TileID(12), pid: 2, bundleID: "test.app", title: "window-2"),
                          ObservedWindow(id: TileID(13), pid: 3, bundleID: "test.app", title: "window-3")])
        check(fresh.world.groups[1]!.strip.columns[0].width == .fixed(317), "disk matching normalizes nil bundle to empty")
        check(fresh.active == TileID(12), "disk remaps saved active window")
        check(fresh.world.groups[1]!.floating.contains(TileID(13)), "disk restores floating window")
        check(fresh.world.check().isEmpty, "round-trip invariants")
        let bad = Snapshot(group: 1, space: .skylight(1), columns: [SnapshotColumn(windows: [window(1)], width: .fixed(-1))])
        let kept = try Snapshot.decode(Snapshot.encode([bad, stacked]))
        check(kept.count == 1 && kept[0].space == stacked.space, "invalid entry dropped, valid sibling kept")
    }
    section("554b4ed: initial adoption follows visual order, not AX enumeration order") {
        var h = Harness()
        h.census(10, [window(3, x: 800), window(1, x: 100), window(2, x: 450)])
        check(h.tiles == [TileID(1), TileID(2), TileID(3)], "census order comes from observed geometry")
        h.send(.command(.focus(TileID(1)), .ipc))
        h.send(.windowAdded(window(4)))
        check(h.tiles == [TileID(1), TileID(4), TileID(2), TileID(3)], "new window inserts after current focus through Core")
        h.census(20, [window(5)])
        h.census(10, [window(3, x: 0), window(2, x: 100), window(1, x: 200), window(4, x: 300)])
        check(h.tiles == [TileID(1), TileID(4), TileID(2), TileID(3)], "saved strip order outranks current AX geometry")
    }
    section("73ef68d: live identities are exact; disk capture cannot copy a foreign Space") {
        var h = Harness()
        h.census(10, [window(1), window(2)])
        h.send(.command(.setWidth(TileID(1), 311), .ipc))
        h.census(20, [window(3)])
        h.census(99, [window(1), window(2)])
        check(h.world.groups[1]!.strip.columns[0].width != .fixed(311), "different sid cannot fuzzy-match live stash")
        h.census(20, [window(3)])
        h.send(.spaceChanged(key: .fingerprint([1, 2]), epoch: h.world.groups[1]!.epoch + 1, windows: [window(1), window(2)]))
        check(h.world.groups[1]!.space == .fingerprint([1, 2]), "degraded key commits")
        check(h.world.groups[1]!.strip.columns[0].width == .fixed(311), "degraded fingerprint deterministically recovers authoritative stash")
        check(h.world.spaces.lookupExact(group: 1, space: .skylight(10)) == nil, "recovered stash re-keyed off the old sid")
        h.send(.command(.setWidth(TileID(2), 222), .ipc))
        h.census(20, [window(3)])
        h.census(10, [window(1), window(2)])
        check(h.world.groups[1]!.strip.columns.map(\.width) == [.fixed(311), .fixed(222)], "returning sid keeps edits made while degraded")
        check(h.world.spaces.lookupExact(group: 1, space: .fingerprint([1, 2])) == nil, "sid return re-keys the fingerprint stash")
        check(h.world.check().isEmpty, "degraded-key invariants")
    }
    section("73ef68d: rules fail closed for missing bundle IDs; sole foreign disk entry is not adopted") {
        var h = Harness(rules: [Rule(bundleID: "", floating: true), Rule(bundleID: "float.app", floating: true)])
        let foreign = Snapshot(group: 1, space: .skylight(90), columns: [SnapshotColumn(windows: [window(999)], width: .fixed(999))])
        h.send(.loadSnapshots([foreign]))
        h.census(10, [window(1, bundle: nil), window(2, bundle: "float.app")])
        h.send(.windowAdded(window(3, bundle: "float.app")))
        check(h.tiles == [TileID(1)], "nil bundle does not match empty-string rule")
        check(h.world.groups[1]!.floating == Set([TileID(2), TileID(3)]), "rules apply at census and adoption")
        check(h.world.groups[1]!.strip.columns[0].width != .fixed(999), "unrelated sole disk snapshot rejected")
        check(h.world.spaces.lookupExact(group: 1, space: .skylight(10))?.windows.contains(where: { $0.id == TileID(999) }) == false,
              "capture writes only this Space's membership")
    }
    section("c9d3e80 554b4ed: snapshot focus survives missing leading columns and floating focus") {
        var h = Harness()
        h.census(10, [window(1), window(2), window(3), window(4, floating: true)])
        h.send(.command(.focus(TileID(2)), .ipc))
        h.census(20, [window(5)])
        h.census(10, [window(2), window(3), window(4, floating: true)])
        check(h.active == TileID(2), "focus tracks identity when an earlier saved column disappears")
        h.send(.command(.focus(TileID(4)), .ipc))
        h.census(20, [window(5)])
        h.census(10, [window(2), window(3), window(4, floating: true)])
        check(h.world.groups[1]!.focus.decision?.tile == TileID(4), "floating focus is saved independently of active column")
        check(h.world.check().isEmpty, "restored focus invariants")
    }
    section("fc92b12: observation revokes frames before commit; same-Space cancellation resumes layout") {
        var h = Harness()
        h.census(10, [window(1)])
        let old = h.world.frames[TileID(1)]!
        h.send(.spaceWillChange)
        check(h.world.frames.isEmpty, "observation revokes ownership without waiting for census")
        h.send(.frameCompleted(tile: old.tile, revision: old.revision, result: .applied))
        check(h.world.appliedFrames.isEmpty, "already-dequeued stale completion cannot change state")
        h.census(10, [])
        check(h.world.frames[TileID(1)]!.revision > old.revision, "same identity resumes with new write revision despite empty census")
    }
    section("283afe2: logical width survives presets, full width and animation settle") {
        var h = Harness(animate: true)
        h.census(10, [window(1)])
        h.send(.command(.setWidth(TileID(1), 377), .ipc))
        h.send(.tick, advance: 3)
        check(h.world.groups[1]!.strip.columns[0].width == .fixed(377), "settle never writes animated width back to logical intent")
        h.send(.command(.toggleFullWidth(TileID(1)), .ipc))
        check(h.world.groups[1]!.strip.columns[0].width == .fixed(377), "full width preserves prior logical intent")
        check(h.world.groups[1]!.strip.columnData[0].cachedWidth == 1000, "full width derives screen-wide target")
        h.send(.command(.toggleFullWidth(TileID(1)), .ipc))
        check(h.world.groups[1]!.strip.columnData[0].cachedWidth == 377, "leaving full width restores logical target")
        h.send(.command(.cycleWidthPreset, .ipc))
        check(h.world.groups[1]!.strip.columns[0].presetIndex != nil, "preset cycling uses Core width model")
        h.send(.tick, advance: 3)
        check(h.world.check().isEmpty, "width invariants")
    }
    section("IPC replies and focus effects remain data") {
        var h = Harness()
        h.census(10, [window(1), window(2)])
        h.send(.ipc(id: 7, command: .focus(TileID(2))))
        check(h.effects.contains { if case .reply(7, .command(.accepted)) = $0 { return true }; return false }, "command reply correlates request ID")
        check(h.effects.contains { if case .raise(TileID(2)) = $0 { return true }; return false }, "focus emits explicit raise")
        h.send(.query(id: 8))
        check(h.effects.contains {
            if case .reply(8, .snapshots(let snapshots)) = $0 { return snapshots.first?.activeColumnIndex == 1 }
            return false
        }, "query reply contains current immutable snapshot")
        func reply(_ id: UInt64, _ command: Command) -> CommandOutcome? {
            h.send(.ipc(id: id, command: command))
            for case .reply(id, .command(let outcome)) in h.effects { return outcome }
            return nil
        }
        check(reply(9, .focus(TileID(99))) == .unknownWindow(TileID(99)), "unknown window is reported")
        check(reply(10, .setWidth(TileID(1), -4)) == .refused("invalid width"), "invalid width is refused")
        h.send(.command(.toggleFloating(TileID(2)), .ipc))
        check(reply(11, .toggleFullWidth(TileID(2))) == .refused("floating window"), "floating target is refused")
        h.send(.spaceWillChange)
        check(reply(12, .focusLeft) == .refused("space change in progress"), "Space change refuses commands")
        var empty = Harness()
        empty.census(10, [])
        empty.send(.ipc(id: 13, command: .cycleWidthPreset))
        check(empty.effects.contains { if case .reply(13, .command(.refused("empty strip"))) = $0 { return true }; return false },
              "empty strip is refused")
    }
    section("keyboard focus and move paths clamp at both edges") {
        var h = Harness()
        h.census(10, [window(1), window(2), window(3)])
        h.send(.command(.focus(TileID(1)), .keyboard))
        h.send(.command(.focusLeft, .keyboard))
        check(h.active == TileID(1), "focusLeft clamps at the left edge")
        h.send(.command(.focusRight, .keyboard))
        check(h.active == TileID(2), "focusRight moves one column")
        h.send(.command(.focusRight, .keyboard))
        h.send(.command(.focusRight, .keyboard))
        check(h.active == TileID(3), "focusRight clamps at the right edge")
        check(h.effects.contains { if case .focus(TileID(3), .keyboard) = $0 { return true }; return false }, "edge focus re-asserts the window")
        h.send(.command(.moveLeft, .keyboard))
        check(h.tiles == [TileID(1), TileID(3), TileID(2)] && h.active == TileID(3), "moveLeft carries the active column")
        h.send(.command(.moveLeft, .keyboard))
        h.send(.command(.moveLeft, .keyboard))
        check(h.tiles == [TileID(3), TileID(1), TileID(2)], "moveLeft clamps at the left edge")
        h.send(.command(.moveRight, .keyboard))
        check(h.tiles == [TileID(1), TileID(3), TileID(2)] && h.active == TileID(3), "moveRight carries the active column")
        let persisted = h.effects.contains { if case .persist = $0 { return true }; return false }
        check(persisted, "moves persist the new order")
        h.send(.command(.close(TileID(2)), .keyboard))
        check(h.effects.contains { if case .close(TileID(2)) = $0 { return true }; return false }, "close asks the app to close")
        check(h.tiles.contains(TileID(2)), "close waits for the destroyed notification")
        h.send(.windowRemoved(TileID(2)))
        check(h.tiles == [TileID(1), TileID(3)], "destroyed window leaves the strip")
    }
    section("eebb564: menu focus, close and width act on the captured tile") {
        var h = Harness()
        h.census(10, [window(1), window(2)])
        h.send(.pointer(.openMenu(TileID(1))))
        h.send(.pointer(.menu(.focus(TileID(2)))))
        check(h.active == TileID(1), "menu focus targets the captured tile")
        h.send(.pointer(.openMenu(TileID(2))))
        h.send(.pointer(.menu(.close(TileID(1)))))
        check(h.effects.contains { if case .close(TileID(2)) = $0 { return true }; return false }, "menu close targets the captured tile")
        h.send(.pointer(.openMenu(TileID(2))))
        h.send(.pointer(.menu(.cycleWidthPreset)))
        check(h.world.pointer.token == nil && h.world.groups[1]!.strip.columns[1].presetIndex == nil, "strip-wide menu action is ignored")
    }
    section("configChanged and frame routing") {
        var h = Harness()
        h.census(10, [window(1, app: 41), window(2, app: 42)])
        check(h.requests.allSatisfy { $0.pid == Int32($0.tile.rawValue) + 40 }, "frame requests carry the owning pid")
        h.send(.configChanged(EngineConfig(gap: 20, defaultWidth: 0.4, animate: false)))
        check(h.world.config.gap == 20 && h.world.groups[1]!.strip.gap == 20, "config reload reaches the strip")
        check(h.world.groups[1]!.strip.columnData.allSatisfy { $0.cachedWidth == 500 }, "existing columns keep their logical width")
        check(!h.requests.isEmpty, "config reload relayouts")
        h.send(.windowAdded(window(3)))
        check(h.world.groups[1]!.strip.columns.first { $0.tiles == [TileID(3)] }?.width == .proportion(0.4), "new columns use the reloaded width")
        let bad = World(topology: Topology(revision: 4, groups: [DisplayGroup(id: 1, displays: [1], frame: .zero)], primaryScreenHeight: 900))
        check(bad.groups.isEmpty && bad.topology.revision == 4, "zero-size display at launch does not trap")
    }
    section("d227a21: external focus stays quiet through momentum and its settle echo") {
        var h = Harness(animate: true)
        h.census(10, [window(1), window(2), window(3)])
        h.advance(EngineConfig.focusDebounce + margin)
        h.send(.pointer(.beginGesture(TileID(1))))
        h.send(.pointer(.delta(300)))
        h.send(.pointer(.endGesture))
        let landed = h.active
        check(landed != TileID(1), "swipe landed away from the focus target")
        h.send(.focus(FocusIntent(tile: TileID(1), pid: 1, source: .appActivation)))
        h.advance(EngineConfig.focusDebounce + margin)
        check(h.active == landed, "momentum ignores incremental focus")
        h.send(.tick, advance: 3)
        h.send(.focus(FocusIntent(tile: TileID(1), source: .axFocus)))
        h.advance(EngineConfig.focusDebounce + margin)
        check(h.active == landed, "settle echo inside the quiet window is ignored")
        h.advance(EngineConfig.gestureQuiet)
        h.send(.focus(FocusIntent(tile: TileID(1), source: .axFocus)))
        h.advance(EngineConfig.focusDebounce + margin)
        check(h.active == TileID(1), "focus resumes after the quiet window")
    }
    section("554b4ed: disk entries are consumed once and out-of-range presets are cleared") {
        var h = Harness()
        let saved = Snapshot(group: 1, space: .skylight(90), columns: [
            SnapshotColumn(windows: [window(7)], width: .fixed(300), presetIndex: 9),
            SnapshotColumn(windows: [window(8)], width: .fixed(310)),
        ])
        h.send(.loadSnapshots([saved]))
        h.census(10, [window(7), window(8)])
        check(h.world.groups[1]!.strip.columns[0].width == .fixed(300), "disk entry restores")
        check(h.world.groups[1]!.strip.columns[0].presetIndex == nil, "preset index beyond the preset list is cleared")
        check(h.world.spaces.disk.isEmpty, "adopted disk entry is consumed")
        h.send(.command(.cycleWidthPreset, .ipc))
        h.census(20, [window(7, app: 70), window(8, app: 80)].map {
            ObservedWindow(id: TileID($0.id.rawValue + 100), pid: $0.pid, bundleID: $0.bundleID, title: $0.title)
        })
        check(h.world.groups[1]!.strip.columns.allSatisfy { $0.width == .proportion(0.5) }, "a consumed entry cannot be adopted twice")
    }
    section("5753fc0: independent display epochs and invalid input") {
        var h = Harness(displays: [display(), display(2, x: 1000)])
        h.census(10, [window(1)])
        h.census(20, [window(2)], group: 2)
        let second = h.world.scope(for: 2)!
        h.census(30, [window(3)])
        h.send(.command(.setWidth(TileID(2), 222), .ipc), group: 2, scope: second)
        check(h.world.groups[2]!.strip.columns[0].width == .fixed(222), "other display epoch remains valid")
        h.census(40, [window(2)])
        check(h.world.groups[1]!.space == .skylight(30), "foreign group's tile cannot be adopted twice")
        let before = h.world.groups[1]!.strip.columns[0].width
        h.send(.command(.setWidth(TileID(3), .nan), .ipc))
        check(h.world.groups[1]!.strip.columns[0].width == before, "invalid width rejected")
        let oldTime = h.world.time
        let event = Event(scope: h.world.scope(for: 1)!, kind: .windowRemoved(TileID(3)))
        _ = reduce(&h.world, event, now: .nan)
        check(h.world.time == oldTime && h.tiles.contains(TileID(3)), "invalid clock cannot mutate world")
        check(h.world.check().isEmpty, "display isolation invariants")
    }
}

@MainActor func probeTests() {
    section("Space census: an empty destination commits after its settle re-read") {
        var h = Harness()
        h.census(10, [window(1), window(2)])
        h.census(30, [])
        check(h.censusRequest.map { abs($0 - EngineConfig.censusSettle) < 1e-9 } == true,
              "deferred empty census requests a settled re-read")
        h.advance(EngineConfig.censusSettle + margin)
        h.census(30, [])
        check(h.world.groups[1]!.space == .skylight(30), "confirmed empty census commits")
        h.send(.windowAdded(window(5)))
        check(h.tiles == [TileID(5)], "window opened on the empty Space joins its own strip")
        h.census(10, [window(1), window(2)])
        check(h.tiles == [TileID(1), TileID(2)], "departing Space keeps its own columns")
        h.send(.spaceWillChange)
        h.census(40, [])
        h.advance(EngineConfig.censusSettle + margin)
        h.census(40, [])
        h.send(.windowAdded(window(6)))
        check(h.tiles == [TileID(6)], "observed empty switch does not freeze the group")
    }
    section("Space census: same-Space resolution applies windows added and destroyed mid-transition") {
        var h = Harness()
        h.census(10, [window(1), window(2)])
        h.send(.spaceWillChange)
        h.send(.windowAdded(window(5)))
        h.send(.windowRemoved(TileID(2)))
        h.send(.spaceChanged(key: .skylight(10), epoch: h.world.groups[1]!.epoch + 1, windows: [window(1), window(5)]))
        check(Set(h.tiles) == [TileID(1), TileID(5)], "census membership wins after a same-Space transition")
        check(h.world.frames[TileID(2)] == nil, "destroyed window loses its frame ownership")
    }
    section("Space identity: fingerprint recovery re-keys the authoritative stash") {
        var h = Harness()
        h.census(10, [window(1), window(2), window(3)])
        h.census(20, [window(4)])
        h.send(.spaceChanged(key: .fingerprint([1, 2, 3]), epoch: h.world.groups[1]!.epoch + 1,
                             windows: [window(1), window(2), window(3)]))
        h.send(.command(.setWidth(TileID(1), 311), .ipc))
        h.send(.command(.focus(TileID(1)), .ipc))
        h.send(.command(.moveRight, .ipc))
        check(h.world.spaces.lookupExact(group: 1, space: .skylight(10)) == nil, "recovered sid entry moved to the fingerprint key")
        h.census(20, [window(4)])
        h.census(10, [window(1), window(2), window(3)])
        check(h.tiles == [TileID(2), TileID(1), TileID(3)], "returning sid restores order edited while degraded")
        check(h.world.groups[1]!.strip.columns[1].width == .fixed(311), "returning sid restores width edited while degraded")
    }
    section("Snapshot identity: disk restore matches window identity, not recycled ids") {
        var h = Harness()
        let saved = Snapshot(group: 1, space: .skylight(90), columns: [
            SnapshotColumn(windows: [window(7, bundle: "safari")], width: .fixed(300)),
            SnapshotColumn(windows: [window(8, bundle: "term")], width: .proportion(0.5)),
            SnapshotColumn(windows: [window(9, bundle: "mail")], width: .proportion(0.5)),
        ])
        h.send(.loadSnapshots([saved]))
        h.census(91, [ObservedWindow(id: TileID(7), pid: 2, bundleID: "term", title: "window-8"),
                      ObservedWindow(id: TileID(8), pid: 1, bundleID: "safari", title: "window-7"),
                      ObservedWindow(id: TileID(9), pid: 3, bundleID: "mail", title: "window-9")])
        check(h.tiles == [TileID(8), TileID(7), TileID(9)], "order follows identity")
        check(h.world.groups[1]!.strip.columns.first { $0.tiles == [TileID(8)] }?.width == .fixed(300), "width follows identity")
    }
    section("Snapshot identity: persist keeps unvisited disk Spaces") {
        var h = Harness()
        let unvisited = Snapshot(group: 1, space: .skylight(99), columns: [SnapshotColumn(windows: [window(50, bundle: "other.app")], width: .fixed(400))])
        h.send(.loadSnapshots([unvisited]))
        h.census(10, [window(1)])
        let payload: [Snapshot] = h.effects.compactMap { effect -> [Snapshot]? in if case .persist(let book) = effect { return book.persisted }; return nil }.last ?? []
        check(payload.map { $0.space } == [.skylight(10), .skylight(99)], "persist payload carries unvisited disk entries")
    }
    section("Snapshot codec: a negative preset index is rejected") {
        let bad = Snapshot(group: 1, space: .skylight(1), columns: [SnapshotColumn(windows: [window(1)], width: .fixed(300), presetIndex: -5)])
        let decoded = (try? Snapshot.decode(Snapshot.encode([bad]))) ?? []
        check(decoded.isEmpty, "negative preset index rejected")
    }
    section("Gesture basis: releases clamp and re-anchor the active column") {
        var free = Harness(gestureSnap: false)
        free.census(10, [window(1), window(2)])
        free.send(.pointer(.beginGesture(TileID(1))))
        free.send(.pointer(.delta(50_000)))
        free.send(.pointer(.endGesture))
        let bounds = free.world.groups[1]!.strip.viewOffsetBounds(at: free.time)
        check(bounds.contains(free.offset), "free scroll stays inside view bounds")
        var snapped = Harness()
        snapped.census(10, [window(1), window(2), window(3), window(4)])
        snapped.send(.command(.focus(TileID(1)), .ipc))
        snapped.send(.pointer(.beginGesture(TileID(1))))
        snapped.send(.pointer(.delta(1_500)))
        snapped.send(.pointer(.endGesture))
        check(snapped.world.groups[1]!.strip.activeColumnIndex == 3, "snapped swipe moves the active column")
        check(abs(snapped.offset - snapped.world.groups[1]!.strip.snapTarget(forColumn: 3, at: snapped.time)) < 0.001,
              "release rests on the landed column's snap point")
        snapped.send(.command(.focusLeft, .ipc))
        check(snapped.active == TileID(3), "next focus continues from the landed column")
    }
    section("Gesture latch: external focus cannot kill a swipe") {
        var h = Harness()
        h.census(10, [window(1), window(2), window(3)])
        h.advance(EngineConfig.focusDebounce + margin)
        h.send(.pointer(.beginGesture(TileID(1))))
        let start = h.offset
        h.send(.pointer(.delta(40)))
        h.send(.focus(FocusIntent(tile: TileID(3), pid: 3, source: .appActivation)))
        h.send(.focus(FocusIntent(tile: TileID(3), source: .axFocus)))
        h.advance(EngineConfig.focusDebounce + margin)
        check(h.gesture != nil, "swipe survives external focus")
        h.send(.pointer(.delta(40)))
        check(abs(h.offset - start - 80) < 0.001, "later deltas still apply")
    }
    section("Space census: a same-Space read listing another Space's windows is not trusted") {
        var h = Harness()
        h.census(10, [window(1), window(2)])
        h.send(.command(.setWidth(TileID(1), 377), .ipc))
        h.census(20, [window(3), window(4)])
        h.census(10, [window(1), window(2)])
        h.send(.spaceChanged(key: .skylight(10), epoch: h.world.groups[1]!.epoch + 1, windows: [window(3), window(4)]))
        check(h.tiles == [TileID(1), TileID(2)], "stale census keeps the live strip")
        check(!h.requests.contains { [TileID(3), TileID(4)].contains($0.tile) }, "no frames for another Space's windows")
        check(h.world.spaces.lookupExact(group: 1, space: .skylight(20))?.windows.map(\.id) == [TileID(3), TileID(4)],
              "other Space's stash untouched")
        h.census(20, [window(3), window(4)])
        h.census(10, [window(1), window(2)])
        check(h.world.groups[1]!.strip.columns[0].width == .fixed(377), "returning Space keeps its width")
    }
    section("Space census: a same-Space partial read does not infer destruction") {
        var h = Harness()
        h.census(10, [window(1), window(2), window(3)])
        h.send(.command(.setWidth(TileID(2), 377), .ipc))
        h.census(20, [window(4)])
        h.census(10, [window(1), window(2), window(3)])
        h.send(.spaceChanged(key: .skylight(10), epoch: h.world.groups[1]!.epoch + 1, windows: [window(1)]))
        check(h.tiles == [TileID(1), TileID(2), TileID(3)], "absent windows stay managed")
        check(h.world.groups[1]!.strip.columns.first { $0.tiles == [TileID(2)] }?.width == .fixed(377), "absent window keeps its width")
        h.send(.spaceWillChange)
        h.send(.windowRemoved(TileID(3)))
        h.send(.spaceChanged(key: .skylight(10), epoch: h.world.groups[1]!.epoch + 1, windows: [window(1), window(2)]))
        check(h.tiles == [TileID(1), TileID(2)], "destruction observed mid-transition still applies")
    }
    section("Space census: invalid windows are dropped, not the whole read") {
        var h = Harness()
        let flat = ObservedWindow(id: TileID(2), pid: 2, bundleID: "test.app", initialFrame: AXRect(CGRect(x: 0, y: 0, width: 0, height: 0)))
        h.census(10, [window(1), flat])
        check(h.world.groups[1]!.space == .skylight(10) && h.tiles == [TileID(1)], "first census commits without the invalid window")
        check(h.effects.contains { if case .log(let line) = $0 { return line.contains("census window dropped") }; return false },
              "dropped window is logged")
    }
    section("Space census: foreign-owned windows are dropped, not the whole read") {
        var h = Harness(displays: [display(), display(2, x: 1000)])
        h.census(10, [window(1)])
        h.census(20, [window(2)], group: 2)
        h.census(30, [window(2), window(5)])
        check(h.world.groups[1]!.space == .skylight(30) && h.tiles == [TileID(5)], "switch commits without the foreign window")
        h.send(.windowAdded(window(6)))
        check(h.world.spaces.lookupExact(group: 1, space: .skylight(10))?.windows.map(\.id) == [TileID(1)],
              "new window does not join the departed Space")
    }
    section("Space census: a group's first bad read is dropped after one settle") {
        var h = Harness()
        h.census(10, [window(1), window(1)])
        check(h.censusRequest != nil, "duplicate census deferred")
        h.advance(EngineConfig.censusSettle + margin)
        h.census(10, [window(1), window(1)])
        check(h.censusRequest == nil, "settled duplicate read is dropped")
        h.census(10, [window(1)])
        check(h.world.groups[1]!.space == .skylight(10) && h.tiles == [TileID(1)], "next good read commits")
    }
    section("Snapshot identity: disk restore survives title churn") {
        func titled(_ id: UInt32, _ bundle: String, _ title: String, x: Double = 0) -> ObservedWindow {
            ObservedWindow(id: TileID(id), pid: 1, bundleID: bundle, title: title, initialFrame: AXRect(CGRect(x: x, y: 30, width: 350, height: 600)))
        }
        var h = Harness()
        h.send(.loadSnapshots([Snapshot(group: 1, space: .skylight(90), columns: [
            SnapshotColumn(windows: [titled(7, "safari", "Apple")], width: .fixed(300)),
            SnapshotColumn(windows: [titled(8, "term", "zsh")], width: .proportion(0.5)),
            SnapshotColumn(windows: [titled(9, "mail", "Inbox (3)")], width: .proportion(0.5)),
        ])]))
        h.census(91, [titled(20, "term", "vim"), titled(21, "safari", "Google", x: 500), titled(22, "mail", "Inbox (4)", x: 900)])
        check(h.tiles == [TileID(21), TileID(20), TileID(22)], "changed titles keep the saved order")
        check(h.world.groups[1]!.strip.columns[0].width == .fixed(300), "changed titles keep the saved width")
        var restart = Harness()
        restart.send(.loadSnapshots([Snapshot(group: 1, space: .skylight(90), columns: [
            SnapshotColumn(windows: [titled(9, "term", "a")], width: .fixed(300)),
            SnapshotColumn(windows: [titled(8, "term", "b")], width: .fixed(500)),
        ])]))
        restart.census(90, [titled(8, "term", "c"), titled(9, "term", "d", x: 500)])
        check(restart.tiles == [TileID(9), TileID(8)], "window id guarded by bundle wins over bundle alone")
        var recycled = Harness()
        recycled.send(.loadSnapshots([Snapshot(group: 1, space: .skylight(90), columns: [
            SnapshotColumn(windows: [titled(1, "term", "x")], width: .fixed(300)),
            SnapshotColumn(windows: [titled(2, "term", "y")], width: .fixed(500)),
        ])]))
        recycled.census(91, [titled(30, "term", "y"), titled(31, "term", "z", x: 500)])
        check(recycled.tiles == [TileID(31), TileID(30)], "a title match wins over an earlier slot's bundle match")
        check(recycled.world.groups[1]!.strip.columns[1].width == .fixed(500), "title match keeps its slot width")
    }
    section("Snapshot identity: known window title changes reach the stash") {
        var h = Harness()
        h.census(10, [window(1)])
        h.send(.windowChanged(ObservedWindow(id: TileID(1), pid: 1, bundleID: "test.app", title: "renamed")))
        check(h.world.spaces.lookupExact(group: 1, space: .skylight(10))?.windows.first?.title == "renamed", "windowChanged refreshes the title")
        h.send(.spaceChanged(key: .skylight(10), epoch: h.world.groups[1]!.epoch + 1,
                             windows: [ObservedWindow(id: TileID(1), pid: 1, bundleID: "test.app", title: "census")]))
        check(h.world.spaces.lookupExact(group: 1, space: .skylight(10))?.windows.first?.title == "census", "same-Space census refreshes the title")
        let reused = h.send(.windowAdded(window(1, app: 99)))
        check(reused.contains { if case .log(let line) = $0 { return line.contains("identity changed") }; return false },
              "a known id with a different owner is logged")
        check(h.world.groups[1]!.windows[TileID(1)]?.pid == 1, "a known id with a different owner is not refreshed")
        h.send(.windowChanged(window(1, app: 77)))
        check(h.world.groups[1]!.windows[TileID(1)]?.pid == 1, "windowChanged with a different owner does not refresh the live window")
        h.send(.windowChanged(h.world.groups[1]!.windows[TileID(1)]!))
        check(!h.persisted, "an unchanged window is not persisted")
    }
    section("Space census: in fingerprint mode an empty Space commits after its settle re-read") {
        var h = Harness()
        func fingerprint(_ ids: Set<UInt32>, _ windows: [ObservedWindow]) {
            h.send(.spaceChanged(key: .fingerprint(ids), epoch: h.world.groups[1]!.epoch + 1, windows: windows))
        }
        fingerprint([1, 2], [window(1), window(2)])
        h.send(.spaceWillChange)
        fingerprint([], [])
        check(h.censusRequest != nil, "empty fingerprint census deferred")
        h.advance(EngineConfig.censusSettle + margin)
        fingerprint([], [])
        check(h.world.groups[1]!.space == .fingerprint([]) && !h.world.groups[1]!.phase.isChanging, "settled empty re-read commits")
        h.send(.windowAdded(window(5)))
        check(h.tiles == [TileID(5)], "window opened on the empty Space joins its own strip")
        h.send(.windowAdded(window(6)))
        h.send(.command(.moveLeft, .ipc))
        h.send(.command(.setWidth(TileID(5), 377), .ipc))
        check(h.tiles == [TileID(6), TileID(5)], "windows rearranged on the formerly empty Space")
        fingerprint([1, 2], [window(1), window(2)])
        check(h.tiles == [TileID(1), TileID(2)], "departing Space keeps its own columns")
        check(!h.world.spaces.live.keys.contains { $0.space.isEmpty }, "never stashed under an empty key")
        fingerprint([5, 6], [window(5), window(6)])
        check(h.tiles == [TileID(6), TileID(5)] && h.widths.last == .fixed(377), "the formerly empty Space restores its order and width")
    }
    section("Gesture latch: external focus during a swipe records the decision without scrolling") {
        var h = Harness()
        h.census(20, [window(3, app: 30), window(4, app: 40)])
        h.send(.command(.focus(TileID(4)), .ipc))
        h.census(10, [window(1, app: 10), window(2, app: 20)])
        h.advance(EngineConfig.focusDebounce + margin)
        h.send(.pointer(.beginGesture(TileID(1))))
        h.send(.pointer(.delta(40)))
        let offset = h.offset
        h.send(.focus(FocusIntent(tile: TileID(2), source: .axFocus)))
        h.advance(EngineConfig.focusDebounce + margin)
        check(h.world.groups[1]!.focus.decision?.tile == TileID(2), "AX focus during a swipe is recorded")
        check(h.gesture != nil && h.offset == offset, "recorded focus does not scroll the swipe")
        h.send(.pointer(.endGesture))
        h.send(.focus(FocusIntent(tile: TileID(3), pid: 30, source: .appActivation)))
        h.census(20, [window(3, app: 30), window(4, app: 40)])
        check(h.active == TileID(3), "dock click during momentum still crosses Spaces")
    }
    section("Gesture basis: removing a window mid-swipe ends the gesture") {
        var h = Harness()
        h.census(10, [window(1), window(2), window(3)])
        h.send(.pointer(.beginGesture(TileID(1))))
        h.send(.pointer(.delta(40)))
        h.send(.windowRemoved(TileID(3)))
        check(h.tiles.count == 2 && h.gesture == nil, "stale snap basis cannot survive a removed column")
    }
    section("Gesture basis: adding a window mid-swipe ends the gesture") {
        var h = Harness()
        h.census(10, [window(1), window(2), window(3)])
        h.send(.pointer(.beginGesture(TileID(1))))
        h.send(.pointer(.delta(40)))
        h.send(.spaceChanged(key: .skylight(10), epoch: h.world.groups[1]!.epoch + 1, windows: [window(1), window(2), window(3), window(4)]))
        check(h.tiles.count == 4 && h.gesture == nil, "stale snap basis cannot survive an added column")
    }
    section("Snapshot identity: strong window-id evidence beats a closer app set on disk") {
        func saved(_ id: UInt32, _ bundle: String) -> ObservedWindow {
            ObservedWindow(id: TileID(id), pid: 1, bundleID: bundle, title: "t\(id)")
        }
        var h = Harness()
        h.send(.loadSnapshots([
            Snapshot(group: 1, space: .skylight(1), columns: [
                SnapshotColumn(windows: [saved(11, "safari")], width: .fixed(111)),
                SnapshotColumn(windows: [saved(12, "term")], width: .fixed(112)),
            ]),
            Snapshot(group: 1, space: .skylight(2), columns: [
                SnapshotColumn(windows: [saved(23, "mail")], width: .fixed(223)),
                SnapshotColumn(windows: [saved(22, "term")], width: .fixed(222)),
                SnapshotColumn(windows: [saved(21, "safari")], width: .fixed(221)),
            ]),
        ]))
        h.census(2, [saved(21, "safari"), saved(22, "term")])
        check(h.tiles == [TileID(22), TileID(21)] && h.widths == [.fixed(222), .fixed(221)], "a Space missing one window keeps its own layout")
        h.census(1, [saved(11, "safari"), saved(12, "term")])
        check(h.tiles == [TileID(11), TileID(12)] && h.widths == [.fixed(111), .fixed(112)], "the other Space keeps its own layout")
    }
    section("Snapshot identity: window ids pick between disk entries with the same apps") {
        func saved(_ id: UInt32) -> ObservedWindow { ObservedWindow(id: TileID(id), pid: 1, bundleID: "term", title: "t\(id)") }
        var h = Harness()
        h.send(.loadSnapshots([
            Snapshot(group: 1, space: .skylight(90), columns: [
                SnapshotColumn(windows: [saved(1)], width: .fixed(300)), SnapshotColumn(windows: [saved(2)], width: .fixed(500)),
            ]),
            Snapshot(group: 1, space: .skylight(91), columns: [
                SnapshotColumn(windows: [saved(3)], width: .fixed(700)), SnapshotColumn(windows: [saved(4)], width: .fixed(800)),
            ]),
        ]))
        h.census(5, [saved(4), saved(3)])
        check(h.tiles == [TileID(3), TileID(4)] && h.widths == [.fixed(700), .fixed(800)], "the entry sharing window ids is adopted")
        check(h.world.spaces.disk.map(\.space) == [.skylight(90)], "the other entry stays on disk")
    }
    section("Snapshot identity: windows without a bundle do not take each other's disk slots") {
        func saved(_ id: UInt32, _ bundle: String?, _ title: String) -> ObservedWindow {
            ObservedWindow(id: TileID(id), pid: 1, bundleID: bundle, title: title)
        }
        var h = Harness()
        h.send(.loadSnapshots([Snapshot(group: 1, space: .skylight(90), columns: [
            SnapshotColumn(windows: [saved(1, "safari", "a")], width: .fixed(300)),
            SnapshotColumn(windows: [saved(2, nil, "x")], width: .fixed(377)),
        ])]))
        h.census(91, [saved(10, "safari", "b"), saved(11, nil, "zzz")])
        check(h.widths.first == .fixed(300), "the bundled window still restores")
        check(!h.widths.contains(.fixed(377)), "an unrelated bundle-less window does not inherit a slot")
    }
    section("Snapshot identity: a title change for a stashed window does not adopt it, even from an old scope") {
        var h = Harness()
        h.census(20, [window(3), window(4)])
        let old = h.world.scope(for: 1)!
        h.census(10, [window(1), window(2)])
        let focused = h.world.groups[1]!.focus.decision?.tile
        let effects = h.send(.windowChanged(ObservedWindow(id: TileID(3), pid: 3, bundleID: "test.app", title: "renamed")), scope: old)
        check(h.persisted, "a refreshed stash is persisted")
        check(h.tiles == [TileID(1), TileID(2)] && h.world.groups[1]!.focus.decision?.tile == focused, "stashed window stays on its Space")
        check(!effects.contains { if case .focus = $0 { return true }; if case .raise = $0 { return true }; return false },
              "stashed window is neither focused nor raised")
        check(h.world.spaces.lookupExact(group: 1, space: .skylight(20))?.windows.first?.title == "renamed", "the stash gets the new title")
        h.send(.windowChanged(ObservedWindow(id: TileID(3), pid: 99, bundleID: "test.app", title: "reused")))
        check(h.logged("identity changed tile=3"), "a stashed id with a different owner is logged")
        check(!h.persisted, "nothing refreshed, nothing persisted")
        check(h.world.spaces.lookupExact(group: 1, space: .skylight(20))?.windows.first?.title == "renamed",
              "a stashed id with a different owner is not refreshed")
    }
    section("Snapshot identity: closing a window prunes live stashes and leaves disk ids alone") {
        var h = Harness()
        h.send(.loadSnapshots([Snapshot(group: 1, space: .skylight(90), columns: [
            SnapshotColumn(windows: [window(1, bundle: "safari")], width: .fixed(311)),
            SnapshotColumn(windows: [window(2, bundle: "mail")], width: .fixed(422)),
        ])]))
        h.census(10, [window(1), window(2)])
        h.census(20, [window(3)])
        h.send(.windowRemoved(TileID(2)))
        check(h.stash(10) == [TileID(1)], "closed window leaves its stash")
        h.census(10, [window(1)])
        h.send(.windowRemoved(TileID(1)))
        check(h.world.spaces.disk.first?.windows.count == 2, "a reused id cannot erase another app's disk slot")
    }
    section("Space census: a deferral for one Space does not settle another") {
        var h = Harness()
        h.census(10, [window(1), window(2)])
        h.census(20, [window(3), window(4)])
        h.census(30, [window(1), window(3)])
        h.advance(EngineConfig.censusSettle + margin)
        h.census(40, [window(1), window(3)])
        check(h.censusRequest.map { abs($0 - EngineConfig.censusSettle) < 1e-9 } == true, "a new Space's first mixed read gets its own settle")
    }
    section("Space census: in fingerprint mode a same-Space read skips only windows stashed on another Space") {
        var h = Harness()
        func fingerprint(_ ids: Set<UInt32>, _ windows: [ObservedWindow]) {
            h.send(.spaceChanged(key: .fingerprint(ids), epoch: h.world.groups[1]!.epoch + 1, windows: windows))
        }
        fingerprint([3, 4], [window(3), window(4)])
        fingerprint([1], [window(1)])
        fingerprint([1], [window(3), window(5)])
        check(h.tiles == [TileID(1), TileID(5)], "the new window joins and the stashed one does not")
        check(h.logged("skipped windows stashed elsewhere"), "the skip is logged")
    }
    section("Moved windows: windowAdded moves a window out of another Space's stash") {
        var h = Harness()
        h.census(20, [window(3), window(4)])
        h.census(10, [window(1), window(2)])
        h.send(.windowAdded(window(3)))
        check(h.tiles.contains(TileID(3)) && h.active == TileID(3), "the added window is tiled and focused")
        check(h.stash(20) == [TileID(4)], "the old Space's stash lets it go")
        h.census(10, [window(1), window(2), window(3)])
        check(h.world.groups[1]!.space == .skylight(10) && h.tiles.count == 3, "the next census of this Space is trusted")
        h.send(.spaceWillChange)
        h.census(30, [window(5)])
        h.census(10, [window(1), window(2), window(3)])
        check(h.world.groups[1]!.space == .skylight(10), "returning to the Space commits it")
    }
    section("Moved windows: a mixed read that survives the settle re-read commits under a Space id") {
        var h = Harness()
        h.census(10, [window(1), window(2)])
        h.census(20, [window(3), window(4)])
        h.send(.spaceWillChange)
        h.census(10, [window(1), window(2), window(3)])
        check(h.world.groups[1]!.space == .skylight(20) && h.censusRequest != nil, "one mixed read is deferred")
        h.advance(EngineConfig.censusSettle + margin)
        h.census(10, [window(1), window(2), window(3)])
        check(h.world.groups[1]!.space == .skylight(10) && Set(h.tiles) == [TileID(1), TileID(2), TileID(3)], "the settled read commits")
        h.census(20, [window(4)])
        check(h.world.groups[1]!.space == .skylight(20) && h.tiles == [TileID(4)], "visiting the old Space shows the rest")
        h.census(10, [window(1), window(2), window(3)])
        check(h.world.groups[1]!.space == .skylight(10) && h.tiles.count == 3, "returning is a clean commit")
        check(h.stash(20) == [TileID(4)], "the visit healed the old Space's stash")
    }
    section("Moved windows: a same-Space read listing a stashed window re-reads, then moves it") {
        var h = Harness()
        h.census(20, [window(3), window(4)])
        h.census(10, [window(1), window(2)])
        let read = [window(1), window(2), window(3), window(9)]
        h.send(.spaceChanged(key: .skylight(10), epoch: h.world.groups[1]!.epoch + 1, windows: read))
        check(h.tiles == [TileID(1), TileID(2)] && h.censusRequest != nil, "one read is not enough to move a window")
        h.advance(EngineConfig.censusSettle + margin)
        h.send(.spaceChanged(key: .skylight(10), epoch: h.world.groups[1]!.epoch + 1, windows: read))
        check(Set(h.tiles) == [TileID(1), TileID(2), TileID(3), TileID(9)], "the settled read adopts the moved and the new window")
        h.census(20, [window(4)])
        check(h.world.groups[1]!.space == .skylight(20) && h.tiles == [TileID(4)], "visiting the old Space shows the rest")
    }
    section("Moved windows: a stale same-Space read repeated past the settle costs gaps, not another Space's layout") {
        var h = Harness()
        h.census(20, [window(3), window(4)])
        h.send(.command(.setWidth(TileID(3), 333), .ipc))
        h.census(10, [window(1), window(2)])
        let stale = [window(3), window(4)]
        h.send(.spaceChanged(key: .skylight(10), epoch: h.world.groups[1]!.epoch + 1, windows: stale))
        h.advance(EngineConfig.censusSettle + margin)
        h.send(.spaceChanged(key: .skylight(10), epoch: h.world.groups[1]!.epoch + 1, windows: stale))
        h.census(20, [window(3), window(4)])
        check(h.tiles == [TileID(3), TileID(4)] && h.widths.first == .fixed(333), "Space 20 keeps its layout")
        h.census(10, [window(1), window(2)])
        check(h.world.groups[1]!.space == .skylight(10) && h.tiles == [TileID(1), TileID(2)], "Space 10 heals on its next visit")
    }
    section("Moved windows: a window on all desktops costs at most one deferral") {
        var h = Harness()
        h.census(10, [window(1), window(2)])
        h.census(20, [window(3), window(4)])
        h.send(.windowAdded(window(9)))
        let switches: [(UInt64, [UInt32])] = [(10, [1, 2, 9]), (20, [3, 4, 9])]
        var deferrals = 0
        for step in 0..<6 {
            let (space, ids) = switches[step % 2]
            h.census(space, ids.map { window($0) })
            if h.censusRequest != nil {
                deferrals += 1
                h.advance(EngineConfig.censusSettle + margin)
                h.census(space, ids.map { window($0) })
            }
            check(h.world.groups[1]!.space == .skylight(space) && Set(h.tiles) == Set(ids.map(TileID.init)), "switch \(step) lands on \(space)")
        }
        check(deferrals <= 1, "at most one deferral across six switches, got \(deferrals)")
    }
    section("Moved windows: windowAdded for a known window leaves other Spaces alone") {
        var h = Harness()
        h.census(10, [window(1), window(2), window(9)])
        h.census(20, [window(3), window(4), window(9)])
        let effects = h.send(.windowAdded(window(9)))
        check(!effects.contains { if case .focus = $0 { return true }; if case .raise = $0 { return true }; return false },
              "a known window is not focused again")
        h.send(.windowAdded(window(9, app: 99)))
        check(h.stash(10)?.contains(TileID(9)) == true, "the other Space keeps the window")
        h.census(10, [window(1), window(2), window(9)])
        check(h.world.groups[1]!.space == .skylight(10) && h.censusRequest == nil, "the next switch is not deferred")
    }
    section("Moved windows: a same-Space read of windows already here is not held") {
        var h = Harness()
        h.census(20, [window(5), window(9)])
        h.census(30, [window(6), window(8)])
        let here = [window(1), window(2), window(8), window(9)]
        h.census(10, here)
        h.advance(EngineConfig.censusSettle + margin)
        h.census(10, here)
        check(h.world.groups[1]!.space == .skylight(10), "the settled read commits")
        h.send(.spaceChanged(key: .skylight(10), epoch: h.world.groups[1]!.epoch + 1, windows: here))
        check(h.censusRequest == nil && !h.world.groups[1]!.phase.isChanging, "nothing can move, so nothing is held")
        h.send(.spaceChanged(key: .skylight(10), epoch: h.world.groups[1]!.epoch + 1, windows: here + [window(7)]))
        check(h.tiles.contains(TileID(7)), "a new window in a mixed same-Space read joins")
    }
    section("Moved windows: a same-Space hold keeps the swipe") {
        var h = Harness()
        h.census(20, [window(3), window(4)])
        h.census(10, [window(1), window(2)])
        h.advance(EngineConfig.focusDebounce + margin)
        h.send(.pointer(.beginGesture(TileID(1))))
        h.send(.pointer(.delta(40)))
        h.send(.spaceChanged(key: .skylight(10), epoch: h.world.groups[1]!.epoch + 1, windows: [window(1), window(2), window(3)]))
        check(h.censusRequest != nil && h.gesture != nil, "the deferral keeps the swipe")
        h.send(.windowAdded(window(8)))
        check(h.logged("window add dropped during space change tile=8"), "a dropped windowAdded is logged")
        h.advance(EngineConfig.censusSettle + margin)
        h.send(.spaceChanged(key: .skylight(10), epoch: h.world.groups[1]!.epoch + 1, windows: [window(1), window(2)]))
        check(h.tiles == [TileID(1), TileID(2)] && h.gesture != nil, "a re-read that changes nothing keeps the swipe")
    }
    section("Moved windows: focus lands during a same-Space hold") {
        var h = Harness()
        h.census(20, [window(3), window(4)])
        h.census(10, [window(1), window(2)])
        h.advance(EngineConfig.focusDebounce + margin)
        h.send(.focus(FocusIntent(tile: TileID(2), source: .axFocus)))
        h.send(.spaceChanged(key: .skylight(10), epoch: h.world.groups[1]!.epoch + 1, windows: [window(1), window(2), window(3)]))
        h.advance(EngineConfig.focusDebounce + margin)
        check(h.world.groups[1]!.phase.isChanging && h.world.groups[1]!.focus.decision?.tile == TileID(2),
              "focus queued before the hold lands inside it")
        h.send(.focus(FocusIntent(tile: TileID(1), source: .axFocus)))
        h.advance(EngineConfig.focusDebounce + margin)
        check(h.world.groups[1]!.phase.isChanging && h.world.groups[1]!.focus.decision?.tile == TileID(1),
              "focus observed during the hold lands")
        h.advance(EngineConfig.censusSettle)
        h.send(.spaceChanged(key: .skylight(10), epoch: h.world.groups[1]!.epoch + 1, windows: [window(1), window(2)]))
        check(!h.world.groups[1]!.phase.isChanging && h.world.groups[1]!.focus.decision?.tile == TileID(1), "the re-read keeps it")
    }
    section("c9d3e80: a real Space change during a same-Space hold still drops focus echoes") {
        var h = Harness()
        h.census(20, [window(3), window(4)])
        h.census(10, [window(1), window(2)])
        h.send(.command(.focus(TileID(2)), .keyboard))
        h.advance(EngineConfig.focusDebounce + margin)
        h.send(.spaceChanged(key: .skylight(10), epoch: h.world.groups[1]!.epoch + 1, windows: [window(1), window(2), window(3)]))
        check(h.censusRequest != nil, "the read opens a same-Space hold")
        h.send(.spaceWillChange)
        h.send(.focus(FocusIntent(tile: TileID(1), source: .axFocus)))
        h.advance(EngineConfig.focusDebounce + margin)
        check(h.world.groups[1]!.focus.decision?.tile == TileID(2), "the echo is dropped once the real change starts")
        h.census(20, [window(3), window(4)])
        h.census(10, [window(1), window(2)])
        check(h.active == TileID(2), "Space 10 restores its own focus")
        check(h.world.check().isEmpty, "hold invariants")
    }
    section("c9d3e80: a same-Space read after spaceWillChange does not reopen focus") {
        var h = Harness()
        h.census(20, [window(3), window(4)])
        h.census(10, [window(1), window(2)])
        h.send(.command(.focus(TileID(1)), .keyboard))
        h.advance(EngineConfig.focusDebounce + margin)
        h.send(.spaceWillChange)
        h.send(.spaceChanged(key: .skylight(10), epoch: h.world.groups[1]!.epoch + 1, windows: [window(1), window(2), window(3)]))
        check(h.censusRequest != nil, "the read is deferred")
        h.send(.focus(FocusIntent(tile: TileID(2), source: .axFocus)))
        h.advance(EngineConfig.focusDebounce + margin)
        check(h.world.groups[1]!.focus.decision?.tile == TileID(1), "a torn-down group drops the echo")
        h.census(20, [window(3), window(4)])
        h.census(10, [window(1), window(2)])
        check(h.active == TileID(1), "Space 10 restores its own focus")
    }
    section("Moved windows: spaceWillChange during a hold keeps the settle clock") {
        var h = Harness()
        h.census(20, [window(3), window(4)])
        h.census(10, [window(1), window(2)])
        let moved = [window(1), window(2), window(3)]
        h.send(.spaceChanged(key: .skylight(10), epoch: h.world.groups[1]!.epoch + 1, windows: moved))
        for _ in 0..<2 {
            h.advance(EngineConfig.censusSettle * 0.6)
            h.send(.spaceWillChange)
            h.send(.spaceChanged(key: .skylight(10), epoch: h.world.groups[1]!.epoch + 1, windows: moved))
        }
        check(!h.world.groups[1]!.phase.isChanging && h.tiles.contains(TileID(3)), "the re-read settles on the original clock")
    }
    section("Moved windows: a cross-Space deferral after a same-Space hold tears down the swipe") {
        var h = Harness()
        h.census(20, [window(3), window(4)])
        h.census(10, [window(1), window(2)])
        h.send(.command(.focus(TileID(2)), .keyboard))
        h.advance(EngineConfig.focusDebounce + margin)
        h.send(.pointer(.beginGesture(TileID(1))))
        h.send(.pointer(.delta(40)))
        h.send(.spaceChanged(key: .skylight(10), epoch: h.world.groups[1]!.epoch + 1, windows: [window(1), window(2), window(3)]))
        check(h.gesture != nil, "the hold keeps the swipe")
        h.census(30, [window(1), window(3)])
        check(h.censusRequest != nil && h.world.groups[1]!.space == .skylight(10), "the mixed read for Space 30 is deferred")
        check(h.gesture == nil && h.world.frames.isEmpty, "the cross-Space deferral cancels the swipe and invalidates frames")
        h.send(.focus(FocusIntent(tile: TileID(1), source: .axFocus)))
        h.advance(EngineConfig.focusDebounce + margin)
        check(h.world.groups[1]!.focus.decision?.tile == TileID(2), "a cross-Space deferral drops AX focus")
        check(h.world.check().isEmpty, "hold invariants")
    }
    section("Moved windows: TODO(R4) fingerprint mode cannot tell a moved window from a stale read") {
        var h = Harness()
        func fingerprint(_ ids: Set<UInt32>, _ windows: [ObservedWindow]) {
            h.send(.spaceChanged(key: .fingerprint(ids), epoch: h.world.groups[1]!.epoch + 1, windows: windows))
        }
        fingerprint([1, 2], [window(1), window(2)])
        fingerprint([3, 4], [window(3), window(4)])
        h.send(.spaceWillChange)
        fingerprint([1, 2, 3], [window(1), window(2), window(3)])
        h.advance(EngineConfig.censusSettle + margin)
        fingerprint([1, 2, 3], [window(1), window(2), window(3)])
        check(h.world.groups[1]!.space == .fingerprint([3, 4]), "pinned: the group stays on the old Space until R4 resolves this")
    }
    section("Moved windows: another display's stash counts as another Space") {
        var h = Harness(displays: [display(), display(2, x: 1000)])
        h.census(50, [window(5)], group: 2)
        h.census(60, [window(6)], group: 2)
        h.census(10, [window(1)])
        var added = h
        h.send(.spaceChanged(key: .skylight(10), epoch: h.world.groups[1]!.epoch + 1, windows: [window(1), window(5)]))
        check(h.tiles == [TileID(1)] && h.censusRequest != nil, "a read listing another display's stashed window is re-read")
        added.send(.windowAdded(window(5)))
        check(added.tiles == [TileID(1), TileID(5)], "windowAdded adopts it")
        check(added.stash(50, group: 2) == nil, "and takes it out of the other display's stash")
    }
    section("Invalid windows: window events with a bad frame cannot poison the book") {
        var h = Harness()
        h.census(20, [window(3), window(4)])
        h.census(10, [window(1), window(2)])
        h.send(.windowAdded(window(3, x: .infinity)))
        h.send(.windowChanged(window(4, x: .nan)))
        h.send(.windowChanged(window(1, x: .infinity)))
        check(h.world.check().isEmpty, "World.check stays clean")
        check((try? Snapshot.encode(h.world.spaces.persisted)) != nil, "the book still encodes")
    }
    section("Snapshot identity: a bundle-less disk entry restores by window id") {
        var h = Harness()
        h.send(.loadSnapshots([Snapshot(group: 1, space: .skylight(90), columns: [
            SnapshotColumn(windows: [window(8, bundle: nil)], width: .fixed(188)),
            SnapshotColumn(windows: [window(7, bundle: nil)], width: .fixed(177)),
        ])]))
        var empty = h
        h.census(5, [window(7, bundle: nil), window(8, bundle: nil)])
        check(h.tiles == [TileID(8), TileID(7)] && h.widths == [.fixed(188), .fixed(177)], "the entry restores")
        empty.census(5, [7, 8].map { ObservedWindow(id: TileID($0), pid: Int32($0), bundleID: "", title: "renamed") })
        check(empty.widths == [.fixed(188), .fixed(177)], "an empty bundle id is the same as none")
    }
    section("IPC: a stale scope still gets a reply") {
        var h = Harness()
        h.census(10, [window(1)])
        let old = h.world.scope(for: 1)!
        h.census(20, [window(2)])
        let effects = h.send(.ipc(id: 5, command: .focusLeft), scope: old)
        check(effects.contains { if case .reply(5, .command(.refused)) = $0 { return true }; return false }, "stale IPC is refused, not dropped")
        let query = h.send(.query(id: 6), scope: old)
        check(query.contains { if case .reply(6, .snapshots) = $0 { return true }; return false }, "stale query still gets the snapshots")
        let topology = h.world.scope(for: 1)!
        h.send(.topologyChanged(Topology(revision: 2, groups: [display()], primaryScreenHeight: 900)))
        let stale = h.send(.query(id: 7), scope: topology)
        check(stale.contains { if case .reply(7, .snapshots(let snapshots)) = $0 { return snapshots.isEmpty }; return false },
              "a query from an old topology gets an empty reply")
    }
    section("Focus authority: a refused command leaves pending focus alone") {
        var h = Harness()
        h.census(10, [window(1), window(2)])
        h.advance(EngineConfig.focusDebounce + margin)
        h.send(.focus(FocusIntent(tile: TileID(2), source: .axFocus)))
        h.send(.ipc(id: 1, command: .setWidth(TileID(1), -5)))
        check(!h.world.timers.isEmpty, "refused command does not cancel the debounced focus")
    }
}

struct Random {
    var state: UInt64
    mutating func next(_ upper: Int) -> Int {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return Int((z ^ (z >> 31)) % UInt64(upper))
    }
}

struct FuzzStream {
    var rng: Random
    var h: Harness
    var nextID: UInt32 = 200
    var priorScopes: [EventScope]
    var reached: [String: Int] = [:]

    init(seed: UInt64) {
        rng = Random(state: seed)
        h = Harness(animate: seed % 2 == 0, displays: [display(), display(2, x: 1000)])
        h.census(10, [window(1), window(2)])
        h.census(20, [window(101), window(102)], group: 2)
        priorScopes = [h.world.scope(for: 1)!, h.world.scope(for: 2)!]
    }

    mutating func pick<T>(_ values: [T]) -> T? { values.isEmpty ? nil : values[rng.next(values.count)] }

    mutating func step() {
        let id = pick(h.world.groups.keys.sorted())!
        let group = h.world.groups[id]!
        let tile = pick(group.windows.keys.sorted { $0.rawValue < $1.rawValue }) ?? TileID(99999)
        let epoch = group.epoch + 1
        let before = (space: group.space, groups: h.world.groups.count)
        switch rng.next(35) {
        case 0: h.send(.command(.focus(tile), .ipc), group: id)
        case 1: h.send(.focus(FocusIntent(tile: tile, source: .axFocus)), group: id)
        case 2: h.send(.command(.setWidth(tile, Double(50 + rng.next(1400))), .keyboard), group: id)
        case 3: h.send(.pointer(.beginGesture(tile)), group: id)
        case 4: h.send(.pointer(.delta(Double(rng.next(400) - 200))), group: id)
        case 5: h.send(.pointer(.endGesture), group: id)
        case 6: h.send(.pointer(.openMenu(tile)), group: id)
        case 7:
            let actions: [Command] = [.toggleFloating(tile), .setWidth(tile, 400), .focus(tile), .close(tile), .toggleFullWidth(tile)]
            h.send(.pointer(.menu(pick(actions)!)), group: id)
        case 8: h.send(.windowRemoved(tile), group: id)
        case 9:
            let stashed = pick(h.world.spaces.live.values.flatMap(\.windows).sorted { $0.id.rawValue < $1.id.rawValue })
            if rng.next(4) == 0, let known = rng.next(2) == 0 ? group.windows[tile] : stashed {
                h.send(.windowChanged(ObservedWindow(id: known.id, pid: known.pid, bundleID: known.bundleID, title: "retitled-\(rng.next(9))")), group: id)
                break
            }
            if rng.next(4) == 0, let stashed {
                h.send(.windowAdded(stashed), group: id)
                break
            }
            nextID += 1
            h.send(.windowAdded(window(nextID, bundle: rng.next(2) == 0 ? nil : "fuzz", floating: rng.next(4) == 0)), group: id)
        case 10:
            let request = h.world.frames.values.sorted { $0.tile.rawValue < $1.tile.rawValue }.first { $0.scope.group == id }
            if let request { h.send(.frameCompleted(tile: request.tile, revision: request.revision, result: rng.next(2) == 0 ? .applied : .timedOut), group: id) }
            else { h.send(.tick, group: id) }
        case 11:
            if let timer = h.world.timers.min(by: { $0.key < $1.key }) {
                h.send(.timer(timer.key), scope: timer.value.scope, advance: 0.2)
            } else { h.send(.tick, group: id, advance: 0.2) }
        case 12:
            priorScopes.append(h.world.scope(for: id)!)
            nextID += 1
            var windows = [window(nextID)]
            if rng.next(3) == 0 { windows.append(ObservedWindow(id: TileID(nextID + 5000), pid: 1, bundleID: nil, initialFrame: AXRect(.zero))) }
            if rng.next(3) == 0, let foreign = h.world.groups.first(where: { $0.key != id })?.value.windows.values.first { windows.append(foreign) }
            h.census(UInt64(100 + rng.next(4)), windows, group: id)
        case 13: h.send(.windowRemoved(tile), group: id, scope: pick(priorScopes)!)
        case 14: h.send(.command(.toggleFloating(tile), .ipc), group: id)
        case 15:
            let groups = rng.next(3) == 0 ? [display()] : [display(), display(2, x: Double(1000 + rng.next(100)))]
            h.send(.topologyChanged(Topology(revision: h.world.topology.revision + 1, groups: groups, primaryScreenHeight: 900)), group: 1)
        case 16: h.send(.pointer(.beginReorder(tile)), group: id)
        case 17: h.send(.pointer(.dropReorder(rng.next(10) - 3)), group: id)
        case 18: h.send(.spaceWillChange, group: id)
        case 19:
            let all = h.world.groups.values.flatMap { $0.windows.values }.sorted { $0.id.rawValue < $1.id.rawValue }
            let target = pick(all)
            h.send(.focus(FocusIntent(tile: target?.id, pid: target?.pid, source: .appActivation)), group: id)
        case 20: h.send(.command(rng.next(2) == 0 ? .focusLeft : .focusRight, .keyboard), group: id)
        case 21: h.send(.command(rng.next(2) == 0 ? .moveLeft : .moveRight, .keyboard), group: id)
        case 22: h.send(.command(.cycleWidthPreset, .keyboard), group: id)
        case 23: h.send(.command(.toggleFullWidth(tile), .keyboard), group: id)
        case 24: h.send(.ipc(id: UInt64(rng.next(1000)), command: rng.next(2) == 0 ? .focus(tile) : .close(tile)), group: id)
        case 25: h.send(.query(id: UInt64(rng.next(1000))), group: id)
        case 26: h.send(.loadSnapshots(h.world.spaces.persisted), group: id)
        case 27:
            if rng.next(3) == 0 { h.send(.spaceChanged(key: .fingerprint([]), epoch: epoch, windows: []), group: id) }
            else { h.census(rng.next(2) == 0 ? UInt64(100 + rng.next(4)) : 10, [], group: id) }
        case 28, 29:
            let saved = h.world.spaces.live.values.filter { $0.group == id }.sorted { $0.space.debugDescription < $1.space.debugDescription }
            guard let visit = pick(saved) else { h.send(.tick, group: id); break }
            let key: SpaceKey = rng.next(2) == 0 ? .fingerprint(visit.fingerprint) : visit.space
            h.send(.spaceChanged(key: key.isEmpty ? .skylight(10) : key, epoch: epoch, windows: visit.windows), group: id)
        case 30: h.send(.pointer(.cancel), group: id)
        case 31: h.send(.configChanged(EngineConfig(gap: Double(rng.next(20)), animate: rng.next(2) == 0, gestureSnap: rng.next(2) == 0,
                                                    snapPoints: pick([[.middle], [.left, .right], [.left, .middle, .right]])!,
                                                    raiseHeight: Double(rng.next(3) * 10))), group: id)
        case 32:
            let frame = CGRect(x: Double(rng.next(2000) - 500), y: Double(rng.next(300)), width: Double(rng.next(1500)), height: 600)
            h.send(.windowMoved(tile, AXRect(frame)), group: id)
        case 33: h.send(.command(rng.next(4) == 0 ? .release : .recover, .ipc), group: id)
        case 34: h.send(.ipc(id: UInt64(rng.next(1000)), command: .recover), group: id, scope: pick(priorScopes)!)
        default: h.send(.tick, group: id)
        }
        let after = h.world.groups[id]
        if case .fingerprint = after?.space { reached["fingerprint key", default: 0] += 1 }
        if case .crossing = after?.focus { reached["dock crossing", default: 0] += 1 }
        if after?.space != before.space, (after?.strip.columns.count ?? 0) > 1 { reached["multi-column restore", default: 0] += 1 }
        if h.world.groups.count != before.groups { reached["group added or removed", default: 0] += 1 }
        if after?.space == .fingerprint([]) { reached["empty fingerprint key", default: 0] += 1 }
        if h.effects.contains(where: { if case .log(let line) = $0 { return line.hasPrefix("census window dropped") }; return false }) {
            reached["census window dropped", default: 0] += 1
        }
    }
}


@MainActor func runtimeTests() {
    section("R3 config: every key parses into the schema") {
        let text = """
        [layout]
        gap = 12
        default_width = 0.4
        width_presets = [0.25, 0.75, 1]
        snap = ["left", "right"]

        [animation]
        enabled = false
        stiffness = 500
        damping_ratio = 0.8
        bounce_distance = 30
        bounce_damping_ratio = 0.5

        [keys]
        focus_left = "ctrl-h"
        focus_right = "ctrl-l"
        move_left = "ctrl-shift-h"
        move_right = "ctrl-shift-l"
        cycle_width = "ctrl-r"
        toggle_full_width = "ctrl-f"
        toggle_floating = ""
        close_window = "ctrl-w"

        [indicator]
        style = "raise"
        color = "#ff8800"
        width = 4
        corner_radius = 6
        raise_height = 24

        [[rules]]
        bundle_id = "us.zoom.xos"
        floating = true

        [[rules]]
        bundle_id = "com.apple.finder"
        floating = false
        """
        guard let config = try? AppConfig.parse(text) else { return check(false, "full config parses") }
        let engine = config.engine
        check(engine.gap == 12 && engine.defaultWidth == 0.4, "layout.gap, layout.default_width")
        check(engine.widthPresets == [0.25, 0.75, 1], "layout.width_presets")
        check(engine.snapPoints == [.left, .right], "layout.snap")
        check(!engine.animate && engine.scroll.stiffness == 500 && abs(engine.scroll.damping - 0.8 * 2 * sqrt(500 * engine.scroll.mass)) < 1e-9, "animation.enabled, stiffness, damping_ratio")
        check(engine.bounceDistance == 30 && engine.bounceDampingRatio == 0.5, "animation.bounce_distance, bounce_damping_ratio")
        check(config.keys[.focusLeft] == "ctrl-h" && config.keys[.focusRight] == "ctrl-l" && config.keys[.moveLeft] == "ctrl-shift-h"
              && config.keys[.moveRight] == "ctrl-shift-l" && config.keys[.cycleWidth] == "ctrl-r"
              && config.keys[.toggleFullWidth] == "ctrl-f" && config.keys[.toggleFloating] == "" && config.keys[.closeWindow] == "ctrl-w",
              "every [keys] action")
        check(config.indicator == IndicatorConfig(style: .raise, color: "#ff8800", width: 4, cornerRadius: 6, raiseHeight: 24),
              "every [indicator] key")
        check(engine.raiseHeight == 24, "raise style lowers unfocused columns by raise_height")
        check(engine.rules == [Rule(bundleID: "us.zoom.xos", floating: true), Rule(bundleID: "com.apple.finder", floating: false)],
              "[[rules]] bundle_id and floating")
        let defaults = try? AppConfig.parse("")
        check(defaults?.engine.gap == EngineConfig.defaultGap && defaults?.indicator.style == .ring && defaults?.engine.raiseHeight == 0
              && defaults?.keys[.focusLeft] == "alt-h", "an empty file gives the defaults")
        let ring = try? AppConfig.parse("[indicator]\nstyle = \"ring\"\nraise_height = 24")
        check(ring?.engine.raiseHeight == 0, "raise_height lowers columns only in raise style")
    }
    section("R3 config: unknown keys and bad values are load errors that name the key") {
        func error(_ text: String) -> String? {
            do { _ = try AppConfig.parse(text); return nil } catch { return error.description }
        }
        check(error("gapp = 3") == "unknown key gapp", "unknown top-level key")
        check(error("[layout]\ngapp = 3") == "unknown key layout.gapp", "unknown key in a section")
        check(error("[keybindings]\nfocus_left = \"alt-h\"") == "unknown key keybindings", "the old schema's section is unknown")
        check(error("[keys]\nfocus_up = \"alt-k\"") == "unknown key keys.focus_up", "an action this runtime lacks is unknown")
        check(error("[[rules]]\napp_id = \"x\"\nfloating = true") == "unknown key rules[0].app_id", "unknown key in a rule")
        check(error("[[rules]]\nbundle_id = \"x\"") == "rules[0] needs bundle_id and floating", "a rule needs both keys")
        check(error("[layout]\ngap = -1") == "layout.gap must be a number >= 0.0", "negative gap")
        check(error("[layout]\ngap = \"wide\"") == "layout.gap must be a number >= 0.0", "gap of the wrong type")
        check(error("[layout]\ndefault_width = 1.5") == "layout.default_width must be a proportion in (0, 1]", "width above 1")
        check(error("[layout]\nwidth_presets = [0.5, 0]") == "layout.width_presets must be a number > 0.0", "zero preset")
        check(error("[layout]\nsnap = [\"centre\"]") == "layout.snap must be one of left, middle, right", "unknown snap point")
        check(error("[animation]\nenabled = 1") == "animation.enabled must be true or false", "flag of the wrong type")
        check(error("[animation]\nstiffness = 0") == "animation.stiffness must be a number > 0.0", "zero stiffness")
        check(error("[indicator]\nstyle = \"glow\"") == "indicator.style must be one of none, ring, raise, flash", "unknown style")
        check(error("[indicator]\ncolor = \"#12345\"") == "indicator.color must be \"auto\" or #RGB / #RRGGBB", "bad color")
        check(error("layout = 3") == "layout must be a table", "a section that is not a table")
        check(error("[layout\ngap = 3")?.hasPrefix("syntax:") == true, "a TOML syntax error")
        check(error("[layout]\ngap = inf") == "layout.gap must be a number >= 0.0", "a gap that is not finite")
        check(error("[[rules]]\nbundle_id = \"\"\nfloating = true") == "rules[0] needs bundle_id and floating", "an empty bundle_id")
        check(error("[indicator]\ncolor = \"#f80\"") == nil, "#RGB is a color")
        check(EngineConfig(raiseHeight: -5).raiseHeight == 0 && EngineConfig(raiseHeight: .nan).raiseHeight == 0, "a raise height below zero is off")
    }
    section("R3 config: a file with no keys is exactly the engine's defaults") {
        guard let empty = try? AppConfig.parse("") else { return check(false, "an empty file parses") }
        let engine = empty.engine, base = EngineConfig()
        check(engine.gap == base.gap && engine.defaultWidth == base.defaultWidth && engine.animate == base.animate
              && engine.gestureSnap == base.gestureSnap && engine.rules == base.rules && engine.widthPresets == base.widthPresets
              && engine.snapPoints == base.snapPoints && engine.scroll.stiffness == base.scroll.stiffness
              && engine.dampingRatio == base.dampingRatio && engine.bounceDistance == base.bounceDistance
              && engine.bounceDampingRatio == base.bounceDampingRatio && engine.raiseHeight == base.raiseHeight, "every engine default")
        check(empty.indicator == IndicatorConfig(), "every indicator default")
    }
    section("R3 config: a key binding the hotkey parser rejects fails the whole load") {
        var keys = AppConfig().keys
        check(Loop.bindingError(keys) == nil, "the default bindings parse")
        keys[.focusLeft] = ""
        check(Loop.bindingError(keys) == nil, "an empty binding turns the action off")
        keys[.focusLeft] = "alt-hh"
        check(Loop.bindingError(keys) == "keys.focus_left: cannot parse \"alt-hh\"", "a typo names the key")
        keys[.focusLeft] = "hyperr-h"
        check(Loop.bindingError(keys) != nil, "an unknown modifier is a typo too")
        let hotkeys = HotkeyManager()
        let bindings = AppConfig().keys
        hotkeys.registerFromConfig(Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) }))
        check(bindings.values.allSatisfy { key in
            hotkeys.parseKeyString(key).flatMap { hotkeys.matchBinding(keyCode: $0.1, flags: $0.0) } != nil
        }, "every action name is one the hotkey manager binds")
    }
    section("R3 config: the smoke harness's ReelNext file parses") {
        let smoke = """
        [layout]
        gap = 64
        snap = ["middle"]

        [animation]
        enabled = true
        stiffness = 800
        damping_ratio = 1.0
        bounce_distance = 40
        bounce_damping_ratio = 0.6

        [keys]
        focus_left = ""
        focus_right = ""
        move_left = ""
        move_right = ""
        cycle_width = ""
        toggle_full_width = ""
        toggle_floating = ""
        close_window = ""

        [indicator]
        style = "none"
        """
        let config = try? AppConfig.parse(smoke)
        check(config?.engine.gap == 64 && config?.keys.values.allSatisfy(\.isEmpty) == true && config?.indicator.style == IndicatorStyle.none,
              "Tests/Smoke/lib.sh write_test_config for ReelNext")
    }
    section("R3 config: a reload applies presets, snap points and springs to live strips") {
        var h = Harness(animate: true)
        h.census(10, [window(1), window(2)])
        h.send(.configChanged(EngineConfig(gap: 20, widthPresets: [0.25, 0.75], snapPoints: [.left, .middle], stiffness: 300,
                                           bounceDistance: 10)))
        let strip = h.world.groups[1]!.strip
        check(strip.widthPresets == [.proportion(0.25), .proportion(0.75)] && strip.snapPoints == [.left, .middle], "presets and snap points")
        check(strip.snapIndices.allSatisfy { $0 == strip.defaultSnapIndex }, "snap indices move to the new default")
        check(strip.scrollSpringParams.stiffness == 300 && strip.bounceDistance == 10 && strip.gap == 20, "springs, bounce and gap")
        h.send(.command(.cycleWidthPreset, .keyboard))
        check(h.world.groups[1]!.strip.columnData[h.world.groups[1]!.strip.activeColumnIndex].cachedWidth == 250, "cycling uses the new presets")
        h.send(.command(.cycleWidthPreset, .keyboard))
        h.send(.configChanged(EngineConfig(widthPresets: [0.5])))
        check(h.world.groups[1]!.strip.columns[h.world.groups[1]!.strip.activeColumnIndex].presetIndex == nil,
              "a preset index past the new list is dropped")
        check(h.world.check().isEmpty, "config invariants")
    }
    section("R3 scheduler: a cancelled token never delivers, and a stale owner is dropped") {
        var now = 0.0
        var delivered: [UInt64] = []
        var censuses: [UInt32] = []
        var live = EventScope(topologyRevision: 1, group: 1, spaceEpoch: 1)
        let scheduler = Scheduler(clock: { now }, isCurrent: { $0 == live }, deliver: { job in
            switch job {
            case .event(let event): if case .timer(let token) = event.kind { delivered.append(token.rawValue) }
            case .census(let group): censuses.append(group)
            }
        }, log: { _ in })
        func timer(_ raw: UInt64, _ scope: EventScope = live) -> (Scheduler.Key, Scheduler.Job) {
            (.engine(TimerToken(raw)), .event(Event(scope: scope, kind: .timer(TimerToken(raw)))))
        }
        for raw: UInt64 in [1, 2, 3] {
            let (key, job) = timer(raw)
            scheduler.schedule(key, deadline: Double(raw) * 0.1, owner: live, job: job)
        }
        scheduler.cancel(.engine(TimerToken(2)))
        now = 0.15
        scheduler.fire(now: now)
        check(delivered == [1], "only the due token fires")
        now = 1
        scheduler.fire(now: now)
        check(delivered == [1, 3], "the cancelled token never delivers")
        scheduler.fire(now: 5)
        check(delivered == [1, 3] && scheduler.pendingCount == 0, "a fired token delivers once")
        let (key, job) = timer(4)
        scheduler.schedule(key, deadline: 2, owner: live, job: job)
        scheduler.schedule(.census(group: 1), deadline: 2, owner: live, job: .census(group: 1))
        live = EventScope(topologyRevision: 1, group: 1, spaceEpoch: 2)
        scheduler.fire(now: 3)
        check(delivered == [1, 3] && censuses.isEmpty, "a token whose owner epoch moved on is dropped")
        scheduler.schedule(.census(group: 1), deadline: 4, owner: live, job: .census(group: 1))
        scheduler.schedule(.census(group: 1), deadline: 6, owner: live, job: .census(group: 1))
        scheduler.fire(now: 5)
        check(censuses.isEmpty && scheduler.pendingCount == 1, "a census request replaces the pending one")
        scheduler.fire(now: 6)
        check(censuses == [1], "the replacement census fires")
    }
    section("R3 scheduler: a job rescheduled by an earlier job in the same batch runs as rescheduled") {
        var delivered: [UInt64] = []
        var onDeliver: (UInt64) -> Void = { _ in }
        let live = EventScope(topologyRevision: 1, group: 1, spaceEpoch: 1)
        let scheduler = Scheduler(clock: { 0 }, isCurrent: { _ in true }, deliver: { job in
            if case .event(let event) = job, case .timer(let token) = event.kind { delivered.append(token.rawValue); onDeliver(token.rawValue) }
        }, log: { _ in })
        @MainActor func schedule(_ key: UInt64, _ deadline: Double, payload: UInt64? = nil) {
            scheduler.schedule(.engine(TimerToken(key)), deadline: deadline, owner: live,
                               job: .event(Event(scope: live, kind: .timer(TimerToken(payload ?? key)))))
        }
        schedule(1, 0.1)
        schedule(2, 0.2)
        onDeliver = { if $0 == 1 { schedule(2, 5, payload: 20) } }
        scheduler.fire(now: 1)
        check(delivered == [1] && scheduler.pendingCount == 1, "the old job does not run in place of the rescheduled one")
        scheduler.fire(now: 5)
        check(delivered == [1, 20], "the rescheduled job runs at its new deadline")
    }
    section("R3 scheduler: due jobs run earliest first, and one a job cancels never runs") {
        var delivered: [UInt64] = []
        var onDeliver: (UInt64) -> Void = { _ in }
        let live = EventScope(topologyRevision: 1, group: 1, spaceEpoch: 1)
        let scheduler = Scheduler(clock: { 0 }, isCurrent: { _ in true }, deliver: { job in
            if case .event(let event) = job, case .timer(let token) = event.kind { delivered.append(token.rawValue); onDeliver(token.rawValue) }
        }, log: { _ in })
        for (raw, deadline) in [(1, 0.3), (2, 0.1), (3, 0.2), (4, 0.4)] as [(UInt64, Double)] {
            scheduler.schedule(.engine(TimerToken(raw)), deadline: deadline, owner: live, job: .event(Event(scope: live, kind: .timer(TimerToken(raw)))))
        }
        onDeliver = { if $0 == 3 { scheduler.cancel(.engine(TimerToken(1))) } }
        scheduler.fire(now: 1)
        check(delivered == [2, 3, 4], "earliest first, and the job cancelled mid-batch never runs")
    }
    section("R3 scheduler: the run-loop timer fires a due job without a manual fire") {
        var delivered = 0
        let live = EventScope(topologyRevision: 1, group: 1, spaceEpoch: 1)
        let clock = { ProcessInfo.processInfo.systemUptime }
        let scheduler = Scheduler(clock: clock, isCurrent: { _ in true }, deliver: { _ in delivered += 1 }, log: { _ in })
        scheduler.schedule(.census(group: 1), deadline: clock() + 0.05, owner: live, job: .census(group: 1))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check(delivered == 1 && scheduler.pendingCount == 0, "the timer delivered the job once")
        delivered = 0
        scheduler.schedule(.census(group: 1), deadline: clock() + 0.05, owner: live, job: .census(group: 1))
        scheduler.schedule(.census(group: 2), deadline: clock() + 0.15, owner: live, job: .census(group: 2))
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        check(delivered == 2, "the timer re-arms for the later job after the first fires")
    }
    section("R3 echo: the written revision decides echo, never a clock") {
        var ledger = EchoLedger()
        let tile = TileID(7)
        let first = CGRect(x: 100, y: 30, width: 500, height: 800)
        let second = CGRect(x: 80, y: 30, width: 500, height: 800)
        ledger.wrote(tile, revision: 1, frame: first)
        ledger.wrote(tile, revision: 2, frame: second)
        check(ledger.classify(tile, observed: second.offsetBy(dx: 0.4, dy: 0)) == .echo(revision: 2), "the app's rounding of our write is an echo")
        check(ledger.classify(tile, observed: second) == .echo(revision: 2), "a second notification for the same write is an echo")
        check(ledger.classify(tile, observed: first) == .foreign, "an older write is forgotten once a newer one echoed")
        ledger.wrote(tile, revision: 3, frame: first)
        ledger.wrote(tile, revision: 4, frame: second)
        check(ledger.classify(tile, observed: first) == .echo(revision: 3), "a late echo of an earlier write in flight is still an echo")
        check(ledger.classify(tile, observed: CGRect(x: 80, y: 30, width: 500, height: 620)) == .echo(revision: 4),
              "a height the app chose is still our write")
        let clamped = CGRect(x: 80, y: 30, width: 560, height: 800)
        check(ledger.classify(tile, observed: clamped) == .foreign, "the same origin at another width is the user")
        check(ledger.classify(tile, observed: second.offsetBy(dx: 0, dy: 50)) == .foreign, "a pure vertical move is the user")
        ledger.record(tile, revision: 5, requested: second, landed: clamped, result: .applied)
        check(ledger.classify(tile, observed: clamped) == .echo(revision: 5), "the width an app clamped our write to is our echo")
        let moved = CGRect(x: 300, y: 30, width: 500, height: 800)
        check(ledger.classify(tile, observed: moved) == .foreign, "a frame we never wrote is the user")
        ledger.wrote(tile, revision: 6, frame: second)
        check(ledger.classify(tile, observed: moved) == .repeated, "an app that keeps refusing our frame is heard once")
        check(ledger.classify(tile, observed: second) == .echo(revision: 6), "an accepted write clears the refusal")
        check(ledger.classify(tile, observed: moved) == .foreign, "the same user frame later is heard again")
        ledger.forget(tile)
        check(ledger.classify(tile, observed: second) == .foreign, "a forgotten window has no echoes")
        for revision in 10...(10 + UInt64(EchoLedger.history)) {
            ledger.wrote(tile, revision: revision, frame: first.offsetBy(dx: Double(revision) * 10, dy: 0))
        }
        check(ledger.classify(tile, observed: first.offsetBy(dx: 100, dy: 0)) == .foreign, "history is bounded")
    }
    section("R3 echo: an app that refuses our width cannot loop write, refuse, rewrite") {
        // Plays the app thread and the Observer: every write lands at least `minimum` wide.
        @MainActor func heard(minimum: Double, readBack: Bool) -> (heard: Int, settled: Bool, preset: Int?) {
            var h = Harness()
            h.census(10, [window(1)])
            var ledger = EchoLedger()
            var heard = 0
            var pending = h.requests
            h.send(.command(.cycleWidthPreset, .keyboard))
            pending += h.requests
            for _ in 0..<50 where !pending.isEmpty {
                let request = pending.removeFirst()
                var landed = request.frame.rect
                landed.size.width = max(landed.width, minimum)
                ledger.record(request.tile, revision: request.revision, requested: request.frame.rect,
                              landed: readBack ? landed : nil, result: .applied)
                h.send(.frameCompleted(tile: request.tile, revision: request.revision, result: .applied))
                pending += h.requests
                if ledger.classify(request.tile, observed: landed) == .foreign {
                    heard += 1
                    h.send(.windowMoved(request.tile, AXRect(landed)))
                    pending += h.requests
                }
            }
            return (heard, pending.isEmpty, h.world.groups[1]!.strip.columns[0].presetIndex)
        }
        let readBack = heard(minimum: 400, readBack: true)
        check(readBack.heard == 0 && readBack.settled && readBack.preset == 0, "a read-back clamp is an echo and the preset stays")
        let late = heard(minimum: 400, readBack: false)
        check(late.heard == 1 && late.settled, "a clamp seen only in the echo is heard once, then the rewrite settles")
        let wider = heard(minimum: 1200, readBack: false)
        check(wider.heard <= 2 && wider.settled, "an app wider than any width we can give it is heard a bounded number of times")
    }
    section("R3 echo: a write that timed out mid-animation and lands late is still ours") {
        var h = Harness(animate: true)
        h.census(10, [window(1), window(2)])
        for _ in 0..<200 { h.send(.tick, advance: 0.02) }
        h.send(.command(.cycleWidthPreset, .keyboard))
        h.send(.tick, advance: 0.02)
        guard let midway = h.requests.first(where: { $0.tile == TileID(1) }) else { return check(false, "the width animation writes the window") }
        var ledger = EchoLedger()
        ledger.record(midway.tile, revision: midway.revision, requested: midway.frame.rect, result: .timedOut)
        let verdict = ledger.classify(midway.tile, observed: midway.frame.rect)
        check(verdict == .echo(revision: midway.revision), "the late echo of a timed-out write is an echo")
        if verdict == .foreign { h.send(.windowMoved(midway.tile, midway.frame)) }
        for _ in 0..<200 { h.send(.tick, advance: 0.02) }
        let column = h.world.groups[1]!.strip.columns[0]
        check(column.presetIndex == 0 && column.width == .proportion(0.33), "the preset cycle finishes")
        var failed = EchoLedger()
        failed.record(midway.tile, revision: midway.revision, requested: midway.frame.rect, result: .failed)
        check(failed.classify(midway.tile, observed: midway.frame.rect) == .foreign, "a write that failed outright is not")
    }
    section("R3 user resize: the column adopts the width and the next layout keeps it") {
        var h = Harness()
        h.census(10, [window(1), window(2)])
        let request = h.world.frames[TileID(1)]!
        let resized = CGRect(x: request.frame.rect.minX + 40, y: request.frame.rect.minY, width: 640, height: request.frame.rect.height)
        h.send(.windowMoved(TileID(1), AXRect(resized)))
        check(h.widths.first == .fixed(640) && h.world.groups[1]!.strip.columns[0].presetIndex == nil, "the column takes the user's width")
        check(h.effects.contains { if case .persist = $0 { true } else { false } }, "a user resize is persisted")
        check(h.requests.first { $0.tile == TileID(1) }?.frame.rect.width == 640, "the window is rewritten at its new width")
        check(h.requests.first { $0.tile == TileID(1) }?.frame.rect.minX == request.frame.rect.minX, "and back at its column's x")
        h.send(.command(.focusRight, .keyboard))
        h.send(.command(.focusLeft, .keyboard))
        check(h.requests.allSatisfy { $0.tile != TileID(1) || $0.frame.rect.width == 640 }, "later layouts keep the width")
        let moved = h.world.frames[TileID(1)]!.frame.rect.offsetBy(dx: 0, dy: 50)
        h.send(.windowMoved(TileID(1), AXRect(moved)))
        check(h.widths.first == .fixed(640) && h.requests.first { $0.tile == TileID(1) }?.frame.rect.minY == request.frame.rect.minY,
              "a pure move keeps the width and puts the window back")
        h.send(.windowMoved(TileID(1), AXRect(moved.insetBy(dx: -0.75, dy: 0))))
        check(h.widths.first == .fixed(640), "a resize within the slop is rounding, not a new width")
        h.send(.windowMoved(TileID(2), AXRect(CGRect(x: 0, y: 0, width: 5000, height: 500))))
        check(h.world.groups[1]!.strip.columnData[1].cachedWidth == 1000, "a width wider than the screen is clamped")
        h.send(.command(.toggleFloating(TileID(2)), .ipc))
        h.send(.windowMoved(TileID(2), AXRect(CGRect(x: 10, y: 10, width: 300, height: 300))))
        check(h.requests.isEmpty, "a floating window keeps the frame the user gave it")
        h.send(.spaceWillChange)
        h.send(.windowMoved(TileID(1), AXRect(CGRect(x: 10, y: 10, width: 300, height: 300))))
        check(h.widths.first == .fixed(640) && h.requests.isEmpty, "a move during a Space change is ignored")
        check(h.world.check().isEmpty, "user resize invariants")
    }
    section("R3 user resize: a full-width window reporting more than the screen stays full width") {
        var h = Harness()
        h.census(10, [window(1), window(2)])
        h.send(.command(.toggleFullWidth(TileID(1)), .ipc))
        let frame = h.world.frames[TileID(1)]!.frame.rect
        h.send(.windowMoved(TileID(1), AXRect(CGRect(x: frame.minX, y: frame.minY, width: frame.width + 200, height: frame.height))))
        check(h.world.groups[1]!.strip.columns[0].isFullWidth, "the column keeps full width")
    }
    section("R3 recover: every frame is written again") {
        var h = Harness()
        h.census(10, [window(1), window(2), window(3)])
        h.send(.tick)
        check(h.requests.isEmpty, "a settled strip writes nothing")
        h.send(.command(.recover, .ipc))
        check(Set(h.requests.map(\.tile)) == [TileID(1), TileID(2), TileID(3)], "recover rewrites every tiled window")
        h.advance(1)
        h.send(.focus(FocusIntent(tile: TileID(3), pid: 3, source: .appActivation)))
        h.send(.command(.recover, .ipc))
        h.advance(EngineConfig.focusDebounce + margin)
        check(h.active == TileID(3), "recover leaves a pending focus to land")
        check(h.world.check().isEmpty, "recover invariants")
    }
    section("R3 release: quitting brings every off-screen window back on screen") {
        var h = Harness()
        h.census(10, (1...6).map { window($0) })
        let area = h.world.topology.groups[0].frame
        let offScreen = h.world.frames.values.filter { $0.frame.rect.intersection(area).width < 2 }.map(\.tile)
        check(!offScreen.isEmpty, "a six-column strip hides some columns")
        h.send(.command(.release, .ipc))
        let released = Dictionary(uniqueKeysWithValues: h.requests.map { ($0.tile, $0.frame.rect) })
        check(Set(released.keys) == Set(offScreen), "only off-screen windows move")
        check(released.values.allSatisfy { area.contains($0) }, "each lands fully inside the working area")
        check(Set(released.values.map(\.origin)).count == released.count, "cascaded, so none hides another exactly")
        var changing = Harness()
        changing.census(10, (1...6).map { window($0) })
        changing.send(.spaceWillChange)
        changing.send(.command(.release, .ipc))
        check(Set(changing.requests.map(\.tile)) == Set(offScreen), "quitting during a Space change still releases")
    }
    section("R3 raise style: unfocused columns sit lower, derived from the active column") {
        var h = Harness()
        h.send(.configChanged(EngineConfig(animate: false, raiseHeight: 20)))
        h.census(10, [window(1), window(2)])
        let top = h.world.topology.groups[0].frame.minY
        func y(_ tile: UInt32) -> Double? { h.world.frames[TileID(tile)].map { Double($0.frame.rect.minY) } }
        check(h.active == TileID(1) && y(1) == top && y(2) == top + 20, "the active column rises, the other falls")
        h.send(.command(.focusRight, .keyboard))
        check(y(2) == top && y(1) == top + 20, "focus moves the raise with it")
        h.send(.configChanged(EngineConfig(animate: false)))
        check(y(1) == top && y(2) == top, "turning raise off levels every column")
        check(!h.world.needsTicks, "a settled strip needs no frame ticks")
    }
    section("R3 frame loop: needsTicks follows scroll and width springs") {
        var h = Harness(animate: true)
        h.census(10, [window(1), window(2), window(3)])
        h.send(.command(.focusLeft, .keyboard))
        check(h.world.needsTicks, "an animating strip asks for ticks")
        for _ in 0..<200 { h.send(.tick, advance: 0.02) }
        check(!h.world.needsTicks, "a settled strip lets the frame loop pause")
        h.send(.command(.cycleWidthPreset, .keyboard))
        check(h.world.needsTicks, "a width spring asks for ticks")
        var raise = Harness(animate: true)
        raise.census(10, [window(1), window(2)])
        for _ in 0..<200 { raise.send(.tick, advance: 0.02) }
        raise.send(.configChanged(EngineConfig(animate: true, raiseHeight: 20)))
        if case .static = raise.world.groups[1]!.strip.viewOffset {} else { check(false, "the view is settled") }
        check(raise.world.needsTicks, "a raise spring on a settled view asks for ticks")
        raise.send(.configChanged(EngineConfig(animate: false, raiseHeight: 20)))
        let top = raise.world.topology.groups[0].frame.minY
        check(!raise.world.needsTicks && raise.world.frames[TileID(2)].map { Double($0.frame.rect.minY) } == top + 20,
              "turning animation off mid-raise snaps the raise to its end")
    }
    section("R3 get-layout: every field the smoke harness reads") {
        var h = Harness()
        h.census(10, [window(1), window(2)])
        h.send(.command(.cycleWidthPreset, .ipc))
        let layout = IPCBridge.layout(world: h.world, active: 1, now: h.time)
        let data = try? JSONSerialization.data(withJSONObject: layout)
        let decoded = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let group = (decoded?["groups"] as? [[String: Any]])?.first { $0["isActive"] as? Bool == true }
        let columns = group?["currentColumns"] as? [[String: Any]] ?? []
        check(decoded?["primaryScreenHeight"] as? Double == 900, "primaryScreenHeight")
        check(group?["gap"] as? Double == h.world.config.gap && group?["viewPos"] is Double && group?["activeColumnIndex"] as? Int == 0,
              "gap, viewPos and activeColumnIndex")
        check(columns.map { $0["windowID"] as? UInt32 } == [1, 2], "windowID per column")
        let frame = columns.first?["frame"] as? [String: Double]
        let written = h.world.frames[TileID(1)]!.frame.rect
        check(frame == ["x": written.minX, "y": written.minY, "w": written.width, "h": written.height], "frame in CG coordinates")
        check(columns.first?["presetIndex"] as? Int == 0 && columns.last?["presetIndex"] is NSNull, "presetIndex or null")
        check(columns.first?["isFullWidth"] as? Bool == false && columns.first?["active"] as? Bool == true
              && columns.first?["cachedWidth"] is Double, "isFullWidth, active and cachedWidth")
    }
    section("R3 bounce: focus past the strip's edge stretches the view and springs back") {
        var h = Harness(animate: true)
        h.census(10, [window(1), window(2)])
        for _ in 0..<200 { h.send(.tick, advance: 0.02) }
        let rest = h.offset
        check(h.active == TileID(1), "the first column is active")
        h.send(.command(.focusLeft, .keyboard))
        h.send(.tick, advance: 0.03)
        check(h.active == TileID(1) && h.offset < rest - 1, "the view stretches past the left edge")
        for _ in 0..<200 { h.send(.tick, advance: 0.02) }
        check(abs(h.offset - rest) < 1 && !h.world.needsTicks, "and settles back where it was")
        var still = Harness()
        still.census(10, [window(1)])
        still.send(.command(.focusLeft, .keyboard))
        check(!still.world.needsTicks, "without animation there is no bounce")
        var swiping = Harness(animate: true)
        swiping.census(10, [window(1), window(2)])
        swiping.send(.pointer(.beginGesture(TileID(1))))
        swiping.send(.pointer(.delta(20)))
        swiping.send(.command(.focusLeft, .keyboard))
        let viewSwipes = if case .gesture = swiping.world.groups[1]!.strip.viewOffset { true } else { false }
        check(viewSwipes == (swiping.gesture != nil), "edge focus during a swipe never leaves a swipe without its view")
    }
    section("R3 bounce: edge focus from a floating window brings focus back to the strip, then bounces") {
        for animate in [false, true] {
            var h = Harness(animate: animate)
            h.census(10, [window(1), window(2, floating: true)])
            for _ in 0..<200 { h.send(.tick, advance: 0.02) }
            let rest = h.offset
            h.send(.command(.focus(TileID(2)), .keyboard))
            h.send(.command(.focusLeft, .keyboard))
            let focused = h.effects.contains { if case .focus(let tile, _) = $0 { tile == TileID(1) } else { false } }
            check(focused && h.world.groups[1]!.focus.decision?.tile == TileID(1), "animate=\(animate): focusLeft focuses tile 1")
            guard animate else { continue }
            h.send(.tick, advance: 0.03)
            check(h.offset < rest - 1, "and the view still stretches past the edge")
            for _ in 0..<200 { h.send(.tick, advance: 0.02) }
            check(abs(h.offset - rest) < 1, "then settles back")
        }
    }
    section("R3 config: a census after a config load builds its group with that config") {
        var h = Harness()
        h.send(.configChanged(EngineConfig(widthPresets: [0.25, 0.75], stiffness: 300)))
        h.census(10, [window(1), window(2)])
        check(h.world.groups[1]!.strip.widthPresets == [.proportion(0.25), .proportion(0.75)], "the census group uses the loaded presets")
    }
    section("R3 frame loop: a settled raise lets the frame loop pause") {
        var h = Harness(animate: true)
        h.send(.configChanged(EngineConfig(animate: true, raiseHeight: 20)))
        h.census(10, [window(1), window(2)])
        for _ in 0..<300 { h.send(.tick, advance: 0.02) }
        check(!h.world.needsTicks, "no ticks once the raise settled")
    }
    section("R3 release: quitting levels a column the raise style lowered") {
        var h = Harness()
        h.send(.configChanged(EngineConfig(animate: false, raiseHeight: 20)))
        h.census(10, [window(1), window(2)])
        guard let active = h.world.frames[TileID(1)]?.frame.rect else { return check(false, "the active column is written") }
        h.send(.command(.release, .ipc))
        let lowered = h.requests.first { $0.tile == TileID(2) }?.frame.rect
        check(lowered?.minY == active.minY && lowered?.height == active.height, "the lowered column comes back up at full height")
    }
    section("R3 lane 8: cycle, toggle full width, toggle back, toggle, cycle") {
        var h = Harness()
        h.census(10, [window(1)])
        h.send(.command(.cycleWidthPreset, .ipc))
        let preset = h.world.groups[1]!.strip.columns[0]
        check(preset.width == .proportion(0.33) && preset.presetIndex == 0, "the cycle lands on the first preset")
        h.send(.command(.toggleFullWidth(TileID(1)), .ipc))
        check(h.world.groups[1]!.strip.columns[0].width == preset.width, "full width keeps the logical width")
        h.send(.command(.toggleFullWidth(TileID(1)), .ipc))
        let back = h.world.groups[1]!.strip
        check(!back.columns[0].isFullWidth && back.columnData[0].cachedWidth == 330, "toggling back restores the preset width")
        h.send(.command(.toggleFullWidth(TileID(1)), .ipc))
        h.send(.command(.cycleWidthPreset, .ipc))
        let column = h.world.groups[1]!.strip.columns[0]
        check(!column.isFullWidth && column.width == .proportion(0.5), "a cycle leaves full width for the next preset")
    }
}

@MainActor func fuzzTests(seeds: [UInt64]) {
    guard only.isEmpty || only == "fuzz" else { return }
    print("▸ fuzz: \(seeds.count) seeds × 10,000 events, World.check() after every event")
    for seed in seeds {
        var stream = FuzzStream(seed: seed)
        for step in 0..<10_000 {
            stream.step()
            let violations = stream.h.world.check()
            check(violations.isEmpty, "seed=\(seed) step=\(step): \(violations)")
            if !violations.isEmpty { break }
        }
        let states = ["fingerprint key", "dock crossing", "multi-column restore", "group added or removed",
                      "empty fingerprint key", "census window dropped"]
        print("  seed=\(seed) reached \(states.map { "\($0)=\(stream.reached[$0, default: 0])" }.joined(separator: " "))")
        for state in states { check(stream.reached[state, default: 0] > 0, "seed=\(seed) fuzz reaches \(state)") }
    }
}

@MainActor func benchmark() {
    guard environment["ENGINE_BENCH"] == "1" else { return }
    var wall: [Duration] = []
    var cpu: [Duration] = []
    for _ in 0..<5 {
        var stream = FuzzStream(seed: 0)
        for _ in 0..<10_000 { stream.step() }
        check(stream.h.world.check().isEmpty, "benchmark invariants")
        wall.append(stream.h.reduceTime)
        cpu.append(stream.h.reduceCPU)
    }
    let median = cpu.sorted()[2]
    print("ENGINE_BENCH seed=0 events=10000 wall=\(wall.map { "\($0)" }) cpu=\(cpu.map { "\($0)" }) median_cpu=\(median)")
    #if !DEBUG
    check(median < .milliseconds(50), "reduce budget: median thread CPU time of 5 rounds of 10,000 events under 50 ms")
    #endif
}

MainActor.assumeIsolated {
    do { try replayTests(); probeTests(); runtimeTests() }
    catch { check(false, "unexpected error: \(error)") }
    var seeds: [UInt64] = [0]
    for value in (environment["ENGINE_FUZZ_SEEDS"] ?? "").split(separator: ",") {
        guard let seed = UInt64(value.trimmingCharacters(in: .whitespaces)) else {
            print("ENGINE_FUZZ_SEEDS expects comma-separated unsigned seeds"); exit(2)
        }
        if !seeds.contains(seed) { seeds.append(seed) }
    }
    fuzzTests(seeds: seeds)
    benchmark()
    if checks == 0 { print("No test matched ENGINE_ONLY=\(only)"); exit(2) }
    print("Engine: \(checks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}
