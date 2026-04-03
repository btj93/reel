import Foundation
import TOMLKit
import Core

/// ScrollWM configuration, loaded from ~/.config/scrollwm/config.toml.
public struct ScrollWMConfig: Sendable {

    // MARK: - Layout

    public var gap: Double = 16
    public var defaultWidth: ColumnWidth = .proportion(0.5)
    public var widthPresets: [ColumnWidth] = [.proportion(0.33), .proportion(0.5), .proportion(0.67)]
    public var snapPoints: [SnapPoint] = [.middle]
    public var struts: StrutsConfig = StrutsConfig()
    public var animationEnabled: Bool = true
    public var floatingOpacity: Double = 1.0

    // MARK: - Animation

    public var scrollStiffness: Double = 800
    public var scrollDampingRatio: Double = 1.0
    public var bounceDistance: Double = 40
    public var bounceDampingRatio: Double = 0.6

    /// Spring params for width animation (reuses scroll spring values).
    public var widthSpringParams: SpringParams {
        SpringParams(dampingRatio: scrollDampingRatio, stiffness: scrollStiffness, epsilon: 0.5)
    }

    // MARK: - Keybindings (action → key string like "hyper-h")

    public var keybindings: [String: String] = [
        "focus_left": "alt-h",
        "focus_right": "alt-l",
        "move_left": "alt-shift-h",
        "move_right": "alt-shift-l",
        "cycle_width": "alt-r",
        "toggle_full_width": "alt-f",
        "toggle_floating": "alt-space",
        "close_window": "alt-w",
        "toggle_always_on_top": "alt-t",
    ]

    // MARK: - Gesture

    public var gestureModifier: String = "fn"
    public var gestureSnap: Bool = true

    // MARK: - Window Rules

    public var rules: [WindowRuleConfig] = []

    // MARK: - Position Memory
    public var positionMemory: Bool = true
    public var savedPositionLimit: Int = 500
    public var positionMemoryRules: [PositionMemoryRuleConfig] = []

    // MARK: - Focus Indicator

    public var focusIndicator: FocusIndicatorConfig = FocusIndicatorConfig()

    // MARK: - Zen Mode

    public var zenMode: ZenModeConfig = ZenModeConfig()

    // MARK: - Startup

    public var startAtLogin: Bool = false

    public init() {}

    // MARK: - Config Path

    public static let configDir = NSHomeDirectory() + "/.config/scrollwm"
    public static let configPath = configDir + "/config.toml"
}

public struct PositionMemoryRuleConfig: Sendable {
    public var appID: String
    public var matchBy: String = "title"  // "title" or "order"

    public init(appID: String, matchBy: String = "title") {
        self.appID = appID
        self.matchBy = matchBy
    }
}

/// Window rule from config.
public struct WindowRuleConfig: Sendable {
    public var appID: String?
    public var appIDRegex: String?
    public var titleRegex: String?
    public var floating: Bool = false
    public var opacity: Double? = nil
    public var alwaysOnTop: Bool? = nil

    public init(appID: String? = nil, appIDRegex: String? = nil, titleRegex: String? = nil, floating: Bool = false, opacity: Double? = nil, alwaysOnTop: Bool? = nil) {
        self.appID = appID
        self.appIDRegex = appIDRegex
        self.titleRegex = titleRegex
        self.floating = floating
        self.opacity = opacity
        self.alwaysOnTop = alwaysOnTop
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

/// Focus indicator configuration.
public struct FocusIndicatorConfig: Sendable {
    public enum Style: String, Sendable {
        case none, ring, raise, flash
    }
    public var style: Style = .ring
    public var color: String = "auto"    // "auto" or hex "#RRGGBB" / "#RGB"
    public var width: Double = 3
    public var cornerRadius: Double = 10

    public init() {}
}

/// Zen mode configuration: dim unfocused tiled windows.
public struct ZenModeConfig: Sendable {
    public var enabled: Bool = false
    public var dimAlpha: Double = 0.3
    public var fadeDuration: Double = 0.15
    public init() {}
}

// MARK: - Loading

extension ScrollWMConfig {

    /// Load config: parse bundled defaults first, then overlay user config on top.
    public static func load() -> (config: ScrollWMConfig, error: String?) {
        // Start from bundled defaults
        var config = loadDefaults()

        let path = configPath

        // Create user config file if it doesn't exist
        if !FileManager.default.fileExists(atPath: path) {
            createDefaultConfig()
            return (config, nil)
        }

        // Parse user config on top of defaults
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            let table = try TOMLTable(string: content)
            config = parse(table: table, base: config)
            return (config, nil)
        } catch {
            return (config, "Config error: \(error.localizedDescription)")
        }
    }

    /// Load defaults from bundled config.default.toml.
    private static let cachedDefaults: ScrollWMConfig = {
        guard let url = Bundle.module.url(forResource: "config.default", withExtension: "toml"),
              let content = try? String(contentsOf: url, encoding: .utf8),
              let table = try? TOMLTable(string: content) else {
            #if DEBUG
            print("[Config] Warning: could not load bundled config.default.toml, using hardcoded defaults")
            fflush(stdout)
            #endif
            return ScrollWMConfig()
        }
        return parse(table: table, base: ScrollWMConfig())
    }()

    private static func loadDefaults() -> ScrollWMConfig {
        cachedDefaults
    }

    // MARK: - Helpers for reading TOML values

    /// Read a number from a TOML value (handles both Int and Double in TOML).
    private static func readDouble(_ value: TOMLValueConvertible?) -> Double? {
        if let v = value {
            if let i = v as? Int { return Double(i) }
            if let d = v as? Double { return d }
            if let i = v.int { return Double(i) }
            if let d = v.double { return d }
        }
        return nil
    }

    private static func readString(_ value: TOMLValueConvertible?) -> String? {
        if let v = value as? String { return v }
        return value?.string
    }

    private static func readBool(_ value: TOMLValueConvertible?) -> Bool? {
        if let v = value as? Bool { return v }
        return value?.bool
    }

    private static func readArray(_ value: TOMLValueConvertible?) -> TOMLArray? {
        if let a = value as? TOMLArray { return a }
        return value?.array
    }

    /// Unwrap a TOML value to a TOMLTable, handling both direct TOMLTable and wrapped TOMLValue.
    private static func readTable(_ value: TOMLValueConvertible?) -> TOMLTable? {
        if let t = value as? TOMLTable { return t }
        return value?.table
    }

    /// Parse a TOML table into a config, starting from a base config.
    /// Only keys present in the table override the base values.
    private static func parse(table: TOMLTable, base: ScrollWMConfig = ScrollWMConfig()) -> ScrollWMConfig {
        var config = base

        // [layout]
        if let layout = readTable(table["layout"]) {
            if let v = readDouble(layout["gap"]) { config.gap = v }
            if let dw = readTable(layout["default_width"]) {
                config.defaultWidth = parseColumnWidth(dw)
            }
            // Parse snap array
            if let snapArray = readArray(layout["snap"]) {
                var points: [SnapPoint] = []
                for item in snapArray {
                    if let str = readString(item) {
                        switch str {
                        case "left": points.append(.left)
                        case "middle": points.append(.middle)
                        case "right": points.append(.right)
                        default:
                            #if DEBUG
                            print("[Config] Unknown snap point: \(str)")
                            fflush(stdout)
                            #endif
                        }
                    }
                }
                let deduped = Array(Set(points)).sorted()
                if !deduped.isEmpty {
                    config.snapPoints = deduped
                }
            }

            // Validation
            if config.snapPoints.isEmpty {
                #if DEBUG
                print("[Config] Warning: snap is empty, defaulting to [middle]")
                fflush(stdout)
                #endif
                config.snapPoints = [.middle]
            }
            if let v = readBool(layout["animation_enabled"]) { config.animationEnabled = v }

            if let struts = readTable(layout["struts"]) {
                if let v = readDouble(struts["left"]) { config.struts.left = v }
                if let v = readDouble(struts["right"]) { config.struts.right = v }
                if let v = readDouble(struts["top"]) { config.struts.top = v }
                if let v = readDouble(struts["bottom"]) { config.struts.bottom = v }
            }
            if let presetsArray = readArray(layout["width_presets"]) {
                var presets: [ColumnWidth] = []
                for item in presetsArray {
                    if let v = readDouble(item), v > 0, v <= 1 {
                        presets.append(.proportion(v))
                    } else {
                        #if DEBUG
                        print("[Config] Warning: skipping invalid width_preset value")
                        fflush(stdout)
                        #endif
                    }
                }
                if !presets.isEmpty {
                    config.widthPresets = presets
                }
            }
            if let v = readBool(layout["position_memory"]) { config.positionMemory = v }
            if let v = readDouble(layout["saved_position_limit"]) { config.savedPositionLimit = Int(v) }
            if let v = readDouble(layout["floating_opacity"]) { config.floatingOpacity = max(0.0, min(1.0, v)) }
        }

        // [animation]
        if let anim = readTable(table["animation"]) {
            if let v = readDouble(anim["scroll_stiffness"]) { config.scrollStiffness = v }
            if let v = readDouble(anim["scroll_damping_ratio"]) { config.scrollDampingRatio = v }
            if let v = readDouble(anim["bounce_distance"]) { config.bounceDistance = v }
            if let v = readDouble(anim["bounce_damping_ratio"]) { config.bounceDampingRatio = v }
        }

        // [keybindings]
        if let kb = readTable(table["keybindings"]) {
            for (key, value) in kb {
                if let v = readString(value) {
                    config.keybindings[key] = v
                }
            }
        }

        // [gesture]
        if let gesture = readTable(table["gesture"]) {
            if let v = readString(gesture["modifier"]) { config.gestureModifier = v }
            if let v = readBool(gesture["snap"]) { config.gestureSnap = v }
        }

        // [[rules]]
        if let rules = readArray(table["rules"]) {
            for item in rules {
                if let rule = readTable(item) {
                    var rc = WindowRuleConfig()
                    rc.appID = readString(rule["app_id"])
                    rc.appIDRegex = readString(rule["app_id_regex"])
                    rc.titleRegex = readString(rule["title_regex"])
                    if let v = readBool(rule["floating"]) { rc.floating = v }
                    if let v = readDouble(rule["opacity"]) { rc.opacity = max(0.0, min(1.0, v)) }
                    if let v = readBool(rule["always_on_top"]) { rc.alwaysOnTop = v }
                    config.rules.append(rc)
                }
            }
        }

        if let pmRules = readArray(table["position_memory_rules"]) {
            for item in pmRules {
                if let rule = readTable(item) {
                    var rc = PositionMemoryRuleConfig(appID: "")
                    if let v = readString(rule["app_id"]) { rc.appID = v }
                    if let v = readString(rule["match_by"]) { rc.matchBy = v }
                    if !rc.appID.isEmpty {
                        config.positionMemoryRules.append(rc)
                    }
                }
            }
        }

        // start_at_login (top-level)
        if let v = readBool(table["start_at_login"]) { config.startAtLogin = v }

        // [focus_indicator]
        if let fi = readTable(table["focus_indicator"]) {
            if let v = readString(fi["style"]) {
                if let style = FocusIndicatorConfig.Style(rawValue: v) {
                    config.focusIndicator.style = style
                } else {
                    #if DEBUG
                    print("[Config] Unknown focus_indicator style: \(v)")
                    fflush(stdout)
                    #endif
                }
            }
            if let v = readString(fi["color"]) { config.focusIndicator.color = v }
            if let v = readDouble(fi["width"]) { config.focusIndicator.width = v }
            if let v = readDouble(fi["corner_radius"]) { config.focusIndicator.cornerRadius = v }
        }

        // [zen_mode]
        if let zm = readTable(table["zen_mode"]) {
            if let v = readBool(zm["enabled"]) { config.zenMode.enabled = v }
            if let v = readDouble(zm["dim_alpha"]) { config.zenMode.dimAlpha = max(0.0, min(1.0, v)) }
            if let v = readDouble(zm["fade_duration"]) { config.zenMode.fadeDuration = max(0.05, v) }
        }

        return config
    }

    private static func parseColumnWidth(_ table: TOMLTable) -> ColumnWidth {
        if let p = readDouble(table["proportion"]) { return .proportion(p) }
        if let f = readDouble(table["fixed"]) { return .fixed(f) }
        return .proportion(0.5)
    }

    /// Create default config file from bundled config.default.toml.
    public static func createDefaultConfig() {
        let dir = configDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        guard let url = Bundle.module.url(forResource: "config.default", withExtension: "toml"),
              let defaultConfig = try? String(contentsOf: url, encoding: .utf8) else {
            #if DEBUG
            print("[Config] Error: could not load bundled config.default.toml")
            fflush(stdout)
            #endif
            return
        }

        try? defaultConfig.write(toFile: configPath, atomically: true, encoding: .utf8)
        #if DEBUG
        print("[Config] Created default config at \(configPath)")
        fflush(stdout)
        #endif
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
            #if DEBUG
            print("[Config] Cannot watch \(path) — file not found")
            fflush(stdout)
            #endif
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
        #if DEBUG
        print("[Config] Watching \(path) for changes")
        fflush(stdout)
        #endif
    }

    /// Stop watching.
    public func stop() {
        source?.cancel()
        source = nil
    }

    private func reload() {
        let (config, error) = ScrollWMConfig.load()
        if let error = error {
            #if DEBUG
            print("[Config] Reload error: \(error)")
            fflush(stdout)
            #endif
            return
        }
        #if DEBUG
        print("[Config] Reloaded successfully")
        fflush(stdout)
        #endif
        onConfigChanged?(config)
    }
}
