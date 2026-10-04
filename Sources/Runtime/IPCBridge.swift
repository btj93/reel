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
    public static let version = "r7"

    public init(loop: Loop) {
        self.loop = loop
        server.onAsyncMessage = { [weak self] message, completion in
            MainActor.assumeIsolated {
                guard let self else { return completion(ReelResponse(success: false, message: "shutting down")) }
                if message.command == ReelCommand.getLayouts.rawValue { self.readLayouts(completion: completion) }
                else { completion(self.handle(message)) }
            }
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

    func handle(_ message: IPCMessage) -> ReelResponse {
        guard let command = ReelCommand(rawValue: message.command) else {
            return ReelResponse(success: false, message: "Unknown command")
        }
        if command == .clearPositionsApp {
            guard let bundleID = message.appID, !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ReelResponse(success: false, message: "clear-positions-app needs a bundle id")
            }
            let outcome = loop.request(.clearPositionsApp(bundleID))
            guard outcome == .accepted else { return reply(outcome) }
            loop.store.clear(bundleID: bundleID)
            return ReelResponse(success: true, message: "Cleared saved positions for \(bundleID)")
        }
        return handle(command)
    }

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
        case .listPositions: return json(Self.positions(loop.store.list()))
        case .clearPositions:
            let outcome = loop.request(.clearPositions)
            guard outcome == .accepted else { return reply(outcome) }
            loop.store.clear()
            return ReelResponse(success: true, message: "Cleared all saved positions")
        case .clearPositionsApp: return ReelResponse(success: false, message: "clear-positions-app needs a bundle id")
        case .getLayouts: return ReelResponse(success: false, message: "get-layouts requires an asynchronous read")
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

    /// Every known Space, with expected placement beside a bounded, fresh AX read. Missing reads are unreadable.
    public static func layouts(world: World, active: UInt32, frames: [UInt32: CGRect], onScreenIDs: Set<UInt32>) -> [String: Any] {
        func entries(_ saved: Snapshot) -> [[String: Any]] {
            let area = world.topology.group(id: saved.group)?.frame
            let displayGroup = world.topology.group(id: saved.group)
            let expected: [TileID: CGRect] = displayGroup.map { group in
                var strip = Strip(gap: world.config.gap, workingArea: CGRect(origin: .zero, size: group.frame.size))
                strip.groupArea = GroupWorkingArea(regions: group.displays.map { DisplayRegion(displayID: $0.id, rect: $0.area.offsetBy(dx: -group.frame.minX, dy: -group.frame.minY)) },
                                                   referenceMidX: group.displays[0].area.midX - group.frame.minX)
                strip.columns = saved.columns.map { column in
                    Column(tiles: column.windows.map(\.id), activeTileIndex: column.activeTileIndex, width: column.width,
                           presetIndex: column.presetIndex, isFullWidth: column.isFullWidth)
                }
                strip.activeColumnIndex = min(saved.activeColumnIndex, max(0, strip.columns.count - 1))
                strip.viewOffset = .static(saved.offset)
                strip.defaultWidth = .proportion(world.config.defaultWidth)
                strip.columnData = strip.columns.map { _ in ColumnData(cachedWidth: 1) }
                strip.snapIndices = saved.columns.map(\.snapIndex)
                strip.recalculateWidths(at: world.time)
                for index in strip.columnData.indices where index != strip.activeColumnIndex {
                    strip.columnData[index].cachedRaiseTarget = world.config.raiseHeight
                }
                return Dictionary(uniqueKeysWithValues: computeTargetFrames(strip: strip, time: world.time).map { ($0.tileID, $0.frame.offsetBy(dx: group.frame.minX, dy: group.frame.minY)) })
            } ?? [:]
            let columns = saved.columns.flatMap { column in column.windows.map { ($0, Optional(column)) } }
            return (columns + saved.floating.map { ($0, nil) } + saved.hidden.map { ($0.window, nil) }).map { window, column in
                let now = frames[window.id.rawValue].map { frame in
                    (frame: frame, onScreen: onScreenIDs.contains(window.id.rawValue))
                }
                let desired = world.groups[saved.group]?.space == saved.space
                    ? world.frames[window.id]?.frame.rect ?? expected[window.id] : expected[window.id]
                var entry: [String: Any] = [
                    "windowID": window.id.rawValue, "bundleID": window.bundleID ?? "", "title": window.title,
                    "savedWidth": column.map { "\($0.width)" } ?? "floating", "isFullWidth": column?.isFullWidth ?? false,
                    "isOnScreen": now?.onScreen ?? false, "currentFrame": NSNull(), "slivered": false,
                    "unreadable": now == nil, "expectedFrame": desired.map(Self.frameJSON) ?? NSNull(),
                    "expectedPlacement": column == nil ? "outside-strip" : expected[window.id] == nil ? "unavailable-display" : "tiled",
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

    private func readLayouts(completion: @escaping @Sendable (ReelResponse) -> Void) {
        let world = loop.world
        let active = loop.group
        let snapshots = world.groups.keys.compactMap(world.currentSnapshot)
            + Array(world.spaces.live.values) + world.spaces.disk
        let windows = snapshots.flatMap { $0.columns.flatMap(\.windows) + $0.floating + $0.hidden.map(\.window) }
        let unique = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let onScreenIDs = Set(windowInfo(onScreenOnly: true).map(\.windowID))
        let probe = FrameProbe(ids: Set(unique.keys)) { frames in
            completion(self.json(Self.layouts(world: world, active: active, frames: frames, onScreenIDs: onScreenIDs)))
        }
        for window in unique.values {
            guard let worker = loop.observer.workers[window.pid] else {
                probe.receive(window.id, frame: nil)
                continue
            }
            worker.run(window.id) { ax in
                let frame: CGRect?
                if case .success(let point) = ax.getPosition(), case .success(let size) = ax.getSize() {
                    frame = CGRect(origin: point, size: size)
                } else { frame = nil }
                DispatchQueue.main.async { MainActor.assumeIsolated { probe.receive(window.id, frame: frame) } }
            }
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

    private static func frameJSON(_ frame: CGRect) -> [String: Double] {
        ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height]
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
            "stageManager": "unsupported",
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
