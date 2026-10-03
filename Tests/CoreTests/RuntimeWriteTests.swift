import CoreGraphics
import Engine
import Runtime

// ReelNext's per-window frame write (`SizeCache`), driven against `FakeAXWindow`.
@MainActor
func runRuntimeWriteTests() {
    print()
    print("Runtime frame writes (SizeCache)")
    let tiled = CGRect(x: 100, y: 25, width: 700, height: 850)

    section("a scroll keeps the size and sets only the position")
    do {
        let w = FakeAXWindow(windowID: 1, pid: 99001, frame: .zero)
        var cache = SizeCache()
        _ = cache.write(tiled, to: w)
        w.currentFrame.size.height = 500  // changed with no notification
        let (result, landed) = cache.write(tiled.offsetBy(dx: -50, dy: 0), to: w)
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
        let second = cache.write(tiled.offsetBy(dx: 40, dy: 0), to: w)
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
        _ = cache.write(tiled.offsetBy(dx: 10, dy: 0), to: w)
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
}
