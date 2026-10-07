import Core
import CoreGraphics
import Engine
import Runtime
import Platform

final class QueuedWriteApp: AXApp, @unchecked Sendable {
    var actions: [@Sendable () -> Void] = []
    override func perform(_ action: @escaping @Sendable () -> Void) -> Bool {
        actions.append(action)
        return true
    }
    override func stopObserving() {}
    func drain() {
        while !actions.isEmpty { actions.removeFirst()() }
    }
}

// ReelNext's per-window frame write (`SizeCache`), driven against `FakeAXWindow`.
@MainActor
func runRuntimeWriteTests() {
    print()
    print("Runtime frame writes (SizeCache)")
    let tiled = CGRect(x: 100, y: 25, width: 700, height: 850)

    section("a window cancelled during its sibling's drained write is never physically written")
    do {
        for requeue in [false, true] {
            let app = QueuedWriteApp(pid: 99001, bundleIdentifier: nil)
            let first = FakeAXWindow(windowID: 1, pid: 99001, frame: .zero)
            let second = FakeAXWindow(windowID: 2, pid: 99001, frame: .zero)
            let third = FakeAXWindow(windowID: 3, pid: 99001, frame: .zero)
            let worker = AppWorker(app: app, windows: [1: first, 2: second, 3: third], clock: ScopeClock(), send: { _, _ in })
            let display = Display(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 830), area: CGRect(x: 0, y: 30, width: 1000, height: 800))
            var world = World(topology: Topology(revision: 1, displays: [display], separateSpaces: true, primaryScreenHeight: 830),
                              config: EngineConfig(animate: false))
            let observed = (1...3).map { ObservedWindow(id: TileID(UInt32($0)), pid: 99001, bundleID: nil) }
            _ = reduce(&world, Event(scope: world.scope(for: 1)!, kind: .spaceChanged(key: .skylight(1), epoch: 1, windows: observed)), now: 1)
            let initial = world.frames
            _ = reduce(&world, Event(scope: world.scope(for: 1)!, kind: .configChanged(EngineConfig(gap: 30, animate: false))), now: 2)
            let replacement = world.frames[TileID(2)]!
            first.onFrameWrite = {
                worker.cancelWrite(TileID(2))
                if requeue {
                    worker.write(replacement)
                }
            }
            for id: UInt32 in [1, 2, 3] {
                worker.write(initial[TileID(id)]!)
            }
            app.drain()
            assertEq(first.frameWriteCount, 1, "the already-started write finishes")
            assertEq(second.frameWriteCount, requeue ? 1 : 0, "the cancelled request never reaches AX")
            assertEq(second.currentFrame, requeue ? replacement.frame.rect : .zero, "only a fresh request can write the cancelled window")
            assertEq(third.frameWriteCount, 1, "cancelling one window preserves its unrelated sibling")
        }
    }

    section("release requests accept successful positioning without a delayed layout confirmation")
    do {
        let area = CGRect(x: 0, y: 30, width: 1000, height: 800)
        let display = Display(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 830), area: area)
        var world = World(topology: Topology(revision: 1, displays: [display], separateSpaces: true, primaryScreenHeight: 830),
                          config: EngineConfig(animate: false))
        let windows = (1...5).map { ObservedWindow(id: TileID(UInt32($0)), pid: 99001, bundleID: nil) }
        let scope = world.scope(for: 1)!
        _ = reduce(&world, Event(scope: scope, kind: .spaceChanged(key: .skylight(4), epoch: 1, windows: windows)), now: 1)
        let effects = reduce(&world, Event(scope: world.scope(for: 1)!, kind: .command(.release, .ipc)), now: 2)
        let requests = effects.compactMap { effect -> FrameRequest? in
            if case .setFrame(let request) = effect { return request }
            return nil
        }
        check(!requests.isEmpty, "the five-column strip emits release writes")
        for request in requests {
            let w = FakeAXWindow(windowID: request.tile.rawValue, pid: 99001, frame: CGRect(x: -499, y: 30, width: 500, height: 600))
            w.shortNextFrame = CGSize(width: request.frame.rect.width, height: 705)
            var cache = SizeCache()
            let outcome = cache.write(request, to: w)
            check(outcome.result == .applied, "release is applied even when the first size read is short")
            check(area.contains(w.currentFrame), "the released fake AX window is fully on screen")
        }
    }

    section("release clamped size stays on screen and errors remain errors")
    do {
        let area = CGRect(x: 0, y: 30, width: 1000, height: 800)
        let display = Display(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 830), area: area)
        var world = World(topology: Topology(revision: 1, displays: [display], separateSpaces: true, primaryScreenHeight: 830), config: EngineConfig(animate: false))
        let windows = (1...5).map { ObservedWindow(id: TileID(UInt32($0)), pid: 99001, bundleID: nil) }
        _ = reduce(&world, Event(scope: world.scope(for: 1)!, kind: .spaceChanged(key: .skylight(4), epoch: 1, windows: windows)), now: 1)
        let effects = reduce(&world, Event(scope: world.scope(for: 1)!, kind: .command(.release, .ipc)), now: 2)
        let requests = effects.compactMap { if case .setFrame(let request) = $0 { return request }; return nil }
        check(!requests.isEmpty, "release emits requests for clipped windows")
        for request in requests {
            if case .release(let bounds) = request.purpose {
                assertEq(bounds.rect, area, "the release request carries its owning display's bounds")
            } else { check(false, "release bounds reach the write path") }
            let w = FakeAXWindow(windowID: request.tile.rawValue, pid: 99001, frame: CGRect(x: -499, y: 30, width: 500, height: 600))
            w.minSize = CGSize(width: 990, height: 800)
            var cache = SizeCache()
            let outcome = cache.write(request, to: w)
            check(outcome.result == .applied && area.contains(w.currentFrame), "successful release of a clamped window is fully contained")
            assertEq(outcome.landed, w.currentFrame, "release reports the real corrected frame, including its origin")
            check(w.positionWriteCount <= 1, "release uses at most one position-only correction")
            w.failNextSet = true
            var failedCache = SizeCache()
            check(failedCache.write(request, to: w).result == .failed, "real AX write failures remain failures")
            w.timeoutNextSet = true
            var timedCache = SizeCache()
            check(timedCache.write(request, to: w).result == .timedOut, "real AX timeouts remain timeouts")
            w.minSize.width = 1001
            var impossibleCache = SizeCache()
            check(impossibleCache.write(request, to: w).result == .failed, "an app wider than its display cannot report successful release")
            w.minSize.width = 990
            w.failsFrameRead = true
            var unreadableCache = SizeCache()
            check(unreadableCache.write(request, to: w).result == .failed, "unreadable landed frames cannot confirm release")
            w.failsFrameRead = false
            if request.frame.rect.minX > 10 {
                w.resistsOffscreen = true
                var refusedCache = SizeCache()
                check(refusedCache.write(request, to: w).result == .failed, "a rejected corrective position remains a failure")
                w.resistsOffscreen = false
                w.positionOffset = 50
                let writesBefore = w.positionWriteCount
                var shiftedCache = SizeCache()
                check(shiftedCache.write(request, to: w).result == .failed, "a successful AX call that still leaves clipping is not a successful release")
                assertEq(w.positionWriteCount - writesBefore, 1, "a refused correction is bounded to one attempt")
            }
        }
    }

    section("a short startup read is repaired by the next settled write")
    do {
        let w = FakeAXWindow(windowID: 90, pid: 99001, frame: .zero)
        w.shortNextFrame = CGSize(width: 700, height: 767)
        var cache = SizeCache()
        let first = cache.write(tiled, to: w)
        assertEq(w.currentFrame.height, 767, "the startup short height reproduces")
        check(first.result == .sizeUnconfirmed, "the first short write requests delayed size confirmation")
        let second = cache.write(tiled, to: w)
        assertEq(w.currentFrame, tiled, "a settled write resends the refused size")
        check(second.result == .sizeUnconfirmed, "the retry requests a fresh delayed read after resizing")
        let confirmed = cache.write(tiled.offsetBy(dx: 10, dy: 0), to: w)
        check(confirmed.result == .applied, "a verified kept size stops delayed confirmation")
        assertEq(w.frameWriteCount, 2, "a successful retry returns to position-only writes")
    }

    section("late resize notifications do not reset a stable refusal budget forever")
    do {
        let w = FakeAXWindow(windowID: 95, pid: 99001, frame: .zero)
        var cache = SizeCache()
        _ = cache.write(tiled, to: w)
        for _ in 0..<20 {
            w.currentFrame.size.height = 767
            cache.observed(w.windowID, frame: w.currentFrame)
            _ = cache.write(tiled, to: w)
        }
        assertEq(w.frameWriteCount, 4, "one initial write and three refused retries despite late AX notifications")
        assertEq(w.currentFrame.height, 767, "a stable asynchronous clamp eventually keeps the cheap path")
    }

    section("a position-dependent refusal is retried when the column reaches a new settled origin")
    do {
        let w = FakeAXWindow(windowID: 94, pid: 99001, frame: .zero)
        w.minSize = CGSize(width: 900, height: 0)
        var cache = SizeCache()
        for _ in 0..<20 { _ = cache.write(tiled, to: w) }
        assertEq(w.frameWriteCount, 3, "a stable clamp remains bounded")
        w.minSize = .zero
        _ = cache.write(tiled.offsetBy(dx: 400, dy: 0), to: w)
        assertEq(w.currentFrame.size, tiled.size, "a new fully visible position does not inherit offscreen refusals forever")
        assertEq(w.frameWriteCount, 4, "the new origin gets one fresh full write")
    }

    section("a late clamp after a successful read-back is repaired on settle")
    do {
        let w = FakeAXWindow(windowID: 93, pid: 99001, frame: .zero)
        var cache = SizeCache()
        _ = cache.write(tiled, to: w, animating: true)
        w.currentFrame.size.height = 767
        _ = cache.write(tiled, to: w, animating: true)
        assertEq(w.currentFrame.height, 767, "animation does not reread a late clamp")
        _ = cache.write(tiled, to: w)
        assertEq(w.currentFrame, tiled, "settle rereads actual size rather than trusting immediate read-back forever")
        assertEq(w.frameWriteCount, 2, "late clamping is retried once")
    }

    section("animation never burns the settled resize retry budget")
    do {
        let w = FakeAXWindow(windowID: 92, pid: 99001, frame: .zero)
        w.shortNextFrame = CGSize(width: 700, height: 767)
        var cache = SizeCache()
        _ = cache.write(tiled, to: w, animating: true)
        for x in 0..<100 { _ = cache.write(tiled.offsetBy(dx: Double(x), dy: 0), to: w, animating: true) }
        assertEq(w.frameWriteCount, 1, "scroll ticks remain position-only")
        _ = cache.write(tiled, to: w)
        assertEq(w.currentFrame, tiled, "settle repairs the short startup read after animation")
        assertEq(w.frameWriteCount, 2, "animation did not exhaust retries")
    }

    section("a stable clamp stops retrying after three actual size writes")
    do {
        let w = FakeAXWindow(windowID: 91, pid: 99001, frame: .zero)
        w.minSize = CGSize(width: 900, height: 0)
        var cache = SizeCache()
        let results = (0..<20).map { _ in cache.write(tiled, to: w).result }
        check(results[0] == .sizeUnconfirmed && results[1] == .sizeUnconfirmed,
              "the first two refused writes request delayed confirmation")
        check(results.dropFirst(2).allSatisfy { $0 == .applied }, "the refusal bound stops confirmation requests")
        assertEq(w.frameWriteCount, 3, "only three full writes for an identical refused size")
        assertEq(w.positionWriteCount, 17, "subsequent settles keep the cheap position path")
        _ = cache.write(CGRect(x: 100, y: 25, width: 750, height: 850), to: w)
        assertEq(w.frameWriteCount, 4, "a new request resets the refusal bound")
        cache.forgetAll()
        _ = cache.write(tiled, to: w)
        assertEq(w.frameWriteCount, 5, "recover resets the bound")
    }

    section("a scroll keeps the size and sets only the position")
    do {
        let w = FakeAXWindow(windowID: 1, pid: 99001, frame: .zero)
        var cache = SizeCache()
        _ = cache.write(tiled, to: w)
        w.currentFrame.size.height = 500  // changed with no notification
        let (result, landed) = cache.write(tiled.offsetBy(dx: -50, dy: 0), to: w, animating: true)
        check(result == .applied, "the position write applies")
        assertEq(w.currentFrame, CGRect(x: 50, y: 25, width: 700, height: 500), "only the position moved")
        assertEq(landed, CGRect(x: 50, y: 25, width: 700, height: 850), "landed is the size the app kept at the last full write")
    }

    section("an app that clamps the width: landed reports the clamp, and the next scroll echoes it")
    do {
        let w = FakeAXWindow(windowID: 2, pid: 99001, frame: .zero)
        w.minSize = CGSize(width: 900, height: 0)
        var cache = SizeCache()
        let first = cache.write(tiled, to: w)
        assertEq(first.landed, CGRect(x: 100, y: 25, width: 900, height: 850), "the read-back carries the clamped width")
        let second = cache.write(tiled.offsetBy(dx: 40, dy: 0), to: w, animating: true)
        assertEq(second.landed, CGRect(x: 140, y: 25, width: 900, height: 850), "the scroll reports the kept width")
        assertEq(w.currentFrame, CGRect(x: 140, y: 25, width: 900, height: 850), "the window keeps its clamp")
    }

    section("recover after the user changed only the height writes the size again")
    do {
        let w = FakeAXWindow(windowID: 3, pid: 99001, frame: .zero)
        var cache = SizeCache()
        _ = cache.write(tiled, to: w)
        w.currentFrame.size.height = 500
        cache.observed(w.windowID, frame: w.currentFrame)
        _ = cache.write(tiled, to: w)
        assertEq(w.currentFrame, tiled, "the height is restored")
    }

    section("recover after a missed notification writes the size again")
    do {
        let w = FakeAXWindow(windowID: 7, pid: 99001, frame: .zero)
        var cache = SizeCache()
        _ = cache.write(tiled, to: w)
        w.currentFrame.size.height = 500
        cache.forgetAll()
        _ = cache.write(tiled, to: w)
        assertEq(w.currentFrame, tiled, "the size is restored")
    }

    section("a width change seen in a notification makes the next write set the size")
    do {
        let w = FakeAXWindow(windowID: 4, pid: 99001, frame: .zero)
        var cache = SizeCache()
        _ = cache.write(tiled, to: w)
        w.currentFrame.size.width = 600
        cache.observed(w.windowID, frame: w.currentFrame)
        _ = cache.write(tiled, to: w)
        assertEq(w.currentFrame, tiled, "the width is restored")
    }

    section("an echo within the slop keeps the position-only path")
    do {
        let w = FakeAXWindow(windowID: 5, pid: 99001, frame: .zero)
        var cache = SizeCache()
        _ = cache.write(tiled, to: w)
        cache.observed(w.windowID, frame: CGRect(x: 100, y: 25, width: 700.5, height: 849.5))
        w.currentFrame.size.height = 500
        _ = cache.write(tiled.offsetBy(dx: 10, dy: 0), to: w, animating: true)
        assertEq(w.currentFrame.height, 500, "still a position write")
    }

    section("a write that asks for a new height sets the size")
    do {
        let w = FakeAXWindow(windowID: 8, pid: 99001, frame: .zero)
        var cache = SizeCache()
        _ = cache.write(tiled, to: w)
        _ = cache.write(CGRect(x: 100, y: 25, width: 700, height: 600), to: w)
        assertEq(w.currentFrame.height, 600, "the new height lands")
    }

    section("a user drag between the write and its read-back is not reported as ours")
    do {
        let w = FakeAXWindow(windowID: 9, pid: 99001, frame: .zero)
        w.dragAfterNextSet = 300
        var cache = SizeCache()
        let (_, landed) = cache.write(tiled, to: w)
        assertEq(landed, tiled, "landed keeps the origin we asked for")
    }

    section("a failed write makes the next one set the size")
    do {
        let w = FakeAXWindow(windowID: 6, pid: 99001, frame: .zero)
        var cache = SizeCache()
        _ = cache.write(tiled, to: w)
        w.failNextSet = true
        let failed = cache.write(tiled.offsetBy(dx: 10, dy: 0), to: w)
        check(failed.result == .failed && failed.landed == nil, "a hard failure reports failed")
        w.currentFrame.size.height = 500
        _ = cache.write(tiled, to: w)
        assertEq(w.currentFrame, tiled, "a full write follows the failure")
    }

    section("a timed-out write reports timedOut, so its late echo stays ours")
    do {
        let w = FakeAXWindow(windowID: 7, pid: 99001, frame: .zero)
        var cache = SizeCache()
        w.timeoutNextSet = true
        check(cache.write(tiled, to: w).result == .timedOut, "a timeout is not a failure")
    }
}
