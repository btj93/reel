// InputPoster: posts trackpad scrolls with phases and left-button events from a JSON script, for the R6 live lanes.
//
//   InputPoster --dry-run script.json     parse the script and print every event it would post; posts nothing
//   REEL_E2E_CONFIRM=1 InputPoster script.json
//
// A script is a JSON array of steps, in CG coordinates (top-left origin of the primary display):
//   {"scroll": "began|changed|ended|cancelled|momentum|momentumEnded|discrete", "x": 500, "y": 400,
//    "dx": -20, "dy": 0, "modifier": "fn|ctrl|alt|cmd|shift|none", "repeat": 10, "intervalMs": 8}
//   {"mouse": "down|drag|up", "x": 500, "y": 40, "toX": 900, "toY": 40, "modifier": "fn", "repeat": 20, "intervalMs": 8}
//   {"waitMs": 400}
// `dx` and `dy` are the trackpad's point deltas (axis 2 and axis 1). A drag moves from (x, y) to (toX, toY) in `repeat`
// steps. Every step after the first waits `intervalMs` (default 8).

import CoreGraphics
import Foundation

struct Step: Decodable {
    let scroll: String?
    let mouse: String?
    let x: Double?
    let y: Double?
    let toX: Double?
    let toY: Double?
    let dx: Double?
    let dy: Double?
    let modifier: String?
    let `repeat`: Int?
    let intervalMs: Int?
    let waitMs: Int?
}

/// One event to post, then a pause.
struct Planned {
    let line: String
    let delayMs: Int
    let make: () -> CGEvent?
}

enum ScriptError: Error, CustomStringConvertible {
    case invalid(Int, String)
    var description: String { if case .invalid(let index, let reason) = self { "step \(index): \(reason)" } else { "" } }
}

func flags(_ name: String?) throws -> CGEventFlags {
    switch name ?? "none" {
    case "none": []
    case "fn": .maskSecondaryFn
    case "ctrl": .maskControl
    case "alt": .maskAlternate
    case "cmd": .maskCommand
    case "shift": .maskShift
    default: throw ScriptError.invalid(-1, "unknown modifier \(name ?? "")")
    }
}

/// CGEvent scroll phase and momentum phase for each step name.
let scrollPhases: [String: (phase: Int64, momentum: Int64, continuous: Bool)] = [
    "began": (1, 0, true), "changed": (2, 0, true), "ended": (4, 0, true), "cancelled": (8, 0, true),
    "momentum": (0, 2, true), "momentumEnded": (0, 3, true), "discrete": (0, 0, false),
]

func plan(_ steps: [Step]) throws -> [Planned] {
    var planned: [Planned] = []
    for (index, step) in steps.enumerated() {
        let count = max(1, step.repeat ?? 1)
        let interval = max(0, step.intervalMs ?? 8)
        let modifier: CGEventFlags
        do { modifier = try flags(step.modifier) } catch { throw ScriptError.invalid(index, "unknown modifier \(step.modifier ?? "")") }
        if let wait = step.waitMs {
            planned.append(Planned(line: "wait \(wait)ms", delayMs: wait, make: { nil }))
            continue
        }
        guard let x = step.x, let y = step.y else { throw ScriptError.invalid(index, "needs x and y") }
        if let name = step.scroll {
            guard let phases = scrollPhases[name] else { throw ScriptError.invalid(index, "unknown scroll phase \(name)") }
            let dx = step.dx ?? 0, dy = step.dy ?? 0
            for _ in 0..<count {
                planned.append(Planned(line: "scroll \(name) dx=\(dx) dy=\(dy) at=\(x),\(y) modifier=\(step.modifier ?? "none")",
                                       delayMs: interval, make: {
                    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy.rounded()),
                                              wheel2: Int32(dx.rounded()), wheel3: 0) else { return nil }
                    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: phases.continuous ? 1 : 0)
                    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phases.phase)
                    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: phases.momentum)
                    event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
                    event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
                    event.location = CGPoint(x: x, y: y)
                    event.flags = modifier
                    return event
                }))
            }
        } else if let name = step.mouse {
            let type: CGEventType
            switch name {
            case "down": type = .leftMouseDown
            case "drag": type = .leftMouseDragged
            case "up": type = .leftMouseUp
            default: throw ScriptError.invalid(index, "unknown mouse event \(name)")
            }
            let toX = step.toX ?? x, toY = step.toY ?? y
            let points = type == .leftMouseDragged
                ? (1...count).map { CGPoint(x: x + (toX - x) * Double($0) / Double(count), y: y + (toY - y) * Double($0) / Double(count)) }
                : [CGPoint(x: x, y: y)]
            for point in points {
                planned.append(Planned(line: "mouse \(name) at=\(Int(point.x)),\(Int(point.y)) modifier=\(step.modifier ?? "none")",
                                       delayMs: interval, make: {
                    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
                    event?.flags = modifier
                    return event
                }))
            }
        } else {
            throw ScriptError.invalid(index, "needs scroll, mouse or waitMs")
        }
    }
    return planned
}

let arguments = Array(CommandLine.arguments.dropFirst())
let dryRun = arguments.contains("--dry-run")
guard let path = arguments.first(where: { $0 != "--dry-run" }) else {
    FileHandle.standardError.write(Data("usage: InputPoster [--dry-run] <script.json | ->\n".utf8))
    exit(64)
}
let data = path == "-" ? FileHandle.standardInput.readDataToEndOfFile() : FileManager.default.contents(atPath: path)
let planned: [Planned]
do {
    guard let data else { throw ScriptError.invalid(-1, "cannot read \(path)") }
    planned = try plan(JSONDecoder().decode([Step].self, from: data))
} catch {
    FileHandle.standardError.write(Data("InputPoster: invalid script \(path): \(error)\n".utf8))
    exit(1)
}

if dryRun {
    for event in planned { print(event.line) }
    print("InputPoster: dry run, \(planned.count) events, nothing posted")
    exit(0)
}
guard ProcessInfo.processInfo.environment["REEL_E2E_CONFIRM"] == "1" else {
    FileHandle.standardError.write(Data("InputPoster: refusing to post input without REEL_E2E_CONFIRM=1 (lane hosts only)\n".utf8))
    exit(2)
}
for event in planned {
    event.make()?.post(tap: .cghidEventTap)
    if event.delayMs > 0 { usleep(useconds_t(event.delayMs * 1000)) }
}
print("InputPoster: posted \(planned.count) events")
