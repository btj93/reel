import Core
import Engine
import Foundation

let environment = ProcessInfo.processInfo.environment
let only = environment["ENGINE_ONLY"]?.lowercased() ?? ""
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

struct Harness {
    var world: World
    var time = 1.0
    var effects: [Effect] = []
    var reduceTime: Duration = .zero

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
        let start = ContinuousClock.now
        effects = reduce(&world, event, now: time)
        reduceTime += start.duration(to: .now)
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

    var requests: [FrameRequest] {
        effects.compactMap { if case .setFrame(let request) = $0 { return request }; return nil }
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
        check(h.effects.contains { if case .requestCensus(1, EngineConfig.censusSettle) = $0 { return true }; return false },
              "mixed census asks the observer for a settled re-read")
        h.census(30, [])
        check(h.world.groups[1]!.space == .skylight(20), "unconfirmed empty census did not commit")
        check(h.effects.contains { if case .requestCensus(1, let after) = $0 { return after < EngineConfig.censusSettle }; return false },
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
    section("c9d3e80 1aa4ede: Space-switch focus echoes cannot overwrite departing focus") {
        var h = Harness()
        h.census(10, [window(1), window(2), window(3)])
        h.send(.command(.focus(TileID(3)), .keyboard))
        h.advance(0.2)
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
        h.advance(0.3)
        check(h.active == TileID(3), "post-restore echo rejected on receipt, not after debounce")
        h.send(.focus(FocusIntent(tile: TileID(1), source: .axFocus, observedSpace: .skylight(20))))
        h.advance(0.3)
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
        h.advance(0.6)
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
        h.advance(0.2)
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
        h.advance(0.2)
        h.send(.focus(FocusIntent(tile: TileID(1), source: .axFocus)))
        let timer = h.world.timers.keys.first!
        h.send(.windowAdded(window(3)))
        check(h.world.timers.isEmpty, "adoption cancels deferred old focus")
        h.send(.timer(timer), advance: 0.3)
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
        h.advance(0.2)
        check(h.world.frames[hung.tile]!.revision > hung.revision, "retry issued newer revision")
        check(h.world.timers.isEmpty, "fired token consumed")
        let retried = h.world.frames[hung.tile]!
        h.send(.frameCompleted(tile: retried.tile, revision: retried.revision, result: .failed))
        let cancelled = h.world.timers.keys.first!
        let old = h.world.scope(for: 1)!
        h.census(20, [window(3)])
        h.send(.timer(cancelled), scope: old, advance: 0.3)
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
        h.advance(0.3)
        h.send(.pointer(.beginGesture(TileID(1))))
        h.send(.pointer(.delta(300)))
        h.send(.pointer(.endGesture))
        let landed = h.active
        check(landed != TileID(1), "swipe landed away from the focus target")
        h.send(.focus(FocusIntent(tile: TileID(1), pid: 1, source: .appActivation)))
        h.advance(0.2)
        check(h.active == landed, "momentum ignores incremental focus")
        h.send(.tick, advance: 3)
        h.send(.focus(FocusIntent(tile: TileID(1), source: .axFocus)))
        h.advance(0.2)
        check(h.active == landed, "settle echo inside the quiet window is ignored")
        h.advance(EngineConfig.gestureQuiet)
        h.send(.focus(FocusIntent(tile: TileID(1), source: .axFocus)))
        h.advance(0.2)
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
    section("probe 1: an empty destination Space commits after its settle re-read") {
        var h = Harness()
        h.census(10, [window(1), window(2)])
        h.census(30, [])
        check(h.effects.contains { if case .requestCensus(1, EngineConfig.censusSettle) = $0 { return true }; return false },
              "deferred empty census requests a settled re-read")
        h.advance(0.6)
        h.census(30, [])
        check(h.world.groups[1]!.space == .skylight(30), "confirmed empty census commits")
        h.send(.windowAdded(window(5)))
        check(h.tiles == [TileID(5)], "window opened on the empty Space joins its own strip")
        h.census(10, [window(1), window(2)])
        check(h.tiles == [TileID(1), TileID(2)], "departing Space keeps its own columns")
        h.send(.spaceWillChange)
        h.census(40, [])
        h.advance(0.6)
        h.census(40, [])
        h.send(.windowAdded(window(6)))
        check(h.tiles == [TileID(6)], "observed empty switch does not freeze the group")
    }
    section("probe 2: same-Space resolution adopts the census membership") {
        var h = Harness()
        h.census(10, [window(1), window(2)])
        h.send(.spaceWillChange)
        h.send(.windowAdded(window(5)))
        h.send(.windowRemoved(TileID(2)))
        h.send(.spaceChanged(key: .skylight(10), epoch: h.world.groups[1]!.epoch + 1, windows: [window(1), window(5)]))
        check(Set(h.tiles) == [TileID(1), TileID(5)], "census membership wins after a same-Space transition")
        check(h.world.frames[TileID(2)] == nil, "destroyed window loses its frame ownership")
    }
    section("probe 3: fingerprint recovery re-keys the authoritative stash") {
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
    section("probe 4: disk restore matches window identity, not recycled ids") {
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
    section("probe 5: persist keeps unvisited disk Spaces") {
        var h = Harness()
        let unvisited = Snapshot(group: 1, space: .skylight(99), columns: [SnapshotColumn(windows: [window(50)], width: .fixed(400))])
        h.send(.loadSnapshots([unvisited]))
        h.census(10, [window(1)])
        let payload: [Snapshot] = h.effects.compactMap { effect -> [Snapshot]? in if case .persist(let book) = effect { return book.persisted }; return nil }.last ?? []
        check(payload.map { $0.space } == [.skylight(10), .skylight(99)], "persist payload carries unvisited disk entries")
    }
    section("probe 6: a negative preset index is rejected at the codec") {
        let bad = Snapshot(group: 1, space: .skylight(1), columns: [SnapshotColumn(windows: [window(1)], width: .fixed(300), presetIndex: -5)])
        let decoded = (try? Snapshot.decode(Snapshot.encode([bad]))) ?? []
        check(decoded.isEmpty, "negative preset index rejected")
    }
    section("probe 7: gestures clamp and re-anchor the active column") {
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
    section("probe 8: external focus cannot kill a swipe") {
        var h = Harness()
        h.census(10, [window(1), window(2), window(3)])
        h.advance(0.3)
        h.send(.pointer(.beginGesture(TileID(1))))
        let start = h.offset
        h.send(.pointer(.delta(40)))
        h.send(.focus(FocusIntent(tile: TileID(3), pid: 3, source: .appActivation)))
        h.send(.focus(FocusIntent(tile: TileID(3), source: .axFocus)))
        h.advance(0.2)
        check(h.gesture != nil, "swipe survives external focus")
        h.send(.pointer(.delta(40)))
        check(abs(h.offset - start - 80) < 0.001, "later deltas still apply")
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
        switch rng.next(32) {
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
            h.census(UInt64(100 + rng.next(4)), [window(nextID)], group: id)
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
        case 27: h.census(rng.next(2) == 0 ? UInt64(100 + rng.next(4)) : 10, [], group: id)
        case 28, 29:
            let saved = h.world.spaces.live.values.filter { $0.group == id }.sorted { $0.space.debugDescription < $1.space.debugDescription }
            guard let visit = pick(saved) else { h.send(.tick, group: id); break }
            let key: SpaceKey = rng.next(2) == 0 ? .fingerprint(visit.fingerprint) : visit.space
            h.send(.spaceChanged(key: key.isEmpty ? .skylight(10) : key, epoch: epoch, windows: visit.windows), group: id)
        case 30: h.send(.pointer(.cancel), group: id)
        case 31: h.send(.configChanged(EngineConfig(gap: Double(rng.next(20)), animate: rng.next(2) == 0, gestureSnap: rng.next(2) == 0)), group: id)
        default: h.send(.tick, group: id)
        }
        let after = h.world.groups[id]
        if case .fingerprint = after?.space { reached["fingerprint key", default: 0] += 1 }
        if case .crossing = after?.focus { reached["dock crossing", default: 0] += 1 }
        if after?.space != before.space, (after?.strip.columns.count ?? 0) > 1 { reached["multi-column restore", default: 0] += 1 }
        if h.world.groups.count != before.groups { reached["group added or removed", default: 0] += 1 }
        if case .gesture = h.world.pointer, case .animation = after?.strip.viewOffset { reached["gesture during animation", default: 0] += 1 }
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
        let states = ["fingerprint key", "dock crossing", "multi-column restore", "group added or removed"]
        print("  seed=\(seed) reached \(states.map { "\($0)=\(stream.reached[$0, default: 0])" }.joined(separator: " "))")
        for state in states { check(stream.reached[state, default: 0] > 0, "seed=\(seed) fuzz reaches \(state)") }
    }
}

@MainActor func benchmark() {
    guard environment["ENGINE_BENCH"] == "1" else { return }
    var rounds: [Duration] = []
    for _ in 0..<5 {
        var stream = FuzzStream(seed: 0)
        for _ in 0..<10_000 { stream.step() }
        check(stream.h.world.check().isEmpty, "benchmark invariants")
        rounds.append(stream.h.reduceTime)
    }
    let median = rounds.sorted()[2]
    print("ENGINE_BENCH seed=0 events=10000 rounds=\(rounds.map { "\($0)" }) median=\(median)")
    #if !DEBUG
    check(median < .milliseconds(50), "reduce budget: median of 5 rounds of 10,000 events under 50 ms")
    #endif
}

MainActor.assumeIsolated {
    do { try replayTests(); probeTests() }
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
