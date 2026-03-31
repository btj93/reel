import Foundation
import Core
import CoreGraphics

// Simple test runner — no Xcode or XCTest required
var passed = 0
var failed = 0
var errors: [String] = []

func check(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        let loc = URL(fileURLWithPath: file).lastPathComponent
        errors.append("  FAIL \(loc):\(line) — \(message)")
    }
}

func assertEq<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #file, line: Int = #line) {
    check(a == b, "\(message) (got \(a), expected \(b))", file: file, line: line)
}

func assertClose(_ a: Double, _ b: Double, tolerance: Double = 1.0, _ message: String = "", file: String = #file, line: Int = #line) {
    check(abs(a - b) < tolerance, "\(message) (got \(a), expected \(b) ± \(tolerance))", file: file, line: line)
}

func section(_ name: String) {
    print("  ▸ \(name)")
}

// MARK: - Helper

func makeStrip(columnCount: Int, width: Double = 0.5, gap: Double = 16, screenWidth: Double = 1440, screenHeight: Double = 900) -> Strip {
    let wa = CGRect(x: 0, y: 25, width: screenWidth, height: screenHeight - 25)
    var columns: [Column] = []
    var columnData: [ColumnData] = []
    for i in 0..<columnCount {
        columns.append(Column(tiles: [TileID(UInt32(i + 1))], width: .proportion(width)))
        columnData.append(ColumnData(cachedWidth: wa.width * width))
    }
    return Strip(columns: columns, columnData: columnData, activeColumnIndex: 0, viewOffset: .static(0), focusMode: .always, gap: gap, workingArea: wa)
}

func makeLayoutStrip(widths: [Double], activeIndex: Int = 0, viewOffset: Double = 0) -> Strip {
    let wa = CGRect(x: 0, y: 25, width: 1440, height: 875)
    var columns: [Column] = []
    var columnData: [ColumnData] = []
    for (i, w) in widths.enumerated() {
        columns.append(Column(tiles: [TileID(UInt32(i + 1))], width: .fixed(w)))
        columnData.append(ColumnData(cachedWidth: w))
    }
    return Strip(columns: columns, columnData: columnData, activeColumnIndex: activeIndex, viewOffset: .static(viewOffset), gap: 16, workingArea: wa)
}

// ============================================================
print("━━━ ScrollWM Core Tests ━━━")
print()

// MARK: - Strip Tests
print("Strip Tests")

section("Empty strip")
do {
    let strip = Strip()
    check(strip.columns.isEmpty, "should be empty")
    assertEq(strip.totalWidth, 0, "total width should be 0")
    check(strip.activeColumn == nil, "no active column")
}

section("Single column")
do {
    let strip = makeStrip(columnCount: 1)
    assertEq(strip.columns.count, 1)
    assertEq(strip.activeColumnIndex, 0)
    check(strip.activeColumn != nil)
}

section("Column X positions")
do {
    let strip = makeStrip(columnCount: 3, gap: 16)
    let colWidth = 1440.0 * 0.5
    assertClose(strip.columnX(at: 0), 0, tolerance: 0.01, "col 0")
    assertClose(strip.columnX(at: 1), colWidth + 16, tolerance: 0.01, "col 1")
    assertClose(strip.columnX(at: 2), 2 * (colWidth + 16), tolerance: 0.01, "col 2")
}

section("Focus right")
do {
    var strip = makeStrip(columnCount: 3)
    strip.focusRight(at: 0)
    assertEq(strip.activeColumnIndex, 1, "should be 1")
    strip.focusRight(at: 0)
    assertEq(strip.activeColumnIndex, 2, "should be 2")
    strip.focusRight(at: 0)
    assertEq(strip.activeColumnIndex, 2, "should stay at 2 (boundary)")
}

section("Focus left")
do {
    var strip = makeStrip(columnCount: 3)
    strip.activeColumnIndex = 2
    strip.focusLeft(at: 0)
    assertEq(strip.activeColumnIndex, 1)
    strip.focusLeft(at: 0)
    assertEq(strip.activeColumnIndex, 0)
    strip.focusLeft(at: 0)
    assertEq(strip.activeColumnIndex, 0, "should stay at 0 (boundary)")
}

section("Insert column")
do {
    var strip = makeStrip(columnCount: 2)
    let newCol = Column(tiles: [TileID(99)], width: .proportion(0.5))
    strip.insertColumn(newCol, at: 0)
    assertEq(strip.columns.count, 3)
    assertEq(strip.activeColumnIndex, 1, "new column should be focused")
    assertEq(strip.columns[1].tiles.first, TileID(99))
}

section("Remove column — focus moves right")
do {
    var strip = makeStrip(columnCount: 3)
    strip.activeColumnIndex = 1
    strip.removeColumn(at: 1, at: 0)
    assertEq(strip.columns.count, 2)
    assertEq(strip.activeColumnIndex, 1, "should focus the right neighbor")
}

section("Remove first column — focus moves right")
do {
    var strip = makeStrip(columnCount: 3)
    strip.activeColumnIndex = 0
    strip.removeColumn(at: 0, at: 0)
    assertEq(strip.columns.count, 2)
    assertEq(strip.activeColumnIndex, 0, "should focus right neighbor (now at index 0)")
}

section("Remove last column")
do {
    var strip = makeStrip(columnCount: 1)
    strip.removeColumn(at: 0, at: 0)
    check(strip.columns.isEmpty)
}

section("Remove rightmost column — focus moves left")
do {
    var strip = makeStrip(columnCount: 3)
    strip.activeColumnIndex = 2
    strip.removeColumn(at: 2, at: 0)
    assertEq(strip.columns.count, 2)
    assertEq(strip.activeColumnIndex, 1, "no right neighbor, should focus left")
}

section("Move column right")
do {
    var strip = makeStrip(columnCount: 3)
    let t0 = strip.columns[0].tiles[0]
    let t1 = strip.columns[1].tiles[0]
    strip.moveColumnRight(at: 0)
    assertEq(strip.activeColumnIndex, 1)
    assertEq(strip.columns[0].tiles[0], t1)
    assertEq(strip.columns[1].tiles[0], t0)
}

section("Cycle width preset")
do {
    var strip = makeStrip(columnCount: 1)
    strip.widthPresets = [.proportion(0.33), .proportion(0.5), .proportion(0.67)]
    strip.cycleWidthPreset()
    assertEq(strip.columns[0].presetIndex, 0)
    strip.cycleWidthPreset()
    assertEq(strip.columns[0].presetIndex, 1)
    strip.cycleWidthPreset()
    assertEq(strip.columns[0].presetIndex, 2)
    strip.cycleWidthPreset()
    assertEq(strip.columns[0].presetIndex, 0, "should wrap")
}

section("Toggle full width")
do {
    var strip = makeStrip(columnCount: 2)
    check(!strip.columns[0].isFullWidth)
    strip.toggleFullWidth()
    check(strip.columns[0].isFullWidth)
    assertClose(strip.columnData[0].cachedWidth, strip.workingArea.width, tolerance: 0.01)
    strip.toggleFullWidth()
    check(!strip.columns[0].isFullWidth)
}

// MARK: - Layout Engine Tests
print()
print("Layout Engine Tests")

section("Empty strip → no frames")
do {
    let frames = computeTargetFrames(strip: Strip(), time: 0)
    check(frames.isEmpty)
}

section("Single column visible")
do {
    let strip = makeLayoutStrip(widths: [720], viewOffset: -(1440 - 720) / 2)
    let frames = computeTargetFrames(strip: strip, time: 0)
    assertEq(frames.count, 1)
    check(frames[0].isVisible)
    check(!frames[0].isOffScreen)
}

section("Off-screen column gets sliver")
do {
    let strip = makeLayoutStrip(widths: [720, 720, 720], viewOffset: 0)
    let frames = computeTargetFrames(strip: strip, time: 0, sliverWidth: 1)
    check(frames[2].isOffScreen, "third column should be off-screen")
    assertClose(frames[2].frame.minX, 1440 - 1, tolerance: 2, "sliver at right edge")
}

section("Vertical stacking")
do {
    let wa = CGRect(x: 0, y: 25, width: 1440, height: 875)
    let column = Column(tiles: [TileID(1), TileID(2)], width: .fixed(720))
    let strip = Strip(columns: [column], columnData: [ColumnData(cachedWidth: 720)], activeColumnIndex: 0, viewOffset: .static(0), gap: 16, workingArea: wa)
    let frames = computeTargetFrames(strip: strip, time: 0)
    assertEq(frames.count, 2)
    let expectedHeight = (875 - 16) / 2.0
    assertClose(frames[0].frame.height, expectedHeight, tolerance: 1, "tile height")
    check(frames[1].frame.minY > frames[0].frame.minY, "second tile below first")
}

// MARK: - Animation Tests
print()
print("Animation Tests")

section("Critical damping converges")
do {
    let params = SpringParams(dampingRatio: 1.0, stiffness: 800)
    let (d0, _) = params.solve(x0: 100, v0: 0, t: 0)
    assertClose(d0, 100, tolerance: 0.01)
    let (d1, _) = params.solve(x0: 100, v0: 0, t: 0.5)
    check(abs(d1) < 1.0, "should be near target at t=0.5 (got \(d1))")
    let (d2, _) = params.solve(x0: 100, v0: 0, t: 2.0)
    check(abs(d2) < 0.001, "should be converged at t=2.0 (got \(d2))")
}

section("Underdamped oscillates")
do {
    let params = SpringParams(dampingRatio: 0.5, stiffness: 800)
    var crossedZero = false
    var last: Double = 100
    for i in 1...100 {
        let (d, _) = params.solve(x0: 100, v0: 0, t: Double(i) * 0.01)
        if d * last < 0 { crossedZero = true; break }
        last = d
    }
    check(crossedZero, "underdamped should oscillate")
}

section("Overdamped does not oscillate")
do {
    let params = SpringParams(dampingRatio: 2.0, stiffness: 800)
    for i in 1...200 {
        let (d, _) = params.solve(x0: 100, v0: 0, t: Double(i) * 0.01)
        check(d >= -0.01, "overdamped at t=\(Double(i)*0.01): \(d)")
    }
}

section("Spring animation retarget")
do {
    let anim = SpringAnimation(from: 0, to: 500, initialVelocity: 0, startTime: 0, params: .horizontalScroll)
    let (midVal, midVel) = anim.evaluate(at: 0.1)
    check(midVal > 0 && midVal < 500, "mid-flight value: \(midVal)")
    let retargeted = anim.retargeted(to: 1000, at: 0.1)
    assertClose(retargeted.from, midVal, tolerance: 0.01)
    assertEq(retargeted.to, 1000.0)
    let (final, _) = retargeted.evaluate(at: 2.0)
    assertClose(final, 1000, tolerance: 0.1, "should converge to new target")
}

section("Easing curves bounded [0,1]")
do {
    let curves: [EasingCurve] = [.linear, .easeOutExpo, .easeOutQuad, .easeOutCubic]
    for curve in curves {
        assertClose(curve.apply(0), 0, tolerance: 0.01)
        assertClose(curve.apply(1), 1, tolerance: 0.01)
    }
}

// MARK: - SwipeTracker Tests
print()
print("SwipeTracker Tests")

section("Velocity estimation")
do {
    var tracker = SwipeTracker()
    for i in 0..<10 {
        tracker.push(delta: 50, timestamp: Double(i) * 0.01)
    }
    let vel = tracker.velocity()
    check(vel > 4000 && vel < 7000, "velocity: \(vel)")
}

section("Window trimming")
do {
    var tracker = SwipeTracker()
    tracker.push(delta: 100, timestamp: 0.0)
    tracker.push(delta: 100, timestamp: 0.05)
    tracker.push(delta: 10, timestamp: 0.200)
    tracker.push(delta: 10, timestamp: 0.250)
    let vel = tracker.velocity()
    check(vel < 600, "old events should be trimmed, got \(vel)")
}

// MARK: - Window Classification Tests
print()
print("Window Classification Tests")

section("Standard window → tile")
do {
    let props = WindowProperties(role: "AXWindow", subrole: "AXStandardWindow", isResizable: true, hasCloseButton: true)
    assertEq(classifyWindow(props), .tile)
}

section("Dialog → float")
do {
    let props = WindowProperties(role: "AXWindow", subrole: "AXDialog", isResizable: false, hasCloseButton: true)
    assertEq(classifyWindow(props), .float)
}

section("Menu → ignore")
do {
    let props = WindowProperties(role: "AXMenu", subrole: nil, isResizable: false, hasCloseButton: false)
    assertEq(classifyWindow(props), .ignore)
}

section("Non-zero layer → ignore")
do {
    let props = WindowProperties(role: "AXWindow", subrole: "AXStandardWindow", isResizable: true, hasCloseButton: true, windowLayer: 1)
    assertEq(classifyWindow(props), .ignore)
}

// ═══════════════════════════════════════
// ColumnWidth Codable
// ═══════════════════════════════════════
print()
print("═ ColumnWidth Codable")

section("Encode/decode proportion")
do {
    let width = ColumnWidth.proportion(0.5)
    let data = try! JSONEncoder().encode(width)
    let json = String(data: data, encoding: .utf8)!
    check(json.contains("proportion"), "should contain 'proportion' key: \(json)")
    let decoded = try! JSONDecoder().decode(ColumnWidth.self, from: data)
    assertEq(decoded, width, "round-trip proportion")
}

section("Encode/decode fixed")
do {
    let width = ColumnWidth.fixed(800.0)
    let data = try! JSONEncoder().encode(width)
    let json = String(data: data, encoding: .utf8)!
    check(json.contains("fixed"), "should contain 'fixed' key: \(json)")
    let decoded = try! JSONDecoder().decode(ColumnWidth.self, from: data)
    assertEq(decoded, width, "round-trip fixed")
}

section("Encode/decode auto")
do {
    let width = ColumnWidth.auto
    let data = try! JSONEncoder().encode(width)
    let json = String(data: data, encoding: .utf8)!
    check(json.contains("auto"), "should contain 'auto' key: \(json)")
    let decoded = try! JSONDecoder().decode(ColumnWidth.self, from: data)
    assertEq(decoded, width, "round-trip auto")
}

// ═══════════════════════════════════════
// Strip insertColumn at index
// ═══════════════════════════════════════
print()
print("═ Strip insertColumn at index")

section("Insert at specific index 0")
do {
    var strip = makeStrip(columnCount: 3)
    let newCol = Column(tiles: [TileID(99)], width: .proportion(0.5))
    strip.insertColumn(newCol, at: 0, atIndex: 0)
    assertEq(strip.columns.count, 4, "should have 4 columns")
    assertEq(strip.columns[0].tiles.first, TileID(99), "new column at index 0")
}

section("Insert at specific index end")
do {
    var strip = makeStrip(columnCount: 3)
    let newCol = Column(tiles: [TileID(99)], width: .proportion(0.5))
    strip.insertColumn(newCol, at: 0, atIndex: 3)
    assertEq(strip.columns.count, 4, "should have 4 columns")
    assertEq(strip.columns[3].tiles.first, TileID(99), "new column at end")
}

section("Insert at clamped index")
do {
    var strip = makeStrip(columnCount: 2)
    let newCol = Column(tiles: [TileID(99)], width: .proportion(0.5))
    strip.insertColumn(newCol, at: 0, atIndex: 10)
    assertEq(strip.columns.count, 3, "should have 3 columns")
    assertEq(strip.columns[2].tiles.first, TileID(99), "clamped to end")
}

// ============================================================
print()
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
if failed == 0 {
    print("✓ All \(passed) tests passed")
} else {
    print("✗ \(failed) failed, \(passed) passed")
    for err in errors { print(err) }
}
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

exit(failed > 0 ? 1 : 0)
