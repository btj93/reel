import Core
import Engine
import Foundation
import IPC

/// Maps `reel-msg` commands onto engine commands and read-only views of the world. The socket server runs each
/// request on the main thread, which never waits on an app, so a hung app cannot stall a reply.
@MainActor
public final class IPCBridge {
    private let loop: Loop
    private let server = SocketServer()
    public static let version = "next-r3"

    public init(loop: Loop) {
        self.loop = loop
        server.onCommand = { [weak self] command in
            MainActor.assumeIsolated { self?.handle(command) ?? ReelResponse(success: false, message: "shutting down") }
        }
        server.onFlushed = { [weak self] command in
            guard command == .quit else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.loop.quit() } }
        }
    }

    @discardableResult
    public func start() -> Bool { server.start() }

    public func stop() { server.stop() }

    func handle(_ command: ReelCommand) -> ReelResponse {
        switch command {
        case .focusLeft: return reply(loop.request(.focusLeft))
        case .focusRight: return reply(loop.request(.focusRight))
        case .moveColumnLeft: return reply(loop.request(.moveLeft))
        case .moveColumnRight: return reply(loop.request(.moveRight))
        case .cycleWidthPreset: return reply(loop.request(.cycleWidthPreset))
        case .toggleFullWidth: return onFocused(Command.toggleFullWidth)
        case .toggleFloating: return onFocused(Command.toggleFloating)
        case .closeWindow: return onFocused(Command.close)
        case .recover: return reply(loop.request(.recover))
        case .focusUp, .focusDown: return ReelResponse(success: false, message: "one display until R5")
        case .getLayouts, .listPositions, .clearPositions: return ReelResponse(success: false, message: "saved Spaces arrive with R4")
        case .listWindows: return json(listWindows())
        case .getLayout: return json(Self.layout(world: loop.world, active: loop.group, now: TimeUtil.now()))
        case .getStatus: return json(status())
        case .pause:
            loop.setPaused(true)
            return ReelResponse(success: true, message: "Paused")
        case .resume:
            loop.setPaused(false)
            return ReelResponse(success: true, message: "Resumed")
        case .reloadConfig:
            if let error = loop.reloadConfig() { return ReelResponse(success: false, message: "config error: \(error)") }
            return ReelResponse(success: true, message: "Config reloaded")
        case .quit: return ReelResponse(success: true, message: "Quitting")
        }
    }

    private func onFocused(_ command: (TileID) -> Command) -> ReelResponse {
        guard let tile = loop.focusedTile else { return ReelResponse(success: false, message: "no focused window") }
        return reply(loop.request(command(tile)))
    }

    private func reply(_ outcome: CommandOutcome) -> ReelResponse {
        switch outcome {
        case .accepted: ReelResponse(success: true, message: "OK")
        case .refused(let reason): ReelResponse(success: false, message: reason)
        case .unknownWindow(let tile): ReelResponse(success: false, message: "unknown window \(tile.rawValue)")
        }
    }

    private func json(_ object: Any) -> ReelResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return ReelResponse(success: false, message: "encoding failed") }
        return ReelResponse(success: true, data: text)
    }

    private func status() -> [String: Any] {
        [
            "isPaused": loop.paused,
            "version": Self.version,
            "socketPath": reelSocketPath(),
            "configDir": loop.paths.configDir,
            "stateDir": loop.paths.stateDir,
            "managedPids": loop.allowedPids.map { $0.sorted() as Any } ?? NSNull(),
            "configError": loop.configError as Any? ?? NSNull(),
        ]
    }

    private func listWindows() -> [[String: Any]] {
        let state = loop.world.groups[loop.group]
        return (state?.windows.values.sorted { $0.id.rawValue < $1.id.rawValue } ?? []).map {
            ["id": $0.id.rawValue, "pid": $0.pid, "bundleID": $0.bundleID ?? "", "title": $0.title,
             "floating": state?.floating.contains($0.id) == true]
        }
    }

    /// The shape the smoke harness reads: one active group with its columns, frames in CG coordinates.
    public static func layout(world: World, active: UInt32, now: Double) -> [String: Any] {
        let now = max(now, world.time)
        let groups: [[String: Any]] = world.topology.groups.compactMap { display in
            guard let state = world.groups[display.id] else { return nil }
            let strip = state.strip
            let targets = Dictionary(computeTargetFrames(strip: strip, time: now, raiseHeight: world.config.raiseHeight)
                .map { ($0.tileID, $0) }, uniquingKeysWith: { first, _ in first })
            let columns: [[String: Any]] = strip.columns.enumerated().map { index, column in
                let tile = column.tiles[column.activeTileIndex]
                let window = state.windows[tile]
                var entry: [String: Any] = [
                    "index": index, "tiles": column.tiles.map(\.rawValue), "windowID": tile.rawValue,
                    "bundleID": window?.bundleID ?? "", "title": window?.title ?? "", "width": "\(column.width)",
                    "cachedWidth": strip.columnData[index].cachedWidth,
                    "currentAnimatedWidth": strip.columnData[index].currentWidth(at: now),
                    "isFullWidth": column.isFullWidth, "presetIndex": column.presetIndex as Any? ?? NSNull(),
                    "active": index == strip.activeColumnIndex, "snapIndex": strip.snapIndices[index],
                ]
                if let target = targets[tile] {
                    let frame = axRect(ViewportRect(target.frame), on: display).rect
                    entry["frame"] = ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height]
                    entry["isVisible"] = target.isVisible
                    entry["isOffScreen"] = target.isOffScreen
                }
                return entry
            }
            return [
                "groupID": [display.id], "isActive": display.id == active,
                "regions": [["displayID": display.id, "minX": display.frame.minX, "minY": display.frame.minY,
                             "maxX": display.frame.maxX, "maxY": display.frame.maxY,
                             "width": display.frame.width, "height": display.frame.height]],
                "viewPos": strip.viewPos(at: now), "workingAreaMinX": display.frame.minX, "workingAreaWidth": display.frame.width,
                "gap": strip.gap, "activeColumnIndex": strip.activeColumnIndex,
                "space": state.space?.debugDescription ?? NSNull(), "spaceEpoch": state.epoch,
                "floating": state.floating.map(\.rawValue).sorted(), "currentColumns": columns,
            ]
        }
        return ["activeDisplayID": active, "primaryScreenHeight": world.topology.primaryScreenHeight, "groups": groups]
    }
}
