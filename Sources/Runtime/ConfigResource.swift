import Foundation

public func defaultConfigSource() -> String {
    let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.bundleURL.deletingLastPathComponent()]
    for root in roots.compactMap({ $0 }) {
        let bundleURL = root.appendingPathComponent("Reel_Engine.bundle")
        let url = Bundle(url: bundleURL)?.url(forResource: "config.default", withExtension: "toml")
            ?? bundleURL.appendingPathComponent("config.default.toml")
        if let source = try? String(contentsOf: url, encoding: .utf8) { return source }
    }
    return ""
}
