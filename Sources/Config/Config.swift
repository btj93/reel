import Foundation
import TOMLKit
import Core

/// ScrollWM configuration, loaded from ~/.config/scrollwm/config.toml.
public struct ScrollWMConfig: Sendable {

    // MARK: - Layout

    public var gap: Double = 16
    public var defaultWidth: ColumnWidth = .proportion(0.5)
    public var widthPresets: [ColumnWidth] = [.proportion(0.33), .proportion(0.5), .proportion(0.67)]
    public var focusMode: CenterFocusedColumn = .always
    public var struts: StrutsConfig = StrutsConfig()
    public var animationEnabled: Bool = true

    // MARK: - Animation

    public var scrollStiffness: Double = 800
    public var scrollDampingRatio: Double = 1.0
    public var bounceDistance: Double = 40
    public var bounceDampingRatio: Double = 0.6

    // MARK: - Keybindings (action → key string like "hyper-h")

    public var keybindings: [String: String] = [
        "focus_left": "hyper-h",
        "focus_right": "hyper-l",
        "move_left": "hyper-j",
        "move_right": "hyper-k",
        "cycle_width": "hyper-r",
        "toggle_full_width": "hyper-f",
        "toggle_floating": "hyper-space",
        "close_window": "hyper-w",
        "spawn_terminal": "hyper-t",
    ]

    // MARK: - Gesture

    public var gestureModifier: String = "fn"

    // MARK: - Window Rules

    public var rules: [WindowRuleConfig] = []

    // MARK: - Terminal

    public var terminalApp: String = "/System/Applications/Utilities/Terminal.app"

    // MARK: - Startup

    public var startAtLogin: Bool = false

    // MARK: - Config Path

    public static let configDir = NSHomeDirectory() + "/.config/scrollwm"
    public static let configPath = configDir + "/config.toml"
}

/// Window rule from config.
public struct WindowRuleConfig: Sendable {
    public var appID: String?
    public var appIDRegex: String?
    public var titleRegex: String?
    public var floating: Bool = false

    public init(appID: String? = nil, appIDRegex: String? = nil, titleRegex: String? = nil, floating: Bool = false) {
        self.appID = appID
        self.appIDRegex = appIDRegex
        self.titleRegex = titleRegex
        self.floating = floating
    }
}

/// Struts (insets for external bars).
public struct StrutsConfig: Sendable {
    public var left: Double = 0
    public var right: Double = 0
    public var top: Double = 0
    public var bottom: Double = 0

    public init(left: Double = 0, right: Double = 0, top: Double = 0, bottom: Double = 0) {
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
    }
}

// MARK: - Loading

extension ScrollWMConfig {

    /// Load config from file, or return defaults if file doesn't exist or is invalid.
    public static func load() -> (config: ScrollWMConfig, error: String?) {
        let path = configPath

        // Create default config if doesn't exist
        if !FileManager.default.fileExists(atPath: path) {
            createDefaultConfig()
            return (ScrollWMConfig(), nil)
        }

        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            let table = try TOMLTable(string: content)
            let config = parse(table: table)
            return (config, nil)
        } catch {
            return (ScrollWMConfig(), "Config error: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers for reading TOML values

    /// Read a number from a TOML value (handles both Int and Double in TOML).
    private static func readDouble(_ value: TOMLValueConvertible?) -> Double? {
        if let v = value {
            // TOMLKit stores integers as TOMLInt and floats as Double
            if let i = v as? Int { return Double(i) }
            if let d = v as? Double { return d }
            // Try parsing the description
            return Double(v.debugDescription)
        }
        return nil
    }

    private static func readString(_ value: TOMLValueConvertible?) -> String? {
        if let v = value as? String { return v }
        if let v = value { return v.debugDescription }
        return nil
    }

    private static func readBool(_ value: TOMLValueConvertible?) -> Bool? {
        if let v = value as? Bool { return v }
        return nil
    }

    /// Parse a TOML table into a config.
    private static func parse(table: TOMLTable) -> ScrollWMConfig {
        var config = ScrollWMConfig()

        // [layout]
        if let layout = table["layout"] as? TOMLTable {
            if let v = readDouble(layout["gap"]) { config.gap = v }
            if let dw = layout["default_width"] as? TOMLTable {
                config.defaultWidth = parseColumnWidth(dw)
            }
            if let fm = readString(layout["focus_mode"]) {
                switch fm {
                case "never": config.focusMode = .never
                case "always": config.focusMode = .always
                case "on-overflow", "on_overflow", "onOverflow": config.focusMode = .onOverflow
                default: break
                }
            }
            if let v = readBool(layout["animation_enabled"]) { config.animationEnabled = v }

            if let struts = layout["struts"] as? TOMLTable {
                if let v = readDouble(struts["left"]) { config.struts.left = v }
                if let v = readDouble(struts["right"]) { config.struts.right = v }
                if let v = readDouble(struts["top"]) { config.struts.top = v }
                if let v = readDouble(struts["bottom"]) { config.struts.bottom = v }
            }
        }

        // [animation]
        if let anim = table["animation"] as? TOMLTable {
            if let v = readDouble(anim["scroll_stiffness"]) { config.scrollStiffness = v }
            if let v = readDouble(anim["scroll_damping_ratio"]) { config.scrollDampingRatio = v }
            if let v = readDouble(anim["bounce_distance"]) { config.bounceDistance = v }
            if let v = readDouble(anim["bounce_damping_ratio"]) { config.bounceDampingRatio = v }
        }

        // [keybindings]
        if let kb = table["keybindings"] as? TOMLTable {
            for (key, value) in kb {
                if let v = readString(value) {
                    config.keybindings[key] = v
                }
            }
        }

        // [gesture]
        if let gesture = table["gesture"] as? TOMLTable {
            if let v = readString(gesture["modifier"]) { config.gestureModifier = v }
        }

        // [[rules]]
        if let rules = table["rules"] as? TOMLArray {
            for item in rules {
                if let rule = item as? TOMLTable {
                    var rc = WindowRuleConfig()
                    rc.appID = readString(rule["app_id"])
                    rc.appIDRegex = readString(rule["app_id_regex"])
                    rc.titleRegex = readString(rule["title_regex"])
                    if let v = readBool(rule["floating"]) { rc.floating = v }
                    config.rules.append(rc)
                }
            }
        }

        // [terminal]
        if let terminal = table["terminal"] as? TOMLTable {
            if let v = readString(terminal["app"]) { config.terminalApp = v }
        }

        // start_at_login (top-level)
        if let v = readBool(table["start_at_login"]) { config.startAtLogin = v }

        return config
    }

    private static func parseColumnWidth(_ table: TOMLTable) -> ColumnWidth {
        if let p = readDouble(table["proportion"]) { return .proportion(p) }
        if let f = readDouble(table["fixed"]) { return .fixed(f) }
        return .proportion(0.5)
    }

    /// Create default config file.
    public static func createDefaultConfig() {
        let dir = configDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let defaultConfig = """
        # ScrollWM Configuration
        # Edit this file and save — changes apply automatically.

        # Start ScrollWM automatically when you log in (requires .app bundle)
        # start_at_login = false

        [layout]
        gap = 16
        focus_mode = "always"  # "never", "always", "on-overflow"
        animation_enabled = true

        # default_width = { proportion = 0.5 }

        # Insets for external status bars (e.g., SketchyBar)
        # [layout.struts]
        # left = 0
        # right = 0
        # top = 0
        # bottom = 0

        [animation]
        scroll_stiffness = 800
        scroll_damping_ratio = 1.0
        bounce_distance = 40
        bounce_damping_ratio = 0.6

        [keybindings]
        # Hyper = Ctrl+Shift+Cmd+Opt (all four modifiers)
        focus_left = "hyper-h"
        focus_right = "hyper-l"
        move_left = "hyper-j"
        move_right = "hyper-k"
        cycle_width = "hyper-r"
        toggle_full_width = "hyper-f"
        toggle_floating = "hyper-space"
        close_window = "hyper-w"
        spawn_terminal = "hyper-t"

        [gesture]
        modifier = "fn"  # Hold this key + trackpad scroll to pan the strip

        # Window rules: match by app bundle ID or title regex
        # [[rules]]
        # app_id = "us.zoom.xos"
        # floating = true

        # [[rules]]
        # app_id_regex = "com\\\\.apple\\\\.systempreferences"
        # floating = true

        [terminal]
        app = "/System/Applications/Utilities/Terminal.app"
        """

        try? defaultConfig.write(toFile: configPath, atomically: true, encoding: .utf8)
        print("[Config] Created default config at \(configPath)")
        fflush(stdout)
    }
}

// MARK: - File Watcher

/// Watches the config file for changes and reloads.
public final class ConfigWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    public var onConfigChanged: ((ScrollWMConfig) -> Void)?

    public init() {}

    deinit { stop() }

    /// Start watching the config file.
    public func start() {
        let path = ScrollWMConfig.configPath

        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            print("[Config] Cannot watch \(path) — file not found")
            fflush(stdout)
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            // Small delay to let the editor finish writing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.reload()
            }
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
                self?.fileDescriptor = -1
            }
        }

        source.resume()
        self.source = source
        print("[Config] Watching \(path) for changes")
        fflush(stdout)
    }

    /// Stop watching.
    public func stop() {
        source?.cancel()
        source = nil
    }

    private func reload() {
        let (config, error) = ScrollWMConfig.load()
        if let error = error {
            print("[Config] Reload error: \(error)")
            fflush(stdout)
            return
        }
        print("[Config] Reloaded successfully")
        fflush(stdout)
        onConfigChanged?(config)
    }
}
