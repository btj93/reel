// TestWindowHost — a bare NSApplication that hosts ordinary NSWindows for E2E smoke tests.
//
// This tool needs NO Accessibility permission: it manages only its OWN windows (creating,
// moving, resizing, closing, titling them) and never touches other processes' windows. The
// live Reel window manager can adopt the windows this host creates and drive them; the host
// merely observes and reports their state so smoke assertions can compare Reel's model against
// on-screen reality.
//
// Protocol: line-delimited JSON on stdin (one command object per line) → line-delimited JSON
// on stdout (one response object per line). See parseCommand / HostResponse below for the
// exact shape. Diagnostics go to stderr so stdout stays a clean request/response stream.
//
// Threading: NSApplication + all NSWindow access is confined to the main thread. A single
// background reader thread does blocking readLine() on stdin (no busy-wait) and hops every
// parsed line onto the main queue (FIFO, so response order is preserved). SIGTERM is handled
// via a main-queue DispatchSource so teardown runs on the main thread.

import AppKit
import Foundation

// MARK: - Protocol types (pure, testable — no AppKit)

/// A rectangle as it crosses the wire. For `setFrame` inputs these are CG top-left coords;
/// for `report` outputs these are the window's CG top-left frame.
struct FrameJSON: Codable, Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

/// Outcome of parsing one input line: a validated command, or a human-readable error message.
/// (A bespoke enum rather than `Result` because the failure payload is a plain String, which
/// does not conform to `Error`.)
enum ParseResult {
    case success(HostCommand)
    case failure(String)
}

/// A fully-parsed, validated command.
enum HostCommand: Equatable {
    case create(count: Int, width: Double, height: Double, title: String?)
    case close(id: Int)
    case focus(id: Int)
    case setFrame(id: Int, frame: FrameJSON)
    case setTitle(id: Int, title: String)
    case report
    case quit
}

/// Per-window state returned by `report`.
struct WindowReport: Encodable, Equatable {
    let id: Int
    /// NSWindow.windowNumber — the CGWindowID the real window manager sees.
    let cgWindowID: Int
    /// Window frame in CG (top-left origin) coordinates.
    let frameCG: FrameJSON
    /// Number of didMove/didResize notifications observed for this window since creation.
    /// This is the echo-suppression oracle: after Reel's setFrame settles, a well-behaved
    /// manager should stop bumping this count.
    let frameChangeCount: Int
    /// Whether this window is currently the key window.
    let isKey: Bool
}

/// Every response is one of these; nil fields are omitted from the JSON (synthesized
/// encodeIfPresent), so a `report` line carries only `ok` + `windows`, an error line only
/// `ok` + `error`, etc.
struct HostResponse: Encodable {
    var ok: Bool
    var id: Int? = nil
    var ids: [Int]? = nil
    var error: String? = nil
    var windows: [WindowReport]? = nil
}

/// The raw decoded request. Unknown keys are ignored; presence/typing is validated in
/// parseCommand so malformed input yields a clean error response rather than a decode throw.
private struct RawRequest: Decodable {
    let cmd: String
    let id: Int?
    let count: Int?
    let single: Bool?
    let width: Double?
    let height: Double?
    let title: String?
    let x: Double?
    let y: Double?
    let w: Double?
    let h: Double?
}

/// Pure: decode + validate one JSON line into a HostCommand, or a human-readable error.
///
/// Example request/response lines:
///   {"cmd":"create","count":2,"width":800,"height":600,"title":"editor"}
///        → {"ids":[1,2],"ok":true}
///   {"cmd":"create","single":true}
///        → {"ids":[3],"ok":true}
///   {"cmd":"close","id":2}
///        → {"id":2,"ok":true}                         (or {"error":"...","id":2,"ok":false})
///   {"cmd":"focus","id":1}
///        → {"id":1,"ok":true}
///   {"cmd":"setFrame","id":1,"x":100,"y":50,"w":800,"h":600}
///        → {"id":1,"ok":true}                         (x/y/w/h are CG top-left coords)
///   {"cmd":"setTitle","id":1,"title":"renamed"}
///        → {"id":1,"ok":true}
///   {"cmd":"report"}
///        → {"ok":true,"windows":[{"cgWindowID":1234,"frameCG":{"h":600,"w":800,"x":100,"y":50},
///                                 "frameChangeCount":2,"id":1,"isKey":true}]}
///   {"cmd":"quit"}
///        → {"ok":true}                                (process then exits 0)
///   <malformed line>
///        → {"error":"invalid JSON: ...","ok":false}
func parseCommand(_ data: Data) -> ParseResult {
    let req: RawRequest
    do {
        req = try JSONDecoder().decode(RawRequest.self, from: data)
    } catch {
        return .failure("invalid JSON: \(error)")
    }

    switch req.cmd {
    case "create":
        // `single: true` forces a single window; otherwise `count` (default 1), clamped to >= 1.
        let count = (req.single == true) ? 1 : max(1, req.count ?? 1)
        return .success(.create(count: count,
                                width: req.width ?? 800,
                                height: req.height ?? 600,
                                title: req.title))
    case "close":
        guard let id = req.id else { return .failure("close requires \"id\"") }
        return .success(.close(id: id))
    case "focus":
        guard let id = req.id else { return .failure("focus requires \"id\"") }
        return .success(.focus(id: id))
    case "setFrame":
        guard let id = req.id, let x = req.x, let y = req.y, let w = req.w, let h = req.h else {
            return .failure("setFrame requires \"id\",\"x\",\"y\",\"w\",\"h\"")
        }
        return .success(.setFrame(id: id, frame: FrameJSON(x: x, y: y, w: w, h: h)))
    case "setTitle":
        guard let id = req.id else { return .failure("setTitle requires \"id\"") }
        guard let title = req.title else { return .failure("setTitle requires \"title\"") }
        return .success(.setTitle(id: id, title: title))
    case "report":
        return .success(.report)
    case "quit":
        return .success(.quit)
    default:
        return .failure("unknown command: \(req.cmd)")
    }
}

/// Pure: encode a response to a single-line JSON Data (sorted keys → deterministic output).
func encodeResponse(_ resp: HostResponse) -> Data {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    return (try? enc.encode(resp)) ?? Data(#"{"error":"encode failed","ok":false}"#.utf8)
}

// MARK: - Coordinate conversion (pure)
//
// AppKit frames use a bottom-left origin anchored at the primary screen's bottom-left and
// spanning all screens. CG frames (what AX/CGWindow report, what `setFrame` accepts here) use
// a top-left origin. The conversion mirrors DisplayInfo.workingArea in Platform:
//   CG_y_top = primaryScreenHeight - AppKit_maxY
// x/width/height are identical in both systems.

/// AppKit (bottom-left) → CG (top-left).
func appKitToCG(_ frame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
    CGRect(x: frame.minX,
           y: primaryScreenHeight - frame.maxY,
           width: frame.width,
           height: frame.height)
}

/// CG (top-left) → AppKit (bottom-left). Exact inverse of appKitToCG.
func cgToAppKit(_ frame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
    CGRect(x: frame.minX,
           y: primaryScreenHeight - frame.minY - frame.height,
           width: frame.width,
           height: frame.height)
}

// MARK: - Window host (main-thread only)

/// Owns the NSWindows this process created and answers commands about them. Every method here
/// must be called on the main thread (NSWindow is not thread-safe).
final class WindowHost {
    private var windows: [Int: NSWindow] = [:]
    private var frameChangeCounts: [Int: Int] = [:]
    private var observers: [Int: [NSObjectProtocol]] = [:]
    private var nextID = 1

    private let primaryScreenHeight: CGFloat
    private let titlePrefix: String

    init(primaryScreenHeight: CGFloat, titlePrefix: String) {
        self.primaryScreenHeight = primaryScreenHeight
        self.titlePrefix = titlePrefix
    }

    /// Titles embed the launch prefix + the window id so a run's windows are uniquely
    /// identifiable on screen and a leaked window from a crashed run can never masquerade
    /// as a fresh one.
    private func formattedTitle(base: String, id: Int) -> String {
        "\(titlePrefix) \(base) #\(id)"
    }

    func handle(_ command: HostCommand) -> HostResponse {
        switch command {
        case let .create(count, width, height, title):
            let ids = (0..<count).map { _ in
                makeWindow(width: CGFloat(width), height: CGFloat(height), title: title)
            }
            return HostResponse(ok: true, ids: ids)
        case let .close(id):
            return closeWindow(id: id)
                ? HostResponse(ok: true, id: id)
                : HostResponse(ok: false, id: id, error: "no window with id \(id)")
        case let .focus(id):
            return focusWindow(id: id)
                ? HostResponse(ok: true, id: id)
                : HostResponse(ok: false, id: id, error: "no window with id \(id)")
        case let .setFrame(id, frame):
            return applyFrame(id: id, frame: frame)
                ? HostResponse(ok: true, id: id)
                : HostResponse(ok: false, id: id, error: "no window with id \(id)")
        case let .setTitle(id, title):
            return applyTitle(id: id, title: title)
                ? HostResponse(ok: true, id: id)
                : HostResponse(ok: false, id: id, error: "no window with id \(id)")
        case .report:
            return HostResponse(ok: true, windows: report())
        case .quit:
            return HostResponse(ok: true)
        }
    }

    @discardableResult
    private func makeWindow(width: CGFloat, height: CGFloat, title: String?) -> Int {
        let id = nextID
        nextID += 1

        // Cascade a little so multiple startup windows aren't perfectly stacked. Position is
        // arbitrary — the window manager under test relocates them immediately.
        let offset = CGFloat(id % 12) * 28
        let rect = NSRect(x: 120 + offset, y: 120 + offset, width: width, height: height)
        let window = NSWindow(contentRect: rect,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        // We manage lifetime via the `windows` dictionary; don't let close() dealloc it.
        window.isReleasedWhenClosed = false
        window.title = formattedTitle(base: title ?? "window", id: id)
        window.makeKeyAndOrderFront(nil)

        windows[id] = window
        frameChangeCounts[id] = 0

        // Count every move/resize — including our own setFrame echoes AND the manager's moves.
        // queue: nil → the block runs synchronously on the (main) thread that posts the
        // notification, so the count is up to date by the time the next `report` is handled.
        let move = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: nil
        ) { [weak self] _ in
            self?.frameChangeCounts[id, default: 0] += 1
        }
        let resize = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: nil
        ) { [weak self] _ in
            self?.frameChangeCounts[id, default: 0] += 1
        }
        observers[id] = [move, resize]
        return id
    }

    private func closeWindow(id: Int) -> Bool {
        guard let window = windows[id] else { return false }
        observers[id]?.forEach { NotificationCenter.default.removeObserver($0) }
        observers[id] = nil
        window.orderOut(nil)
        window.close()
        windows[id] = nil
        frameChangeCounts[id] = nil
        return true
    }

    private func focusWindow(id: Int) -> Bool {
        guard let window = windows[id] else { return false }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// Frame arrives in CG (top-left) coords; convert to AppKit before applying.
    private func applyFrame(id: Int, frame: FrameJSON) -> Bool {
        guard let window = windows[id] else { return false }
        let cg = CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h)
        window.setFrame(cgToAppKit(cg, primaryScreenHeight: primaryScreenHeight), display: true)
        return true
    }

    private func applyTitle(id: Int, title: String) -> Bool {
        guard let window = windows[id] else { return false }
        window.title = formattedTitle(base: title, id: id)
        return true
    }

    private func report() -> [WindowReport] {
        windows.keys.sorted().compactMap { id in
            guard let window = windows[id] else { return nil }
            let cg = appKitToCG(window.frame, primaryScreenHeight: primaryScreenHeight)
            return WindowReport(
                id: id,
                cgWindowID: window.windowNumber,
                frameCG: FrameJSON(x: cg.minX, y: cg.minY, w: cg.width, h: cg.height),
                frameChangeCount: frameChangeCounts[id] ?? 0,
                isKey: window.isKeyWindow
            )
        }
    }

    /// Close every window and exit cleanly. Called on SIGTERM, on `quit`, and on stdin EOF.
    func terminate() -> Never {
        for id in Array(windows.keys) {
            _ = closeWindow(id: id)
        }
        exit(0)
    }
}

// MARK: - I/O helpers

private let stdoutHandle = FileHandle.standardOutput

func writeResponse(_ resp: HostResponse) {
    var data = encodeResponse(resp)
    data.append(0x0A) // '\n' — line-delimited output
    stdoutHandle.write(data)
}

private func logDiagnostic(_ message: String) {
    FileHandle.standardError.write(Data("TestWindowHost: \(message)\n".utf8))
}

/// Process one input line on the main thread: parse, act, respond, and exit on `quit`.
func processLine(_ line: String, host: WindowHost) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return } // ignore blank lines
    switch parseCommand(Data(trimmed.utf8)) {
    case let .failure(message):
        writeResponse(HostResponse(ok: false, error: message))
    case let .success(command):
        writeResponse(host.handle(command))
        if case .quit = command { host.terminate() }
    }
}

// MARK: - Entry point

// Launch flags:
//   --primary-height <points>   Explicit primary-screen height for AppKit↔CG conversion.
//   --title-prefix <string>     Prefix embedded in every window title (default "TestWindowHost").
//   --windows <N>               Create N windows at startup (used by the smoke harness).
//   --width <points>            Startup-window content width  (default 800).
//   --height <points>           Startup-window content height (default 600).
let arguments = CommandLine.arguments
var primaryHeightArg: CGFloat? = nil
var titlePrefix = "TestWindowHost"
var startupWindows = 0
var startupWidth: CGFloat = 800
var startupHeight: CGFloat = 600

var argIndex = 1
while argIndex < arguments.count {
    let arg = arguments[argIndex]
    func nextValue() -> String? {
        guard argIndex + 1 < arguments.count else { return nil }
        argIndex += 1
        return arguments[argIndex]
    }
    switch arg {
    case "--primary-height":
        if let v = nextValue(), let d = Double(v) { primaryHeightArg = CGFloat(d) }
    case "--title-prefix":
        if let v = nextValue() { titlePrefix = v }
    case "--windows":
        if let v = nextValue(), let n = Int(v) { startupWindows = max(0, n) }
    case "--width":
        if let v = nextValue(), let d = Double(v) { startupWidth = CGFloat(d) }
    case "--height":
        if let v = nextValue(), let d = Double(v) { startupHeight = CGFloat(d) }
    default:
        logDiagnostic("ignoring unknown argument \(arg)")
    }
    argIndex += 1
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// Primary-screen height for AppKit↔CG conversion. Prefer the explicit --primary-height flag
// (which callers derive from Reel's get-layout `primaryScreenHeight`, guaranteeing both sides
// agree); otherwise infer from NSScreen.screens.first — index 0 is the screen carrying the menu
// bar (the primary), whose AppKit frame is anchored at (0,0), so frame.maxY == its full height.
let primaryScreenHeight: CGFloat = primaryHeightArg ?? (NSScreen.screens.first?.frame.maxY ?? 0)
if primaryHeightArg != nil {
    logDiagnostic("primaryScreenHeight=\(primaryScreenHeight) (from --primary-height)")
} else {
    logDiagnostic("primaryScreenHeight=\(primaryScreenHeight) (inferred from NSScreen.screens.first.frame.maxY)")
}

let host = WindowHost(primaryScreenHeight: primaryScreenHeight, titlePrefix: titlePrefix)

if startupWindows > 0 {
    let resp = host.handle(.create(count: startupWindows,
                                   width: Double(startupWidth),
                                   height: Double(startupHeight),
                                   title: nil))
    logDiagnostic("created \(startupWindows) startup window(s): ids=\(resp.ids ?? [])")
    NSApp.activate(ignoringOtherApps: true)
}

// SIGTERM (and SIGINT for interactive convenience): ignore the default disposition and handle
// on the main queue so window teardown runs on the main thread.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler {
    logDiagnostic("received SIGTERM — closing windows, exiting 0")
    host.terminate()
}
sigtermSource.resume()
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    logDiagnostic("received SIGINT — closing windows, exiting 0")
    host.terminate()
}
sigintSource.resume()

// Blocking stdin reader on a background thread (no busy-wait). Each line is parsed and hopped
// to the main queue in order; stdin EOF triggers a clean shutdown.
let readerThread = Thread {
    while let line = readLine(strippingNewline: true) {
        DispatchQueue.main.async { processLine(line, host: host) }
    }
    DispatchQueue.main.async {
        logDiagnostic("stdin closed (EOF) — exiting 0")
        host.terminate()
    }
}
readerThread.stackSize = 1 << 20
readerThread.start()

app.run()
