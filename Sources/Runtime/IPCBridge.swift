import AppKit
import Core
import Engine
import Foundation
import IPC
import Platform

/// Maps `reel-msg` commands onto engine commands and read-only views of the world. The socket server runs each
/// request on the main thread, which never waits on an app, so a hung app cannot stall a reply.
@MainActor
public final class IPCBridge {
    private let loop: Loop
    private let server = SocketServer()
    public static let version = "next-r5"

    public init(loop: Loop) {
        self.loop = loop
        server.onCommand = { [weak self] command in
            MainActor.assumeIsolated { self?.handle(command) ?? ReelResponse(success: false, message: "shutting down") }
        }
        // Through AppKit, so the delegate stops this server and releases windows before the app exits.
        server.onFlushed = { command in
            guard command == .quit else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { NSApp.terminate(nil) } }
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
        case .recover: return reply(loop.recover())
        case .focusUp: return reply(loop.request(.focusUp))
        case .focusDown: return reply(loop.request(.focusDown))
        case .listPositions: return json(Self.positions(loop.world.spaces.persisted))
        case .clearPositions:
            let outcome = loop.request(.clearPositions)
            guard outcome == .accepted else { return reply(outcome) }
            loop.store.flush()
            return ReelResponse(success: true, message: "Cleared all saved positions")
        case .getLayouts: return json(Self.layouts(world: loop.world, active: loop.group, windows: windowServerFrames()))
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

    /// One entry per saved window, in the order the book keeps its strips.
    public static func positions(_ snapshots: [Snapshot]) -> [[String: Any]] {
        snapshots.flatMap { saved in
            let slots: [(ObservedWindow, String, Bool)] = saved.columns.flatMap { column in column.windows.map { ($0, "\(column.width)", false) } }
                + saved.floating.map { ($0, "floating", false) } + saved.hidden.map { ($0.window, $0.width.map { "\($0)" } ?? "floating", true) }
            return slots.enumerated().map { index, slot in
                ["groupID": saved.group, "space": saved.space.debugDescription, "slotIndex": index, "windowID": slot.0.id.rawValue,
                 "bundleID": slot.0.bundleID ?? "", "windowTitle": slot.0.title, "width": slot.1, "hidden": slot.2]
            }
        }
    }

    /// Every Space the engine knows, the current one first, with where each window is now. Frames come from the
    /// window server, not AX, so a hung app cannot stall the reply. A window less than 10 points on its display is
    /// `slivered`: parked off screen, or stuck there.
    public static func layouts(world: World, active: UInt32, windows: [UInt32: (frame: CGRect, onScreen: Bool)]) -> [String: Any] {
        func entries(_ saved: Snapshot) -> [[String: Any]] {
            let area = world.topology.group(id: saved.group)?.frame
            let columns = saved.columns.flatMap { column in column.windows.map { ($0, Optional(column)) } }
            return (columns + saved.floating.map { ($0, nil) }).map { window, column in
                let now = windows[window.id.rawValue]
                var entry: [String: Any] = [
                    "windowID": window.id.rawValue, "bundleID": window.bundleID ?? "", "title": window.title,
                    "savedWidth": column.map { "\($0.width)" } ?? "floating", "isFullWidth": column?.isFullWidth ?? false,
                    "isOnScreen": now?.onScreen ?? false, "currentFrame": NSNull(), "slivered": false,
                ]
                if let frame = now?.frame {
                    entry["currentFrame"] = ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height]
                    entry["slivered"] = area.map { frame.intersection($0).width < 10 } ?? false
                }
                return entry
            }
        }
        var spaces: [[String: Any]] = []
        var current = Set<GroupSpace>()
        for id in world.groups.keys.sorted() {
            guard let saved = world.currentSnapshot(group: id) else { continue }
            current.insert(GroupSpace(group: id, space: saved.space))
            spaces.append(["groupID": id, "isActiveGroup": id == active, "isCurrentSpace": true, "source": "live",
                           "spaceKey": saved.space.debugDescription, "windows": entries(saved)])
        }
        let session = world.spaces.live.filter { !current.contains($0.key) }.map(\.value)
        for (source, saved) in session.map({ ("session", $0) }) + world.spaces.disk.map({ ("disk", $0) }) {
            spaces.append(["groupID": saved.group, "isActiveGroup": false, "isCurrentSpace": false, "source": source,
                           "spaceKey": saved.space.debugDescription, "windows": entries(saved)])
        }
        return ["activeDisplayID": active, "primaryScreenHeight": world.topology.primaryScreenHeight, "spaces": spaces]
    }

    /// Where the window server has every window now, on any Space.
    private func windowServerFrames() -> [UInt32: (frame: CGRect, onScreen: Bool)] {
        Dictionary(windowInfo(onScreenOnly: false).map { ($0.windowID, (frame: $0.bounds, onScreen: $0.isOnScreen)) },
                   uniquingKeysWith: { first, _ in first })
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
            "stageManager": UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") == true ? "unsupported" : "off",
        ]
    }

    private func listWindows() -> [[String: Any]] {
        loop.world.groups.keys.sorted().flatMap { id in
            let state = loop.world.groups[id]!
            return state.windows.values.sorted { $0.id.rawValue < $1.id.rawValue }.map {
                ["id": $0.id.rawValue, "pid": $0.pid, "bundleID": $0.bundleID ?? "", "title": $0.title,
                 "floating": state.floating.contains($0.id), "groupID": id]
            }
        }
    }

    /// The shape the smoke harness reads: every group with its displays and columns, frames in CG coordinates.
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
                "groupID": display.displays.map(\.id), "isActive": display.id == active,
                "regions": display.displays.map { member in
                    ["displayID": member.id, "minX": member.area.minX, "minY": member.area.minY, "maxX": member.area.maxX,
                     "maxY": member.area.maxY, "width": member.area.width, "height": member.area.height]
                },
                "viewPos": strip.viewPos(at: now), "workingAreaMinX": display.frame.minX, "workingAreaWidth": display.frame.width,
                "gap": strip.gap, "activeColumnIndex": strip.activeColumnIndex,
                "space": state.space?.debugDescription ?? NSNull(), "spaceEpoch": state.epoch,
                "floating": state.floating.map(\.rawValue).sorted(), "currentColumns": columns,
            ]
        }
        return ["activeDisplayID": active, "primaryScreenHeight": world.topology.primaryScreenHeight, "groups": groups]
    }
}
