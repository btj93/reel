import Foundation
import Core
import CoreGraphics
import Config
import IPC
import TOMLKit
import WindowManager
import Platform

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

func makeStrip(columnCount: Int, width: Double = 0.5, gap: Double = 16, screenWidth: Double = 1440, screenHeight: Double = 900, snapPoints: [SnapPoint] = [.middle]) -> Strip {
    let wa = CGRect(x: 0, y: 25, width: screenWidth, height: screenHeight - 25)
    var columns: [Column] = []
    var columnData: [ColumnData] = []
    for i in 0..<columnCount {
        columns.append(Column(tiles: [TileID(UInt32(i + 1))], width: .proportion(width)))
        columnData.append(ColumnData(cachedWidth: wa.width * width))
    }
    let defaultIdx = snapPoints.firstIndex(of: .middle) ?? (snapPoints.count - 1) / 2
    let snapIndices = Array(repeating: defaultIdx, count: columnCount)
    return Strip(columns: columns, columnData: columnData, activeColumnIndex: 0, viewOffset: .static(0), snapPoints: snapPoints, snapIndices: snapIndices, gap: gap, workingArea: wa)
}

func makeLayoutStrip(widths: [Double], activeIndex: Int = 0, viewOffset: Double = 0) -> Strip {
    let wa = CGRect(x: 0, y: 25, width: 1440, height: 875)
    var columns: [Column] = []
    var columnData: [ColumnData] = []
    for (i, w) in widths.enumerated() {
        columns.append(Column(tiles: [TileID(UInt32(i + 1))], width: .fixed(w)))
        columnData.append(ColumnData(cachedWidth: w))
    }
    let snapIndices = Array(repeating: 0, count: widths.count)
    return Strip(columns: columns, columnData: columnData, activeColumnIndex: activeIndex, viewOffset: .static(viewOffset), snapIndices: snapIndices, gap: 16, workingArea: wa)
}

// ============================================================
print("━━━ Reel Core Tests ━━━")
print()

// MARK: - Strip Tests
print("Strip Tests")

section("Empty strip")
do {
    let strip = Strip()
    check(strip.columns.isEmpty, "should be empty")
    assertEq(strip.totalWidth(at: 0), 0, "total width should be 0")
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
    strip.cycleWidthPreset(at: 0, params: nil)
    assertEq(strip.columns[0].presetIndex, 0)
    strip.cycleWidthPreset(at: 0, params: nil)
    assertEq(strip.columns[0].presetIndex, 1)
    strip.cycleWidthPreset(at: 0, params: nil)
    assertEq(strip.columns[0].presetIndex, 2)
    strip.cycleWidthPreset(at: 0, params: nil)
    assertEq(strip.columns[0].presetIndex, 0, "should wrap")
}

section("Toggle full width")
do {
    var strip = makeStrip(columnCount: 2)
    check(!strip.columns[0].isFullWidth)
    strip.toggleFullWidth(at: 0)
    check(strip.columns[0].isFullWidth)
    assertClose(strip.columnData[0].cachedWidth, strip.workingArea.width, tolerance: 0.01)
    strip.toggleFullWidth(at: 0)
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
    let strip = Strip(columns: [column], columnData: [ColumnData(cachedWidth: 720)], activeColumnIndex: 0, viewOffset: .static(0), snapIndices: [0], gap: 16, workingArea: wa)
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

section("SpringParams precomputed regime — critical")
do {
    let params = SpringParams(dampingRatio: 1.0, stiffness: 800)
    let times: [Double] = [0, 0.01, 0.05, 0.1, 0.3, 0.5, 1.0, 2.0]
    let expected: [(Double, Double)] = [
        (100.0, -50.0),
        (96.30312305093057, -629.934513694812),
        (58.08577991500826, -967.4318253047313),
        (22.332675603806926, -467.4424449835371),
        (0.19275982986168097, -4.878366977817575),
        (0.0010742503874700989, -0.02838015940249447),
        (1.49779477471394e-09, -4.091827408768751e-08),
        (1.5316838538913174e-21, -4.257025796237067e-20),
    ]
    for (i, t) in times.enumerated() {
        let (d, v) = params.solve(x0: 100, v0: -50, t: t)
        assertClose(d, expected[i].0, tolerance: 1e-10, "critical d at t=\(t)")
        assertClose(v, expected[i].1, tolerance: 1e-10, "critical v at t=\(t)")
    }
}

section("SpringParams precomputed regime — underdamped")
do {
    let params = SpringParams(dampingRatio: 0.5, stiffness: 800)
    let times: [Double] = [0, 0.01, 0.05, 0.1, 0.3, 0.5, 1.0, 2.0]
    let expected: [(Double, Double)] = [
        (100.0, -50.0),
        (95.94595202614556, -723.607700947456),
        (42.55716290123872, -1509.8648634721399),
        (-10.076984071510532, -492.8697772969101),
        (1.396057248304523, -41.046085525326596),
        (0.0658184980668828, 0.8217202990376328),
        (3.402950711879452e-05, 0.0013614986174029186),
        (-1.259344258226379e-11, 1.6040561037902914e-09),
    ]
    for (i, t) in times.enumerated() {
        let (d, v) = params.solve(x0: 100, v0: -50, t: t)
        assertClose(d, expected[i].0, tolerance: 1e-10, "underdamped d at t=\(t)")
        assertClose(v, expected[i].1, tolerance: 1e-10, "underdamped v at t=\(t)")
    }
}

section("SpringParams precomputed regime — overdamped")
do {
    let params = SpringParams(dampingRatio: 2.0, stiffness: 800)
    let times: [Double] = [0, 0.01, 0.05, 0.1, 0.3, 0.5, 1.0, 2.0]
    let expected: [(Double, Double)] = [
        (100.0, -50.0),
        (96.88460288658496, -487.9310691313741),
        (73.36793751840405, -552.424762910267),
        (50.25189607665591, -380.82800490771234),
        (11.037543369066283, -83.6507557515311),
        (2.424324593174694, -18.373344287323253),
        (0.05481338558734754, -0.4154168166199714),
        (2.802065919177662e-05, -0.00021236150470019258),
    ]
    for (i, t) in times.enumerated() {
        let (d, v) = params.solve(x0: 100, v0: -50, t: t)
        assertClose(d, expected[i].0, tolerance: 1e-10, "overdamped d at t=\(t)")
        assertClose(v, expected[i].1, tolerance: 1e-10, "overdamped v at t=\(t)")
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
    check(vel > 2000 && vel < 3500, "velocity: \(vel)")
}

section("Weighted velocity ignores stale samples")
do {
    var tracker = SwipeTracker()
    tracker.push(delta: 100, timestamp: 0.0)
    tracker.push(delta: 100, timestamp: 0.05)
    tracker.push(delta: 10, timestamp: 0.200)
    tracker.push(delta: 10, timestamp: 0.250)
    let vel = tracker.velocity()
    // Recent deltas are small (10px) — weighted velocity should reflect that,
    // not the old fast deltas (100px).
    check(vel < 600, "recent slow samples should dominate, got \(vel)")
}

// MARK: - Window Classification Tests
print()
print("Window Classification Tests")

section("Standard window with title → tile")
do {
    let props = WindowProperties(role: "AXWindow", subrole: "AXStandardWindow", isResizable: true, hasCloseButton: true, title: "My Document")
    assertEq(classifyWindow(props), .tile)
}

section("Standard window with nil title → float (popup/autocomplete)")
do {
    let props = WindowProperties(role: "AXWindow", subrole: "AXStandardWindow", isResizable: true, hasCloseButton: true, title: nil)
    assertEq(classifyWindow(props), .float)
}

section("Standard window with empty title → float (popup/autocomplete)")
do {
    let props = WindowProperties(role: "AXWindow", subrole: "AXStandardWindow", isResizable: true, hasCloseButton: true, title: "")
    assertEq(classifyWindow(props), .float)
}

section("Standard window with title but tiny frame → float (Fork autocomplete)")
do {
    // Fork's autocomplete dropdown reports as AXStandardWindow with a title
    // ("Window"), is resizable, and has a close button — but it's only ~200 px
    // wide. Size gate must catch it.
    let props = WindowProperties(
        role: "AXWindow", subrole: "AXStandardWindow",
        isResizable: true, hasCloseButton: true,
        title: "Window",
        frame: CGRect(x: 0, y: 0, width: 200, height: 1037)
    )
    assertEq(classifyWindow(props), .float)
}

section("Standard window with title but short frame → float")
do {
    let props = WindowProperties(
        role: "AXWindow", subrole: "AXStandardWindow",
        isResizable: true, hasCloseButton: true,
        title: "Window",
        frame: CGRect(x: 0, y: 0, width: 800, height: 100)
    )
    assertEq(classifyWindow(props), .float)
}

section("Standard window with title and substantial frame → tile (TablePlus)")
do {
    let props = WindowProperties(
        role: "AXWindow", subrole: "AXStandardWindow",
        isResizable: true, hasCloseButton: true,
        title: "blogbot-go-postgres : blogbot - PostgreSQL 15.17",
        frame: CGRect(x: 0, y: 0, width: 1120, height: 1037)
    )
    assertEq(classifyWindow(props), .tile)
}

section("Standard window with title and unknown frame → tile (no regression)")
do {
    // Backwards-compat: when frame is unavailable (nil), the size gate is
    // skipped — preserves prior behavior for callers that don't fetch frame.
    let props = WindowProperties(
        role: "AXWindow", subrole: "AXStandardWindow",
        isResizable: true, hasCloseButton: true,
        title: "My Document",
        frame: nil
    )
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

// MARK: - Snap Point Tests
print()
print("Snap Point Tests")

section("SnapPoint ordering")
do {
    check(SnapPoint.left < SnapPoint.middle, "left < middle")
    check(SnapPoint.middle < SnapPoint.right, "middle < right")
    let unsorted: [SnapPoint] = [.right, .left, .middle]
    let sorted = unsorted.sorted()
    assertEq(sorted, [.left, .middle, .right], "spatial sort")
}

section("computeSnapOffset — middle matches old centering")
do {
    let offset = computeSnapOffset(snapPoint: .middle, columnWidth: 720, workingAreaWidth: 1440)
    assertClose(offset, -360, tolerance: 0.01, "middle centers column")
}

section("computeSnapOffset — left")
do {
    let offset = computeSnapOffset(snapPoint: .left, columnWidth: 720, workingAreaWidth: 1440)
    assertClose(offset, 0, tolerance: 0.01, "left aligns to left edge")
}

section("computeSnapOffset — right")
do {
    let offset = computeSnapOffset(snapPoint: .right, columnWidth: 720, workingAreaWidth: 1440)
    assertClose(offset, -720, tolerance: 0.01, "right aligns to right edge")
}

section("computeSnapOffset — full-width column collapses to 0")
do {
    for snap in [SnapPoint.left, .middle, .right] {
        let offset = computeSnapOffset(snapPoint: snap, columnWidth: 1440, workingAreaWidth: 1440)
        assertClose(offset, 0, tolerance: 0.01, "\(snap) full-width")
    }
}

section("computeSnapOffset — column wider than screen clamps to 0")
do {
    let offset = computeSnapOffset(snapPoint: .right, columnWidth: 2000, workingAreaWidth: 1440)
    assertClose(offset, 0, tolerance: 0.01, "wider than screen clamps")
}

section("Strip — default snap index is middle")
do {
    let wa = CGRect(x: 0, y: 25, width: 1440, height: 875)
    var strip = Strip(snapPoints: [.left, .middle, .right], gap: 16, workingArea: wa)
    let col = Column(tiles: [TileID(1)], width: .proportion(0.5))
    strip.insertColumn(col, at: 0)
    assertEq(strip.snapIndices.count, 1, "one snap index")
    assertEq(strip.snapIndices[0], 1, "default is middle (index 1)")
}

section("Strip — default snap index without middle")
do {
    let wa = CGRect(x: 0, y: 25, width: 1440, height: 875)
    var strip = Strip(snapPoints: [.left, .right], gap: 16, workingArea: wa)
    let col = Column(tiles: [TileID(1)], width: .proportion(0.5))
    strip.insertColumn(col, at: 0)
    assertEq(strip.snapIndices[0], 0, "default is (count-1)/2 = 0 for [left, right]")
}

section("Strip — removeColumn removes snap index")
do {
    let wa = CGRect(x: 0, y: 25, width: 1440, height: 875)
    var strip = Strip(snapPoints: [.left, .middle, .right], gap: 16, workingArea: wa)
    for i in 0..<3 {
        strip.insertColumn(Column(tiles: [TileID(UInt32(i + 1))], width: .proportion(0.5)), at: 0)
    }
    assertEq(strip.snapIndices.count, 3)
    strip.removeColumn(at: 1, at: 0)
    assertEq(strip.snapIndices.count, 2, "snap index removed with column")
}

section("Strip — moveColumnRight swaps snap indices")
do {
    let wa = CGRect(x: 0, y: 25, width: 1440, height: 875)
    var strip = Strip(snapPoints: [.left, .middle, .right], gap: 16, workingArea: wa)
    for i in 0..<3 {
        strip.insertColumn(Column(tiles: [TileID(UInt32(i + 1))], width: .proportion(0.5)), at: 0)
    }
    strip.snapIndices[0] = 2
    strip.activeColumnIndex = 0
    strip.moveColumnRight(at: 0)
    assertEq(strip.snapIndices[1], 2, "snap index followed the column")
    assertEq(strip.snapIndices[0], 1, "neighbor's snap index is default")
}

// MARK: - Snap Navigation Tests
print()
print("Snap Navigation Tests")

section("navigateRight — cycles snap points before changing focus")
do {
    // navigateRight decrements snap (window slides left on screen, revealing right)
    var strip = makeStrip(columnCount: 3, snapPoints: [.left, .middle, .right])
    strip.activeColumnIndex = 1
    strip.snapIndices[1] = 2  // start at right

    let _ = strip.navigateRight(at: 0)
    assertEq(strip.activeColumnIndex, 1, "still on column 1")
    assertEq(strip.snapIndices[1], 1, "snap decremented to middle")

    let _ = strip.navigateRight(at: 0)
    assertEq(strip.activeColumnIndex, 1, "still on column 1")
    assertEq(strip.snapIndices[1], 0, "snap decremented to left")

    let _ = strip.navigateRight(at: 0)
    assertEq(strip.activeColumnIndex, 2, "moved to column 2")
}

section("navigateLeft — cycles snap points before changing focus")
do {
    // navigateLeft increments snap (window slides right on screen, revealing left)
    var strip = makeStrip(columnCount: 3, snapPoints: [.left, .middle, .right])
    strip.activeColumnIndex = 1
    strip.snapIndices[1] = 0  // start at left

    let _ = strip.navigateLeft(at: 0)
    assertEq(strip.activeColumnIndex, 1, "still on column 1")
    assertEq(strip.snapIndices[1], 1, "snap incremented to middle")

    let _ = strip.navigateLeft(at: 0)
    assertEq(strip.activeColumnIndex, 1, "still on column 1")
    assertEq(strip.snapIndices[1], 2, "snap incremented to right")

    let _ = strip.navigateLeft(at: 0)
    assertEq(strip.activeColumnIndex, 0, "moved to column 0")
}

section("navigateRight — focus change snaps to next leftward milestone")
do {
    // Col 0 width=720, col 1 width=720, gap=16, screen=1440
    // Col 0 at left snap (offset=0). navigateRight exhausts → focus col 1.
    // adjustedOffset = 0 + 0 - 736 = -736
    // For col 1: left=0, middle=-360, right=-720.
    // Window is at -736, past right(-720). Going left, first unreached = right(-720).
    // But window already passed right, so next leftward = middle? No:
    // -736 < -720 (right), so right is to the LEFT of current pos. Check: -736 < -720? Yes.
    // Iterate reversed: i=2 right=-720, -736 < -720? Yes → return right.
    // Actually: currentOffset(-736) < snapOffset(-720)? Yes → unreached going left.
    // So snap to right (idx=2).
    var strip = makeStrip(columnCount: 2, snapPoints: [.left, .middle, .right])
    strip.snapIndices[0] = 0
    strip.viewOffset = .static(0)

    let _ = strip.navigateRight(at: 0)
    assertEq(strip.activeColumnIndex, 1, "moved to column 1")
    assertEq(strip.snapIndices[1], 2, "col 1 snaps to right (next leftward milestone)")
}

section("snap=[middle] — immediate focus change (backward compat)")
do {
    var strip = makeStrip(columnCount: 3, snapPoints: [.middle])

    let _ = strip.navigateRight(at: 0)
    assertEq(strip.activeColumnIndex, 1, "immediate focus change")

    let _ = strip.navigateRight(at: 0)
    assertEq(strip.activeColumnIndex, 2, "immediate focus change")
}

section("snap=[left] — single snap, immediate focus change, left-aligned")
do {
    var strip = makeStrip(columnCount: 2, snapPoints: [.left])
    let _ = strip.navigateRightInstant(at: 0)
    assertEq(strip.activeColumnIndex, 1, "immediate focus change")
    let offset = strip.viewOffset.current(at: 0)
    assertClose(offset, 0, tolerance: 0.01, "left-aligned")
}

section("navigateRight — rubber-band at boundary")
do {
    var strip = makeStrip(columnCount: 1, snapPoints: [.left, .middle, .right])
    strip.snapIndices[0] = 0  // at leftmost (exhausted for navigateRight which decrements)
    let anim = strip.navigateRight(at: 0)
    check(anim != nil, "should produce rubber-band animation")
    assertEq(strip.activeColumnIndex, 0, "still on column 0")
    assertEq(strip.snapIndices[0], 0, "snap unchanged")
}

section("navigateLeft — rubber-band at boundary")
do {
    var strip = makeStrip(columnCount: 1, snapPoints: [.left, .middle, .right])
    strip.snapIndices[0] = 2  // at rightmost (exhausted for navigateLeft which increments)
    let anim = strip.navigateLeft(at: 0)
    check(anim != nil, "should produce rubber-band animation")
    assertEq(strip.activeColumnIndex, 0, "still on column 0")
    assertEq(strip.snapIndices[0], 2, "snap unchanged")
}

section("snap=[left,right] — two snap points, default index is 0 (left)")
do {
    // navigateRight decrements snap: 0 is already minimum, so moves focus
    var strip = makeStrip(columnCount: 2, snapPoints: [.left, .right])
    assertEq(strip.snapIndices[0], 0, "default snap index for [left, right]")
    let _ = strip.navigateRightInstant(at: 0)
    assertEq(strip.activeColumnIndex, 1, "moves focus immediately (already at leftmost snap)")
}

// MARK: - Gesture Snap Helper Tests
print()
print("Gesture Snap Helper Tests")

section("nearestSnapPoint — single snap point")
do {
    let (idx, offset) = nearestSnapPoint(
        projectedOffset: -200,
        snapPoints: [.middle],
        columnWidth: 720,
        workingAreaWidth: 1440
    )
    assertEq(idx, 0, "only one option")
    assertClose(offset, -360, tolerance: 0.01, "middle offset")
}

section("nearestSnapPoint — picks closest of three")
do {
    // left=0, middle=-360, right=-720. Projected=-100 → closest is left (0).
    let (idx, _) = nearestSnapPoint(
        projectedOffset: -100,
        snapPoints: [.left, .middle, .right],
        columnWidth: 720,
        workingAreaWidth: 1440
    )
    assertEq(idx, 0, "closest to left")
}

section("nearestSnapPoint — picks right when projected far negative")
do {
    // left=0, middle=-360, right=-720. Projected=-600 → closest is right (-720).
    let (idx, _) = nearestSnapPoint(
        projectedOffset: -600,
        snapPoints: [.left, .middle, .right],
        columnWidth: 720,
        workingAreaWidth: 1440
    )
    assertEq(idx, 2, "closest to right")
}

section("nearestSnapPoint — picks middle when equidistant favors first")
do {
    // left=0, middle=-360, right=-720. Projected=-180 → equidistant between left(0) and middle(-360).
    // Should pick first match (left at index 0) since we use < not <=.
    let (idx, _) = nearestSnapPoint(
        projectedOffset: -180,
        snapPoints: [.left, .middle, .right],
        columnWidth: 720,
        workingAreaWidth: 1440
    )
    assertEq(idx, 0, "equidistant picks first (left)")
}

// MARK: - columnIndexAtStripX Tests
print()
print("columnIndexAtStripX Tests")

section("columnIndexAtStripX — hits first column")
do {
    // 3 columns of width 720, gap 16. Col 0: [0, 720), Col 1: [736, 1456), Col 2: [1472, 2192)
    let columnWidths: [Double] = [720, 720, 720]
    let idx = columnIndexAtStripX(100, columnWidths: columnWidths, gap: 16)
    assertEq(idx, 0, "inside first column")
}

section("columnIndexAtStripX — hits second column")
do {
    let columnWidths: [Double] = [720, 720, 720]
    let idx = columnIndexAtStripX(800, columnWidths: columnWidths, gap: 16)
    assertEq(idx, 1, "inside second column")
}

section("columnIndexAtStripX — in gap picks nearest column")
do {
    // Gap between col 0 and col 1 is [720, 736). Midpoint = 728.
    let columnWidths: [Double] = [720, 720, 720]
    let idxLeft = columnIndexAtStripX(724, columnWidths: columnWidths, gap: 16)
    assertEq(idxLeft, 0, "in gap, closer to left column")
    let idxRight = columnIndexAtStripX(732, columnWidths: columnWidths, gap: 16)
    assertEq(idxRight, 1, "in gap, closer to right column")
}

section("columnIndexAtStripX — before strip")
do {
    let columnWidths: [Double] = [720, 720]
    let idx = columnIndexAtStripX(-100, columnWidths: columnWidths, gap: 16)
    assertEq(idx, 0, "clamp to first")
}

section("columnIndexAtStripX — past end of strip")
do {
    let columnWidths: [Double] = [720, 720]
    let idx = columnIndexAtStripX(5000, columnWidths: columnWidths, gap: 16)
    assertEq(idx, 1, "clamp to last")
}

section("columnIndexAtStripX — single column")
do {
    let idx = columnIndexAtStripX(999, columnWidths: [720], gap: 16)
    assertEq(idx, 0, "only column")
}

section("Cursor-to-strip coordinate conversion")
do {
    // Setup: 3 columns, 720px each, gap 16, screen at x=0 width 1440
    // Active column = 1 (at stripX = 736), viewOffset = -360 (centered)
    // viewPos = 736 + (-360) = 376
    // Screen shows strip from x=376 to x=1816
    // Cursor at screen center (720) should map to stripX = 720 - 0 + 736 + (-360) = 1096
    // That's inside column 1 [736, 1456) ✓
    let wa = CGRect(x: 0, y: 25, width: 1440, height: 875)
    let cursorScreenX: Double = 720
    let activeColX: Double = 736  // columnX(at: 1) = 720 + 16
    let viewOffset: Double = -360
    let cursorStripX = (cursorScreenX - wa.minX) + activeColX + viewOffset
    assertClose(cursorStripX, 1096, tolerance: 0.01, "cursor at screen center maps into column 1")

    let idx = columnIndexAtStripX(cursorStripX, columnWidths: [720, 720, 720], gap: 16)
    assertEq(idx, 1, "column under cursor is column 1")
}

section("Cursor-to-strip — secondary display offset")
do {
    // Screen at x=1440 (secondary display), width 1440
    // Active column = 0 (stripX = 0), viewOffset = -360 (centered)
    // Cursor at screen midpoint = 1440 + 720 = 2160
    // cursorStripX = (2160 - 1440) + 0 + (-360) = 360
    // That's inside column 0 [0, 720) ✓
    let wa = CGRect(x: 1440, y: 25, width: 1440, height: 875)
    let cursorScreenX: Double = 2160
    let activeColX: Double = 0
    let viewOffset: Double = -360
    let cursorStripX = (cursorScreenX - wa.minX) + activeColX + viewOffset
    assertClose(cursorStripX, 360, tolerance: 0.01, "secondary display cursor maps correctly")

    let idx = columnIndexAtStripX(cursorStripX, columnWidths: [720, 720], gap: 16)
    assertEq(idx, 0, "column under cursor is column 0")
}

// MARK: - Width Animation Tests
print()
print("Width Animation Tests")

section("currentWidth(at:) returns animated value")
do {
    let params = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)
    let anim = SpringAnimation(from: 360, to: 720, startTime: 0, params: params)
    var data = ColumnData(cachedWidth: 720, widthAnimation: anim)
    // At t=0, should return the start value (360), not the target
    let val0 = data.currentWidth(at: 0)
    assertClose(val0, 360, tolerance: 1.0, "currentWidth at t=0 should be start value")
    // At t=2.0, spring should be settled, should return cachedWidth
    let valEnd = data.currentWidth(at: 2.0)
    assertClose(valEnd, 720, tolerance: 1.0, "currentWidth at t=2.0 should be target")
    // With no animation, returns cachedWidth
    data.widthAnimation = nil
    let valStatic = data.currentWidth(at: 0)
    assertClose(valStatic, 720, tolerance: 0.01, "no animation returns cachedWidth")
}

section("cycleWidthPreset animated — creates width spring")
do {
    var strip = makeStrip(columnCount: 1)
    strip.widthPresets = [.proportion(0.25), .proportion(0.5), .proportion(0.75)]
    // Column starts at 0.5 width (720px on 1440 screen)
    let oldWidth = strip.columnData[0].cachedWidth
    assertClose(oldWidth, 720, tolerance: 1.0, "starts at 720")

    let params = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)
    strip.cycleWidthPreset(at: 0, params: params)

    // presetIndex should be 0 (first preset: 0.25)
    assertEq(strip.columns[0].presetIndex, 0)
    // cachedWidth should be the target (0.25 * 1440 = 360)
    assertClose(strip.columnData[0].cachedWidth, 360, tolerance: 1.0, "cachedWidth is target")
    // widthAnimation should be non-nil
    check(strip.columnData[0].widthAnimation != nil, "widthAnimation should be set")
    // currentWidth at t=0 should be the OLD width (720)
    assertClose(strip.columnData[0].currentWidth(at: 0), 720, tolerance: 1.0, "animated from old")
    // currentWidth at t=2.0 should converge to target (360)
    assertClose(strip.columnData[0].currentWidth(at: 2.0), 360, tolerance: 1.0, "converges to target")
}

section("cycleWidthPreset animated — rapid retarget preserves velocity")
do {
    var strip = makeStrip(columnCount: 1)
    strip.widthPresets = [.proportion(0.25), .proportion(0.5), .proportion(0.75)]
    let params = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)

    // First cycle at t=0
    strip.cycleWidthPreset(at: 0, params: params)
    // Second cycle at t=0.05 (mid-animation)
    strip.cycleWidthPreset(at: 0.05, params: params)

    assertEq(strip.columns[0].presetIndex, 1, "second preset")
    let anim = strip.columnData[0].widthAnimation!
    check(anim.initialVelocity != 0, "velocity should be preserved from first spring")
}

section("cycleWidthPreset non-animated — no widthAnimation")
do {
    var strip = makeStrip(columnCount: 1)
    strip.widthPresets = [.proportion(0.25), .proportion(0.5), .proportion(0.75)]
    strip.cycleWidthPreset(at: 0, params: nil)
    assertEq(strip.columns[0].presetIndex, 0)
    assertClose(strip.columnData[0].cachedWidth, 360, tolerance: 1.0)
    check(strip.columnData[0].widthAnimation == nil, "no animation when params is nil")
}

section("Config — width_presets proportions resolve correctly")
do {
    let presets: [ColumnWidth] = [.proportion(0.25), .proportion(0.5), .proportion(0.75), .proportion(1.0)]
    let resolved = presets.map { $0.resolve(workingAreaWidth: 1440, gap: 16) }
    assertClose(resolved[0], 360, tolerance: 0.01, "0.25 preset")
    assertClose(resolved[1], 720, tolerance: 0.01, "0.5 preset")
    assertClose(resolved[2], 1080, tolerance: 0.01, "0.75 preset")
    assertClose(resolved[3], 1440, tolerance: 0.01, "1.0 preset")
}

section("settleWidthAnimations — merged settle + active check")
do {
    var strip = makeStrip(columnCount: 2)
    let params = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)

    // No animations initially — returns false (no active remain)
    check(!strip.settleWidthAnimations(at: 0), "no animations initially")

    // Add a width animation to column 0
    strip.columnData[0].widthAnimation = SpringAnimation(from: 360, to: 720, startTime: 0, params: params)
    check(strip.settleWidthAnimations(at: 0), "active at t=0")
    check(strip.columnData[0].widthAnimation != nil, "not settled at t=0")

    // At t=2.0, animation should be done — settleWidthAnimations nils it and returns false
    check(!strip.settleWidthAnimations(at: 2.0), "settled at t=2.0")
    check(strip.columnData[0].widthAnimation == nil, "nilled after settle")
}

section("evaluateWithStatus matches isDone + evaluate")
do {
    let params = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)
    let anim = SpringAnimation(from: 0, to: 500, initialVelocity: 0, startTime: 0, params: params)

    // Mid-flight: not done
    let (val1, done1) = anim.evaluateWithStatus(at: 0.05)
    let (evalVal1, _) = anim.evaluate(at: 0.05)
    let isDone1 = anim.isDone(at: 0.05)
    assertClose(val1, evalVal1, tolerance: 1e-10, "value should match evaluate")
    assertEq(done1, isDone1, "isDone should match")
    check(!done1, "should not be done at t=0.05")

    // Well past convergence: done
    let (val2, done2) = anim.evaluateWithStatus(at: 5.0)
    let isDone2 = anim.isDone(at: 5.0)
    check(done2, "should be done at t=5.0")
    assertEq(done2, isDone2, "isDone should match at convergence")
    _ = val2 // suppress unused warning
}

section("evaluateWithStatus epsilon boundary")
do {
    let params = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)
    let anim = SpringAnimation(from: 0, to: 100, initialVelocity: 0, startTime: 0, params: params)

    // Binary search for the convergence time
    var lo = 0.0, hi = 2.0
    for _ in 0..<100 {
        let mid = (lo + hi) / 2.0
        if anim.isDone(at: mid) { hi = mid } else { lo = mid }
    }
    // lo is just before done, hi is just after done
    let (_, doneBefore) = anim.evaluateWithStatus(at: lo)
    let (_, doneAfter) = anim.evaluateWithStatus(at: hi)
    check(!doneBefore, "should not be done just before epsilon boundary")
    check(doneAfter, "should be done just after epsilon boundary")
    assertEq(doneBefore, anim.isDone(at: lo), "boundary before")
    assertEq(doneAfter, anim.isDone(at: hi), "boundary after")
}

section("ColumnData.currentWidth with active widthAnimation")
do {
    let params = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)
    let anim = SpringAnimation(from: 300, to: 600, startTime: 0, params: params)
    let data = ColumnData(cachedWidth: 600, widthAnimation: anim)

    // Mid-animation: should return animated value, not cachedWidth
    let width = data.currentWidth(at: 0.05)
    check(width > 300 && width < 600, "should be between from and to, got \(width)")
    check(width != 600, "should not return cachedWidth during animation")

    // After convergence: should return cachedWidth
    let widthLate = data.currentWidth(at: 5.0)
    assertClose(widthLate, 600, tolerance: 0.5, "should return cachedWidth when done")
}

// ═══════════════════════════════════════
// settleWidthAnimations returns Bool
// ═══════════════════════════════════════
print()
print("═ settleWidthAnimations returns Bool")

section("settleWidthAnimations returns false when all settled")
do {
    let wa = CGRect(x: 0, y: 25, width: 1440, height: 875)
    var strip = Strip(
        columns: [Column(tiles: [TileID(1)]), Column(tiles: [TileID(2)])],
        columnData: [ColumnData(cachedWidth: 500), ColumnData(cachedWidth: 500)],
        activeColumnIndex: 0,
        viewOffset: .static(0),
        snapIndices: [0, 1],
        gap: 16,
        workingArea: wa
    )
    let hasActive = strip.settleWidthAnimations(at: 0)
    check(!hasActive, "no animations means no active remain")
}

section("settleWidthAnimations mixed case — settle done, keep active")
do {
    let wa = CGRect(x: 0, y: 25, width: 1440, height: 875)
    let params = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)
    let doneAnim = SpringAnimation(from: 300, to: 500, startTime: 0, params: params)
    let activeAnim = SpringAnimation(from: 300, to: 500, startTime: 4.9, params: params)

    var strip = Strip(
        columns: [Column(tiles: [TileID(1)]), Column(tiles: [TileID(2)])],
        columnData: [
            ColumnData(cachedWidth: 500, widthAnimation: doneAnim),
            ColumnData(cachedWidth: 500, widthAnimation: activeAnim)
        ],
        activeColumnIndex: 0,
        viewOffset: .static(0),
        snapIndices: [0, 1],
        gap: 16,
        workingArea: wa
    )

    let hasActive = strip.settleWidthAnimations(at: 5.0)
    check(hasActive, "should return true — second animation still active")
    check(strip.columnData[0].widthAnimation == nil, "done animation should be niled")
    check(strip.columnData[1].widthAnimation != nil, "active animation should remain")
}

// ============================================================
// MARK: - Strip Snapshot Matching
// ============================================================
print()
print("▶ Strip Snapshot Matching")

// Helpers for snapshot tests
func makeSlot(
    windowID: CGWindowID? = nil, bundleID: String, title: String? = nil,
    width: ColumnWidth = .proportion(0.5), presetIndex: Int? = nil, isFullWidth: Bool = false,
    vacant: Bool = false, vacatedAt: Date? = nil
) -> SlotDescriptor {
    SlotDescriptor(windowID: windowID, bundleID: bundleID, windowTitle: title,
                   width: width, presetIndex: presetIndex, isFullWidth: isFullWidth,
                   vacant: vacant, vacatedAt: vacatedAt)
}

func makeStripWindow(tileID: UInt32, windowID: CGWindowID, bundleID: String, title: String? = nil) -> StripWindowInfo {
    StripWindowInfo(tileID: TileID(tileID), windowID: windowID, bundleID: bundleID, windowTitle: title)
}

section("WindowID fast-path match")
do {
    let snapshot = StripSnapshot(slots: [
        makeSlot(windowID: 100, bundleID: "com.app.A"),
        makeSlot(windowID: 200, bundleID: "com.app.B"),
    ], lastUpdated: Date())
    let result = matchWindowToSlot(windowID: 100, bundleID: "com.app.A", title: nil,
                                    snapshot: snapshot, filledSlots: [], now: Date())
    assertEq(result, 0, "windowID 100 matches slot 0")
}

section("WindowID fast-path requires bundleID match (reuse guard)")
do {
    let snapshot = StripSnapshot(slots: [
        makeSlot(windowID: 100, bundleID: "com.app.A"),
    ], lastUpdated: Date())
    // Different bundleID — should NOT match even though windowID matches
    let result = matchWindowToSlot(windowID: 100, bundleID: "com.app.DIFFERENT", title: nil,
                                    snapshot: snapshot, filledSlots: [], now: Date())
    check(result == nil, "windowID reuse with different bundleID should not match")
}

section("Semantic match by bundleID + title")
do {
    let snapshot = StripSnapshot(slots: [
        makeSlot(bundleID: "com.app.A", title: "Doc 1"),
        makeSlot(bundleID: "com.app.A", title: "Doc 2"),
    ], lastUpdated: Date())
    let result = matchWindowToSlot(windowID: 999, bundleID: "com.app.A", title: "Doc 2",
                                    snapshot: snapshot, filledSlots: [], now: Date())
    assertEq(result, 1, "title 'Doc 2' matches slot 1")
}

section("Semantic match bundleID only (first-unfilled tiebreaker)")
do {
    let snapshot = StripSnapshot(slots: [
        makeSlot(bundleID: "com.app.X"),
        makeSlot(bundleID: "com.app.A"),
        makeSlot(bundleID: "com.app.A"),
    ], lastUpdated: Date())
    let result = matchWindowToSlot(windowID: 999, bundleID: "com.app.A", title: nil,
                                    snapshot: snapshot, filledSlots: [], now: Date())
    assertEq(result, 1, "first unfilled slot for bundleID")
}

section("Multiple windows same app different titles → correct slots")
do {
    let snapshot = StripSnapshot(slots: [
        makeSlot(bundleID: "com.app.A", title: "Alpha"),
        makeSlot(bundleID: "com.app.B"),
        makeSlot(bundleID: "com.app.A", title: "Beta"),
    ], lastUpdated: Date())
    let r1 = matchWindowToSlot(windowID: 1, bundleID: "com.app.A", title: "Beta",
                                snapshot: snapshot, filledSlots: [], now: Date())
    assertEq(r1, 2, "Beta matches slot 2")
    let r2 = matchWindowToSlot(windowID: 2, bundleID: "com.app.A", title: "Alpha",
                                snapshot: snapshot, filledSlots: [2], now: Date())
    assertEq(r2, 0, "Alpha matches slot 0")
}

section("Multiple windows same app same title → assigned in order")
do {
    let snapshot = StripSnapshot(slots: [
        makeSlot(bundleID: "com.term"),
        makeSlot(bundleID: "com.term"),
        makeSlot(bundleID: "com.term"),
    ], lastUpdated: Date())
    let r1 = matchWindowToSlot(windowID: 1, bundleID: "com.term", title: nil,
                                snapshot: snapshot, filledSlots: [], now: Date())
    assertEq(r1, 0, "first Terminal gets slot 0")
    let r2 = matchWindowToSlot(windowID: 2, bundleID: "com.term", title: nil,
                                snapshot: snapshot, filledSlots: [0], now: Date())
    assertEq(r2, 1, "second Terminal gets slot 1")
    let r3 = matchWindowToSlot(windowID: 3, bundleID: "com.term", title: nil,
                                snapshot: snapshot, filledSlots: [0, 1], now: Date())
    assertEq(r3, 2, "third Terminal gets slot 2")
}

section("Already-filled slots skipped")
do {
    let snapshot = StripSnapshot(slots: [
        makeSlot(bundleID: "com.app.A"),
        makeSlot(bundleID: "com.app.A"),
    ], lastUpdated: Date())
    let result = matchWindowToSlot(windowID: 99, bundleID: "com.app.A", title: nil,
                                    snapshot: snapshot, filledSlots: [0], now: Date())
    assertEq(result, 1, "slot 0 filled, returns slot 1")
}

section("All slots filled → nil")
do {
    let snapshot = StripSnapshot(slots: [
        makeSlot(bundleID: "com.app.A"),
    ], lastUpdated: Date())
    let result = matchWindowToSlot(windowID: 99, bundleID: "com.app.A", title: nil,
                                    snapshot: snapshot, filledSlots: [0], now: Date())
    check(result == nil, "all slots filled returns nil")
}

section("Codable round-trips for SlotDescriptor and StripSnapshot")
do {
    let slot = makeSlot(windowID: 42, bundleID: "com.test", title: "Hello",
                         width: .fixed(800), presetIndex: 2, isFullWidth: true)
    let snapshot = StripSnapshot(slots: [slot], lastUpdated: Date(timeIntervalSince1970: 1000))
    let data = try! JSONEncoder().encode(snapshot)
    let decoded = try! JSONDecoder().decode(StripSnapshot.self, from: data)
    assertEq(decoded.slots.count, 1, "round-trip slot count")
    assertEq(decoded.slots[0].bundleID, "com.test", "round-trip bundleID")
    assertEq(decoded.slots[0].windowID, 42, "round-trip windowID")
    assertEq(decoded.slots[0].windowTitle, "Hello", "round-trip title")
    assertEq(decoded.slots[0].width, .fixed(800), "round-trip width")
    assertEq(decoded.slots[0].presetIndex, 2, "round-trip presetIndex")
    assertEq(decoded.slots[0].isFullWidth, true, "round-trip isFullWidth")
}

section("Codable round-trip with nil windowID (disk format)")
do {
    let slot = makeSlot(bundleID: "com.test")
    let data = try! JSONEncoder().encode(slot)
    let decoded = try! JSONDecoder().decode(SlotDescriptor.self, from: data)
    check(decoded.windowID == nil, "nil windowID preserved")
    assertEq(decoded.bundleID, "com.test", "bundleID preserved")
}

section("computeFilledSlots two-pass: windowID then semantic")
do {
    let slots = [
        makeSlot(windowID: 100, bundleID: "com.app.A", title: "Doc 1"),
        makeSlot(windowID: 200, bundleID: "com.app.B"),
        makeSlot(bundleID: "com.app.A", title: "Doc 2"),
    ]
    let windows = [
        makeStripWindow(tileID: 1, windowID: 100, bundleID: "com.app.A", title: "Doc 1"),
        makeStripWindow(tileID: 2, windowID: 200, bundleID: "com.app.B", title: nil),
        makeStripWindow(tileID: 3, windowID: 300, bundleID: "com.app.A", title: "Doc 2"),
    ]
    let filled = computeFilledSlots(slots: slots, stripWindows: windows)
    assertEq(filled.count, 3, "all 3 slots filled")
    check(filled.contains(0), "slot 0 filled by windowID")
    check(filled.contains(1), "slot 1 filled by windowID")
    check(filled.contains(2), "slot 2 filled by semantic")
}

section("computeFilledSlots: single column can't claim multiple slots")
do {
    // Two slots with same bundleID, one window — only first slot claimed
    let slots = [
        makeSlot(bundleID: "com.app.A"),
        makeSlot(bundleID: "com.app.A"),
    ]
    let windows = [
        makeStripWindow(tileID: 1, windowID: 100, bundleID: "com.app.A"),
    ]
    let filled = computeFilledSlots(slots: slots, stripWindows: windows)
    assertEq(filled.count, 1, "only one slot claimed")
    check(filled.contains(0), "first matching slot claimed")
}

section("computeFilledSlots: windowID pass requires bundleID match")
do {
    // Slot has windowID 100 for app A, but strip window 100 is app B (ID reuse)
    let slots = [
        makeSlot(windowID: 100, bundleID: "com.app.A"),
    ]
    let windows = [
        makeStripWindow(tileID: 1, windowID: 100, bundleID: "com.app.B"),
    ]
    let filled = computeFilledSlots(slots: slots, stripWindows: windows)
    assertEq(filled.count, 0, "windowID reuse with wrong bundleID not filled")
}

section("computeFilledSlots: ghost (vacant) slots not claimed as filled")
do {
    let slots = [
        makeSlot(bundleID: "com.app.A"),
        makeSlot(bundleID: "com.app.B", vacant: true, vacatedAt: Date()),
        makeSlot(bundleID: "com.app.C"),
    ]
    // Window for com.app.B exists but ghost slot should not be marked filled
    let windows = [
        makeStripWindow(tileID: 1, windowID: 100, bundleID: "com.app.A"),
        makeStripWindow(tileID: 2, windowID: 200, bundleID: "com.app.B"),
        makeStripWindow(tileID: 3, windowID: 300, bundleID: "com.app.C"),
    ]
    let filled = computeFilledSlots(slots: slots, stripWindows: windows)
    check(!filled.contains(1), "ghost slot 1 not marked as filled")
    check(filled.contains(0), "live slot 0 filled")
    check(filled.contains(2), "live slot 2 filled")
}

section("Ghost slot: matched on reopen")
do {
    let snapshot = StripSnapshot(slots: [
        makeSlot(bundleID: "com.app.A"),
        makeSlot(bundleID: "com.app.B", vacant: true, vacatedAt: Date()),
        makeSlot(bundleID: "com.app.C"),
    ], lastUpdated: Date())
    let result = matchWindowToSlot(windowID: 999, bundleID: "com.app.B", title: nil,
                                    snapshot: snapshot, filledSlots: [], now: Date())
    assertEq(result, 1, "ghost slot matched at original position")
}

section("Ghost slot expiry enforced in matchWindowToSlot")
do {
    let expiredDate = Date().addingTimeInterval(-700)  // 700s ago > 600s expiry
    let snapshot = StripSnapshot(slots: [
        makeSlot(bundleID: "com.app.B", vacant: true, vacatedAt: expiredDate),
    ], lastUpdated: Date())
    let result = matchWindowToSlot(windowID: 999, bundleID: "com.app.B", title: nil,
                                    snapshot: snapshot, filledSlots: [], now: Date())
    check(result == nil, "expired ghost not matched")
}

section("Ghost slot not expired within window")
do {
    let recentDate = Date().addingTimeInterval(-300)  // 300s ago < 600s expiry
    let snapshot = StripSnapshot(slots: [
        makeSlot(bundleID: "com.app.B", vacant: true, vacatedAt: recentDate),
    ], lastUpdated: Date())
    let result = matchWindowToSlot(windowID: 999, bundleID: "com.app.B", title: nil,
                                    snapshot: snapshot, filledSlots: [], now: Date())
    assertEq(result, 0, "recent ghost still matched")
}

section("computeFilledSlots during simulated sequential batch-add")
do {
    let slots = [
        makeSlot(windowID: 100, bundleID: "com.app.A"),
        makeSlot(windowID: 200, bundleID: "com.app.B"),
        makeSlot(windowID: 300, bundleID: "com.app.C"),
    ]
    // Simulate adding windows one at a time
    var windows: [StripWindowInfo] = []

    // Add first window
    windows.append(makeStripWindow(tileID: 1, windowID: 100, bundleID: "com.app.A"))
    let filled1 = computeFilledSlots(slots: slots, stripWindows: windows)
    assertEq(filled1.count, 1, "after 1st add: 1 slot filled")

    // Add second window
    windows.append(makeStripWindow(tileID: 2, windowID: 200, bundleID: "com.app.B"))
    let filled2 = computeFilledSlots(slots: slots, stripWindows: windows)
    assertEq(filled2.count, 2, "after 2nd add: 2 slots filled")

    // Add third window
    windows.append(makeStripWindow(tileID: 3, windowID: 300, bundleID: "com.app.C"))
    let filled3 = computeFilledSlots(slots: slots, stripWindows: windows)
    assertEq(filled3.count, 3, "after 3rd add: all 3 slots filled")
}

// MARK: - matchSlotsToWindows (replay-loop helper)

section("matchSlotsToWindows — single match")
do {
    let slots = [makeSlot(bundleID: "com.app.A", title: "Doc")]
    let candidates = [makeStripWindow(tileID: 1, windowID: 100, bundleID: "com.app.A", title: "Doc")]
    let pairs = matchSlotsToWindows(slots: slots, candidates: candidates)
    assertEq(pairs.count, 1, "one pair")
    assertEq(pairs[0].slotIndex, 0, "slot 0")
    assertEq(pairs[0].candidateIndex, 0, "cand 0")
}

section("matchSlotsToWindows — multi-match prefers title")
do {
    let slots = [
        makeSlot(bundleID: "com.app.A", title: "Beta"),
        makeSlot(bundleID: "com.app.A", title: "Alpha"),
    ]
    let candidates = [
        makeStripWindow(tileID: 1, windowID: 1, bundleID: "com.app.A", title: "Alpha"),
        makeStripWindow(tileID: 2, windowID: 2, bundleID: "com.app.A", title: "Beta"),
    ]
    let pairs = matchSlotsToWindows(slots: slots, candidates: candidates)
    assertEq(pairs.count, 2, "two pairs")
    // slot 0 (Beta) should pair with candidate 1 (Beta)
    assertEq(pairs[0].slotIndex, 0, "first pair slot 0")
    assertEq(pairs[0].candidateIndex, 1, "first pair cand 1 (Beta)")
    // slot 1 (Alpha) should pair with candidate 0 (Alpha)
    assertEq(pairs[1].slotIndex, 1, "second pair slot 1")
    assertEq(pairs[1].candidateIndex, 0, "second pair cand 0 (Alpha)")
}

section("matchSlotsToWindows — title miss falls back to bundle match")
do {
    // Slot expects Alpha, but only a different-titled window is available.
    let slots = [makeSlot(bundleID: "com.app.A", title: "Alpha")]
    let candidates = [makeStripWindow(tileID: 1, windowID: 100, bundleID: "com.app.A", title: "Gamma")]
    let pairs = matchSlotsToWindows(slots: slots, candidates: candidates)
    assertEq(pairs.count, 1, "bundle-only fallback pairs")
    assertEq(pairs[0].candidateIndex, 0, "candidate 0 chosen")
}

section("matchSlotsToWindows — slot with no candidate dropped")
do {
    let slots = [
        makeSlot(bundleID: "com.app.A"),
        makeSlot(bundleID: "com.missing"),
        makeSlot(bundleID: "com.app.B"),
    ]
    let candidates = [
        makeStripWindow(tileID: 1, windowID: 1, bundleID: "com.app.A"),
        makeStripWindow(tileID: 2, windowID: 2, bundleID: "com.app.B"),
    ]
    let pairs = matchSlotsToWindows(slots: slots, candidates: candidates)
    assertEq(pairs.count, 2, "missing bundle dropped")
    assertEq(pairs[0].slotIndex, 0, "slot 0 matched")
    assertEq(pairs[1].slotIndex, 2, "slot 2 matched")
}

section("matchSlotsToWindows — vacant slot skipped")
do {
    let slots = [
        makeSlot(bundleID: "com.app.A"),
        makeSlot(bundleID: "com.app.B", vacant: true, vacatedAt: Date()),
        makeSlot(bundleID: "com.app.C"),
    ]
    let candidates = [
        makeStripWindow(tileID: 1, windowID: 1, bundleID: "com.app.A"),
        makeStripWindow(tileID: 2, windowID: 2, bundleID: "com.app.B"),
        makeStripWindow(tileID: 3, windowID: 3, bundleID: "com.app.C"),
    ]
    let pairs = matchSlotsToWindows(slots: slots, candidates: candidates)
    assertEq(pairs.count, 2, "vacant slot skipped even with live candidate")
    assertEq(pairs[0].slotIndex, 0, "slot 0 paired")
    assertEq(pairs[1].slotIndex, 2, "slot 2 paired (skipping vacant slot 1)")
}

section("matchSlotsToWindows — each candidate used at most once")
do {
    // Two identical-looking slots, one candidate.
    let slots = [
        makeSlot(bundleID: "com.app.A"),
        makeSlot(bundleID: "com.app.A"),
    ]
    let candidates = [makeStripWindow(tileID: 1, windowID: 1, bundleID: "com.app.A")]
    let pairs = matchSlotsToWindows(slots: slots, candidates: candidates)
    assertEq(pairs.count, 1, "one pair only")
    assertEq(pairs[0].slotIndex, 0, "first slot takes the candidate")
}

// MARK: - moveColumn(from:to:)

section("moveColumn — move forward")
do {
    var strip = makeStrip(columnCount: 4)
    strip.activeColumnIndex = 1
    strip.moveColumn(from: 1, to: 3, at: 0)
    assertEq(strip.columns[0].tiles[0], TileID(1), "col 0")
    assertEq(strip.columns[1].tiles[0], TileID(3), "col 1")
    assertEq(strip.columns[2].tiles[0], TileID(4), "col 2")
    assertEq(strip.columns[3].tiles[0], TileID(2), "col 3")
    assertEq(strip.activeColumnIndex, 3, "active tracks moved column")
}

section("moveColumn — move backward")
do {
    var strip = makeStrip(columnCount: 4)
    strip.activeColumnIndex = 3
    strip.moveColumn(from: 3, to: 0, at: 0)
    assertEq(strip.columns[0].tiles[0], TileID(4), "col 0")
    assertEq(strip.columns[1].tiles[0], TileID(1), "col 1")
    assertEq(strip.columns[2].tiles[0], TileID(2), "col 2")
    assertEq(strip.columns[3].tiles[0], TileID(3), "col 3")
    assertEq(strip.activeColumnIndex, 0, "active tracks moved column")
}

section("moveColumn — same position is no-op")
do {
    var strip = makeStrip(columnCount: 3)
    strip.activeColumnIndex = 1
    strip.moveColumn(from: 1, to: 1, at: 0)
    assertEq(strip.columns[0].tiles[0], TileID(1), "unchanged")
    assertEq(strip.columns[1].tiles[0], TileID(2), "unchanged")
    assertEq(strip.columns[2].tiles[0], TileID(3), "unchanged")
    assertEq(strip.activeColumnIndex, 1, "active unchanged")
}

// MARK: - Rubber-band with custom velocity

section("rubber-band — default kick velocity")
do {
    var strip = makeStrip(columnCount: 1)
    let anim = strip.createRubberBandAnimation(direction: 1, at: 0)
    assertClose(anim.initialVelocity, 600, tolerance: 1, "default kick")
}

section("rubber-band — custom kick velocity")
do {
    var strip = makeStrip(columnCount: 1)
    let anim = strip.createRubberBandAnimation(direction: 1, kickVelocity: 200, at: 0)
    assertClose(anim.initialVelocity, 200, tolerance: 1, "custom kick")
}

// MARK: - Velocity-seeded navigation
print()
print("Velocity-Seeded Navigation Tests")

section("navigateRight with velocity — focus change uses velocity")
do {
    var strip = makeStrip(columnCount: 3, snapPoints: [.middle])
    let anim = strip.navigateRight(at: 0, velocity: 1500)
    check(anim != nil, "animation created")
    assertEq(strip.activeColumnIndex, 1, "moved to col 1")
    assertClose(anim!.initialVelocity, 1500, tolerance: 1, "uses provided velocity")
}

section("navigateLeft with velocity — edge bounce uses kickVelocity")
do {
    var strip = makeStrip(columnCount: 3, snapPoints: [.middle])
    let anim = strip.navigateLeft(at: 0, velocity: 800)
    check(anim != nil, "animation created")
    assertClose(anim!.to, strip.snapTargetForActive(at: 0), tolerance: 0.5,
                "rubber-band to == canonical snap")
    assertClose(anim!.initialVelocity, -800, tolerance: 1, "kick velocity preserved")
}

section("navigateRight with velocity — snap point advance uses velocity")
do {
    var strip = makeStrip(columnCount: 2, snapPoints: [.left, .middle, .right])
    // Set to right snap (index 2); navigateRight decrements to middle (index 1)
    // Current viewOffset=0 (left), target will be -360 (middle) — distinct, so animation fires
    strip.snapIndices[0] = 2
    let anim = strip.navigateRight(at: 0, velocity: 500)
    check(anim != nil, "animation created")
    assertEq(strip.snapIndices[0], 1, "snap advanced from right to middle")
}

// MARK: - setWidthPreset
print()
print("setWidthPreset Tests")

section("setWidthPreset — direct selection")
do {
    var strip = makeStrip(columnCount: 2)
    strip.widthPresets = [.proportion(0.25), .proportion(0.5), .proportion(0.67)]
    strip.setWidthPreset(index: 2, at: 0, params: nil)
    assertEq(strip.columns[0].presetIndex, 2, "preset index set")
    let expectedWidth = strip.widthPresets[2].resolve(
        workingAreaWidth: strip.workingArea.width, gap: strip.gap
    )
    assertClose(strip.columnData[0].cachedWidth, expectedWidth, tolerance: 1, "width resolved")
    check(strip.columnData[0].widthAnimation == nil, "no animation when params is nil")
}

section("setWidthPreset — animated")
do {
    var strip = makeStrip(columnCount: 2)
    strip.widthPresets = [.proportion(0.25), .proportion(0.5), .proportion(0.67)]
    strip.setWidthPreset(index: 0, at: 0, params: .horizontalScroll)
    assertEq(strip.columns[0].presetIndex, 0, "preset index set")
    check(strip.columnData[0].widthAnimation != nil, "animation created with params")
}

// MARK: - CursorConfig

section("CursorConfig — defaults")
do {
    let config = CursorConfig()
    assertEq(config.longPressDelayMs, 300, "default long press delay")
    assertClose(config.dragThresholdPx, 5.0, tolerance: 0.01, "default drag threshold")
    assertClose(config.swipeThresholdPx, 50.0, tolerance: 0.01, "default swipe threshold")
    assertClose(config.titleBarCornerInsetPx, 8.0, tolerance: 0.01, "default title bar corner inset")
}

section("ReorderOverlayConfig — defaults")
do {
    let config = ReorderOverlayConfig()
    assertEq(config.thumbnailStyle, "screenshot", "default thumbnail style")
    assertClose(config.thumbnailHeight, 160.0, tolerance: 0.01, "default thumbnail height")
}

// MARK: - removeColumn viewOffset Preservation

print("removeColumn viewOffset Preservation Tests")

section("removeColumn — left of active preserves visual position")
do {
    // 3 columns, active=2, each 720px wide, gap=16
    var strip = makeStrip(columnCount: 3)
    strip.activeColumnIndex = 2
    strip.viewOffset = .static(-100)
    let viewPosBefore = strip.viewPos(at: 0)
    let removedWidth = strip.columnData[0].currentWidth(at: 0) + strip.gap  // 736
    strip.removeColumn(at: 0, at: 0)
    // columnX(active) drops by removedWidth automatically because columnData
    // is now shorter; viewOffset must stay the same to keep the active column
    // pinned at its on-screen position. viewPos therefore decreases by exactly
    // removedWidth (the strip slid left under a stationary viewport-relative
    // anchor).
    assertClose(strip.viewOffset.current(at: 0), -100, tolerance: 0.1, "viewOffset should be unchanged")
    assertClose(strip.viewPos(at: 0), viewPosBefore - removedWidth, tolerance: 0.1, "viewPos shifts by exactly removedWidth")
    assertEq(strip.activeColumnIndex, 1, "active index should decrement")
}

section("removeColumn — left of active keeps active column on-screen")
do {
    // Regression: when a left-of-active column was removed (e.g. HealthCheck
    // killing the prior Fork window after a repo swap inserted the new window
    // to its right via snapshot restore), the viewport jumped left by 2×
    // removedWidth, leaving the focused window off-center to the right and the
    // window one to its left visually centered.
    var strip = makeStrip(columnCount: 3)
    strip.activeColumnIndex = 2
    strip.viewOffset = .static(strip.snapTargetForActive(at: 0))
    let activeOnScreenBefore = strip.columnX(at: 2, time: 0) - strip.viewPos(at: 0)
    strip.removeColumn(at: 0, at: 0)
    let activeOnScreenAfter = strip.columnX(at: strip.activeColumnIndex, time: 0) - strip.viewPos(at: 0)
    assertClose(activeOnScreenAfter, activeOnScreenBefore, tolerance: 0.1, "active column's on-screen X must not move when a left column is removed")
}

section("removeColumn — right of active preserves viewOffset")
do {
    var strip = makeStrip(columnCount: 3)
    strip.activeColumnIndex = 0
    strip.viewOffset = .static(-200)
    strip.removeColumn(at: 2, at: 0)
    // Removing column to the right should not change viewOffset
    assertClose(strip.viewOffset.current(at: 0), -200, tolerance: 0.1, "viewOffset should be unchanged")
    assertEq(strip.activeColumnIndex, 0, "active index unchanged")
}

section("removeColumn — active column recenters")
do {
    var strip = makeStrip(columnCount: 3)
    strip.activeColumnIndex = 1
    strip.viewOffset = .static(-999)
    strip.removeColumn(at: 1, at: 0)
    // Removing active column should recenter on new active
    let offset = strip.viewOffset.current(at: 0)
    // New active is column 1 (right neighbor). Snap offset for middle with 720px column and 1440 wa = -360
    assertClose(offset, -360, tolerance: 0.1, "should recenter on new active column")
}

// MARK: - computeTargetFrames Horizontal Positioning

print("computeTargetFrames Horizontal Positioning Tests")

section("computeTargetFrames — single column centered")
do {
    let strip = makeLayoutStrip(widths: [720], activeIndex: 0, viewOffset: -360)
    // viewPos = columnX(0) + viewOffset = 0 + (-360) = -360
    // screenX = colX(0) - viewPos + wa.minX = 0 - (-360) + 0 = 360
    let frames = computeTargetFrames(strip: strip, time: 0)
    check(!frames.isEmpty, "should have frames")
    if let f = frames.first {
        assertClose(Double(f.frame.minX), 360.0, tolerance: 1.0, "column centered at x=360")
        assertClose(Double(f.frame.width), 720.0, tolerance: 1.0, "column width 720")
        check(f.isVisible, "single centered column should be visible")
    }
}

section("computeTargetFrames — two columns, left visible")
do {
    // Two 600px columns with gap=16, viewOffset=0 (left-aligned)
    let strip = makeLayoutStrip(widths: [600, 600], activeIndex: 0, viewOffset: 0)
    // viewPos = columnX(0) + 0 = 0
    // col0 screenX = 0 - 0 + 0 = 0
    // col1 screenX = 616 - 0 + 0 = 616
    let frames = computeTargetFrames(strip: strip, time: 0)
    assertEq(frames.count, 2, "two tiles")
    let f0 = frames.first(where: { $0.tileID == TileID(1) })
    let f1 = frames.first(where: { $0.tileID == TileID(2) })
    if let f0 = f0 {
        assertClose(Double(f0.frame.minX), 0.0, tolerance: 1.0, "col0 at x=0")
        check(f0.isVisible, "col0 visible")
    }
    if let f1 = f1 {
        assertClose(Double(f1.frame.minX), 616.0, tolerance: 1.0, "col1 at x=616")
        check(f1.isVisible, "col1 visible")
    }
}

section("computeTargetFrames — far column off-screen")
do {
    // 5 columns of 720px each, active=0, viewOffset=0. Columns beyond screen should be far.
    let strip = makeLayoutStrip(widths: [720, 720, 720, 720, 720], activeIndex: 0, viewOffset: 0)
    let frames = computeTargetFrames(strip: strip, time: 0)
    // col0: x=0 (visible), col1: x=736 (visible), col2: x=1472 (partially visible or near)
    // col3: x=2208 (far), col4: x=2944 (far)
    let f3 = frames.first(where: { $0.tileID == TileID(4) })
    let f4 = frames.first(where: { $0.tileID == TileID(5) })
    if let f3 = f3 {
        check(f3.isOffScreen, "col3 should be off-screen")
    }
    if let f4 = f4 {
        check(f4.isOffScreen, "col4 should be off-screen")
    }
}

// MARK: - Config Validation

print("Config Validation Tests")

section("Config — negative gap clamped to 0")
do {
    let toml = """
    [layout]
    gap = -5
    """
    let table = try! TOMLTable(string: toml)
    let config = ReelConfig.load(from: table)
    assertClose(config.gap, 0, tolerance: 0.01, "negative gap clamped to 0")
}

section("Config — negative stiffness clamped to 1")
do {
    let toml = """
    [animation]
    scroll_stiffness = -100
    """
    let table = try! TOMLTable(string: toml)
    let config = ReelConfig.load(from: table)
    assertClose(config.scrollStiffness, 1, tolerance: 0.01, "negative stiffness clamped to 1")
}

section("Config — damping ratio clamped to 0.01")
do {
    let toml = """
    [animation]
    scroll_damping_ratio = 0
    """
    let table = try! TOMLTable(string: toml)
    let config = ReelConfig.load(from: table)
    assertClose(config.scrollDampingRatio, 0.01, tolerance: 0.001, "zero damping ratio clamped to 0.01")
}

section("Config — proportion clamped to [0.01, 1]")
do {
    let toml = """
    [layout.default_width]
    proportion = 5.0
    """
    let table = try! TOMLTable(string: toml)
    let config = ReelConfig.load(from: table)
    if case .proportion(let p) = config.defaultWidth {
        assertClose(p, 1.0, tolerance: 0.01, "proportion clamped to 1.0")
    } else {
        check(false, "should be proportion type")
    }
}

section("Config — invalid regex ignored")
do {
    let toml = """
    [[rules]]
    app_id_regex = "[invalid("
    floating = true
    """
    let table = try! TOMLTable(string: toml)
    let config = ReelConfig.load(from: table)
    assertEq(config.rules.count, 1, "rule should still be added")
    check(config.rules[0].appIDRegex == nil, "invalid regex should be nil")
}

// MARK: - IPC Message Round-Trip

print("IPC Message Round-Trip Tests")

section("IPCMessage — encode/decode round-trip")
do {
    let msg = IPCMessage(command: "focus-left")
    let data = try! JSONEncoder().encode(msg)
    let decoded = try! JSONDecoder().decode(IPCMessage.self, from: data)
    check(decoded.command == "focus-left", "command preserved")
    check(decoded.appID == nil, "appID nil when not set")
}

section("IPCMessage — with appID round-trip")
do {
    let msg = IPCMessage(command: "clear-positions", appID: "com.example.app")
    let data = try! JSONEncoder().encode(msg)
    let decoded = try! JSONDecoder().decode(IPCMessage.self, from: data)
    check(decoded.command == "clear-positions", "command preserved")
    check(decoded.appID == "com.example.app", "appID preserved")
}

section("ReelResponse — success round-trip")
do {
    let resp = ReelResponse(success: true, message: "ok", data: "{\"count\":5}")
    let data = try! JSONEncoder().encode(resp)
    let decoded = try! JSONDecoder().decode(ReelResponse.self, from: data)
    check(decoded.success == true, "success preserved")
    check(decoded.message == "ok", "message preserved")
    check(decoded.data == "{\"count\":5}", "data preserved")
}

section("ReelResponse — failure with nil fields")
do {
    let resp = ReelResponse(success: false)
    let data = try! JSONEncoder().encode(resp)
    let decoded = try! JSONDecoder().decode(ReelResponse.self, from: data)
    check(decoded.success == false, "success false preserved")
    check(decoded.message == nil, "nil message preserved")
    check(decoded.data == nil, "nil data preserved")
}

section("ReelCommand — rawValue round-trip")
do {
    for cmd in ReelCommand.allCases {
        let encoded = try! JSONEncoder().encode(cmd)
        let decoded = try! JSONDecoder().decode(ReelCommand.self, from: encoded)
        check(decoded == cmd, "\(cmd.rawValue) round-trip")
    }
}

// ============================================================
// MARK: - Reorder Insertion Index

section("Insertion index — cursor left of all thumbnails")
do {
    // 3 columns [A, B, C], dragging B (index 1). Non-dragged: [A, C] at indices [0, 2].
    // Thumbnails at x: 100 (A), 250 (C). Midpoint: 175.
    let result = computeReorderInsertionIndex(
        cursorX: 50,
        thumbnailMidpoints: [175],
        nonDraggedOriginalIndices: [0, 2],
        draggedIndex: 1,
        columnCount: 3
    )
    assertEq(result, 0, "cursor left of all → insert at 0")
}

section("Insertion index — cursor right of all thumbnails")
do {
    let result = computeReorderInsertionIndex(
        cursorX: 300,
        thumbnailMidpoints: [175],
        nonDraggedOriginalIndices: [0, 2],
        draggedIndex: 1,
        columnCount: 3
    )
    assertEq(result, 3, "cursor right of all → insert at end")
}

section("Insertion index — cursor between thumbnails")
do {
    // 4 columns [A, B, C, D], dragging A (index 0). Non-dragged: [B, C, D] at indices [1, 2, 3].
    // Midpoints: [175, 325].
    let result = computeReorderInsertionIndex(
        cursorX: 200,
        thumbnailMidpoints: [175, 325],
        nonDraggedOriginalIndices: [1, 2, 3],
        draggedIndex: 0,
        columnCount: 4
    )
    assertEq(result, 2, "cursor between B and C → insert at 2")
}

section("Insertion index — single non-dragged column, cursor left")
do {
    // 2 columns [A, B], dragging A (index 0). Non-dragged: [B] at index [1].
    // Thumbnail B is centered at ~150; midpoint at 150 splits left/right.
    let result = computeReorderInsertionIndex(
        cursorX: 50,
        thumbnailMidpoints: [150],
        nonDraggedOriginalIndices: [1],
        draggedIndex: 0,
        columnCount: 2
    )
    assertEq(result, 0, "cursor left of single thumbnail → insert at 0")
}

section("Insertion index — single non-dragged column, cursor right")
do {
    let result = computeReorderInsertionIndex(
        cursorX: 300,
        thumbnailMidpoints: [150],
        nonDraggedOriginalIndices: [1],
        draggedIndex: 0,
        columnCount: 2
    )
    assertEq(result, 2, "cursor right of single thumbnail → insert at end")
}

section("Insertion index — dragging last column")
do {
    // 3 columns [A, B, C], dragging C (index 2). Non-dragged: [A, B] at indices [0, 1].
    // Midpoint: 175.
    let result = computeReorderInsertionIndex(
        cursorX: 100,
        thumbnailMidpoints: [175],
        nonDraggedOriginalIndices: [0, 1],
        draggedIndex: 2,
        columnCount: 3
    )
    assertEq(result, 0, "dragging last, cursor before first → insert at 0")
}

// MARK: - focusColumnIncremental Tests
print()
print("focusColumnIncremental Tests")

section("fully visible active column → anchorOnly, no scroll")
do {
    // 3 columns of 0.5 width on 1440px screen: each col 720, gap 16.
    // Col 0: x=0; Col 1: x=736; Col 2: x=1472.
    // viewOffset makes activeColumn middle (slack=720-720=0 — all snaps = 0).
    // With activeIndex=1 and col1 centered, col1 occupies x=16..736 on screen (roughly).
    // Let's use narrower columns so we can see visible vs off-screen.
    var strip = makeStrip(columnCount: 3, width: 0.3, snapPoints: [.middle])
    // cols width = 432, gap 16. totalWidth = 3*432 + 2*16 = 1328. screen 1440. slack = 1008.
    // activeIndex=0, snap=middle → offset = -504
    strip.activeColumnIndex = 0
    strip.snapIndices = [0, 0, 0]
    strip.viewOffset = .static(-504)  // col0 centered on screen
    // On screen: col0 at x=504..936; col1 at x=952..1384 (still visible). col2 off right.
    let result = strip.focusColumnIncremental(colIndex: 1, at: 0, animated: false)
    assertEq(result, .anchorOnly, "col1 is fully visible → anchorOnly")
    assertEq(strip.activeColumnIndex, 1, "activeColumnIndex updated")
    // viewOffset re-anchored: oldColX=0, newColX=448 (432+16). adjusted = -504 + 0 - 448 = -952
    if case .static(let off) = strip.viewOffset {
        assertClose(off, -952, tolerance: 0.01, "re-anchored offset")
    } else {
        check(false, "expected static viewOffset after anchorOnly")
    }
    assertEq(strip.snapIndices[1], 0, "snap index untouched")
}

section("off-right column → scrolls to first leftward milestone")
do {
    // 3 cols of 0.3 width (432 each), snapPoints = [.left, .middle, .right]
    var strip = makeStrip(columnCount: 3, width: 0.3, snapPoints: [.left, .middle, .right])
    // cols width = 432, screen 1440, slack = 1008.
    // offsets per snap: .left = 0, .middle = -504, .right = -1008
    // activeIndex=0, snap=.left → offset = 0. col0 at x=0..432; col1 at x=448..880; col2 at x=896..1328 (visible).
    // Push col2 off: set viewOffset to .left for col0 AND swap activeIndex=0 to right-shift cols.
    // Instead: use 4 columns so col3 is clearly off-right.
    var strip4 = makeStrip(columnCount: 4, width: 0.3, snapPoints: [.left, .middle, .right])
    strip4.activeColumnIndex = 0
    strip4.snapIndices = [0, 0, 0, 0]  // all .left
    strip4.viewOffset = .static(0)  // col0 at left
    // col0: 0..432, col1: 448..880, col2: 896..1328, col3: 1344..1776 (off-right)
    let result = strip4.focusColumnIncremental(colIndex: 3, at: 0, animated: false)
    // Need to travel leftward: nextSnapMilestoneLeft from adjustedOffset.
    // adjustedOffset = 0 + 0 - 1344 = -1344. snapPoints in column-space offsets:
    //   .left=0, .middle=-504, .right=-1008.
    // Iterate right→left indices (2,1,0): offset -1008 > -1344? yes → index 2 (.right).
    // So target offset = -1008.
    assertEq(strip4.activeColumnIndex, 3, "activeColumnIndex updated to 3")
    assertEq(strip4.snapIndices[3], 2, "snap index set to .right (milestone leftward)")
    if case .scrolledInstant(let to) = result {
        assertClose(to, -1008, tolerance: 0.01, "target offset = .right snap")
    } else {
        check(false, "expected scrolledInstant, got \(result)")
    }
    if case .static(let off) = strip4.viewOffset {
        assertClose(off, -1008, tolerance: 0.01, "viewOffset set to target")
    } else {
        check(false, "expected static viewOffset")
    }
}

section("off-left column → scrolls to first rightward milestone")
do {
    var strip = makeStrip(columnCount: 4, width: 0.3, snapPoints: [.left, .middle, .right])
    // same geometry as above
    strip.activeColumnIndex = 3
    strip.snapIndices = [2, 2, 2, 2]  // all .right
    strip.viewOffset = .static(-1008)  // col3 right-aligned
    // col positions on screen: col3 at x=1008..1440; col0 off-left at x= -1344..-912, etc.
    let result = strip.focusColumnIncremental(colIndex: 0, at: 0, animated: false)
    // adjustedOffset = -1008 + col3X - col0X = -1008 + 1344 - 0 = 336.
    // Iterate 0→n: .left=0 → 336 > 0? yes → index 0.
    // target offset = 0.
    assertEq(strip.activeColumnIndex, 0, "active updated to 0")
    assertEq(strip.snapIndices[0], 0, "snap set to .left (milestone rightward)")
    if case .scrolledInstant(let to) = result {
        assertClose(to, 0, tolerance: 0.01, "target offset = .left snap")
    } else {
        check(false, "expected scrolledInstant, got \(result)")
    }
}

section("animated path produces .animation viewOffset")
do {
    var strip = makeStrip(columnCount: 4, width: 0.3, snapPoints: [.middle])
    strip.activeColumnIndex = 0
    strip.snapIndices = [0, 0, 0, 0]
    strip.viewOffset = .static(0)
    let result = strip.focusColumnIncremental(colIndex: 3, at: 1.0, animated: true)
    if case .scrolledAnimated(let from, let to) = result {
        check(from != to, "from/to differ")
    } else {
        check(false, "expected scrolledAnimated, got \(result)")
    }
    if case .animation = strip.viewOffset {
        check(true)
    } else {
        check(false, "expected animation viewOffset")
    }
}

section("click on current active column → anchorOnly, no visual change")
do {
    var strip = makeStrip(columnCount: 3, width: 0.3, snapPoints: [.middle])
    strip.activeColumnIndex = 1
    strip.snapIndices = [0, 0, 0]
    strip.viewOffset = .static(-504)
    let before = strip.viewOffset
    let result = strip.focusColumnIncremental(colIndex: 1, at: 0, animated: false)
    assertEq(result, .anchorOnly, "same-column click")
    assertEq(strip.activeColumnIndex, 1)
    // viewOffset re-anchored with delta 0 (old == new column) → unchanged
    if case .static(let a) = strip.viewOffset, case .static(let b) = before {
        assertClose(a, b, tolerance: 0.01, "viewOffset unchanged")
    }
}

section("invalid colIndex → noChange")
do {
    var strip = makeStrip(columnCount: 2)
    let result = strip.focusColumnIncremental(colIndex: 99, at: 0, animated: false)
    assertEq(result, .noChange)
    assertEq(strip.activeColumnIndex, 0, "active unchanged")
}

section("column wider than screen → clamps to offset 0")
do {
    // col width 1600 > screen 1440, slack < 0, computeSnapOffset returns 0 regardless of snap.
    var strip = makeStrip(columnCount: 2, width: 1.2, snapPoints: [.left, .middle, .right])
    strip.activeColumnIndex = 0
    strip.snapIndices = [0, 0]
    strip.viewOffset = .static(-200)  // off-left scenario
    // col1 position depends, but all snaps collapse to 0.
    let result = strip.focusColumnIncremental(colIndex: 1, at: 0, animated: false)
    if case .scrolledInstant(let to) = result {
        assertClose(to, 0, tolerance: 0.01, "all snaps collapse to 0")
    }
}

// MARK: - Raise Focus Indicator Offset

print("Raise Focus Indicator Offset Tests")

// Helper: set cachedRaiseTarget on every column based on active index (matches applyLayout's sync).
func syncRaiseTargets(_ strip: inout Strip, raiseHeight rh: Double) {
    for i in 0..<strip.columnData.count where strip.columnData[i].raiseAnimation == nil {
        strip.columnData[i].cachedRaiseTarget = (i == strip.activeColumnIndex) ? 0 : rh
    }
}

section("raiseHeight — active hangs from ceiling, others sit at bottom, all same reduced height")
do {
    var strip = makeLayoutStrip(widths: [720, 720, 720], activeIndex: 1, viewOffset: 0)
    let wa = strip.workingArea  // y=25, height=875
    let rh: Double = 20
    syncRaiseTargets(&strip, raiseHeight: rh)
    let frames = computeTargetFrames(strip: strip, time: 0, raiseHeight: rh)

    // Column 0 (not active): y shifted down, reduced height
    assertClose(Double(frames[0].frame.minY), Double(wa.minY) + rh, tolerance: 1, "col 0 y shifted down")
    assertClose(Double(frames[0].frame.height), Double(wa.height) - rh, tolerance: 1, "col 0 reduced height")

    // Column 1 (active): hangs from ceiling, same reduced height
    assertClose(Double(frames[1].frame.minY), Double(wa.minY), tolerance: 1, "active col at ceiling")
    assertClose(Double(frames[1].frame.height), Double(wa.height) - rh, tolerance: 1, "active col reduced height")

    // Column 2 (not active): y shifted down, reduced height
    assertClose(Double(frames[2].frame.minY), Double(wa.minY) + rh, tolerance: 1, "col 2 y shifted down")
    assertClose(Double(frames[2].frame.height), Double(wa.height) - rh, tolerance: 1, "col 2 reduced height")
}

section("raiseHeight = 0 — no change from normal layout")
do {
    let strip = makeLayoutStrip(widths: [720, 720], activeIndex: 0, viewOffset: 0)
    let normalFrames = computeTargetFrames(strip: strip, time: 0)
    let raiseFrames = computeTargetFrames(strip: strip, time: 0, raiseHeight: 0)
    for i in 0..<normalFrames.count {
        assertEq(normalFrames[i].frame, raiseFrames[i].frame, "frame \(i) unchanged with zero raiseHeight")
    }
}

section("raiseHeight — single column (active) hangs from ceiling, reduced height")
do {
    var strip = makeLayoutStrip(widths: [720], activeIndex: 0, viewOffset: -360)
    let wa = strip.workingArea
    syncRaiseTargets(&strip, raiseHeight: 30)
    let frames = computeTargetFrames(strip: strip, time: 0, raiseHeight: 30)
    assertClose(Double(frames[0].frame.minY), Double(wa.minY), tolerance: 1, "single active col at ceiling")
    assertClose(Double(frames[0].frame.height), Double(wa.height) - 30, tolerance: 1, "single active col reduced height")
}

section("raiseHeight — multi-tile column splits reduced height")
do {
    // 2-tile non-active column should split the reduced height evenly
    let wa = CGRect(x: 0, y: 25, width: 1440, height: 875)
    let col0 = Column(tiles: [TileID(1), TileID(2)], width: .fixed(720))
    let col1 = Column(tiles: [TileID(3)], width: .fixed(720))
    var strip = Strip(columns: [col0, col1], columnData: [ColumnData(cachedWidth: 720), ColumnData(cachedWidth: 720)], activeColumnIndex: 1, viewOffset: .static(0), snapIndices: [0, 0], gap: 16, workingArea: wa)
    let rh: Double = 20
    syncRaiseTargets(&strip, raiseHeight: rh)
    // frames[0] and frames[1] are col0's two tiles (non-active), frames[2] is col1 (active)
    let frames = computeTargetFrames(strip: strip, time: 0, raiseHeight: rh)
    assertEq(frames.count, 3)

    let reducedHeight = Double(wa.height) - rh
    let expectedTileHeight = (reducedHeight - 16) / 2.0  // 2 tiles, 1 gap
    assertClose(Double(frames[0].frame.minY), Double(wa.minY) + rh, tolerance: 1, "multi-tile col top tile y")
    assertClose(Double(frames[0].frame.height), expectedTileHeight, tolerance: 1, "multi-tile col top tile height")
    assertClose(Double(frames[1].frame.minY), Double(wa.minY) + rh + expectedTileHeight + 16, tolerance: 1, "multi-tile col bottom tile y")
    assertClose(Double(frames[1].frame.height), expectedTileHeight, tolerance: 1, "multi-tile col bottom tile height")

    // Active column (col1) — hangs from ceiling, reduced height
    assertClose(Double(frames[2].frame.minY), Double(wa.minY), tolerance: 1, "active col at ceiling")
    assertClose(Double(frames[2].frame.height), reducedHeight, tolerance: 1, "active col reduced height")
}

section("raiseHeight — off-screen non-active column sliver inherits offset")
do {
    // 3 columns, only first ~2 visible; column 2 is off-screen and non-active
    var strip = makeLayoutStrip(widths: [720, 720, 720], activeIndex: 0, viewOffset: 0)
    let wa = strip.workingArea
    let rh: Double = 20
    syncRaiseTargets(&strip, raiseHeight: rh)
    let frames = computeTargetFrames(strip: strip, time: 0, sliverWidth: 1, raiseHeight: rh)
    // Column 2 should be off-screen
    check(frames[2].isOffScreen, "col 2 should be off-screen")
    // Its sliver frame height should be the reduced height
    assertClose(Double(frames[2].frame.height), Double(wa.height) - rh, tolerance: 1, "off-screen sliver uses reduced height")
}

// MARK: - ColumnData raiseAnimation

print("ColumnData raiseAnimation Tests")

section("currentRaiseOffset — no animation returns cachedRaiseTarget")
do {
    var cd = ColumnData(cachedWidth: 720)
    // Default cachedRaiseTarget is 0
    assertClose(cd.currentRaiseOffset(at: 0), 0, tolerance: 0.1, "default target 0")
    // Set target to 20 (non-active column)
    cd.cachedRaiseTarget = 20
    assertClose(cd.currentRaiseOffset(at: 0), 20, tolerance: 0.1, "target 20")
}

section("currentRaiseOffset — mid-animation returns interpolated value")
do {
    let params = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)
    // Animate from 0 (ceiling) to 20 (bottom) — column losing focus
    let anim = SpringAnimation(from: 0, to: 20, startTime: 0, params: params)
    var cd = ColumnData(cachedWidth: 720, raiseAnimation: anim)
    cd.cachedRaiseTarget = 20
    // At time 0.001: should be near the start value (0)
    let earlyVal = cd.currentRaiseOffset(at: 0.001)
    check(earlyVal < 10, "early in animation should be closer to 0, got \(earlyVal)")
    check(earlyVal > -1, "should not be negative")
}

section("currentRaiseOffset — done animation returns cachedRaiseTarget")
do {
    let params = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)
    let anim = SpringAnimation(from: 0, to: 20, startTime: 0, params: params)
    var cd = ColumnData(cachedWidth: 720, raiseAnimation: anim)
    cd.cachedRaiseTarget = 20
    // At time 5s: spring is long converged
    let lateVal = cd.currentRaiseOffset(at: 5.0)
    assertClose(lateVal, 20, tolerance: 1, "converged to cachedRaiseTarget")
}

// MARK: - Strip settleRaiseAnimations

print("Strip settleRaiseAnimations Tests")

section("settleRaiseAnimations — nils converged springs")
do {
    let params = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)
    var strip = makeLayoutStrip(widths: [720, 720], activeIndex: 0, viewOffset: 0)
    strip.columnData[1].raiseAnimation = SpringAnimation(from: 0, to: 20, startTime: 0, params: params)
    let anyActive = strip.settleRaiseAnimations(at: 5.0)
    check(!anyActive, "all converged, none active")
    check(strip.columnData[1].raiseAnimation == nil, "converged spring should be nil")
}

section("settleRaiseAnimations — keeps in-flight springs")
do {
    let params = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)
    var strip = makeLayoutStrip(widths: [720, 720], activeIndex: 0, viewOffset: 0)
    strip.columnData[1].raiseAnimation = SpringAnimation(from: 0, to: 20, startTime: 10.0, params: params)
    let anyActive = strip.settleRaiseAnimations(at: 10.001)
    check(anyActive, "in-flight spring should still be active")
    check(strip.columnData[1].raiseAnimation != nil, "in-flight spring should not be nil")
}

// ============================================================

// MARK: - Animated raiseHeight in computeTargetFrames

print("Animated raiseHeight in computeTargetFrames Tests")

section("raiseHeight with per-column animation — mid-animation Y offset")
do {
    let wa = CGRect(x: 0, y: 25, width: 1440, height: 875)
    let params = SpringParams(dampingRatio: 1.0, stiffness: 800, epsilon: 0.5)

    // Column 0 is active (at ceiling), column 1 just lost focus (animating 0 → 20)
    var cd0 = ColumnData(cachedWidth: 720)
    cd0.cachedRaiseTarget = 0
    var cd1 = ColumnData(cachedWidth: 720, raiseAnimation: SpringAnimation(from: 0, to: 20, startTime: 0, params: params))
    cd1.cachedRaiseTarget = 20

    let col0 = Column(tiles: [TileID(1)], width: .fixed(720))
    let col1 = Column(tiles: [TileID(2)], width: .fixed(720))
    let strip = Strip(columns: [col0, col1], columnData: [cd0, cd1], activeColumnIndex: 0, viewOffset: .static(0), snapIndices: [0, 0], gap: 16, workingArea: wa)

    // At time 0.001 — col1's animation just started, Y offset should be near 0
    let frames = computeTargetFrames(strip: strip, time: 0.001, raiseHeight: 20)
    // Col 0 (active, no animation, target=0): y = wa.minY
    assertClose(Double(frames[0].frame.minY), Double(wa.minY), tolerance: 1, "active col at ceiling")
    // Col 1 (non-active, mid-animation): y between wa.minY and wa.minY+20
    let col1Y = Double(frames[1].frame.minY)
    check(col1Y >= Double(wa.minY) - 1, "col1 y not above ceiling, got \(col1Y)")
    check(col1Y < Double(wa.minY) + 15, "col1 y should be early in animation (close to ceiling), got \(col1Y)")
    // Both columns have same reduced height
    assertClose(Double(frames[0].frame.height), Double(wa.height) - 20, tolerance: 1, "col0 reduced height")
    assertClose(Double(frames[1].frame.height), Double(wa.height) - 20, tolerance: 1, "col1 reduced height")
}

section("raiseHeight — default cachedRaiseTarget (0) places all columns at ceiling")
do {
    // Before applyLayout() sync, all columns have cachedRaiseTarget = 0 (default).
    // Verifies that computeTargetFrames doesn't assume activeColumnIndex — it reads per-column state.
    let strip = makeLayoutStrip(widths: [720, 720], activeIndex: 0, viewOffset: 0)
    let frames = computeTargetFrames(strip: strip, time: 0, raiseHeight: 20)
    for i in 0..<frames.count {
        assertClose(Double(frames[i].frame.minY), Double(strip.workingArea.minY), tolerance: 1, "frame \(i) default at ceiling")
    }
}

// ============================================================

// MARK: - DisplayRegion Tests
print()
print("DisplayRegion Tests")

section("DisplayRegion stores displayID and rect")
do {
    let region = DisplayRegion(displayID: 42, rect: CGRect(x: 100, y: 0, width: 1440, height: 900))
    assertEq(region.displayID, UInt32(42), "displayID round-trips")
    assertEq(region.rect, CGRect(x: 100, y: 0, width: 1440, height: 900), "rect round-trips")
}

section("DisplayRegion is Equatable")
do {
    let a = DisplayRegion(displayID: 1, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
    let b = DisplayRegion(displayID: 1, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
    let c = DisplayRegion(displayID: 2, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
    check(a == b, "same displayID + rect equal")
    check(a != c, "different displayID differs")
}

// MARK: - GroupWorkingArea Tests
print()
print("GroupWorkingArea Tests")

section("solo region — totalSpan equals the region rect")
do {
    let r = CGRect(x: 0, y: 25, width: 1440, height: 875)
    let ga = GroupWorkingArea(
        regions: [DisplayRegion(displayID: 1, rect: r)],
        referenceMidX: r.midX
    )
    assertEq(ga.totalSpan, r, "solo totalSpan = rect")
    assertEq(ga.referenceMidX, r.midX, "referenceMidX set")
    assertEq(ga.regions.count, 1, "one region")
}

section("two flush regions — totalSpan is their union")
do {
    let r0 = CGRect(x: 0, y: 25, width: 1440, height: 875)
    let r1 = CGRect(x: 1440, y: 25, width: 2560, height: 1415)
    let ga = GroupWorkingArea(
        regions: [DisplayRegion(displayID: 1, rect: r0),
                  DisplayRegion(displayID: 2, rect: r1)],
        referenceMidX: r0.midX
    )
    assertEq(ga.totalSpan.minX, 0, "union minX")
    assertEq(ga.totalSpan.maxX, 4000, "union maxX (1440+2560)")
    assertEq(ga.totalSpan.minY, 25, "union minY")
    assertEq(ga.totalSpan.maxY, 1440, "union maxY")
}

section("two regions with gap — totalSpan spans the gap")
do {
    let r0 = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let r1 = CGRect(x: 1100, y: 0, width: 1000, height: 800)  // 100px gap
    let ga = GroupWorkingArea(
        regions: [DisplayRegion(displayID: 1, rect: r0),
                  DisplayRegion(displayID: 2, rect: r1)],
        referenceMidX: r0.midX
    )
    assertEq(ga.totalSpan, CGRect(x: 0, y: 0, width: 2100, height: 800), "union bridges gap")
}

// MARK: - Strip.groupArea Tests
print()
print("Strip.groupArea Tests")

section("Strip constructed from groupArea exposes workingArea computed")
do {
    let r = CGRect(x: 0, y: 25, width: 1440, height: 875)
    let ga = GroupWorkingArea(
        regions: [DisplayRegion(displayID: 1, rect: r)],
        referenceMidX: r.midX
    )
    let strip = Strip(groupArea: ga)
    assertEq(strip.groupArea, ga, "groupArea round-trips")
    assertEq(strip.workingArea, r, "workingArea is totalSpan")
}

section("Strip constructed from CGRect wraps in singleton group")
do {
    let r = CGRect(x: 10, y: 20, width: 1000, height: 700)
    let strip = Strip(workingArea: r)
    assertEq(strip.workingArea, r, "workingArea round-trips")
    assertEq(strip.groupArea.regions.count, 1, "singleton group")
    assertEq(strip.groupArea.regions[0].rect, r, "region rect = workingArea")
    assertEq(strip.groupArea.regions[0].displayID, UInt32(0), "synthesized displayID = 0")
    assertEq(strip.groupArea.referenceMidX, r.midX, "referenceMidX = midX of singleton")
}

// MARK: - ColumnWidth.resolveBlended Tests
print()
print("ColumnWidth.resolveBlended Tests")

section("proportion — fully on region 0 (no blend)")
do {
    let r0 = DisplayRegion(displayID: 1, rect: CGRect(x: 0, y: 0, width: 1000, height: 800))
    let overlaps: [(DisplayRegion, Double)] = [(r0, 1000 * 800)]
    let w = ColumnWidth.proportion(0.5).resolveBlended(overlaps: overlaps, gap: 16)
    assertClose(w, 500, tolerance: 0.5, "0.5 of r0 width")
}

section("proportion — fully on region 1 (no blend)")
do {
    let r1 = DisplayRegion(displayID: 2, rect: CGRect(x: 1000, y: 0, width: 2000, height: 1000))
    let overlaps: [(DisplayRegion, Double)] = [(r1, 2000 * 1000)]
    let w = ColumnWidth.proportion(0.5).resolveBlended(overlaps: overlaps, gap: 16)
    assertClose(w, 1000, tolerance: 0.5, "0.5 of r1 width")
}

section("proportion — 50/50 straddle blends by area")
do {
    let r0 = DisplayRegion(displayID: 1, rect: CGRect(x: 0, y: 0, width: 1000, height: 800))
    let r1 = DisplayRegion(displayID: 2, rect: CGRect(x: 1000, y: 0, width: 2000, height: 800))
    let overlaps: [(DisplayRegion, Double)] = [(r0, 100), (r1, 100)]
    let w = ColumnWidth.proportion(0.5).resolveBlended(overlaps: overlaps, gap: 16)
    assertClose(w, 0.5 * 0.5 * 1000 + 0.5 * 0.5 * 2000, tolerance: 0.5, "avg of 500 and 1000 = 750")
}

section("proportion — 30/70 straddle blends by area")
do {
    let r0 = DisplayRegion(displayID: 1, rect: CGRect(x: 0, y: 0, width: 1000, height: 800))
    let r1 = DisplayRegion(displayID: 2, rect: CGRect(x: 1000, y: 0, width: 2000, height: 800))
    let overlaps: [(DisplayRegion, Double)] = [(r0, 30), (r1, 70)]
    let w = ColumnWidth.proportion(0.5).resolveBlended(overlaps: overlaps, gap: 16)
    // 0.3 * 500 + 0.7 * 1000 = 150 + 700 = 850
    assertClose(w, 850, tolerance: 0.5, "area-weighted blend")
}

section("fixed — returns literal regardless of blend")
do {
    let r0 = DisplayRegion(displayID: 1, rect: CGRect(x: 0, y: 0, width: 1000, height: 800))
    let r1 = DisplayRegion(displayID: 2, rect: CGRect(x: 1000, y: 0, width: 2000, height: 800))
    let overlaps: [(DisplayRegion, Double)] = [(r0, 50), (r1, 50)]
    let w = ColumnWidth.fixed(300).resolveBlended(overlaps: overlaps, gap: 16)
    assertClose(w, 300, tolerance: 0.5, "fixed ignores blend")
}

section("auto — treated as proportion(0.5)")
do {
    let r0 = DisplayRegion(displayID: 1, rect: CGRect(x: 0, y: 0, width: 1000, height: 800))
    let overlaps: [(DisplayRegion, Double)] = [(r0, 1)]
    let w = ColumnWidth.auto.resolveBlended(overlaps: overlaps, gap: 16)
    assertClose(w, 500, tolerance: 0.5, "auto = proportion(0.5)")
}

section("empty overlaps — returns 0 (caller's fallback applies elsewhere)")
do {
    let overlaps: [(DisplayRegion, Double)] = []
    let w = ColumnWidth.proportion(0.5).resolveBlended(overlaps: overlaps, gap: 16)
    assertClose(w, 0, tolerance: 0.5, "no regions → 0")
}

// MARK: - computeColumnGeometry Tests
print("computeColumnGeometry Tests")

section("solo region — geometry is p × region.width, region.height")
do {
    let r = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let ga = GroupWorkingArea(
        regions: [DisplayRegion(displayID: 1, rect: r)],
        referenceMidX: r.midX
    )
    let g = computeColumnGeometry(
        groupArea: ga, centerX: r.midX, width: .proportion(0.5), gap: 16
    )
    assertClose(g.width, 500, tolerance: 0.5, "0.5 × 1000")
    assertClose(g.height, 800, tolerance: 0.5, "region height")
    assertClose(g.midY, 400, tolerance: 0.5, "region midY")
    check(g.fallbackRegion == nil, "no fallback for solo")
}

section("two regions — column entirely on region 1")
do {
    let r0 = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let r1 = CGRect(x: 1000, y: 0, width: 2000, height: 1000)
    let ga = GroupWorkingArea(
        regions: [DisplayRegion(displayID: 1, rect: r0),
                  DisplayRegion(displayID: 2, rect: r1)],
        referenceMidX: r0.midX
    )
    let g = computeColumnGeometry(
        groupArea: ga, centerX: r1.midX, width: .proportion(0.5), gap: 16
    )
    assertClose(g.width, 1000, tolerance: 0.5, "0.5 × 2000")
    assertClose(g.height, 1000, tolerance: 0.5, "r1 height")
    assertClose(g.midY, 500, tolerance: 0.5, "r1 midY")
    check(g.fallbackRegion == nil, "no fallback — overlap exists")
}

section("two regions — 50/50 straddle at seam")
do {
    let r0 = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let r1 = CGRect(x: 1000, y: 0, width: 1000, height: 800)
    let ga = GroupWorkingArea(
        regions: [DisplayRegion(displayID: 1, rect: r0),
                  DisplayRegion(displayID: 2, rect: r1)],
        referenceMidX: r0.midX
    )
    let g = computeColumnGeometry(
        groupArea: ga, centerX: 1000, width: .proportion(0.5), gap: 16
    )
    // equal widths → width converges to 0.5 × 1000 = 500
    assertClose(g.width, 500, tolerance: 0.5, "symmetric straddle → 500")
    assertClose(g.height, 800, tolerance: 0.5, "same height both sides")
    check(g.fallbackRegion == nil, "no fallback — overlap exists")
}

section("two regions with different heights — 50/50 straddle blends height")
do {
    let r0 = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let r1 = CGRect(x: 1000, y: 0, width: 1000, height: 1600)
    let ga = GroupWorkingArea(
        regions: [DisplayRegion(displayID: 1, rect: r0),
                  DisplayRegion(displayID: 2, rect: r1)],
        referenceMidX: r0.midX
    )
    let g = computeColumnGeometry(
        groupArea: ga, centerX: 1000, width: .proportion(0.5), gap: 16
    )
    check(g.height > 800 && g.height < 1600, "height blended, got \(g.height)")
}

section("entirely in a gap — fallbackRegion is set to nearest")
do {
    let r0 = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let r1 = CGRect(x: 1500, y: 0, width: 1000, height: 800)
    let ga = GroupWorkingArea(
        regions: [DisplayRegion(displayID: 1, rect: r0),
                  DisplayRegion(displayID: 2, rect: r1)],
        referenceMidX: r0.midX
    )
    // centerX = 1200 → nearest edge is r0.maxX=1000 (dist 200) vs r1.minX=1500 (dist 300).
    // So nearest = r0.
    let g = computeColumnGeometry(
        groupArea: ga, centerX: 1200, width: .proportion(0.5), gap: 16
    )
    assertClose(g.width, 500, tolerance: 0.5, "fallback to r0 width")
    assertClose(g.height, 800, tolerance: 0.5, "fallback to r0 height")
    check(g.fallbackRegion?.displayID == 1, "fallbackRegion = r0")
}

// MARK: - computeTargetFrames multi-region Tests
print("computeTargetFrames multi-region Tests")

section("two-region strip — column on region 0 keeps r0 dimensions")
do {
    let r0 = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let r1 = CGRect(x: 1000, y: 0, width: 2000, height: 1000)
    let ga = GroupWorkingArea(
        regions: [DisplayRegion(displayID: 1, rect: r0),
                  DisplayRegion(displayID: 2, rect: r1)],
        referenceMidX: r0.midX
    )
    var strip = Strip(groupArea: ga)
    strip.columns = [Column(tiles: [TileID(1)], width: .proportion(0.5))]
    strip.columnData = [ColumnData(cachedWidth: 500)]
    strip.snapIndices = [0]
    strip.activeColumnIndex = 0
    strip.viewOffset = .static(0)

    let frames = computeTargetFrames(strip: strip, time: 0)
    assertEq(frames.count, 1, "one tile")
    let f = frames[0]
    assertClose(Double(f.frame.width), 500, tolerance: 1.0, "r0 proportion width")
}

section("two-region strip — column scrolled onto region 1 grows")
do {
    let r0 = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let r1 = CGRect(x: 1000, y: 0, width: 2000, height: 800)
    let ga = GroupWorkingArea(
        regions: [DisplayRegion(displayID: 1, rect: r0),
                  DisplayRegion(displayID: 2, rect: r1)],
        referenceMidX: r0.midX
    )
    var strip = Strip(groupArea: ga)
    strip.columns = [Column(tiles: [TileID(1)], width: .proportion(0.5))]
    strip.columnData = [ColumnData(cachedWidth: 500)]
    strip.snapIndices = [0]
    strip.activeColumnIndex = 0
    // Scroll far enough that column center lands in r1 (x≈2000).
    // Starting: column center at (500/2)=250 in strip coords. Need screen center ≈ 2000.
    // screenCenter = cumX + colW/2 - viewPos + minX = 0 + 250 - viewPos + 0 = 250 - viewPos.
    // Want 250 - viewPos ≈ 2000 → viewPos ≈ -1750.
    strip.viewOffset = .static(-1750)

    let frames = computeTargetFrames(strip: strip, time: 0)
    let f = frames[0]
    // Column should render at r1's proportion (0.5 × 2000 = 1000). Allow some slack
    // for A2 iteration convergence.
    check(Double(f.frame.width) > 800, "width grew, got \(f.frame.width)")
}

// MARK: - DisplayManager.alignmentGroups Tests
print("DisplayManager.alignmentGroups Tests")

func makeDisplayInfo(id: CGDirectDisplayID, frame: CGRect) -> DisplayInfo {
    DisplayInfo(
        displayID: id,
        frame: frame,
        visibleFrame: frame,
        isMain: id == 1,
        refreshRate: 60
    )
}

section("solo display — one group of size 1")
do {
    let displays: [CGDirectDisplayID: DisplayInfo] = [
        1: makeDisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
    ]
    let groups = DisplayManager.alignmentGroups(from: displays)
    assertEq(groups.count, 1, "one group")
    assertEq(groups[0], [1], "group contains display 1")
}

section("two flush same-height displays — one group of size 2")
do {
    let displays: [CGDirectDisplayID: DisplayInfo] = [
        1: makeDisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
        2: makeDisplayInfo(id: 2, frame: CGRect(x: 1440, y: 0, width: 2560, height: 900))
    ]
    let groups = DisplayManager.alignmentGroups(from: displays)
    assertEq(groups.count, 1, "one merged group")
    assertEq(groups[0].count, 2, "two members")
    check(groups[0].contains(1) && groups[0].contains(2), "both displays")
}

section("two displays with partial Y-overlap — one group")
do {
    let displays: [CGDirectDisplayID: DisplayInfo] = [
        1: makeDisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
        2: makeDisplayInfo(id: 2, frame: CGRect(x: 1440, y: 200, width: 1920, height: 600))
    ]
    let groups = DisplayManager.alignmentGroups(from: displays)
    assertEq(groups.count, 1, "merge with partial Y-overlap")
}

section("two displays edge-touching (zero Y-overlap) — two groups")
do {
    let displays: [CGDirectDisplayID: DisplayInfo] = [
        1: makeDisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
        2: makeDisplayInfo(id: 2, frame: CGRect(x: 1440, y: 900, width: 1920, height: 600))
    ]
    let groups = DisplayManager.alignmentGroups(from: displays)
    assertEq(groups.count, 2, "edge-touching does not merge")
}

section("vertical stack — two groups")
do {
    let displays: [CGDirectDisplayID: DisplayInfo] = [
        1: makeDisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
        2: makeDisplayInfo(id: 2, frame: CGRect(x: 0, y: 900, width: 1440, height: 900))
    ]
    let groups = DisplayManager.alignmentGroups(from: displays)
    assertEq(groups.count, 2, "vertical stack does not merge")
}

section("three-way chain A-B-C transitive merge")
do {
    let displays: [CGDirectDisplayID: DisplayInfo] = [
        1: makeDisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
        2: makeDisplayInfo(id: 2, frame: CGRect(x: 1000, y: 100, width: 1000, height: 600)),
        3: makeDisplayInfo(id: 3, frame: CGRect(x: 2000, y: 50, width: 1000, height: 500))
    ]
    let groups = DisplayManager.alignmentGroups(from: displays)
    assertEq(groups.count, 1, "A-B-C all merge transitively")
    assertEq(groups[0].count, 3, "three members")
}

section("epsilon tolerance on X-edge (0.3 px gap)")
do {
    let displays: [CGDirectDisplayID: DisplayInfo] = [
        1: makeDisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
        2: makeDisplayInfo(id: 2, frame: CGRect(x: 1440.3, y: 0, width: 1920, height: 900))
    ]
    let groups = DisplayManager.alignmentGroups(from: displays)
    assertEq(groups.count, 1, "0.3 px gap tolerated by ε=0.5")
}

section("X gap beyond epsilon (1 px gap) — no merge")
do {
    let displays: [CGDirectDisplayID: DisplayInfo] = [
        1: makeDisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
        2: makeDisplayInfo(id: 2, frame: CGRect(x: 1441, y: 0, width: 1920, height: 900))
    ]
    let groups = DisplayManager.alignmentGroups(from: displays)
    assertEq(groups.count, 2, "1 px gap exceeds ε=0.5")
}

section("members sorted by frame.minX")
do {
    let displays: [CGDirectDisplayID: DisplayInfo] = [
        2: makeDisplayInfo(id: 2, frame: CGRect(x: 1440, y: 0, width: 1920, height: 900)),
        1: makeDisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
    ]
    let groups = DisplayManager.alignmentGroups(from: displays)
    assertEq(groups.count, 1, "one group")
    assertEq(groups[0][0], UInt32(1), "leftmost first (id 1)")
    assertEq(groups[0][1], UInt32(2), "rightmost second (id 2)")
}

// ============================================================
// MARK: - Per-Display Snap Tests
print("Per-Display Snap Tests")

section("solo group — snap target unchanged (regression)")
do {
    let r = CGRect(x: 0, y: 25, width: 1440, height: 875)
    let ga = GroupWorkingArea(
        regions: [DisplayRegion(displayID: 1, rect: r)],
        referenceMidX: r.midX
    )
    var strip = Strip(snapPoints: [.middle], groupArea: ga)
    strip.columns = [Column(tiles: [TileID(1)], width: .proportion(0.5))]
    strip.columnData = [ColumnData(cachedWidth: 720)]
    strip.snapIndices = [0]
    strip.activeColumnIndex = 0
    let targetOffset = strip.snapTargetForActive(at: 0)
    // Solo middle snap: viewOffset = cumX(0) - regionOffset(0) + localSnap.
    // localSnap for .middle, colWidth=720, waWidth=1440 → -360.
    assertClose(targetOffset, -360, tolerance: 1.0, "solo middle snap offset")
}

section("two-region group — active column on region 1 snaps to r1 midX")
do {
    let r0 = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let r1 = CGRect(x: 1000, y: 0, width: 2000, height: 800)
    let ga = GroupWorkingArea(
        regions: [DisplayRegion(displayID: 1, rect: r0),
                  DisplayRegion(displayID: 2, rect: r1)],
        referenceMidX: r0.midX
    )
    var strip = Strip(snapPoints: [.middle], groupArea: ga)
    strip.columns = [Column(tiles: [TileID(1)], width: .proportion(0.5))]
    strip.columnData = [ColumnData(cachedWidth: 1000)]
    strip.snapIndices = [0]
    strip.activeColumnIndex = 0
    strip.viewOffset = ViewOffset.static(-1500)
    let targetOffset = strip.snapTargetForActive(at: 0)
    // Active column's midX lands at screen x=2000 (inside r1).
    // Snap to r1.midX = 2000. colWidth=1000, waWidth=2000, localSnap=-500.
    // regionOffset = 1000. cumX=0. target = 0 - 1000 + (-500) = -1500.
    assertClose(targetOffset, -1500, tolerance: 5.0, "multi-region: snap to r1 midX")
}

section("two-region group — active column on region 0 snaps to r0 midX")
do {
    let r0 = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let r1 = CGRect(x: 1000, y: 0, width: 2000, height: 800)
    let ga = GroupWorkingArea(
        regions: [DisplayRegion(displayID: 1, rect: r0),
                  DisplayRegion(displayID: 2, rect: r1)],
        referenceMidX: r0.midX
    )
    var strip = Strip(snapPoints: [.middle], groupArea: ga)
    strip.columns = [Column(tiles: [TileID(1)], width: .proportion(0.5))]
    strip.columnData = [ColumnData(cachedWidth: 500)]
    strip.snapIndices = [0]
    strip.activeColumnIndex = 0
    strip.viewOffset = ViewOffset.static(0)
    let targetOffset = strip.snapTargetForActive(at: 0)
    // midX on screen = 250 (inside r0). Snap to r0.midX = 500.
    // colWidth=500, waWidth=1000, localSnap=-250. regionOffset=0. cumX=0.
    // target = 0 - 0 + (-250) = -250.
    assertClose(targetOffset, -250, tolerance: 1.0, "multi-region: snap to r0 midX")
}

// MARK: - Region-Aware Preset & Full-Width Tests
print("Region-Aware Preset & Full-Width Tests")

section("toggleFullWidth on multi-region — sizes to owning region, not totalSpan")
do {
    let r0 = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let r1 = CGRect(x: 1000, y: 0, width: 2000, height: 800)
    let ga = GroupWorkingArea(
        regions: [DisplayRegion(displayID: 1, rect: r0),
                  DisplayRegion(displayID: 2, rect: r1)],
        referenceMidX: r0.midX
    )
    var strip = Strip(snapPoints: [.middle], groupArea: ga)
    strip.columns = [Column(tiles: [TileID(1)], width: .proportion(0.5))]
    strip.columnData = [ColumnData(cachedWidth: 500)]
    strip.snapIndices = [0]
    strip.activeColumnIndex = 0
    strip.viewOffset = ViewOffset.static(0)

    strip.toggleFullWidth(at: 0)
    assertClose(strip.columnData[0].cachedWidth, 1000, tolerance: 1.0, "full-width on r0 = 1000 (not 3000)")
}

section("toggleFullWidth on multi-region — column on r1 → fills r1")
do {
    let r0 = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let r1 = CGRect(x: 1000, y: 0, width: 2000, height: 800)
    let ga = GroupWorkingArea(
        regions: [DisplayRegion(displayID: 1, rect: r0),
                  DisplayRegion(displayID: 2, rect: r1)],
        referenceMidX: r0.midX
    )
    var strip = Strip(snapPoints: [.middle], groupArea: ga)
    strip.columns = [Column(tiles: [TileID(1)], width: .proportion(0.5))]
    strip.columnData = [ColumnData(cachedWidth: 1000)]
    strip.snapIndices = [0]
    strip.activeColumnIndex = 0
    // Scroll so active column's midpoint is in r1.
    strip.viewOffset = ViewOffset.static(-1500)

    strip.toggleFullWidth(at: 0)
    assertClose(strip.columnData[0].cachedWidth, 2000, tolerance: 1.0, "full-width on r1 = 2000")
}

section("cycleWidthPreset uses owning region's width")
do {
    let r0 = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let r1 = CGRect(x: 1000, y: 0, width: 2000, height: 800)
    let ga = GroupWorkingArea(
        regions: [DisplayRegion(displayID: 1, rect: r0),
                  DisplayRegion(displayID: 2, rect: r1)],
        referenceMidX: r0.midX
    )
    var strip = Strip(
        snapPoints: [.middle],
        groupArea: ga,
        widthPresets: [.proportion(0.33), .proportion(0.5), .proportion(0.67)]
    )
    strip.columns = [Column(tiles: [TileID(1)], width: .proportion(0.5), presetIndex: 0)]
    strip.columnData = [ColumnData(cachedWidth: 1000)]
    strip.snapIndices = [0]
    strip.activeColumnIndex = 0
    strip.viewOffset = ViewOffset.static(-1500)  // column on r1

    strip.cycleWidthPreset(at: 0, params: SpringParams?.none)
    // Next preset = 0.5 × r1.width = 1000.
    assertClose(strip.columnData[0].cachedWidth, 1000, tolerance: 1.0, "0.5 × r1.width")

    strip.cycleWidthPreset(at: 0, params: SpringParams?.none)
    // Next preset = 0.67 × r1.width = 1340.
    assertClose(strip.columnData[0].cachedWidth, 1340, tolerance: 2.0, "0.67 × r1.width")
}

section("recalculateWidths — each column uses its own owning region")
do {
    let r0 = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let r1 = CGRect(x: 1000, y: 0, width: 2000, height: 800)
    let ga = GroupWorkingArea(
        regions: [DisplayRegion(displayID: 1, rect: r0),
                  DisplayRegion(displayID: 2, rect: r1)],
        referenceMidX: r0.midX
    )
    var strip = Strip(snapPoints: [.middle], groupArea: ga)
    strip.columns = [
        Column(tiles: [TileID(1)], width: .proportion(0.5)),
        Column(tiles: [TileID(2)], width: .proportion(0.5), isFullWidth: true)
    ]
    strip.columnData = [
        ColumnData(cachedWidth: 500),
        ColumnData(cachedWidth: 2000)
    ]
    strip.snapIndices = [0, 0]
    strip.activeColumnIndex = 1
    strip.viewOffset = ViewOffset.static(-1000)

    strip.recalculateWidths(at: 0)
    assertClose(strip.columnData[0].cachedWidth, 500, tolerance: 1.0, "col 0 → 0.5 × r0.w = 500")
    assertClose(strip.columnData[1].cachedWidth, 2000, tolerance: 1.0, "col 1 full-width on r1 = 2000")
}

// ============================================================
// MARK: - W1 Layer-1 backfill (StripSnapshotStore, topology boundaries, Core gaps)
runL1StoreTests()
runL1TopologyTests()
runL1CoreBackfillTests()
runL1AuditGapTests()
runL1GroupAreaTests()
runL1FocusGateTests()

// ============================================================
// MARK: - W4 Layer-2 StripController simulation (fakes + virtual clock)
runSimFocus()
runSimAnim()
runSimSpace()

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
