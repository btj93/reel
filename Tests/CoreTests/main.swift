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
print("━━━ ScrollWM Core Tests ━━━")
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
