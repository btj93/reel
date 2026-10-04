import Core
import Foundation
import TOMLKit

public enum KeyAction: String, CaseIterable, Sendable {
    case focusLeft = "focus_left"
    case focusRight = "focus_right"
    case focusUp = "focus_up"
    case focusDown = "focus_down"
    case moveLeft = "move_left"
    case moveRight = "move_right"
    case cycleWidth = "cycle_width"
    case toggleFullWidth = "toggle_full_width"
    case toggleFloating = "toggle_floating"
    case closeWindow = "close_window"
}

/// The key held for trackpad swipes, wheel scrolls and title-bar drags.
public enum GestureModifier: String, CaseIterable, Sendable {
    case fn, ctrl, alt, cmd
}

public enum IndicatorStyle: String, CaseIterable, Sendable {
    case none, ring, raise, flash
}

public struct IndicatorConfig: Equatable, Sendable {
    public var style: IndicatorStyle
    public var color: String
    public var width: Double
    public var cornerRadius: Double
    public var raiseHeight: Double

    public init(style: IndicatorStyle = .ring, color: String = "auto", width: Double = 3, cornerRadius: Double = 10,
                raiseHeight: Double = 20) {
        self.style = style
        self.color = color
        self.width = width
        self.cornerRadius = cornerRadius
        self.raiseHeight = raiseHeight
    }
}

public struct ConfigError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

/// The whole config file. Every key is listed in `AppConfig.parse`; any other key is an error, so a typo never
/// silently falls back to a default.
public struct AppConfig: Sendable {
    public internal(set) var engine = EngineConfig()
    public internal(set) var keys: [KeyAction: String] = [
        .focusLeft: "alt-h", .focusRight: "alt-l", .focusUp: "alt-k", .focusDown: "alt-j",
        .moveLeft: "alt-shift-h", .moveRight: "alt-shift-l", .cycleWidth: "alt-r", .toggleFullWidth: "alt-f", .toggleFloating: "alt-space", .closeWindow: "alt-w",
    ]
    public internal(set) var struts = WorkingInsets()
    public internal(set) var indicator = IndicatorConfig()
    public internal(set) var gestureModifier = GestureModifier.fn

    public init() {}

    public static func parse(_ source: String) throws(ConfigError) -> AppConfig {
        do { return try read(TOMLTable(string: source)) } catch let error as ConfigError { throw error } catch {
            throw ConfigError(description: "syntax: \((error as? TOMLParseError)?.description ?? "\(error)")")
        }
    }

    private static func read(_ root: TOMLTable) throws -> AppConfig {
        let base = EngineConfig()
        var gap = base.gap, defaultWidth = base.defaultWidth, presets = base.widthPresets, snap = base.snapPoints
        var animate = base.animate, stiffness = base.scroll.stiffness, damping = base.dampingRatio
        var bounce = base.bounceDistance, bounceDamping = base.bounceDampingRatio, rules = base.rules, gestureSnap = base.gestureSnap
        var config = AppConfig()
        try Section(root, path: "").read([
            "layout": { try Section($0, path: "layout").read([
                "gap": { gap = try number($0, "layout.gap", min: 0) },
                "default_width": { defaultWidth = try proportion($0, "layout.default_width") },
                "width_presets": { presets = try list($0, "layout.width_presets").map { try proportion($0, "layout.width_presets") } },
                "snap": { snap = try list($0, "layout.snap").map { try choice($0, "layout.snap", [SnapPoint.left, .middle, .right]) } },
                "struts": { try Section($0, path: "layout.struts").read([
                    "top": { config.struts.top = try number($0, "layout.struts.top", min: 0) },
                    "bottom": { config.struts.bottom = try number($0, "layout.struts.bottom", min: 0) },
                    "left": { config.struts.left = try number($0, "layout.struts.left", min: 0) },
                    "right": { config.struts.right = try number($0, "layout.struts.right", min: 0) },
                ]) },
            ]) },
            "animation": { try Section($0, path: "animation").read([
                "enabled": { animate = try flag($0, "animation.enabled") },
                "stiffness": { stiffness = try number($0, "animation.stiffness", above: 0) },
                "damping_ratio": { damping = try number($0, "animation.damping_ratio", above: 0) },
                "bounce_distance": { bounce = try number($0, "animation.bounce_distance", min: 0) },
                "bounce_damping_ratio": { bounceDamping = try number($0, "animation.bounce_damping_ratio", above: 0) },
            ]) },
            "keys": { try Section($0, path: "keys").read(Dictionary(uniqueKeysWithValues: KeyAction.allCases.map { action in
                (action.rawValue, { config.keys[action] = try text($0, "keys.\(action.rawValue)") })
            })) },
            "gesture": { try Section($0, path: "gesture").read([
                "modifier": { config.gestureModifier = try choice($0, "gesture.modifier", GestureModifier.allCases) },
                "snap": { gestureSnap = try flag($0, "gesture.snap") },
            ]) },
            "indicator": { try Section($0, path: "indicator").read([
                "style": { config.indicator.style = try choice($0, "indicator.style", IndicatorStyle.allCases) },
                "color": { config.indicator.color = try color($0) },
                "width": { config.indicator.width = try number($0, "indicator.width", min: 0) },
                "corner_radius": { config.indicator.cornerRadius = try number($0, "indicator.corner_radius", min: 0) },
                "raise_height": { config.indicator.raiseHeight = try number($0, "indicator.raise_height", min: 0) },
            ]) },
            "rules": { value in
                rules = try list(value, "rules").enumerated().map { index, entry in
                    var bundleID: String?, bundleIDRegex: String?, titleRegex: String?, floating: Bool?
                    let path = "rules[\(index)]"
                    try Section(entry, path: path).read([
                        "bundle_id": { bundleID = try text($0, "\(path).bundle_id") },
                        "bundle_id_regex": { bundleIDRegex = try regex($0, "\(path).bundle_id_regex") },
                        "title_regex": { titleRegex = try regex($0, "\(path).title_regex") },
                        "floating": { floating = try flag($0, "\(path).floating") },
                    ])
                    guard let floating, bundleID?.isEmpty != true,
                          bundleID != nil || bundleIDRegex != nil || titleRegex != nil else {
                        throw ConfigError(description: "\(path) needs bundle_id and floating")
                    }
                    return Rule(bundleID: bundleID, bundleIDRegex: bundleIDRegex, titleRegex: titleRegex, floating: floating)
                }
            },
        ])
        config.engine = EngineConfig(gap: gap, defaultWidth: defaultWidth, animate: animate, gestureSnap: gestureSnap,
                                     rules: rules, widthPresets: presets, snapPoints: snap, stiffness: stiffness,
                                     dampingRatio: damping, bounceDistance: bounce, bounceDampingRatio: bounceDamping,
                                     raiseHeight: config.indicator.style == .raise ? config.indicator.raiseHeight : 0)
        return config
    }
}

private struct Section {
    let table: TOMLTable
    let path: String

    init(_ value: TOMLValueConvertible, path: String) throws {
        guard let table = value as? TOMLTable ?? value.table else { throw ConfigError(description: "\(path) must be a table") }
        self.table = table
        self.path = path
    }

    func read(_ fields: [String: (TOMLValueConvertible) throws -> Void]) throws {
        for key in table.keys.sorted() {
            guard let field = fields[key] else {
                throw ConfigError(description: "unknown key \(path.isEmpty ? key : "\(path).\(key)")")
            }
            guard let value = table[key] else { continue }
            try field(value)
        }
    }
}

private func number(_ value: TOMLValueConvertible, _ key: String, min: Double? = nil, above: Double? = nil) throws -> Double {
    guard let number = value.int.map(Double.init) ?? value.double, number.isFinite,
          min.map({ number >= $0 }) ?? true, above.map({ number > $0 }) ?? true else {
        let bound = min.map { " >= \($0)" } ?? above.map { " > \($0)" } ?? ""
        throw ConfigError(description: "\(key) must be a number\(bound)")
    }
    return number
}

private func proportion(_ value: TOMLValueConvertible, _ key: String) throws -> Double {
    let number = try number(value, key, above: 0)
    guard number <= 1 else { throw ConfigError(description: "\(key) must be a proportion in (0, 1]") }
    return number
}

private func flag(_ value: TOMLValueConvertible, _ key: String) throws -> Bool {
    guard let flag = value.bool else { throw ConfigError(description: "\(key) must be true or false") }
    return flag
}

private func text(_ value: TOMLValueConvertible, _ key: String) throws -> String {
    guard let text = value.string else { throw ConfigError(description: "\(key) must be a string") }
    return text
}

private func list(_ value: TOMLValueConvertible, _ key: String) throws -> [TOMLValueConvertible] {
    guard let array = value as? TOMLArray ?? value.array else { throw ConfigError(description: "\(key) must be an array") }
    return Array(array)
}

private func choice<T: RawRepresentable<String>>(_ value: TOMLValueConvertible, _ key: String, _ options: [T]) throws -> T {
    guard let choice = options.first(where: { $0.rawValue == value.string }) else {
        throw ConfigError(description: "\(key) must be one of \(options.map(\.rawValue).joined(separator: ", "))")
    }
    return choice
}

private func color(_ value: TOMLValueConvertible) throws -> String {
    let color = try text(value, "indicator.color")
    let hex = color.hasPrefix("#") ? color.dropFirst() : ""
    guard color == "auto" || ([3, 6].contains(hex.count) && hex.allSatisfy(\.isHexDigit)) else {
        throw ConfigError(description: "indicator.color must be \"auto\" or #RGB / #RRGGBB")
    }
    return color
}

private func regex(_ value: TOMLValueConvertible, _ key: String) throws -> String {
    let pattern = try text(value, key)
    guard !pattern.isEmpty, (try? NSRegularExpression(pattern: pattern)) != nil else {
        throw ConfigError(description: "\(key) must be a valid nonempty regex")
    }
    return pattern
}
